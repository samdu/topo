import Foundation
import Network
import Testing
@testable import TopoProxy

/// `URLSessionUpstream` against local origins: the path the app takes, minus TLS.
@Suite struct UpstreamTests {
    /// Review focus 7: a redirect from the one origin is handed back to the guest, not followed,
    /// so the origin it names receives nothing.
    @Test func aRedirectIsHandedBackAndNeverFollowed() async throws {
        let elsewhere = try StubOrigin { _, inbound in
            try await inbound.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        }
        let elsewherePort = try await elsewhere.start()
        defer { elsewhere.stop() }
        let origin = try StubOrigin { _, inbound in
            try await inbound.send(Data("HTTP/1.1 307 Temporary Redirect\r\nLocation: http://127.0.0.1:\(elsewherePort)/v1/messages\r\nContent-Length: 0\r\n\r\n".utf8))
        }
        _ = try await origin.start()
        defer { origin.stop() }

        let (proxy, port, _) = try await startedProxy(URLSessionUpstream(origin: origin.url))
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: #"{"model":"x"}"#))
        let (head, _) = try await client.readResponse()
        #expect(head.status == 307)
        #expect(origin.requests.count == 1)
        try await Task.sleep(for: .milliseconds(200))
        #expect(elsewhere.requests.isEmpty, "the redirect was followed to \(elsewhere.url)")
    }

    /// Review focus 2 over URLSession: the session hands each event on as it arrives, so the first
    /// reaches the guest before the origin sends the second.
    @Test func urlSessionPassesEachEventOnAsItArrives() async throws {
        let firstArrived = Signal()
        let secondSent = Signal()
        let origin = try StubOrigin { _, inbound in
            try await inbound.send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            try await inbound.send(ResponseWriter.chunk(Data("event: message_start\ndata: {}\n\n".utf8)))
            _ = await firstArrived.wait(3)
            secondSent.fire()
            try await inbound.send(ResponseWriter.chunk(Data("event: message_stop\ndata: {}\n\n".utf8)))
            try await inbound.send(ResponseWriter.lastChunk)
        }
        _ = try await origin.start()
        defer { origin.stop() }
        let (proxy, port, _) = try await startedProxy(URLSessionUpstream(origin: origin.url))
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: #"{"model":"x","stream":true}"#))
        #expect(try await client.readHead().status == 200)
        let first = try await client.readChunk()
        let sentBeforeArrival = secondSent.hasFired
        firstArrived.fire()
        #expect(first.map { String(decoding: $0, as: UTF8.self) }?.contains("message_start") == true)
        #expect(!sentBeforeArrival, "URLSession held the first event until the second arrived")
        var rest = Data()
        while let chunk = try await client.readChunk() { rest.append(chunk) }
        #expect(String(decoding: rest, as: UTF8.self).contains("message_stop"))
    }

    /// Review focus 5 over URLSession: the guest going away closes the upstream connection.
    @Test func aClientThatGoesAwayClosesTheUpstreamConnection() async throws {
        let origin = try StubOrigin { _, inbound in
            try await inbound.send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            try await inbound.send(ResponseWriter.chunk(Data("event: message_start\ndata: {}\n\n".utf8)))
            // Then a ping every 100 ms, as the API sends between events, until the far side closes.
            while true {
                try await Task.sleep(for: .milliseconds(100))
                try await inbound.send(ResponseWriter.chunk(Data("event: ping\ndata: {}\n\n".utf8)))
            }
        }
        _ = try await origin.start()
        defer { origin.stop() }
        let (proxy, port, _) = try await startedProxy(URLSessionUpstream(origin: origin.url))
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: #"{"model":"x","stream":true}"#))
        _ = try await client.readHead()
        _ = try await client.readChunk()
        #expect(origin.closed == 0)
        client.close()
        let closed = Signal()
        Task { while origin.closed == 0 { try? await Task.sleep(for: .milliseconds(10)) }; closed.fire() }
        #expect(await closed.wait(3), "the upstream connection stayed open after the client left")
    }

