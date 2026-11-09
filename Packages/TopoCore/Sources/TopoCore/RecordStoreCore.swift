import Foundation

/// The semantics a local record store keeps, CloudKit's as far as the package relies on them:
/// every save is compare-and-set on the change tag, a batch applies all or nothing, a nil tag
/// is create-only, each save mints a new tag, and the change feed is read from tokens that
/// expire. `InMemoryRecordDatabase` and `LocalRecordDatabase` are both this, the second with a
/// journal behind it, so the store a test holds and the store a phone with no iCloud account
/// runs on cannot drift apart.
///
/// A store's tags and tokens carry its `store` id, so a tag or a token from a store with another
/// id is never honoured: a tag is a stale save, a token an expired one. Each journal and each
/// `InMemoryRecordDatabase` has an id of its own.
///
/// An empty string or asset list is saved as no field, as the CloudKit adapter leaves it off the
/// wire and the server answers it absent.
package struct RecordStoreCore: Sendable {
    /// What one mutation did, as it is replayed: the records as saved (their new tags on them),
    /// or the records deleted with their types.
    package enum Applied: Codable, Sendable, Equatable {
        case saved([Record])
        case deleted([DeletedRecord])
    }

    package struct DeletedRecord: Codable, Sendable, Equatable {
        package var id: RecordID
        package var type: String
    }

    package let store: String
    package private(set) var records: [RecordID: Record] = [:]
    /// The tag counter: the next save's tag is one past it.
    package private(set) var minted: Int64 = 0
    /// The feed's epoch: a token from an earlier one has expired, as CloudKit's do.
    package private(set) var epoch: Int64 = 0
    /// The change feed since the epoch began: one entry per record saved or deleted, in order.
    private var feed: [(id: RecordID, type: String)] = []

    package init(store: String) { self.store = store }

    /// The core as a compaction left it: these records, the tag counter and the epoch, with a
    /// feed that lists each record once, so a read from no token sees all of them.
    package init(store: String, records: [Record], minted: Int64, epoch: Int64) {
        self.store = store
        self.minted = minted
        self.epoch = epoch
        for record in records.sorted(by: { $0.id.name < $1.id.name }) {
            self.records[record.id] = record
            feed.append((record.id, record.type))
        }
    }

    /// The outcome a save would have, without applying it: the records with their new tags, or
    /// the refusal CloudKit would give.
    package func prepareSave(_ batch: [Record]) throws -> Applied {
        for record in batch {
            switch (record.changeTag, records[record.id]) {
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
        var next = minted
        return .saved(batch.map { record in
            next += 1
            var saved = record
            saved.changeTag = "\(store)-\(next)"
            saved.fields = saved.fields.filter { _, value in
                switch value {
                case .strings(let list): !list.isEmpty
                case .assets(let list): !list.isEmpty
                default: true
                }
            }
            return saved
        })
    }

    /// The outcome a delete would have: the records that exist among those named.
    package func prepareDelete(_ ids: [RecordID]) -> Applied {
        var seen: Set<RecordID> = []
        return .deleted(ids.compactMap { id in
            guard seen.insert(id).inserted, let gone = records[id] else { return nil }
            return DeletedRecord(id: id, type: gone.type)
        })
    }

    /// Applies an outcome `prepareSave` or `prepareDelete` gave, or one replayed from a journal.
    package mutating func apply(_ applied: Applied) {
        switch applied {
        case .saved(let saved):
            for record in saved {
                records[record.id] = record
                feed.append((record.id, record.type))
                if let tag = record.changeTag, let n = Self.counter(of: tag, store: store) { minted = max(minted, n) }
            }
        case .deleted(let gone):
            for entry in gone where records.removeValue(forKey: entry.id) != nil {
                feed.append((entry.id, entry.type))
            }
        }
    }

    private static func counter(of tag: String, store: String) -> Int64? {
        guard tag.hasPrefix(store + "-") else { return nil }
        return Int64(tag.dropFirst(store.count + 1))
    }

    /// Every token handed out so far stops being answered.
    package mutating func expireTokens() {
        epoch += 1
        feed = records.values.sorted { $0.id.name < $1.id.name }.map { ($0.id, $0.type) }
    }

    package func fetch(_ ids: [RecordID]) -> [RecordID: Record] {
        var out: [RecordID: Record] = [:]
        for id in ids { if let r = records[id] { out[id] = r } }
        return out
    }

    package func query(_ query: RecordQuery) -> [Record] {
        records.values
            .filter { record in record.type == query.type && query.filters.allSatisfy { Self.matches(record, $0) } }
            .sorted { $0.id.name < $1.id.name }
    }

    package func records(ofType type: String) -> [Record] {
        records.values.filter { $0.type == type }.sorted { $0.id.name < $1.id.name }
    }

    package func changes(ofType type: String, since token: Data?) throws -> RecordChanges {
        var start = 0
        if let token {
            let parts = String(decoding: token, as: UTF8.self).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == Substring(store), Int64(parts[1]) == epoch,
                  let at = Int(parts[2]), at >= 0, at <= feed.count else { throw RecordChangesError.tokenExpired }
            start = at
        }
        var seen: Set<RecordID> = []
        var changed: [Record] = []
        var deleted: [RecordID] = []
        // Each record once, as the store holds it now: the feed says what moved, not how often.
        for entry in feed[start...].reversed() where entry.type == type && seen.insert(entry.id).inserted {
            // From no token the feed is what exists, as CloudKit's is: a record gone before it is
            // not reported, so a reader has to ask for what it cached by name.
            if let record = records[entry.id], record.type == type { changed.append(record) } else if token != nil { deleted.append(entry.id) }
        }
        return RecordChanges(changed: changed.reversed(), deleted: deleted.reversed(),
                             token: Data("\(store):\(epoch):\(feed.count)".utf8))
    }

    private static func matches(_ record: Record, _ filter: RecordQuery.Filter) -> Bool {
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
