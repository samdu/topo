import Foundation
import Network
import Testing
import TopoAuth
@testable import TopoProxy

@Suite struct CredentialTests {
    /// Review focus 1: the guest's `Authorization` reaches the upstream byte for byte, and no line
    /// the proxy logs contains it.
    @Test func theGuestsAuthorizationGoesThroughUnchangedAndIsNeverLogged() async throws {
        let token = "sk-ant-oat01-guest-\(UUID().uuidString)"
        let upstream = StubUpstream()
        let (proxy, port, logs) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages?beta=true", body: #"{"model":"claude-haiku-4-5-20251001"}"#,
                                   headers: ["Authorization: Bearer \(token)", "anthropic-beta: oauth-2025-04-20"]))
        let (head, _) = try await client.readResponse()
        #expect(head.status == 200)

        let seen = try #require(upstream.requests.first)
        #expect(seen.headers.values("Authorization") == ["Bearer \(token)"])
        #expect(seen.headers.value("anthropic-beta") == "oauth-2025-04-20")
        #expect(seen.target == "/v1/messages?beta=true")
        #expect(!logs.lines.isEmpty)
        for line in logs.lines {
            #expect(!line.contains(token), "logged: \(line)")
            #expect(!line.contains("Bearer"), "logged: \(line)")
        }
    }

    /// Review focus 4, the launch path's half: the environment the guest is handed carries the
    /// long-lived token sign-in minted, and the ordinary access token only when there is none.
    @Test func theGuestsEnvironmentCarriesTheLongLivedToken() async throws {
        let ordinary = InMemoryTokenStore(Tokens(accessToken: "ordinary", refreshToken: "r", expiresAt: .distantFuture, scopes: []))
        let guest = InMemoryTokenStore(Tokens(accessToken: "long-lived", refreshToken: "", expiresAt: .distantFuture, scopes: []))
        let credential = GuestCredential(store: guest, fallback: StoredTokenProvider(store: ordinary))
        let handed = try await APIProxy.guestEnvironment(port: 4242, credential: credential)
        #expect(handed.environment == ["ANTHROPIC_BASE_URL": "http://127.0.0.1:4242", "CLAUDE_CODE_OAUTH_TOKEN": "long-lived"])
        #expect(handed.source == .longLived)

        try guest.clear()
        let fallback = try await APIProxy.guestEnvironment(port: 4242, credential: credential)
        #expect(fallback.environment["CLAUDE_CODE_OAUTH_TOKEN"] == "ordinary")
        #expect(fallback.source == .accessToken)

        try ordinary.clear()
        await #expect(throws: TokenProviderError.signedOut) { try await APIProxy.guestEnvironment(port: 4242, credential: credential) }
    }

    /// What belongs to the hop stays on it; everything else, credential included, goes on.
    @Test func hopByHopHeadersStayOnTheirHop() async throws {
        let upstream = StubUpstream { _ in
            UpstreamResponse(status: 200, headers: [
                HTTPField("Content-Type", "application/json"), HTTPField("Content-Encoding", "gzip"),
                HTTPField("Content-Length", "2"), HTTPField("Connection", "keep-alive"), HTTPField("request-id", "req_1"),
            ], body: AsyncThrowingStream { $0.yield(Data("{}".utf8)); $0.finish() })
        }
        let (proxy, port, _) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages/count_tokens", body: "{}", headers: [
            "Connection: keep-alive, X-Hop", "X-Hop: 1", "Keep-Alive: timeout=5", "Accept-Encoding: gzip",
            "x-api-key: guest-key", "Proxy-Authorization: Basic abc",
        ]))
        let (head, body) = try await client.readResponse()
        let seen = try #require(upstream.requests.first)
        let names = Set(seen.headers.map { $0.name.lowercased() })
        #expect(names.isDisjoint(with: ["connection", "x-hop", "keep-alive", "accept-encoding", "host", "content-length", "proxy-authorization"]))
        #expect(seen.headers.value("x-api-key") == "guest-key")
        #expect(seen.body == Data("{}".utf8))
        #expect(head.headers.value("request-id") == "req_1")
        #expect(head.headers.value("Content-Encoding") == nil)
        #expect(head.headers.value("Content-Length") == nil)
        #expect(head.chunked)
        #expect(body == Data("{}".utf8))
    }
}

