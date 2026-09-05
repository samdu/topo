import Foundation

/// One device on the Apple ID, as the private database knows it: the record
/// every bundle writes about itself at launch and reads about the others.
/// Record name `device/<id>`, type `Device`.
///
/// Pairing is symmetric and recorded on both sides: each device lists in
/// `pairedWith` the devices whose code it scanned or whose scan it accepted.
/// Roles are not stored; primary is whoever holds the lease.
public struct Device: Hashable, Sendable, Identifiable {
    public static let recordType = "Device"
    static let recordPrefix = "device/"

    public enum Kind: String, Sendable, CaseIterable {
        case mac, phone, pad, watch, tv, womble
    }

    public let id: DeviceID
    public var name: String
    public var kind: Kind
    /// Base64 of the device's public key, for the tunnel layer. Shown in the
    /// pairing code so the scanner can check the record against the screen.
    public var publicKey: String
    /// Where the device answers on the LAN, `host:port`, newest first.
    public var endpoints: [String]
    public var pairedWith: [DeviceID]
    public let registeredAt: Date
    public var seenAt: Date

    public init(id: DeviceID, name: String, kind: Kind, publicKey: String, endpoints: [String] = [],
                pairedWith: [DeviceID] = [], registeredAt: Date, seenAt: Date) {
        self.id = id
        self.name = name
        self.kind = kind
        self.publicKey = publicKey
        self.endpoints = endpoints
        self.pairedWith = pairedWith
        self.registeredAt = registeredAt
        self.seenAt = seenAt
    }

    public static func recordID(for id: DeviceID) -> RecordID { RecordID(recordPrefix + id.rawValue) }

    public func isPaired(with other: DeviceID) -> Bool { pairedWith.contains(other) }

    public init?(record: Record) {
        guard record.type == Device.recordType, record.id.name.hasPrefix(Device.recordPrefix),
              let name = record.string("name"),
              let kindString = record.string("kind"), let kind = Kind(rawValue: kindString),
              let publicKey = record.string("publicKey"),
              let registeredAt = record.date("registeredAt"),
              let seenAt = record.date("seenAt") else { return nil }
        self.init(id: DeviceID(String(record.id.name.dropFirst(Device.recordPrefix.count))),
                  name: name, kind: kind, publicKey: publicKey,
                  endpoints: record.strings("endpoints") ?? [],
                  pairedWith: (record.strings("pairedWith") ?? []).map { DeviceID(rawValue: $0) },
                  registeredAt: registeredAt, seenAt: seenAt)
    }

    func record(changeTag: String?) -> Record {
        Record(type: Device.recordType, id: Device.recordID(for: id), fields: [
            "name": .string(name),
            "kind": .string(kind.rawValue),
            "publicKey": .string(publicKey),
            "endpoints": .strings(endpoints),
            "pairedWith": .strings(pairedWith.map(\.rawValue)),
            "registeredAt": .date(registeredAt),
            "seenAt": .date(seenAt),
        ], changeTag: changeTag)
    }
}

/// What the QR code on a hub's screen carries: enough for the scanner to
/// find the hub's record, check that the key on the screen is the key in
/// the record, and reach it on the LAN without waiting for a query.
/// `topo://pair?v=1&d=<id>&n=<name>&k=<publicKey>&e=<endpoint>`.
public struct PairingCode: Hashable, Sendable {
    public static let version = "1"

    public var device: DeviceID
    public var name: String
    public var publicKey: String
    public var endpoint: String?

    public init(device: DeviceID, name: String, publicKey: String, endpoint: String?) {
        self.device = device
        self.name = name
        self.publicKey = publicKey
        self.endpoint = endpoint
    }

    public init(_ device: Device) {
        self.init(device: device.id, name: device.name, publicKey: device.publicKey, endpoint: device.endpoints.first)
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "topo"
        parts.host = "pair"
        var items = [
            URLQueryItem(name: "v", value: Self.version),
            URLQueryItem(name: "d", value: device.rawValue),
            URLQueryItem(name: "n", value: name),
            URLQueryItem(name: "k", value: publicKey),
        ]
        if let endpoint { items.append(URLQueryItem(name: "e", value: endpoint)) }
        parts.queryItems = items
        return parts.url!
    }

    /// Nil for anything but a version-1 pairing URL with a device and a key.
    public init?(url: URL) {
        guard url.scheme == "topo", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var fields: [String: String] = [:]
        for item in items { fields[item.name] = item.value }
        guard fields["v"] == Self.version, let device = fields["d"], !device.isEmpty,
              let key = fields["k"], !key.isEmpty else { return nil }
        self.init(device: DeviceID(device), name: fields["n"] ?? device, publicKey: key, endpoint: fields["e"])
    }
}

