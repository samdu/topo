import Foundation
import Testing
@testable import TopoAuth

@Suite(.serialized) struct ClaudeOAuthTests {
    let oauth = ClaudeOAuth(configuration: .claude, session: StubURLProtocol.session())

    @Test func authorizeURLCarriesThePKCEAndStateTheCLISends() throws {
        let attempt = oauth.begin(redirect: .loopback(port: 51234))
        let items = try #require(URLComponents(url: attempt.authorizeURL, resolvingAgainstBaseURL: false)?.queryItems)
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        #expect(attempt.authorizeURL.host == "claude.com")
        #expect(attempt.authorizeURL.path == "/cai/oauth/authorize")
        #expect(q["code"] == "true")
        #expect(q["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(q["response_type"] == "code")
        #expect(q["redirect_uri"] == "http://localhost:51234/callback")
        #expect(q["scope"] == "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload")
        #expect(q["code_challenge_method"] == "S256")
        #expect(q["state"] == attempt.state)
        #expect(q["code_challenge"] == ClaudeOAuth.base64URL(sha256(attempt.codeVerifier)))
    }

    @Test func manualRedirectUsesTheHostedCallbackPage() {
        let attempt = oauth.begin(redirect: .manual)
        #expect(attempt.authorizeURL.absoluteString.contains("redirect_uri=https://platform.claude.com/oauth/code/callback"))
    }

    @Test func eachAttemptIsFresh() {
        let a = oauth.begin(redirect: .manual), b = oauth.begin(redirect: .manual)
        #expect(a.state != b.state)
        #expect(a.codeVerifier != b.codeVerifier)
        #expect(a.codeVerifier.count >= 43)
    }

    @Test func parsesTheLoopbackCallback() throws {
        let url = try #require(URL(string: "http://localhost:5/callback?code=abc&state=xyz"))
        let parsed = try #require(ClaudeOAuth.parseCallback(url))
        #expect(parsed.code == "abc" && parsed.state == "xyz")
        #expect(ClaudeOAuth.parseCallback(URL(string: "http://localhost:5/callback?error=denied")!) == nil)
    }

    @Test func parsesThePastedCode() {
        #expect(ClaudeOAuth.parsePasted(" abc#xyz\n").code == "abc")
        #expect(ClaudeOAuth.parsePasted(" abc#xyz\n").state == "xyz")
        #expect(ClaudeOAuth.parsePasted("abc").state == nil)
    }

    @Test func exchangePostsTheCLIsJSONBodyAndReadsTokens() async throws {
        let attempt = oauth.begin(redirect: .loopback(port: 4000))
        StubURLProtocol.respond(status: 200, json: #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"scope":"user:inference user:profile"}"#)
        let tokens = try await oauth.exchange(code: "the-code", state: attempt.state, attempt: attempt)
        let request = try #require(StubURLProtocol.lastRequest)
        let body = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data()) as? [String: String])
        #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(body["grant_type"] == "authorization_code")
        #expect(body["code"] == "the-code")
        #expect(body["redirect_uri"] == "http://localhost:4000/callback")
        #expect(body["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(body["code_verifier"] == attempt.codeVerifier)
        #expect(body["state"] == attempt.state)
        #expect(tokens.accessToken == "at")
        #expect(tokens.refreshToken == "rt")
        #expect(tokens.scopes == ["user:inference", "user:profile"])
        #expect(abs(tokens.expiresAt.timeIntervalSinceNow - 3600) < 5)
        #expect(!tokens.isExpired())
        #expect(tokens.isExpired(at: Date().addingTimeInterval(3560)))
    }

    @Test func aBarePastedCodeIsAcceptedAndAForeignStateIsNot() async throws {
        let attempt = oauth.begin(redirect: .manual)
        StubURLProtocol.respond(status: 200, json: #"{"access_token":"at","refresh_token":"rt","expires_in":10}"#)
        _ = try await oauth.exchange(code: "c", state: nil, attempt: attempt)
        await #expect(throws: ClaudeOAuth.Error.stateMismatch) {
            try await oauth.exchange(code: "c", state: "someone-elses", attempt: attempt)
        }
    }

    @Test func aRejectedCodeIsInvalidAndOtherStatusesSurface() async throws {
        let attempt = oauth.begin(redirect: .manual)
        StubURLProtocol.respond(status: 401, json: "{}")
        await #expect(throws: ClaudeOAuth.Error.invalidCode) { try await oauth.exchange(code: "c", state: nil, attempt: attempt) }
        StubURLProtocol.respond(status: 500, json: "{}")
        await #expect(throws: ClaudeOAuth.Error.http(status: 500)) { try await oauth.exchange(code: "c", state: nil, attempt: attempt) }
        StubURLProtocol.respond(status: 200, json: "not json")
        await #expect(throws: ClaudeOAuth.Error.malformedResponse) { try await oauth.exchange(code: "c", state: nil, attempt: attempt) }
    }

    @Test func refreshKeepsTheOldRefreshTokenWhenNoneComesBack() async throws {
        let old = Tokens(accessToken: "a", refreshToken: "keep-me", expiresAt: .distantPast, scopes: ["user:inference"])
        StubURLProtocol.respond(status: 200, json: #"{"access_token":"b","expires_in":100}"#)
        let new = try await oauth.refresh(old)
        let body = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody ?? Data()) as? [String: String])
        #expect(body["grant_type"] == "refresh_token")
        #expect(body["refresh_token"] == "keep-me")
        #expect(body["scope"] == "user:inference")
        #expect(new.accessToken == "b")
        #expect(new.refreshToken == "keep-me")
    }

    @Test func inMemoryStoreRoundTrips() throws {
        let store = InMemoryTokenStore()
        #expect(try store.load() == nil)
        let t = Tokens(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1), scopes: [])
        try store.save(t)
        #expect(try store.load() == t)
        try store.clear()
        #expect(try store.load() == nil)
    }
}

private func sha256(_ s: String) -> Data {
    import_CryptoKit_sha256(Data(s.utf8))
}
