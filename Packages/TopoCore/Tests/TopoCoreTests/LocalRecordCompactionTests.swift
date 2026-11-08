import Foundation
import Testing
@testable import TopoCore

/// Compaction seen by a later open, and a torn last frame whose length is whole.
@Suite struct LocalRecordCompactionTests {
    let file = FileManager.default.temporaryDirectory.appending(path: "lens-\(UUID().uuidString)/records.journal")
    func open() throws -> LocalRecordDatabase { try LocalRecordDatabase(file: file) }

    /// Compaction keeps every record, seen by a *second* open (the first open's memory is not the file).
    @Test func compactionKeepsEveryRecordAcrossTheNextOpen() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "Turn", id: RecordID("turn/p/1"), fields: ["t": .string("hi")]))
        var b = try await db.save(Record(type: "T", id: RecordID("b"), fields: ["v": .int(0)]))
        for v in 1...10 { b.fields["v"] = .int(Int64(v)); b = try await db.save(b) }
        _ = try open()           // compacts
        let second = try open()  // reads the snapshot
        #expect(await second.current(RecordID("turn/p/1")) != nil)
        #expect(await second.current(RecordID("b")) == b)
    }

    /// A tag handed out before a compaction is never minted again for that record.
    @Test func aStaleTagFromBeforeCompactionIsStillRefused() async throws {
        let db = try open()
        let first = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        var cur = first
        for v in 1...10 { cur.fields["v"] = .int(Int64(v)); cur = try await db.save(cur) }
        _ = try open()
        let after = try open()
        var next = cur; next.fields["v"] = .int(99)
        let saved = try await after.save(next)
        #expect(saved.changeTag != first.changeTag, "tag \(saved.changeTag ?? "") reissued")
        var stale = first; stale.fields["v"] = .int(-1)
        await #expect(throws: RecordDatabaseError.self) { try await after.save(stale) }
    }

    /// A token from before a compaction is refused at every later open, not only the compacting one.
    @Test func aPreCompactionTokenStaysExpiredAtTheNextOpen() async throws {
        let db = try open()
        var r = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        let token = try await db.changes(ofType: "T", since: nil).token
        for v in 1...10 { r.fields["v"] = .int(Int64(v)); r = try await db.save(r) }
        _ = try open()
        let later = try open()
        await #expect(throws: RecordChangesError.self) { try await later.changes(ofType: "T", since: token) }
    }

    /// A journal just compacted is not compacted again (tokens survive a plain relaunch after one).
    @Test func aTokenAfterCompactionSurvivesTheNextOpen() async throws {
        let db = try open()
        var r = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(0)]))
        for v in 1...10 { r.fields["v"] = .int(Int64(v)); r = try await db.save(r) }
        let compacted = try open()
        let token = try await compacted.changes(ofType: "T", since: nil).token
        let later = try open()
        _ = try await later.changes(ofType: "T", since: token)
    }

    /// A committed last frame whose body was zeroed is a frame that rotted, not a torn write: its
    /// slot was written after it was whole, so the file is refused and nothing is cut.
    @Test func aCommittedLastFrameThatDoesNotReadIsDamage() async throws {
        let db = try open()
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        let before = try Data(contentsOf: file)
        _ = try await db.save(Record(type: "T", id: RecordID("b")))
        var bytes = try Data(contentsOf: file)
        for i in (before.count + LocalRecordDatabase.prefix)..<bytes.count { bytes[i] = 0 }
        try bytes.write(to: file)
        #expect(throws: LocalRecordDatabase.Failure.self) { try open() }
        #expect(try Data(contentsOf: file) == bytes)
    }
}
