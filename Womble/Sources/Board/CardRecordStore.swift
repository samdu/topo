import CloudKit
import Foundation

/// The two things Womble asks of CloudKit about the board. The seam the
/// tests read a hidden tail through, and the only place that knows about
/// containers and zones.
///
/// Every completion may run on any queue; the reader hops to the main queue
/// once, at the end.
protocol CardRecordStore: AnyObject {
    /// Every card record in the zone, from its change feed. An empty result
    /// is an empty board; a board nobody has shared with this screen is also
    /// empty, and neither is a failure.
    func allCards(_ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void)
    /// These records, fetched by ID. A name that is not there is absent from
    /// the result rather than an error.
    func fetchCards(named names: [String], _ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void)
}

/// The house board in the shared container.
///
/// Two places it can be: a zone somebody shared with this Apple ID, which
/// arrives in the shared database, or one this Apple ID owns. A house has
/// one board, so the first zone named `Board` is it, shared first — the
/// household's board is more likely somebody else's than this screen's own.
///
/// A lookup that fails is a failure, not an empty board. The difference
/// matters on a wall: an empty board clears the screen, and a screen that
/// clears itself because the network hiccuped is worse than one showing
/// what it last knew.
final class CloudKitCardStore: CardRecordStore {
    private let container: CKContainer
    private let zoneName: String
    private var found: (database: CKDatabase, zoneID: CKRecordZone.ID)?

    init(containerIdentifier: String = "iCloud.zone.hexagon.topo.board", zoneName: String = "Board") {
        self.container = CKContainer(identifier: containerIdentifier)
        self.zoneName = zoneName
    }

    func allCards(_ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void) {
        zone { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(nil):
                // Nobody has a board yet, or nobody has shared one here.
                completion(.success([]))
            case .success(let found?):
                ZoneChanges.records(ofType: CardRevision.recordType, in: found.database,
                                    zoneID: found.zoneID, completion: completion)
            }
        }
    }

    func fetchCards(named names: [String], _ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void) {
        guard !names.isEmpty else { return completion(.success([])) }
        zone { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(nil):
                completion(.success([]))
            case .success(let found?):
                let ids = names.map { CKRecord.ID(recordName: $0, zoneID: found.zoneID) }
                let operation = CKFetchRecordsOperation(recordIDs: ids)
                operation.fetchRecordsCompletionBlock = { records, error in
                    if let error = error, !CloudKitStore.isOnlyMissingRecords(error) {
                        completion(.failure(CloudKitStore.mapped(error)))
                        return
                    }
                    completion(.success(Array((records ?? [:]).values)))
                }
                found.database.add(operation)
            }
        }
    }

    /// Where the board is, or nil for nowhere. Remembered once found: a
    /// house does not move its board between reads.
    private func zone(_ completion: @escaping (Result<(database: CKDatabase, zoneID: CKRecordZone.ID)?, TranscriptError>) -> Void) {
        if let found = found { return completion(.success(found)) }
        container.sharedCloudDatabase.fetchAllRecordZones { shared, error in
            if let error = error {
                completion(.failure(CloudKitStore.mapped(error)))
                return
            }
            if let zone = (shared ?? []).first(where: { $0.zoneID.zoneName == self.zoneName }) {
                self.found = (self.container.sharedCloudDatabase, zone.zoneID)
                completion(.success(self.found))
                return
            }
            self.container.privateCloudDatabase.fetchAllRecordZones { own, error in
                if let error = error {
                    completion(.failure(CloudKitStore.mapped(error)))
                    return
                }
                if let zone = (own ?? []).first(where: { $0.zoneID.zoneName == self.zoneName }) {
                    self.found = (self.container.privateCloudDatabase, zone.zoneID)
                    completion(.success(self.found))
                    return
                }
                completion(.success(nil))
            }
        }
    }
}
