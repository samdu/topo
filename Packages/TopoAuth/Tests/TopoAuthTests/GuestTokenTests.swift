import Foundation
import Testing
@testable import TopoAuth

/// The guest's long-lived token: minted at sign-in the way `claude setup-token` asks for one, kept
/// in the keychain beside the ordinary tokens, removed by sign-out, and what the guest is handed.
extension Stubbed {
    @Suite @MainActor struct GuestTokenTests {
        /// The token endpoint as a sign-in meets it: the code exchange answers the ordinary tokens,
        /// the refresh grant answers the long-lived one and a rotated refresh token.
        static func tokenEndpoint(mint: (status: Int, json: String)? = nil) -> @Sendable ([String: Any]) -> (status: Int, json: String) {
            let mint = mint ?? (200, #"{"access_token":"long-lived","refresh_token":"rotated","expires_in":31536000,"scope":"user:inference"}"#)
            return { body in
                switch body["grant_type"] as? String {
                case "authorization_code":
                    return (200, #"{"access_token":"ordinary","refresh_token":"first","expires_in":28800,"scope":"user:inference user:profile"}"#)
                case "refresh_token": return mint
                default: return (400, "{}")
                }
            }
        }

        @Test func theMintIsTheCLIsLoginFromARefreshToken() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            StubURLProtocol.respond(status: 200, json: #"{"access_token":"long-lived","expires_in":31536000,"scope":"user:inference"}"#)
            let oauth = ClaudeOAuth(session: StubURLProtocol.session())
            let minted = try await oauth.mintLongLived(from: Tokens(accessToken: "a", refreshToken: "the-refresh", expiresAt: .distantFuture, scopes: ["user:profile"]))
            let body = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data()) as? [String: Any])
            #expect(StubURLProtocol.lastRequest?.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
            #expect(body["grant_type"] as? String == "refresh_token")
            #expect(body["refresh_token"] as? String == "the-refresh")
            #expect(body["client_id"] as? String == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
            #expect(body["scope"] as? String == "user:inference")
            #expect(body["expires_in"] as? Int == 31_536_000)
            #expect(minted.accessToken == "long-lived")
            #expect(minted.refreshToken == "")
            #expect(abs(minted.expiresAt.timeIntervalSinceNow - 31_536_000) < 5)
        }

        #if os(macOS)
        /// Review focus 4: sign-in stores the long-lived token beside the ordinary ones, in the
        /// keychain, and sign-out removes it from the keychain.
        @Test func signInKeepsTheLongLivedTokenBesideTheOrdinaryOnesAndSignOutRemovesIt() async throws {
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

            _ = signIn.start()
            await signIn.finish(pasted: "the-code")
            #expect(signIn.phase == .signedIn)
            let ordinary = try #require(try store.load())
            let minted = try #require(try guest.load())
            #expect(ordinary.accessToken == "ordinary")
            // The refresh token the mint came back with is the one the ordinary tokens carry on with.
            #expect(ordinary.refreshToken == "rotated")
            #expect(minted.accessToken == "long-lived")
            #expect(minted.refreshToken == "")
            #expect(minted.expiresAt > Date().addingTimeInterval(364 * 86_400))
            #expect(keychain.holdsItem(service: guest.service, account: guest.account))
            let grants = StubURLProtocol.bodies.compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["grant_type"] as? String }
            #expect(grants == ["authorization_code", "refresh_token"])

            signIn.signOut()
            #expect(!keychain.holdsItem(service: guest.service, account: guest.account), "sign-out left the guest's token in the keychain")
            #expect(!keychain.holdsItem(service: store.service, account: store.account))
        }
        #endif

        /// An endpoint that will not mint one still signs in; the guest falls back to the ordinary
        /// access token, and a long-lived token from an earlier login is not left behind.
        @Test func aRefusedMintStillSignsInAndLeavesNoGuestToken() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            StubURLProtocol.responder = Self.tokenEndpoint(mint: (400, #"{"error":"invalid_request"}"#))
            let store = InMemoryTokenStore()
            let guest = InMemoryTokenStore(Tokens(accessToken: "an-earlier-login", refreshToken: "", expiresAt: .distantFuture, scopes: []))
            let signIn = SignIn(oauth: ClaudeOAuth(session: StubURLProtocol.session()), store: store, guestStore: guest)
            _ = signIn.start()
            await signIn.finish(pasted: "the-code")
            #expect(signIn.phase == .signedIn)
            #expect(try store.load()?.refreshToken == "first")
            #expect(try guest.load() == nil)
            let credential = GuestCredential(store: guest, fallback: StoredTokenProvider(store: store, oauth: ClaudeOAuth(session: StubURLProtocol.session())))
            let handed = try await credential.token()
            #expect(handed.token == "ordinary")
            #expect(handed.source == .accessToken)
        }

        /// A device with no guest store (the hub) mints nothing: one request, the exchange.
        @Test func aDeviceWithNoGuestMintsNothing() async throws {
            StubURLProtocol.reset()
            defer { StubURLProtocol.reset() }
            StubURLProtocol.responder = Self.tokenEndpoint()
            let store = InMemoryTokenStore()
            let signIn = SignIn(oauth: ClaudeOAuth(session: StubURLProtocol.session()), store: store)
            _ = signIn.start()
            await signIn.finish(pasted: "the-code")
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
