import Foundation

/// A one-shot HTTP listener on the loopback interface that catches the browser's redirect to
/// `/callback?code=…&state=…`, answers with a small page, and hands the URL back. BSD sockets
/// rather than Network.framework: a plain listener is all this is, and it must bind in a test
/// process as well as in an app.
public final class LoopbackCallback: @unchecked Sendable {
    public let port: UInt16
    private let queue = DispatchQueue(label: "zone.hexagon.topo.oauth-callback")
    private var sockets: [Int32]
    private var sources: [DispatchSourceRead] = []
    private var continuation: CheckedContinuation<URL, Swift.Error>?
    private var finished = false

    public enum Error: Swift.Error { case cancelled, bindFailed }

    /// Binds an ephemeral port on 127.0.0.1 and, when it can, the same port on ::1, so the
    /// browser reaches it whichever address it resolves `localhost` to first.
    public init() throws {
        let v4 = socket(AF_INET, SOCK_STREAM, 0)
        guard v4 >= 0 else { throw Error.bindFailed }
        var one: Int32 = 1
        setsockopt(v4, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr4 = sockaddr_in()
        addr4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr4.sin_family = sa_family_t(AF_INET)
        addr4.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        addr4.sin_port = 0
        let bound = withUnsafePointer(to: &addr4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.bind(v4, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(v4, $0, &len) }
        }
        guard bound == 0, named == 0, listen(v4, 4) == 0 else { close(v4); throw Error.bindFailed }
        port = UInt16(bigEndian: addr4.sin_port)
        sockets = [v4]

        let v6 = socket(AF_INET6, SOCK_STREAM, 0)
        if v6 >= 0 {
            setsockopt(v6, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(v6, Int32(IPPROTO_IPV6), IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_addr = in6addr_loopback
            addr6.sin6_port = port.bigEndian
            let ok = withUnsafePointer(to: &addr6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Foundation.bind(v6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            } == 0 && listen(v6, 4) == 0
            if ok { sockets.append(v6) } else { close(v6) }
        }

        for fd in sockets {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(on: fd) }
            source.resume()
            sources.append(source)
        }
    }

    deinit { tearDown() }

    /// Resolves with the callback URL the browser hit. Cancel with `cancel()`.
    public func wait() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if self.finished { continuation.resume(throwing: Error.cancelled) } else { self.continuation = continuation }
            }
        }
    }

    public func cancel() {
        queue.async {
            self.continuation?.resume(throwing: Error.cancelled)
            self.continuation = nil
            self.tearDown()
        }
    }

    private func tearDown() {
        finished = true
        sources.forEach { $0.cancel() }
        sources.removeAll()
        sockets.forEach { close($0) }
        sockets.removeAll()
    }

    private func accept(on fd: Int32) {
        let client = Foundation.accept(fd, nil, nil)
        guard client >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 8192)
        let n = read(client, &buffer, buffer.count)
        let head = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
        let target = head.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
        let url = URL(string: "http://localhost:\(port)\(target)")
        let done = url.map { $0.path == "/callback" && ClaudeOAuth.parseCallback($0) != nil } ?? false
        let body = done
            ? "<html><body style=\"font-family:-apple-system,system-ui;text-align:center;padding-top:4em\"><h1>Signed in</h1><p>You can close this window and go back to Topo.</p></body></html>"
            : "<html><body><h1>Not found</h1></body></html>"
        let response = "HTTP/1.1 \(done ? "200 OK" : "404 Not Found")\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        _ = response.utf8CString.withUnsafeBufferPointer { write(client, $0.baseAddress, $0.count - 1) }
        close(client)
        if done, let url {
            continuation?.resume(returning: url)
            continuation = nil
            tearDown()
        }
    }
}
