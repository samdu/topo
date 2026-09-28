import Foundation
import Network
import os
import Security
import TopoProxy

/// The phone's tool service: the guest's third hole, beside its mounts and the API proxy. An
/// `NWListener` bound to `127.0.0.1` at a port picked at start, plain HTTP/1.1 through the proxy's
/// own reader, and one route, `POST /run`, whose body is a call's arguments (`ToolRequest`) and
/// whose answer is `200 text/plain`: a first line `exit: <status>`, then what the tool said.
///
/// Loopback is not private — any process on the device, and a web page open beside the app, can
/// reach `127.0.0.1` — so every request's body starts with a token (`ToolRequest`), made once
/// when the service is, handed to the guest only in the environment of the process the app starts
/// (`environment`), and compared in constant time. A request is refused before any tool runs when
/// it carries no such token, carries an `Origin` or a `Sec-Fetch-*` header (a browser's marks, and
/// a browser has no business here), names a `Host` other than `127.0.0.1` at this port, or is not
/// `POST /run`. One request per connection, then the connection closes.
///
/// Every connection is bounded (`bound`, 90 s: under the 120 s Claude Code's Bash tool gives a
/// command by default) from the moment it is accepted: a request not read by then is answered 408
/// and closed, and a call not answered by then is answered with `ToolReply.timedOut` whether or
/// not the tool has stopped. It logs each call's tool, status and time, and each refusal's reason,
/// and never an argument, a header value or anything a tool said.
public actor ToolService {
    public typealias Log = @Sendable (String) -> Void

    /// The variables the guest's `topo` reads.
    public static let urlVariable = "TOPO_TOOLS_URL"
    public static let tokenVariable = "TOPO_TOOLS_TOKEN"
    /// The one route.
    public static let path = "/run"
    /// The largest call accepted: arguments, not files.
    public static let bodyLimit = 64 * 1024
    public static let defaultBound: Duration = .seconds(90)

    public static let defaultLog: Log = { line in
        Logger(subsystem: "zone.hexagon.topo", category: "tools").info("\(line, privacy: .public)")
    }

    public let token: String
    private let table: ToolTable
    private let bound: Duration
    private let log: Log
    private let listener: NWListener
    private let queue = DispatchQueue(label: "zone.hexagon.topo.tools")
    private var ready: CheckedContinuation<UInt16, any Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    public private(set) var port: UInt16?

    public init(tools: [any Tool], token: String = ToolService.newToken(), bound: Duration = ToolService.defaultBound,
                log: @escaping Log = ToolService.defaultLog) throws {
        let parameters = NWParameters.tcp
        // Loopback only: no other interface, and no LAN peer, reaches it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        table = ToolTable(tools)
        self.token = token
        self.bound = bound
        self.log = log
    }

    /// 32 random bytes, as hex.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "no random bytes for the tool service's token")
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Starts listening and returns the port, once bound.
    public func start() async throws -> UInt16 {
        if let port { return port }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.stateChanged(state) }
        }
        listener.start(queue: queue)
        return try await withCheckedThrowingContinuation { continuation in
            ready = continuation
        }
    }

    /// Stops listening and closes every connection.
    public func stop() {
        listener.cancel()
        port = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }

    /// What the guest's environment gains so its `topo` reaches the service on `port`. The token
    /// is handed over here and nowhere else.
    public static func environment(port: UInt16, token: String) -> [String: String] {
        [urlVariable: "http://127.0.0.1:\(port)", tokenVariable: token]
    }

    private func stateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            let bound = listener.port?.rawValue ?? 0
            port = bound
            ready?.resume(returning: bound)
            ready = nil
        case .failed(let error):
            ready?.resume(throwing: error)
            ready = nil
        case .cancelled:
            ready?.resume(throwing: CancellationError())
            ready = nil
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard listener.state != .cancelled, let port else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        let inbound = Inbound(connection, limit: Self.bodyLimit + RequestReader.headLimit + 1024)
        inbound.start(queue: queue)
        let gate = Gate(token: token, port: port)
        let table = table, bound = bound, log = log
        let deadline = ContinuousClock.now + bound
        Task.detached {
            await Self.serve(inbound, gate: gate, table: table, deadline: deadline, bound: bound, log: log)
            connection.cancel()
            await self.forget(id)
        }
    }

    private func forget(_ id: ObjectIdentifier) {
        connections[id] = nil
    }

    /// One request on one connection: read and run by `deadline`, judged, answered.
    private static func serve(_ inbound: Inbound, gate: Gate, table: ToolTable, deadline: ContinuousClock.Instant,
                              bound: Duration, log: @escaping Log) async {
        // A client that never finishes its request is answered at the deadline and let go: the
        // read ends when the connection does.
        let read = First()
        let timer = Task {
            try await Task.sleep(until: deadline)
            guard read.claim() else { return }
            log("refused 408: the request was not whole within \(Int(bound / .seconds(1))) s")
            try? await inbound.send(plain(status: 408, "refused\n"))
            inbound.connection.cancel()
        }
        let request: InboundRequest
        do {
            let next = try await RequestReader.next(from: inbound, bodyLimit: bodyLimit)
            guard read.claim() else { return }
            timer.cancel()
            guard let next else { return }
            request = next
        } catch let error as WireError {
            guard read.claim() else { return }
            timer.cancel()
            guard error != .closed else { return }
            log("refused \(error.status): unreadable request")
            try? await inbound.send(plain(status: error.status, "refused\n"))
            return
        } catch {
            timer.cancel()
            return
        }
        if let refusal = gate.judge(request) {
            log("refused \(refusal.status): \(refusal.reason)")
            try? await inbound.send(plain(status: refusal.status, "refused\n"))
            return
        }
        let arguments: [String]
        do {
            arguments = try ToolRequest.arguments(from: ToolRequest.split(request.body)?.arguments ?? Data())
        } catch {
            log("refused 400: the arguments are not base64 lines of UTF-8")
            try? await inbound.send(plain(status: 400, "refused\n"))
            return
        }
        let started = ContinuousClock.now
        let reply = await bounded(arguments, table: table, until: deadline, bound: bound)
        // The tool's name only when it is one: an unknown word is an argument like any other.
        let name = arguments.first.flatMap { table.tool(named: $0)?.name } ?? (arguments.first == "help" || arguments.isEmpty ? "help" : "unknown")
        let milliseconds = Int((ContinuousClock.now - started) / .milliseconds(1))
        log("\(name) exit \(reply.status) in \(milliseconds) ms")
        try? await inbound.send(plain(status: 200, "exit: \(reply.status)\n" + reply.text))
    }

    /// The call, answered by the tool or by the bound, whichever comes first. The tool is not
    /// waited for past the bound: a tool that ignores cancellation (a prompt nobody answers) runs
    /// on, answering nobody.
    public static func bounded(_ arguments: [String], table: ToolTable, until deadline: ContinuousClock.Instant,
                        bound: Duration) async -> ToolReply {
        let once = Once()
        let seconds = Int(bound / .seconds(1))
        let late = ToolReply(status: ToolReply.timedOut, text:
            "topo: no answer within \(seconds) s. If the phone is showing a permission prompt, ask the person to answer it, then try again.\n")
        return await withCheckedContinuation { (continuation: CheckedContinuation<ToolReply, Never>) in
            let work = Task { await table.run(arguments) }
            let timer = Task { try await Task.sleep(until: deadline) }
            Task {
                let reply = await work.value
                timer.cancel()
                once.resume(continuation, with: reply)
            }
            Task {
                guard (try? await timer.value) != nil else { return }
                if once.resume(continuation, with: late) { work.cancel() }
            }
        }
    }

    static func plain(status: Int, _ text: String) -> Data {
        let body = Data(text.utf8)
        var data = ResponseWriter.head(status: status, headers: [
            HTTPField("Content-Type", "text/plain; charset=utf-8"),
            HTTPField("Content-Length", String(body.count)),
            HTTPField("Connection", "close"),
        ])
        data.append(body)
        return data
    }
}

