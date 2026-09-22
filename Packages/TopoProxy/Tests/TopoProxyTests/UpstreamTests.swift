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
        let firstSent = Signal()
        let origin = try StubOrigin { _, inbound in
            try await inbound.send(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
            try await inbound.send(ResponseWriter.chunk(Data("event: ping\ndata: {}\n\n".utf8)))
            firstSent.fire()
            // And then nothing: the stream stays open until the far side closes it.
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

    @Test func everyTargetStaysOnTheOneOrigin() {
        let upstream = URLSessionUpstream()
        #expect(upstream.url(for: "/v1/messages?beta=true")?.absoluteString == "https://api.anthropic.com/v1/messages?beta=true")
        for target in ["//evil.example/v1", "/@evil.example/", "/v1/messages#frag"] {
            #expect(upstream.url(for: target)?.host == "api.anthropic.com", "\(target)")
        }
        #expect(upstream.url(for: "http://evil.example/") == nil)
        #expect(upstream.url(for: "evil.example") == nil)
        #expect(upstream.url(for: ".evil.example/") == nil)
    }

    @Test func anUnreachableOriginIsABadGatewayShapedLikeTheAPIsErrors() async throws {
        // A port bound and released, so nothing listens there.
        let placeholder = try StubOrigin { _, _ in }
        let closedPort = try await placeholder.start()
        placeholder.stop()
        let (proxy, port, _) = try await startedProxy(URLSessionUpstream(origin: URL(string: "http://127.0.0.1:\(closedPort)")!))
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: #"{"model":"x"}"#))
        let (head, body) = try await client.readResponse()
        #expect(head.status == 502)
        let error = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(error["type"] as? String == "error")
        #expect((error["error"] as? [String: Any])?["type"] as? String == "api_error")
    }
}
