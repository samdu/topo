import CloudKit
import Foundation

/// `TurnRecordStore` over the private CloudKit database, in the zone the
/// client and the hub write.
///
/// Written against the CloudKit of iOS 12 — `CKQueryOperation` and
/// `CKFetchRecordsOperation` with their completion blocks — because that is
/// the deployment target. The replacements (`recordMatchedBlock`,
/// `queryResultBlock`, `perRecordResultBlock`) arrived in iOS 15 and are
/// unavailable on the devices this bundle exists for.
final class CloudKitStore: TurnRecordStore {
    /// The container the whole of Topo shares. Every bundle — client, hub,
    /// Womble — reads and writes this one, so the identifier is a contract
    /// between them, not a per-target setting.
    static let containerIdentifier = "iCloud.zone.hexagon.topo"
    /// The log lives in a custom zone: the default zone has no atomic
    /// batches, which the writers need and the readers inherit.
    static let zoneName = "Topo"

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let accumulator = DispatchQueue(label: "zone.hexagon.topo.womble.read")

    init(container: CKContainer = CKContainer(identifier: CloudKitStore.containerIdentifier)) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: CloudKitStore.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    func accountAvailable(_ completion: @escaping (Result<Void, TranscriptError>) -> Void) {
        container.accountStatus { status, error in
            switch status {
            case .available:
                completion(.success(()))
            case .noAccount, .restricted:
                completion(.failure(.noAccount))
            default:
                // `.couldNotDetermine`, and anything a later OS adds: the
                // account may well be fine, so this is a retry, not a
                // verdict about the device's Apple ID.
                completion(.failure(.unavailable(error ?? CKError(.internalError))))
            }
        }
    }

    /// Every turn there is. It asks for a positive sequence rather than for
    /// everything, and the difference is not cosmetic: CloudKit answers a
    /// match-all predicate out of the record name's index, which the
    /// development schema never marks queryable, so `NSPredicate(value: true)`
    /// comes back as an error on a real container and the screen says the log
    /// could not be read. The index behind a field of our own is built when
    /// the first record carrying it is saved. Sequences start at 1, so this
    /// asks for the same records by a road that exists.
    static let everyTurn = NSPredicate(format: "sequence > 0")

    func queryTurns(_ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void) {
        var records: [CKRecord] = []

        func run(_ operation: CKQueryOperation) {
            operation.zoneID = zoneID
            operation.recordFetchedBlock = { record in
                self.accumulator.sync { records.append(record) }
            }
            operation.queryCompletionBlock = { cursor, error in
                if let error = error {
                    completion(.failure(CloudKitStore.mapped(error)))
                    return
                }
                if let cursor = cursor {
                    run(CKQueryOperation(cursor: cursor))
                    return
                }
                completion(.success(self.accumulator.sync { records }))
            }
            database.add(operation)
        }

        run(CKQueryOperation(query: CKQuery(recordType: Turn.recordType, predicate: CloudKitStore.everyTurn)))
    }

    func fetchTurns(named names: [String], _ completion: @escaping (Result<Set<String>, TranscriptError>) -> Void) {
        guard !names.isEmpty else { return completion(.success([])) }
        let operation = CKFetchRecordsOperation(recordIDs: names.map { CKRecord.ID(recordName: $0, zoneID: zoneID) })
        operation.fetchRecordsCompletionBlock = { records, error in
            let present = Set((records ?? [:]).keys.map { $0.recordName })
            if let error = error, !CloudKitStore.isOnlyMissingRecords(error) {
                completion(.failure(CloudKitStore.mapped(error)))
                return
            }
            completion(.success(present))
        }
        database.add(operation)
    }

    /// A probe for a record that is not there comes back as a partial
    /// failure of `unknownItem`s, which is the ordinary answer — no hidden
    /// tail — and not a failed read.
    static func isOnlyMissingRecords(_ error: Error) -> Bool {
        guard let ck = error as? CKError, ck.code == .partialFailure,
              let byItem = ck.partialErrorsByItemID, !byItem.isEmpty else { return false }
        return byItem.values.allSatisfy { ($0 as? CKError)?.code == .unknownItem }
    }

    static func mapped(_ error: Error) -> TranscriptError {
        guard let ck = error as? CKError else { return .unavailable(error) }
        switch ck.code {
        case .notAuthenticated, .managedAccountRestricted:
            return .noAccount
        case .zoneNotFound, .userDeletedZone:
            // Nobody has written a turn on this Apple ID, so there is no zone
            // to read. That is an empty log, not a broken one.
            return .noLog
        case .permissionFailure, .badContainer, .badDatabase, .missingEntitlement,
             .invalidArguments, .incompatibleVersion,
             .constraintViolation, .limitExceeded, .quotaExceeded:
            return .rejected(error)
        case .partialFailure:
            for sub in (ck.partialErrorsByItemID ?? [:]).values {
                let mapped = CloudKitStore.mapped(sub)
                if case .unavailable = mapped { continue }
                return mapped
            }
            return .unavailable(error)
        default:
            return .unavailable(error)
        }
    }
}
