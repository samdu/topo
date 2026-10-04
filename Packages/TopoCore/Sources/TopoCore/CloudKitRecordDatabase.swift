#if canImport(CloudKit)
@preconcurrency import CloudKit
import Foundation
import os

/// `RecordDatabase` over a `CKDatabase` and one record zone.
///
/// Compare-and-set rides CloudKit's own `ifServerRecordUnchanged` policy: a
/// tagged record is saved through a copy of the `CKRecord` it was fetched
/// as, whose change tag CloudKit checks, and an untagged one is a fresh
/// `CKRecord` that CloudKit refuses if the ID exists. `CKRecord`s from
/// `fetch` and from saves are kept so a later save can find the one to
/// write through; query and change-feed results are not kept. A record
/// whose tag is not on hand is fetched again and checked before the save,
/// so a save over one of those is a fetch and then the save.
///
/// The zone must exist, and it must be a custom zone: the default zone has
/// no atomic batches. Every field that appears in a query filter needs a
/// queryable index in the CloudKit schema; the whole of a type is read from
/// the zone's change feed, which needs none.
public final class CloudKitRecordDatabase: ZoneDatabase, @unchecked Sendable {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let lock = NSLock()
    private var fetched: [RecordID: CKRecord] = [:]

    /// The container every bundle shares and the zone the records live in.
    public static let containerIdentifier = "iCloud.zone.hexagon.topo"
    public static let zoneName = "Topo"

    public init(database: CKDatabase, zoneID: CKRecordZone.ID) {
        self.database = database
        self.zoneID = zoneID
    }

