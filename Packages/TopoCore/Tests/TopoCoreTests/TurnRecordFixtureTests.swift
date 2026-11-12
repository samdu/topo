import Foundation
import Testing
@testable import TopoCore

/// `Tests/Fixtures/turn.json` is the `Turn` record as the log writes it, and Womble's
/// `TurnFixtureTests` reads the same file. Each side is held to the file, not to the other's code,
/// so a field renamed or retyped on either side fails that side's suite.
@Suite struct TurnRecordFixtureTests {
    @Test func theWriterProducesTheFixture() throws {
        let fixture = try Self.fixture()
        let turn = Turn(ref: .init(device: DeviceID("phone"), sequence: 3),
                        parents: [.init(device: DeviceID("hub"), sequence: 2), .init(device: DeviceID("phone"), sequence: 2)],
                        role: .person, text: "hello", at: Date(timeIntervalSince1970: 1_793_000_000), nonce: "nonce-3")
        #expect(turn.record == fixture)
        #expect(Turn(record: fixture) == turn)
    }

    /// The fixture's fields by JSON type: a string, a whole number, a list of strings, and
    /// `{"date": seconds}`. The form is the file's own, so Womble reads it without `FieldValue`.
    static func fixture() throws -> Record {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/turn.json")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let type = try #require(json["type"] as? String)
        let name = try #require(json["name"] as? String)
        let raw = try #require(json["fields"] as? [String: Any])
        var fields: [String: FieldValue] = [:]
        for (key, value) in raw {
            switch value {
            case let s as String: fields[key] = .string(s)
            case let n as NSNumber: fields[key] = .int(n.int64Value)
            case let list as [String]: fields[key] = .strings(list)
            case let d as [String: Any]:
                let seconds = try #require(d["date"] as? NSNumber, "\(key): an object is a date")
                fields[key] = .date(Date(timeIntervalSince1970: seconds.doubleValue))
            default: Issue.record("\(key): no field type for \(value)")
            }
        }
        return Record(type: type, id: RecordID(name), fields: fields)
    }
}
