import Foundation
import Network
import TopoProxy
@testable import TopoTools

/// A tool that records what it was called with and answers as it is told.
final class ScriptedTool: Tool, @unchecked Sendable {
    let name: String
    let summary = "a scripted tool"
    let usage = "topo scripted <anything>"
    private let lock = NSLock()
    private var _calls: [[String]] = []
    private let answer: @Sendable ([String]) async -> ToolReply

    init(name: String = "echo", answer: @escaping @Sendable ([String]) async -> ToolReply = { .ok($0.joined(separator: "|") + "\n") }) {
        self.name = name
        self.answer = answer
    }

    var calls: [[String]] { lock.withLock { _calls } }

    func run(_ arguments: [String]) async -> ToolReply {
        lock.withLock { _calls.append(arguments) }
        return await answer(arguments)
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func add(_ line: String) { lock.withLock { _lines.append(line) } }
}

func startedService(_ tools: [any Tool], bound: Duration = ToolService.defaultBound)
    async throws -> (service: ToolService, port: UInt16, logs: LogLines) {
    let logs = LogLines()
    let service = try ToolService(tools: tools, bound: bound, log: { logs.add($0) })
    let port = try await service.start()
    return (service, port, logs)
}

/// A service over `tools`, started on the first port `ports` draws that is free, with its log captured.
func startedServiceOnTestPort(_ tools: [any Tool], from ports: TestPorts = .shared) async throws -> (service: ToolService, port: UInt16, logs: LogLines) {
    let start = { (port: NWEndpoint.Port) in
        let logs = LogLines()
        let service = try ToolService(tools: tools, log: { logs.add($0) })
        await service.set(requestedPort: port)
        let bound: UInt16
        do { bound = try await service.start() } catch { await service.stop(); throw error }
        // Asked for once: a later start or `relisten` picks a port of its own, as in the app.
        await service.set(requestedPort: .any)
        return (service, bound, logs)
    }
    return try await ports.first(start)
}

/// A port for a test that lets its listener go and then needs that port again: a squatter bound
/// on it, or `relisten(on:)`. Every other listener and connection in the run is on a port the
/// system picks from its ephemeral range (49152–65535, `net.inet.ip.portrange.first`), and a
/// port it has just freed is one it can pick next, which hands a parallel test the port this one
/// was about to take back. These are below that range, so nothing in the run is handed one, and
/// each is given out once per run, from a random start so two runs at once seldom meet.
final class TestPorts: @unchecked Sendable {
    static let range: ClosedRange<UInt16> = 44000...47999
    /// The suites' one allocator: every port a test binds through `first` comes out of it.
    static let shared = TestPorts(offset: Int.random(in: 0..<range.count))

    private let lock = NSLock()
    private var handing: [UInt16]
    private let parent: TestPorts?
    private let offset: Int?
    private var drawn = 0

    /// The range from `offset`, each port once and none twice: draw n is the port `offset + n`
    /// round the range, and the draw after the range's count of them is nil.
    init(offset: Int) {
        handing = []
        parent = nil
        self.offset = offset
    }

    /// `ports` in turn, then what `parent` draws; with no parent, nil once `ports` are spent.
    /// A test hands only a port it drew from `shared` itself, so whatever this binds came out of
    /// `shared` once.
    init(handing ports: [UInt16], then parent: TestPorts? = nil) {
        handing = ports
        self.parent = parent
        offset = nil
    }

    /// The next port, consumed whether or not it is bound: nil when there is none.
    func draw() -> UInt16? {
        let own = lock.withLock { () -> UInt16?? in
            if !handing.isEmpty { return .some(handing.removeFirst()) }
            guard let offset else { return .none }
            guard drawn < Self.range.count else { return .some(nil) }
            defer { drawn += 1 }
            return .some(Self.range.lowerBound + UInt16((offset + drawn) % Self.range.count))
        }
        if let own { return own }
        return parent?.draw()
    }

