import Foundation
import Testing
@testable import TopoAuth

/// The guest's long-lived token: its own authorization after the ordinary one, asked for the way
/// `claude setup-token` asks (`user:inference` alone, `expires_in` of a year on the exchange), kept
/// in the keychain beside the ordinary tokens, removed by sign-out, and what the guest is handed.
/// The ordinary tokens are the first exchange's, untouched by the second.
extension Stubbed {
    @Suite @MainActor struct GuestTokenTests {
        nonisolated static let ordinaryReply = #"{"access_token":"ordinary","refresh_token":"first","expires_in":28800,"scope":"user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"}"#
        nonisolated static let longLivedReply = #"{"access_token":"long-lived","refresh_token":"inference-only","expires_in":31536000,"scope":"user:inference"}"#

        /// The token endpoint as a sign-in meets it: a code exchange asking for a year answers the
        /// long-lived token and any other code exchange the ordinary one; a refresh grant answers as
        /// the real endpoint did on the device, with a rotated refresh token carrying only what it
        /// was asked for.
        static func tokenEndpoint(longLived: (status: Int, json: String) = (200, longLivedReply)) -> @Sendable ([String: Any]) -> (status: Int, json: String) {
            { body in
                switch body["grant_type"] as? String {
                case "authorization_code": body["expires_in"] != nil ? longLived : (200, ordinaryReply)
                case "refresh_token": (200, #"{"access_token":"refreshed","refresh_token":"rotated","expires_in":31536000,"scope":"user:inference"}"#)
                default: (400, #"{"error":"unsupported_grant_type"}"#)
                }
            }
        }

        /// The browser, as far as the listener is concerned: one request, redirects not followed.
        final class NoFollow: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
                completionHandler(nil)
            }
        }

        struct Browser {
            let session = URLSession(configuration: .ephemeral, delegate: NoFollow(), delegateQueue: nil)
            /// Hits `authorizeURL`'s redirect_uri as the authorization server would after Approve.
            func approve(_ authorizeURL: URL, code: String) async throws -> HTTPURLResponse {
                let items = try #require(URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems)
                let redirect = try #require(items.first { $0.name == "redirect_uri" }?.value)
                let state = try #require(items.first { $0.name == "state" }?.value)
                let (_, response) = try await session.data(from: URL(string: "\(redirect)?code=\(code)&state=\(state)")!)
                return try #require(response as? HTTPURLResponse)
            }
        }

        static func query(_ url: URL, _ name: String) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
        }

        static func sentBodies() -> [[String: Any]] {
            StubURLProtocol.bodies.compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }

        func settle(_ signIn: SignIn, until done: (SignIn.Phase) -> Bool) async throws {
            for _ in 0..<200 where !done(signIn.phase) { try await Task.sleep(for: .milliseconds(10)) }
        }

        /// Runs the ordinary authorization through the loopback listener and returns where its
        /// callback sent the browser.
        func approveTheLogin(_ signIn: SignIn, browser: Browser) async throws -> URL {
            let url = signIn.start()
            let response = try await browser.approve(url, code: "login-code")
            #expect(response.statusCode == 302, "the login's callback did not send the browser on to the guest's authorization")
            let next = try #require(response.value(forHTTPHeaderField: "Location").flatMap(URL.init(string:)))
            try await settle(signIn) { if case .approvingGuest = $0 { true } else { false } }
            return next
        }

        @Test func theGuestsAuthorizationIsAskedForAsSetupTokenAsksForOne() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            let oauth = ClaudeOAuth(session: StubURLProtocol.session())
            let login = oauth.begin(redirect: .loopback(port: 4000))
            let guest = oauth.begin(redirect: .loopback(port: 4001), grant: .longLived)
            #expect(Self.query(login.authorizeURL, "scope") == ClaudeOAuth.Configuration.claude.scopes.joined(separator: " "))
            #expect(Self.query(guest.authorizeURL, "scope") == "user:inference")
            #expect(Self.query(guest.authorizeURL, "client_id") == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
            #expect(guest.authorizeURL.absoluteString.hasPrefix("https://claude.com/cai/oauth/authorize?"))

