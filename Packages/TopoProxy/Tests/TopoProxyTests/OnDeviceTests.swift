import Foundation
import Testing
@testable import TopoProxy

/// A stand-in for Apple's on-device model: four characters a token, a window the test sets, and
/// a reply that is the snapshots it is handed, or a failure after them.
final class FakeLocalModel: LocalModel, @unchecked Sendable {
    private let lock = NSLock()
    let window: Int
    let snapshots: [String]
    let failure: (any Error)?
    let unavailable: String?
    /// Whether to wait, after the snapshots, until cancelled.
    let hangs: Bool
    let cancelled = Signal()
    private var asked: [(history: [LocalTurn], prompt: String)] = []

    init(window: Int = 8192, snapshots: [String] = ["Hel", "Hello", "Hello there."], failure: (any Error)? = nil,
         unavailable: String? = nil, hangs: Bool = false) {
        self.window = window
        self.snapshots = snapshots
        self.failure = failure
        self.unavailable = unavailable
        self.hangs = hangs
    }

    var requests: [(history: [LocalTurn], prompt: String)] { lock.withLock { asked } }

    func unavailability() async -> String? { unavailable }
    func contextSize() async -> Int { window }

    func tokenCount(instructions: String, history: [LocalTurn], prompt: String) async throws -> Int {
        (instructions.count + prompt.count + history.reduce(0) { $0 + $1.text.count }) / 4
    }

    func stream(instructions: String, history: [LocalTurn], prompt: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { asked.append((history, prompt)) }
        let (snapshots, failure, hangs, cancelled) = (self.snapshots, self.failure, self.hangs, self.cancelled)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for snapshot in snapshots { continuation.yield(snapshot) }
                if hangs {
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                    cancelled.fire()
                    return
                }
                if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

func messagesBody(model: String = OnDeviceModel.id, stream: Bool = true, _ messages: [(String, Any)]) -> String {
    let object: [String: Any] = ["model": model, "stream": stream, "max_tokens": 32000,
                                 "messages": messages.map { ["role": $0.0, "content": $0.1] }]
    return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

/// The events of a server-sent stream, each as its name and its data.
func sseEvents(_ data: Data) -> [(name: String, data: [String: Any])] {
    String(decoding: data, as: UTF8.self).components(separatedBy: "\n\n").compactMap { block in
        let lines = block.split(separator: "\n")
        guard let name = lines.first(where: { $0.hasPrefix("event: ") })?.dropFirst(7),
              let json = lines.first(where: { $0.hasPrefix("data: ") })?.dropFirst(6),
              let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return nil }
        return (String(name), object)
    }
}

func collect(_ response: UpstreamResponse) async throws -> Data {
    var data = Data()
    for try await chunk in response.body { data.append(chunk) }
    return data
}

@Suite struct OnDeviceRoutingTests {
    /// Review focus 1: a request carrying the placeholder key never reaches the API, whatever its
    /// path, its model or its spelling of the path.
    @Test(arguments: [
        ("x-api-key: \(OnDeviceModel.placeholderKey)", "/v1/messages?beta=true", OnDeviceModel.id),
        ("x-api-key: \(OnDeviceModel.placeholderKey)", "/v1/messages", "sonnet"),
        ("x-api-key: \(OnDeviceModel.placeholderKey)", "/v1/models", "claude-haiku-5-5"),
        ("x-api-key: \(OnDeviceModel.placeholderKey)", "/v1//messages/./", "opus"),
        ("x-api-key: \(OnDeviceModel.placeholderKey)", "/v1/%256d%2565ssages", "opus"),
        ("Authorization: Bearer \(OnDeviceModel.placeholderKey)", "/v1/messages", "fable"),
        ("authorization: bearer \(OnDeviceModel.placeholderKey)", "/api/oauth/profile", "fable"),
    ])
    func thePlaceholderIsNeverForwarded(_ header: String, _ path: String, _ model: String) async throws {
        let upstream = StubUpstream()
        let local = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream, local: local)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post(path, body: messagesBody(model: model, [("user", "hi")]), headers: [header]))
        _ = try await client.readResponse()
        #expect(upstream.requests.isEmpty, "the placeholder went upstream on \(path)")
        #expect(local.requests.count == 1)
    }

