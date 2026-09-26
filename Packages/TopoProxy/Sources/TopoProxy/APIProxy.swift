import Foundation
import Network
import os
import TopoAuth

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
/// is judged in its canonical form (`canonical(_:)`), since the upstream resolves a doubled
/// slash, a dot segment or percent-encoding to the same endpoint.
public actor APIProxy {
    public typealias Log = @Sendable (String) -> Void

    /// The model a debug build's requests are rewritten to; nil in a release build.
    public static let pinnedModel: String? = {
        #if DEBUG
        "claude-haiku-4-5-20251001"
        #else
        nil
        #endif
    }()

    /// The largest request body accepted; Claude Code's are JSON, images included.
    public static let bodyLimit = 32 * 1024 * 1024

    public static let defaultLog: Log = { line in
        Logger(subsystem: "zone.hexagon.topo", category: "proxy").info("\(line, privacy: .public)")
    }

    private let listener: NWListener
    private let forwarder: Forwarder
    private let queue = DispatchQueue(label: "zone.hexagon.topo.proxy")
    private var ready: CheckedContinuation<UInt16, any Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    public private(set) var port: UInt16?

    public init(upstream: any Upstream = URLSessionUpstream(), log: @escaping Log = APIProxy.defaultLog) throws {
        let parameters = NWParameters.tcp
        // Loopback only: the listener is bound to 127.0.0.1, so no other interface — and no LAN
        // peer — reaches it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        forwarder = Forwarder(upstream: upstream, log: log)
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

    /// Stops listening and closes every connection, which cancels every request in flight.
    public func stop() {
        listener.cancel()
        port = nil
        for connection in connections.values { connection.cancel() }
        connections = [:]
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
        guard listener.state != .cancelled else { connection.cancel(); return }
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
        do {
            response = try await upstream.send(outbound)
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
                for try await chunk in response.body where !chunk.isEmpty {
                    try await inbound.send(chunkedOut ? ResponseWriter.chunk(chunk) : chunk)
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
        return keepOpen
    }

    /// The body with its `model` replaced, or nil when it is not a JSON object.
    /// A path as the pin judges it: percent-encoding decoded until nothing is left to decode,
    /// backslashes read as slashes, empty and `.` segments dropped, `..` resolved, lowercased, and
    /// with no trailing slash. It errs towards naming `/v1/messages`: a spelling the upstream would
    /// not resolve there costs nothing more than a pinned model.
    static func canonical(_ path: String) -> String {
        var decoded = path
        while let next = decoded.removingPercentEncoding, next != decoded { decoded = next }
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
