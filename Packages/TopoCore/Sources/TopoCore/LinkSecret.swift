import Foundation

/// The secret every device on the Apple ID shares and a stranger on the LAN does not: thirty-two
/// random bytes in the private database, record `link/secret`, created once by whichever
/// device asks first (a create-only save, so two asking together get the one). A live turn over
/// the socket carries a MAC under it, which proves the asker can read this person's private
/// database, the same trust the pairing token rests on. It is not a pairing: it says "one of
/// this person's devices", not which.
public struct LinkSecret: Hashable, Sendable {
    public static let recordType = "LinkSecret"
    public static let recordID = RecordID("link/secret")

    public let bytes: Data

    public init(bytes: Data) {
        self.bytes = bytes
    }

    public init?(record: Record) {
        guard record.type == LinkSecret.recordType, let encoded = record.string("secret"),
              let bytes = Data(base64Encoded: encoded), bytes.count == 32 else { return nil }
        self.init(bytes: bytes)
    }

    var record: Record {
        Record(type: LinkSecret.recordType, id: LinkSecret.recordID, fields: ["secret": .string(bytes.base64EncodedString())])
    }

    /// The secret, made if there is none. Two devices making one together get the same one:
    /// the loser of the create-only save reads the winner's.
    public static func ensure(in database: any RecordDatabase, random: () -> Data = { random32() }) async throws -> LinkSecret {
        if let record = try await database.fetch(recordID), let secret = LinkSecret(record: record) { return secret }
        let fresh = LinkSecret(bytes: random())
        do {
            _ = try await database.save(fresh.record)
            return fresh
        } catch RecordDatabaseError.serverRecordChanged(_, let server) {
            guard let secret = LinkSecret(record: server) else { throw LinkSecretError.unreadable }
            return secret
        }
    }

    /// The secret as the database holds it, or nil when none has been made.
    public static func read(from database: any RecordDatabase) async throws -> LinkSecret? {
        try await database.fetch(recordID).flatMap(LinkSecret.init(record:))
    }

    public static func random32() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }
}

public enum LinkSecretError: Error, Sendable {
    /// A record exists under the secret's name and does not parse.
    case unreadable
}