    /// The `/api/hello` check Claude Code makes before its first turn, a `HEAD`, carries the key
    /// and is answered on the phone.
    @Test func theHelloCheckIsAnsweredOnThePhone() async throws {
        let upstream = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream, local: OnDeviceUpstream(model: FakeLocalModel()))
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send("HEAD /api/hello HTTP/1.1\r\nHost: 127.0.0.1\r\nx-api-key: \(OnDeviceModel.placeholderKey)\r\n\r\n")
        let head = try await client.readHead()
        #expect(head.status == 200)
        #expect(upstream.requests.isEmpty)
    }

    /// Review focus 2: a Claude model whose API cannot be reached is not answered on the phone.
    /// Sam: "If someone has a Claude Code account and it can't be reached right now, I don't think
    /// it should automatically fall back to the on-device model."
    @Test func aClaudeModelIsForwardedAndItsFailureIsItsOwn() async throws {
        let upstream = StubUpstream { _ in throw URLError(.notConnectedToInternet) }
        let local = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream, local: local)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: messagesBody(model: "sonnet", [("user", "hi")]),
                                   headers: ["Authorization: Bearer sk-ant-oat01-real"]))
        let (head, _) = try await client.readResponse()
        #expect(head.status == 502)
        #expect(upstream.requests.count == 1)
        #expect(local.requests.isEmpty)
    }

    /// Review focus 3: a body naming the on-device model, sent with a real login's credential (a
    /// signed-in person who chose it), is answered on the phone with its model as it was; the
    /// debug pin does not rewrite it to Haiku and send it on.
    @Test func anOnDeviceBodyIsAnsweredLocallyAndNotPinned() async throws {
        let upstream = StubUpstream()
        let local = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream, local: local)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        for path in ["/v1/messages?beta=true", "/v1/messages/count_tokens?beta=true"] {
            try await client.send(post(path, body: messagesBody([("user", "hi")]), headers: ["Authorization: Bearer sk-ant-oat01-real"]))
            _ = try await client.readResponse()
        }
        #expect(upstream.requests.isEmpty)
        #expect(local.requests.count == 2)
        let model = (try JSONSerialization.jsonObject(with: try #require(local.requests.first?.body)) as? [String: Any])?["model"] as? String
        #expect(model == OnDeviceModel.id)
    }

    /// The other half of focus 3: everything that does go upstream is still pinned in a debug
    /// build, which this suite is.
    @Test func aBodyGoingUpstreamIsStillPinned() async throws {
        let upstream = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream, local: StubUpstream())
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: messagesBody(model: "opus", [("user", "hi")]),
                                   headers: ["Authorization: Bearer sk-ant-oat01-real"]))
        _ = try await client.readResponse()
        let seen = try #require(upstream.requests.first?.body)
        let model = (try JSONSerialization.jsonObject(with: seen) as? [String: Any])?["model"] as? String
        #expect(model == APIProxy.pinnedModel)
    }

    /// A model name that only resembles the on-device one is a Claude request.
    @Test(arguments: ["Apple-On-Device", "apple-on-device-2", " apple-on-device", "claude-apple-on-device"])
    func aLookalikeModelGoesUpstream(_ model: String) async throws {
        let upstream = StubUpstream()
        let local = StubUpstream()
        let (proxy, port, _) = try await startedProxy(upstream, local: local)
        defer { Task { await proxy.stop() } }
        let client = try await WireClient(port: port)
        try await client.send(post("/v1/messages", body: messagesBody(model: model, [("user", "hi")]),
                                   headers: ["Authorization: Bearer sk-ant-oat01-real"]))
        _ = try await client.readResponse()
        #expect(upstream.requests.count == 1)
        #expect(local.requests.isEmpty)
    }
}

