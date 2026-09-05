import Foundation
import Testing
import TopoCore
import TopoCoreTesting

@Suite struct InMemoryRecordDatabaseTests {
    let db = InMemoryRecordDatabase()

    @Test func createIsCreateOnly() async throws {
        let id = RecordID("r")
        let saved = try await db.save(Record(type: "T", id: id, fields: ["v": .int(1)]))
        #expect(saved.changeTag != nil)
        await #expect(throws: RecordDatabaseError.self) {
            try await db.save(Record(type: "T", id: id, fields: ["v": .int(2)]))
        }
        #expect(await db.current(id)?.int("v") == 1)
    }

    @Test func compareAndSetNeedsTheCurrentTag() async throws {
        let id = RecordID("r")
        var first = try await db.save(Record(type: "T", id: id, fields: ["v": .int(1)]))
        var second = try await db.save(first.with(v: 2))
        #expect(second.changeTag != first.changeTag)
        do {
            first.fields["v"] = .int(3)
            _ = try await db.save(first)
            Issue.record("stale save should fail")
        } catch RecordDatabaseError.serverRecordChanged(let rid, let server) {
            #expect(rid == id)
            #expect(server.int("v") == 2)
        }
        second.fields["v"] = .int(4)
        _ = try await db.save(second)
        #expect(await db.current(id)?.int("v") == 4)
    }

    @Test func taggedSaveOfMissingRecordIsUnknownItem() async throws {
        await #expect(throws: RecordDatabaseError.self) {
            try await db.save(Record(type: "T", id: RecordID("gone"), changeTag: "x"))
        }
    }

    @Test func batchIsAllOrNothing() async throws {
        let a = RecordID("a"), b = RecordID("b")
        _ = try await db.save(Record(type: "T", id: b))
        await #expect(throws: RecordDatabaseError.self) {
            try await db.save([Record(type: "T", id: a), Record(type: "T", id: b)])
        }
        #expect(await db.current(a) == nil)
        #expect(await db.writes.count == 1)
    }

    @Test func queryFiltersByTypeAndFields() async throws {
        _ = try await db.save([
            Record(type: "T", id: RecordID("1"), fields: ["d": .string("x"), "n": .int(1)]),
            Record(type: "T", id: RecordID("2"), fields: ["d": .string("x"), "n": .int(2)]),
            Record(type: "T", id: RecordID("3"), fields: ["d": .string("y"), "n": .int(3)]),
            Record(type: "U", id: RecordID("4"), fields: ["d": .string("x"), "n": .int(4)]),
        ])
        let all = try await db.query(RecordQuery(type: "T"))
        #expect(all.map(\.id.name) == ["1", "2", "3"])
        let some = try await db.query(RecordQuery(type: "T", filters: [
            .init("d", .equals, .string("x")), .init("n", .greaterThan, .int(1)),
        ]))
        #expect(some.map(\.id.name) == ["2"])
    }
}

private extension Record {
    func with(v: Int64) -> Record {
        var copy = self
        copy.fields["v"] = .int(v)
        return copy
    }
}
