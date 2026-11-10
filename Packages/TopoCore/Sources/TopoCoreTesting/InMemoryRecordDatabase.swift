import Foundation
import TopoCore

/// An in-memory `RecordDatabase` with CloudKit's save semantics: every save
/// is compare-and-set on the change tag, a batch applies all or nothing, and
/// each successful save mints a new tag. Tests and previews use it; nothing
/// here talks to iCloud.
///
/// It is more forgiving than CloudKit where the difference needs a real
/// container to model:
/// - its query index is strongly consistent, where the server's lags and a
///   newest record leaves no gap behind it (`StaleTailDatabase` and
///   `BlindQueryDatabase` in TopoCore's tests model the lag where it matters);
/// - an empty filter list matches every record of the type, where the server
///   refuses a match-all predicate without a queryable record-name index, so
///   nothing here may rely on one;
/// - it refuses no record or batch for its size, a duplicate ID in a batch or
///   a record of another type under one ID;
/// - the adapter's walk of an atomic batch's per-record results and a query's
///   pagination (`CloudKitRecordDatabase`) are reached by no suite.
/// A test passing here proves nothing about those. A type nothing has saved
/// answers `[]` and an empty list is saved as no field, as the adapter makes
/// CloudKit's answers, and a tag from another store is never honoured.
///
/// `beforeSave` runs inside `save` before the tags are checked. Because the
/// actor suspends at that await, a test can hold one writer there while
/// another fetches and saves, which is how the lease race is reproduced.
public actor InMemoryRecordDatabase: ZoneDatabase {
    /// The semantics, shared with the store a phone with no iCloud account runs on
    /// (`LocalRecordDatabase`), so the two cannot drift apart.
    private var core = RecordStoreCore(store: "tag-\(UUID().uuidString)")
    private var beforeSave: (@Sendable ([Record]) async -> Void)?

    /// Every record ever saved, in save order. A record ID appearing twice
    /// here means a record was overwritten.
    public private(set) var writes: [Record] = []

    public init() {}

    public func setBeforeSave(_ hook: (@Sendable ([Record]) async -> Void)?) {
        beforeSave = hook
    }

    /// The record the store holds now, or nil.
    public func current(_ id: RecordID) -> Record? { core.records[id] }

    public func save(_ records: [Record]) async throws -> [Record] {
        await beforeSave?(records)
        let applied = try core.prepareSave(records)
        core.apply(applied)
        guard case .saved(let saved) = applied else { return [] }
        writes.append(contentsOf: saved)
        return saved
    }

    public func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { core.fetch(ids) }

    public func query(_ query: RecordQuery) async throws -> [Record] { core.query(query) }

    public func records(ofType type: String) async throws -> [Record] { core.records(ofType: type) }

    public func delete(_ ids: [RecordID]) async throws { core.apply(core.prepareDelete(ids)) }

    /// Every token handed out so far stops being answered, as CloudKit's expire.
    public func expireChangeTokens() { core.expireTokens() }

    public func changes(ofType type: String, since token: Data?) async throws -> RecordChanges {
        try core.changes(ofType: type, since: token)
    }
}
