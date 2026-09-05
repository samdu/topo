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

    private var attempt: ClaudeOAuth.Attempt?
    private var loopback: LoopbackCallback?

    public init(oauth: ClaudeOAuth = ClaudeOAuth(), store: TokenStore = KeychainTokenStore()) {
        self.oauth = oauth
        self.store = store
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
        cancel()
        phase = .idle
    }

    private func exchange(code: String, state: String?) async {
        guard let attempt else { fail("No sign-in in progress."); return }
        phase = .exchanging
        do {
            let tokens = try await oauth.exchange(code: code, state: state, attempt: attempt)
            try store.save(tokens)
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

    private func fail(_ message: String) {
        loopback?.cancel()
        loopback = nil
        attempt = nil
        phase = .failed(message)
    }
}
