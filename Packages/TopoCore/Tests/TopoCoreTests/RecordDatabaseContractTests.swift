import Foundation
import Testing
import TopoCore
import TopoCoreTesting

/// The semantics every local record store keeps, run over the in-memory store the tests hold
/// and the journalled one a phone with no iCloud account runs on (`RecordDatabaseContract`).
enum ContractStore: String, CaseIterable, CustomTestStringConvertible {
    case memory, disk
    var testDescription: String { rawValue }
}

/// A store under the contract, with the one read the contract needs beyond the protocol.
struct ContractDB: Sendable {
    let base: any ZoneDatabase
    let peek: @Sendable (RecordID) async -> Record?

    init(_ kind: ContractStore) throws {
        switch kind {
        case .memory:
            let db = InMemoryRecordDatabase()
            base = db
            peek = { await db.current($0) }
        case .disk:
            let db = try LocalRecordDatabase(file: FileManager.default.temporaryDirectory
                .appending(path: "contract-\(UUID().uuidString)/records.journal"))
            base = db
            peek = { await db.current($0) }
        }
    }

    func current(_ id: RecordID) async -> Record? { await peek(id) }
    func save(_ r: Record) async throws -> Record { try await base.save(r) }
    func save(_ r: [Record]) async throws -> [Record] { try await base.save(r) }
    func query(_ q: RecordQuery) async throws -> [Record] { try await base.query(q) }
    func records(ofType t: String) async throws -> [Record] { try await base.records(ofType: t) }
    func delete(_ ids: [RecordID]) async throws { try await base.delete(ids) }
    func changes(ofType t: String, since token: Data?) async throws -> RecordChanges { try await base.changes(ofType: t, since: token) }
}

@Suite struct RecordDatabaseContract {

    @Test(arguments: ContractStore.allCases) func createIsCreateOnly(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
        let id = RecordID("r")
        let saved = try await db.save(Record(type: "T", id: id, fields: ["v": .int(1)]))
        #expect(saved.changeTag != nil)
        await #expect(throws: RecordDatabaseError.self) {
            try await db.save(Record(type: "T", id: id, fields: ["v": .int(2)]))
        }
        #expect(await db.current(id)?.int("v") == 1)
    }

    @Test(arguments: ContractStore.allCases) func compareAndSetNeedsTheCurrentTag(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
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

    @Test(arguments: ContractStore.allCases) func recordsOfATypeAreEveryRecordOfItWhateverTheirFields(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
        _ = try await db.save(Record(type: "T", id: RecordID("a"), fields: ["v": .int(1)]))
        _ = try await db.save(Record(type: "T", id: RecordID("junk")))
        _ = try await db.save(Record(type: "U", id: RecordID("b"), fields: ["v": .int(1)]))
        let all = try await db.records(ofType: "T")
        #expect(all.map(\.id.name) == ["a", "junk"])
    }

    @Test(arguments: ContractStore.allCases) func taggedSaveOfMissingRecordIsUnknownItem(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
        await #expect(throws: RecordDatabaseError.self) {
            try await db.save(Record(type: "T", id: RecordID("gone"), changeTag: "x"))
        }
    }

    @Test(arguments: ContractStore.allCases) func batchIsAllOrNothing(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
        let a = RecordID("a"), b = RecordID("b")
        let stored = try await db.save(Record(type: "T", id: b))
        await #expect(throws: RecordDatabaseError.self) {
            try await db.save([Record(type: "T", id: a), Record(type: "T", id: b)])
        }
        #expect(await db.current(a) == nil)
        #expect(await db.current(b)?.changeTag == stored.changeTag, "the record the batch failed on is untouched")
    }

    @Test(arguments: ContractStore.allCases) func queryFiltersByTypeAndFields(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
        _ = try await db.save([
            Record(type: "T", id: RecordID("1"), fields: ["d": .string("x"), "n": .int(1)]),
            Record(type: "T", id: RecordID("2"), fields: ["d": .string("x"), "n": .int(2)]),
            Record(type: "T", id: RecordID("3"), fields: ["d": .string("y"), "n": .int(3)]),
            Record(type: "U", id: RecordID("4"), fields: ["d": .string("x"), "n": .int(4)]),
        ])
        let some = try await db.query(RecordQuery(type: "T", filters: [
            .init("d", .equals, .string("x")), .init("n", .greaterThan, .int(1)),
        ]))
        #expect(some.map(\.id.name) == ["2"])
    }

    /// An empty list carries no element type, so the adapter leaves it off the wire and CloudKit
    /// answers the field absent; a store here does the same, so no reader is tested against an
    /// empty list it will never be handed.
    @Test(arguments: ContractStore.allCases) func anEmptyListIsSavedAsNoField(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
        let saved = try await db.save(Record(type: "T", id: RecordID("a"), fields: [
            "names": .strings([]), "files": .assets([]), "kept": .strings(["x"]),
        ]))
        #expect(saved.fields == ["kept": .strings(["x"])])
        #expect(await db.current(RecordID("a"))?.fields == ["kept": .strings(["x"])])
    }

    /// A change tag or a token is one store's: another store of the same kind never honours it.
    @Test(arguments: ContractStore.allCases) func aTagOrATokenFromAnotherStoreIsNotHonoured(_ kind: ContractStore) async throws {
        let mine = try ContractDB(kind)
        let other = try ContractDB(kind)
        let theirs = try await other.save(Record(type: "T", id: RecordID("a")))
        _ = try await mine.save(Record(type: "T", id: RecordID("a")))
        await #expect(throws: RecordDatabaseError.self) { try await mine.save(theirs) }
        let token = try await other.changes(ofType: "T", since: nil).token
        await #expect(throws: RecordChangesError.self) { try await mine.changes(ofType: "T", since: token) }
    }

    // MARK: The change feed and deletes, as CloudKit's

    @Test(arguments: ContractStore.allCases) func theFeedFromATokenCarriesOnlyWhatMovedSince(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
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
        let db = InMemoryRecordDatabase()
        let token = try await db.changes(ofType: "T", since: nil).token
        await db.expireChangeTokens()
        await #expect(throws: RecordChangesError.self) { try await db.changes(ofType: "T", since: token) }
        _ = try await db.changes(ofType: "T", since: nil)
    }

    /// From no token the feed lists what exists and no deletion, as CloudKit's does, so a reader
    /// that cached a record deleted since cannot learn of it from the feed alone.
    @Test(arguments: ContractStore.allCases) func theFeedFromNoTokenReportsNoDeletion(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
        _ = try await db.save(Record(type: "T", id: RecordID("a")))
        _ = try await db.save(Record(type: "T", id: RecordID("b")))
        try await db.delete([RecordID("a")])
        let all = try await db.changes(ofType: "T", since: nil)
        #expect(all.changed.map(\.id.name) == ["b"])
        #expect(all.deleted.isEmpty)
    }

    @Test(arguments: ContractStore.allCases) func deletingWhatIsGoneIsNotAnError(_ kind: ContractStore) async throws {
        let db = try ContractDB(kind)
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
