import CloudKit
import XCTest

/// `turn.json` (`Packages/TopoCore/Tests/Fixtures`) is the `Turn` record as the log writes it;
/// TopoCore's `TurnRecordFixtureTests` holds the writer to the same file. Womble is held to it
/// through the read it makes of CloudKit, a `CKRecord` and `CloudKitTranscriptSource`.
enum TurnFixture {
    /// The fixture's record name and its fields as CloudKit hands them over: a string, a whole
    /// number, a list of strings, and `{"date": seconds}`.
    static func load() throws -> (name: String, fields: [String: CKRecordValue]) {
        let url = try XCTUnwrap(Bundle(for: Marker.self).url(forResource: "turn", withExtension: "json"),
                                "turn.json is not in the bundle")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, Turn.recordType)
        let name = try XCTUnwrap(json["name"] as? String)
        let raw = try XCTUnwrap(json["fields"] as? [String: Any])
        var fields: [String: CKRecordValue] = [:]
        for (key, value) in raw {
            switch value {
            case let s as String: fields[key] = s as NSString
            case let n as NSNumber: fields[key] = NSNumber(value: n.int64Value)
            case let list as [String]: fields[key] = list as NSArray
            case let d as [String: Any]:
                let seconds = try XCTUnwrap(d["date"] as? NSNumber, "\(key): an object is a date")
                fields[key] = Date(timeIntervalSince1970: seconds.doubleValue) as NSDate
            default: XCTFail("\(key): no field type for \(value)")
            }
        }
        return (name, fields)
    }

    private final class Marker {}
}

final class TurnFixtureTests: XCTestCase {
    func testTheLogsTurnRecordReadsAsItsTurn() throws {
        let fixture = try TurnFixture.load()
        let record = CKRecord(recordType: Turn.recordType, recordID: CKRecord.ID(recordName: fixture.name))
        for (key, value) in fixture.fields { record[key] = value }
        let transcript = CloudKitTranscriptSource.transcript(from: [record])
        XCTAssertEqual(transcript.missing, [])
        XCTAssertEqual(transcript.unreadable, [])
        let turn = try XCTUnwrap(transcript.turns.first)
        XCTAssertEqual(transcript.turns.count, 1)
        XCTAssertEqual(turn.ref, TurnRef(device: DeviceID("phone"), sequence: 3))
        XCTAssertEqual(turn.parents, [TurnRef(device: DeviceID("hub"), sequence: 2), TurnRef(device: DeviceID("phone"), sequence: 2)])
        XCTAssertEqual(turn.role, .person)
        XCTAssertEqual(turn.text, "hello")
        XCTAssertEqual(turn.at, Date(timeIntervalSince1970: 1_793_000_000))
    }
}
