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

        // MARK: One refresh in flight

        /// A store that counts its loads, and signals once a given number has been reached: every
        /// caller loads the set exactly once before it asks for a refresh or joins the one in
        /// flight, so the count says how many callers are waiting.
        final class CountingStore: TokenStore, @unchecked Sendable {
            let inner: InMemoryTokenStore
            private let lock = NSLock()
            private var loads = 0
            private let target: Int
            let reached = DispatchSemaphore(value: 0)

            init(_ tokens: Tokens?, signalAfter target: Int) {
                inner = InMemoryTokenStore(tokens)
                self.target = target
            }

            func load() throws -> Tokens? {
                let count = lock.withLock { loads += 1; return loads }
                if count == target { reached.signal() }
                return try inner.load()
            }
            func save(_ tokens: Tokens) throws { try inner.save(tokens) }
            func clear() throws { try inner.clear() }
        }

        static let stale = Tokens(accessToken: "stale", refreshToken: "r1", expiresAt: Date(), scopes: ["user:inference"])

        /// The token endpoint as the device run met it: a refresh token is single-use, so the first
        /// grant on `r1` rotates it and every later one on `r1` is refused.
        static func rotatingEndpoint(first: (status: Int, json: String)) -> @Sendable ([String: Any]) -> (status: Int, json: String) {
            let spent = NSLock()
            nonisolated(unsafe) var used: Set<String> = []
            return { body in
                let token = body["refresh_token"] as? String ?? ""
                let fresh = spent.withLock { used.insert(token).inserted }
                return fresh ? first : (400, #"{"error":"invalid_grant"}"#)
            }
        }

        /// Holds the first grant open until `store` has been loaded `callers` times, so every
        /// caller has arrived before any refresh lands. Bounded, so a provider that never lets the
        /// callers arrive fails on its counts rather than hanging.
        static func holdFirstGrant(until store: CountingStore) {
            let once = NSLock()
            nonisolated(unsafe) var held = false
            StubURLProtocol.beforeResponse = {
                let first = once.withLock { defer { held = true }; return !held }
                if first { _ = store.reached.wait(timeout: .now() + 5) }
            }
        }

        static func grants() -> Int {
            StubURLProtocol.bodies.filter {
                (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["grant_type"] as? String == "refresh_token"
            }.count
        }

        @Test func overlappingCallsOnAnExpiredSetSpendOneGrant() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            let callers = 6
            let store = CountingStore(Self.stale, signalAfter: callers)
            let provider = StoredTokenProvider(store: store, oauth: ClaudeOAuth(session: StubURLProtocol.session()))
            StubURLProtocol.responder = Self.rotatingEndpoint(first: (200, #"{"access_token":"new","refresh_token":"r2","expires_in":3600,"scope":"user:inference"}"#))
            Self.holdFirstGrant(until: store)

            // Five ask for an access token and one for a refresh, all at once.
            let tokens = await withTaskGroup(of: Result<String, any Error>.self) { group in
                for index in 0..<callers {
                    group.addTask {
                        await Self.outcome { index == 0 ? try await provider.refresh().accessToken : try await provider.accessToken() }
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(Self.grants() == 1, "overlapping callers spent \(Self.grants()) refresh grants")
            #expect(tokens.map { try? $0.get() } == Array(repeating: "new", count: callers))
            #expect(try store.load()?.refreshToken == "r2")

            // A caller after the refresh wrote its tokens reads them and makes no grant.
            #expect(try await provider.accessToken() == "new")
            #expect(Self.grants() == 1)
        }

        @Test func aFailedRefreshReachesEveryWaiterAndIsNotKept() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            let callers = 4
            let store = CountingStore(Self.stale, signalAfter: callers)
            let provider = StoredTokenProvider(store: store, oauth: ClaudeOAuth(session: StubURLProtocol.session()))
            StubURLProtocol.responder = { _ in (503, "{}") }
            Self.holdFirstGrant(until: store)

            let results = await withTaskGroup(of: Result<String, any Error>.self) { group in
                for _ in 0..<callers { group.addTask { await Self.outcome { try await provider.accessToken() } } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(Self.grants() == 1, "waiters on one failing refresh spent \(Self.grants()) grants")
            for result in results {
                #expect(throws: ClaudeOAuth.Error.http(status: 503)) { try result.get() }
            }
            #expect(try store.load() == Self.stale)

            // The next call makes a fresh attempt rather than meeting the failure again.
            StubURLProtocol.beforeResponse = nil
            StubURLProtocol.responder = { _ in (200, #"{"access_token":"new","refresh_token":"r2","expires_in":3600}"#) }
            #expect(try await provider.accessToken() == "new")
            #expect(Self.grants() == 2)
        }

        @Test func callersWaitingOnARefreshThatFinishesAfterSignOutWriteNothing() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            let callers = 3
            let store = CountingStore(Self.stale, signalAfter: callers)
            let provider = StoredTokenProvider(store: store, oauth: ClaudeOAuth(session: StubURLProtocol.session()))
            StubURLProtocol.responder = Self.rotatingEndpoint(first: (200, #"{"access_token":"new","refresh_token":"r2","expires_in":3600}"#))
            let once = NSLock()
            nonisolated(unsafe) var held = false
            StubURLProtocol.beforeResponse = {
                let first = once.withLock { defer { held = true }; return !held }
                if first { _ = store.reached.wait(timeout: .now() + 5) }
                try? store.clear()
            }

            let results = await withTaskGroup(of: Result<String, any Error>.self) { group in
                for _ in 0..<callers { group.addTask { await Self.outcome { try await provider.accessToken() } } }
                return await group.reduce(into: []) { $0.append($1) }
            }
            #expect(Self.grants() == 1)
            for result in results {
                #expect(throws: TokenProviderError.signedOut) { try result.get() }
            }
            #expect(try store.inner.load() == nil)
        }

        static func outcome(_ body: () async throws -> String) async -> Result<String, any Error> {
            do { return .success(try await body()) } catch { return .failure(error) }
        }
    }
}
