import Foundation
import Network
import os
import TopoAuth
import TopoCore

/// The loopback relay Claude Code in the guest reaches the API through: plain HTTP/1.1 in on
/// `127.0.0.1` at a port picked at start, every request forwarded to the one upstream
/// (api.anthropic.com over TLS, `URLSessionUpstream`), the response streamed back chunk by chunk
/// as it arrives. The guest's own `Authorization` is carried unchanged: the proxy holds no
/// credential and adds none, it only carries TLS the emulator cannot. It logs the method, path,
/// status and time of each request and never a header value.
///
/// Inbound it speaks HTTP/1.1 with keep-alive: requests one after another on one connection,
/// bodies framed by `Content-Length` or chunked, `Expect: 100-continue` answered. The request body
/// is read whole before it is forwarded (the debug pin has to read it); the response body never
/// is. A client that goes away mid-response cancels the upstream request.
///
/// In a debug build the `model` of every `/v1/messages` body is rewritten to `pinnedModel`
/// before it is forwarded, whatever the guest asked for, so a debug build spends Haiku. The path
/// is judged in its canonical form (`canonical(_:)`), so a doubled slash, a dot segment or
/// percent-encoding does not take a request past the pin; a path still percent-encoded after
/// `decodePasses` is refused with a 400 before its body is read.
///
/// A listener that fails or is cancelled once it is up — iOS takes a suspended app's away — is the
/// proxy down: its port is forgotten, its connections closed and the loss logged, and the next
/// `start` listens again, on a port of its own, with a new listener. `relisten` starts a new listener whatever the old one's state, which is what each launch of the resident asks for: iOS's word of a loss can come late, and a port it freed can be bound again by another process.
public actor APIProxy {
    public typealias Log = @Sendable (String) -> Void

    /// The model a debug build's requests are rewritten to; nil in a release build.
    public static let pinnedModel: String? = {
        #if DEBUG
        "claude-haiku-5-5"
        #else
        nil
        #endif
    }()

    /// The largest request body accepted; Claude Code's are JSON, images included.
    public static let bodyLimit = 32 * 1024 * 1024

    public static let defaultLog: Log = { line in
        Logger(subsystem: "zone.hexagon.topo", category: "proxy").info("\(line, privacy: .public)")
    }

    /// The listener of the running generation; nil while down.
    private(set) var listener: NWListener?
    /// Bumped by every start and every stop or loss, so a late state from a listener that is no
    /// longer the running one reaches nothing.
    private(set) var generation = 0
    private let forwarder: Forwarder
    private let log: Log
    private let queue = DispatchQueue(label: "zone.hexagon.topo.proxy")
    /// Starts waiting for the running listener to be ready.
    private var waiting: [CheckedContinuation<UInt16, any Error>] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    public private(set) var port: UInt16?

    public init(upstream: any Upstream = URLSessionUpstream(), log: @escaping Log = APIProxy.defaultLog) throws {
        forwarder = Forwarder(upstream: upstream, log: log)
        self.log = log
    }

    /// Starts listening and returns the port, once bound; the port it has when already up. A
    /// start while another is waiting for its listener waits for the same one.
    public func start() async throws -> UInt16 { try await listen(requesting: requestedPort) }

    /// Lets the listener go and starts a new one on `port` itself, whatever the old one's state:
    /// what a frozen resident was launched with, which it can be continued toward only once this
    /// app holds that port again. A port another process has bound meanwhile is not shared — the
    /// bind fails, and so does this — so a resident is never continued toward a listener that is
    /// not the app's.
    public func relisten(on port: UInt16) async throws -> UInt16 {
        guard let wanted = NWEndpoint.Port(rawValue: port), port != 0 else { throw POSIXError(.EINVAL) }
        down()
        settle(.failure(CancellationError()))
        let bound = try await listen(requesting: wanted)
        guard bound == port else { throw POSIXError(.EADDRINUSE) }
        return bound
    }

    private func listen(requesting requested: NWEndpoint.Port) async throws -> UInt16 {
        if let port { return port }
        if listener == nil {
            let parameters = NWParameters.tcp
            // Loopback only: the listener is bound to 127.0.0.1, so no other interface — and no
            // LAN peer — reaches it.
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: requested)
            let listener = try NWListener(using: parameters)
            generation += 1
            let current = generation
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                Task { await self.accept(connection, generation: current) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.stateChanged(state, generation: current) }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
        return try await withCheckedThrowingContinuation { continuation in
            waiting.append(continuation)
        }
    }

    /// Lets the listener go and starts a new one, on a port of its own, whatever the old one's
    /// state: a listener bound a moment ago is this one's by construction, where a held port may
    /// have been taken away while the app was suspended, its word of that not yet come, and even
    /// bound again by another process. Closes every connection, so it is for a moment nothing is
    /// using them: the resident's launch.
    public func relisten() async throws -> UInt16 {
        down()
        settle(.failure(CancellationError()))
        return try await start()
    }

    /// Stops listening and closes every connection, which cancels every request in flight.
    public func stop() {
        down()
        settle(.failure(CancellationError()))
    }

    /// The URL the guest's `ANTHROPIC_BASE_URL` is set to.
    public static func baseURL(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    /// What the guest's environment gains so Claude Code talks through the proxy on `port`, with
    /// the token `credential` hands out: the long-lived one when sign-in minted it, otherwise the
    /// ordinary access token. The token is handed over here and nowhere else — only in the
    /// environment of the process the app starts. Throws `TokenProviderError.signedOut` with no
    /// login.
    public static func guestEnvironment(port: UInt16, credential: GuestCredential) async throws
        -> (environment: [String: String], source: GuestCredential.Source) {
        let (token, source) = try await credential.token()
        return (["ANTHROPIC_BASE_URL": baseURL(port: port), "CLAUDE_CODE_OAUTH_TOKEN": token], source)
    }

    private func stateChanged(_ state: NWListener.State, generation current: Int) async {
        guard current == generation, let listener else { return }
        switch state {
        case .ready:
            if let holdReady {
                await holdReady()
                guard current == generation else { return }
            }
            // A listener that cannot name its port is a failed start.
            guard let bound = listener.port?.rawValue, bound != 0 else {
                down()
                settle(.failure(POSIXError(.EADDRNOTAVAIL)))
                return
            }
            port = bound
            settle(.success(bound))
        case .failed(let error) where hearsLoss:
            lost("it failed", error)
        case .cancelled where hearsLoss:
            lost("it was cancelled", CancellationError())
        case .waiting(let error) where port == nil:
            // A port that cannot be bound waits for one that can; a start takes it as failed.
            down()
            settle(.failure(error))
        default:
            break
        }
    }

    /// The running listener went away without being stopped: down until the next start.
    private func lost(_ how: String, _ error: any Error) {
        if port != nil { log("listener lost (\(how)); the next start listens again") }
        down()
        settle(.failure(error))
    }

    // MARK: Seams for the tests

    /// The port the next listener asks for; any, outside a test that needs one taken.
    var requestedPort: NWEndpoint.Port = .any
    /// Whether a listener's own word that it failed or was cancelled is heard; a test turns it off
    /// to stand for the word not having come yet.
    var hearsLoss = true
    /// Awaited before a listener's readiness is settled, so a test can hold a start pending.
    var holdReady: (@Sendable () async -> Void)?
    var waitingStarts: Int { waiting.count }
    func set(requestedPort: NWEndpoint.Port) { self.requestedPort = requestedPort }
    func set(hearsLoss: Bool) { self.hearsLoss = hearsLoss }
    func set(holdReady: (@Sendable () async -> Void)?) { self.holdReady = holdReady }

    private func down() {
        generation += 1
        listener?.cancel()
        listener = nil
        port = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
    }

    private func settle(_ result: Result<UInt16, any Error>) {
        let starts = waiting
        waiting = []
        for start in starts { start.resume(with: result) }
    }

    private func accept(_ connection: NWConnection, generation current: Int) {
        guard current == generation, port != nil else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        let inbound = Inbound(connection, limit: Self.bodyLimit + RequestReader.headLimit + 64 * 1024)
        inbound.start(queue: queue)
        let forwarder = forwarder
        Task.detached {
            await forwarder.serve(inbound)
            connection.cancel()
            await self.forget(id)
        }
    }

    private func forget(_ id: ObjectIdentifier) {
        connections[id] = nil
    }
}

/// One connection's requests, in order, each forwarded and its response streamed back before the
/// next is read.
struct Forwarder: Sendable {
    let upstream: any Upstream
    let log: APIProxy.Log

    /// Request headers that belong to this hop and not the next, or that URLSession sets itself.
    /// `Authorization` is not among them: the guest's credential goes through unchanged.
    static let requestDropped: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "host", "content-length", "expect", "accept-encoding",
    ]

    /// Response headers that belong to the upstream hop, or describe a framing or a coding
    /// URLSession has already undone.
    static let responseDropped: Set<String> = [
        "connection", "keep-alive", "proxy-connection", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length", "content-encoding",
    ]

    static func filter(_ headers: [HTTPField], dropping dropped: Set<String>) -> [HTTPField] {
        let named = Set(headers.tokens("Connection"))
        return headers.filter {
            let name = $0.name.lowercased()
            return !dropped.contains(name) && !named.contains(name)
        }
    }

    /// How much of each end of an answer a timed run keeps a copy of to read the token counts from.
    static let usageWindow = 8192

    /// The path segments a mark may name: the routes Claude Code is known to ask for. The path is
    /// the guest's to choose, so a segment is written only when it is one of these.
    static let routeSegments: Set<String> = ["v1", "api", "messages", "count_tokens", "batches", "models", "hello",
                                             "oauth", "claude_cli", "claude_code", "organizations", "files"]

    /// A request's path as a mark names it: each segment that is one of `routeSegments`, and a
    /// `*` for any other, which could be an id or a secret however much it reads like a word. A
    /// query is not part of it.
    static func routeForMark(_ path: String?) -> String {
        guard let path = path?.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first else { return "?" }
        return path.split(separator: "/", omittingEmptySubsequences: false).map { segment in
            segment.isEmpty || routeSegments.contains(String(segment)) ? String(segment) : "*"
        }.joined(separator: "/")
    }

    func serve(_ inbound: Inbound) async {
        while true {
            let request: InboundRequest
            do {
                guard let next = try await RequestReader.next(from: inbound, bodyLimit: APIProxy.bodyLimit) else { return }
                request = next
            } catch let error as WireError {
                if error != .closed {
                    log("refused a request: \(error)")
                    try? await inbound.send(Self.errorResponse(status: error.status, type: "invalid_request_error",
                                                               message: "Topo's proxy could not read the request: \(error)"))
                }
                return
            } catch {
                return
            }
            // The response runs as its own task so the client going away can cancel it, and the
            // cancellation reaches the upstream request through the body stream.
            let work = Task { await self.respond(to: request, on: inbound) }
            inbound.whenEnded { work.cancel() }
            let reusable = await work.value
            inbound.whenEnded(nil)
            guard reusable, request.keepAlive, !Task.isCancelled else { return }
        }
    }

    /// Forwards one request and streams its response back. True when the connection can carry
    /// another request after it.
    func respond(to request: InboundRequest, on inbound: Inbound) async -> Bool {
        let started = ContinuousClock.now
        let line = "\(request.method) \(request.path)"
        guard request.method != "CONNECT" else {
            log("\(line) refused: no tunnels")
            try? await inbound.send(Self.errorResponse(status: 405, type: "invalid_request_error", message: "Topo's proxy does not tunnel."))
            return false
        }
        var body = request.body
        #if DEBUG
        if APIProxy.pinnedModel != nil, Self.canonical(request.path) == nil {
            log("\(line) refused: the path is still percent-encoded after \(Self.decodePasses) decodes")
            try? await inbound.send(Self.errorResponse(status: 400, type: "invalid_request_error",
                                                       message: "A debug build of Topo refuses a path still percent-encoded after \(Self.decodePasses) decodes: it cannot tell whether the request needs its model pinned."))
            return request.keepAlive
        }
        if let pinned = APIProxy.pinnedModel, request.method == "POST", Self.canonical(request.path) == "/v1/messages" {
            guard let rewritten = Self.pin(body, to: pinned) else {
                log("\(line) refused: the debug pin could not read the body")
                try? await inbound.send(Self.errorResponse(status: 400, type: "invalid_request_error",
                                                           message: "A debug build of Topo pins every request to \(pinned) and could not read this one's model."))
                return request.keepAlive
            }
            body = rewritten
        }
        #endif
        let outbound = UpstreamRequest(method: request.method, target: request.target,
                                       headers: Self.filter(request.headers, dropping: Self.requestDropped),
                                       body: body.isEmpty ? nil : body)
        let response: UpstreamResponse
        let route = "\(request.method) \(Self.routeForMark(Self.canonical(request.path)))"
        Perf.mark("proxy.request \(route) bytes=\(body.count)")
        // A timed run also reads what the request is made of and what the API counted of it.
        let counted = Perf.recording && request.method == "POST" && Self.canonical(request.path) == "/v1/messages"
        if counted, let shape = Self.shapeForMark(body) { Perf.mark("proxy.shape \(shape)") }
        do {
            response = try await upstream.send(outbound)
            Perf.mark("proxy.head \(route) \(response.status)")
        } catch {
            if Task.isCancelled { log("\(line) cancelled: the client went away"); return false }
            // A target that would leave the one origin is the guest's request at fault; anything
            // else is the upstream failing, and a bad gateway.
            let status = { if case .foreignTarget? = error as? UpstreamError { 400 } else { 502 } }()
            log("\(line) \(status) in \(Self.elapsed(since: started)): failed upstream: \(Self.describe(error))")
            try? await inbound.send(Self.errorResponse(status: status, type: "api_error",
                                                       message: "Topo's proxy could not reach api.anthropic.com: \(Self.describe(error))"))
            return request.keepAlive
        }

        let hasBody = ResponseWriter.hasBody(status: response.status, method: request.method)
        let chunkedOut = hasBody && request.version == "HTTP/1.1"
        var headers = Self.filter(response.headers, dropping: Self.responseDropped)
        if chunkedOut { headers.append(HTTPField("Transfer-Encoding", "chunked")) }
        // An HTTP/1.0 client reads the body to the end of the connection.
        let keepOpen = request.keepAlive && (chunkedOut || !hasBody)
        if !keepOpen { headers.append(HTTPField("Connection", "close")) }
        do {
            try await inbound.send(ResponseWriter.head(status: response.status, headers: headers))
            if hasBody {
                var first = true
                var opening = Data(), closing = Data(), usageMarked = false
                for try await chunk in response.body where !chunk.isEmpty {
                    if first { Perf.mark("proxy.firstByte \(route)"); first = false }
                    try await inbound.send(chunkedOut ? ResponseWriter.chunk(chunk) : chunk)
                    // Read after the chunk has gone on, and only a copy of the stream's two ends.
                    if counted {
                        if !usageMarked, opening.count < Self.usageWindow {
                            opening.append(chunk)
                            if let usage = Self.usageForMark(opening) { Perf.mark("proxy.usage \(usage)"); usageMarked = true }
                        }
                        closing = (closing + chunk).suffix(Self.usageWindow)
                    }
                }
                if counted, let out = Self.count("output_tokens", in: String(decoding: closing, as: UTF8.self)) {
                    Perf.mark("proxy.usage.out \(out)")
                }
                try Task.checkCancellation()
                if chunkedOut { try await inbound.send(ResponseWriter.lastChunk) }
            }
        } catch {
            // Headers are gone, so the status cannot change: the connection closes short of the
            // last chunk, which the client reads as a truncated response.
            log("\(line) \(response.status) cut short after \(Self.elapsed(since: started)): \(Task.isCancelled ? "the client went away" : Self.describe(error))")
            return false
        }
        log("\(line) \(response.status) in \(Self.elapsed(since: started))")
        Perf.mark("proxy.done \(route)")
        return keepOpen
    }

    /// The body with its `model` replaced, or nil when it is not a JSON object.
    /// How many layers of percent-encoding the pin decodes. A path still encoded after that many
    /// is one no client writes, and a debug build refuses it rather than decoding further: each
    /// pass reads the whole path, and the path is the guest's to make as long as the head allows.
    static let decodePasses = 3

    /// A path as the pin judges it: percent-encoding decoded for up to `decodePasses` layers,
    /// backslashes read as slashes, empty and `.` segments dropped, `..` resolved, lowercased, and
    /// with no trailing slash. Nil when a layer of encoding is left after the last pass.
    static func canonical(_ path: String) -> String? {
        var decoded = path
        for _ in 0..<decodePasses {
            guard let next = decoded.removingPercentEncoding, next != decoded else { break }
            decoded = next
        }
        if let next = decoded.removingPercentEncoding, next != decoded { return nil }
        var segments: [Substring] = []
        for segment in decoded.lowercased().replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            switch segment {
            case ".": continue
            case "..": _ = segments.popLast()
            default: segments.append(segment)
            }
        }
        return "/" + segments.joined(separator: "/")
    }

    static func pin(_ body: Data, to model: String) -> Data? {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        object["model"] = model
        return try? JSONSerialization.data(withJSONObject: object)
    }

    /// An answer shaped like the API's own errors, so Claude Code reports what it says.
    static func errorResponse(status: Int, type: String, message: String) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "type": "error", "error": ["type": type, "message": message],
        ], options: [.sortedKeys])) ?? Data()
        var response = ResponseWriter.head(status: status, headers: [
            HTTPField("Content-Type", "application/json"),
            HTTPField("Content-Length", String(body.count)),
        ])
        response.append(body)
        return response
    }

    static func describe(_ error: Error) -> String {
        if let url = error as? URLError { return "URLError \(url.code.rawValue)" }
        return String(describing: error)
    }

    static func elapsed(since start: ContinuousClock.Instant) -> String {
        let duration = ContinuousClock.now - start
        let ms = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
        return "\(ms) ms"
    }
}
