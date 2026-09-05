import Foundation
import TopoCore

/// An in-memory `RecordDatabase` with CloudKit's save semantics: every save
/// is compare-and-set on the change tag, a batch applies all or nothing, and
/// each successful save mints a new tag. Tests and previews use it; nothing
/// here talks to iCloud.
///
/// `beforeSave` runs inside `save` before the tags are checked. Because the
/// actor suspends at that await, a test can hold one writer there while
/// another fetches and saves, which is how the lease race is reproduced.
public actor InMemoryRecordDatabase: RecordDatabase {
    private var store: [RecordID: Record] = [:]
    private var tagCounter = 0
    private var beforeSave: (@Sendable ([Record]) async -> Void)?

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
