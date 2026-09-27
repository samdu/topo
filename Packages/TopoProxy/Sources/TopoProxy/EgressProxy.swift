import Foundation
import Network
import os

/// The guest's way to the few hosts it may fetch software from: a plain-HTTP/1.1 forward proxy on
/// `127.0.0.1` at a port picked at start, beside the API proxy and sharing its reader and writer.
/// TLS does not work under the emulator, so the guest's clients are pointed at `http://` URLs and
/// this proxy speaks TLS for them: it takes an absolute `http://` request to a host on `hosts`, and
/// forwards it as `https://<host><path>` on 443 (`URLSessionEgress`), the response streamed back as
/// the guest reads it.
///
/// Everything else is refused before any upstream connection is made (`judge`): `CONNECT` (405 —
/// the proxy never tunnels), a request-target that is not an absolute `http://` URI, `https://`
/// included (400), and a host off the list, an explicit port other than 80, a userinfo part or an
/// IP literal (403). Headers go through unchanged but for the hop's own; the proxy holds no
/// credential and adds none. It logs the method, host, path, status, bytes and time of each request
/// and never a header value or a query string. A refusal answered on the head closes the
/// connection, since the request's body was never read.
public actor EgressProxy {
    public typealias Log = @Sendable (String) -> Void

    /// Every host the proxy connects to, matched on the request's host lowercased, with no
    /// resolution: Alpine's CDN and GitHub's hosts for git, `gh` and release downloads.
    public static let hosts: Set<String> = [
        "dl-cdn.alpinelinux.org",
        "github.com",
        "api.github.com",
        "codeload.github.com",
        "objects.githubusercontent.com",
        "raw.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// The largest request body accepted: the API proxy's.
    public static let bodyLimit = APIProxy.bodyLimit

    public static let defaultLog: Log = { line in
        Logger(subsystem: "zone.hexagon.topo", category: "egress").info("\(line, privacy: .public)")
    }

    private let listener: NWListener
    private let upstream: any EgressUpstream
    private let log: Log
    private let queue = DispatchQueue(label: "zone.hexagon.topo.egress")
    private var ready: CheckedContinuation<UInt16, any Error>?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    public private(set) var port: UInt16?

    public init(upstream: any EgressUpstream = URLSessionEgress(), log: @escaping Log = EgressProxy.defaultLog) throws {
        let parameters = NWParameters.tcp
        // Loopback only, as the API proxy: no other interface, and no LAN peer, reaches it.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.upstream = upstream
        self.log = log
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

    /// The proxy's URL, as the guest's clients are given it.
    public static func proxyURL(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    /// The prefixes git is told to rewrite from `https://` to `http://` (`url.<http>.insteadOf`),
    /// so a clone of an `https://github.com/…` URL comes through the proxy rather than failing at
    /// the guest's own TLS.
    public static let gitRewrites = ["github.com", "codeload.github.com", "objects.githubusercontent.com", "raw.githubusercontent.com"]

    /// What the guest's environment gains so its clients use the proxy on `port`: `http_proxy` in
    /// both spellings, loopback exempt (`no_proxy`, so Claude Code still reaches the API proxy
    /// directly), and git's configuration through its environment (`GIT_CONFIG_COUNT`), so no file
    /// under the home is written for it. No `https_proxy`: a client given one would `CONNECT`.
    public static func guestEnvironment(port: UInt16) -> [String: String] {
        let url = proxyURL(port: port)
        var git: [(String, String)] = [("http.proxy", url)]
        git += gitRewrites.map { ("url.http://\($0)/.insteadOf", "https://\($0)/") }
        var environment = [
            "http_proxy": url, "HTTP_PROXY": url,
            "no_proxy": "127.0.0.1,localhost", "NO_PROXY": "127.0.0.1,localhost",
            "GIT_CONFIG_COUNT": String(git.count),
        ]
        for (index, (key, value)) in git.enumerated() {
            environment["GIT_CONFIG_KEY_\(index)"] = key
            environment["GIT_CONFIG_VALUE_\(index)"] = value
        }
        return environment
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
        let forwarder = EgressForwarder(upstream: upstream, log: log)
        Task.detached {
            await forwarder.serve(inbound)
            connection.cancel()
            await self.forget(id)
        }
    }

    private func forget(_ id: ObjectIdentifier) {
        connections[id] = nil
    }

    /// Where a request the proxy takes goes: a host on the list and the path and query to ask it.
    struct Destination: Equatable {
        var host: String
        var target: String
    }

    /// Why a request is refused, and its status.
    struct Refusal: Error, Equatable {
        var status: Int
        var reason: String
    }

    /// The whole of the destination policy, applied to the request line before anything else is
    /// read or any connection made.
    static func judge(method: String, target: String) -> Result<Destination, Refusal> {
        if method == "CONNECT" { return .failure(Refusal(status: 405, reason: "no tunnels")) }
        let lowered = target.lowercased()
        if lowered.hasPrefix("https://") {
            return .failure(Refusal(status: 400, reason: "https:// in the request line: ask for http://, the proxy speaks TLS itself"))
        }
        guard lowered.hasPrefix("http://") else {
            return .failure(Refusal(status: 400, reason: "not an absolute http:// request-target"))
        }
        if target.contains("#") { return .failure(Refusal(status: 400, reason: "a fragment in the request-target")) }
        let rest = target.dropFirst("http://".count)
        let authority = rest.prefix { $0 != "/" && $0 != "?" }
        let remainder = rest.dropFirst(authority.count)
        if authority.contains("@") { return .failure(Refusal(status: 403, reason: "a userinfo part")) }
        if authority.hasPrefix("[") { return .failure(Refusal(status: 403, reason: "an IP literal")) }
        var host = authority
        if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            guard authority[authority.index(after: colon)...] == "80" else {
                return .failure(Refusal(status: 403, reason: "a port other than 80"))
            }
        }
        let name = host.lowercased()
        guard hosts.contains(name) else { return .failure(Refusal(status: 403, reason: "a host off the list")) }
        let path = remainder.isEmpty ? "/" : remainder.hasPrefix("?") ? "/" + remainder : String(remainder)
        return .success(Destination(host: name, target: path))
    }
}

/// One connection's requests, in order, each judged on its head, forwarded and its response
/// streamed back before the next is read.
struct EgressForwarder: Sendable {
    let upstream: any EgressUpstream
    let log: EgressProxy.Log

    func serve(_ inbound: Inbound) async {
        while true {
            let destination: EgressProxy.Destination
            var request: InboundRequest
            do {
                guard let raw = try await inbound.read(through: RequestReader.headEnd, maximum: RequestReader.headLimit,
                                                       tooLarge: .headTooLarge) else { return }
                request = try RequestReader.parseHead(raw, originFormOnly: false)
                switch EgressProxy.judge(method: request.method, target: request.target) {
                case .failure(let refusal):
                    log("\(request.method) refused (\(refusal.status)): \(refusal.reason)")
                    try? await inbound.send(Self.refusal(status: refusal.status, message: "Topo's egress proxy refused the request: \(refusal.reason)."))
                    return
                case .success(let judged):
                    destination = judged
                }
                request.body = try await RequestReader.body(for: request, from: inbound, limit: EgressProxy.bodyLimit)
            } catch let error as WireError {
                if error != .closed {
                    log("refused a request: \(error)")
                    try? await inbound.send(Self.refusal(status: error.status, message: "Topo's egress proxy could not read the request: \(error)"))
                }
                return
            } catch {
                return
            }
            // The response runs as its own task so the client going away can cancel it, and the
            // cancellation reaches the upstream request through the body stream.
            let judged = request
            let work = Task { await self.respond(to: judged, at: destination, on: inbound) }
            inbound.whenEnded { work.cancel() }
            let reusable = await work.value
            inbound.whenEnded(nil)
            guard reusable, request.keepAlive, !Task.isCancelled else { return }
        }
    }

    /// Forwards one request and streams its response back, one chunk asked of the upstream only
    /// once the one before it is written. True when the connection can carry another request.
    func respond(to request: InboundRequest, at destination: EgressProxy.Destination, on inbound: Inbound) async -> Bool {
        let started = ContinuousClock.now
        let path = String(destination.target.prefix { $0 != "?" })
        let line = "\(request.method) \(destination.host) \(path)"
        let outbound = EgressRequest(host: destination.host, method: request.method, target: destination.target,
                                     headers: Forwarder.filter(request.headers, dropping: Forwarder.requestDropped),
                                     body: request.body.isEmpty ? nil : request.body)
        let response: EgressResponse
        do {
            response = try await upstream.send(outbound)
        } catch {
            if Task.isCancelled { log("\(line) cancelled: the client went away"); return false }
            log("\(line) 502 in \(Forwarder.elapsed(since: started)): failed upstream: \(Forwarder.describe(error))")
            try? await inbound.send(Self.refusal(status: 502, message: "Topo's egress proxy could not reach \(destination.host): \(Forwarder.describe(error))", close: false))
            return request.keepAlive
        }

        let hasBody = ResponseWriter.hasBody(status: response.status, method: request.method)
        let chunkedOut = hasBody && request.version == "HTTP/1.1"
        var headers = Forwarder.filter(response.headers, dropping: Forwarder.responseDropped)
        if chunkedOut { headers.append(HTTPField("Transfer-Encoding", "chunked")) }
        // An HTTP/1.0 client reads the body to the end of the connection.
        let keepOpen = request.keepAlive && (chunkedOut || !hasBody)
        if !keepOpen { headers.append(HTTPField("Connection", "close")) }
        var bytes = 0
        do {
            try await inbound.send(ResponseWriter.head(status: response.status, headers: headers))
            if hasBody {
                for try await chunk in response.body where !chunk.isEmpty {
                    try await inbound.send(chunkedOut ? ResponseWriter.chunk(chunk) : chunk)
                    bytes += chunk.count
                    response.delivered(chunk.count)
                }
                try Task.checkCancellation()
                if chunkedOut { try await inbound.send(ResponseWriter.lastChunk) }
            }
        } catch {
            // Headers are gone, so the status cannot change: the connection closes short of the
            // last chunk, which the client reads as a truncated response.
            log("\(line) \(response.status) cut short after \(bytes) bytes in \(Forwarder.elapsed(since: started)): \(Task.isCancelled ? "the client went away" : Forwarder.describe(error))")
            return false
        }
        log("\(line) \(response.status) \(bytes) bytes in \(Forwarder.elapsed(since: started))")
        return keepOpen
    }

    static func refusal(status: Int, message: String, close: Bool = true) -> Data {
        let body = Data((message + "\n").utf8)
        var headers = [HTTPField("Content-Type", "text/plain; charset=utf-8"), HTTPField("Content-Length", String(body.count))]
        if close { headers.append(HTTPField("Connection", "close")) }
        var response = ResponseWriter.head(status: status, headers: headers)
        response.append(body)
        return response
    }
}
