import CryptoKit
import Foundation
import Network
import Testing
@testable import TopoProxy

/// An egress upstream that counts what reaches it, over another: the proxy reaches the network
/// only through `send`, so no call is no connection.
final class CountingEgress: EgressUpstream, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [EgressRequest] = []
    let inner: any EgressUpstream

    init(_ inner: any EgressUpstream) { self.inner = inner }

    var requests: [EgressRequest] { lock.withLock { received } }

    func send(_ request: EgressRequest) async throws -> EgressResponse {
        lock.withLock { received.append(request) }
        return try await inner.send(request)
    }
}

/// An egress proxy whose every allowlisted host is the one stub origin, over the real
/// `URLSessionEgress`, started, with its log captured.
func startedEgress(origin: StubOrigin) async throws -> (EgressProxy, UInt16, LogLines, CountingEgress, URLSessionEgress) {
    let originPort = try await origin.start()
    let session = URLSessionEgress(origin: { _ in URL(string: "http://127.0.0.1:\(originPort)")! })
    let counting = CountingEgress(session)
    let lines = LogLines()
    let proxy = try EgressProxy(upstream: counting, log: lines.log)
    let port = try await proxy.start()
    return (proxy, port, lines, counting, session)
}

func okOrigin(_ text: String = "ok") throws -> StubOrigin {
    try StubOrigin { _, inbound in
        try await inbound.send(Data("HTTP/1.1 200 OK\r\nContent-Length: \(text.utf8.count)\r\n\r\n\(text)".utf8))
    }
}

@Suite struct EgressProxyTests {
    /// Sends `head` and answers the status, asserting nothing reached the upstream.
    func refusal(_ head: String) async throws -> Int {
        try await refused(head).status
    }

    /// Sends `head` and answers the status and the refusal's text, asserting nothing reached the
    /// upstream.
    func refused(_ head: String) async throws -> (status: Int, text: String) {
        let origin = try okOrigin()
        let (proxy, port, _, upstream, _) = try await startedEgress(origin: origin)
        defer { Task { await proxy.stop(); origin.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(head)
        let (answer, body) = try await client.readResponse()
        #expect(upstream.requests.isEmpty, "\(head) reached the upstream")
        #expect(origin.requests.isEmpty)
        return (answer.status, String(decoding: body, as: UTF8.self))
    }

    /// The list is a constant, and every entry is named here, so a change to it is a diff in two
    /// places.
    @Test func theListIsExactlyTheseHosts() {
        #expect(EgressProxy.hosts == [
            "dl-cdn.alpinelinux.org", "github.com", "api.github.com", "codeload.github.com",
            "objects.githubusercontent.com", "raw.githubusercontent.com", "release-assets.githubusercontent.com",
        ])
    }

    @Test func refusesConnect() async throws {
        #expect(try await refusal("CONNECT github.com:443 HTTP/1.1\r\nHost: github.com:443\r\n\r\n") == 405)
        #expect(try await refusal("CONNECT http://github.com/ HTTP/1.1\r\nHost: github.com\r\n\r\n") == 405)
    }

    @Test func refusesRelativeRequest() async throws {
        #expect(try await refusal("GET /alpine/v3.22/main/aarch64/APKINDEX.tar.gz HTTP/1.1\r\nHost: dl-cdn.alpinelinux.org\r\n\r\n") == 400)
        #expect(try await refusal("GET github.com/samdu HTTP/1.1\r\nHost: github.com\r\n\r\n") == 400)
        #expect(try await refusal("GET ftp://github.com/ HTTP/1.1\r\nHost: github.com\r\n\r\n") == 400)
    }

    @Test(arguments: ["api.anthropic.com", "127.0.0.1", "localhost", "10.0.0.1", "[::1]", "GitHub.com.evil.example",
                      "github.com.", "evilgithub.com", "gist.github.com", "example.com"])
    func refusesHostOffList(_ host: String) async throws {
        #expect(try await refusal("GET http://\(host)/ HTTP/1.1\r\nHost: \(host)\r\n\r\n") == 403)
    }

    @Test(arguments: ["443", "8080", "22", "", "080"])
    func refusesExplicitPort(_ port: String) async throws {
        #expect(try await refusal("GET http://github.com:\(port)/ HTTP/1.1\r\nHost: github.com\r\n\r\n") == 403)
    }

