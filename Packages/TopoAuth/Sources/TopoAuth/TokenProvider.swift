import Foundation

/// Hands out a usable access token, refreshing it first when it is about to expire.
public protocol TokenProvider: Sendable {
    func accessToken() async throws -> String
}

public enum TokenProviderError: Error, Equatable {
    case signedOut
}

/// Tokens from the store, refreshed through the OAuth client and written back. A refresh token is
/// single-use — the grant rotates it, and a second grant on the spent one is refused — so a
/// provider has one refresh in flight at most: a caller that finds the set expired while a refresh
/// is running, or asks for a refresh while one is, awaits that refresh and gets its result, tokens
/// or error. The app makes one provider over the ordinary store and hands it to every path that
/// needs a token (`TopoApp`), which makes that one refresh in flight for the process. A failed
/// refresh is not kept: the next call after it makes a fresh attempt. A refresh that finishes
/// after a sign-out, or after another writer replaced the tokens, is not written back: the store
/// must still hold exactly what was loaded.
public actor StoredTokenProvider: TokenProvider {
    /// The store this provider reads and writes, for a caller that reports on what it holds.
    public nonisolated let store: TokenStore
    private let oauth: ClaudeOAuth
    private let now: @Sendable () -> Date
    /// The refresh every caller awaits while it runs; nil between refreshes.
    private var inFlight: Task<Tokens, any Error>?

    public init(store: TokenStore, oauth: ClaudeOAuth = ClaudeOAuth(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.oauth = oauth
        self.now = now
    }

    /// What the store holds, without touching the network, for a diagnostics screen.
    public enum State: Equatable, Sendable {
        case signedOut
        case expired(at: Date)
        case valid(until: Date)
    }

    public func state() -> State {
        guard let tokens = try? store.load() else { return .signedOut }
        return tokens.isExpired(at: now()) ? .expired(at: tokens.expiresAt) : .valid(until: tokens.expiresAt)
    }

    /// The stored access token, or, when it is about to expire, what the refresh in flight returns
    /// (a new one when none is). A caller arriving after a refresh wrote its tokens reads those and
    /// makes no grant.
    public func accessToken() async throws -> String {
        guard let tokens = try store.load() else { throw TokenProviderError.signedOut }
        guard tokens.isExpired(at: now()) else { return tokens.accessToken }
        return try await refresh(tokens).accessToken
    }

    /// Refreshes now, expired or not, and writes the result back as `accessToken` does: what the
    /// refresh grant returned, its granted `scopes` included. Asked for while a refresh is in
    /// flight, it is that refresh.
    public func refresh() async throws -> Tokens {
        guard let tokens = try store.load() else { throw TokenProviderError.signedOut }
        return try await refresh(tokens)
    }

    private func refresh(_ tokens: Tokens) async throws -> Tokens {
        if let inFlight { return try await inFlight.value }
        // The task inherits this actor, so it cannot start before `inFlight` is set, and it clears
        // `inFlight` on the actor as it ends, before any caller resumes: a call after a failure
        // finds nothing in flight and makes its own grant. A caller cancelled while it waits
        // leaves the refresh running for the others.
        let task = Task { () throws -> Tokens in
            defer { inFlight = nil }
            let refreshed = try await oauth.refresh(tokens)
            guard try store.load() == tokens else { throw TokenProviderError.signedOut }
            try store.save(refreshed)
            return refreshed
        }
        inFlight = task
        return try await task.value
    }
}

/// The token Claude Code in the guest is started with, as `CLAUDE_CODE_OAUTH_TOKEN`: the
/// long-lived one sign-in minted when there is one and it has not expired, and otherwise the
/// ordinary access token, refreshed first if it is about to expire. The guest never refreshes: a
/// refresh would go to platform.claude.com over the guest's own TLS, which fails under the
/// emulator, so whatever it is handed has to last the life of the process it is handed to.
public struct GuestCredential: Sendable {
    public enum Source: Equatable, Sendable {
        /// The long-lived token sign-in minted.
        case longLived
        /// The ordinary access token, since no long-lived one is held.
        case accessToken
    }

    public var store: TokenStore
    public var fallback: TokenProvider
    public var now: @Sendable () -> Date

    public init(store: TokenStore, fallback: TokenProvider, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.fallback = fallback
        self.now = now
    }

    /// Throws `TokenProviderError.signedOut` when there is no login at all.
    public func token() async throws -> (token: String, source: Source) {
        if let minted = try store.load(), !minted.accessToken.isEmpty, !minted.isExpired(at: now()) {
            return (minted.accessToken, .longLived)
        }
        return (try await fallback.accessToken(), .accessToken)
    }
}