public enum PairingError: Error, Sendable, Equatable {
    /// The code names a device with no record; it has not launched against
    /// this Apple ID's database, or the launch has not landed yet.
    case unknownDevice(DeviceID)
    /// The key on the screen is not the key in the record.
    case keyMismatch(DeviceID)
    /// A device does not pair with itself.
    case selfPairing
    /// Both records kept changing under the update.
    case contended
}

/// Reads and writes `Device` records.
public struct DeviceDirectory: Sendable {
    let database: any RecordDatabase

    public init(database: any RecordDatabase) {
        self.database = database
    }

    /// Writes a device's own record: created if absent, otherwise updated
    /// with its current name, kind, key, endpoints and `seenAt`, keeping the
    /// pairings already recorded. Returns the record as the store holds it.
    public func register(_ device: Device) async throws -> Device {
        for _ in 0..<3 {
            let current = try await database.fetch(Device.recordID(for: device.id))
            var toSave = device
            if let current {
                if let existing = Device(record: current) {
                    toSave = Device(id: device.id, name: device.name, kind: device.kind, publicKey: device.publicKey,
                                    endpoints: device.endpoints, pairedWith: existing.pairedWith,
                                    registeredAt: existing.registeredAt, seenAt: device.seenAt)
                }
            }
            do {
                let saved = try await database.save(toSave.record(changeTag: current?.changeTag))
                return Device(record: saved) ?? toSave
            } catch RecordDatabaseError.serverRecordChanged {
                continue
            }
        }
        throw PairingError.contended
    }

    public func device(_ id: DeviceID) async throws -> Device? {
        try await database.fetch(Device.recordID(for: id)).flatMap(Device.init(record:))
    }

    /// Every device record, by name.
    public func all() async throws -> [Device] {
        // Every device has a `seenAt`, so this is the whole directory. It is not a match-all
        // predicate because CloudKit answers one of those from the record name's index, which
        // the development schema never builds; a custom field's index it builds on first save.
        try await database.query(RecordQuery(type: Device.recordType, filters: [
            .init("seenAt", .greaterThan, .date(.distantPast)),
        ]))
            .compactMap(Device.init(record:))
            .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
    }

    /// Updates `seenAt` on a device's record.
    public func touch(_ id: DeviceID, at now: Date) async throws {
        _ = try await update(id) { $0.seenAt = now }
    }

    /// The scanner's half of pairing: checks the code against the record it
    /// names and lists each device in the other's `pairedWith`, both records
    /// in one atomic save, so the pairing is on both sides or on neither.
    /// Returns the scanned device's record.
    public func pair(_ code: PairingCode, as me: DeviceID) async throws -> Device {
        guard code.device != me else { throw PairingError.selfPairing }
        for _ in 0..<5 {
            let records = try await database.fetch([Device.recordID(for: code.device), Device.recordID(for: me)])
            guard let otherRecord = records[Device.recordID(for: code.device)],
                  var other = Device(record: otherRecord) else { throw PairingError.unknownDevice(code.device) }
            guard other.publicKey == code.publicKey else { throw PairingError.keyMismatch(code.device) }
            guard let mineRecord = records[Device.recordID(for: me)],
                  var mine = Device(record: mineRecord) else { throw PairingError.unknownDevice(me) }
            if other.isPaired(with: me), mine.isPaired(with: code.device) { return other }
            if !mine.pairedWith.contains(code.device) { mine.pairedWith.append(code.device) }
            if !other.pairedWith.contains(me) { other.pairedWith.append(me) }
            do {
                let saved = try await database.save([mine.record(changeTag: mineRecord.changeTag),
                                                     other.record(changeTag: otherRecord.changeTag)])
                return saved.last.flatMap(Device.init(record:)) ?? other
            } catch RecordDatabaseError.serverRecordChanged {
                continue
            }
        }
        throw PairingError.contended
    }

    /// Compare-and-set on one device record, retried while it moves.
    private func update(_ id: DeviceID, _ change: (inout Device) -> Void) async throws -> Device {
        for _ in 0..<5 {
            guard let record = try await database.fetch(Device.recordID(for: id)),
                  var device = Device(record: record) else { throw PairingError.unknownDevice(id) }
            change(&device)
            do {
                let saved = try await database.save(device.record(changeTag: record.changeTag))
                return Device(record: saved) ?? device
            } catch RecordDatabaseError.serverRecordChanged {
                continue
            }
        }
        throw PairingError.contended
    }
}
