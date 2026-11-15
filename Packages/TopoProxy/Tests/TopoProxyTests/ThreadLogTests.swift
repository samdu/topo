import Foundation
import os
import Testing

@testable import TopoProxy

/// What the proxy notes of each `/v1/messages` request's thread: read off the requests that went
/// through it, not off any setting, so a launch that asked for threads under a name Claude Code
/// does not read shows as requests on none.
struct ThreadLogTests {
    static let beta = "oauth-2025-04-20,message-threads-2026-08-12,claude-code-20250219"

    /// Through a running proxy: a request with no threads beta is noted as on none, a create and a
    /// continue as themselves, with their bytes and the status each was answered with, a stale
    /// continue's 404 among them; a request on another path is not noted at all.
    @Test func eachRequestIsNotedAsWhatItCarried() async throws {
        let statuses = [200, 200, 404, 200]
        let count = OSAllocatedUnfairLock(initialState: 0)
        let upstream = StubUpstream { _ in
            let index = count.withLock { value in defer { value += 1 }; return value }
            let status = statuses[min(index, statuses.count - 1)]
            return UpstreamResponse(status: status, headers: [HTTPField("Content-Type", "application/json")],
                                    body: AsyncThrowingStream { $0.yield(Data("{}".utf8)); $0.finish() })
        }
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let threads = ThreadLog(now: { when })
        let proxy = try APIProxy(upstream: upstream, log: { _ in }, threads: threads)
        defer { Task { await proxy.stop() } }
        let port = try await proxy.start()
        let bodies = [
            (#"{"model":"m","messages":[]}"#, "anthropic-beta: oauth-2025-04-20"),
            (#"{"model":"m","thread":{"type":"create"},"messages":[]}"#, "anthropic-beta: \(Self.beta)"),
            (#"{"model":"m","thread":{"type":"continue","previous_message_id":"msg_1"},"messages":[]}"#, "anthropic-beta: \(Self.beta)"),
            (#"{"model":"m","thread":{"type":"create"},"messages":[]}"#, "anthropic-beta: \(Self.beta)"),
        ]
        for (body, beta) in bodies {
            let client = try await WireClient(port: port)
            try await client.send(post("/v1/messages?beta=true", body: body, headers: [beta]))
            _ = try await client.readResponse()
        }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages/count_tokens", body: #"{"thread":{"type":"create"}}"#, headers: ["anthropic-beta: \(Self.beta)"]))
        _ = try await client.readResponse()

        let sent = threads.recent()
        #expect(sent.map(\.kind) == [.none, .create, .continue, .create])
        #expect(sent.map(\.status) == [200, 200, 404, 200])
        #expect(sent.allSatisfy { $0.at == when })
        // What went upstream, which in a debug build is the body with its model pinned.
        #expect(sent.map(\.bytes) == upstream.requests.prefix(4).map { $0.body?.count ?? 0 })
    }

    /// A request's mark names a model request's thread by its kind alone, read from the request
    /// as `ThreadLog` reads it, and nothing else the request carries.
    @Test func aRequestsMarkNamesItsThreadByKindAlone() {
        let body = Data(#"{"model":"m","thread":{"type":"continue","previous_message_id":"msg_secret"},"messages":[]}"#.utf8)
        let kind = ThreadLog.kind(headers: [HTTPField("anthropic-beta", Self.beta)], body: body)
        #expect(Forwarder.requestMark(route: "POST /v1/messages", bytes: body.count, id: "id=7", thread: kind)
                == "proxy.request POST /v1/messages bytes=\(body.count) id=7 thread=continue")
        #expect(Forwarder.requestMark(route: "GET /v1/models", bytes: 0, id: "id=8", thread: nil)
                == "proxy.request GET /v1/models bytes=0 id=8")
    }

    /// A thread is read only under the threads beta: the same field without it is a request on
    /// none, which is what the API would make of it. Under the beta, a body with no thread the
    /// proxy can read is said to be one.
    @Test func aThreadIsReadOnlyUnderItsBeta() {
        let create = Data(#"{"thread":{"type":"create"}}"#.utf8)
        #expect(ThreadLog.kind(headers: [HTTPField("anthropic-beta", "oauth-2025-04-20")], body: create) == .none)
        #expect(ThreadLog.kind(headers: [], body: create) == .none)
        #expect(ThreadLog.kind(headers: [HTTPField("Anthropic-Beta", "a, message-threads-2026-08-12")], body: create) == .create)
        let beta = [HTTPField("anthropic-beta", Self.beta)]
        #expect(ThreadLog.kind(headers: beta, body: Data("not json".utf8)) == .unread)
        #expect(ThreadLog.kind(headers: beta, body: Data(#"{"messages":[]}"#.utf8)) == .unread)
        #expect(ThreadLog.kind(headers: beta, body: Data(#"{"thread":{"type":"fork"}}"#.utf8)) == .unread)
    }

    /// A request the client goes away from before its answer's head is noted as cancelled, not
    /// left waiting for an answer that will never come.
    @Test func aRequestTheClientLeftIsNotedAsCancelled() async throws {
        let upstream = StubUpstream { _ in
            try await Task.sleep(for: .seconds(30))
            return StubUpstream.ok("{}")
        }
        let threads = ThreadLog()
        let proxy = try APIProxy(upstream: upstream, log: { _ in }, threads: threads)
        defer { Task { await proxy.stop() } }
        let port = try await proxy.start()
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages?beta=true", body: #"{"model":"m","thread":{"type":"continue"}}"#,
                                   headers: ["anthropic-beta: \(Self.beta)"]))
        for _ in 0..<500 where upstream.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(threads.recent().map(\.status) == [nil])
        client.reset()
        for _ in 0..<500 where threads.recent().first?.status == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(threads.recent().map(\.status) == [ThreadLog.cancelled])
        #expect(threads.recent().map(\.kind) == [.continue])
    }

    /// A request on no thread is never parsed: the body is read only under the threads beta.
    @Test func aRequestWithoutTheBetaIsNotParsed() {
        let parses = OSAllocatedUnfairLock(initialState: 0)
        let parse: (Data) -> Any? = { data in
            parses.withLock { $0 += 1 }
            return try? JSONSerialization.jsonObject(with: data)
        }
        let body = Data(#"{"thread":{"type":"create"},"messages":[]}"#.utf8)
        #expect(ThreadLog.kind(headers: [HTTPField("anthropic-beta", "oauth-2025-04-20")], body: body, parse: parse) == .none)
        #expect(ThreadLog.kind(headers: [], body: body, parse: parse) == .none)
        #expect(parses.withLock { $0 } == 0)
        #expect(ThreadLog.kind(headers: [HTTPField("anthropic-beta", Self.beta)], body: body, parse: parse) == .create)
        #expect(parses.withLock { $0 } == 1)
    }

    /// The log keeps the newest `kept`, and a clear forgets them all, so an answer landing for a
    /// request noted before the clear notes nothing.
    @Test func theLogIsBoundedAndAClearForgetsAnAnswerStillOwed() {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        let threads = ThreadLog(now: { when })
        var last = 0
        for bytes in 1...(ThreadLog.kept + 3) { last = threads.sent(bytes: bytes, kind: .none) }
        #expect(threads.recent().map(\.bytes) == Array(4...(ThreadLog.kept + 3)))
        threads.clear()
        threads.answered(last, status: 200)
        #expect(threads.recent().isEmpty)
        let fresh = threads.sent(bytes: 9, kind: .continue)
        threads.answered(fresh, status: 404)
        #expect(threads.recent() == [ThreadLog.Sent(at: when, bytes: 9, kind: .continue, status: 404)])
    }
}
