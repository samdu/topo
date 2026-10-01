import Foundation
import Network
import os

/// The guest's name server: plain DNS in on `127.0.0.1`, over UDP and TCP at one port picked at
/// start, each question asked of the system resolver (`RecordResolver`, dnssd on the phone) and
/// the answer written back as a DNS reply. The guest reaches it at `127.0.0.53` port 53, which its
/// socket layer carries here. Whatever the phone's own lookups get — Private Relay, a VPN's
/// resolver and split DNS, a DNS profile — the guest gets; nothing is cached, and there is no
/// other upstream.
///
/// Loopback is not private — any process on the device can reach `127.0.0.1` — so what it answers
/// is only what the system resolver would answer that process itself, and everything is bounded:
/// a message over 512 bytes is dropped (a TCP connection closed) before it is read; at most 64
/// questions are in flight, and one past that is answered `SERVFAIL` without being asked; every
/// question is answered within 4 s of its arrival, `SERVFAIL` at the bound; at most 16 TCP
/// connections, each closed 10 s from its accept; a reply that does not fit 512 bytes over UDP (or the
/// query's EDNS size, at most 1232) goes back truncated with `TC` set, so the client asks again
/// over TCP, where a reply is at most 65,535. Only a query of one question, opcode `QUERY`, class
/// IN is asked; anything else is `FORMERR` or `NOTIMP`, asked of nobody.
///
/// It logs counts — at most one line every 60 s while there is traffic — and a line when it cannot
/// start or its listener or socket is lost, never a name, a type, an address, an answer or a
/// client's port.
///
/// UDP is a socket of its own bound to `127.0.0.1`, each reply sent to the address its question
/// came from; TCP is an `NWListener` required to the same address and port.
///
/// The actor runs on a serial queue of its own, which is also where the socket's reads, the
/// listener, its connections and dnssd call back, so every query is started, answered and deallocated there and
/// nothing blocks the cooperative pool.
public actor DNSForwarder {
    public typealias Log = @Sendable (String) -> Void

    public static let messageLimit = 512
    public static let inFlightLimit = 64
    public static let tcpConnectionLimit = 16
    public static let ednsLimit: UInt16 = 1232
    public static let tcpReplyLimit = 65_535
    public static let defaultQueryBound: Duration = .seconds(4)
    /// How long a negative dnssd answered from its cache waits for one from the network.
    public static let cachedNegativeGrace: Duration = .milliseconds(250)
    public static let defaultConnectionBound: Duration = .seconds(10)
    public static let defaultLogInterval: Duration = .seconds(60)

    public static let defaultLog: Log = { line in
        Logger(subsystem: "zone.hexagon.topo", category: "dns").info("\(line, privacy: .public)")
    }

    private let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let resolver: any RecordResolver
    private let log: Log
    private let queryBound: Duration
    private let connectionBound: Duration
    private let logInterval: Duration

    private(set) var tcp: NWListener?
    /// The UDP side: a socket of its own rather than a listener, since `NWListener` over UDP hands
    /// datagrams from different clients to one connection, whose reply would go to only one of them.
    private var udp: DispatchSourceRead?
    /// Bumped by every start and stop, so a listener's late callback acts on nothing newer.
    private(set) var generation = 0
    public private(set) var port: UInt16?
    private var starting: Task<UInt16, any Error>?
    /// A listener of this generation failed after it was ready and before the start finished.
    private var lostWhileStarting: Int?
    private var observer: (@Sendable (UInt16?) -> Void)?

    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Keyed by a number never used twice, so a late callback or timer for a question already
    /// answered finds nothing rather than a newer question at a reused address.
    private var pending: [UInt64: Pending] = [:]
    private var nextQuestion: UInt64 = 0
    /// One timer for every question's bound, armed for the earliest: a timer per question would
    /// be held by the queue until its deadline even once cancelled, so a flood would pile them up.
    private var sweep: DispatchSourceTimer?
    private var sweepArmed = false

    private var counts = Counts()
    private var lastLog = ContinuousClock.now
    private var flushScheduled = false

    public init(resolver: any RecordResolver = SystemRecordResolver(), queryBound: Duration = DNSForwarder.defaultQueryBound,
                connectionBound: Duration = DNSForwarder.defaultConnectionBound,
                logInterval: Duration = DNSForwarder.defaultLogInterval, log: @escaping Log = DNSForwarder.defaultLog) {
        queue = DispatchSerialQueue(label: "zone.hexagon.topo.dns")
        self.resolver = resolver
        self.queryBound = queryBound
        self.connectionBound = connectionBound
        self.logInterval = logInterval
        self.log = log
    }

    /// Calls `observer` with the port each time the forwarder is ready and with nil each time it
    /// goes down — stopped, or its listener failed or taken away (iOS reclaims a suspended app's) —
    /// on the forwarder's queue, and answers with the port now, nil while it is down.
    @discardableResult
    public func observe(_ observer: @escaping @Sendable (UInt16?) -> Void) -> UInt16? {
        self.observer = observer
        return port
    }

    /// Starts both listeners on one port and returns it; the port it has when already running.
    /// TCP is bound first at a port the system picks and UDP at the same number; when that is
    /// taken, both are tried again.
    public func start() async throws -> UInt16 {
        if let port { return port }
        // One start at a time: a second caller while one is binding gets its answer, rather than
        // making listeners of its own over the first's.
        if let starting { return try await starting.value }
        let task = Task { try await self.listen() }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    private func listen() async throws -> UInt16 {
        var failure: (any Error)?
        for _ in 0..<5 {
            generation += 1
            let current = generation
            let tcp: NWListener
            do {
                tcp = try NWListener(using: Self.loopback(.tcp, port: .any))
            } catch {
                failure = error
                continue
            }
            self.tcp = tcp
            do {
                let bound = try await ready(tcp, generation: current)
                guard generation == current else { throw CancellationError() }
                guard lostWhileStarting != current else { throw POSIXError(.ENOTCONN) }
                listenUDP(try Self.udpSocket(port: bound), generation: current)
                port = bound
                observer?(bound)
                return bound
            } catch {
                failure = error
                tcp.cancel()
                self.tcp = nil
                if error is CancellationError { throw error }
            }
        }
        log("dns: forwarder could not start; the guest resolves through the phone's name servers")
        throw failure ?? CancellationError()
    }

    /// Stops listening, closes every connection and abandons every question in flight.
    public func stop() {
        guard tcp != nil || udp != nil || port != nil else { return }
        down()
    }

    /// Parameters for a listener on `127.0.0.1` alone: no other interface, and no LAN peer,
    /// reaches it.
    static func loopback(_ parameters: NWParameters, port: NWEndpoint.Port) -> NWParameters {
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = false
        return parameters
    }

    private func ready(_ listener: NWListener, generation current: Int) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
            let waiting = Waiting(continuation)
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.assumeIsolated { forwarder in
                    // Nothing before the start has finished: a connection that lands between the
                    // listener's ready and a UDP bind that fails would outlive the attempt, and
                    // nothing the guest sends can arrive before it is told the port.
                    guard forwarder.generation == current, forwarder.port != nil else { connection.cancel(); return }
                    forwarder.acceptTCP(connection)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.assumeIsolated { forwarder in
                    switch state {
                    case .ready:
                        // Port 0 is the rewrite's "off"; a listener that cannot name its port is a failed start.
                        if let port = listener.port?.rawValue, port != 0 {
                            waiting.resume(.success(port))
                        } else {
                            waiting.resume(.failure(POSIXError(.EADDRNOTAVAIL)))
                        }
                    case .waiting(let error):
                        // A port that cannot be bound waits for one that can; a start takes it as failed.
                        waiting.resume(.failure(error))
                    case .failed(let error):
                        if !waiting.resume(.failure(error)) { forwarder.lost(current) }
                    case .cancelled:
                        if !waiting.resume(.failure(CancellationError())) { forwarder.lost(current) }
                    default:
                        break
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    /// A start's wait for its listener, resumed once, on the forwarder's queue.
    private final class Waiting: @unchecked Sendable {
        private var continuation: CheckedContinuation<UInt16, any Error>?
        init(_ continuation: CheckedContinuation<UInt16, any Error>) { self.continuation = continuation }
        /// Whether this was the resumption.
        @discardableResult func resume(_ result: Result<UInt16, any Error>) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(with: result)
            return true
        }
    }

    /// A listener of the running generation went away without being stopped: the guest falls back
    /// to the phone's own name servers until the next start, which the log says.
    private func lost(_ current: Int) {
        guard current == generation else { return }
        guard port != nil else {
            lostWhileStarting = current
            return
        }
        log("dns: forwarder lost; the guest resolves through the phone's name servers until it starts again")
        down()
    }

    private func down() {
        generation += 1
        tcp?.cancel()
        udp?.cancel()
        tcp = nil
        udp = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
        for question in pending.values { question.abandon() }
        pending = [:]
        sweep?.cancel()
        sweep = nil
        sweepArmed = false
        let wasUp = port != nil
        port = nil
        if wasUp { observer?(nil) }
    }

    // MARK: TCP

    private func acceptTCP(_ connection: NWConnection) {
        guard connections.count < Self.tcpConnectionLimit else {
            count(\.refused)
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.assumeIsolated { $0.connections[id] = nil }
            default: break
            }
        }
        connection.start(queue: queue)
        // Whatever happens to the listener that accepted it: cancelling one already cancelled is
        // nothing, and holding it weakly keeps a closed connection from waiting out the bound.
        queue.asyncAfter(deadline: .now() + connectionBound.timeInterval) { [weak connection] in
            connection?.cancel()
        }
        readLength(connection)
    }

    /// One length-prefixed message, then the next: a length over the limit closes the connection
    /// before the message is read.
    private func readLength(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.assumeIsolated { forwarder in
                guard let data, data.count == 2, error == nil else { connection.cancel(); return }
                let length = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
                guard length > 0, length <= Self.messageLimit else {
                    forwarder.count(\.dropped)
                    connection.cancel()
                    return
                }
                forwarder.readMessage(connection, length: length, closing: complete)
            }
        }
    }

    private func readMessage(_ connection: NWConnection, length: Int, closing: Bool) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.assumeIsolated { forwarder in
                guard let data, data.count == length, error == nil else { connection.cancel(); return }
                forwarder.received(Array(data), limit: Self.tcpReplyLimit, over: .tcp) { reply in
                    let prefix = [UInt8(reply.count >> 8), UInt8(reply.count & 0xff)]
                    connection.send(content: Data(prefix + reply), completion: .idempotent)
                }
                if !complete { forwarder.readLength(connection) }
            }
        }
    }

    // MARK: UDP

    /// A non-blocking datagram socket bound to `127.0.0.1` at `port`.
    static func udpSocket(port: UInt16) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            let error = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return fd
    }

    /// Reads `fd` whenever it is readable, on the forwarder's queue; the socket is closed when
    /// the source is cancelled.
    private func listenUDP(_ fd: Int32, generation current: Int) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.assumeIsolated { $0.drain(fd, generation: current) }
        }
        source.setCancelHandler { close(fd) }
        udp = source
        source.resume()
    }

    /// Every datagram waiting, each answered to the address it came from. One over the limit is
    /// dropped unread (the buffer is larger, so the size is seen); a socket that fails is the
    /// forwarder gone.
    func drain(_ fd: Int32, generation current: Int) {
        guard generation == current else { return }
        var buffer = [UInt8](repeating: 0, count: 2 * Self.messageLimit)
        for _ in 0..<Self.inFlightLimit {
            var from = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let size = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, MSG_DONTWAIT, $0, &length)
                }
            }
            if size < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { lost(current) }
                return
            }
            guard size <= Self.messageLimit else {
                count(\.dropped)
                continue
            }
            let peer = from
            received(Array(buffer[0..<size]), limit: nil, over: .udp) { reply in
                var to = peer
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, reply, reply.count, 0, $0, length) }
                }
            }
        }
    }

    // MARK: Questions

    enum Transport { case udp, tcp }

    /// One question from arrival to its one reply.
    /// Touched only on the forwarder's queue.
    private final class Pending: @unchecked Sendable {
        let query: DNSQuery
        let limit: Int
        let transport: Transport
        let send: ([UInt8]) -> Void
        let done: () -> Void
        var handle: (any ResolverQuery)?
        /// When the question is answered `SERVFAIL` if nothing has answered it.
        var bound = ContinuousClock.now
        /// When the sweep answers it: its bound, or sooner while a cached negative waits.
        var deadline = ContinuousClock.now
        /// A negative dnssd answered from its cache, answered at `deadline` unless the network's
        /// answer comes first.
        var cachedNegative: UInt8?
        var records: [DNSRecord] = []
        /// A record of the type asked for is held (for a CNAME question, the CNAME).
        var answered = false

        init(query: DNSQuery, limit: Int, transport: Transport, send: @escaping ([UInt8]) -> Void,
             done: @escaping () -> Void) {
            self.query = query
            self.limit = limit
            self.transport = transport
            self.send = send
            self.done = done
        }

        func abandon() {
            handle?.cancel()
            handle = nil
            done()
        }
    }

    private func received(_ bytes: [UInt8], limit: Int?, over transport: Transport, send: @escaping ([UInt8]) -> Void,
                          done: @escaping () -> Void = {}) {
        count(\.queries)
        let query: DNSQuery
        do {
            query = try DNSQuery.read(bytes)
        } catch {
            switch error {
            case .unanswerable:
                count(\.dropped)
            case .reply(let id, let rd, let rcode, let question):
                count(\.malformed)
                send(DNSReply.refusal(id: id, rd: rd, rcode: rcode, question: question))
            }
            done()
            return
        }
        // Over UDP, 512 bytes or what the client's EDNS offers, never more than 1232.
        let udpLimit = Int(min(max(query.ednsSize ?? 512, 512), Self.ednsLimit))
        guard pending.count < Self.inFlightLimit else {
            count(\.refused)
            count(\.servfail)
            send(DNSReply.make(to: query, rcode: DNSReply.servFail, answers: [], limit: udpLimit, ednsSize: Self.ednsLimit).bytes)
            done()
            return
        }
        let question = Pending(query: query, limit: limit ?? udpLimit, transport: transport, send: send, done: done)
        nextQuestion += 1
        let id = nextQuestion
        pending[id] = question
        question.handle = resolver.query(name: query.presentationName, type: query.type, queue: queue) { [weak self] answer in
            self?.assumeIsolated { $0.answer(id, answer) }
        }
        question.bound = .now + queryBound
        question.deadline = question.bound
        if !sweepArmed { arm() }
    }

    /// Sets the sweep for the earliest deadline among the questions in flight.
    private func arm() {
        guard let earliest = pending.values.map(\.deadline).min() else {
            sweepArmed = false
            return
        }
        if sweep == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.assumeIsolated { $0.expire() } }
            timer.resume()
            sweep = timer
        }
        sweepArmed = true
        let wait = max(earliest - .now, .zero)
        sweep?.schedule(deadline: .now() + wait.timeInterval, leeway: .milliseconds(10))
    }

    /// Every question past its deadline answered — with its cached negative when one was waiting,
    /// `SERVFAIL` at its bound otherwise — and its query deallocated.
    private func expire() {
        let now = ContinuousClock.now
        for (id, question) in pending where question.deadline <= now {
            if let rcode = question.cachedNegative {
                finish(id, rcode: rcode, keep: true)
            } else {
                finish(id, rcode: DNSReply.servFail, keep: false)
            }
        }
        arm()
    }

    /// One callback of a question's query. The question is complete when a record of the type
    /// asked for has arrived and its batch has ended (a callback without `MoreComing`), or when a
    /// negative or an error arrives — a negative from dnssd's cache only once the grace has passed
    /// with nothing from the network; a batch of CNAMEs alone is not complete, since the target's
    /// records can come in a later one.
    private func answer(_ id: UInt64, _ answer: RecordAnswer) {
        guard let question = pending[id] else { return }
        switch answer.outcome {
        case .noSuchName where answer.fromCache, .noSuchRecord where answer.fromCache:
            // Possibly the cache of a DNS configuration just replaced, with the network's answer
            // behind it: it waits a moment for that answer before it is the reply.
            guard question.cachedNegative == nil else { return }
            question.cachedNegative = answer.outcome == .noSuchName ? DNSReply.nxDomain : DNSReply.noError
            question.deadline = min(question.bound, .now + Self.cachedNegativeGrace)
            arm()
            return
        default:
            if question.cachedNegative != nil {
                // The network answered: what the cache said is not the reply.
                question.cachedNegative = nil
                question.deadline = question.bound
            }
        }
        switch answer.outcome {
        case .noSuchName:
            finish(id, rcode: DNSReply.nxDomain, keep: true)
        case .noSuchRecord:
            finish(id, rcode: DNSReply.noError, keep: true)
        case .failed:
            finish(id, rcode: DNSReply.servFail, keep: false)
        case .record:
            if let labels = DNSRecord.labels(presentation: answer.name) {
                let record = DNSRecord(labels: labels, type: answer.type, ttl: answer.ttl, rdata: answer.rdata)
                let same: (DNSRecord) -> Bool = {
                    $0.type == record.type && $0.rdata == record.rdata && Self.sameName($0.labels, record.labels)
                }
                if answer.add {
                    if !question.records.contains(where: same) { question.records.append(record) }
                } else {
                    question.records.removeAll(where: same)
                }
                // From what is held now, so a record added and removed again answers nothing.
                question.answered = question.records.contains {
                    $0.type == question.query.type || question.query.type == DNSQuery.typeANY
                }
            }
            if !answer.moreComing, question.answered {
                finish(id, rcode: DNSReply.noError, keep: true)
            }
        }
    }

    private static func sameName(_ a: [[UInt8]], _ b: [[UInt8]]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { $0.lowercased() == $1.lowercased() }
    }

    /// Answers a question once: with what was gathered when `keep`, and with no records otherwise.
    private func finish(_ id: UInt64, rcode: UInt8, keep: Bool) {
        guard let question = pending.removeValue(forKey: id) else { return }
        question.handle?.cancel()
        question.handle = nil
        let reply = DNSReply.make(to: question.query, rcode: rcode, answers: keep ? question.records : [],
                                  limit: question.limit, ednsSize: Self.ednsLimit)
        count(rcode == DNSReply.servFail ? \.servfail : \.answered)
        if reply.truncated { count(\.truncated) }
        question.send(reply.bytes)
        question.done()
    }

    // MARK: The count log

    struct Counts: Equatable {
        var queries = 0, answered = 0, servfail = 0, truncated = 0, dropped = 0, malformed = 0, refused = 0
        var isEmpty: Bool { self == Counts() }
        var line: String {
            "dns: \(queries) queries, \(answered) answered, \(servfail) servfail, \(truncated) truncated, "
                + "\(dropped) dropped, \(malformed) malformed, \(refused) refused at a cap"
        }
    }

    private func count(_ field: WritableKeyPath<Counts, Int>) {
        counts[keyPath: field] += 1
        guard !flushScheduled else { return }
        flushScheduled = true
        let due = max(lastLog + logInterval - ContinuousClock.now, .zero)
        queue.asyncAfter(deadline: .now() + due.timeInterval) { [weak self] in
            self?.assumeIsolated { $0.flush() }
        }
    }

    private func flush() {
        flushScheduled = false
        guard !counts.isEmpty else { return }
        log(counts.line)
        counts = Counts()
        lastLog = .now
    }
}

private extension [UInt8] {
    func lowercased() -> [UInt8] { map { (0x41...0x5a).contains($0) ? $0 | 0x20 : $0 } }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