    /// The private database of the shared container, in the shared zone.
    public convenience init(container: CKContainer = CKContainer(identifier: containerIdentifier)) {
        self.init(database: container.privateCloudDatabase,
                  zoneID: CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName))
    }

    /// Creates the zone if it does not exist. Saving an existing zone is a
    /// no-op on the server, so this is safe to call at every launch.
    public func ensureZone() async throws {
        do {
            _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
        } catch {
            throw Self.mapped(error, recordIDs: [])
        }
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
        // An atomic batch that fails fails every record, and all but the one at fault say only
        // that the batch failed (`batchRequestFailed`): the one at fault is the error, so a
        // caller that retries a conflict on its own record is told of the conflict.
        for ck in ckRecords {
            if case .failure(let e)? = result.saveResults[ck.recordID], (e as? CKError)?.code != .batchRequestFailed {
                throw Self.mapped(e, recordIDs: [ck.recordID])
            }
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
                // A type nothing has ever saved is not in the development schema, and
                // CloudKit answers a query on it with unknownItem rather than nothing.
                // The in-memory database answers the same question with an empty list;
                // so does this one, or a fresh account can never take its first turn.
                if let ck = error as? CKError, ck.code == .unknownItem { return [] }
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

    /// Every record of the type, from the process's mirror of the zone (`ZoneMirror`): the zone's
    /// change feed, walked from the beginning by the first read and from where the last one
    /// stopped by every read after, whichever object over this zone asks. A match-all query
    /// would do the same only with a queryable index on the record name, which the development
    /// schema never builds.
    public func records(ofType type: String) async throws -> [Record] {
        Perf.mark("zone.read.begin \(type)")
        defer { Perf.mark("zone.read.end \(type)") }
        return try await mirror.records(ofType: type)
    }

    /// One mirror per zone for the process, since every reader makes its own database object.
    private static let mirrors = OSAllocatedUnfairLock<[String: ZoneMirror]>(initialState: [:])

    private var mirror: ZoneMirror {
        let key = "\(database.databaseScope.rawValue)/\(zoneID.ownerName)/\(zoneID.zoneName)"
        return Self.mirrors.withLock { mirrors in
            if let mirror = mirrors[key] { return mirror }
            let mirror = ZoneMirror(store: Self.store(named: key)) { [database, zoneID] token in
                try await Self.page(of: database, zoneID: zoneID, since: token)
            }
            mirrors[key] = mirror
            return mirror
        }
    }

    /// Where a zone's copy is kept between launches: the caches directory, which the system may
    /// empty (a launch after that walks the feed), under the iCloud account it was read as. With
    /// no account to name, nothing is kept.
    private static func store(named key: String) -> ZoneMirror.Store? {
        guard let identity = FileManager.default.ubiquityIdentityToken,
              let owner = try? NSKeyedArchiver.archivedData(withRootObject: identity, requiringSecureCoding: true),
              let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return ZoneMirror.Store(file: mirrorDirectory(in: caches).appendingPathComponent(key.replacingOccurrences(of: "/", with: "-") + ".plist"),
                                owner: owner)
    }

    private static func mirrorDirectory(in caches: URL) -> URL { caches.appendingPathComponent("zone-mirror", isDirectory: true) }

    /// Forgets every zone this process has read and removes their copies from disk, whichever
    /// process wrote them: what a sign-out leaves on the device of the log is nothing.
    public static func forgetMirrors() async {
        for mirror in mirrors.withLock({ Array($0.values) }) { await mirror.forget() }
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: mirrorDirectory(in: caches))
        }
    }

    /// One page of the zone's change feed, every type.
    private static func page(of database: CKDatabase, zoneID: CKRecordZone.ID, since token: Data?) async throws -> ZoneFeedPage {
        var server: CKServerChangeToken?
        if let token {
            server = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token)
            guard server != nil else { throw RecordChangesError.tokenExpired }
        }
        let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                   deletions: [CKDatabase.RecordZoneChange.Deletion],
                   changeToken: CKServerChangeToken, moreComing: Bool)
        do {
            page = try await database.recordZoneChanges(inZoneWith: zoneID, since: server)
        } catch {
            if let ck = error as? CKError, ck.code == .changeTokenExpired { throw RecordChangesError.tokenExpired }
            throw mapped(error, recordIDs: [])
        }
        var changed: [Record] = []
        for (id, result) in page.modificationResultsByID {
            switch result {
            case .success(let change): changed.append(record(from: change.record))
            case .failure(let e): throw mapped(e, recordIDs: [id])
            }
        }
        Perf.mark("zone.page records=\(changed.count) deleted=\(page.deletions.count)")
        return ZoneFeedPage(changed: changed, deleted: page.deletions.map { RecordID($0.recordID.recordName) },
                            token: try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true),
                            moreComing: page.moreComing)
    }

    public func delete(_ ids: [RecordID]) async throws {
        guard !ids.isEmpty else { return }
        let ckIDs = ids.map { CKRecord.ID(recordName: $0.name, zoneID: zoneID) }
        let result: [CKRecord.ID: Result<Void, any Error>]
        do {
            result = try await database.modifyRecords(saving: [], deleting: ckIDs, savePolicy: .ifServerRecordUnchanged,
                                                      atomically: true).deleteResults
        } catch {
            // A record already gone is what was asked for.
            if let ck = error as? CKError, ck.code == .unknownItem { return }
            throw Self.mapped(error, recordIDs: ckIDs)
        }
        for (id, outcome) in result {
            if case .failure(let e) = outcome {
                if let ck = e as? CKError, ck.code == .unknownItem { continue }
                throw Self.mapped(e, recordIDs: [id])
            }
        }
        lock.withLock { for id in ids { fetched[id] = nil } }
    }

    /// The zone's change feed from `token`, kept to the one type. A deletion names its type, so
    /// one of another type is not reported.
    public func changes(ofType type: String, since token: Data?) async throws -> RecordChanges {
        var server: CKServerChangeToken?
        if let token {
            server = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: token)
            guard server != nil else { throw RecordChangesError.tokenExpired }
        }
        var changed: [RecordID: Record] = [:]
        var deleted: Set<RecordID> = []
        var more = true
        while more {
            let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                       deletions: [CKDatabase.RecordZoneChange.Deletion],
                       changeToken: CKServerChangeToken, moreComing: Bool)
            do {
                page = try await database.recordZoneChanges(inZoneWith: zoneID, since: server)
            } catch {
                if let ck = error as? CKError, ck.code == .changeTokenExpired { throw RecordChangesError.tokenExpired }
                throw Self.mapped(error, recordIDs: [])
            }
            for (id, result) in page.modificationResultsByID {
                switch result {
                case .success(let change):
                    guard change.record.recordType == type else { continue }
                    remember(change.record)
                    let record = Self.record(from: change.record)
                    changed[record.id] = record
                    deleted.remove(record.id)
                case .failure(let e):
                    throw Self.mapped(e, recordIDs: [id])
                }
            }
            for deletion in page.deletions where deletion.recordType == type {
                let id = RecordID(deletion.recordID.recordName)
                changed[id] = nil
                deleted.insert(id)
            }
            server = page.changeToken
            more = page.moreComing
        }
        let data = try NSKeyedArchiver.archivedData(withRootObject: server as Any, requiringSecureCoding: true)
        return RecordChanges(changed: changed.values.sorted { $0.id.name < $1.id.name },
                             deleted: deleted.sorted { $0.name < $1.name }, token: data)
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
            // An empty list carries no element type, and a field the schema has
            // not seen yet cannot be created from one: the server answers the
            // whole batch with "Syntax error in request". Every reader here
            // treats an absent list as empty, so leave it off the wire.
            if case .strings(let a) = value, a.isEmpty { copy[key] = nil; continue }
            if case .assets(let a) = value, a.isEmpty { copy[key] = nil; continue }
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
        case let a as [CKAsset]:
            // An asset's file is on disk once the record is; one that cannot be read is not the file.
            let data = a.compactMap { $0.fileURL.flatMap { try? Data(contentsOf: $0) } }
            return data.count == a.count ? .assets(data) : nil
        default: return nil
        }
    }

    static func ckValue(_ value: FieldValue) -> any CKRecordValue {
        switch value {
        case .string(let s): return s as NSString
        case .int(let i): return NSNumber(value: i)
        case .date(let d): return d as NSDate
        case .strings(let a): return a as NSArray
        case .assets(let a): return a.map(Self.asset) as NSArray
        }
    }

    /// A file for CloudKit to upload, in the temporary directory, which the system empties.
    static func asset(_ data: Data) -> CKAsset {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("asset-\(UUID().uuidString)")
        try? data.write(to: url, options: .atomic)
        return CKAsset(fileURL: url)
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
