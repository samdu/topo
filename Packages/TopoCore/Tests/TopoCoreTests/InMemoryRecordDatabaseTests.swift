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

    @Test func recordsOfATypeAreEveryRecordOfItWhateverTheirFields() async throws {
        _ = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(1)]))
        _ = try await db.save(Record(type: "T", id: RecordID("junk")))
        _ = try await db.save(Record(type: "U", id: RecordID("b"), fields: ["v": .int(1)]))
        let all = try await db.records(ofType: "T")
        #expect(all.map(\.id.name) == ["a", "junk"])
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

    // MARK: The change feed and deletes, as CloudKit's

    @Test func theFeedFromATokenCarriesOnlyWhatMovedSince() async throws {
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        _ = try await db.save(Record(type: "U", id: RecordID("u")))
        let first = try await db.changes(ofType: "T", since: nil)
        #expect(first.changed.map(\.id.name) == ["a"])
        #expect(first.deleted.isEmpty)
        let b = try await db.save(Record(type: "T", id: RecordID("b"), fields: ["v": .int(1)]))
        _ = try await db.save(b.with(v: 2))
        try await db.delete([RecordID("a")])
        let second = try await db.changes(ofType: "T", since: first.token)
        #expect(second.changed.map(\.id.name) == ["b"], "a record saved twice is listed once, as it is now")
        #expect(second.changed.first?.int("v") == 2)
        #expect(second.deleted == [RecordID("a")])
        let third = try await db.changes(ofType: "T", since: second.token)
        #expect(third.changed.isEmpty && third.deleted.isEmpty)
    }

    @Test func anExpiredTokenIsRefusedAsCloudKitRefusesIt() async throws {
        let token = try await db.changes(ofType: "T", since: nil).token
        await db.expireChangeTokens()
        await #expect(throws: RecordChangesError.self) { try await db.changes(ofType: "T", since: token) }
        _ = try await db.changes(ofType: "T", since: nil)
    }

    /// From no token the feed lists what exists and no deletion, as CloudKit's does, so a reader
    /// that cached a record deleted since cannot learn of it from the feed alone.
    @Test func theFeedFromNoTokenReportsNoDeletion() async throws {
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        _ = try await db.save(Record(type: "T", id: RecordID("b")))
        try await db.delete([RecordID("a")])
        let all = try await db.changes(ofType: "T", since: nil)
        #expect(all.changed.map(\.id.name) == ["b"])
        #expect(all.deleted.isEmpty)
    }

    @Test func deletingWhatIsGoneIsNotAnError() async throws {
        try await db.delete([RecordID("never")])
        let saved = try await db.save(Record(type: "T", id: RecordID("r")))
        try await db.delete([saved.id])
        #expect(await db.current(saved.id) == nil)
        // A tag from before the delete no longer names anything, as on the server.
        await #expect(throws: RecordDatabaseError.self) { try await db.save(saved) }
    }
}

private extension Record {
    func with(v: Int64) -> Record {
        var copy = self
        copy.fields["v"] = .int(v)
        return copy
    }
}
