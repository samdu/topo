import Foundation

/// A request the egress proxy has judged and is sending on: the host from the list, the path and
/// query, the headers less the hop's own, and the whole body.
public struct EgressRequest: Sendable {
    public var host: String
    public var method: String
    public var target: String
    public var headers: [HTTPField]
    public var body: Data?
}

/// A response on its way back. The body is paced: the proxy reports each chunk it has written to
/// the guest (`delivered`), and the upstream reads ahead only a bounded amount past what it was
/// told was delivered. Ending the iteration early ends the upstream request.
public struct EgressResponse: Sendable {
    public var status: Int
    public var headers: [HTTPField]
    public var body: AsyncThrowingStream<Data, Error>
    public var delivered: @Sendable (Int) -> Void

    public init(status: Int, headers: [HTTPField], body: AsyncThrowingStream<Data, Error>,
                delivered: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.status = status
        self.headers = headers
        self.body = body
        self.delivered = delivered
    }
}

/// Where the egress proxy's requests go. `URLSessionEgress` in the app and in the suite, whose
/// `origin` seam is what points a test at a stub.
public protocol EgressUpstream: Sendable {
    func send(_ request: EgressRequest) async throws -> EgressResponse
}

/// The egress proxy's upstream over `URLSession`: `https://<host><target>`, TLS by URLSession,
/// redirects refused (the 3xx itself goes back, for the guest's client to follow or not), no
/// cookies, no cache, content codings undone by the session as for the API proxy. The body is
/// handed on as the data delegate delivers it, and the task is suspended while more than
/// `highWater` bytes are waiting to be written to the guest, then resumed once they are down to
/// `lowWater`, so a slow reader never has a whole response held in memory for it.
public final class URLSessionEgress: EgressUpstream, @unchecked Sendable {
    /// The origin a host is reached at: `https://<host>` in the app; a test's local stub in the
    /// suite. The proxy's list is applied before this is asked, so no test widens it.
    public typealias Origin = @Sendable (String) -> URL

    public static let tls: Origin = { host in URL(string: "https://\(host)")! }

    public static let highWater = 256 * 1024
    public static let lowWater = 64 * 1024

    private let origin: Origin
    private let session: URLSession
    private let relay = Relay()
    /// How long the upstream may go quiet before the request fails. A suspended task is not
    /// subject to it.
    public var idleTimeout: TimeInterval = 600

    public init(origin: @escaping Origin = URLSessionEgress.tls, configuration: URLSessionConfiguration = .ephemeral) {
        self.origin = origin
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        configuration.connectionProxyDictionary = [:]
        session = URLSession(configuration: configuration, delegate: relay, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    /// The most bytes any response has had waiting between the network and the guest.
    var peakBuffered: Int { relay.peak }

    /// The URL `target` names at `host`'s origin, or nil if putting them together would name any
    /// other scheme, host or port.
    func url(host: String, target: String) -> URL? {
        let base = origin(host)
        guard target.hasPrefix("/"), !target.contains("#"),
              let url = URL(string: base.absoluteString.trimmingSuffix("/") + target),
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    public func send(_ request: EgressRequest) async throws -> EgressResponse {
        guard let url = url(host: request.host, target: request.target) else { throw UpstreamError.foreignTarget(request.target) }
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
        let relay = relay
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (head: CheckedContinuation<EgressResponse, Error>) in
                relay.register(task, head: head, body: body, continuation: continuation)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// The session's delegate: one entry per task, the head handed over once, the body yielded as
    /// it arrives, and the bytes not yet delivered counted against the high water.
    private final class Relay: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private struct Entry {
            var task: URLSessionDataTask
            var head: CheckedContinuation<EgressResponse, Error>?
            var body: AsyncThrowingStream<Data, Error>
            var continuation: AsyncThrowingStream<Data, Error>.Continuation
            var buffered = 0
            var suspended = false
        }

        private let lock = NSLock()
        private var entries: [Int: Entry] = [:]
        private var peakBuffered = 0

        var peak: Int { lock.withLock { peakBuffered } }

        func register(_ task: URLSessionDataTask, head: CheckedContinuation<EgressResponse, Error>,
                      body: AsyncThrowingStream<Data, Error>, continuation: AsyncThrowingStream<Data, Error>.Continuation) {
            lock.withLock { entries[task.taskIdentifier] = Entry(task: task, head: head, body: body, continuation: continuation) }
        }

        /// The proxy wrote `count` bytes of task `id`'s body to the guest.
        func delivered(_ count: Int, of id: Int) {
            let resume: URLSessionDataTask? = lock.withLock {
                guard var entry = entries[id] else { return nil }
                entry.buffered -= count
                let resume = entry.suspended && entry.buffered <= URLSessionEgress.lowWater
                if resume { entry.suspended = false }
                entries[id] = entry
                return resume ? entry.task : nil
            }
            resume?.resume()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let id = dataTask.taskIdentifier
            let pending: (CheckedContinuation<EgressResponse, Error>, AsyncThrowingStream<Data, Error>)? = lock.withLock {
                guard var entry = entries[id], let head = entry.head else { return nil }
                entry.head = nil
                entries[id] = entry
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
            head.resume(returning: EgressResponse(status: http.statusCode, headers: headers, body: body,
                                                  delivered: { [weak self] count in self?.delivered(count, of: id) }))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let (continuation, suspend): (AsyncThrowingStream<Data, Error>.Continuation?, Bool) = lock.withLock {
                guard var entry = entries[dataTask.taskIdentifier] else { return (nil, false) }
                entry.buffered += data.count
                peakBuffered = max(peakBuffered, entry.buffered)
                let suspend = !entry.suspended && entry.buffered > URLSessionEgress.highWater
                if suspend { entry.suspended = true }
                entries[dataTask.taskIdentifier] = entry
                return (entry.continuation, suspend)
            }
            if suspend { dataTask.suspend() }
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

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var trimmed = self
        while trimmed.hasSuffix(suffix) { trimmed.removeLast(suffix.count) }
        return trimmed
    }
}
