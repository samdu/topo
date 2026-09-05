import Foundation

/// Hands out a usable access token, refreshing it first when it is about to expire.
public protocol TokenProvider: Sendable {
    func accessToken() async throws -> String
}

public enum TokenProviderError: Error, Equatable {
    case signedOut
}

/// Tokens from the store, refreshed through the OAuth client and written back. Refreshes run one
/// at a time so two turns in flight cannot both spend the same refresh token, and a refresh that
/// finishes after a sign-out, or after another writer replaced the tokens, is not written back:
/// the store must still hold exactly what was loaded.
public actor StoredTokenProvider: TokenProvider {
    private let store: TokenStore
    private let oauth: ClaudeOAuth
    private let now: @Sendable () -> Date

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

    public func accessToken() async throws -> String {
        guard let tokens = try store.load() else { throw TokenProviderError.signedOut }
        guard tokens.isExpired(at: now()) else { return tokens.accessToken }
        let refreshed = try await oauth.refresh(tokens)
        guard try store.load() == tokens else { throw TokenProviderError.signedOut }
        try store.save(refreshed)
        return refreshed.accessToken
    }
}
