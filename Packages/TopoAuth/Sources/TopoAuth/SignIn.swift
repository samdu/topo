import Foundation
import Observation

/// Drives one "Sign in with Claude" from a button press to tokens in the store. The view supplies
/// the browser (a web-authentication session); this object owns the attempt, the loopback
/// listener and the exchange, so the flow is the same on every platform that can show a browser.
///
/// On a device that runs a guest (`guestStore` set) the sign-in is two authorizations, as
/// `claude login` and `claude setup-token` are two: the ordinary login, then the guest's
/// long-lived token (`ClaudeOAuth.Grant.longLived`), each with its own code, verifier and exchange,
/// so the second never touches the ordinary tokens. With a loopback listener the first callback
/// is answered with a redirect to the second authorization, so the same browser sheet goes straight
/// on to it; otherwise the second is opened (`Phase.approvingGuest(opening:)`) and its code pasted.
/// A second authorization that fails or is declined still leaves the person signed in, with no
/// guest token kept, and the guest runs on the ordinary access token (`GuestCredential`).
@MainActor
@Observable
public final class SignIn {
    public enum Phase: Equatable {
        case idle
        /// The browser is open; `pasteHint` is true when the flow expects a pasted code.
        case waiting(pasteHint: Bool)
        case exchanging
        /// Signed in; the guest's authorization is waiting for its Approve. `opening` is a URL the
        /// view has to open, nil when the browser is already on its way there.
        case approvingGuest(opening: URL?, pasteHint: Bool)
        case signedIn
        case failed(String)
    }

    public private(set) var phase: Phase = .idle
    public let oauth: ClaudeOAuth
    public let store: TokenStore
    /// Where the guest's long-lived token is kept, or nil on a device that runs no guest (the hub,
    /// the watch, the television), which asks for none.
    public let guestStore: TokenStore?

    private var attempt: ClaudeOAuth.Attempt?
    private var loopback: LoopbackCallback?
    private var guestAttempt: ClaudeOAuth.Attempt?
    private var guestLoopback: LoopbackCallback?
    /// The first callback redirects the browser to the guest's authorization.
    private var chained = false
    /// The guest's code, when its callback arrived before the ordinary exchange had finished.
    private var guestCode: (code: String, state: String?)?
    /// The guest's authorization was declined while the ordinary exchange was still running.
    private var guestDeclined = false
    private var exchangingGuest = false
    /// Makes a loopback listener, nil when none binds. A test makes it nil to take the paste path.
    var makeListener: () -> LoopbackCallback? = { try? LoopbackCallback() }

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
        reset()
        let redirect: ClaudeOAuth.Redirect
        if let listener = makeListener() {
            loopback = listener
            redirect = .loopback(port: listener.port)
        } else {
            redirect = .manual
        }
        let attempt = oauth.begin(redirect: redirect)
        self.attempt = attempt
        phase = .waiting(pasteHint: redirect == .manual)
        if guestStore != nil, let listener = loopback {
            prepareGuest()
            if let guestAttempt, guestLoopback != nil {
                listener.redirectOnSuccess(to: guestAttempt.authorizeURL)
                chained = true
            }
        }
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

    /// The user pasted what the hosted callback page showed, for whichever authorization is waiting.
    public func finish(pasted text: String) async {
        let parsed = ClaudeOAuth.parsePasted(text)
        if case .approvingGuest = phase {
            await exchangeGuest(code: parsed.code, state: parsed.state)
            return
        }
        guard !parsed.code.isEmpty else { fail("Paste the code the sign-in page showed."); return }
        await exchange(code: parsed.code, state: parsed.state)
    }

    /// The browser was closed or Cancel pressed. Before the login lands that ends the attempt;
    /// once it has, it declines the guest's authorization and the person is signed in without one.
    public func cancel() {
        switch phase {
        case .approvingGuest:
            finishSignIn()
        case .exchanging:
            // The exchange in flight finishes either way; only the guest's authorization is dropped.
            if !exchangingGuest {
                guestDeclined = true
                tearDownGuest()
            }
        case .waiting:
            reset()
            phase = .idle
        case .idle, .signedIn, .failed:
            reset()
        }
    }

    public func signOut() {
        try? store.clear()
        try? guestStore?.clear()
        reset()
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
            guard let guestStore else { phase = .signedIn; return }
            // A long-lived token from an earlier login is not this login's.
            try guestStore.clear()
        } catch ClaudeOAuth.Error.stateMismatch {
            fail("The sign-in didn't match this attempt. Try again."); return
        } catch ClaudeOAuth.Error.invalidCode {
            fail("Claude didn't accept that code. Try again."); return
        } catch {
            fail("Sign-in failed: \(error)"); return
        }
        if guestDeclined { finishSignIn(); return }
        if guestAttempt == nil { prepareGuest() }
        guard let guestAttempt else { finishSignIn(); return }
        if let early = guestCode {
            guestCode = nil
            phase = .approvingGuest(opening: nil, pasteHint: false)
            await exchangeGuest(code: early.code, state: early.state)
            return
        }
        phase = .approvingGuest(opening: chained ? nil : guestAttempt.authorizeURL,
                                pasteHint: guestAttempt.redirect == .manual)
    }

    /// The guest's authorization, ready before the browser needs it: its own attempt, and a
    /// listener of its own when one binds (the hosted paste page when not).
    private func prepareGuest() {
        let redirect: ClaudeOAuth.Redirect
        if let listener = makeListener() {
            guestLoopback = listener
            redirect = .loopback(port: listener.port)
            Task { [weak self] in
                guard let url = try? await listener.wait(), let parsed = ClaudeOAuth.parseCallback(url) else { return }
                await self?.guestCalledBack(code: parsed.code, state: parsed.state)
            }
        } else {
            redirect = .manual
        }
        guestAttempt = oauth.begin(redirect: redirect, grant: .longLived)
    }

    private func guestCalledBack(code: String, state: String?) async {
        guard guestAttempt != nil else { return }
        if case .approvingGuest = phase {
            await exchangeGuest(code: code, state: state)
        } else {
            // The ordinary exchange has not landed yet; it takes this code up when it does.
            guestCode = (code, state)
        }
    }

    /// Exchanges the guest's code and keeps only its access token. Any failure is the fallback:
    /// signed in, no guest token kept.
    private func exchangeGuest(code: String, state: String?) async {
        guard let guestAttempt, let guestStore else { finishSignIn(); return }
        phase = .exchanging
        exchangingGuest = true
        if var minted = try? await oauth.exchange(code: code, state: state, attempt: guestAttempt),
           self.guestAttempt == guestAttempt {
            minted.refreshToken = ""
            try? guestStore.save(minted)
        }
        // A sign-out or a new start during the exchange owns the phase now.
        guard self.guestAttempt == guestAttempt else { return }
        finishSignIn()
    }

    private func finishSignIn() {
        tearDownGuest()
        guestDeclined = false
        exchangingGuest = false
        phase = .signedIn
    }

    private func tearDownGuest() {
        guestLoopback?.cancel()
        guestLoopback = nil
        guestAttempt = nil
        guestCode = nil
        chained = false
    }

    private func reset() {
        loopback?.cancel()
        loopback = nil
        attempt = nil
        tearDownGuest()
        guestDeclined = false
        exchangingGuest = false
    }

    private func fail(_ message: String) {
        reset()
        phase = .failed(message)
    }
}