    @Test func refusesHttpsRequestLine() async throws {
        for target in ["https://github.com/samdu/topo", "HTTPS://github.com/"] {
            let (status, text) = try await refused("GET \(target) HTTP/1.1\r\nHost: github.com\r\n\r\n")
            #expect(status == 400)
            #expect(text.contains("https:// in the request line"), "\(target): \(text)")
        }
    }

    @Test(arguments: ["140.82.112.3", "[2606:50c0:8000::153]", "0x7f000001", "2130706433"])
    func refusesIPLiteral(_ host: String) async throws {
        #expect(try await refusal("GET http://\(host)/ HTTP/1.1\r\nHost: github.com\r\n\r\n") == 403)
    }

    /// An IPv6 literal is refused as one, whatever its brackets hold, before its colons are read
    /// as a port.
    @Test(arguments: ["[::1]", "[2606:50c0:8000::153]", "[::ffff:127.0.0.1]"])
    func refusesIPv6LiteralAsOne(_ host: String) async throws {
        let (status, text) = try await refused("GET http://\(host)/ HTTP/1.1\r\nHost: github.com\r\n\r\n")
        #expect(status == 403)
        #expect(text.contains("an IP literal"), "\(host): \(text)")
    }

    @Test func refusesUserinfo() async throws {
        #expect(try await refusal("GET http://user:secret@github.com/ HTTP/1.1\r\nHost: github.com\r\n\r\n") == 403)
        #expect(try await refusal("GET http://github.com@example.com/ HTTP/1.1\r\nHost: github.com\r\n\r\n") == 403)
    }

    /// The debug pin's only wire is the API proxy: `api.anthropic.com` is not on this list, so a
    /// `/v1/messages` through the egress proxy never goes anywhere.
    @Test func refusesAnthropicAPI() async throws {
        let body = #"{"model":"claude-opus-5","messages":[]}"#
        #expect(try await refusal("POST http://api.anthropic.com/v1/messages HTTP/1.1\r\nHost: api.anthropic.com\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)") == 403)
    }

    @Test func aRequestOnTheListIsSentOverTheOriginWithItsPathAndQuery() async throws {
        let origin = try okOrigin("fetched")
        let (proxy, port, _, upstream, _) = try await startedEgress(origin: origin)
        defer { Task { await proxy.stop(); origin.stop() } }
        let client = try await WireClient(port: port)
        try await client.send("GET http://GitHub.com/samdu/topo/info/refs?service=git-upload-pack HTTP/1.1\r\nHost: github.com\r\nProxy-Connection: keep-alive\r\nProxy-Authorization: Basic eDp5\r\nGit-Protocol: version=2\r\n\r\n")
        let (head, body) = try await client.readResponse()
        #expect(head.status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "fetched")
        let sent = try #require(upstream.requests.first)
        #expect(sent.host == "github.com")
        #expect(sent.target == "/samdu/topo/info/refs?service=git-upload-pack")
        #expect(sent.headers.value("Git-Protocol") == "version=2")
        #expect(sent.headers.value("Proxy-Connection") == nil)
        #expect(sent.headers.value("Proxy-Authorization") == nil)
        let received = try #require(origin.requests.first)
        #expect(received.target == "/samdu/topo/info/refs?service=git-upload-pack")
        #expect(received.headers.value("Proxy-Authorization") == nil)
    }

    @Test func thePort80IsTheSameAsNone() async throws {
        let origin = try okOrigin()
        let (proxy, port, _, upstream, _) = try await startedEgress(origin: origin)
        defer { Task { await proxy.stop(); origin.stop() } }
        let client = try await WireClient(port: port)
        try await client.send("GET http://dl-cdn.alpinelinux.org:80 HTTP/1.1\r\nHost: dl-cdn.alpinelinux.org\r\n\r\n")
        #expect(try await client.readResponse().head.status == 200)
        #expect(upstream.requests.map(\.target) == ["/"])
    }

    /// Only `https://<host>` on 443 is ever an upstream URL: the seam is the only thing a test
    /// changes, and the app's is `tls`.
    @Test func theAppsOriginIsTLSOnTheHostItself() {
        let egress = URLSessionEgress()
        #expect(egress.url(host: "github.com", target: "/samdu/topo")?.absoluteString == "https://github.com/samdu/topo")
        #expect(egress.url(host: "github.com", target: "@example.com/") == nil)
        #expect(egress.url(host: "github.com", target: "/a#b") == nil)
    }

