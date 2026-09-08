import Foundation
import TopoAuth
import TopoCore

/// The models the phone harness offers. Sonnet is the default; the others are a setting. Haiku is
/// not offered — it is what `pinned` forces a debug build onto, so it is a case without being a
/// choice, and `allCases` (the picker) is written out rather than synthesised to keep it that way.
public enum ClaudeModel: String, CaseIterable, Sendable, Codable, Identifiable {
    case sonnet5 = "claude-sonnet-5"
    case opus5 = "claude-opus-5"
    case fable51 = "claude-fable-5-1"
    case haiku45 = "claude-haiku-4-5-20251001"

    public static let `default` = ClaudeModel.sonnet5
    /// What the chat menu offers. Haiku is deliberately absent.
    public static let allCases: [ClaudeModel] = [.sonnet5, .opus5, .fable51]
    public var id: String { rawValue }

    /// The model every call goes to whatever the setting says, or nil when the setting is obeyed.
    ///
    /// A debug build is pinned to Haiku. Debug is what a simulator run, an engineer's build and
    /// `swift test` all are, and such a build is signed into a real Claude subscription — Sam's,
    /// through the seeded setup token — so a stray turn spends his account. Pinning the cheapest
    /// model makes the cost of an accidental turn a rounding error rather than a judgement call.
    /// Only a release build lets the picker choose.
    public static let pinned: ClaudeModel? = {
        #if DEBUG
        .haiku45
        #else
        nil
        #endif
    }()

    /// The model a request actually carries: the pin when there is one, the asked-for model
    /// otherwise. Every call path goes through here, so there is one place the pin can be read.
    public static func effective(_ requested: ClaudeModel) -> ClaudeModel { pinned ?? requested }

    public var displayName: String {
        switch self {
        case .sonnet5: "Sonnet 5"
        case .opus5: "Opus 5"
        case .fable51: "Fable 5.1"
        case .haiku45: "Haiku 4.5"
        }
    }
}

/// One message as the Messages API takes it: a role and plain text.
public struct ChatMessage: Sendable, Equatable, Codable {
    public enum Role: String, Sendable, Codable { case user, assistant }
    public var role: Role
    public var content: String
    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// How bytes leave the process. `URLSession` in the app; a recorder in tests.
public protocol Transport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: Transport {
    public var session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MessagesAPIError.malformedResponse }
        return (data, http)
    }
}

public enum MessagesAPIError: Error, Equatable {
    /// The API answered with an error; `message` is its own text when it sent one.
    case http(status: Int, message: String?)
    case malformedResponse
    /// The model declined the turn (`stop_reason: refusal`).
    case refused(category: String?)
}

/// A reply as the harness keeps it.
public struct Reply: Sendable, Equatable {
    public var text: String
    public var model: String
    public var stopReason: String?
    public var inputTokens: Int
    public var outputTokens: Int

    public init(text: String, model: String, stopReason: String?, inputTokens: Int, outputTokens: Int) {
        self.text = text
        self.model = model
        self.stopReason = stopReason
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    /// A reply found already in the log: its text is the turn's, and nothing else is known.
    init(recovered turn: Turn, model: ClaudeModel) {
        self.init(text: turn.text, model: model.rawValue, stopReason: nil, inputTokens: 0, outputTokens: 0)
    }
}

/// `POST /v1/messages` with an OAuth bearer token, the way the Claude Code CLI calls it: the
/// `oauth-2025-04-20` beta and a system prompt that opens with the CLI's own identity line,
/// which is what a claude.ai subscription token is accepted for. Non-streaming, text only.
public struct MessagesAPI: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let identity = "You are Claude Code, Anthropic's official CLI for Claude."

    public var transport: Transport
    public var tokens: TokenProvider
    public var maxTokens = 16000
    /// How long one call may take before it fails rather than hangs. Non-streaming, so the whole
    /// reply arrives at once; a long answer on a slow link needs minutes, not the default minute.
    public var timeout: TimeInterval = 300
    /// Told the HTTP status of every answer, and the time it took; a screen shows the last.
    public var onResponse: (@Sendable (Int, TimeInterval) -> Void)?

    public init(transport: Transport = URLSessionTransport(), tokens: TokenProvider) {
        self.transport = transport
        self.tokens = tokens
    }

    public func complete(_ messages: [ChatMessage], model: ClaudeModel, system: String) async throws -> Reply {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Request(
            // The pin is applied here rather than at the picker, so it holds for every caller:
            // the chat's own turn, `answerPending`, and anything added later.
            model: ClaudeModel.effective(model).rawValue,
            max_tokens: maxTokens,
            system: [.init(type: "text", text: Self.identity), .init(type: "text", text: system)],
            messages: messages
        ))
        let started = Date()
        let (data, response) = try await transport.send(request)
        onResponse?(response.statusCode, Date().timeIntervalSince(started))
        guard response.statusCode == 200 else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            throw MessagesAPIError.http(status: response.statusCode, message: message)
        }
        guard let body = try? JSONDecoder().decode(Response.self, from: data) else { throw MessagesAPIError.malformedResponse }
        if body.stop_reason == "refusal" { throw MessagesAPIError.refused(category: body.stop_details?.category) }
        return Reply(
            text: body.content.compactMap { $0.type == "text" ? $0.text : nil }.joined(),
            model: body.model,
            stopReason: body.stop_reason,
            inputTokens: body.usage?.input_tokens ?? 0,
            outputTokens: body.usage?.output_tokens ?? 0
        )
    }

    struct Request: Encodable {
        struct SystemBlock: Encodable { var type: String; var text: String }
        var model: String
        var max_tokens: Int
        var system: [SystemBlock]
        var messages: [ChatMessage]
    }

    struct Response: Decodable {
        struct Block: Decodable { var type: String; var text: String? }
        struct Usage: Decodable { var input_tokens: Int; var output_tokens: Int }
        struct StopDetails: Decodable { var category: String? }
        var model: String
        var content: [Block]
        var stop_reason: String?
        var stop_details: StopDetails?
        var usage: Usage?
    }

    struct ErrorEnvelope: Decodable {
        struct Body: Decodable { var type: String?; var message: String? }
        var error: Body
    }
}
