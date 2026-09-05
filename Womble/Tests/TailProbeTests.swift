import CloudKit
import XCTest

/// A store whose query index is behind the records, the way CloudKit's is:
/// `hidden` exists and can be fetched by ID, but the query does not return
/// it. Everything else answers straight away, on the calling queue.
private final class FakeStore: TurnRecordStore {
    var queried: [CKRecord] = []
    var hidden: [CKRecord] = []
    var account: Result<Void, TranscriptError> = .success(())
    var queryResult: TranscriptError?
    var fetchResult: TranscriptError?
    private(set) var probed: [String] = []

    func accountAvailable(_ completion: @escaping (Result<Void, TranscriptError>) -> Void) {
        completion(account)
    }

    func allTurns(_ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void) {
        if let error = queryResult { return completion(.failure(error)) }
        completion(.success(queried))
    }

    func fetchTurns(named names: [String], _ completion: @escaping (Result<Set<String>, TranscriptError>) -> Void) {
        probed += names
        if let error = fetchResult { return completion(.failure(error)) }
        let all = Set((queried + hidden).map { $0.recordID.recordName })
        completion(.success(all.intersection(names)))
    }
}

private func turnRecord(_ device: String, _ sequence: Int64, parents: [String] = []) -> CKRecord {
    let ref = TurnRef(device: DeviceID(device), sequence: sequence)
    let record = CKRecord(recordType: Turn.recordType,
                          recordID: CKRecord.ID(recordName: Turn.recordName(for: ref)))
    record["device"] = device as NSString
    record["sequence"] = NSNumber(value: sequence)
    record["parents"] = parents as NSArray
    record["role"] = "person" as NSString
    record["text"] = "turn \(sequence)" as NSString
    record["at"] = Date(timeIntervalSince1970: TimeInterval(sequence)) as NSDate
    record["nonce"] = "n\(sequence)" as NSString
    return record
}

final class TailProbeTests: XCTestCase {
    private func read(_ store: FakeStore) -> Result<Transcript, TranscriptError> {
        let source = CloudKitTranscriptSource(store: store)
        var result: Result<Transcript, TranscriptError>?
        let done = expectation(description: "read")
        source.read { result = $0; done.fulfill() }
        wait(for: [done], timeout: 2)
        return result!
    }

    func testATurnTheQueryIndexHasNotCaughtUpWithIsReportedMissing() {
        // The whole point: a tail the query is short by leaves no gap behind
        // it, so without the probe this read looks complete.
        let store = FakeStore()
        store.queried = [turnRecord("phone", 1), turnRecord("phone", 2, parents: ["phone/1"])]
        store.hidden = [turnRecord("phone", 3, parents: ["phone/2"])]

        guard case .success(let transcript) = read(store) else { return XCTFail("the read failed") }
        XCTAssertFalse(transcript.isComplete, "a hidden tail is an incomplete read")
        XCTAssertTrue(transcript.missing.contains(TurnRef(device: DeviceID("phone"), sequence: 3)))
        XCTAssertEqual(transcript.ordered.count, 2, "the turns that were read are still shown")
    }

    func testEveryDeviceIsProbedPastItsOwnEnd() {
        let store = FakeStore()
        store.queried = [turnRecord("phone", 1), turnRecord("phone", 2), turnRecord("hub", 1)]
        _ = read(store)
        XCTAssertEqual(Set(store.probed), ["turn/phone/3", "turn/hub/2"])
    }

    func testAGapIsProbedPastTheGapNotUpToIt() {
        // `missing` counts towards a device's end, so a log that already has
        // a hole is still probed past its last known turn.
        let store = FakeStore()
        store.queried = [turnRecord("phone", 1), turnRecord("phone", 3)]
        _ = read(store)
        XCTAssertEqual(store.probed, ["turn/phone/4"])
    }

    func testNothingIsProbedWhenTheLogIsEmpty() {
        let store = FakeStore()
        guard case .success(let transcript) = read(store) else { return XCTFail("the read failed") }
        XCTAssertTrue(transcript.isEmpty)
        XCTAssertTrue(store.probed.isEmpty, "no device, nothing to probe past")
    }

    func testACompleteReadStaysComplete() {
        let store = FakeStore()
        store.queried = [turnRecord("phone", 1), turnRecord("phone", 2, parents: ["phone/1"])]
        guard case .success(let transcript) = read(store) else { return XCTFail("the read failed") }
        XCTAssertTrue(transcript.isComplete)
        XCTAssertEqual(transcript.ordered.count, 2)
    }

    func testAFailedProbeIsAFailedRead() {
        // Not a transcript with a note on it: the probe is how this read
        // knows it reached the end, so without it there is nothing to show.
        let store = FakeStore()
        store.queried = [turnRecord("phone", 1)]
        store.fetchResult = .unavailable(CKError(.networkUnavailable))
        guard case .failure(let error) = read(store) else { return XCTFail("the read should have failed") }
        if case .unavailable = error {} else { XCTFail("the probe's error is the read's error") }
    }

    func testNoAccountNeverReachesTheQuery() {
        let store = FakeStore()
        store.account = .failure(.noAccount)
        store.queryResult = .rejected(CKError(.permissionFailure))
        guard case .failure(let error) = read(store) else { return XCTFail("the read should have failed") }
        if case .noAccount = error {} else { XCTFail("the account is answered first") }
    }
}

final class MissingRecordErrorTests: XCTestCase {
    private func partialFailure(_ sub: [CKError.Code]) -> CKError {
        var byItem: [CKRecord.ID: Error] = [:]
        for (index, code) in sub.enumerated() {
            byItem[CKRecord.ID(recordName: "turn/phone/\(index + 1)")] = CKError(code)
        }
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: byItem])
    }

    func testProbesForAbsentRecordsAreNotAFailure() {
        // The ordinary answer to a tail probe is "no such record", which
        // CloudKit reports as a partial failure of unknown items.
        XCTAssertTrue(CloudKitStore.isOnlyMissingRecords(partialFailure([.unknownItem, .unknownItem])))
    }

    func testARealFailureAmongThemIsAFailure() {
        XCTAssertFalse(CloudKitStore.isOnlyMissingRecords(partialFailure([.unknownItem, .networkFailure])))
        XCTAssertFalse(CloudKitStore.isOnlyMissingRecords(CKError(.networkFailure)))
        XCTAssertFalse(CloudKitStore.isOnlyMissingRecords(partialFailure([])))
    }
}
