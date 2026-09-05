import Foundation

/// A device on the Apple ID: a phone, the hub, a viewer.
struct DeviceID: Hashable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

/// Names one turn: the device that wrote it and its sequence number on that
/// device. Sequence numbers start at 1.
struct TurnRef: Hashable, Comparable, CustomStringConvertible {
    let device: DeviceID
    let sequence: Int64

    init(device: DeviceID, sequence: Int64) {
        self.device = device
        self.sequence = sequence
    }

    /// Parses the form `device/sequence`. The device may itself contain slashes.
    init?(parsing string: String) {
        guard let slash = string.range(of: "/", options: .backwards),
            let seq = Int64(string[slash.upperBound...])
        else { return nil }
        self.init(device: DeviceID(String(string[..<slash.lowerBound])), sequence: seq)
    }

    var description: String { return "\(device.rawValue)/\(sequence)" }

    static func < (a: TurnRef, b: TurnRef) -> Bool {
        if a.device.rawValue != b.device.rawValue { return a.device.rawValue < b.device.rawValue }
        return a.sequence < b.sequence
    }
}

enum TurnRole: String {
    case person
    case assistant
}

/// One turn of the transcript, as Womble reads it. Immutable once written,
/// and Womble never writes: the fields below are the read side of the `Turn`
/// record type, and nothing here appends, claims or heartbeats.
struct Turn: Hashable {
    static let recordType = "Turn"
    static let recordPrefix = "turn/"

    let ref: TurnRef
    let parents: [TurnRef]
    let role: TurnRole
    let text: String
    let at: Date

    /// Nil if the record is not a well-formed turn: a sequence below 1 is not
    /// one, and neither is a parent list Womble cannot parse in full. An
    /// absent `parents` field reads as no parents, since CloudKit may drop an
    /// empty list. `nonce` is a writer's business and is not read here.
    ///
    /// The name and the fields must agree on which turn this is. A record
    /// named `turn/phone/1` whose fields say `hub/2` is not a turn: taking
    /// its word would let it stand where the real `hub/2` goes, and the
    /// reader would show a turn nobody wrote at a ref it does not hold.
    init?(recordName: String, fields: [String: Any]) {
        guard let named = Turn.ref(ofRecordNamed: recordName),
            let device = fields["device"] as? String,
            let sequence = (fields["sequence"] as? NSNumber)?.int64Value, sequence >= 1,
            named == TurnRef(device: DeviceID(device), sequence: sequence),
            let roleString = fields["role"] as? String, let role = TurnRole(rawValue: roleString),
            let text = fields["text"] as? String,
            let at = fields["at"] as? Date
        else { return nil }
        let parentStrings = fields["parents"] as? [String] ?? []
        let parents = parentStrings.compactMap(TurnRef.init(parsing:))
        guard parents.count == parentStrings.count else { return nil }
        self.ref = TurnRef(device: DeviceID(device), sequence: sequence)
        self.parents = parents
        self.role = role
        self.text = text
        self.at = at
    }

    /// The name a turn's record has.
    static func recordName(for ref: TurnRef) -> String { return recordPrefix + ref.description }

    /// The ref a turn record's name carries, whatever the rest of it holds.
    static func ref(ofRecordNamed name: String) -> TurnRef? {
        guard name.hasPrefix(recordPrefix) else { return nil }
        guard let ref = TurnRef(parsing: String(name.dropFirst(recordPrefix.count))), ref.sequence >= 1
        else { return nil }
        return ref
    }
}
