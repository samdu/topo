import Foundation
import Network
import Testing
@testable import TopoProxy

/// A raw HTTP/1.1 client over one TCP connection, so a test controls every byte and every write
/// boundary. Its reads come through the proxy's own `Inbound`, and a watchdog cancels the
/// connection after `deadline` seconds, so a test that waits on something that never comes fails
/// rather than hangs.
final class WireClient: @unchecked Sendable {
    let connection: NWConnection
    let inbound: Inbound
    private let watchdog: Task<Void, Never>

    init(host: NWEndpoint.Host = "127.0.0.1", port: UInt16, deadline: Double = 10) async throws {
        connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        inbound = Inbound(connection, limit: 64 * 1024 * 1024)
        let connection = connection
        watchdog = Task {
            try? await Task.sleep(for: .seconds(deadline))
            if !Task.isCancelled { connection.cancel() }
        }
        inbound.start(queue: DispatchQueue(label: "test.client"))
    }

    deinit {
        watchdog.cancel()
        connection.cancel()
    }

    func send(_ text: String) async throws { try await inbound.send(Data(text.utf8)) }
    func send(_ data: Data) async throws { try await inbound.send(data) }
    /// Sends `text` and then a FIN: the write side shut down, the read side still open.
    func sendThenShutDownWrites(_ text: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(text.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    /// A full close: the socket closed both ways, as a client that aborts closes it.
    func close() { connection.cancel() }
    /// A reset.
    func reset() { connection.forceCancel() }

    struct Head {
        var status: Int
        var headers: [HTTPField]
        var raw: Data
        var chunked: Bool { headers.tokens("Transfer-Encoding").contains("chunked") }
    }

    func readHead() async throws -> Head {
        guard let raw = try await inbound.read(through: RequestReader.headEnd, maximum: 64 * 1024, tooLarge: .headTooLarge) else {
            throw WireError.closed
        }
        let text = String(decoding: raw, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let status = Int(lines.removeFirst().split(separator: " ")[1])!
        let headers = lines.map { line -> HTTPField in
            let colon = line.firstIndex(of: ":")!
            return HTTPField(String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return Head(status: status, headers: headers, raw: raw)
    }

    /// The next chunk of a chunked body, or nil at the last chunk (whose trailer it consumes).
    func readChunk() async throws -> Data? {
        guard let line = try await inbound.read(through: RequestReader.crlf, maximum: 64, tooLarge: .malformed("size")) else { throw WireError.closed }
        let size = Int(String(decoding: line.dropLast(2), as: UTF8.self), radix: 16)!
        if size == 0 {
            _ = try await inbound.read(count: 2)
            return nil
        }
        let data = try await inbound.read(count: size)
        _ = try await inbound.read(count: 2)
        return data
    }

    /// Every byte until the proxy closes the connection.
    func readToEnd() async throws -> Data {
        var data = Data()
        while true {
            do { data.append(try await inbound.read(count: 1)) } catch WireError.closed { return data }
        }
    }

    /// A whole response: head and body, de-chunked or by Content-Length.
    func readResponse() async throws -> (head: Head, body: Data) {
        let head = try await readHead()
        var body = Data()
        if head.chunked {
            while let chunk = try await readChunk() { body.append(chunk) }
        } else if let length = head.headers.value("Content-Length").flatMap(Int.init), length > 0 {
            body = try await inbound.read(count: length)
        }
        return (head, body)
    }
}

/// An upstream the test scripts: it records every request and answers with whatever `answer`
/// returns.
final class StubUpstream: Upstream, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [UpstreamRequest] = []
    let answer: @Sendable (UpstreamRequest) async throws -> UpstreamResponse

    init(answer: @escaping @Sendable (UpstreamRequest) async throws -> UpstreamResponse = { _ in StubUpstream.ok("{}") }) {
        self.answer = answer
    }

    var requests: [UpstreamRequest] { lock.withLock { received } }

    func send(_ request: UpstreamRequest) async throws -> UpstreamResponse {
        lock.withLock { received.append(request) }
        return try await answer(request)
    }

    static func ok(_ text: String, headers: [HTTPField] = [HTTPField("Content-Type", "application/json")]) -> UpstreamResponse {
        UpstreamResponse(status: 200, headers: headers, body: AsyncThrowingStream { continuation in
            continuation.yield(Data(text.utf8))
            continuation.finish()
        })
    }
}

/// A local HTTP origin for the tests of `URLSessionUpstream`: it reads each request with the
/// proxy's own reader and hands the raw connection to `handle`, which writes whatever it likes.
final class StubOrigin: @unchecked Sendable {
    let listener: NWListener
    private let lock = NSLock()
    private var received: [InboundRequest] = []
    private var closedConnections = 0
    let handle: @Sendable (InboundRequest, Inbound) async throws -> Void

    init(handle: @escaping @Sendable (InboundRequest, Inbound) async throws -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.handle = handle
    }

    var requests: [InboundRequest] { lock.withLock { received } }
    /// Connections the far side (URLSession) closed or reset.
    var closed: Int { lock.withLock { closedConnections } }

    func start() async throws -> UInt16 {
        let ready = Ready()
        listener.stateUpdateHandler = { [listener] state in
            if case .ready = state { ready.resume(listener.port!.rawValue) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let inbound = Inbound(connection, limit: 64 * 1024 * 1024)
            inbound.whenEnded { [weak self] in self?.lock.withLock { self?.closedConnections += 1 } }
            inbound.start(queue: DispatchQueue(label: "test.origin"))
            Task {
                while let request = try? await RequestReader.next(from: inbound, bodyLimit: 1 << 26) {
                    self.lock.withLock { self.received.append(request) }
                    try? await self.handle(request, inbound)
                }
            }
        }
        listener.start(queue: DispatchQueue(label: "test.origin.listener"))
        return try await ready.value()
    }

    func stop() { listener.cancel() }

    var url: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)")! }
}

/// A value one side sets once and the other waits for.
final class Ready: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt16?
    private var waiting: CheckedContinuation<UInt16, Error>?

    func resume(_ v: UInt16) {
        let w: CheckedContinuation<UInt16, Error>? = lock.withLock {
            guard value == nil else { return nil }
            value = v
            defer { waiting = nil }
            return waiting
        }
        w?.resume(returning: v)
    }

    func value() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { c in
            let now: UInt16? = lock.withLock {
                if let value { return value }
                waiting = c
                return nil
            }
            if let now { c.resume(returning: now) }
        }
    }
}

/// A one-shot signal: `fire` once, `wait` with a deadline.
final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() { lock.withLock { fired = true } }
    var hasFired: Bool { lock.withLock { fired } }

    /// True when fired within `seconds`.
    func wait(_ seconds: Double) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if hasFired { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return hasFired
    }
}

/// Lines a proxy logged.
final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var lines: [String] { lock.withLock { stored } }
    var log: APIProxy.Log { { [self] line in lock.withLock { stored.append(line) } } }
}

/// A proxy over `upstream`, started, with its log captured.
func startedProxy(_ upstream: any Upstream) async throws -> (APIProxy, UInt16, LogLines) {
    let lines = LogLines()
    let proxy = try APIProxy(upstream: upstream, log: lines.log)
    let port = try await proxy.start()
    return (proxy, port, lines)
}

func post(_ path: String, body: String, headers: [String] = []) -> String {
    let extra = headers.map { $0 + "\r\n" }.joined()
    return "POST \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n\(extra)Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
}
