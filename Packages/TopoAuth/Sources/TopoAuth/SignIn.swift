import Foundation
import Observation

/// Drives one "Sign in with Claude" from a button press to tokens in the store. The view supplies
/// the browser (a web-authentication session); this object owns the attempt, the loopback
/// listener and the exchange, so the flow is the same on every platform that can show a browser.
@MainActor
@Observable
public final class SignIn {
    public enum Phase: Equatable {
        case idle
        /// The browser is open; `pasteHint` is true when the flow expects a pasted code.
        case waiting(pasteHint: Bool)
        case exchanging
        case signedIn
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public let oauth: ClaudeOAuth
    public let store: TokenStore
    /// Where the guest's long-lived token is kept, or nil on a device that runs no guest (the hub,
    /// the watch, the television), which mints none.
    public let guestStore: TokenStore?

    private var attempt: ClaudeOAuth.Attempt?
    private var loopback: LoopbackCallback?

    public init(oauth: ClaudeOAuth = ClaudeOAuth(), store: TokenStore = KeychainTokenStore(),
                guestStore: TokenStore? = nil) {
        self.oauth = oauth
        self.store = store
        self.guestStore = guestStore
        if (try? store.load()) != nil { phase = .signedIn }
    }

    /// Starts an attempt and returns the URL to open. With a loopback listener the callback lands
    /// in `wait()`; without one (the listener failed to bind) the hosted page shows a code to paste.
    public func start() -> URL {
        cancel()
        let redirect: ClaudeOAuth.Redirect
        if let listener = try? LoopbackCallback() {
            loopback = listener
            redirect = .loopback(port: listener.port)
        } else {
            redirect = .manual
        }
        let attempt = oauth.begin(redirect: redirect)
        self.attempt = attempt
        phase = .waiting(pasteHint: redirect == .manual)
        if let listener = loopback {
            Task { [weak self] in
                guard let url = try? await listener.wait() else { return }
                await self?.finish(callback: url)
            }
        }
        return attempt.authorizeURL
    }

    /// The loopback listener caught the redirect.
    public func finish(callback url: URL) async {
        guard let parsed = ClaudeOAuth.parseCallback(url) else { fail("The sign-in came back without a code."); return }
        await exchange(code: parsed.code, state: parsed.state)
    }

    /// The user pasted what the hosted callback page showed.
    public func finish(pasted text: String) async {
        let parsed = ClaudeOAuth.parsePasted(text)
        guard !parsed.code.isEmpty else { fail("Paste the code the sign-in page showed."); return }
        await exchange(code: parsed.code, state: parsed.state)
    }

    public func cancel() {
        loopback?.cancel()
        loopback = nil
        attempt = nil
        if case .waiting = phase { phase = .idle }
    }

    public func signOut() {
        try? store.clear()
        try? guestStore?.clear()
        cancel()
        phase = .idle
    }

    private func exchange(code: String, state: String?) async {
        guard let attempt else { fail("No sign-in in progress."); return }
        phase = .exchanging
        do {
            var tokens = try await oauth.exchange(code: code, state: state, attempt: attempt)
            let guest = await mintGuestToken(from: &tokens)
            try store.save(tokens)
            if let guestStore {
                if let guest { try guestStore.save(guest) } else { try guestStore.clear() }
            }
            loopback = nil
            self.attempt = nil
            phase = .signedIn
        } catch ClaudeOAuth.Error.stateMismatch {
            fail("The sign-in didn't match this attempt. Try again.")
        } catch ClaudeOAuth.Error.invalidCode {
            fail("Claude didn't accept that code. Try again.")
        } catch {
            fail("Sign-in failed: \(error)")
        }
    }

    /// The guest's long-lived token, minted from the fresh sign-in's refresh token, or nil when this
    /// device mints none or the endpoint would not mint one — in which case the guest is handed the
    /// ordinary access token instead (`GuestCredential`). A refresh token the mint came back with
    /// replaces the one it spent, so the ordinary tokens carry on whether or not the server rotates.
    private func mintGuestToken(from tokens: inout Tokens) async -> Tokens? {
        guard guestStore != nil, !tokens.refreshToken.isEmpty else { return nil }
        guard var minted = try? await oauth.mintLongLived(from: tokens) else { return nil }
        if !minted.refreshToken.isEmpty { tokens.refreshToken = minted.refreshToken }
        minted.refreshToken = ""
        return minted
    }

    private func fail(_ message: String) {
        loopback?.cancel()
        loopback = nil
        attempt = nil
        phase = .failed(message)
    }
}
