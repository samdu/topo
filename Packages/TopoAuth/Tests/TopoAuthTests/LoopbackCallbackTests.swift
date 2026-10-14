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
        #expect(String(decoding: body, as: UTF8.self).contains("Approval received"))
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

    /// The page says the approval arrived and how to get back, and nothing of what the browser
    /// brought: it is written before the code is exchanged, in whichever browser carried it.
    @Test func thePageOffersTheWayBackAndCarriesNothingOfTheRequest() async throws {
        let listener = try LoopbackCallback(back: URL(string: "topo://open")!)
        let (body, response) = try await URLSession.shared.data(from: URL(string: "http://localhost:\(listener.port)/callback?code=abc123secret&state=xyz789state")!)
        let http = try #require(response as? HTTPURLResponse)
        let page = String(decoding: body, as: UTF8.self)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "Location") == nil)
        #expect(page.contains("<a href=\"topo://open\""))
        #expect(page.contains("Approval received"))
        #expect(!page.contains("Signed in"), "the page said the sign-in worked before the exchange")
        #expect(!page.contains("abc123secret") && !page.contains("xyz789state"))
        #expect(ClaudeOAuth.parseCallback(try await listener.wait())?.code == "abc123secret")
        #expect(!LoopbackCallback.received(back: nil).contains("href"), "a device with no scheme offered a link")
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
