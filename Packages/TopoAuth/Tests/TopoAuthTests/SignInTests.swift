import Foundation
import Testing
@testable import TopoAuth

extension Stubbed {
    @Suite @MainActor struct SignInTests {
        let store = InMemoryTokenStore()

        func make() -> SignIn {
            SignIn(oauth: ClaudeOAuth(configuration: .claude, session: StubURLProtocol.session()), store: store)
        }

        @Test func startsIdleWithNoTokenAndSignedInWithOne() throws {
            #expect(make().phase == .idle)
            try store.save(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scopes: []))
            #expect(make().phase == .signedIn)
        }

        @Test func startOpensALoopbackAttemptAndTheCallbackSignsIn() async throws {
            let signIn = make()
            let url = signIn.start()
            #expect(signIn.phase == .waiting(pasteHint: false))
            let redirect = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "redirect_uri" }?.value)
            let state = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
            #expect(redirect.hasPrefix("http://localhost:"))
            StubURLProtocol.respond(status: 200, json: #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#)
            // The browser hits the listener.
            _ = try await URLSession.shared.data(from: URL(string: "\(redirect)?code=abc&state=\(state)")!)
            for _ in 0..<50 where signIn.phase != .signedIn { try await Task.sleep(for: .milliseconds(20)) }
            #expect(signIn.phase == .signedIn)
            let saved = try store.load()
            #expect(saved?.accessToken == "at", "saved=\(String(describing: saved)) phase=\(signIn.phase)")
        }

        @Test func aPastedCodeSignsInAndAWrongStateFails() async throws {
            let signIn = make()
            _ = signIn.start()
            StubURLProtocol.respond(status: 200, json: #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#)
            await signIn.finish(pasted: "abc#not-this-attempt")
            #expect({ if case .failed = signIn.phase { true } else { false } }())
            _ = signIn.start()
            await signIn.finish(pasted: "abc")
            #expect(signIn.phase == .signedIn)
        }

        @Test func cancelReturnsToIdleAndSignOutClearsTheStore() async throws {
            let signIn = make()
            _ = signIn.start()
            signIn.cancel()
            #expect(signIn.phase == .idle)
            try store.save(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture, scopes: []))
            let again = make()
            again.signOut()
            #expect(again.phase == .idle)
            #expect(try store.load() == nil)
        }
    }
}

@Suite struct KeychainTokenStoreTests {
    @Test func roundTripsThroughTheKeychain() throws {
        let store = KeychainTokenStore(service: "zone.hexagon.topo.tests", account: UUID().uuidString)
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        let t = Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1), scopes: ["x"])
        try store.save(t)
        #expect(try store.load() == t)
        var t2 = t; t2.accessToken = "b"
        try store.save(t2)
        #expect(try store.load() == t2)
        try store.clear()
        #expect(try store.load() == nil)
    }
}
