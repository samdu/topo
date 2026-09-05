import CloudKit
import Foundation

/// The self-test's steps against the real containers.
///
/// It writes, which is the one thing this bundle otherwise never does, and
/// it writes nowhere anybody reads: every record goes into a zone of its
/// own, made at the start and deleted at the end, under a device ID no real
/// device could have. The record types are the container's, so the schema,
/// the entitlement, the account and the indexes are all the real ones; the
/// log and the board are untouched.
///
/// What it proves is the path an ordinary read takes: a create-only write,
/// a read back through the zone's change feed, the fetch-by-ID probe past
/// the end of a device's run, and that a second write of the same record is
/// refused. Those are the four things that fail quietly on a device and
/// look identical from a simulator.
enum CloudKitSelfTest {
    static func steps(logContainer: String = "iCloud.zone.hexagon.topo",
                      boardContainer: String = "iCloud.zone.hexagon.topo.board") -> [SelfTestStep] {
        let run = Run(logIdentifier: logContainer, boardIdentifier: boardContainer)
        return [
            SelfTestStep(name: "iCloud account") { run.account($0) },
            SelfTestStep(name: "Make a zone of its own") { run.makeZone($0) },
            SelfTestStep(name: "Write a turn") { run.writeTurn(sequence: 1, $0) },
            SelfTestStep(name: "Read it back from the change feed") { run.readBack($0) },
            SelfTestStep(name: "Probe past the end: nothing there") { run.probe(sequence: 2, expecting: false, $0) },
            SelfTestStep(name: "Write the next turn") { run.writeTurn(sequence: 2, $0) },
            SelfTestStep(name: "Probe past the end: found by ID") { run.probe(sequence: 2, expecting: true, $0) },
            SelfTestStep(name: "Refuse to overwrite a turn") { run.refuseOverwrite($0) },
            SelfTestStep(name: "The board's container") { run.board($0) },
            SelfTestStep(name: "Tidy up") { run.tidy($0) },
        ]
    }

    /// The state the steps share: which zones were made, and what was
    /// written into them.
    private final class Run {
        // Made when a step first needs one, not when the list is built:
        // `CKContainer(identifier:)` raises in a bundle with no iCloud
        // entitlement, which is what a logic test is, and the list of steps
        // is worth checking there.
        private let logIdentifier: String
        private let boardIdentifier: String
        private lazy var logContainer = CKContainer(identifier: logIdentifier)
        private lazy var boardContainer = CKContainer(identifier: boardIdentifier)
        /// A device nothing else could be. The log's readers key everything
        /// by device, so a self-test that used a real one would be a turn
        /// in somebody's transcript.
        let device = "selftest-" + UUID().uuidString.lowercased()
        let zoneName = "SelfTest-" + UUID().uuidString.prefix(8)
        var logZone: CKRecordZone.ID?
        var boardZone: CKRecordZone.ID?

        init(logIdentifier: String, boardIdentifier: String) {
            self.logIdentifier = logIdentifier
            self.boardIdentifier = boardIdentifier
        }

        struct Failed: LocalizedError {
            let what: String
            var errorDescription: String? { return what }
        }

        func account(_ done: @escaping (Result<String, Error>) -> Void) {
            logContainer.accountStatus { status, error in
                if let error = error { return done(.failure(error)) }
                switch status {
                case .available:
                    done(.success("signed in"))
                case .noAccount:
                    done(.failure(Failed(what: "no iCloud account on this device")))
                case .restricted:
                    done(.failure(Failed(what: "iCloud is restricted on this device")))
                default:
                    done(.failure(Failed(what: "iCloud could not say whether there is an account")))
                }
            }
        }

        func makeZone(_ done: @escaping (Result<String, Error>) -> Void) {
            let zone = CKRecordZone(zoneName: zoneName)
            let operation = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            operation.modifyRecordZonesCompletionBlock = { saved, _, error in
                if let error = error { return done(.failure(error)) }
                guard let made = saved?.first else {
                    return done(.failure(Failed(what: "the zone was not made and CloudKit said nothing")))
                }
                self.logZone = made.zoneID
                done(.success(self.zoneName))
            }
            logContainer.privateCloudDatabase.add(operation)
        }

        func writeTurn(sequence: Int64, _ done: @escaping (Result<String, Error>) -> Void) {
            guard let zone = logZone else { return done(.failure(Failed(what: "no zone"))) }
            let name = "turn/\(device)/\(sequence)"
            let record = CKRecord(recordType: "Turn", recordID: CKRecord.ID(recordName: name, zoneID: zone))
            record["device"] = device as NSString
            record["sequence"] = NSNumber(value: sequence)
            record["parents"] = (sequence == 1 ? [] : ["\(device)/\(sequence - 1)"]) as NSArray
            record["role"] = "person" as NSString
            record["text"] = "self-test" as NSString
            record["at"] = Date() as NSDate
            record["nonce"] = UUID().uuidString as NSString
            save([record], in: logContainer.privateCloudDatabase) { result in
                done(result.map { _ in name })
            }
        }

        func readBack(_ done: @escaping (Result<String, Error>) -> Void) {
            guard let zone = logZone else { return done(.failure(Failed(what: "no zone"))) }
            ZoneChanges.records(ofType: "Turn", in: logContainer.privateCloudDatabase, zoneID: zone) { result in
                switch result {
                case .failure(let error):
                    done(.failure(error))
                case .success(let records):
                    guard !records.isEmpty else {
                        return done(.failure(Failed(what: "the feed came back empty, and a turn was just written")))
                    }
                    done(.success("\(records.count) record\(records.count == 1 ? "" : "s")"))
                }
            }
        }

