import Foundation
import Network
import TopoCore

/// The phone's word to the hub that holds the lease: the log moved. One `moved` line over the
/// hub's channel (`NudgeTLS`, at the host the lease record names and the port its key's record
/// names, `ProbeWire`), held open until the hub answers: `read` once the pass that read the log
/// after the nudge has ended, when the reply it wrote (if it wrote one) is in the log for the
/// phone to read now.
///
/// It is only ever a hint. It carries the lease it is for and the turn's mark, no words, and
/// nothing waits on it: with no answer the poll and the push bring the same turn and the same
/// reply, a few seconds later. Every way it can fail is `unreached`, a hub with no key among them.
/// Asked to, the hub streams the reply down the same connection before it answers (`ReplyFrame`);
/// what is streamed is provisional, and the log's reply replaces it. The channel is sealed and
/// both ends prove they hold the hub's key, which only the devices on the Apple ID can read
/// (`NudgeKey`), so nothing else on the network reads a frame, sends a nudge or poses as the hub.
public enum HubNudge {
    public enum Answer: Equatable, Sendable {
        /// The hub's pass has ended: read the log.
        case read
        /// The hub has no pass to run for this lease, or too many nudges waiting.
        case no
        /// No answer: no key, the endpoint could not be reached, the handshake failed, the
        /// connection closed, or said nothing in time. The kind of failure, for a mark.
        case unreached(String)
    }

    /// How long the connection is given to be made, the channel's handshake included: a LAN
    /// round trip is milliseconds, and a phone off the hub's network fails at once or waits here.
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

    /// Says the log moved to the holder of `lease`, with the hub's key as `keys` has it from
    /// `database`, once `reachable` says the hub's host may be asked (the app's local network
    /// gate; false sends nothing). A hub with no key record is sent nothing (`noKey`), and a
    /// record that cannot be read likewise (`keyUnread`), with a mark that says why; a handshake
    /// the hub refused drops the phone's copy of the key, so the next nudge reads the record
    /// again (a hub that launched since minted another), and so does a handshake still under way at
    /// the bound, and a connect that failed or ran out (a hub that launched since listens on another
    /// port): after a connect the endpoint is not tried for `Unreached.forgetAfter`, so a hub off
    /// the network costs a read of its record at most once in that while.
    public static func send(for lease: Lease, mark: String, keys: NudgeKeys, in database: any RecordDatabase,
                            reachable: @Sendable (_ host: String, _ port: UInt16) async -> Bool = { _, _ in true },
                            stream: (@Sendable (ReplyFrame) async -> Void)? = nil) async -> Answer {
        guard let endpoint = lease.endpoint, let (host, _) = hostAndPort(endpoint) else { return .unreached("noEndpoint") }
        if Unreached.shared.recently(endpoint) { return .unreached("recently") }
        let key: NudgeKey
        switch await keys.key(for: lease, in: database) {
        case .key(let found, let read):
            Perf.mark("nudge.key \(read ? "read" : "kept")")
            key = found
        case .none:
            Perf.mark("nudge.key none")
            return .unreached("noKey")
        case .unread(let kind):
            Perf.mark("nudge.key unread \(kind)")
            return .unreached("keyUnread")
        }
        guard await reachable(host, key.port) else { return .unreached("gated") }
        let answer = await send(for: lease, mark: mark, key: key, stream: stream)
        if case .unreached(let kind) = answer, dropsKey(kind) { await keys.failed(key) }
        return answer
    }

    /// Whether a connection that failed this way drops the phone's copy of the key: a handshake
    /// the hub refused or that did not agree (a hub launched since minted another), one still under
    /// way at the bound, and a connect that failed or ran out (a hub launched since listens on
    /// another port). A nudge and a heads-up drop it alike.
    static func dropsKey(_ kind: String) -> Bool {
        ["handshake", "agreement", "handshakeTimeout", "connect", "connectTimeout"].contains(kind)
    }

