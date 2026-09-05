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

/// CloudKit answers a match-all predicate out of the record name's index,
/// which the development schema never marks queryable — so asking for
/// everything is asking for an error on a real container, and the screen
/// says the log could not be read. Asking by a field of our own works,
/// because that index is built when the first record carrying it is saved.
final class TurnQueryPredicateTests: XCTestCase {
    func testTheQueryAsksBySequenceRatherThanForEverything() {
        XCTAssertEqual(CloudKitStore.everyTurn.predicateFormat, "sequence > 0")
        XCTAssertNotEqual(CloudKitStore.everyTurn, NSPredicate(value: true))
    }

    func testEverySequenceARealTurnCanHaveMatches() {
        // Sequences start at 1, so this is every turn there is.
        for sequence in [1, 2, 99, Int(Int32.max)] {
            XCTAssertTrue(CloudKitStore.everyTurn.evaluate(with: ["sequence": sequence]),
                          "turn \(sequence) would not be read")
        }
    }
}
