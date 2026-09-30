import Foundation
import TopoCore

/// An in-memory `RecordDatabase` with CloudKit's save semantics: every save
/// is compare-and-set on the change tag, a batch applies all or nothing, and
/// each successful save mints a new tag. Tests and previews use it; nothing
/// here talks to iCloud.
///
/// It is more forgiving than CloudKit in four ways, each of which has shipped
/// a bug: its query index is strongly consistent, where the server's lags and
/// a newest record leaves no gap behind it; an empty filter list matches every
/// record of the type, where the server refuses a match-all predicate without
/// a queryable record-name index; a type nothing has saved answers `[]`, where
/// the server answers `unknownItem`; and an empty string list saves, where the
/// server refuses the whole batch with "Syntax error in request". A test
/// passing here proves nothing about those four, which are exercised against a
/// real container or not at all.
///
/// `beforeSave` runs inside `save` before the tags are checked. Because the
/// actor suspends at that await, a test can hold one writer there while
/// another fetches and saves, which is how the lease race is reproduced.
public actor InMemoryRecordDatabase: ZoneDatabase {
    private var store: [RecordID: Record] = [:]
    private var tagCounter = 0
    private var beforeSave: (@Sendable ([Record]) async -> Void)?
    /// The change feed: one entry per save or delete, in order, which `changes(ofType:since:)`
    /// reads from a token (the entry count when it was handed out, and the epoch it was handed
    /// out in). A token from an earlier epoch has expired, as CloudKit's do.
    private var feed: [(id: RecordID, type: String)] = []
    private var feedEpoch = 0

    /// Every record ever saved, in save order. A record ID appearing twice
    /// here means a record was overwritten.
    public private(set) var writes: [Record] = []

    public init() {}

    public func setBeforeSave(_ hook: (@Sendable ([Record]) async -> Void)?) {
        beforeSave = hook
    }

    /// The record the store holds now, or nil.
    public func current(_ id: RecordID) -> Record? { store[id] }

    public func save(_ records: [Record]) async throws -> [Record] {
        await beforeSave?(records)
        for record in records {
            switch (record.changeTag, store[record.id]) {
            case (nil, let existing?):
                throw RecordDatabaseError.serverRecordChanged(record.id, server: existing)
            case (let tag?, let existing?) where existing.changeTag != tag:
                throw RecordDatabaseError.serverRecordChanged(record.id, server: existing)
            case (.some, nil):
                throw RecordDatabaseError.unknownItem(record.id)
            default:
                break
            }
        }
        var saved: [Record] = []
        for var record in records {
            tagCounter += 1
            record.changeTag = "tag-\(tagCounter)"
            store[record.id] = record
            writes.append(record)
            feed.append((record.id, record.type))
            saved.append(record)
        }
        return saved
    }

    public func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        var out: [RecordID: Record] = [:]
        for id in ids {
            if let r = store[id] { out[id] = r }
        }
        return out
    }

    public func query(_ query: RecordQuery) async throws -> [Record] {
        store.values
            .filter { record in record.type == query.type && query.filters.allSatisfy { matches(record, $0) } }
            .sorted { $0.id.name < $1.id.name }
    }

    public func records(ofType type: String) async throws -> [Record] {
        store.values.filter { $0.type == type }.sorted { $0.id.name < $1.id.name }
    }

    public func delete(_ ids: [RecordID]) async throws {
        for id in ids {
            guard let gone = store.removeValue(forKey: id) else { continue }
            feed.append((id, gone.type))
        }
    }

    /// Every token handed out so far stops being answered, as CloudKit's expire.
    public func expireChangeTokens() { feedEpoch += 1 }

    public func changes(ofType type: String, since token: Data?) async throws -> RecordChanges {
        var start = 0
        if let token {
            let parts = String(decoding: token, as: UTF8.self).split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, parts[0] == feedEpoch, parts[1] <= feed.count else { throw RecordChangesError.tokenExpired }
            start = parts[1]
        }
        var seen: Set<RecordID> = []
        var changed: [Record] = []
        var deleted: [RecordID] = []
        // Each record once, as the store holds it now: the feed says what moved, not how often.
        for entry in feed[start...].reversed() where entry.type == type && seen.insert(entry.id).inserted {
            if let record = store[entry.id], record.type == type { changed.append(record) } else { deleted.append(entry.id) }
        }
        return RecordChanges(changed: changed.reversed(), deleted: deleted.reversed(), token: Data("\(feedEpoch):\(feed.count)".utf8))
    }

    private func matches(_ record: Record, _ filter: RecordQuery.Filter) -> Bool {
        guard let value = record.fields[filter.field] else { return false }
        switch (filter.op, value, filter.value) {
        case (.equals, _, _):
            return value == filter.value
        case (.greaterThan, .int(let a), .int(let b)):
            return a > b
        case (.greaterThan, .date(let a), .date(let b)):
            return a > b
        case (.greaterThan, .string(let a), .string(let b)):
            return a > b
        case (.greaterThan, _, _):
            return false
        }
    }
}
