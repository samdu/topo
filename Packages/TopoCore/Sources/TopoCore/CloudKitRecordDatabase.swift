#if canImport(CloudKit)
@preconcurrency import CloudKit
import Foundation

/// `RecordDatabase` over a `CKDatabase` and one record zone.
///
/// Compare-and-set rides CloudKit's own `ifServerRecordUnchanged` policy: a
/// tagged record is saved through a copy of the `CKRecord` it was fetched
/// as, whose change tag CloudKit checks, and an untagged one is a fresh
/// `CKRecord` that CloudKit refuses if the ID exists. `CKRecord`s from
/// `fetch` and from saves are kept so a later save can find the one to
/// write through; query results are not kept, since nothing saves over
/// them. A record whose tag is not on hand is fetched again and checked
/// before the save.
///
/// The zone must exist, and it must be a custom zone: the default zone has
/// no atomic batches. Every field that appears in a query filter needs a
/// queryable index in the CloudKit schema; the whole of a type is read from
/// the zone's change feed, which needs none.
public final class CloudKitRecordDatabase: RecordDatabase, @unchecked Sendable {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let lock = NSLock()
    private var fetched: [RecordID: CKRecord] = [:]

    public init(database: CKDatabase, zoneID: CKRecordZone.ID) {
        self.database = database
        self.zoneID = zoneID
    }

    public func save(_ records: [Record]) async throws -> [Record] {
        var ckRecords: [CKRecord] = []
        for record in records {
            ckRecords.append(try await ckRecord(for: record))
        }
        let result: (saveResults: [CKRecord.ID: Result<CKRecord, any Error>], deleteResults: [CKRecord.ID: Result<Void, any Error>])
        do {
            result = try await database.modifyRecords(saving: ckRecords, deleting: [],
                                                      savePolicy: .ifServerRecordUnchanged, atomically: true)
        } catch {
            throw Self.mapped(error, recordIDs: ckRecords.map(\.recordID))
        }
        var saved: [Record] = []
        for ck in ckRecords {
            switch result.saveResults[ck.recordID] {
            case .success(let s)?:
                remember(s)
                saved.append(Self.record(from: s))
            case .failure(let e)?:
                throw Self.mapped(e, recordIDs: [ck.recordID])
            case nil:
                throw RecordDatabaseError.unavailable(underlying: CKError(.internalError))
            }
        }
        return saved
    }

