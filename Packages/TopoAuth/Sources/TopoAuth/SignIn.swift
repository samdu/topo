import Foundation
import Observation

/// Drives Claude Code's own login from a button press to `auth status` saying `claude.ai`. The
/// view supplies the browser (a web-authentication sheet, opened at `sheet`); `login` is the
/// `claude` the login runs in.
///
/// One login process serves two URLs at once: the loopback one it hands its `BROWSER`, which the
/// sheet opens first, and the paste-page one it prints. When the loopback cannot be reached the
/// browser stops on a connection error, so *Open the page again* opens the paste page, whose
/// `code#state` the person pastes and this writes to the login's stdin. The person closing the
/// loopback's sheet ends the login; closing the paste page's does not, since copying the code and
/// closing it is how the code reaches the field.
@MainActor
@Observable
public final class SignIn {
    public enum Phase: Equatable {
        /// Waiting for what the login runs in, with what it waits on.
        case preparing(String)
        /// Ready to sign in.
        case idle
        /// A login is running.
        case approving(Approval)
        case signedIn
        case failed(String)
    }

    public struct Approval: Equatable, Sendable {
        /// The paste-page URL the login printed, nil until it has.
        public var page: URL?
        /// Whether the paste page has been opened, so the field for its code is shown.
        public var pasting: Bool

        public init(page: URL?, pasting: Bool) {
            self.page = page
            self.pasting = pasting
        }
    }

    /// The sheet the view keeps open: nil for none. A new value is a new sheet.
    public struct Sheet: Equatable, Sendable {
        public enum Kind: Sendable { case approve, page }
        public let url: URL
        public let kind: Kind
        let id = UUID()
    }

    public private(set) var phase: Phase
    public private(set) var sheet: Sheet?
    /// A phone signed in under the login before Claude Code's own: the sign-in screen says why it
    /// asks again, until the next sign-in.
    public private(set) var signInAgain: Bool

    private let login: any ClaudeLogin
    private let cache: LoginCache
    private var attempt: (any LoginAttempt)?
    /// Counts attempts, sign-outs and cancels: what an older one hears afterwards reaches nothing.
    private var generation = 0
    /// The generation whose login has exited, so an attempt that lands after its own end is not kept.
    private var exited = -1
    /// Logouts in order, so a sign-in after a sign-out never runs beside its logout.
    private var logout: Task<Void, Never>?

    /// `accept` says what counts as signed in; a debug build launched with a developer's token
    /// takes that token's `oauth_token` too.
    private let accept: @Sendable (ClaudeLoginStatus) -> Bool

    public init(login: any ClaudeLogin, cache: LoginCache = .standard, signInAgain: Bool = false,
                accept: @escaping @Sendable (ClaudeLoginStatus) -> Bool = { $0.isClaudeAI }) {
        self.login = login
        self.cache = cache
        self.accept = accept
        self.signInAgain = signInAgain
        phase = cache.isSignedIn ? .signedIn : .preparing("")
    }