    /// `start` on the next port, and on the next after each one already held, every port tried
    /// consumed so no later draw is handed it, a fallback's included; that refusal once there is
    /// no port left to draw.
    func first<T>(_ start: (NWEndpoint.Port) async throws -> T) async throws -> T {
        while let port = draw() {
            do { return try await start(NWEndpoint.Port(rawValue: port)!) } catch NWError.posix(.EADDRINUSE) {}
        }
        throw NWError.posix(.EADDRINUSE)
    }
}

/// One raw request on a fresh connection, and the status and body that came back — or nil status
/// when the connection closed with nothing said.
func exchange(port: UInt16, _ head: String, body: Data = Data())
    async throws -> (status: Int?, body: String) {
    let current = Current()
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(10))
        if !Task.isCancelled { current.cancel() }
    }
    defer { watchdog.cancel(); current.cancel() }
    let inbound = try await connect(port: port, current: current)
    var data = Data(head.utf8)
    data.append(body)
    try await inbound.send(data)
    guard let raw = try await inbound.read(through: RequestReader.headEnd, maximum: 64 * 1024, tooLarge: .headTooLarge) else {
        return (nil, "")
    }
    let text = String(decoding: raw, as: UTF8.self)
    let lines = text.components(separatedBy: "\r\n")
    let status = Int(lines[0].split(separator: " ")[1])
    let length = lines.dropFirst().first { $0.lowercased().hasPrefix("content-length:") }
        .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    let bodyData = length > 0 ? try await inbound.read(count: length) : Data()
    return (status, String(decoding: bodyData, as: UTF8.self))
}

/// A client connection to `127.0.0.1:port`, started, from a local port bound before the
/// connect. Left to the connect, a connection whose pair with `port` is still held in TIME_WAIT
/// by an earlier one — a listener handed a port number the run connected to before — is refused
/// as in use, and every new connection to `port` is then given the same local port and refused
/// the same way for the 30 s TIME_WAIT lasts, while Network waits for the network to change
/// rather than failing (#474). Bound first, the local port is the system's next free one; one
/// that still makes a held pair is refused the same way, and a new connection draws another
/// (`restart()` would keep the port). Nothing is sent before it is ready, so the request is made
/// once. A connection that waits for anything else throws what it waits on, as a send queued on
/// it would have: a refusal is ECONNREFUSED at once, not the watchdog's cancel.
private func connect(port: UInt16, current: Current) async throws -> Inbound {
    for attempt in 1...50 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        guard current.set(connection) else { throw NWError.posix(.ECANCELED) }
        let inbound = Inbound(connection, limit: 1 << 20)
        inbound.start(queue: DispatchQueue(label: "test.tools.client"))
        // Read rather than heard: the handler is Inbound's, and one put in front of it after the
        // start misses a state reported before it was in place. A watchdog's cancel ends the wait.
        var state = connection.state
        while state == .setup || state == .preparing {
            try await Task.sleep(for: .milliseconds(2))
            state = connection.state
        }
        switch state {
        case .waiting(.posix(.EADDRINUSE)) where attempt < 50:
            connection.cancel()
        case .waiting(let error):
            connection.cancel()
            throw error
        case .cancelled:
            throw NWError.posix(.ECANCELED)
        default:
            return inbound
        }
    }
    throw NWError.posix(.EADDRINUSE)
}

/// The connection an exchange is on, so its watchdog cancels the one it is making now; once
/// cancelled, none is made after, and the exchange throws.
private final class Current: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?
    private var cancelled = false

    func set(_ next: NWConnection) -> Bool {
        lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            connection = next
            return true
        }
    }

    func cancel() {
        lock.withLock { () -> NWConnection? in
            cancelled = true
            return connection
        }?.cancel()
    }
}

/// A well-formed call, with whatever headers are given in place of the usual ones.
func call(port: UInt16, token: String, _ arguments: [String], extra: [String] = [],
          host: String? = nil, method: String = "POST", path: String = ToolService.path) -> (String, Data) {
    let body = ToolRequest.body(token: token, arguments)
    var head = "\(method) \(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\n"
    head += "Content-Length: \(body.count)\r\n"
    for line in extra { head += line + "\r\n" }
    head += "\r\n"
    return (head, body)
}