@Suite struct MessagesTranslationTests {
    @Test func remindersSystemMessagesThinkingAndToolsAreLeftOut() throws {
        let body = messagesBody([
            ("user", [["type": "text", "text": "<system-reminder>\nbig context\n</system-reminder>"],
                      ["type": "text", "text": "what's in my notes?"]]),
            ("assistant", [["type": "thinking", "thinking": "hmm"], ["type": "text", "text": "Let me look."],
                           ["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "ls"]]]),
            ("user", [["type": "tool_result", "tool_use_id": "t1", "content": "secret.md"]]),
            ("assistant", "Nothing much."),
            ("system", "# Environment\nlots of it"),
            ("user", "thanks <system-reminder>more</system-reminder> a lot"),
        ])
        let translation = try MessagesTranslation.translate(Data(body.utf8))
        #expect(translation.history == [
            LocalTurn(.user, "what's in my notes?"),
            LocalTurn(.assistant, "Let me look.\n\n[used Bash]"),
            LocalTurn(.user, "[tool result]"),
            LocalTurn(.assistant, "Nothing much."),
        ])
        #expect(translation.prompt == "thanks  a lot")
        #expect(translation.stream)
        #expect(!translation.history.contains { $0.text.contains("secret.md") || $0.text.contains("Environment") })
    }

    @Test func anUnclosedReminderRunsToTheEnd() {
        #expect(MessagesTranslation.withoutReminders("hi <system-reminder> never closed") == "hi")
    }

    @Test func aBodyThatIsNotMessagesIsUnreadable() {
        #expect(throws: MessagesTranslation.Failure.self) { try MessagesTranslation.translate(Data("[1]".utf8)) }
        #expect(throws: MessagesTranslation.Failure.self) { try MessagesTranslation.translate(Data(#"{"model":"x"}"#.utf8)) }
    }

    /// Review focus 4: the oldest turns go first, a pair at a time, until it fits the window with
    /// room for the reply.
    @Test func theNewestTurnsThatFitAreKept() async throws {
        let model = FakeLocalModel(window: 2048)
        var messages: [(String, Any)] = []
        for n in 0..<20 {
            // Long questions and short answers, so dropping one turn at a time would stop with the
            // history opening on an answer.
            messages.append(("user", "question \(n) " + String(repeating: "q", count: 700)))
            messages.append(("assistant", "answer \(n) " + String(repeating: "a", count: 40)))
        }
        messages.append(("user", "the last thing"))
        let translation = try MessagesTranslation.translate(Data(messagesBody(messages).utf8))
        let (fitted, tokens, dropped) = try await translation.fit(model)
        #expect(tokens <= 2048 - MessagesTranslation.replyReserve)
        #expect(fitted.prompt == "the last thing")
        #expect(fitted.history.first?.role == .user)
        #expect(fitted.history.last?.text.hasPrefix("answer 19") == true)
        #expect(dropped > 0 && dropped % 2 == 0)
        #expect(fitted.history.count + dropped == 40)
        // The next older pair would not have fitted.
        let wider = Array(translation.history.suffix(fitted.history.count + 2))
        #expect(try await model.tokenCount(instructions: MessagesTranslation.instructions, history: wider, prompt: fitted.prompt) > 2048 - MessagesTranslation.replyReserve)
    }

    /// A prompt too long alone keeps its end, marked as cut.
    @Test func aPromptTooLongAloneKeepsItsEnd() async throws {
        let model = FakeLocalModel(window: 2048)
        let long = String(repeating: "x", count: 20_000) + " the end"
        let translation = try MessagesTranslation.translate(Data(messagesBody([("user", long)]).utf8))
        let (fitted, tokens, _) = try await translation.fit(model)
        #expect(tokens <= 2048 - MessagesTranslation.replyReserve)
        #expect(fitted.prompt.hasPrefix(MessagesTranslation.cutMarker))
        #expect(fitted.prompt.hasSuffix(" the end"))
    }

    /// Claude Code 2.1.285's own first request, recorded from the guest's pin against a stub,
    /// is ~16 K tokens; translated, it fits an 8192 window with room left over.
    @Test func claudeCodesFirstRequestFits() async throws {
        let url = try #require(Bundle.module.url(forResource: "claude-code-2.1.285-first-request", withExtension: "json", subdirectory: "Fixtures"))
        let body = try Data(contentsOf: url)
        #expect(body.count > 50_000)
        let translation = try MessagesTranslation.translate(body)
        #expect(translation.prompt == "hi")
        #expect(translation.history.isEmpty)
        let (_, tokens, dropped) = try await translation.fit(FakeLocalModel(window: 8192))
        #expect(tokens < 1024)
        #expect(dropped == 0)
    }
}

@Suite struct OnDeviceUpstreamTests {
    func request(_ body: String, path: String = "/v1/messages?beta=true", method: String = "POST") -> UpstreamRequest {
        UpstreamRequest(method: method, target: path, headers: [], body: Data(body.utf8))
    }

