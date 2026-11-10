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
func exchange(port: UInt16, _ head: String, body: Data = Data(), host: NWEndpoint.Host = "127.0.0.1")
    async throws -> (status: Int?, body: String) {
    let connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let inbound = Inbound(connection, limit: 1 << 20)
    let watchdog = Task {
        try? await Task.sleep(for: .seconds(10))
        if !Task.isCancelled { connection.cancel() }
    }
    defer { watchdog.cancel(); connection.cancel() }
    inbound.start(queue: DispatchQueue(label: "test.tools.client"))
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

/// Whether something is listening on `127.0.0.1` at a port: a TCP connect, closed as soon as it
/// is answered, bounded by `within`, run off the cooperative pool.
enum LoopbackProbe {
    static let patience: Duration = .seconds(1)

    static func answers(port: UInt16, within: Duration = patience) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: connects(port: port, within: within))
            }
        }
    }

    static func connects(port: UInt16, within: Duration) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return false }
        defer { close(socket) }
        var on: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let started = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poll = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
        let milliseconds = Int32(within / .milliseconds(1))
        guard Darwin.poll(&poll, 1, milliseconds) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}

/// Another listener on `127.0.0.1` at `port`, as a process that took a port iOS freed would be:
/// it accepts and closes, and answers nothing. Ready when returned.
func squat(_ port: UInt16) async throws -> NWListener {
    let parameters = NWParameters.tcp
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
    let listener = try NWListener(using: parameters)
    listener.newConnectionHandler = { $0.cancel() }
    let once = SquatReady()
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            once.continuation = continuation
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.resume(nil)
                case .failed(let error), .waiting(let error): once.resume(error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.squat"))
        }
    } catch {
        // A squat refused lets its listener go, so a search past held ports leaves none behind.
        listener.cancel()
        throw error
    }
    return listener
}

final class SquatReady: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<Void, Error>?
    func resume(_ error: Error?) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { continuation = nil }
            return continuation
        }
        if let error { waiting?.resume(throwing: error) } else { waiting?.resume() }
    }
}
