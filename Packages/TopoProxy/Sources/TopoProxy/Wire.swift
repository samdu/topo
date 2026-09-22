import CFNetwork
import Foundation
import Network

/// One header line, name as it was written.
public struct HTTPField: Sendable, Equatable {
    public var name: String
    public var value: String
    public init(_ name: String, _ value: String) {
        self.name = name
        self.value = value
    }
}

extension Array where Element == HTTPField {
    /// Every value under `name`, compared without case.
    func values(_ name: String) -> [String] {
        filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    func value(_ name: String) -> String? { values(name).first }

    /// The comma-separated tokens of every `name` line, lowercased: `Connection`,
    /// `Transfer-Encoding`, `Expect`.
    func tokens(_ name: String) -> [String] {
        values(name).flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}

/// Why a request could not be read, and the status it is answered with before the connection
/// closes.
enum WireError: Error, Equatable {
    case malformed(String)
    case headTooLarge
    case bodyTooLarge
    case unsupportedFraming(String)
    /// The client went away mid-request; nothing is answered.
    case closed

    var status: Int {
        switch self {
        case .malformed: 400
        case .headTooLarge: 431
        case .bodyTooLarge: 413
        case .unsupportedFraming: 501
        case .closed: 0
        }
    }
}

/// A request as it came off the wire: the head parsed by CFNetwork's `CFHTTPMessage`, the body
/// de-framed from `Content-Length` or chunked.
struct InboundRequest: Sendable {
    var method: String
    /// The request-target exactly as the client wrote it, path and query.
    var target: String
    /// "HTTP/1.1" or "HTTP/1.0".
    var version: String
    var headers: [HTTPField]
    var body: Data

    /// The path without its query.
    var path: String { String(target.prefix { $0 != "?" }) }

    /// Whether the connection stays open after the response: HTTP/1.1 unless the client said
    /// `Connection: close`, HTTP/1.0 only if it asked for keep-alive (which is not offered, so no).
    var keepAlive: Bool {
        version == "HTTP/1.1" && !headers.tokens("Connection").contains("close")
    }
}

/// The inbound side of one connection: every byte the client sends, read continuously into a
/// buffer the request reader takes from, so a client that goes away is seen while a response is
/// still streaming to it (`whenEnded`), and a request pipelined behind another waits in the buffer.
/// Receiving pauses while more than `limit` bytes wait unread.
///
/// The end of what the client sends and the client being gone are two things. A FIN is only the
/// first: a client may shut down its write side after a whole request and still read the whole
/// response, so it ends the reads (`readsEnded`) and nothing else. The client is gone when the
/// connection fails or is cancelled — a reset, or the RST a closed socket answers the next write
/// with — and only that fires `whenEnded`. A client that closed outright is therefore seen at the
/// first write after its close, which on a streamed reply is the next event or ping.
final class Inbound: @unchecked Sendable {
    let connection: NWConnection
    private let limit: Int
    private let lock = NSLock()
    private var buffer = Data()
    /// The connection failed or was cancelled: the client is gone.
    private var ended = false
    /// The client sent its FIN, or the connection is gone: nothing more will arrive.
    private var readsEnded = false
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var onEnd: (@Sendable () -> Void)?

    init(_ connection: NWConnection, limit: Int) {
        self.connection = connection
        self.limit = limit
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.end()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            let rearm: Bool = lock.withLock {
                if let data, !data.isEmpty { buffer.append(data) }
                if complete || error != nil { readsEnded = true; return false }
                if buffer.count >= limit { paused = true; return false }
                return true
            }
            if error != nil { end() } else { wake() }
            if rearm { receive() }
        }
    }

    private func end() {
        let (handler, waiting): ((@Sendable () -> Void)?, CheckedContinuation<Void, Never>?) = lock.withLock {
            guard !ended else { return (nil, nil) }
            ended = true
            readsEnded = true
            defer { onEnd = nil; waiter = nil }
            return (onEnd, waiter)
        }
        waiting?.resume()
        handler?()
    }

    private func wake() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            defer { waiter = nil }
            return waiter
        }
        waiting?.resume()
    }

    /// Calls `handler` once, when the client goes away or the connection fails — now, if it
    /// already has. Replaces any handler set before.
    func whenEnded(_ handler: (@Sendable () -> Void)?) {
        let now: Bool = lock.withLock {
            if ended { return true }
            onEnd = handler
            return false
        }
        if now { handler?() }
    }

    /// Waits until the buffer holds more than `count` bytes or the stream has ended.
    private func awaitMore(than count: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready: Bool = lock.withLock {
                if buffer.count > count || readsEnded { return true }
                waiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Takes the first `count` bytes off the buffer, resuming receipt if it had paused.
    private func take(_ count: Int) -> Data {
        let (taken, rearm): (Data, Bool) = lock.withLock {
            let taken = buffer.prefix(count)
            buffer.removeFirst(count)
            let rearm = paused && buffer.count < limit && !readsEnded
            if rearm { paused = false }
            return (Data(taken), rearm)
        }
        if rearm { receive() }
        return taken
    }

    private var snapshot: (Data, Bool) { lock.withLock { (buffer, readsEnded) } }

    /// Everything up to and including the first `delimiter`, or nil when the stream ended with
    /// nothing buffered (a client that closed between requests). Throws when more than `maximum`
    /// bytes arrive with no delimiter, or the stream ends partway.
    func read(through delimiter: Data, maximum: Int, tooLarge: WireError) async throws -> Data? {
        while true {
            let (bytes, finished) = snapshot
            if let found = bytes.range(of: delimiter) {
                let length = found.upperBound - bytes.startIndex
                guard length <= maximum else { throw tooLarge }
                return take(length)
            }
            if bytes.count > maximum { throw tooLarge }
            if finished {
                if bytes.isEmpty { return nil }
                throw WireError.closed
            }
            await awaitMore(than: bytes.count)
        }
    }

    /// Exactly `count` bytes.
    func read(count: Int) async throws -> Data {
        while true {
            let (bytes, finished) = snapshot
            if bytes.count >= count { return take(count) }
            if finished { throw WireError.closed }
            await awaitMore(than: bytes.count)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

enum RequestReader {
    static let crlf = Data("\r\n".utf8)
    static let headEnd = Data("\r\n\r\n".utf8)
    static let headLimit = 64 * 1024
    static let continueLine = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    /// The next request on the connection, or nil when the client closed cleanly between requests.
    static func next(from inbound: Inbound, bodyLimit: Int) async throws -> InboundRequest? {
        guard let raw = try await inbound.read(through: headEnd, maximum: headLimit, tooLarge: .headTooLarge) else { return nil }
        var request = try parseHead(raw)
        request.body = try await body(for: request, from: inbound, limit: bodyLimit)
        return request
    }

    /// The request line and headers, parsed by `CFHTTPMessage`. Only origin-form targets (a path)
    /// are accepted: an absolute URL would name a host, and there is one upstream.
    static func parseHead(_ raw: Data) throws -> InboundRequest {
        let message = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, true).takeRetainedValue()
        let appended = raw.withUnsafeBytes { bytes in
            CFHTTPMessageAppendBytes(message, bytes.bindMemory(to: UInt8.self).baseAddress!, raw.count)
        }
        guard appended, CFHTTPMessageIsHeaderComplete(message),
              let method = CFHTTPMessageCopyRequestMethod(message)?.takeRetainedValue() as String? else {
            throw WireError.malformed("unreadable request head")
        }
        let version = CFHTTPMessageCopyVersion(message).takeRetainedValue() as String
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else { throw WireError.malformed("unsupported version \(version)") }
        // The target as written, from the request line: CFHTTPMessage's own URL is resolved
        // against the Host header, and what is forwarded has to be exactly what the guest sent.
        let requestLine = String(decoding: raw.prefix { $0 != UInt8(ascii: "\r") }, as: UTF8.self)
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == method else { throw WireError.malformed("unreadable request line") }
        let target = String(parts[1])
        guard target.hasPrefix("/"), target.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
            throw WireError.malformed("the request-target has to be a path")
        }
        let fields = (CFHTTPMessageCopyAllHeaderFields(message)?.takeRetainedValue() as? [String: String]) ?? [:]
        let headers = fields.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { HTTPField($0.key, $0.value) }
        return InboundRequest(method: method, target: target, version: version, headers: headers, body: Data())
    }

    /// The body as its framing says: chunked, `Content-Length`, or none. A request carrying both
    /// is refused rather than guessed at, and so is any transfer coding but chunked alone.
    static func body(for request: InboundRequest, from inbound: Inbound, limit: Int) async throws -> Data {
        let codings = request.headers.tokens("Transfer-Encoding")
        let lengths = request.headers.values("Content-Length")
        if !codings.isEmpty {
            guard lengths.isEmpty else { throw WireError.malformed("both Content-Length and Transfer-Encoding") }
            guard codings == ["chunked"] else { throw WireError.unsupportedFraming(codings.joined(separator: ", ")) }
            try await sendContinueIfAsked(request, inbound)
            return try await chunked(from: inbound, limit: limit)
        }
        guard !lengths.isEmpty else { return Data() }
        let distinct = Set(lengths.flatMap { $0.split(separator: ",") }.map { $0.trimmingCharacters(in: .whitespaces) })
        guard distinct.count == 1, let text = distinct.first, !text.isEmpty, text.allSatisfy(\.isASCII),
              text.allSatisfy(\.isNumber), let length = Int(text) else {
            throw WireError.malformed("unreadable Content-Length")
        }
        guard length <= limit else { throw WireError.bodyTooLarge }
        guard length > 0 else { return Data() }
        try await sendContinueIfAsked(request, inbound)
        return try await inbound.read(count: length)
    }

    private static func sendContinueIfAsked(_ request: InboundRequest, _ inbound: Inbound) async throws {
        if request.version == "HTTP/1.1", request.headers.tokens("Expect").contains("100-continue") {
            try await inbound.send(continueLine)
        }
    }

    /// Chunks until the zero-length one, then the trailer section, which is read and dropped.
    static func chunked(from inbound: Inbound, limit: Int) async throws -> Data {
        var body = Data()
        while true {
            guard let line = try await inbound.read(through: crlf, maximum: 4096, tooLarge: .malformed("chunk size line too long")) else {
                throw WireError.closed
            }
            let text = String(decoding: line.dropLast(2), as: UTF8.self)
            let digits = text.prefix { $0 != ";" }.trimmingCharacters(in: .whitespaces)
            guard !digits.isEmpty, digits.count <= 15, digits.allSatisfy(\.isHexDigit), let size = Int(digits, radix: 16) else {
                throw WireError.malformed("unreadable chunk size")
            }
            if size == 0 {
                while true {
                    guard let trailer = try await inbound.read(through: crlf, maximum: 8192, tooLarge: .headTooLarge) else { throw WireError.closed }
                    if trailer == crlf { return body }
                }
            }
            guard body.count + size <= limit else { throw WireError.bodyTooLarge }
            body.append(try await inbound.read(count: size))
            guard try await inbound.read(count: 2) == crlf else { throw WireError.malformed("chunk not followed by CRLF") }
        }
    }
}

enum ResponseWriter {
    static let reasons: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
        301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
        408: "Request Timeout", 413: "Content Too Large", 429: "Too Many Requests", 431: "Request Header Fields Too Large",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway", 503: "Service Unavailable",
        504: "Gateway Timeout", 529: "Overloaded",
    ]

    static func head(status: Int, headers: [HTTPField]) -> Data {
        var text = "HTTP/1.1 \(status) \(reasons[status] ?? "Status")\r\n"
        for field in headers { text += "\(field.name): \(field.value)\r\n" }
        text += "\r\n"
        return Data(text.utf8)
    }

    static func chunk(_ data: Data) -> Data {
        var framed = Data(String(data.count, radix: 16).utf8)
        framed.append(RequestReader.crlf)
        framed.append(data)
        framed.append(RequestReader.crlf)
        return framed
    }

    static let lastChunk = Data("0\r\n\r\n".utf8)

    /// Whether a response to `method` with `status` has a body at all.
    static func hasBody(status: Int, method: String) -> Bool {
        !(method == "HEAD" || (100..<200).contains(status) || status == 204 || status == 304)
    }
}
