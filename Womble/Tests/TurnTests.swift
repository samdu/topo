import XCTest


final class TurnRefTests: XCTestCase {
    func testParsesDeviceAndSequence() {
        let ref = TurnRef(parsing: "phone/3")
        XCTAssertEqual(ref?.device.rawValue, "phone")
        XCTAssertEqual(ref?.sequence, 3)
    }

    func testDeviceMayContainSlashes() {
        // The device is everything before the *last* slash, so a device
        // whose name has one does not parse as a different device.
        let ref = TurnRef(parsing: "sam/phone/12")
        XCTAssertEqual(ref?.device.rawValue, "sam/phone")
        XCTAssertEqual(ref?.sequence, 12)
    }

    func testRejectsMalformed() {
        XCTAssertNil(TurnRef(parsing: "phone"))
        XCTAssertNil(TurnRef(parsing: "phone/"))
        XCTAssertNil(TurnRef(parsing: "phone/one"))
        XCTAssertNil(TurnRef(parsing: ""))
    }

    func testRecordNameRoundTrip() {
        XCTAssertEqual(Turn.ref(ofRecordNamed: "turn/phone/4"), TurnRef(device: DeviceID("phone"), sequence: 4))
        XCTAssertNil(Turn.ref(ofRecordNamed: "phone/4"), "a name without the prefix is not a turn")
        XCTAssertNil(Turn.ref(ofRecordNamed: "turn/phone/0"), "sequence numbers start at 1")
        XCTAssertNil(Turn.ref(ofRecordNamed: "turn/phone/-2"))
    }
}

final class TurnParsingTests: XCTestCase {
    private func fields(_ overrides: [String: Any?] = [:]) -> [String: Any] {
        var fields: [String: Any] = [
            "device": "phone",
            "sequence": NSNumber(value: 1),
            "parents": [String](),
            "role": "person",
            "text": "hello",
            "at": Date(timeIntervalSince1970: 100),
            "nonce": "n1",
        ]
        for (key, value) in overrides {
            if let value = value { fields[key] = value } else { fields.removeValue(forKey: key) }
        }
        return fields
    }

    func testReadsATurn() {
        let turn = Turn(recordName: "turn/phone/1", fields: fields(["parents": ["hub/2"]]))
        XCTAssertEqual(turn?.ref, TurnRef(device: DeviceID("phone"), sequence: 1))
        XCTAssertEqual(turn?.parents, [TurnRef(device: DeviceID("hub"), sequence: 2)])
        XCTAssertEqual(turn?.role, .person)
        XCTAssertEqual(turn?.text, "hello")
    }

    func testAbsentParentsReadAsNone() {
        // CloudKit may drop an empty list, so a turn with no parents can
        // arrive with no field at all.
        XCTAssertEqual(Turn(recordName: "turn/phone/1", fields: fields(["parents": nil]))?.parents, [])
    }

    func testRejectsAnUnparseableParent() {
        // Half a parent list is worse than none: it would render as a turn
        // that continues from somewhere it does not.
        XCTAssertNil(Turn(recordName: "turn/phone/1", fields: fields(["parents": ["hub/2", "nonsense"]])))
    }

    func testRejectsMissingAndMalformedFields() {
        XCTAssertNil(Turn(recordName: "turn/phone/1", fields: fields(["text": nil])))
        XCTAssertNil(Turn(recordName: "turn/phone/1", fields: fields(["at": nil])))
        XCTAssertNil(Turn(recordName: "turn/phone/1", fields: fields(["role": "narrator"])))
        XCTAssertNil(Turn(recordName: "turn/phone/1", fields: fields(["sequence": NSNumber(value: 0)])))
        XCTAssertNil(Turn(recordName: "phone/1", fields: fields()), "the record name must be a turn's")
    }

    func testMissingNonceIsStillReadable() {
        // The nonce is a writer's business; a viewer never uses it, so its
        // absence must not hide a turn.
        XCTAssertNotNil(Turn(recordName: "turn/phone/1", fields: fields(["nonce": nil])))
    }
}
