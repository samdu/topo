import Foundation
import Network
import TopoCore

/// The phone's word to the hub that holds the lease: the log moved. One `moved` line over TCP to
/// the endpoint the lease record names (`ProbeWire`), held open until the hub answers: `read`
/// once the pass that read the log after the nudge has ended, when the reply it wrote (if it
/// wrote one) is in the log for the phone to read now.
///
/// It is only ever a hint. It carries the lease it is for and the turn's mark, no words and
/// nothing secret, and nothing waits on it: with no answer the poll and the push bring the same
/// turn and the same reply, a few seconds later. Every way it can fail is `unreached`. Asked to,
/// the hub streams the reply down the same connection before it answers (`ReplyFrame`); what is
/// streamed is provisional, and the log's reply replaces it.
public enum HubNudge {
    public enum Answer: Equatable, Sendable {
        /// The hub's pass has ended: read the log.
        case read
        /// The hub has no pass to run for this lease, or too many nudges waiting.
        case no
        /// No answer: the endpoint could not be reached, closed, or said nothing in time. The
        /// kind of failure, for a mark.
        case unreached(String)
    }

    /// How long the connection is given to be made: a LAN round trip is milliseconds, and a phone
    /// off the hub's network fails at once or waits here.
    public static let connectBound: TimeInterval = 2
    /// How long the answer is waited for: a pass is the model's whole turn.
    public static let answerBound: TimeInterval = 600

    /// The host and port of a lease's endpoint (`host:port` or `[v6]:port`), for the app to ask
    /// for local network access to.
    public static func hostAndPort(_ endpoint: String) -> (host: String, port: UInt16)? {
        guard let (host, port) = SocketLeaseProbe.parse(endpoint) else { return nil }
        return ("\(host)", port.rawValue)
    }

    /// The longest line of a streamed reply: one frame, a few characters of words as JSON.
    static let frameMaximum = 65_536

    /// Says the log moved to the holder of `lease`, at its endpoint, and waits for its answer.
    /// With `stream`, asks for the reply to the turn `mark` names as the hub's mind writes it, and
    /// hands it each frame in order as it arrives, ahead of the answer; a line that is no frame is
    /// passed over. A connect that failed within `connectBound` is remembered for this endpoint
    /// (`Unreached`), and the next nudge to it within that while is answered `unreached` at once.
    public static func send(for lease: Lease, mark: String, connectBound: TimeInterval = connectBound,
                            answerBound: TimeInterval = answerBound,
                            stream: (@Sendable (ReplyFrame) async -> Void)? = nil) async -> Answer {
        guard let endpoint = lease.endpoint, let (host, port) = SocketLeaseProbe.parse(endpoint) else {
            return .unreached("noEndpoint")
        }
        guard ProbeWire.isMark(Substring(mark)) else { return .unreached("badMark") }
        if Unreached.shared.recently(endpoint) { return .unreached("recently") }
        let connection = NWConnection(host: host, port: port, using: .tcp)
        let stage = Stage()
        // Each bound cancels the connection, which fails whichever step is pending.
        let connecting = Task {
            try? await Task.sleep(for: .seconds(connectBound))
            if stage.isConnecting { connection.cancel() }
        }
        // From the moment the line is sent.
        var answering: Task<Void, Never>?
        defer {
            connecting.cancel()
            answering?.cancel()
            connection.cancel()
        }
        return await withTaskCancellationHandler {
            connection.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.nudge"))
            do {
                try await connection.waitUntilReady()
            } catch {
                let kind = Self.kind(error, connection)
                // A connect that failed or ran out, off the hub's network: not tried again for a
                // while. Local network access refused is the gate's, not the network's.
                if kind == "connect" || kind == "connectTimeout" { Unreached.shared.failed(endpoint) }
                return .unreached(kind)
            }
            stage.connected()
            Unreached.shared.reached(endpoint)
            Perf.mark("nudge.connected")
            do {
                try await connection.send(ProbeWire.nudge(lease, mark: mark, stream: stream != nil))
            } catch {
                return .unreached("send")
            }
            Perf.mark("nudge.sent")
            answering = Task {
                try? await Task.sleep(for: .seconds(answerBound))
                connection.cancel()
            }
            let lines = NWConnection.Lines(connection)
            while true {
                guard let next = try? await lines.next(maximum: stream == nil ? 16 : frameMaximum),
                      let line = Optional(next.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return .unreached("answer")
                }
                switch line {
                case "read": return .read
                case "no": return .no
                default:
                    guard let stream, let frame = ReplyFrame(line: line) else {
                        if stream == nil { return .unreached("answer") }
                        continue
                    }
                    if Task.isCancelled { return .unreached("cancelled") }
                    await stream(frame)
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Connects that failed, by endpoint, for `Unreached.forgetAfter`: a phone off the hub's
    /// network (on cellular, on another Wi-Fi) pays the connect bound once a while rather than at
    /// every turn. A change of the phone's network, which a path monitor sees, forgets them all at
    /// once, so the first turn back on the LAN nudges; so does `forget()`, which the app calls as it
    /// comes to the front.
    public final class Unreached: @unchecked Sendable {
        public static let shared = Unreached()
        /// Sixty seconds.
        public static let forgetAfter: TimeInterval = 60

        private let lock = NSLock()
        private var failures: [String: TimeInterval] = [:]
        private let now: @Sendable () -> TimeInterval
        private var monitor: NWPathMonitor?
        private var lastPath: String?

        init(now: @escaping @Sendable () -> TimeInterval = PrimaryLease.continuousUptime, watchPath: Bool = true) {
            self.now = now
            guard watchPath else { return }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in self?.pathChanged(Self.describe(path)) }
            monitor.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.path"))
            self.monitor = monitor
        }

        /// The interfaces a path runs over and its status: what changes when the phone joins or
        /// leaves a network.
        static func describe(_ path: NWPath) -> String {
            "\(path.status) " + path.availableInterfaces.map { "\($0.name):\($0.type)" }.joined(separator: ",")
        }

        func pathChanged(_ path: String) {
            lock.withLock {
                if lastPath != nil, lastPath != path { failures = [:] }
                lastPath = path
            }
        }

        func recently(_ endpoint: String) -> Bool {
            lock.withLock {
                guard let at = failures[endpoint] else { return false }
                if now() - at < Self.forgetAfter { return true }
                failures[endpoint] = nil
                return false
            }
        }

        func failed(_ endpoint: String) { lock.withLock { failures[endpoint] = now() } }
        func reached(_ endpoint: String) { lock.withLock { failures[endpoint] = nil } }

        /// Every failure forgotten: the next nudge to each endpoint is tried.
        public func forget() { lock.withLock { failures = [:] } }
    }

    /// Why a connection was not made, by kind: denied local network access says so, since it is
    /// the one a person can change.
    private static func kind(_ error: any Error, _ connection: NWConnection) -> String {
        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { return "localNetworkDenied" }
        if error is CancellationError { return "connectTimeout" }
        return "connect"
    }

    private final class Stage: @unchecked Sendable {
        private let lock = NSLock()
        private var made = false
        var isConnecting: Bool { lock.withLock { !made } }
        func connected() { lock.withLock { made = true } }
    }
}
