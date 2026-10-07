import Foundation

/// A query over one record type. Filters are ANDed. An empty filter list
/// matches every record of the type.
public struct RecordQuery: Hashable, Sendable {
    public enum Operator: Hashable, Sendable {
        case equals
        case greaterThan
    }

    public struct Filter: Hashable, Sendable {
        public var field: String
        public var op: Operator
        public var value: FieldValue
        public init(_ field: String, _ op: Operator, _ value: FieldValue) {
            self.field = field
            self.op = op
            self.value = value
        }
    }

    public var type: String
    public var filters: [Filter]

    public init(type: String, filters: [Filter] = []) {
        self.type = type
        self.filters = filters
    }
}

public enum RecordDatabaseError: Error, Sendable {
    /// The save was rejected because the server holds a different version:
    /// the record exists and the saved copy had no tag, or its tag is stale.
    /// `server` is the version the server holds now.
    case serverRecordChanged(RecordID, server: Record)
    /// A tagged record was saved but no longer exists on the server.
    case unknownItem(RecordID)
    /// The store could not be reached. Retry later; nothing was applied.
    case unavailable(underlying: any Error)
    /// The store refused the request and will keep refusing it: not signed
    /// in, no permission, no such zone, over quota, a bad argument. Nothing
    /// was applied, and retrying will not help until something changes.
    case rejected(underlying: any Error)
}

/// The subset of CloudKit the package uses, over the private database.
///
/// Every save is compare-and-set, all or nothing: a record whose `changeTag`
/// is nil is created only if nothing exists under its ID, and a tagged record
/// is written only if the server still holds that tag. A batch that fails on
/// any record applies none. There is no unconditional write, because nothing
/// in the package ever overwrites: the turn log only creates, and the lease
/// only moves from the version it last read.
public protocol RecordDatabase: Sendable {
    /// Saves every record or none. Returns the saved records with their new tags.
    func save(_ records: [Record]) async throws -> [Record]
    /// Fetches by ID. IDs with no record are absent from the result.
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record]
    /// Every record of the query's type matching all its filters. Needs a
    /// queryable index on every filtered field.
    func query(_ query: RecordQuery) async throws -> [Record]
    /// Every record of the type in the zone, read from the zone's change
    /// feed rather than a query: it needs no index, so it works on a schema
    /// nobody has touched, and it sees every record however malformed, so a
    /// reader can report what it cannot parse.
    func records(ofType type: String) async throws -> [Record]
    /// This database with every save and fetch by ID bounded: one not answered within
    /// `seconds` throws `unavailable`, though it may still be applied. For a caller that
    /// holds something up while it waits, as the lease does. A store with no slow link to
    /// bound is its own answer, which is the default.
    func answering(within seconds: TimeInterval) -> any RecordDatabase
}

extension RecordDatabase {
    public func answering(within seconds: TimeInterval) -> any RecordDatabase { self }

    /// Saves one record; see `save(_:)`.
    public func save(_ record: Record) async throws -> Record {
        try await save([record])[0]
    }

    /// Fetches one record, or nil if it does not exist.
    public func fetch(_ id: RecordID) async throws -> Record? {
        try await fetch([id])[id]
    }
}

/// What changed in one record type of the zone since a token: the records saved and the IDs
/// deleted, each as the store has it now, and the token to ask from next time.
public struct RecordChanges: Sendable {
    public var changed: [Record]
    public var deleted: [RecordID]
    /// Opaque; handed back to `changes(ofType:since:)`.
    public var token: Data

    public init(changed: [Record], deleted: [RecordID], token: Data) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
    }
}

public enum RecordChangesError: Error, Sendable {
    /// The store no longer answers from that token: read again from the start (nil), and
    /// confirm anything a reader held that the fresh read does not mention by fetching it.
    case tokenExpired
}

/// A `RecordDatabase` that can also delete, and say what changed since it was last asked: the
/// zone's change feed read from a token. For records one device owns and replaces — a widget's
/// document — where the log's append-only types never delete.
public protocol ZoneDatabase: RecordDatabase {
    /// Deletes every record named. A record already gone is not an error: what is asked is that
    /// none of them be there.
    func delete(_ ids: [RecordID]) async throws
    /// The zone's changes to `type` since `token`, or every record of it with nil. Needs no index.
    func changes(ofType type: String, since token: Data?) async throws -> RecordChanges
}
