import Foundation
import Network
import Security
import TopoCore

/// The secret a hub and the devices on its Apple ID share for the nudge's channel (`HubNudge`,
/// `docs/hub.md`, *The channel*): 32 random bytes the hub mints at each launch and keeps in a
/// record of its own in the private zone, `nudge-key/<hub>`, with the name the key goes by on the
/// wire (`identity`, sixteen hex digits, the TLS pre-shared key's identity) and the port of the
/// listener that takes it. Only the Apple ID reads the zone, so only its devices can open the
/// channel or be answered on it. Nothing prints the secret: its description and its mirror name
/// the identity alone.
public struct NudgeKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public static let recordType = "NudgeKey"
    public static func recordID(for hub: DeviceID) -> RecordID { RecordID("nudge-key/\(hub.rawValue)") }
    /// The secret's length in bytes.
    static let secretLength = 32

    public let hub: DeviceID
    /// The key's name on the wire, sent in the clear in the handshake.
    public let identity: String
    let secret: Data
    /// The secure listener's port; 0 until it is bound.
    public let port: UInt16

    init(hub: DeviceID, identity: String, secret: Data, port: UInt16) {
        self.hub = hub
        self.identity = identity
        self.secret = secret
        self.port = port
    }

    /// A fresh key for `hub`, from the system's secure generator.
    public static func mint(hub: DeviceID) -> NudgeKey {
        NudgeKey(hub: hub, identity: random(8).map { String(format: "%02x", $0) }.joined(),
                 secret: random(secretLength), port: 0)
    }

    private static func random(_ count: Int) -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        precondition(status == errSecSuccess, "the system's random generator failed")
        return bytes
    }

    /// The same key, at the port its listener was bound to.
    public func on(port: UInt16) -> NudgeKey { NudgeKey(hub: hub, identity: identity, secret: secret, port: port) }

    public var description: String { "NudgeKey(\(identity))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["hub": hub, "identity": identity, "port": port]) }

    /// A record that is not a whole key — another type, another hub's name, a secret of the wrong
    /// length, an identity that is not sixteen hex digits, no port — is no key.
    public init?(record: Record) {
        guard record.type == Self.recordType,
              let hub = record.string("hub").map({ DeviceID($0) }), record.id == Self.recordID(for: hub),
              let identity = record.string("identity"), Self.isIdentity(identity),
              let encoded = record.string("secret"), let secret = Data(base64Encoded: encoded), secret.count == Self.secretLength,
              let port = record.int("port"), (1...Int64(UInt16.max)).contains(port) else { return nil }
        self.init(hub: hub, identity: identity, secret: secret, port: UInt16(port))
    }

    static func isIdentity(_ identity: String) -> Bool {
        identity.count == 16 && identity.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    func record(changeTag: String?) -> Record {
        Record(type: Self.recordType, id: Self.recordID(for: hub), fields: [
            "hub": .string(hub.rawValue),
            "identity": .string(identity),
            "secret": .string(secret.base64EncodedString()),
            "port": .int(Int64(port)),
            "mintedAt": .date(Date()),
        ], changeTag: changeTag)
    }

    /// Writes this key over the hub's record, whatever it held: the hub is its only writer.
    public func save(to database: any RecordDatabase) async throws {
        for _ in 0..<3 {
            let current = try await database.fetch(Self.recordID(for: hub))
            do {
                _ = try await database.save(record(changeTag: current?.changeTag))
                return
            } catch RecordDatabaseError.serverRecordChanged {
                continue
            }
        }
        throw Contended()
    }

    /// Three saves in a row lost to another writer of the record.
    public struct Contended: Error {}

    /// A read's or a save's failure by kind, for a mark or a log line: an error's description can
    /// carry the record it was about, and this record is the secret.
    public static func kind(of error: any Error) -> String {
        switch error {
        case RecordDatabaseError.unavailable: "unavailable"
        case RecordDatabaseError.rejected: "rejected"
        case RecordDatabaseError.serverRecordChanged, is Contended: "contended"
        case RecordDatabaseError.unknownItem: "unknownItem"
        case is CancellationError: "cancelled"
        default: "other"
        }
    }

    /// The hub's key as its record holds it: nil when there is none, or what is there is not a key.
    public static func read(for hub: DeviceID, from database: any RecordDatabase) async throws -> NudgeKey? {
        try await database.fetch(recordID(for: hub)).flatMap(NudgeKey.init(record:))
    }
}

/// The channel's TLS: TLS 1.2 with the key as its pre-shared key, in the one suite
/// `ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (RFC 7905), so each connection's keys come from an
/// ephemeral exchange the pre-shared key authenticates, both ends prove they hold the key in the
/// handshake's Finished messages, and every record is sealed and numbered. No certificate is
/// made or read. Not TLS 1.3: Network.framework completed no TLS 1.3 handshake on a pre-shared key
/// alone on macOS 27.2. What is configured is not taken as what was agreed (a suite asked for
/// alone has finished as another): each end reads the version and suite off the finished
/// handshake (`agreed`) and drops a connection that is anything else before a line is sent or
/// read.
enum NudgeTLS {
    static let version = tls_protocol_version_t.TLSv12
    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256.
    static let suite: UInt16 = 0xCCAC

    /// `suites` is the one suite but in the suites, which offer another to see it refused.
    static func parameters(_ key: NudgeKey, suites: [UInt16] = [suite]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_add_pre_shared_key(options, dispatchData(key.secret), dispatchData(Data(key.identity.utf8)))
        for suite in suites { sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: suite)!) }
        sec_protocol_options_set_min_tls_protocol_version(options, version)
        sec_protocol_options_set_max_tls_protocol_version(options, version)
        // A peer that offers a certificate is not the hub's key: refused, never evaluated.
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(false) },
                                              DispatchQueue(label: "zone.hexagon.topo.link.verify"))
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    /// Whether the connection's finished handshake is the version and suite the channel is.
    static func agreed(_ connection: NWConnection) -> Bool {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else { return false }
        let security = metadata.securityProtocolMetadata
        return sec_protocol_metadata_get_negotiated_tls_protocol_version(security) == version
            && sec_protocol_metadata_get_negotiated_tls_ciphersuite(security).rawValue == suite
    }

    private static func dispatchData(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}

