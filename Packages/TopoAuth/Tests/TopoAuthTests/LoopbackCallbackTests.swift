import Foundation
import Testing
@testable import TopoAuth

@Suite struct LoopbackCallbackTests {
    @Test func catchesTheBrowsersRedirectAndAnswersIt() async throws {
        let listener = try LoopbackCallback()
        #expect(listener.port != 0)
        async let hit = listener.wait()
        let url = URL(string: "http://localhost:\(listener.port)/callback?code=abc&state=xyz")!
        let (body, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("Signed in"))
        let caught = try await hit
        #expect(ClaudeOAuth.parseCallback(caught)?.code == "abc")
    }

    @Test(arguments: ["127.0.0.1", "[::1]"])
    func anythingElseIsNotFoundOnEitherLoopbackAddress(host: String) async throws {
        let listener = try LoopbackCallback()
        let url = URL(string: "http://\(host):\(listener.port)/favicon.ico")!
        let (_, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        listener.cancel()
    }

    @Test func cancelUnblocksWait() async throws {
        let listener = try LoopbackCallback()
        let task = Task { try await listener.wait() }
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        await #expect(throws: LoopbackCallback.Error.cancelled) { try await task.value }
    }
}
