import Foundation

/// The proxy's second upstream: Apple's on-device model, answering in the Messages API's shape so
/// that Claude Code in the guest talks to it as it talks to the API. Nothing it answers leaves the
/// phone.
///
/// - `HEAD` or `GET /api/hello` (Claude Code's reachability check): 200.
/// - `POST /v1/messages/count_tokens`: the translated request's count.
/// - `POST /v1/messages`: the request translated (`MessagesTranslation`) and fitted to the
///   model's window, then answered as server-sent events (`message_start`, one text block's
///   deltas, `message_delta` with `end_turn`, `message_stop`) as the model writes, or as one
///   message when the request did not ask for a stream. `input_tokens` is the fitted request's
///   count, so Claude Code never sees a window filling and never compacts: the fitting is the
///   window's management. Tools are not offered to the model.
/// - Anything else: a 404 in the API's error shape.
///
/// Every refusal is a 400 `invalid_request_error` whose message says why — a model that cannot
/// run here, a request that cannot be made to fit, a generation that failed — because Claude Code
/// shows a 400's message at once and retries a 5xx for minutes (2.1.285, measured: a 503 was
/// asked eight times over 100 s), which would leave the person on *Asking…* with no reason. A refusal (a guardrail, a language the model does not
/// speak) is the reply itself, a sentence saying so, so the person reads why there is no answer.
/// Ending the body's iteration (the client gone) cancels the generation.
public struct OnDeviceUpstream: Upstream {
    public typealias Log = @Sendable (String) -> Void
    let model: any LocalModel
    let log: Log

    public init(model: any LocalModel = SystemLocalModel(), log: @escaping Log = { _ in }) {
        self.model = model
        self.log = log
    }

    public func send(_ request: UpstreamRequest) async throws -> UpstreamResponse {
        let path = request.target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let route = Forwarder.canonical(path)
        switch (request.method, route) {
        case ("HEAD", "/api/hello"), ("GET", "/api/hello"):
            return Self.json(200, [:], head: request.method == "HEAD")
        case ("POST", "/v1/messages/count_tokens"):
            let translation: MessagesTranslation
            do { translation = try MessagesTranslation.translate(request.body ?? Data()) } catch {
                return Self.refusal("Topo could not read the request: \(error)")
            }
            let count = (try? await model.tokenCount(instructions: MessagesTranslation.instructions,
                                                     history: translation.history, prompt: translation.prompt)) ?? 0
            return Self.json(200, ["input_tokens": count])
        case ("POST", "/v1/messages"):
            return await messages(request.body ?? Data())
        default:
            return Self.error(404, "not_found_error", "Apple's on-device model answers messages only.")
        }
    }

