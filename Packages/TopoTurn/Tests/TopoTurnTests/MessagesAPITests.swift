import Foundation
import Testing
import TopoCore
@testable import TopoTurn

@Suite struct MessagesAPITests {
    @Test func sendsTheRequestTheCLISends() async throws {
        let transport = RecordingTransport((200, reply("hi")))
        let api = MessagesAPI(transport: transport, tokens: FixedToken(token: "abc"))
        let out = try await api.complete([ChatMessage(role: .user, content: "hello")], model: .opus5, system: "be terse")
        let request = try #require(transport.requests.first)
        #expect(request.url == MessagesAPI.endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        let body = try #require(transport.lastBody)
        #expect(body["model"] as? String == ClaudeModel.effective(.opus5).rawValue)
        #expect(body["max_tokens"] as? Int == 16000)
        let system = try #require(body["system"] as? [[String: String]])
        #expect(system.map { $0["text"] } == [MessagesAPI.identity, "be terse"])
        #expect((body["messages"] as? [[String: String]]) == [["role": "user", "content": "hello"]])
        #expect(out == Reply(text: "hi", model: "claude-sonnet-5", stopReason: "end_turn", inputTokens: 10, outputTokens: 5))
    }

    @Test func joinsTextBlocksAndSurfacesErrors() async throws {
        let transport = RecordingTransport(
            (200, #"{"model":"m","content":[{"type":"thinking","thinking":""},{"type":"text","text":"a"},{"type":"text","text":"b"}],"stop_reason":"end_turn"}"#),
            (429, #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#),
            (200, "not json"),
            (200, reply("", stop: "refusal"))
        )
        let api = MessagesAPI(transport: transport, tokens: FixedToken())
        let m = [ChatMessage(role: .user, content: "x")]
        #expect(try await api.complete(m, model: .sonnet5, system: "").text == "ab")
        await #expect(throws: MessagesAPIError.http(status: 429, message: "slow down")) { try await api.complete(m, model: .sonnet5, system: "") }
        await #expect(throws: MessagesAPIError.malformedResponse) { try await api.complete(m, model: .sonnet5, system: "") }
        await #expect(throws: MessagesAPIError.refused(category: nil)) { try await api.complete(m, model: .sonnet5, system: "") }
    }

    @Test func defaultModelIsSonnet() {
        #expect(ClaudeModel.default == .sonnet5)
        #expect(ClaudeModel.allCases.map(\.rawValue) == ["claude-sonnet-5", "claude-opus-5", "claude-fable-5-1"])
    }

    /// The pin, at the wire rather than at the picker: whatever a caller asks for, a debug build
    /// sends Haiku. This suite is a debug build, so it can assert the pinned half directly.
    @Test func aDebugBuildAsksHaikuWhateverTheSettingSays() async throws {
        #expect(ClaudeModel.pinned == .haiku45)
        #expect(!ClaudeModel.allCases.contains(.haiku45))
        for asked in [ClaudeModel.sonnet5, .opus5, .fable51, .haiku45] {
            #expect(ClaudeModel.effective(asked) == .haiku45)
            let transport = RecordingTransport((200, reply("hi")))
            let api = MessagesAPI(transport: transport, tokens: FixedToken())
            _ = try await api.complete([ChatMessage(role: .user, content: "x")], model: asked, system: "")
            #expect(try #require(transport.lastBody)["model"] as? String == "claude-haiku-4-5-20251001")
        }
    }
}