    /// Review focus 5: the events Claude Code reads, in the API's order, the deltas adding up to
    /// the reply, and `input_tokens` the fitted request's count.
    @Test func theStreamIsTheAPIsShape() async throws {
        let upstream = OnDeviceUpstream(model: FakeLocalModel())
        let response = try await upstream.send(request(messagesBody([("user", "hi")])))
        #expect(response.status == 200)
        #expect(response.headers.value("Content-Type") == "text/event-stream")
        let events = sseEvents(try await collect(response))
        #expect(events.map(\.name) == ["message_start", "content_block_start", "content_block_delta", "content_block_delta",
                                       "content_block_delta", "content_block_stop", "message_delta", "message_stop"])
        let deltas = events.compactMap { ($0.data["delta"] as? [String: Any])?["text"] as? String }
        #expect(deltas.joined() == "Hello there.")
        let start = try #require(events.first?.data["message"] as? [String: Any])
        #expect(start["model"] as? String == OnDeviceModel.id)
        let usage = try #require(start["usage"] as? [String: Any])
        let expected = try await FakeLocalModel().tokenCount(instructions: MessagesTranslation.instructions, history: [], prompt: "hi")
        #expect(usage["input_tokens"] as? Int == expected)
        let stop = try #require(events.first { $0.name == "message_delta" }?.data["delta"] as? [String: Any])
        #expect(stop["stop_reason"] as? String == "end_turn")
    }

    /// A snapshot that does not extend what was sent sends nothing, and no word is sent twice.
    @Test func aRevisedSnapshotNeverRepeatsText() async throws {
        let upstream = OnDeviceUpstream(model: FakeLocalModel(snapshots: ["Hello", "Help", "Hello world"]))
        let events = sseEvents(try await collect(try await upstream.send(request(messagesBody([("user", "hi")])))))
        let deltas = events.compactMap { ($0.data["delta"] as? [String: Any])?["text"] as? String }
        #expect(deltas == ["Hello", " world"])
    }

    @Test func aRequestNotAskingForAStreamIsOneMessage() async throws {
        let upstream = OnDeviceUpstream(model: FakeLocalModel())
        let response = try await upstream.send(request(messagesBody(stream: false, [("user", "hi")])))
        let object = try #require(try JSONSerialization.jsonObject(with: try await collect(response)) as? [String: Any])
        let content = try #require(object["content"] as? [[String: Any]])
        #expect(content.first?["text"] as? String == "Hello there.")
        #expect(object["stop_reason"] as? String == "end_turn")
    }

    /// A refusal is the reply, so the person reads why.
    @Test func aRefusalIsTheReply() async throws {
        let model = FakeLocalModel(snapshots: [], failure: LocalModelError.declined("Apple's on-device model wouldn't answer that."))
        let events = sseEvents(try await collect(try await OnDeviceUpstream(model: model).send(request(messagesBody([("user", "hi")])))))
        let deltas = events.compactMap { ($0.data["delta"] as? [String: Any])?["text"] as? String }
        #expect(deltas == ["Apple's on-device model wouldn't answer that."])
        #expect(events.last?.name == "message_stop")
    }

    @Test func anUnavailableModelSaysWhy() async throws {
        let model = FakeLocalModel(unavailable: "Turn on Apple Intelligence in Settings to use the on-device model.")
        let response = try await OnDeviceUpstream(model: model).send(request(messagesBody([("user", "hi")])))
        // A 400, which Claude Code says at once, and not a 5xx, which it retries for minutes.
        #expect(response.status == 400)
        let object = try JSONSerialization.jsonObject(with: try await collect(response)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        #expect(error?["type"] as? String == "invalid_request_error")
        #expect((error?["message"] as? String)?.contains("Apple Intelligence") == true)
        #expect(model.requests.isEmpty)
    }

    @Test func countTokensIsTheTranslatedCount() async throws {
        let response = try await OnDeviceUpstream(model: FakeLocalModel()).send(request(messagesBody([("user", "hi")]), path: "/v1/messages/count_tokens"))
        let object = try JSONSerialization.jsonObject(with: try await collect(response)) as? [String: Any]
        #expect((object?["input_tokens"] as? Int ?? 0) > 0)
    }

    @Test func anyOtherRouteIsNotFound() async throws {
        let response = try await OnDeviceUpstream(model: FakeLocalModel()).send(request("", path: "/v1/models", method: "GET"))
        #expect(response.status == 404)
    }

    /// Review focus 6: the client going away ends the generation.
    @Test func cancellingTheBodyCancelsTheModel() async throws {
        let model = FakeLocalModel(snapshots: ["Hel"], hangs: true)
        let response = try await OnDeviceUpstream(model: model).send(request(messagesBody([("user", "hi")])))
        // The proxy cancels the task reading the body when its client goes (`Forwarder.serve`).
        let delta = Signal()
        let reader = Task {
            for try await chunk in response.body where String(decoding: chunk, as: UTF8.self).contains("text_delta") { delta.fire() }
        }
        #expect(await delta.wait(3))
        #expect(!model.cancelled.hasFired)
        reader.cancel()
        #expect(await model.cancelled.wait(3))
    }

    /// Apple's own model, where this Mac or simulator has it: a real answer in the API's shape.
    /// Skipped where the model is not available, which is said by the skip, not taken as a pass.
    @Test(.enabled(if: OnDeviceModel.unavailability() == nil, "Apple's on-device model is not available here"))
    func theRealModelAnswers() async throws {
        // With a turn before it, so the transcript the session is made from has a prompt and a
        // response in it, which is the path every turn after the first takes.
        let response = try await OnDeviceUpstream().send(request(messagesBody([
            ("user", "My dog is called Daphne."), ("assistant", "Daphne is a lovely name."),
            ("user", "What is my dog called? Reply with her name only."),
        ])))
        #expect(response.status == 200)
        let events = sseEvents(try await collect(response))
        #expect(events.first?.name == "message_start")
        #expect(events.last?.name == "message_stop")
        let text = events.compactMap { ($0.data["delta"] as? [String: Any])?["text"] as? String }.joined()
        #expect(text.contains("Daphne"), "\(text)")
    }
}