/// What a request has to be before any tool runs.
struct Gate: Sendable {
    let token: String
    let port: UInt16

    struct Refusal: Equatable {
        var status: Int
        var reason: String
    }

    func judge(_ request: InboundRequest) -> Refusal? {
        let headers = request.headers
        if !headers.values("Origin").isEmpty || headers.contains(where: { $0.name.lowercased().hasPrefix("sec-fetch-") }) {
            return Refusal(status: 403, reason: "a browser's request")
        }
        let hosts = headers.values("Host")
        guard hosts.count == 1, ["127.0.0.1", "127.0.0.1:\(port)"].contains(hosts[0]) else {
            return Refusal(status: 403, reason: "not addressed to 127.0.0.1:\(port)")
        }
        guard let given = ToolRequest.split(request.body)?.token, Self.equal(given, token) else {
            return Refusal(status: 401, reason: "no token, or not this service's")
        }
        guard request.path == ToolService.path, request.target == ToolService.path else {
            return Refusal(status: 404, reason: "not \(ToolService.path)")
        }
        guard request.method == "POST" else {
            return Refusal(status: 405, reason: "not a POST")
        }
        return nil
    }

    /// Whether two strings are equal, in time that depends on their lengths and not on where they
    /// first differ.
    static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }
}

/// Says yes once: to whichever of two racers claims it first.
final class First: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// Resumes a continuation once, whoever gets there first.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    @discardableResult
    func resume(_ continuation: CheckedContinuation<ToolReply, Never>, with reply: ToolReply) -> Bool {
        let first: Bool = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { continuation.resume(returning: reply) }
        return first
    }
}