    /// Waits for what the login runs in, saying what it waits on; then the screen offers the
    /// sign-in. Signed in already, it asks nothing.
    public func prepare() async {
        guard case .preparing = phase else { return }
        let generation = generation
        do {
            try await login.prepare { [weak self] line in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == generation, case .preparing = self.phase else { return }
                    self.phase = .preparing(line)
                }
            }
            guard self.generation == generation, case .preparing = phase else { return }
            phase = .idle
        } catch {
            guard self.generation == generation, case .preparing = phase else { return }
            phase = .failed("Topo could not get ready: \(error)")
        }
    }

    /// Asks `auth status` again, at a guest's boot: a login that has gone (a logout, an expired
    /// refresh) puts the screen back on the sign-in. A status that could not be read changes
    /// nothing, nor one read across a sign-in or a sign-out that began since.
    public func refresh() async {
        await logout?.value
        let generation = generation
        guard let status = try? await login.status(), self.generation == generation else { return }
        if case .approving = phase { return }
        if accept(status) {
            cache.save(status)
            phase = .signedIn
        } else if phase == .signedIn {
            cache.clear()
            phase = .idle
        }
    }

    /// Starts a login. The sheet opens once it has asked for its browser.
    public func start() {
        switch phase {
        case .idle, .failed: break
        case .preparing, .approving, .signedIn: return
        }
        generation += 1
        let generation = generation
        phase = .approving(Approval(page: nil, pasting: false))
        sheet = nil
        let logout = logout
        let heard: @Sendable (LoginEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in self?.heard(event, in: generation) }
        }
        Task { [weak self, login] in
            await logout?.value
            do {
                let attempt = try await login.begin(heard)
                guard let self, self.generation == generation, self.exited != generation else { await attempt.end(); return }
                self.attempt = attempt
            } catch {
                guard let self, self.generation == generation else { return }
                self.phase = .failed("Claude Code's sign-in did not start: \(error)")
            }
        }
    }

    private func heard(_ event: LoginEvent, in generation: Int) {
        guard self.generation == generation, case .approving(var approval) = phase else { return }
        switch event {
        case .browser(let url):
            sheet = Sheet(url: url, kind: .approve)
        case .pastePage(let url):
            approval.page = url
            phase = .approving(approval)
        case .ended(let end):
            exited = generation
            attempt = nil
            sheet = nil
            switch end {
            case .succeeded: Task { await self.signedIn(in: generation) }
            case .failed(let message): phase = .failed(message)
            case .stopped: phase = .failed("The sign-in stopped. Try again.")
            }
        }
    }

    private func signedIn(in generation: Int) async {
        let status = try? await login.status()
        guard self.generation == generation else { return }
        guard let status, accept(status) else {
            phase = .failed("Claude Code finished the sign-in but does not say it is signed in with Claude.")
            return
        }
        cache.save(status)
        signInAgain = false
        cache.defaults.removeObject(forKey: LoginMigration.signInAgainKey)
        phase = .signedIn
    }

    /// *Open the page again*: the running login's paste page, whose code goes in the field. With
    /// no login running any more, a fresh one.
    public func openPageAgain() {
        guard case .approving(var approval) = phase else { start(); return }
        guard let page = approval.page else { return }
        approval.pasting = true
        phase = .approving(approval)
        sheet = Sheet(url: page, kind: .page)
    }

    /// The person pasted what the page showed.
    public func paste(_ text: String) async {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .approving = phase, let attempt else { return }
        guard !code.isEmpty else { return }
        do {
            try await attempt.paste(code)
        } catch {
            guard case .approving = phase else { return }
            phase = .failed("The code did not reach Claude Code: \(error)")
        }
    }

    /// The person closed `closed`: the loopback's sheet ends the login, the paste page's does not.
    public func sheetClosed(_ closed: Sheet) {
        guard sheet == closed else { return }
        sheet = nil
        if closed.kind == .approve { cancel() }
    }

    /// Cancel: the login is ended and the screen offers the sign-in again.
    public func cancel() {
        guard case .approving = phase else { return }
        endAttempt()
        phase = .idle
    }

    /// Lets go of the login: nothing counts as signed in from this call, and Claude Code's own
    /// logout runs after. `unfinished` is what the rest of the sign-out could not do (a
    /// connection's token the keychain would not remove), which the sign-in screen then says.
    public func signOut(unfinished: String? = nil) {
        cache.clear()
        endAttempt()
        let previous = logout
        logout = Task { [login] in
            await previous?.value
            await login.logout()
        }
        phase = unfinished.map { .failed("Signed out, but \($0)") } ?? .idle
    }

    /// Returns once every logout asked for has run.
    public func loggedOut() async {
        await logout?.value
    }

    private func endAttempt() {
        generation += 1
        sheet = nil
        if let attempt {
            self.attempt = nil
            Task { await attempt.end() }
        }
    }
}
