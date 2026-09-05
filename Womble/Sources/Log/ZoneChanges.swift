import CloudKit
import Foundation

/// Every record of a type in a zone, read from the zone's change feed.
///
/// Not a query. CloudKit answers a match-all predicate out of the record
/// name's index, which the development schema never marks queryable, so
/// asking for everything is asking for an error; and asking by a field of
/// ours cannot see a record damaged badly enough to have lost that field.
/// The feed needs no index and hands back everything in the zone, which is
/// what lets this screen say what it could not make sense of instead of
/// quietly showing less than there is.
///
/// With no change token it is the whole zone, which is what a viewer wants:
/// Womble has nothing to catch up from.
enum ZoneChanges {
    static func records(ofType type: String, in database: CKDatabase, zoneID: CKRecordZone.ID,
                        completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void) {
        var found: [CKRecord] = []
        var zoneFailure: Error?
        let lock = NSLock()

        let operation = CKFetchRecordZoneChangesOperation()
        operation.recordZoneIDs = [zoneID]
        operation.fetchAllChanges = true
        operation.recordChangedBlock = { record in
            guard record.recordType == type else { return }
            lock.lock()
            found.append(record)
            lock.unlock()
        }
        operation.recordZoneFetchCompletionBlock = { _, _, _, _, error in
            guard let error = error else { return }
            lock.lock()
            zoneFailure = error
            lock.unlock()
        }
        operation.fetchRecordZoneChangesCompletionBlock = { error in
            lock.lock()
            let failure = error ?? zoneFailure
            let all = found
            lock.unlock()
            if let failure = failure {
                completion(.failure(CloudKitStore.mapped(failure)))
                return
            }
            completion(.success(all))
        }
        database.add(operation)
    }
}
