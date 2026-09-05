import Foundation
import TopoAuth

/// The models the phone harness offers. Sonnet is the default; the others are a setting.
public enum ClaudeModel: String, CaseIterable, Sendable, Codable, Identifiable {
    case sonnet5 = "claude-sonnet-5"
    case opus5 = "claude-opus-5"
    case fable51 = "claude-fable-5-1"

    public static let `default` = ClaudeModel.sonnet5
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sonnet5: "Sonnet 5"
        case .opus5: "Opus 5"
        case .fable51: "Fable 5.1"
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

    public init(transport: Transport = URLSessionTransport(), tokens: TokenProvider) {
        self.transport = transport
        self.tokens = tokens
    }

    public func complete(_ messages: [ChatMessage], model: ClaudeModel, system: String) async throws -> Reply {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Request(
            model: model.rawValue,
            max_tokens: maxTokens,
            system: [.init(type: "text", text: Self.identity), .init(type: "text", text: system)],
            messages: messages
        ))
        let (data, response) = try await transport.send(request)
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
