import Foundation
import TopoCore

/// The person's choice of model, where every device can read it: one record in the zone
/// (`ModelChoice`, `choice/model`), which a device writes when it hands a turn to another device
/// to answer and its slider says otherwise, and which the hub reads when it has a turn to answer.
/// So the model a hub answers with is the one chosen on the device the person is holding.
///
/// A record of its own rather than a field of the turn, because a save the schema refuses
/// (a build that writes it against an environment it was never deployed to) loses only the
/// choice, never the person's turn, which a field in the turn's atomic batch would take with it.
/// It holds the family's alias (`ClaudeModel.rawValue`), never the model a debug build is pinned
/// to: the pin is each build's own (`ClaudeModel.effective`).
public enum ModelChoice {
    public static let recordType = "ModelChoice"
    public static let recordID = RecordID("choice/model")

    /// The choice the record holds, or nil when there is none or it names no choice (`ClaudeModel(setting:)`).
    public static func read(from database: any RecordDatabase) async throws -> ClaudeModel? {
        try await database.fetch(recordID).flatMap { $0.string("model") }.flatMap(ClaudeModel.init(setting:))
    }

    /// Makes the record say `model`, as said by `device`: nothing when it already does, otherwise
    /// a compare-and-set over the version read, read again when another device wrote between.
    public static func say(_ model: ClaudeModel, by device: DeviceID, to database: any RecordDatabase) async throws {
        var current = try await database.fetch(recordID)
        for _ in 0..<3 {
            if current?.string("model") == model.rawValue { return }
            let record = Record(type: recordType, id: recordID, fields: [
                "model": .string(model.rawValue),
                "device": .string(device.rawValue),
                "at": .date(Date()),
            ], changeTag: current?.changeTag)
            do {
                _ = try await database.save([record])
                return
            } catch RecordDatabaseError.serverRecordChanged(_, let server) {
                current = server
            }
        }
    }
}
