import CloudKit
import XCTest


final class CloudKitReadTests: XCTestCase {
    private func record(_ name: String, _ fields: [String: CKRecordValue]) -> CKRecord {
        let record = CKRecord(recordType: Turn.recordType, recordID: CKRecord.ID(recordName: name))
        for (key, value) in fields { record[key] = value }
        return record
    }

    private var wellFormed: [String: CKRecordValue] {
        return [
            "device": "phone" as NSString,
            "sequence": NSNumber(value: 1),
            "role": "assistant" as NSString,
            "text": "hello" as NSString,
            "at": Date(timeIntervalSince1970: 100) as NSDate,
            "nonce": "n1" as NSString,
        ]
    }

    func testReadsRecords() {
        let transcript = CloudKitTranscriptSource.transcript(from: [record("turn/phone/1", wellFormed)])
        XCTAssertEqual(transcript.ordered.count, 1)
        XCTAssertEqual(transcript.ordered.first?.role, .assistant)
        XCTAssertTrue(transcript.isComplete)
    }

    func testARecordNamedAsATurnThatDoesNotParseIsMissing() {
        // Something is at that ref and it is not readable as the turn it
        // claims to be, so the read is incomplete rather than quietly short.
        var fields = wellFormed
        fields.removeValue(forKey: "text")
        let transcript = CloudKitTranscriptSource.transcript(from: [record("turn/phone/1", fields)])
        XCTAssertEqual(transcript.missing, [TurnRef(device: DeviceID("phone"), sequence: 1)])
        XCTAssertFalse(transcript.isComplete)
    }

    func testARecordWhoseFieldsClaimAnotherRefIsMissing() {
        // The impostor is reported at its own name, and the turn it claimed
        // to be is untouched.
        var fields = wellFormed
        fields["device"] = "hub" as NSString
        fields["sequence"] = NSNumber(value: 2)
        let real = record("turn/hub/2", fields)
        let impostor = record("turn/phone/1", fields)
        let transcript = CloudKitTranscriptSource.transcript(from: [real, impostor])
        XCTAssertEqual(transcript.ordered.count, 1)
        XCTAssertEqual(transcript.ordered.first?.ref, TurnRef(device: DeviceID("hub"), sequence: 2))
        XCTAssertTrue(transcript.missing.contains(TurnRef(device: DeviceID("phone"), sequence: 1)))
        XCTAssertFalse(transcript.isComplete)
    }

    func testARecordWithNoRefIsUnreadable() {
        let transcript = CloudKitTranscriptSource.transcript(from: [record("something-else", wellFormed)])
        XCTAssertEqual(transcript.unreadable, ["something-else"])
        XCTAssertFalse(transcript.isComplete)
    }

    func testErrorMapping() {
        func mapped(_ code: CKError.Code) -> TranscriptError {
            return CloudKitStore.mapped(CKError(code))
        }
        if case .noAccount = mapped(.notAuthenticated) {} else { XCTFail("not signed in is an account problem") }
        if case .noLog = mapped(.zoneNotFound) {} else { XCTFail("no zone means nothing has been written") }
        if case .rejected = mapped(.permissionFailure) {} else { XCTFail("permission failure will not clear") }
        if case .unavailable = mapped(.networkUnavailable) {} else { XCTFail("no network is a retry") }
        if case .unavailable = mapped(.serviceUnavailable) {} else { XCTFail("a busy server is a retry") }
        if case .unavailable = CloudKitStore.mapped(NSError(domain: "test", code: 1)) {} else {
            XCTFail("a non-CloudKit error is a retry")
        }
    }
}

/// The read is the zone's change feed rather than a query, so a record too
/// damaged to be found by a field of ours is still seen — and a screen that
/// says a turn is missing is telling the truth about the log rather than
/// about the index.
final class DamagedRecordTests: XCTestCase {
    func testARecordWithNoSequenceIsStillSeenAndReported() {
        let damaged = CKRecord(recordType: Turn.recordType,
                               recordID: CKRecord.ID(recordName: "turn/phone/1"))
        damaged["device"] = "phone" as NSString
        // No sequence, no role, no text: a query by sequence could not
        // return this at all, and the feed hands it over.
        let store = DamagedRecordStore(records: [damaged])
        let source = CloudKitTranscriptSource(store: store)

        var answer: Result<Transcript, TranscriptError>?
        let done = expectation(description: "read")
        source.read { result in
            answer = result
            done.fulfill()
        }
        wait(for: [done], timeout: 2)

        guard case .success(let transcript)? = answer else { return XCTFail("not a transcript") }
        XCTAssertFalse(transcript.isComplete)
        XCTAssertEqual(transcript.missing, [TurnRef(device: DeviceID("phone"), sequence: 1)])
    }
}

/// Answers with whatever it was given, and finds nothing past the end.
private final class DamagedRecordStore: TurnRecordStore {
    private let records: [CKRecord]

    init(records: [CKRecord]) { self.records = records }

    func accountAvailable(_ completion: @escaping (Result<Void, TranscriptError>) -> Void) {
        completion(.success(()))
    }

    func allTurns(_ completion: @escaping (Result<[CKRecord], TranscriptError>) -> Void) {
        completion(.success(records))
    }

    func fetchTurns(named names: [String], _ completion: @escaping (Result<Set<String>, TranscriptError>) -> Void) {
        completion(.success([]))
    }
}