    @Test func boundToLoopbackOnly() async throws {
        let origin = try okOrigin()
        let (proxy, port, _, _, _) = try await startedEgress(origin: origin)
        defer { Task { await proxy.stop(); origin.stop() } }
        #expect(EgressProxy.proxyURL(port: port) == "http://127.0.0.1:\(port)")
        let probe = LoopbackTests()
        #expect(probe.connect(to: "127.0.0.1", port: port) == 0)
        let addresses = probe.nonLoopbackIPv4Addresses()
        try #require(!addresses.isEmpty, "this machine has no non-loopback IPv4 address to try")
        for address in addresses {
            #expect(probe.connect(to: address, port: port) == ECONNREFUSED, "\(address):\(port) accepted a connection")
        }
    }

    @Test func logCarriesNoHeaderOrQuery() async throws {
        let origin = try okOrigin()
        let (proxy, port, lines, _, _) = try await startedEgress(origin: origin)
        defer { Task { await proxy.stop(); origin.stop() } }
        let client = try await WireClient(port: port)
        try await client.send("GET http://api.github.com/user?access_token=querysecret HTTP/1.1\r\nHost: api.github.com\r\nAuthorization: token headersecret\r\nCookie: cookiesecret\r\n\r\n")
        #expect(try await client.readResponse().head.status == 200)
        let refused = try await WireClient(port: port)
        try await refused.send("GET http://example.com/x?token=refusedsecret HTTP/1.1\r\nHost: example.com\r\nAuthorization: Bearer refusedheader\r\n\r\n")
        #expect(try await refused.readResponse().head.status == 403)
        let log = lines.lines.joined(separator: "\n")
        #expect(log.contains("GET api.github.com /user 200 2 bytes in "))
        for secret in ["querysecret", "access_token", "headersecret", "cookiesecret", "refusedsecret", "refusedheader", "token="] {
            #expect(!log.contains(secret), "the log carries \(secret): \(log)")
        }
    }

    @Test func redirectReturnedNotFollowed() async throws {
        let origin = try StubOrigin { _, inbound in
            try await inbound.send(Data("HTTP/1.1 302 Found\r\nLocation: https://github.com/elsewhere\r\nContent-Length: 0\r\n\r\n".utf8))
        }
        let (proxy, port, _, _, _) = try await startedEgress(origin: origin)
        defer { Task { await proxy.stop(); origin.stop() } }
        let client = try await WireClient(port: port)
        try await client.send("GET http://github.com/moved HTTP/1.1\r\nHost: github.com\r\n\r\n")
        let head = try await client.readResponse().head
        #expect(head.status == 302)
        #expect(head.headers.value("Location") == "https://github.com/elsewhere")
        #expect(origin.requests.count == 1)
    }

    @Test func streamsBeforeUpstreamEnds() async throws {
        let release = Signal()
        let origin = try StubOrigin { _, inbound in
            // A declared type, as git's smart HTTP answers carry: without one URLSession holds the
            // first 512 bytes to sniff a type from.
            try await inbound.send(Data("HTTP/1.1 200 OK\r\nContent-Type: application/x-git-upload-pack-result\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            try await inbound.send(ResponseWriter.chunk(Data("first".utf8)))
            _ = await release.wait(10)
            try await inbound.send(ResponseWriter.chunk(Data("second".utf8)))
            try await inbound.send(ResponseWriter.lastChunk)
        }
        let (proxy, port, _, _, _) = try await startedEgress(origin: origin)
        defer { Task { await proxy.stop(); origin.stop() } }
        let client = try await WireClient(port: port)
        try await client.send("POST http://github.com/samdu/topo/git-upload-pack HTTP/1.1\r\nHost: github.com\r\nContent-Length: 4\r\n\r\n0000")
        #expect(try await client.readHead().status == 200)
        #expect(try await client.readChunk() == Data("first".utf8))
        #expect(!release.hasFired)
        release.fire()
        var rest = Data()
        while let chunk = try await client.readChunk() { rest.append(chunk) }
        #expect(rest == Data("second".utf8))
    }

    @Test func largeBodyPassesWhole() async throws {
        let size = 64 * 1024 * 1024
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0..<size / 8).flatMap { _ in withUnsafeBytes(of: generator.next() as UInt64, Array.init) })
        let origin = try StubOrigin { _, inbound in
            try await inbound.send(Data("HTTP/1.1 200 OK\r\nContent-Length: \(payload.count)\r\n\r\n".utf8))
            var offset = 0
            while offset < payload.count {
                let end = min(offset + 1 << 20, payload.count)
                try await inbound.send(payload.subdata(in: offset..<end))
                offset = end
            }
        }
        let (proxy, port, _, _, _) = try await startedEgress(origin: origin)
        defer { Task { await proxy.stop(); origin.stop() } }
        let client = try await WireClient(port: port, deadline: 120)
        try await client.send("GET http://objects.githubusercontent.com/big HTTP/1.1\r\nHost: objects.githubusercontent.com\r\n\r\n")
        let head = try await client.readHead()
        #expect(head.status == 200)
        var hasher = SHA256()
        var received = 0
        while let chunk = try await client.readChunk() {
            hasher.update(data: chunk)
            received += chunk.count
        }
        #expect(received == size)
        #expect(Data(hasher.finalize()) == Data(SHA256.hash(data: payload)))
    }

