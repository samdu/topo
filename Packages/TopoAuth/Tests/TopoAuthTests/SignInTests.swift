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

/// A round trip through a real keychain with the store's own queries. On macOS that keychain is not
/// the user's: `TemporaryKeychain` creates a file-based one in a temporary directory with a random
/// password, unlocked with no timeout, and the store is pointed at it with `keychainPath`, which adds
/// the keychain to search (`kSecMatchSearchList`) and, on an add, to write to (`kSecUseKeychain`) and
/// changes nothing else. So the test needs no login session or unlocked login keychain, and leaves the
/// login keychain and the search list alone. A keychain that cannot be created, set or unlocked fails
/// the test at a `#require`; nothing here skips.
@Suite struct KeychainTokenStoreTests {
    @Test func roundTripsThroughTheKeychain() throws {
        var store = KeychainTokenStore(service: "zone.hexagon.topo.tests", account: UUID().uuidString)
        #if os(macOS)
        let keychain = try TemporaryKeychain()
        defer { keychain.delete() }
        store.keychainPath = keychain.path
        #endif
        defer { try? store.clear() }
        #expect(try store.load() == nil)
        let t = Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1), scopes: ["x"])
        try store.save(t)
        #if os(macOS)
        #expect(keychain.holdsItem(service: store.service, account: store.account), "the store wrote outside the keychain it was pointed at")
        #endif
        #expect(try store.load() == t)
        var t2 = t; t2.accessToken = "b"
        try store.save(t2)
        #expect(try store.load() == t2)
        try store.clear()
        #expect(try store.load() == nil)
    }
}

extension Stubbed {
    @Suite struct StoredTokenProviderTests {
        @Test func handsOutAFreshTokenAndRefreshesAStaleOne() async throws {
            let store = InMemoryTokenStore(Tokens(accessToken: "fresh", refreshToken: "r", expiresAt: Date().addingTimeInterval(3600), scopes: []))
            let provider = StoredTokenProvider(store: store, oauth: ClaudeOAuth(session: StubURLProtocol.session()))
            #expect(try await provider.accessToken() == "fresh")

            try store.save(Tokens(accessToken: "stale", refreshToken: "r", expiresAt: Date(), scopes: []))
            StubURLProtocol.respond(status: 200, json: #"{"access_token":"new","refresh_token":"r2","expires_in":3600}"#)
            #expect(try await provider.accessToken() == "new")
            #expect(try store.load()?.refreshToken == "r2")
        }

        @Test func aRefreshFinishingAfterSignOutIsDropped() async throws {
            let store = InMemoryTokenStore(Tokens(accessToken: "stale", refreshToken: "r", expiresAt: Date(), scopes: []))
            let oauth = ClaudeOAuth(session: StubURLProtocol.session())
            let provider = StoredTokenProvider(store: store, oauth: oauth)
            StubURLProtocol.respond(status: 200, json: #"{"access_token":"new","refresh_token":"r2","expires_in":3600}"#)
            StubURLProtocol.beforeResponse = { try? store.clear() }
            defer { StubURLProtocol.beforeResponse = nil }
            await #expect(throws: TokenProviderError.signedOut) { try await provider.accessToken() }
            #expect(try store.load() == nil)
        }

        @Test func signedOutIsAnError() async throws {
            let provider = StoredTokenProvider(store: InMemoryTokenStore(), oauth: ClaudeOAuth(session: StubURLProtocol.session()))
            await #expect(throws: TokenProviderError.signedOut) { try await provider.accessToken() }
        }
    }
}
