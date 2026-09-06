import Foundation
import Network
import TopoCore

/// The wire form of a live turn, on the same listener as the lease probe: one request line,
/// one reply. `answer <device>/<sequence>\n` names a person's turn already in the log and asks
/// the listener, if it is primary, to answer it now. The listener replies
/// `reply <device>/<sequence> <byteCount>\n` naming the reply's own turn, followed by exactly
/// `byteCount` bytes of UTF-8, the reply's text; or `no\n` when it is not primary or cannot.
/// CloudKit is truth: the reply lands in the log as it always does, and this only makes it
/// arrive at once. Anything else, or silence, is no.
///
/// The body is transcript content sent to any LAN client that can spell a ref, where `hold`
/// leaks nothing. Before TestFlight `answer` is to be gated on pairing, challenging against the
/// `Device` record's public key.
enum TurnWire {
    /// The most a reply body may be; a count above this is refused before anything is allocated.
    static let maximumBody = 1 << 20

    static func request(_ ref: TurnRef) -> Data {
        Data("answer \(ref)\n".utf8)
    }

    static func parseRequest(_ line: String) -> TurnRef? {
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 2, parts[0] == "answer" else { return nil }
        return TurnRef(parsing: String(parts[1]))
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
/// turn now. The reply's ref and text, or nil: not primary, unreachable, silent past the
/// timeout, or garbage. A model call takes tens of seconds, so the timeout is minutes, not the
/// probe's two seconds; the caller loses nothing on nil, since the log's own path answers the
/// turn anyway.
public struct SocketTurnClient: Sendable {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    public func ask(_ endpoint: String, toAnswer ref: TurnRef) async -> LiveReply? {
        guard let (host, port) = SocketLeaseProbe.parse(endpoint) else { return nil }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let deadline = Task { [timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            connection.cancel()
        }
        defer {
            deadline.cancel()
            connection.cancel()
        }
        connection.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.turn"))
        guard (try? await connection.waitUntilReady()) != nil,
              (try? await connection.send(TurnWire.request(ref))) != nil,
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
