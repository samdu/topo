import CloudKit
import Foundation

/// Where the board comes from. The screen holds one of these and knows
/// nothing else about CloudKit.
protocol BoardSource {
    func read(_ completion: @escaping (Result<Board, TranscriptError>) -> Void)
}

/// The house board, read from the shared container.
///
/// Two places it can be: a zone somebody shared with this Apple ID, which
/// arrives in the shared database, or one this Apple ID owns itself. A
/// house has one board, so the first zone named `Board` is it, shared
/// first — the household's board is more likely somebody else's than this
/// screen's own.
///
/// Womble writes nothing here either. It is a noticeboard: it shows what
/// the house posted, and a tap is the client app's business.
final class CloudKitBoardSource: BoardSource {
    private let container: CKContainer
    private let zoneName: String

    init(containerIdentifier: String = "iCloud.zone.hexagon.topo.board", zoneName: String = "Board") {
        self.container = CKContainer(identifier: containerIdentifier)
        self.zoneName = zoneName
    }

    /// Every card there is, asked for by sequence: a match-all predicate is
    /// answered out of the record name's index, which the schema never
    /// marks queryable. Sequences start at 1. Same reason as the turn log,
    /// same shape.
    static let everyCard = NSPredicate(format: "sequence > 0")

    func read(_ completion: @escaping (Result<Board, TranscriptError>) -> Void) {
        zone { found in
            guard let found = found else {
                // No board anywhere is not a failure: nobody has posted a
                // card, or nobody has shared one with this screen yet.
                completion(.success(Board(revisions: [])))
                return
            }
            self.query(in: found.database, zoneID: found.zoneID, completion: completion)
        }
    }

    private func zone(_ completion: @escaping ((database: CKDatabase, zoneID: CKRecordZone.ID)?) -> Void) {
        container.sharedCloudDatabase.fetchAllRecordZones { zones, _ in
            if let zone = (zones ?? []).first(where: { $0.zoneID.zoneName == self.zoneName }) {
                completion((self.container.sharedCloudDatabase, zone.zoneID))
                return
            }
            self.container.privateCloudDatabase.fetchAllRecordZones { own, _ in
                if let zone = (own ?? []).first(where: { $0.zoneID.zoneName == self.zoneName }) {
                    completion((self.container.privateCloudDatabase, zone.zoneID))
                    return
                }
                completion(nil)
            }
        }
    }

    private func query(in database: CKDatabase, zoneID: CKRecordZone.ID,
                       completion: @escaping (Result<Board, TranscriptError>) -> Void) {
        var revisions: [CardRevision] = []
        let lock = NSLock()

        func run(_ operation: CKQueryOperation) {
            operation.zoneID = zoneID
            operation.recordFetchedBlock = { record in
                guard let revision = CardRevision(record: record) else { return }
                lock.lock()
                revisions.append(revision)
                lock.unlock()
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
                lock.lock()
                let all = revisions
                lock.unlock()
                completion(.success(Board(revisions: all)))
            }
            database.add(operation)
        }

        run(CKQueryOperation(query: CKQuery(recordType: CardRevision.recordType,
                                            predicate: CloudKitBoardSource.everyCard)))
    }
}
