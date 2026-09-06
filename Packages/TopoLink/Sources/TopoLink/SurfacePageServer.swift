import Foundation
import Network

/// Serves a web-page Womble on the house's own network.
///
/// A screen gets a path of its own — `/s/<token>/`, the page, and
/// `surface.json` beside it — so the page asks for the document relative to
/// itself and never handles a token at all. The token is the whole of the
/// access control, which is why it is minted per screen, unguessable, and
/// revocable; an unknown one is `404` with nothing said about whether it was
/// ever real.
///
/// LAN only, and deliberately: a token in a path is in the browser's history
/// and in any proxy's log, so a request from anywhere but a private address
/// is refused before it is read. Nothing here goes through the tunnel.
public actor SurfacePageServer {
    /// A file the page is made of, ready to send.
    public struct File: Sendable {
        public var data: Data
        public var contentType: String

        public init(data: Data, contentType: String) {
            self.data = data
            self.contentType = contentType
        }
    }

    /// The document for a token, or nil when this hub does not know it —
    /// which is the same answer as a path that is not a screen's.
    public typealias Documents = @Sendable (String) async -> SurfaceDocument?

    private let listener: NWListener
    private let files: [String: File]
    private let documents: Documents
    private var ready: CheckedContinuation<UInt16, any Error>?
    public private(set) var port: UInt16?

    /// - Parameters:
    ///   - port: 0 picks a free one.
    ///   - files: the page itself, by name: `index.html`, `womble.css`,
    ///     `womble.js`. Served under every token this hub knows.
    ///   - documents: what to answer `surface.json` with.
    public init(port: UInt16 = 0, files: [String: File], documents: @escaping Documents) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
        self.files = files
        self.documents = documents
    }

    public func start() async throws -> UInt16 {
        if let port { return port }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.stateChanged(state) }
        }
        listener.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.page"))
        return try await withCheckedThrowingContinuation { ready = $0 }
    }

    public func stop() {
        listener.cancel()
        port = nil
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

    private func serve(_ connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.page.serve"))
        defer { connection.cancel() }
        guard Self.isLocal(connection.endpoint) else { return }
        guard let request = try? await connection.readRequest() else {
            try? await connection.send(Self.response(status: "400 Bad Request"))
            return
        }
        try? await connection.send(await answer(to: request))
    }

    /// What to send back. Split out from the connection so the tests can ask
    /// the questions a browser asks without one.
    func answer(to request: HTTPRequest) async -> Data {
        guard request.method == "GET" || request.method == "HEAD" else {
            return Self.response(status: "405 Method Not Allowed")
        }
        guard let (token, file) = Self.route(request.path) else { return Self.notFound }
        guard let document = await documents(token) else { return Self.notFound }
        if file == "surface.json" {
            guard let json = try? document.json() else {
                return Self.response(status: "500 Internal Server Error")
            }
            let etag = SurfaceDocument.etag(for: json)
            if request.headers["if-none-match"]?.split(separator: ",")
                .map({ $0.trimmingCharacters(in: .whitespaces) }).contains(etag) == true {
                return Self.response(status: "304 Not Modified", headers: ["ETag": etag])
            }
            return Self.response(status: "200 OK", headers: ["ETag": etag],
                                 body: json, contentType: "application/json; charset=utf-8",
                                 includeBody: request.method == "GET")
        }
        guard let page = files[file] else { return Self.notFound }
        return Self.response(status: "200 OK", body: page.data, contentType: page.contentType,
                             includeBody: request.method == "GET")
    }

    /// `/s/<token>/` and what may be asked for beneath it. A path with
    /// anything else in it — a `..`, a directory of its own — is not a
    /// screen's and is answered like an unknown token.
    static func route(_ path: String) -> (token: String, file: String)? {
        let withoutQuery = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let parts = withoutQuery.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // "", "s", token, file
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "s" else { return nil }
        let token = parts[2]
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        // The page is served from the token's own path, so a bare `/s/<token>/`
        // is the page itself. A name is a name: no dot to start it, and
        // nothing that could climb out of the handful of files there are.
        let file = parts[3].isEmpty ? "index.html" : parts[3]
        guard !file.hasPrefix("."),
              file.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }) else { return nil }
        return (token, file)
    }

    /// A private address, a link-local one, or the loopback: the house, in
    /// other words. Anything else is refused before its request is read.
    static func isLocal(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = address.rawValue.map { $0 }
            guard bytes.count == 4 else { return false }
            if bytes[0] == 127 || bytes[0] == 10 { return true }
            if bytes[0] == 192 && bytes[1] == 168 { return true }
            if bytes[0] == 172 && (16...31).contains(bytes[1]) { return true }
            if bytes[0] == 169 && bytes[1] == 254 { return true }
            return false
        case .ipv6(let address):
            if address.isLoopback || address.isLinkLocal { return true }
            // Unique local addresses, fc00::/7.
            return (address.rawValue.first ?? 0) & 0xFE == 0xFC
        default:
            return false
        }
    }

    static let notFound = response(status: "404 Not Found")

    static func response(status: String, headers: [String: String] = [:], body: Data = Data(),
                         contentType: String = "text/plain; charset=utf-8", includeBody: Bool = true) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // A wall screen asks every five seconds; nothing here is worth
        // holding on to between two of them.
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        if includeBody { out.append(body) }
        return out
    }
}

/// As much of a request as this serves: the line, and the headers by
/// lowercased name. There is no body to read — nothing here is written to.
struct HTTPRequest: Sendable, Equatable {
    var method: String
    var path: String
    var headers: [String: String]

    /// Nil for anything that is not a request line and headers.
    init?(_ text: String) {
        var lines = text.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return nil }
        let request = lines.removeFirst().split(separator: " ").map(String.init)
        guard request.count == 3, request[2].hasPrefix("HTTP/") else { return nil }
        method = request[0]
        path = request[1]
        headers = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
        }
    }
}

extension NWConnection {
    /// Reads until the blank line that ends the headers. A request larger
    /// than that is not a browser asking for a wall screen.
    func readRequest(maximum: Int = 8192) async throws -> HTTPRequest {
        var buffer = Data()
        while true {
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard let request = HTTPRequest(String(decoding: buffer[..<end.lowerBound], as: UTF8.self)) else {
                    throw ProbeWire.LineTooLong()
                }
                return request
            }
            guard buffer.count < maximum else { throw ProbeWire.LineTooLong() }
            let (chunk, complete) = try await receiveChunk(maximum: maximum - buffer.count)
            if let chunk { buffer.append(chunk) }
            if complete {
                guard let request = HTTPRequest(String(decoding: buffer, as: UTF8.self)) else {
                    throw ProbeWire.LineTooLong()
                }
                return request
            }
        }
    }

    private func receiveChunk(maximum: Int) async throws -> (Data?, Bool) {
        let box = OneShot<ReceivedChunk>()
        receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
            if let error { box.resume(.failure(error)); return }
            box.resume(.success(ReceivedChunk(data: data, complete: complete)))
        }
        let chunk = try await box.value()
        return (chunk.data, chunk.complete)
    }
}
