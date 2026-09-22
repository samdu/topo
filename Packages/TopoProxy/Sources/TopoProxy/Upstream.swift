import Foundation

/// A request on its way out: the method, the path and query exactly as the guest wrote them, the
/// headers left once the proxy has taken out what is the connection's own, and the whole body.
public struct UpstreamRequest: Sendable {
    public var method: String
    public var target: String
    public var headers: [HTTPField]
    public var body: Data?
}

/// A response on its way back: status and headers once they arrive, the body as a stream of
/// whatever chunks the network hands over. Ending the iteration early — a client gone, a task
/// cancelled — ends the upstream request.
public struct UpstreamResponse: Sendable {
    public var status: Int
    public var headers: [HTTPField]
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [HTTPField], body: AsyncThrowingStream<Data, Error>) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

/// Where requests go. `URLSessionUpstream` in the app; a stub in the tests, so the suite runs
/// offline.
public protocol Upstream: Sendable {
    func send(_ request: UpstreamRequest) async throws -> UpstreamResponse
}

public enum UpstreamError: Error, Equatable {
    /// The target would have named somewhere other than the one origin.
    case foreignTarget(String)
    case notHTTP
}

/// The one upstream, over `URLSession`: every request goes to `origin` (api.anthropic.com), TLS
/// by URLSession, and nowhere else. Redirects are refused — the 3xx itself is what comes back — so
/// no request follows one to another host. The body is handed on chunk by chunk from the data
/// delegate as it arrives. The session keeps no cookies and no cache, and decodes any content
/// coding itself, which is why the proxy takes `Accept-Encoding` out of the request and
/// `Content-Encoding` out of the response.
public final class URLSessionUpstream: Upstream, @unchecked Sendable {
    public static let anthropic = URL(string: "https://api.anthropic.com")!

    public let origin: URL
    private let session: URLSession
    private let relay = Relay()
    /// How long the upstream may go quiet before the request fails: a streamed reply pings well
    /// inside this, and a long one is still streaming.
    public var idleTimeout: TimeInterval = 600

    /// - Parameters:
    ///   - origin: api.anthropic.com; a test's local stub origin in the suite.
    ///   - configuration: the session's; a test adds a `URLProtocol` to it.
    public init(origin: URL = URLSessionUpstream.anthropic, configuration: URLSessionConfiguration = .ephemeral) {
        self.origin = origin
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// The URL a target names on the one origin, or nil if putting them together would name any
    /// other scheme, host or port.
    func url(for target: String) -> URL? {
        guard target.hasPrefix("/"), !target.contains("#") else { return nil }
        var base = origin.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + target),
              url.scheme == origin.scheme, url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    public func send(_ request: UpstreamRequest) async throws -> UpstreamResponse {
        guard let url = url(for: request.target) else { throw UpstreamError.foreignTarget(request.target) }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = idleTimeout
        for field in request.headers { urlRequest.addValue(field.value, forHTTPHeaderField: field.name) }
        urlRequest.httpBody = request.body
        let task = session.dataTask(with: urlRequest)
        let (body, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        continuation.onTermination = { termination in
            if case .cancelled = termination { task.cancel() }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (head: CheckedContinuation<UpstreamResponse, Error>) in
                relay.register(task.taskIdentifier, head: head, body: body, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The session's delegate: one entry per task, the head handed over once and the body yielded
    /// as it arrives.
    private final class Relay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Entry {
            var head: CheckedContinuation<UpstreamResponse, Error>?
            var body: AsyncThrowingStream<Data, Error>
            var continuation: AsyncThrowingStream<Data, Error>.Continuation
        }

        private let lock = NSLock()
        private var entries: [Int: Entry] = [:]

        func register(_ id: Int, head: CheckedContinuation<UpstreamResponse, Error>,
                      body: AsyncThrowingStream<Data, Error>, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            lock.withLock { entries[id] = Entry(head: head, body: body, continuation: continuation) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let pending: (CheckedContinuation<UpstreamResponse, Error>, AsyncThrowingStream<Data, Error>)? = lock.withLock {
                guard var entry = entries[dataTask.taskIdentifier], let head = entry.head else { return nil }
                entry.head = nil
                entries[dataTask.taskIdentifier] = entry
                return (head, entry.body)
            }
            guard let (head, body) = pending else { completionHandler(.cancel); return }
            guard let http = response as? HTTPURLResponse else {
                head.resume(throwing: UpstreamError.notHTTP)
                completionHandler(.cancel)
                return
            }
            let headers = http.allHeaderFields.compactMap { key, value -> HTTPField? in
                guard let name = key as? String else { return nil }
                return HTTPField(name, "\(value)")
            }.sorted { $0.name.lowercased() < $1.name.lowercased() }
            head.resume(returning: UpstreamResponse(status: http.statusCode, headers: headers, body: body))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let continuation = lock.withLock { entries[dataTask.taskIdentifier]?.continuation }
            continuation?.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let entry = lock.withLock({ entries.removeValue(forKey: task.taskIdentifier) }) else { return }
            if let head = entry.head {
                head.resume(throwing: error ?? UpstreamError.notHTTP)
            }
            if let error { entry.continuation.finish(throwing: error) } else { entry.continuation.finish() }
        }
    }
}
