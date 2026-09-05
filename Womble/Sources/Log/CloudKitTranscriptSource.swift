import CloudKit
import Foundation

/// Reads the turn log out of the private CloudKit database, in the zone the
/// client and the hub write.
///
/// CloudKit is truth here, and for Womble it is the whole truth: there is no
/// socket, no live turn and nothing to be fast about. It reads the records,
/// and a read that cannot be completed says so rather than showing part of a
/// conversation as all of it.
///
/// Written against the CloudKit of iOS 12 — `CKQueryOperation` with
/// `recordFetchedBlock` and `queryCompletionBlock` — because that is the
/// deployment target. The replacements (`recordMatchedBlock`,
/// `queryResultBlock`) arrived in iOS 15 and are unavailable on the devices
/// this bundle exists for.
final class CloudKitTranscriptSource: TranscriptSource {
    /// The container the whole of Topo shares. Every bundle — client, hub,
    /// Womble — reads and writes this one, so the identifier is a contract
    /// between them, not a per-target setting.
    static let containerIdentifier = "iCloud.zone.hexagon.topo"
    /// The log lives in a custom zone: the default zone has no atomic
    /// batches, which the writers need and the readers inherit.
    static let zoneName = "Topo"

    private let database: CKDatabase
    private let container: CKContainer
    private let zoneID: CKRecordZone.ID
    private let accumulator = DispatchQueue(label: "zone.hexagon.topo.womble.read")

    init(container: CKContainer = CKContainer(identifier: CloudKitTranscriptSource.containerIdentifier)) {
        self.container = container
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: CloudKitTranscriptSource.zoneName,
                                      ownerName: CKCurrentUserDefaultName)
    }

    func read(completion: @escaping (Result<Transcript, TranscriptError>) -> Void) {
        let finish: (Result<Transcript, TranscriptError>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }
        container.accountStatus { status, error in
            switch status {
            case .available:
                self.query(finish)
            case .noAccount, .restricted:
                finish(.failure(.noAccount))
            default:
                // `.couldNotDetermine`, and anything a later OS adds: the
                // account may well be fine, so this is a retry, not a verdict
                // about the device's Apple ID.
                finish(.failure(.unavailable(error ?? CKError(.internalError))))
            }
        }
    }

    private func query(_ completion: @escaping (Result<Transcript, TranscriptError>) -> Void) {
        var records: [CKRecord] = []

        func run(_ operation: CKQueryOperation) {
            operation.zoneID = zoneID
            operation.recordFetchedBlock = { record in
                self.accumulator.sync { records.append(record) }
            }
            operation.queryCompletionBlock = { cursor, error in
                if let error = error {
                    completion(.failure(CloudKitTranscriptSource.mapped(error)))
                    return
                }
                if let cursor = cursor {
                    run(CKQueryOperation(cursor: cursor))
                    return
                }
                let fetched = self.accumulator.sync { records }
                completion(.success(CloudKitTranscriptSource.transcript(from: fetched)))
            }
            database.add(operation)
        }

        run(CKQueryOperation(query: CKQuery(recordType: Turn.recordType, predicate: NSPredicate(value: true))))
    }

    /// The turns, and what the read could not make sense of. A record whose
    /// name is a ref but whose fields do not parse is reported as missing
    /// under that ref: something is there, and it is not readable as the turn
    /// it claims to be.
    static func transcript(from records: [CKRecord]) -> Transcript {
        var turns: [Turn] = []
        var missing = Set<TurnRef>()
        var unreadable: [String] = []
        for record in records {
            let name = record.recordID.recordName
            if let turn = Turn(recordName: name, fields: fields(of: record)) {
                turns.append(turn)
            } else if let ref = Turn.ref(ofRecordNamed: name) {
                missing.insert(ref)
            } else {
                unreadable.append(name)
            }
        }
        return Transcript(turns: turns, missing: missing, unreadable: unreadable)
    }

    static func fields(of record: CKRecord) -> [String: Any] {
        var fields: [String: Any] = [:]
        for key in record.allKeys() {
            if let value = record[key] { fields[key] = value }
        }
        return fields
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
        default:
            return .unavailable(error)
        }
    }
}
