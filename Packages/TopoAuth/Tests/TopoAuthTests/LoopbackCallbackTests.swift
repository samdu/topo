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

    /// The login's callback sends the browser on to the guest's authorization.
    @Test func aSuccessRedirectAnswersTheCallbackWithIt() async throws {
        let listener = try LoopbackCallback()
        let next = URL(string: "https://claude.com/cai/oauth/authorize?scope=user%3Ainference")!
        listener.redirectOnSuccess(to: next)
        final class NoFollow: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        }
        let session = URLSession(configuration: .ephemeral, delegate: NoFollow(), delegateQueue: nil)
        let (_, response) = try await session.data(from: URL(string: "http://localhost:\(listener.port)/callback?code=abc&state=xyz")!)
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 302)
        #expect(http.value(forHTTPHeaderField: "Location") == next.absoluteString)
        #expect(ClaudeOAuth.parseCallback(try await listener.wait())?.code == "abc")
    }

    /// A callback that lands before anyone waits is kept for the wait, not dropped as cancelled.
    @Test func aCallbackBeforeTheWaitIsKept() async throws {
        let listener = try LoopbackCallback()
        _ = try await URLSession.shared.data(from: URL(string: "http://localhost:\(listener.port)/callback?code=early&state=s")!)
        #expect(ClaudeOAuth.parseCallback(try await listener.wait())?.code == "early")
    }

    @Test func cancelUnblocksWait() async throws {
        let listener = try LoopbackCallback()
        let task = Task { try await listener.wait() }
        try await Task.sleep(for: .milliseconds(50))
        listener.cancel()
        await #expect(throws: LoopbackCallback.Error.cancelled) { try await task.value }
    }
}