            StubURLProtocol.responder = Self.tokenEndpoint()
            _ = try await oauth.exchange(code: "c", state: nil, attempt: login)
            let minted = try await oauth.exchange(code: "g", state: nil, attempt: guest)
            let bodies = Self.sentBodies()
            #expect(bodies.count == 2)
            #expect(bodies.first?["expires_in"] == nil)
            #expect(bodies.last?["grant_type"] as? String == "authorization_code")
            #expect(bodies.last?["code"] as? String == "g")
            #expect(bodies.last?["expires_in"] as? Int == 31_536_000)
            #expect(minted.accessToken == "long-lived")
            #expect(abs(minted.expiresAt.timeIntervalSinceNow - 31_536_000) < 5)
        }

        /// Review focus 4 and the device finding: two authorizations, two code exchanges and no
        /// refresh grant; the ordinary tokens are exactly what their own exchange returned, their
        /// refresh token byte for byte; the guest keeps the long-lived access token alone; sign-out
        /// removes both keychain items.
        #if os(macOS)
        @Test func signInIsTwoAuthorizationsAndLeavesTheOrdinaryTokensAsTheirExchangeGaveThem() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            StubURLProtocol.responder = Self.tokenEndpoint()
            let keychain = try TemporaryKeychain()
            defer { keychain.delete() }
            let account = UUID().uuidString
            var store = KeychainTokenStore(service: "zone.hexagon.topo.tests", account: account)
            var guest = KeychainTokenStore(service: "zone.hexagon.topo.tests", account: account + "-guest")
            store.keychainPath = keychain.path
            guest.keychainPath = keychain.path
            let signIn = SignIn(oauth: ClaudeOAuth(session: StubURLProtocol.session()), store: store, guestStore: guest)
            let browser = Browser()

            let next = try await approveTheLogin(signIn, browser: browser)
            #expect(signIn.phase == .approvingGuest(opening: nil, pasteHint: false))
            #expect(Self.query(next, "scope") == "user:inference")
            let ordinaryBefore = try #require(try store.load())
            #expect(ordinaryBefore.refreshToken == "first")

            _ = try await browser.approve(next, code: "guest-code")
            try await settle(signIn) { $0 == .signedIn }
            #expect(signIn.phase == .signedIn)

            let bodies = Self.sentBodies()
            #expect(bodies.map { $0["grant_type"] as? String } == ["authorization_code", "authorization_code"])
            #expect(bodies.map { $0["code"] as? String } == ["login-code", "guest-code"])
            #expect(bodies.last?["expires_in"] as? Int == 31_536_000)
            let ordinary = try #require(try store.load())
            #expect(ordinary == ordinaryBefore)
            #expect(Data(ordinary.refreshToken.utf8) == Data("first".utf8))
            #expect(ordinary.scopes == ClaudeOAuth.Configuration.claude.scopes)
            let minted = try #require(try guest.load())
            #expect(minted.accessToken == "long-lived")
            #expect(minted.refreshToken == "", "the guest's inference-only refresh token was kept")
            #expect(minted.scopes == ["user:inference"])
            #expect(minted.expiresAt > Date().addingTimeInterval(364 * 86_400))
            #expect(keychain.holdsItem(service: guest.service, account: guest.account))

            signIn.signOut()
            #expect(!keychain.holdsItem(service: guest.service, account: guest.account), "sign-out left the guest's token in the keychain")
            #expect(!keychain.holdsItem(service: store.service, account: store.account))
        }
        #endif

        /// The second Approve declined (the sheet closed, or Skip): signed in, no guest token kept —
        /// an earlier login's included — and the guest is handed the ordinary access token.
        @Test func declinedSecondApproveStillSignsInAndTheGuestFallsBack() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            StubURLProtocol.responder = Self.tokenEndpoint()
            let store = InMemoryTokenStore()
            let guest = InMemoryTokenStore(Tokens(accessToken: "an-earlier-login", refreshToken: "", expiresAt: .distantFuture, scopes: []))
            let signIn = SignIn(oauth: ClaudeOAuth(session: StubURLProtocol.session()), store: store, guestStore: guest)
            let next = try await approveTheLogin(signIn, browser: Browser())
            signIn.cancel()
            #expect(signIn.phase == .signedIn)
            #expect(try guest.load() == nil)
            #expect(try store.load()?.refreshToken == "first")
            // Its listener is gone: an Approve after the decline reaches nothing.
            await #expect(throws: (any Error).self) { _ = try await Browser().approve(next, code: "late") }
            #expect(StubURLProtocol.bodies.count == 1)

            let credential = GuestCredential(store: guest, fallback: StoredTokenProvider(store: store, oauth: ClaudeOAuth(session: StubURLProtocol.session())))
            let handed = try await credential.token()
            #expect(handed.token == "ordinary")
            #expect(handed.source == .accessToken)
        }

        /// A second exchange the endpoint refuses is the same fallback, and leaves the ordinary
        /// tokens as they were.
        @Test func aRefusedSecondExchangeStillSignsIn() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            StubURLProtocol.responder = Self.tokenEndpoint(longLived: (400, #"{"error":"invalid_request"}"#))
            let store = InMemoryTokenStore()
            let guest = InMemoryTokenStore()
            let signIn = SignIn(oauth: ClaudeOAuth(session: StubURLProtocol.session()), store: store, guestStore: guest)
            let browser = Browser()
            let next = try await approveTheLogin(signIn, browser: browser)
            _ = try await browser.approve(next, code: "guest-code")
            try await settle(signIn) { $0 == .signedIn }
            #expect(signIn.phase == .signedIn)
            #expect(try guest.load() == nil)
            #expect(try store.load()?.refreshToken == "first")
            #expect(Self.sentBodies().count == 2)
        }

        /// The guest's code can come back pasted, like the login's.
        @Test func thePastedGuestCodeIsTheGuestsExchange() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            StubURLProtocol.responder = Self.tokenEndpoint()
            let store = InMemoryTokenStore()
            let guest = InMemoryTokenStore()
            let signIn = SignIn(oauth: ClaudeOAuth(session: StubURLProtocol.session()), store: store, guestStore: guest)
            let next = try await approveTheLogin(signIn, browser: Browser())
            await signIn.finish(pasted: "guest-code#\(try #require(Self.query(next, "state")))")
            #expect(signIn.phase == .signedIn)
            #expect(try guest.load()?.accessToken == "long-lived")
            #expect(try store.load()?.refreshToken == "first")
        }

        /// With no loopback listener for either authorization, both codes are pasted: the login's,
        /// then the guest's from the second authorization the screen is told to open, and the
        /// ordinary tokens are the first exchange's throughout.
        @Test func withNoListenerBothCodesArePasted() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            StubURLProtocol.responder = Self.tokenEndpoint()
            let store = InMemoryTokenStore()
            let guest = InMemoryTokenStore()
            let signIn = SignIn(oauth: ClaudeOAuth(session: StubURLProtocol.session()), store: store, guestStore: guest)
            var binds = 0
            signIn.makeListener = { binds += 1; return nil }

            let login = signIn.start()
            #expect(signIn.phase == .waiting(pasteHint: true))
            #expect(Self.query(login, "redirect_uri") == "https://platform.claude.com/oauth/code/callback")
            await signIn.finish(pasted: "login-code#\(try #require(Self.query(login, "state")))")
            guard case .approvingGuest(let opening?, pasteHint: true) = signIn.phase else {
                Issue.record("the login's paste did not ask for the guest's authorization to be opened: \(signIn.phase)")
                return
            }
            #expect(binds == 2, "the guest's authorization did not try a listener of its own")
            #expect(Self.query(opening, "scope") == "user:inference")
            #expect(Self.query(opening, "redirect_uri") == "https://platform.claude.com/oauth/code/callback")
            let ordinaryBefore = try #require(try store.load())

            await signIn.finish(pasted: "guest-code#\(try #require(Self.query(opening, "state")))")
            #expect(signIn.phase == .signedIn)
            let minted = try #require(try guest.load())
            #expect(minted.accessToken == "long-lived")
            #expect(minted.refreshToken == "")
            #expect(try store.load() == ordinaryBefore)
            #expect(try store.load()?.refreshToken == "first")
            let bodies = Self.sentBodies()
            #expect(bodies.map { $0["code"] as? String } == ["login-code", "guest-code"])
            #expect(bodies.map { $0["grant_type"] as? String } == ["authorization_code", "authorization_code"])
            #expect(bodies.last?["expires_in"] as? Int == 31_536_000)
        }

        /// A device with no guest store (the hub) asks for no second authorization: one exchange,
        /// and the callback is answered with the "Signed in" page rather than sent anywhere.
        @Test func aDeviceWithNoGuestAsksForNoSecondAuthorization() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            StubURLProtocol.responder = Self.tokenEndpoint()
            let store = InMemoryTokenStore()
            let signIn = SignIn(oauth: ClaudeOAuth(session: StubURLProtocol.session()), store: store)
            let response = try await Browser().approve(signIn.start(), code: "login-code")
            #expect(response.statusCode == 200)
            try await settle(signIn) { $0 == .signedIn }
            #expect(signIn.phase == .signedIn)
            #expect(StubURLProtocol.bodies.count == 1)
            #expect(try store.load()?.refreshToken == "first")
        }

        @Test func theGuestIsHandedTheLongLivedTokenUntilItExpires() async throws {
            let ordinary = InMemoryTokenStore(Tokens(accessToken: "ordinary", refreshToken: "r", expiresAt: .distantFuture, scopes: []))
            let guest = InMemoryTokenStore(Tokens(accessToken: "long-lived", refreshToken: "", expiresAt: Date().addingTimeInterval(86_400), scopes: []))
            let credential = GuestCredential(store: guest, fallback: StoredTokenProvider(store: ordinary))
            #expect(try await credential.token() == ("long-lived", .longLived))
            try guest.save(Tokens(accessToken: "long-lived", refreshToken: "", expiresAt: Date(), scopes: []))
            #expect(try await credential.token() == ("ordinary", .accessToken))
            try ordinary.clear()
            try guest.clear()
            await #expect(throws: TokenProviderError.signedOut) { try await credential.token() }
        }
    }
}
