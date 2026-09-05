import CryptoKit
import Foundation

/// The Claude OAuth flow, as the Claude Code CLI performs it: authorization code with PKCE (S256)
/// against claude.com, token exchange and refresh against platform.claude.com. The endpoints,
/// client id and scopes are the CLI's own; Topo signs in as that client because a Claude
/// subscription is only reachable through it.
public struct ClaudeOAuth: Sendable {
    public struct Configuration: Sendable {
        public var authorizeURL: URL
        public var tokenURL: URL
        /// The hosted callback page that shows the user a `code#state` string to paste back.
        public var manualRedirectURL: URL
        public var clientID: String
        public var scopes: [String]

        public static let claude = Configuration(
            authorizeURL: URL(string: "https://claude.com/cai/oauth/authorize")!,
            tokenURL: URL(string: "https://platform.claude.com/v1/oauth/token")!,
            manualRedirectURL: URL(string: "https://platform.claude.com/oauth/code/callback")!,
            clientID: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            scopes: ["user:profile", "user:inference", "user:sessions:claude_code", "user:mcp_servers", "user:file_upload"]
        )

        public init(authorizeURL: URL, tokenURL: URL, manualRedirectURL: URL, clientID: String, scopes: [String]) {
            self.authorizeURL = authorizeURL
            self.tokenURL = tokenURL
            self.manualRedirectURL = manualRedirectURL
            self.clientID = clientID
            self.scopes = scopes
        }
    }

    /// Where the authorization server sends the browser after consent.
    public enum Redirect: Sendable, Equatable {
        /// A listener on `http://localhost:<port>/callback`, as the CLI uses on a machine with a browser.
        case loopback(port: UInt16)
        /// The hosted page on platform.claude.com; the user pastes the code it shows.
        case manual

        func url(_ config: Configuration) -> URL {
            switch self {
            case .loopback(let port): URL(string: "http://localhost:\(port)/callback")!
            case .manual: config.manualRedirectURL
            }
        }
    }

    /// One sign-in attempt: the PKCE verifier and state that must round-trip through the browser.
    public struct Attempt: Sendable, Equatable {
        public var state: String
        public var codeVerifier: String
        public var redirect: Redirect
        public var authorizeURL: URL
    }

    public enum Error: Swift.Error, Equatable {
        case stateMismatch
        case invalidCode
        case http(status: Int)
        case malformedResponse
    }

    public var configuration: Configuration
    public var session: URLSession

    public init(configuration: Configuration = .claude, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    // MARK: Authorize

    public func begin(redirect: Redirect) -> Attempt {
        let verifier = Self.randomToken(bytes: 96)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomToken(bytes: 32)
        return Attempt(
            state: state,
            codeVerifier: verifier,
            redirect: redirect,
            authorizeURL: authorizeURL(state: state, challenge: challenge, redirect: redirect)
        )
    }

    func authorizeURL(state: String, challenge: String, redirect: Redirect) -> URL {
        var components = URLComponents(url: configuration.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect.url(configuration).absoluteString),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    // MARK: Callback parsing

    /// The code and state carried by a loopback callback URL.
    public static func parseCallback(_ url: URL) -> (code: String, state: String)? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let code = items.first(where: { $0.name == "code" })?.value,
              let state = items.first(where: { $0.name == "state" })?.value
        else { return nil }
        return (code, state)
    }

    /// The string the hosted callback page shows: `code#state`, or a bare code.
    public static func parsePasted(_ text: String) -> (code: String, state: String?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 { return (String(parts[0]), String(parts[1])) }
        return (trimmed, nil)
    }

    // MARK: Token exchange

    /// Exchanges the authorization code for tokens. `state` is checked against the attempt when the
    /// callback carried one; a pasted bare code is accepted on the attempt's own state.
    public func exchange(code: String, state: String?, attempt: Attempt) async throws -> Tokens {
        if let state, state != attempt.state { throw Error.stateMismatch }
        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": attempt.redirect.url(configuration).absoluteString,
            "client_id": configuration.clientID,
            "code_verifier": attempt.codeVerifier,
            "state": attempt.state,
        ]
        return try await post(body)
    }

    public func refresh(_ tokens: Tokens) async throws -> Tokens {
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": configuration.clientID,
            "scope": (tokens.scopes.isEmpty ? configuration.scopes : tokens.scopes).joined(separator: " "),
        ]
        var refreshed = try await post(body)
        if refreshed.refreshToken.isEmpty { refreshed.refreshToken = tokens.refreshToken }
        return refreshed
    }

    private func post(_ body: [String: String]) async throws -> Tokens {
        var request = URLRequest(url: configuration.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw status == 401 ? Error.invalidCode : Error.http(status: status) }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data).tokens(now: Date())
        } catch {
            throw Error.malformedResponse
        }
    }

    // MARK: PKCE helpers

    static func randomToken(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in bytes.indices { bytes[i] = UInt8.random(in: .min ... .max) }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The token endpoint's reply.
struct TokenResponse: Decodable {
    var access_token: String
    var refresh_token: String?
    var expires_in: Double
    var scope: String?

    func tokens(now: Date) -> Tokens {
        Tokens(
            accessToken: access_token,
            refreshToken: refresh_token ?? "",
            expiresAt: now.addingTimeInterval(expires_in),
            scopes: scope?.split(separator: " ").map(String.init) ?? []
        )
    }
}

public struct Tokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scopes: [String]

    public init(accessToken: String, refreshToken: String, expiresAt: Date, scopes: [String]) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    /// True inside the last minute of the token's life, so a caller refreshes before a request fails.
    public func isExpired(at date: Date = Date()) -> Bool {
        date >= expiresAt.addingTimeInterval(-60)
    }
}
