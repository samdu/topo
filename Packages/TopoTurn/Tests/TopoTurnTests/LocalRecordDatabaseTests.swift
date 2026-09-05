import Foundation
import Testing
import TopoCore
@testable import TopoTurn

@Suite struct LocalRecordDatabaseTests {
    @Test func createOnlyAndCompareAndSet() async throws {
        let db = try LocalRecordDatabase(url: nil)
        let a = Record(type: "T", id: RecordID("a"), fields: ["n": .int(1)])
        let saved = try await db.save(a)
        #expect(saved.changeTag != nil)
        await #expect(throws: RecordDatabaseError.self) { _ = try await db.save(a) }
        var stale = saved
        stale.changeTag = "nope"
        await #expect(throws: RecordDatabaseError.self) { _ = try await db.save(stale) }
        var fresh = saved
        fresh["n"] = .int(2)
        let again = try await db.save(fresh)
        #expect(again.changeTag != saved.changeTag)
        #expect(try await db.fetch(RecordID("a"))?.int("n") == 2)
        var ghost = Record(type: "T", id: RecordID("ghost"))
        ghost.changeTag = "1"
        await #expect(throws: RecordDatabaseError.self) { _ = try await db.save(ghost) }
    }

    @Test func aBatchIsAllOrNothing() async throws {
        let db = try LocalRecordDatabase(url: nil)
        _ = try await db.save(Record(type: "T", id: RecordID("x")))
        await #expect(throws: RecordDatabaseError.self) {
            _ = try await db.save([Record(type: "T", id: RecordID("y")), Record(type: "T", id: RecordID("x"))])
        }
        #expect(try await db.fetch(RecordID("y")) == nil)
    }

    @Test func queriesFilterByTypeAndField() async throws {
        let db = try LocalRecordDatabase(url: nil)
        _ = try await db.save([
            Record(type: "Turn", id: RecordID("1"), fields: ["device": .string("p"), "sequence": .int(1)]),
            Record(type: "Turn", id: RecordID("2"), fields: ["device": .string("p"), "sequence": .int(2)]),
            Record(type: "Turn", id: RecordID("3"), fields: ["device": .string("q"), "sequence": .int(3)]),
            Record(type: "Other", id: RecordID("4"), fields: ["device": .string("p"), "sequence": .int(9)]),
        ])
        let all = try await db.query(RecordQuery(type: "Turn"))
        #expect(all.count == 3)
        let later = try await db.query(RecordQuery(type: "Turn", filters: [.init("device", .equals, .string("p")), .init("sequence", .greaterThan, .int(1))]))
        #expect(later.map(\.id.name) == ["2"])
    }

    @Test func survivesARelaunchFromItsFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topo-\(UUID().uuidString)/log.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let first = try LocalRecordDatabase(url: url)
        let saved = try await first.save(Record(type: "T", id: RecordID("a"), fields: ["s": .strings(["x", "y"]), "d": .date(Date(timeIntervalSince1970: 5))]))
        let second = try LocalRecordDatabase(url: url)
        let back = try #require(try await second.fetch(RecordID("a")))
        #expect(back == saved)
        let next = try await second.save(Record(type: "T", id: RecordID("b")))
        #expect(next.changeTag != saved.changeTag)
    }

    @Test func aFailedWriteLeavesNothingBehind() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A directory where the file should be makes the atomic write fail.
        let url = dir.appendingPathComponent("log.json")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let db = try LocalRecordDatabase(url: url)
        await #expect(throws: (any Error).self) { _ = try await db.save(Record(type: "T", id: RecordID("a"))) }
        #expect(try await db.fetch(RecordID("a")) == nil)
        // The same create-only save is still open, not a conflict.
        try FileManager.default.removeItem(at: url)
        #expect(try await db.save(Record(type: "T", id: RecordID("a"))).changeTag == "1")
    }

    @Test func destroyEmptiesItDeletesTheFileAndRefusesWrites() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("topo-\(UUID().uuidString)/log.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try LocalRecordDatabase(url: url)
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        try db.destroy()
        #expect(try await db.fetch(RecordID("a")) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await #expect(throws: RecordDatabaseError.self) { _ = try await db.save(Record(type: "T", id: RecordID("b"))) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(try await LocalRecordDatabase(url: url).query(RecordQuery(type: "T")).isEmpty)
    }

    @Test func aFileThatCannotBeRemovedIsReportedAndStillNotServed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("topo-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("log.json")
        let db = try LocalRecordDatabase(url: url)
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        // A read-only directory refuses the unlink.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        #expect(throws: (any Error).self) { try db.destroy() }
        #expect(try await db.fetch(RecordID("a")) == nil)
        await #expect(throws: RecordDatabaseError.self) { _ = try await db.save(Record(type: "T", id: RecordID("b"))) }
    }

    @Test func theTurnLogAndLeaseRunOnIt() async throws {
        let db = try LocalRecordDatabase(url: nil)
        let transport = RecordingTransport((200, reply("hello")))
        let (runner, _) = try await makeRunner(database: db, transport: transport)
        let result = try await runner.run("hi", model: .sonnet5)
        #expect(result.assistant.text == "hello")
        #expect(try await TurnLog(database: db).read().ordered.count == 2)
    }
}