@Suite struct StreamingTests {
    /// Review focus 2: each event reaches the client as it leaves the upstream. The stub holds the
    /// second event until the client has the first (or three seconds pass), so a proxy that
    /// collects the body before replying delivers the first only after the second was sent.
    @Test func eachEventReachesTheClientBeforeTheNextIsSent() async throws {
        let firstArrived = Signal()
        let secondSent = Signal()
        let upstream = StubUpstream { _ in
            UpstreamResponse(status: 200, headers: [HTTPField("Content-Type", "text/event-stream")], body: AsyncThrowingStream { continuation in
                Task {
                    continuation.yield(Data("event: message_start\ndata: {}\n\n".utf8))
                    _ = await firstArrived.wait(3)
                    secondSent.fire()
                    continuation.yield(Data("event: message_stop\ndata: {}\n\n".utf8))
                    continuation.finish()
                }
            })
        }
        let (proxy, port, _) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: #"{"model":"x","stream":true}"#))
        let head = try await client.readHead()
        #expect(head.status == 200)
        let first = try await client.readChunk()
        let sentBeforeArrival = secondSent.hasFired
        firstArrived.fire()
        #expect(first.map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("event: message_start") == true)
        #expect(!sentBeforeArrival, "the first event reached the client only after the upstream sent the second")
        let second = try await client.readChunk()
        #expect(second.map { String(decoding: $0, as: UTF8.self) }?.hasPrefix("event: message_stop") == true)
        #expect(try await client.readChunk() == nil)
    }

    /// Review focus 5: a client that goes away mid-stream cancels the upstream request.
    @Test func aClientThatGoesAwayCancelsTheUpstream() async throws {
        let cancelled = Signal()
        let upstream = StubUpstream { _ in
            UpstreamResponse(status: 200, headers: [HTTPField("Content-Type", "text/event-stream")], body: AsyncThrowingStream { continuation in
                continuation.onTermination = { termination in
                    if case .cancelled = termination { cancelled.fire() }
                }
                // One event, and then the upstream stays open, as a long reply does between events.
                continuation.yield(Data("event: ping\ndata: {}\n\n".utf8))
            })
        }
        let (proxy, port, logs) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: #"{"model":"x","stream":true}"#))
        _ = try await client.readHead()
        _ = try await client.readChunk()
        #expect(!cancelled.hasFired)
        client.close()
        #expect(await cancelled.wait(3), "the upstream stream was still running after the client left: \(logs.lines)")
    }
}

@Suite struct FramingTests {
    /// Review focus 6: two requests back to back on one connection, the first's head split across
    /// writes and its body chunked, the second's by Content-Length and in the same write as the
    /// first's end. Both reach the upstream whole and both responses come back, in order.
    @Test func twoRequestsOnOneConnectionArriveWholeAndAnswerInOrder() async throws {
        let upstream = StubUpstream { request in StubUpstream.ok("answer to \(request.target): \(request.body?.count ?? 0) bytes") }
        let (proxy, port, _) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)