    /// A client reading 1 KB a second while the origin has 16 MB ready: what the proxy holds
    /// between the network and the guest stays under 1 MB.
    @Test func slowReaderBoundsBuffering() async throws {
        let size = 16 * 1024 * 1024
        let chunk = Data(repeating: 0x61, count: 64 * 1024)
        let origin = try StubOrigin { _, inbound in
            try await inbound.send(Data("HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\n\r\n".utf8))
            for _ in 0..<(size / chunk.count) { try await inbound.send(chunk) }
        }
        let (proxy, port, _, _, session) = try await startedEgress(origin: origin)
        defer { Task { await proxy.stop(); origin.stop() } }
        let reader = SlowReader(port: port)
        defer { reader.close() }
        try #require(reader.connected, "could not connect to the proxy")
        reader.write("GET http://release-assets.githubusercontent.com/big HTTP/1.1\r\nHost: release-assets.githubusercontent.com\r\n\r\n")
        var read = 0
        for _ in 0..<8 {
            read += reader.read(upTo: 1024)
            try await Task.sleep(for: .seconds(1))
        }
        #expect(read > 0, "the slow reader got nothing")
        #expect(session.peakBuffered > 0, "nothing was counted")
        #expect(session.peakBuffered < 1024 * 1024, "the proxy held \(session.peakBuffered) bytes for a slow reader")
    }
}

/// A client on a plain socket with a small receive buffer, which reads only when told to.
final class SlowReader {
    private let fd: Int32
    let connected: Bool

    init(port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        self.fd = fd
        var small: Int32 = 4096
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &small, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &sin.sin_addr)
        connected = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    func write(_ text: String) {
        _ = text.utf8CString.withUnsafeBufferPointer { Darwin.write(fd, $0.baseAddress, $0.count - 1) }
    }

    /// Reads at most `count` bytes, answering how many.
    func read(upTo count: Int) -> Int {
        var buffer = [UInt8](repeating: 0, count: count)
        return max(0, Darwin.read(fd, &buffer, count))
    }

    func close() { Darwin.close(fd) }
}

@Suite struct EgressEnvironmentTests {
    @Test func theGuestIsHandedThePortAndGitsRewrites() {
        let environment = EgressProxy.guestEnvironment(port: 4321)
        #expect(environment["http_proxy"] == "http://127.0.0.1:4321")
        #expect(environment["HTTP_PROXY"] == "http://127.0.0.1:4321")
        #expect(environment["no_proxy"] == "127.0.0.1,localhost")
        #expect(environment["NO_PROXY"] == "127.0.0.1,localhost")
        #expect(environment["https_proxy"] == nil && environment["HTTPS_PROXY"] == nil)
        let count = Int(environment["GIT_CONFIG_COUNT"] ?? "") ?? 0
        let git = (0..<count).map { (environment["GIT_CONFIG_KEY_\($0)"] ?? "", environment["GIT_CONFIG_VALUE_\($0)"] ?? "") }
        #expect(git.first! == ("http.proxy", "http://127.0.0.1:4321"))
        for host in ["github.com", "codeload.github.com", "objects.githubusercontent.com", "raw.githubusercontent.com"] {
            #expect(git.contains { $0 == ("url.http://\(host)/.insteadOf", "https://\(host)/") }, "no rewrite for \(host)")
            #expect(EgressProxy.hosts.contains(host))
        }
    }
}