/// The phone's copy of each hub's key, read from the hub's record once per lease epoch: a hub's
/// every start takes the lease at a new epoch, and a key is minted only at a launch, so a key read
/// under an epoch is the key of the launch that holds it. A handshake that failed drops the copy,
/// and the next nudge reads the record again.
public actor NudgeKeys {
    public static let shared = NudgeKeys()
    /// How long the record's read is given.
    public static let readBound: TimeInterval = 2

    public enum Lookup: Equatable, Sendable {
        case key(NudgeKey, read: Bool)
        /// The hub has no key record, or what it holds is not a key: a hub built before the channel.
        case none
        /// The record could not be read, by kind of failure.
        case unread(String)
    }

    private var kept: [DeviceID: (epoch: Int64, key: NudgeKey)] = [:]

    public init() {}

    public func key(for lease: Lease, in database: any RecordDatabase) async -> Lookup {
        if let kept = kept[lease.holder], kept.epoch == lease.epoch { return .key(kept.key, read: false) }
        do {
            // The record is read under the holder's name, and a key is one only of the hub it names.
            guard let key = try await NudgeKey.read(for: lease.holder, from: database.answering(within: Self.readBound)) else {
                kept[lease.holder] = nil
                return .none
            }
            kept[lease.holder] = (lease.epoch, key)
            return .key(key, read: true)
        } catch {
            return .unread(NudgeKey.kind(of: error))
        }
    }

    /// The copy of `key` is dropped, if it is still the one kept.
    public func failed(_ key: NudgeKey) {
        if kept[key.hub]?.key.identity == key.identity { kept[key.hub] = nil }
    }
}