    private func messages(_ body: Data) async -> UpstreamResponse {
        if let reason = await model.unavailability() { return Self.refusal(reason) }
        let fitted: MessagesTranslation, tokens: Int
        do {
            let translation = try MessagesTranslation.translate(body)
            let fit = try await translation.fit(model)
            (fitted, tokens) = (fit.0, fit.tokens)
            log("on-device: \(fit.0.history.count) turns, \(fit.tokens) tokens, \(fit.dropped) older turns left out")
        } catch let failure as MessagesTranslation.Failure {
            return Self.refusal("Topo could not read the request: \(failure)")
        } catch LocalModelError.tooLong {
            return Self.refusal("That message is too long for Apple's on-device model.")
        } catch {
            return Self.refusal("Apple's on-device model failed: \(error)")
        }
        let generation = model.stream(instructions: MessagesTranslation.instructions, history: fitted.history, prompt: fitted.prompt)
        let id = "msg_ondevice_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        if fitted.stream {
            return UpstreamResponse(status: 200, headers: [HTTPField("Content-Type", "text/event-stream")],
                                    body: Self.events(of: generation, id: id, inputTokens: tokens))
        }
        var text = ""
        do {
            for try await snapshot in generation { text = snapshot }
        } catch LocalModelError.declined(let words) {
            text = Self.appending(words, to: text)
        } catch LocalModelError.unavailable(let reason) {
            return Self.refusal(reason)
        } catch {
            return Self.refusal("Apple's on-device model failed: \(error)")
        }
        return Self.json(200, Self.message(id: id, text: text, inputTokens: tokens, stop: "end_turn"))
    }

    /// The generation's snapshots as the API's events, each delta the part of a snapshot past what
    /// was already sent. A snapshot that does not extend what was sent (the model revising) sends
    /// nothing until one does, so no word is ever sent twice.
    static func events(of generation: AsyncThrowingStream<String, Error>, id: String, inputTokens: Int) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(event("message_start", ["type": "message_start", "message": message(id: id, text: nil, inputTokens: inputTokens, stop: nil)]))
                continuation.yield(event("content_block_start", ["type": "content_block_start", "index": 0,
                                                                 "content_block": ["type": "text", "text": ""]]))
                var sent = ""
                func delta(_ text: String) {
                    guard !text.isEmpty else { return }
                    sent += text
                    continuation.yield(event("content_block_delta", ["type": "content_block_delta", "index": 0,
                                                                     "delta": ["type": "text_delta", "text": text]]))
                }
                do {
                    for try await snapshot in generation {
                        if snapshot.hasPrefix(sent) { delta(String(snapshot.dropFirst(sent.count))) }
                    }
                } catch LocalModelError.declined(let words) {
                    delta(sent.isEmpty ? words : "\n\n" + words)
                } catch {
                    if !Task.isCancelled {
                        let message = { if case LocalModelError.unavailable(let reason) = error { reason } else { "Apple's on-device model failed: \(error)" } }()
                        continuation.yield(event("error", ["type": "error", "error": ["type": "api_error", "message": message]]))
                    }
                    continuation.finish()
                    return
                }
                guard !Task.isCancelled else { continuation.finish(); return }
                continuation.yield(event("content_block_stop", ["type": "content_block_stop", "index": 0]))
                continuation.yield(event("message_delta", ["type": "message_delta",
                                                           "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
                                                           "usage": ["output_tokens": estimatedTokens(sent)]]))
                continuation.yield(event("message_stop", ["type": "message_stop"]))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func appending(_ words: String, to text: String) -> String { text.isEmpty ? words : text + "\n\n" + words }

    /// Output tokens as the usage reports them: an estimate, four characters a token.
    static func estimatedTokens(_ text: String) -> Int { (text.count + 3) / 4 }

    static func message(id: String, text: String?, inputTokens: Int, stop: String?) -> [String: Any] {
        [
            "id": id, "type": "message", "role": "assistant", "model": OnDeviceModel.id,
            "content": text.map { [["type": "text", "text": $0]] } ?? [],
            "stop_reason": stop ?? NSNull(), "stop_sequence": NSNull(),
            "usage": ["input_tokens": inputTokens, "output_tokens": text.map(estimatedTokens) ?? 0,
                      "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0],
        ]
    }

    static func event(_ name: String, _ data: [String: Any]) -> Data {
        let json = (try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])) ?? Data("{}".utf8)
        return Data("event: \(name)\ndata: ".utf8) + json + Data("\n\n".utf8)
    }

    static func json(_ status: Int, _ object: [String: Any], head: Bool = false) -> UpstreamResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return UpstreamResponse(status: status, headers: [HTTPField("Content-Type", "application/json")],
                                body: AsyncThrowingStream { continuation in
                                    if !head { continuation.yield(data) }
                                    continuation.finish()
                                })
    }

    static func error(_ status: Int, _ type: String, _ message: String) -> UpstreamResponse {
        json(status, ["type": "error", "error": ["type": type, "message": message]])
    }

    /// What the on-device model will not or cannot do, as an answer Claude Code says at once.
    static func refusal(_ message: String) -> UpstreamResponse { error(400, "invalid_request_error", message) }
}