        let firstBody = #"{"model":"x","messages":[{"role":"user","content":"one"}]}"#
        let secondBody = #"{"model":"x","messages":[{"role":"user","content":"two, a little longer"}]}"#
        let split = firstBody.index(firstBody.startIndex, offsetBy: 20)
        let chunked = String(firstBody[..<split]).utf8.count
        let rest = String(firstBody[split...])
        let pieces = [
            "POST /v1/messages/count_tokens?first HTTP/1.1\r\nHo",
            "st: 127.0.0.1\r\nContent-Type: appli",
            "cation/json\r\nTransfer-Encoding: chunked\r\n",
            "\r\n\(String(chunked, radix: 16));ext=1\r\n\(firstBody[..<split])\r\n",
            "\(String(rest.utf8.count, radix: 16))\r\n\(rest)\r\n0\r\nX-Trailer: t\r\n\r\n" + post("/v1/messages/count_tokens?second", body: secondBody),
        ]
        for piece in pieces {
            try await client.send(piece)
            try await Task.sleep(for: .milliseconds(30))
        }
        let (firstHead, firstAnswer) = try await client.readResponse()
        let (secondHead, secondAnswer) = try await client.readResponse()
        #expect(firstHead.status == 200 && secondHead.status == 200)
        #expect(String(decoding: firstAnswer, as: UTF8.self) == "answer to /v1/messages/count_tokens?first: \(firstBody.utf8.count) bytes")
        #expect(String(decoding: secondAnswer, as: UTF8.self) == "answer to /v1/messages/count_tokens?second: \(secondBody.utf8.count) bytes")
        let seen = upstream.requests
        try #require(seen.count == 2)
        #expect(seen[0].target == "/v1/messages/count_tokens?first")
        #expect(seen[1].target == "/v1/messages/count_tokens?second")
        #expect(seen.map { $0.body.map { String(decoding: $0, as: UTF8.self) } } == [firstBody, secondBody])
        #expect(seen.allSatisfy { $0.headers.value("Transfer-Encoding") == nil })
    }

    @Test func aRequestFramedTwoWaysIsRefused() async throws {
        let upstream = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send("POST /v1/messages HTTP/1.1\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n")
        let (head, _) = try await client.readResponse()
        #expect(head.status == 400)
        #expect(upstream.requests.isEmpty)
    }

    @Test func anAbsoluteTargetOrATunnelIsRefused() async throws {
        let upstream = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let first = try await WireClient(port: port)
        try await first.send("GET http://example.com/v1/models HTTP/1.1\r\nHost: example.com\r\n\r\n")
        #expect(try await first.readResponse().head.status == 400)
        let second = try await WireClient(port: port)
        try await second.send("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
        #expect(try await second.readResponse().head.status >= 400)
        #expect(upstream.requests.isEmpty)
    }

    @Test func expectContinueIsAnswered() async throws {
        let upstream = StubUpstream { request in StubUpstream.ok("\(request.body?.count ?? 0)") }
        let (proxy, port, _) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send("POST /v1/files HTTP/1.1\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n")
        #expect(try await client.readHead().status == 100)
        try await client.send("hello")
        let (head, body) = try await client.readResponse()
        #expect(head.status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "5")
    }
}

@Suite struct LoopbackTests {
    /// Review focus 3: the listener is bound to 127.0.0.1 and nothing else, so a connection to this
    /// machine's own non-loopback address is refused.
    @Test func theListenerIsBoundToLoopbackAlone() async throws {
        let (proxy, port, _) = try await startedProxy(StubUpstream())
        defer { Task { await proxy.stop() } }
        #expect(APIProxy.baseURL(port: port) == "http://127.0.0.1:\(port)")
        #expect(connect(to: "127.0.0.1", port: port) == 0)
        let addresses = nonLoopbackIPv4Addresses()
        try #require(!addresses.isEmpty, "this machine has no non-loopback IPv4 address to try")
        for address in addresses {
            #expect(connect(to: address, port: port) == ECONNREFUSED, "\(address):\(port) accepted a connection")
        }
    }

    /// Every up IPv4 address of this machine that is neither loopback nor a tunnel's.
    func nonLoopbackIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(entry.pointee.ifa_flags)
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, flags & IFF_POINTOPOINT == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append(String(cString: host))
            }
        }
        return found
    }

    /// 0 on a connection, otherwise the errno `connect` failed with.
    func connect(to address: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno }
        defer { close(fd) }
        // A bound on the attempt, so an address that drops the SYN fails the test in seconds.
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &sin.sin_addr)
        let result = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0 ? 0 : errno
    }
}

@Suite struct DebugPinTests {
    #if DEBUG
    /// Review focus 8: a debug build sends Haiku whatever model the guest asked for.
    @Test func aDebugBuildSendsHaikuWhateverTheGuestAskedFor() async throws {
        #expect(APIProxy.pinnedModel == "claude-haiku-4-5-20251001")
        let upstream = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages?beta=true", body: #"{"model":"claude-opus-5","max_tokens":5,"stream":true,"messages":[{"role":"user","content":"hi"}]}"#))
        #expect(try await client.readResponse().head.status == 200)
        let seen = try #require(upstream.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: seen.body ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "claude-haiku-4-5-20251001")
        #expect(body["max_tokens"] as? Int == 5)
        #expect(body["stream"] as? Bool == true)
        #expect((body["messages"] as? [[String: Any]])?.first?["content"] as? String == "hi")
    }

    /// A body the pin cannot read is not forwarded unpinned.
    @Test func aBodyThePinCannotReadIsRefused() async throws {
        let upstream = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: "not json"))
        let (head, body) = try await client.readResponse()
        #expect(head.status == 400)
        #expect(String(decoding: body, as: UTF8.self).contains("invalid_request_error"))
        #expect(upstream.requests.isEmpty)
    }
    #endif
}