    public func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        let ckIDs = ids.map { CKRecord.ID(recordName: $0.name, zoneID: zoneID) }
        let results: [CKRecord.ID: Result<CKRecord, any Error>]
        do {
            results = try await database.records(for: ckIDs)
        } catch {
            throw Self.mapped(error, recordIDs: ckIDs)
        }
        var out: [RecordID: Record] = [:]
        for (id, result) in results {
            switch result {
            case .success(let ck):
                remember(ck)
                out[RecordID(id.recordName)] = Self.record(from: ck)
            case .failure(let e):
                if let ck = e as? CKError, ck.code == .unknownItem { continue }
                throw Self.mapped(e, recordIDs: [id])
            }
        }
        return out
    }

    public func query(_ query: RecordQuery) async throws -> [Record] {
        let ckQuery = CKQuery(recordType: query.type, predicate: Self.predicate(for: query))
        var out: [Record] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let page: (matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)], queryCursor: CKQueryOperation.Cursor?)
            do {
                if let cursor {
                    page = try await database.records(continuingMatchFrom: cursor)
                } else {
                    page = try await database.records(matching: ckQuery, inZoneWith: zoneID)
                }
            } catch {
                throw Self.mapped(error, recordIDs: [])
            }
            for (id, result) in page.matchResults {
                switch result {
                case .success(let ck):
                    out.append(Self.record(from: ck))
                case .failure(let e):
                    throw Self.mapped(e, recordIDs: [id])
                }
            }
            cursor = page.queryCursor
        } while cursor != nil
        return out
    }

    /// The zone's change feed from the beginning, kept to the one type. A
    /// match-all query would do the same only with a queryable index on the
    /// record name, which the development schema never builds.
    public func records(ofType type: String) async throws -> [Record] {
        var out: [Record] = []
        var token: CKServerChangeToken?
        var more = true
        while more {
            let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                       deletions: [CKDatabase.RecordZoneChange.Deletion],
                       changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                page = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)
            } catch {
                throw Self.mapped(error, recordIDs: [])
            }
            for (id, result) in page.modificationResultsByID {
                switch result {
                case .success(let change):
                    if change.record.recordType == type { out.append(Self.record(from: change.record)) }
                case .failure(let e):
                    throw Self.mapped(e, recordIDs: [id])
                }
            }
            token = page.changeToken
            more = page.moreComing
        }
        return out
    }

    // MARK: - Mapping

    private func ckRecord(for record: Record) async throws -> CKRecord {
        let ckID = CKRecord.ID(recordName: record.id.name, zoneID: zoneID)
        let base: CKRecord
        if let tag = record.changeTag {
            if let cached = cachedRecord(record.id), cached.recordChangeTag == tag {
                base = cached
            } else {
                let results = try await database.records(for: [ckID])
                switch results[ckID] {
                case .success(let server)?:
                    guard server.recordChangeTag == tag else {
                        throw RecordDatabaseError.serverRecordChanged(record.id, server: Self.record(from: server))
                    }
                    base = server
                case .failure(let e)?:
                    throw Self.mapped(e, recordIDs: [ckID])
                case nil:
                    throw RecordDatabaseError.unknownItem(record.id)
                }
            }
        } else {
            base = CKRecord(recordType: record.type, recordID: ckID)
        }
        return Self.applying(record.fields, to: base)
    }

    /// A copy of `base` carrying exactly `fields` among the field kinds this
    /// package maps. Fields of other kinds are left as they are, so a newer
    /// version's data survives an older version's heartbeat. The copy keeps
    /// the change tag, and the cached original is never written to.
    static func applying(_ fields: [String: FieldValue], to base: CKRecord) -> CKRecord {
        let copy = base.copy() as! CKRecord
        for key in copy.allKeys() where fields[key] == nil && fieldValue(copy[key]) != nil {
            copy[key] = nil
        }
        for (key, value) in fields {
            copy[key] = ckValue(value)
        }
        return copy
    }

    private func remember(_ ck: CKRecord) {
        lock.withLock { fetched[RecordID(ck.recordID.recordName)] = ck }
    }

    private func cachedRecord(_ id: RecordID) -> CKRecord? {
        lock.withLock { fetched[id] }
    }

    static func predicate(for query: RecordQuery) -> NSPredicate {
        if query.filters.isEmpty { return NSPredicate(value: true) }
        return NSCompoundPredicate(andPredicateWithSubpredicates: query.filters.map { f in
            let op = f.op == .equals ? "==" : ">"
            return NSPredicate(format: "%K \(op) %@", f.field, ckValue(f.value) as! NSObject)
        })
    }

    static func record(from ck: CKRecord) -> Record {
        var fields: [String: FieldValue] = [:]
        for key in ck.allKeys() {
            if let value = fieldValue(ck[key]) { fields[key] = value }
        }
        return Record(type: ck.recordType, id: RecordID(ck.recordID.recordName),
                      fields: fields, changeTag: ck.recordChangeTag)
    }

    static func fieldValue(_ value: (any CKRecordValue)?) -> FieldValue? {
        switch value {
        case let s as String: return .string(s)
        case let d as Date: return .date(d)
        case let n as NSNumber: return .int(n.int64Value)
        case let a as [String]: return .strings(a)
        default: return nil
        }
    }

    static func ckValue(_ value: FieldValue) -> any CKRecordValue {
        switch value {
        case .string(let s): return s as NSString
        case .int(let i): return NSNumber(value: i)
        case .date(let d): return d as NSDate
        case .strings(let a): return a as NSArray
        }
    }

    /// CloudKit errors that will not clear on their own.
    static let permanentCodes: Set<CKError.Code> = [
        .notAuthenticated, .permissionFailure, .badContainer, .badDatabase, .missingEntitlement,
        .zoneNotFound, .userDeletedZone, .quotaExceeded, .invalidArguments, .incompatibleVersion,
        .constraintViolation, .limitExceeded, .managedAccountRestricted, .participantMayNeedVerification,
    ]

    static func mapped(_ error: any Error, recordIDs: [CKRecord.ID]) -> any Error {
        guard let ck = error as? CKError else { return RecordDatabaseError.unavailable(underlying: error) }
        switch ck.code {
        case .serverRecordChanged:
            if let server = ck.serverRecord {
                return RecordDatabaseError.serverRecordChanged(RecordID(server.recordID.recordName),
                                                               server: record(from: server))
            }
            return RecordDatabaseError.unavailable(underlying: error)
        case .unknownItem:
            return RecordDatabaseError.unknownItem(RecordID(recordIDs.first?.recordName ?? ""))
        case .partialFailure:
            for (_, sub) in ck.partialErrorsByItemID ?? [:] {
                let m = mapped(sub, recordIDs: recordIDs)
                if case RecordDatabaseError.unavailable = m { continue }
                return m
            }
            return RecordDatabaseError.unavailable(underlying: error)
        case let code where permanentCodes.contains(code):
            return RecordDatabaseError.rejected(underlying: error)
        default:
            return RecordDatabaseError.unavailable(underlying: error)
        }
    }
}
#endif