    /// Says the log moved to the holder of `lease` over the channel `key` opens, and waits for its
    /// answer. With `stream`, asks for the reply to the turn `mark` names as the hub's mind writes
    /// it, and hands it each frame in order as it arrives, ahead of the answer; a line that is no
    /// frame is passed over. A connect that failed within `connectBound` is remembered for this
    /// endpoint (`Unreached`), and the next nudge to it within that while is answered `unreached`
    /// at once; a refused handshake is not, since the hub was reached, and nor is a handshake
    /// still under way at the bound over a TCP connection that was made (`handshakeTimeout`,
    /// told by `TCPReached` beneath the channel's TLS).
    static func send(for lease: Lease, mark: String, key: NudgeKey, connectBound: TimeInterval = connectBound,
                     answerBound: TimeInterval = answerBound,
                     stream: (@Sendable (ReplyFrame) async -> Void)? = nil) async -> Answer {
        guard let endpoint = lease.endpoint, let (host, _) = SocketLeaseProbe.parse(endpoint) else {
            return .unreached("noEndpoint")
        }
        guard key.hub == lease.holder, let port = NWEndpoint.Port(rawValue: key.port), key.port != 0 else {
            return .unreached("noKey")
        }
        guard ProbeWire.isMark(Substring(mark)) else { return .unreached("badMark") }
        if Unreached.shared.recently(endpoint) { return .unreached("recently") }
        let stage = Stage()
        let parameters = NudgeTLS.parameters(key)
        parameters.defaultProtocolStack.applicationProtocols.append(TCPReached.options(telling: stage))
        let connection = NWConnection(host: host, port: port, using: parameters)
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
                let kind = Self.kind(error, connection, stage)
                // A connect that failed or ran out, off the hub's network: not tried again for a
                // while. Local network access refused is the gate's, not the network's, and a
                // refused handshake is the key's.
                if kind == "connect" || kind == "connectTimeout" { Unreached.shared.failed(endpoint) }
                return .unreached(kind)
            }
            // What the handshake agreed, not what was asked for, admits the hub.
            guard NudgeTLS.agreed(connection) else { return .unreached("agreement") }
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
            return await answer(NWConnection.Lines(connection), stream: stream)
        } onCancel: {
            connection.cancel()
        }
    }

    /// The hub's answer to a nudge on `lines`, with the frames of a streamed reply handed to
    /// `stream` ahead of it; a line that is no frame is passed over while streaming.
    static func answer(_ lines: NWConnection.Lines, stream: (@Sendable (ReplyFrame) async -> Void)?) async -> Answer {
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
    }

    /// A heads-up to the hub that holds `lease`: the person's turn under `mark` is being saved now
    /// (`ProbeWire`'s `coming`), so the hub's pass gets ready for it while the phone's save is out.
    /// Begun with nothing awaited by its caller, it reads no record and asks for nothing: the key
    /// is the one already kept for the lease's epoch (`NudgeKeys.kept(for:)`), and a phone with
    /// none sends nothing. It carries the lease and the mark, never a word. Once the turn is saved,
    /// `saved` says its ref down the same connection, which the hub then answers as a nudge; a
    /// heads-up the hub did not take, or one whose connection went, is nil there, and the nudge
    /// goes the usual way. `cancel` closes it, which ends the hub's wait for the turn at once.
    public final class Coming: @unchecked Sendable {
        public let lease: Lease
        public let mark: String
        private let lock = NSLock()
        private var connection: NWConnection?
        private var cancelled = false
        private var lines: NWConnection.Lines?
        private var opening: Task<Bool, Never>?

        /// How long the hub is given to answer the heads-up once the line is sent: it answers at once.
        public static let answerBound: TimeInterval = 2

        init(lease: Lease, mark: String) {
            self.lease = lease
            self.mark = mark
        }

        /// Opens the heads-up for the turn `mark` names to the holder of `lease`, with the key
        /// `keys` already keeps for it. Returns at once; the connection is made in a task of its own.
        public static func begin(for lease: Lease, mark: String, keys: NudgeKeys,
                                 connectBound: TimeInterval = HubNudge.connectBound,
                                 answerBound: TimeInterval = Coming.answerBound) -> Coming {
            let coming = Coming(lease: lease, mark: mark)
            let opening = Task { await coming.open(keys: keys, connectBound: connectBound, answerBound: answerBound) }
            coming.lock.withLock { coming.opening = opening }
            return coming
        }

        private func open(keys: NudgeKeys, connectBound: TimeInterval, answerBound: TimeInterval) async -> Bool {
            guard let key = await keys.kept(for: lease) else {
                Perf.mark("turn.coming.skipped turn=\(mark) noKey")
                return false
            }
            let answer = await opening(key, connectBound: connectBound, answerBound: answerBound)
            switch answer {
            case .read:
                Perf.mark("turn.coming.answer turn=\(mark) ready")
                return true
            case .no:
                Perf.mark("turn.coming.answer turn=\(mark) no")
            case .unreached(let kind):
                if Self.skips(kind) {
                    Perf.mark("turn.coming.skipped turn=\(mark) \(kind)")
                } else {
                    Perf.mark("turn.coming.answer turn=\(mark) unreached \(kind)")
                    if dropsKey(kind) { await keys.failed(key) }
                }
            }
            close()
            return false
        }

        /// Kinds that mean nothing was sent for a reason known before the connection was made.
        private static func skips(_ kind: String) -> Bool { ["noEndpoint", "noKey", "badMark", "recently", "cancelled"].contains(kind) }

        /// Connects, sends `coming` and reads the hub's answer: `read` stands for `ready`.
        private func opening(_ key: NudgeKey, connectBound: TimeInterval, answerBound: TimeInterval) async -> Answer {
            guard let endpoint = lease.endpoint, let (host, _) = SocketLeaseProbe.parse(endpoint) else {
                return .unreached("noEndpoint")
            }
            guard key.hub == lease.holder, let port = NWEndpoint.Port(rawValue: key.port), key.port != 0 else {
                return .unreached("noKey")
            }
            guard ProbeWire.isMark(Substring(mark)) else { return .unreached("badMark") }
            if Unreached.shared.recently(endpoint) { return .unreached("recently") }
            let stage = Stage()
            let parameters = NudgeTLS.parameters(key)
            parameters.defaultProtocolStack.applicationProtocols.append(TCPReached.options(telling: stage))
            let connection = NWConnection(host: host, port: port, using: parameters)
            guard lock.withLock({ () -> Bool in
                guard !cancelled else { return false }
                self.connection = connection
                return true
            }) else { return .unreached("cancelled") }
            // Each bound cancels the connection, which fails whichever step is pending.
            let connecting = Task {
                try? await Task.sleep(for: .seconds(connectBound))
                if stage.isConnecting { connection.cancel() }
            }
            defer { connecting.cancel() }
            connection.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.coming"))
            do {
                try await connection.waitUntilReady()
            } catch {
                let kind = HubNudge.kind(error, connection, stage)
                if lock.withLock({ cancelled }) { return .unreached("cancelled") }
                if kind == "connect" || kind == "connectTimeout" { Unreached.shared.failed(endpoint) }
                return .unreached(kind)
            }
            guard NudgeTLS.agreed(connection) else { return .unreached("agreement") }
            stage.connected()
            Unreached.shared.reached(endpoint)
            guard (try? await connection.send(ProbeWire.coming(lease, mark: mark))) != nil else { return .unreached("send") }
            Perf.mark("turn.coming.sent turn=\(mark)")
            let answering = Task {
                try? await Task.sleep(for: .seconds(answerBound))
                if !self.lock.withLock({ self.answered }) { connection.cancel() }
            }
            defer { answering.cancel() }
            let lines = NWConnection.Lines(connection)
            guard let line = try? await lines.next(maximum: 16) else { return .unreached("answer") }
            lock.withLock { answered = true; self.lines = lines }
            switch line.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "ready": return .read
            case "no": return .no
            default: return .unreached("answer")
            }
        }
        private var answered = false

        /// The turn is saved as `ref`: said down the heads-up's connection, and the hub's answer
        /// to it as a nudge's, the reply's frames handed to `stream` ahead of it. Nil when the hub
        /// did not take the heads-up or the line could not be sent: the nudge goes the usual way.
        public func saved(_ ref: TurnRef, answerBound: TimeInterval = HubNudge.answerBound,
                          stream: (@Sendable (ReplyFrame) async -> Void)?) async -> Answer? {
            guard let opening = lock.withLock({ self.opening }), await opening.value,
                  let (connection, lines) = lock.withLock({ () -> (NWConnection, NWConnection.Lines)? in
                      guard !cancelled, let connection, let lines else { return nil }
                      return (connection, lines)
                  }) else { return nil }
            guard (try? await connection.send(ProbeWire.saved(ref, stream: stream != nil))) != nil else {
                close()
                return nil
            }
            Perf.mark("nudge.sent")
            let answering = Task {
                try? await Task.sleep(for: .seconds(answerBound))
                connection.cancel()
            }
            defer {
                answering.cancel()
                close()
            }
            return await withTaskCancellationHandler {
                await HubNudge.answer(lines, stream: stream)
            } onCancel: {
                connection.cancel()
            }
        }

        /// Closes the heads-up: the hub's wait for its turn ends, and `saved` is nil from now.
        public func cancel() {
            let opening = lock.withLock { () -> Task<Bool, Never>? in
                cancelled = true
                return self.opening
            }
            opening?.cancel()
            close()
        }

        private func close() {
            lock.withLock { connection }?.cancel()
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
    /// the one a person can change, and a handshake the hub refused, since that is the key.
    static func kind(_ error: any Error, _ connection: NWConnection, _ stage: Stage) -> String {
        if connection.currentPath?.unsatisfiedReason == .localNetworkDenied { return "localNetworkDenied" }
        if error is CancellationError { return stage.tcpReached ? "handshakeTimeout" : "connectTimeout" }
        if case .tls? = error as? NWError { return "handshake" }
        return "connect"
    }

    final class Stage: @unchecked Sendable {
        private let lock = NSLock()
        private var made = false, tcp = false
        var isConnecting: Bool { lock.withLock { !made } }
        func connected() { lock.withLock { made = true } }
        /// Whether TCP connected beneath the channel's handshake (`TCPReached`).
        var tcpReached: Bool { lock.withLock { tcp } }
        func reachedTCP() { lock.withLock { tcp = true } }
    }
}

/// A framer beneath the channel's TLS that hands every byte through untouched and tells the nudge
/// when TCP has connected: Network.framework starts a framer once the protocol below it is ready,
/// and the connection's state says nothing of that until the handshake above has finished. A
/// connect bound that runs out after it is a hub reached whose handshake was slow, not a hub off
/// the network.
final class TCPReached: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: TCPReached.self)
    static let label = "zone.hexagon.topo.tcp-reached"
    private static let stageKey = "stage"

    /// The framer's options for one connection, telling `stage`.
    static func options(telling stage: HubNudge.Stage) -> NWProtocolFramer.Options {
        let options = NWProtocolFramer.Options(definition: definition)
        options[stageKey] = stage
        return options
    }

    init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        (framer.options[Self.stageKey] as? HubNudge.Stage)?.reachedTCP()
        framer.passThroughInput()
        framer.passThroughOutput()
        return .ready
    }

    func handleInput(framer: NWProtocolFramer.Instance) -> Int { 0 }
    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message, messageLength: Int, isComplete: Bool) {}
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