        func probe(sequence: Int64, expecting present: Bool, _ done: @escaping (Result<String, Error>) -> Void) {
            guard let zone = logZone else { return done(.failure(Failed(what: "no zone"))) }
            let id = CKRecord.ID(recordName: "turn/\(device)/\(sequence)", zoneID: zone)
            let operation = CKFetchRecordsOperation(recordIDs: [id])
            operation.fetchRecordsCompletionBlock = { records, error in
                let found = (records ?? [:])[id] != nil
                if let error = error, !found, present {
                    return done(.failure(error))
                }
                if found == present {
                    done(.success(present ? "there, as it should be" : "absent, as it should be"))
                } else {
                    done(.failure(Failed(what: present
                        ? "the record was written and a fetch by ID could not find it"
                        : "a record that was never written came back")))
                }
            }
            logContainer.privateCloudDatabase.add(operation)
        }

        func refuseOverwrite(_ done: @escaping (Result<String, Error>) -> Void) {
            guard let zone = logZone else { return done(.failure(Failed(what: "no zone"))) }
            // The same name again, with no change tag: create-only, which is
            // what stops two writers clobbering each other.
            let record = CKRecord(recordType: "Turn",
                                  recordID: CKRecord.ID(recordName: "turn/\(device)/1", zoneID: zone))
            record["device"] = device as NSString
            record["sequence"] = NSNumber(value: 1)
            record["role"] = "person" as NSString
            record["text"] = "self-test overwrite" as NSString
            record["at"] = Date() as NSDate
            save([record], in: logContainer.privateCloudDatabase) { result in
                switch result {
                case .success:
                    done(.failure(Failed(what: "the second write was accepted; nothing here is create-only")))
                case .failure(let error):
                    let code = (error as NSError).code
                    if code == CKError.serverRecordChanged.rawValue || code == CKError.partialFailure.rawValue {
                        done(.success("refused, as it should be"))
                    } else {
                        done(.failure(error))
                    }
                }
            }
        }

        func board(_ done: @escaping (Result<String, Error>) -> Void) {
            let zone = CKRecordZone(zoneName: zoneName)
            let make = CKModifyRecordZonesOperation(recordZonesToSave: [zone], recordZoneIDsToDelete: nil)
            make.modifyRecordZonesCompletionBlock = { saved, _, error in
                if let error = error { return done(.failure(error)) }
                guard let made = saved?.first else {
                    return done(.failure(Failed(what: "the board's zone was not made")))
                }
                self.boardZone = made.zoneID
                let card = CKRecord(recordType: "Card",
                                    recordID: CKRecord.ID(recordName: "card/\(self.device)/1", zoneID: made.zoneID))
                card["card"] = "\(self.device)/1" as NSString
                card["device"] = self.device as NSString
                card["sequence"] = NSNumber(value: 1)
                card["owner"] = self.device as NSString
                card["body"] = "self-test" as NSString
                card["state"] = "posted" as NSString
                card["at"] = Date() as NSDate
                card["nonce"] = UUID().uuidString as NSString
                self.save([card], in: self.boardContainer.privateCloudDatabase) { result in
                    switch result {
                    case .failure(let error):
                        done(.failure(error))
                    case .success:
                        ZoneChanges.records(ofType: "Card", in: self.boardContainer.privateCloudDatabase,
                                            zoneID: made.zoneID) { read in
                            switch read {
                            case .failure(let error):
                                done(.failure(error))
                            case .success(let records):
                                guard !records.isEmpty else {
                                    return done(.failure(Failed(what: "the board's feed came back empty")))
                                }
                                done(.success("wrote and read a card"))
                            }
                        }
                    }
                }
            }
            boardContainer.privateCloudDatabase.add(make)
        }

        func tidy(_ done: @escaping (Result<String, Error>) -> Void) {
            var failures: [String] = []
            let group = DispatchGroup()
            for (zone, database) in [(logZone, logContainer.privateCloudDatabase),
                                     (boardZone, boardContainer.privateCloudDatabase)] {
                guard let zone = zone else { continue }
                group.enter()
                let operation = CKModifyRecordZonesOperation(recordZonesToSave: nil, recordZoneIDsToDelete: [zone])
                operation.modifyRecordZonesCompletionBlock = { _, _, error in
                    if let error = error { failures.append(SelfTest.describe(error)) }
                    group.leave()
                }
                database.add(operation)
            }
            group.notify(queue: .main) {
                if failures.isEmpty {
                    done(.success("the test zones are gone"))
                } else {
                    // Worth saying, and not worth failing over: what is left
                    // behind is a zone nothing reads.
                    done(.failure(Failed(what: "left a test zone behind: " + failures.joined(separator: "; "))))
                }
            }
        }

        private func save(_ records: [CKRecord], in database: CKDatabase,
                          _ done: @escaping (Result<Void, Error>) -> Void) {
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .ifServerRecordUnchanged
            operation.isAtomic = true
            operation.modifyRecordsCompletionBlock = { _, _, error in
                if let error = error { return done(.failure(error)) }
                done(.success(()))
            }
            database.add(operation)
        }
    }
}
