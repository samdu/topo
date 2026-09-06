import CryptoKit
import Foundation
import Network
import TopoCore

/// The wire form of a live turn, on the same listener as the lease probe: one request line,
/// one reply. `answer <device>/<sequence> <asker> <nonce> <mac>\n` names a person's turn
/// already in the log and asks the listener, if it is primary, to answer it now; `mac` is the
/// hex HMAC-SHA256, under the Apple ID's link secret (`LinkSecret` in the private database), of
/// the line before it, so only one of this person's devices can ask, and a stranger on the LAN
/// who can spell a ref gets `no`. The listener replies `reply <device>/<sequence> <byteCount>\n`
/// naming the reply's own turn, followed by exactly `byteCount` bytes of UTF-8, the reply's
/// text; or `no\n` when the MAC is wrong, it is not primary, or it cannot. CloudKit is truth:
/// the reply lands in the log as it always does, and this only makes it arrive at once.
/// Anything else, or silence, is no. A captured request replayed yields the same reply to the
/// same turn and nothing else; the nonce keeps two asks apart, it is not a replay guard.
enum TurnWire {
    /// The most a reply body may be; a count above this is refused before anything is allocated.
    static let maximumBody = 1 << 20

    struct Request: Hashable {
        var ref: TurnRef
        var asker: DeviceID
        var nonce: String
        var mac: String

        var signed: String { "answer \(ref) \(asker.rawValue) \(nonce)" }

        func verifies(with secret: Data) -> Bool {
            let expected = TurnWire.mac(of: signed, secret: secret)
            // Constant time, so a wrong MAC's failure says nothing about how wrong.
            guard expected.utf8.count == mac.utf8.count else { return false }
            var differ: UInt8 = 0
            for (a, b) in zip(expected.utf8, mac.utf8) { differ |= a ^ b }
            return differ == 0
        }
    }

    static func request(_ ref: TurnRef, from asker: DeviceID, secret: Data) -> Data {
        let signed = "answer \(ref) \(asker.rawValue) \(UUID().uuidString)"
        return Data("\(signed) \(mac(of: signed, secret: secret))\n".utf8)
    }

    static func parseRequest(_ line: String) -> Request? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 5, parts[0] == "answer", let ref = TurnRef(parsing: String(parts[1])),
              !parts[2].isEmpty, !parts[3].isEmpty, parts[4].count == 64 else { return nil }
        return Request(ref: ref, asker: DeviceID(String(parts[2])), nonce: String(parts[3]), mac: String(parts[4]))
    }

    static func mac(of message: String, secret: Data) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: secret))
        return code.map { String(format: "%02x", $0) }.joined()
    }

    static func reply(_ ref: TurnRef, _ text: String) -> Data {
        let body = Data(text.utf8)
        return Data("reply \(ref) \(body.count)\n".utf8) + body
    }

    /// The reply line: the reply's ref and how many bytes follow. Nil for `no` or anything else.
    static func parseReplyLine(_ line: String) -> (TurnRef, Int)? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 3, parts[0] == "reply", let ref = TurnRef(parsing: String(parts[1])),
              let count = Int(parts[2]), count >= 0, count <= maximumBody else { return nil }
        return (ref, count)
    }
}

/// A reply as it comes back over the wire: the reply turn's ref, and its text.
public struct LiveReply: Hashable, Sendable {
    public var ref: TurnRef
    public var text: String

    public init(ref: TurnRef, text: String) {
        self.ref = ref
        self.text = text
    }
}

/// Asks a primary, at the `host:port` its lease or device record names, to answer a person's
/// turn now, as `asker`, under the link secret. The reply's ref and text, or nil: not primary,
/// unreachable, silent past the timeout, or garbage. Connecting has a deadline of seconds, so a
/// stale address that swallows the packets costs little; the reply has minutes, since a model
/// call takes tens of seconds. The caller loses nothing on nil: the log's own path answers the
/// turn anyway.
public struct SocketTurnClient: Sendable {
    public var connectTimeout: TimeInterval
    public var timeout: TimeInterval

    public init(connectTimeout: TimeInterval = 3, timeout: TimeInterval = 120) {
        self.connectTimeout = connectTimeout
        self.timeout = timeout
    }

    public func ask(_ endpoint: String, toAnswer ref: TurnRef, as asker: DeviceID, secret: Data) async -> LiveReply? {
        guard let (host, port) = SocketLeaseProbe.parse(endpoint) else { return nil }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let connecting = Task { [connectTimeout] in
            try? await Task.sleep(for: .seconds(connectTimeout))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.turn"))
        guard (try? await connection.waitUntilReady()) != nil else { connecting.cancel(); return nil }
        connecting.cancel()
        let deadline = Task { [timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer { deadline.cancel() }
        guard (try? await connection.send(TurnWire.request(ref, from: asker, secret: secret))) != nil,
              let (line, rest) = try? await connection.readLineKeepingRest(maximum: 256),
              let (replyRef, count) = TurnWire.parseReplyLine(line),
              let body = try? await connection.readExactly(count, startingWith: rest) else { return nil }
        return LiveReply(ref: replyRef, text: String(decoding: body, as: UTF8.self))
    }
}

extension NWConnection {
    /// Reads until a newline, however TCP splits it, and returns the line without its newline
    /// and whatever arrived after it, which belongs to the body that follows.
    func readLineKeepingRest(maximum: Int) async throws -> (String, Data) {
        var buffer = Data()
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return (String(decoding: buffer[..<newline], as: UTF8.self), Data(buffer[buffer.index(after: newline)...]))
            }
            guard buffer.count < maximum else { throw ProbeWire.LineTooLong() }
            let (chunk, complete) = try await receiveSome(maximum: maximum - buffer.count)
            if let chunk { buffer.append(chunk) }
            if complete, !buffer.contains(UInt8(ascii: "\n")) { throw TurnWire.BodyCutShort() }
        }
    }

    /// Reads exactly `count` bytes, however TCP splits them, `rest` being what an earlier read
    /// already took past its line. Zero bytes is an empty body.
    func readExactly(_ count: Int, startingWith rest: Data = Data()) async throws -> Data {
        var buffer = rest
        buffer.reserveCapacity(count)
        if buffer.count > count { throw TurnWire.BodyCutShort() }
        while buffer.count < count {
            let (chunk, complete) = try await receiveSome(maximum: count - buffer.count)
            if let chunk { buffer.append(chunk) }
            if complete, buffer.count < count { throw TurnWire.BodyCutShort() }
        }
        return buffer
    }
}

extension TurnWire {
    struct BodyCutShort: Error {}
}