    /// An upstream failure is the API-shaped 502, a response that is not HTTP included.
    @Test func aResponseThatIsNotHTTPIsABadGateway() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotHTTPProtocol.self]
        let (proxy, port, _) = try await startedProxy(URLSessionUpstream(configuration: configuration))
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: #"{"model":"x"}"#))
        let (head, body) = try await client.readResponse()
        #expect(head.status == 502)
        let error = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(error["type"] as? String == "error")
        #expect((error["error"] as? [String: Any])?["type"] as? String == "api_error")
    }

    /// The session keeps no cookies and no cache: a response that sets a cookie and says it may be
    /// cached is asked for again at the origin, with no cookie.
    @Test func theSessionKeepsNoCookiesAndNoCache() async throws {
        let origin = try StubOrigin { _, inbound in
            let body = #"{"data":[]}"#
            try await inbound.send(Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                + "Set-Cookie: topo-session=abc123; Path=/\r\nCache-Control: public, max-age=3600\r\n"
                + "Last-Modified: Mon, 21 Sep 2026 00:00:00 GMT\r\nETag: \"v1\"\r\n"
                + "Content-Length: \(body.utf8.count)\r\n\r\n\(body)").utf8))
        }
        _ = try await origin.start()
        defer { origin.stop() }
        let (proxy, port, _) = try await startedProxy(URLSessionUpstream(origin: origin.url))
        defer { Task { await proxy.stop() } }
        for _ in 0..<2 {
            let client = try await WireClient(port: port)
            try await client.send("GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            let (head, _) = try await client.readResponse()
            #expect(head.status == 200)
            #expect(head.headers.value("Set-Cookie") != nil, "the guest is still handed what the origin set")
        }
        let seen = origin.requests
        #expect(seen.count == 2, "the second request was answered from a cache")
        for request in seen {
            #expect(request.headers.value("Cookie") == nil)
            #expect(request.headers.value("If-None-Match") == nil)
            #expect(request.headers.value("If-Modified-Since") == nil)
        }
    }

    @Test func everyTargetStaysOnTheOneOrigin() {
        let upstream = URLSessionUpstream()
        #expect(upstream.url(for: "/v1/messages?beta=true")?.absoluteString == "https://api.anthropic.com/v1/messages?beta=true")
        for target in ["//evil.example/v1", "/@evil.example/"] {
            #expect(upstream.url(for: target)?.host == "api.anthropic.com", "\(target)")
        }
        #expect(upstream.url(for: "/v1/messages#private") == nil)
        #expect(upstream.url(for: "http://evil.example/") == nil)
        #expect(upstream.url(for: "evil.example") == nil)
        #expect(upstream.url(for: ".evil.example/") == nil)
    }

    @Test func anUnreachableOriginIsABadGatewayShapedLikeTheAPIsErrors() async throws {
        // A port bound and released, so nothing listens there.
        let placeholder = try StubOrigin { _, _ in }
        let closedPort = try await placeholder.start()
        placeholder.stop()
        let (proxy, port, logs) = try await startedProxy(URLSessionUpstream(origin: URL(string: "http://127.0.0.1:\(closedPort)")!))
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: #"{"model":"x"}"#, headers: ["Authorization: Bearer sk-ant-oat01-unlogged"]))
        let (head, body) = try await client.readResponse()
        #expect(head.status == 502)
        // Logged like every other request: method, path, status and time, then the error's kind.
        let line = try #require(logs.lines.first)
        #expect(logs.lines.count == 1)
        #expect(line.range(of: #"^POST /v1/messages 502 in \d+ ms: failed upstream: URLError -?\d+$"#, options: .regularExpression) != nil, "logged: \(line)")
        #expect(!line.contains("sk-ant-oat01-unlogged"))
        let error = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(error["type"] as? String == "error")
        #expect((error["error"] as? [String: Any])?["type"] as? String == "api_error")
    }
}

/// Answers every request with a plain `URLResponse`, which no HTTP server would.
final class NotHTTPProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = URLResponse(url: request.url!, mimeType: "text/plain", expectedContentLength: 2, textEncodingName: nil)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("ok".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
