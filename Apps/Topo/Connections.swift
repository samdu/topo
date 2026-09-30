import Foundation
import Observation
import TopoAuth
import TopoTools
import UIKit

/// What connecting GitHub asks of GitHub, so a test can stand in for it.
protocol GitHubConnecting: Sendable {
    func start() async throws -> GitHubDeviceFlow.Code
    func token(for code: GitHubDeviceFlow.Code) async throws -> String
    func login(token: String) async throws -> String
}

extension GitHubDeviceFlow: GitHubConnecting {}

/// The services Topo is connected to on the person's behalf, and the one flow in flight. The
/// tokens are in `ConnectionStore` (the device keychain), which the tool service reads per call, so
/// the guest never keeps one; this is the screen's side of it.
///
/// Every flow runs under a generation. Cancel, Disconnect, a second Connect and `forget()` move it,
/// and a flow checks it after each thing it waits on and just before it saves, so a flow the person
/// has walked away from, or one still running when the login goes, saves nothing.
@Observable @MainActor
final class Connections {
    enum GitHub: Equatable {
        case disconnected
        /// Asking GitHub for a code.
        case starting
        /// The code is shown and GitHub is being polled.
        case waiting(GitHubDeviceFlow.Code)
        /// Asking GitHub who approved it, then saving.
        case finishing
        case connected(login: String)
        case failed(String)
    }

    enum OnePassword: Equatable {
        case disconnected
        /// A pasted token being checked with `op vault list` in the guest.
        case verifying
        case connected(vaults: String)
        case failed(String)
    }

    private(set) var github: GitHub
    private(set) var onePassword: OnePassword

    /// Where the person revokes Topo's authorization, which a disconnect does not: GitHub's list
    /// of the OAuth apps they have authorized.
    static let githubAuthorizations = URL(string: "https://github.com/settings/applications")!
    /// Where a person makes a service account for the vault they choose.
    static let onePasswordServiceAccounts = URL(string: "https://my.1password.com/developer-tools/infrastructure-secrets/serviceaccount")!

    let store: ConnectionStore
    private let flow: GitHubConnecting
    private let op: OnePasswordRunning
    /// The pasteboard a token was pasted from, cleared once the token is saved.
    private let pasteboard: Pasteboard
    /// Puts the code on the pasteboard, which is a write and asks nothing of the person.
    private let copy: @MainActor (String) -> Void
    /// The in-app browser: the system's web-authentication sheet (`WebAuth`), which is Safari,
    /// so Password AutoFill fills a login there and a GitHub session already in Safari is used.
    private let browser: Browser
    /// A `forget()` the keychain refused, kept across launches, so no later login is handed what
    /// an earlier one connected.
    let leftBehind: ConnectionsLeftBehind
    /// The `topo secret` requests in flight, which a clear of the 1Password token ends.
    let secrets: SecretRequests
    /// Clears the credentials the controls' requests name (`topo control secret`), which go with
    /// the connections' tokens.
    private let clearControlSecrets: @Sendable () throws -> Void
    private var generation = 0
    private var task: Task<Void, Never>?
    private var onePasswordGeneration = 0
    private var onePasswordTask: Task<Void, Never>?

    init(store: ConnectionStore = KeychainConnectionStore(), flow: GitHubConnecting = GitHubDeviceFlow(),
         onePassword: OnePasswordRunning = GuestOnePassword(), pasteboard: Pasteboard = SystemPasteboard(),
         copy: @escaping @MainActor (String) -> Void = { UIPasteboard.general.string = $0 },
         browser: Browser = WebAuthBrowser(), leftBehind: ConnectionsLeftBehind = ConnectionsLeftBehind(),
         secrets: SecretRequests = SecretRequests(),
         clearControlSecrets: @escaping @Sendable () throws -> Void = { try ControlSecrets().clearAll() }) {
        self.store = store
        self.flow = flow
        self.op = onePassword
        self.pasteboard = pasteboard
        self.copy = copy
        self.browser = browser
        self.leftBehind = leftBehind
        self.secrets = secrets
        self.clearControlSecrets = clearControlSecrets
        github = Self.standing(store)
        self.onePassword = Self.standingOnePassword(store)
        // A clear refused before, at a sign-out, a takeover or a demotion, is tried again at each
        // launch, since until it succeeds the tokens there are a login's that is gone. So is the
        // first launch of an install: the keychain outlives an uninstall and the app's defaults do
        // not, so a token found then is an earlier install's, and whose login it was is unknown.
        // Each clear is tried again alone, so a refusal of one never takes what a later login put
        // in the other.
        if leftBehind.words != nil || !leftBehind.installed { forgetConnections() }
        if leftBehind.controlSecrets != nil || !leftBehind.installed { forgetControlSecrets() }
        sayUnforgotten()
        leftBehind.installed = true
    }

    /// What the keychain holds for GitHub: connected, not, or unreadable — which is said, never
    /// taken for not connected.
    private static func standing(_ store: ConnectionStore) -> GitHub {
        do {
            return try store.load(.github).map { .connected(login: $0.account) } ?? .disconnected
        } catch {
            return .failed("The GitHub connection could not be read from this phone's keychain: \(error)")
        }
    }

    /// The same for 1Password.
    private static func standingOnePassword(_ store: ConnectionStore) -> OnePassword {
        do {
            return try store.load(.onePassword).map { .connected(vaults: $0.account) } ?? .disconnected
        } catch {
            return .failed("The 1Password connection could not be read from this phone's keychain: \(error)")
        }
    }

    /// Takes a pasted service-account token, checks it with `op vault list` in the guest, and
    /// saves it with the vaults it reaches only when that answers with at least one. The text must
    /// be one `ops_` token and nothing else (`isServiceAccountToken`).
    func connectOnePassword(pasted: String) {
        if leftBehind.words != nil { forget() }
        if let words = leftBehind.words {
            onePassword = .failed(Self.sentence(words))
            return
        }
        let token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = supersedeOnePassword()
        guard Self.isServiceAccountToken(token) else {
            onePassword = .failed("That is not a 1Password service-account token, which is ops_ and then only letters, digits and underscores. Copy the token 1Password showed when the service account was made.")
            return
        }
        onePassword = .verifying
        let pasted = pasteboard.changeCount
        onePasswordTask = Task { [op, store, pasteboard] in
            do {
                let exit = try await op.run(OnePasswordVaults.arguments, token: token)
                guard generation == self.onePasswordGeneration else { return }
                guard exit.status == 0, let vaults = OnePasswordVaults.read(exit.output) else {
                    onePassword = .failed("1Password refused the token: \(exit.said.isEmpty ? "status \(exit.status)" : exit.said)")
                    return
                }
                guard !vaults.isEmpty else {
                    onePassword = .failed("The service account reaches no vault. Give it one in 1Password and paste the token again.")
                    return
                }
                let names = vaults.map(\.name).joined(separator: ", ")
                try store.save(Connection(token: token, account: names), for: .onePassword)
                onePassword = .connected(vaults: names)
                // The token was on the pasteboard, where any app the person opens next can read
                // it; it goes once it is kept, unless something else has been copied since.
                if pasteboard.changeCount == pasted { pasteboard.clear() }
            } catch {
                guard generation == self.onePasswordGeneration else { return }
                onePassword = .failed("The token could not be checked: \(error)")
            }
        }
    }

    /// `ops_` and then only `[A-Za-z0-9_]`, the alphabet 1Password's service-account tokens are
    /// written in, under 8 KiB.
    static func isServiceAccountToken(_ text: String) -> Bool {
        text.hasPrefix("ops_") && text.utf8.count > 4 && text.utf8.count < 8192
            && text.utf8.dropFirst(4).allSatisfy { byte in
                (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                    || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_")
            }
    }

    /// Stops a check in flight; what was connected before stays.
    func cancelOnePassword() {
        supersedeOnePassword()
        onePassword = Self.standingOnePassword(store)
    }

    /// Forgets the service-account token on this phone.
    func disconnectOnePassword() {
        if leftBehind.words != nil { return forget() }
        supersedeOnePassword()
        secrets.clearing {
            do {
                try store.clear(.onePassword)
                onePassword = .disconnected
            } catch {
                onePassword = .failed("The token could not be removed from this phone's keychain: \(error)")
            }
        }
    }

    @discardableResult
    private func supersedeOnePassword() -> Int {
        onePasswordGeneration += 1
        onePasswordTask?.cancel()
        onePasswordTask = nil
        return onePasswordGeneration
    }

    /// Starts connecting GitHub: a code from GitHub, copied and shown, and GitHub's page for it
    /// opened in the in-app browser; then the poll, the login and the save.
    func connectGitHub() {
        if leftBehind.words != nil { forget() }
        if let words = leftBehind.words {
            github = .failed(Self.sentence(words))
            return
        }
        let generation = supersede()
        github = .starting
        task = Task { [flow, store] in
            do {
                let code = try await flow.start()
                guard generation == self.generation else { return }
                github = .waiting(code)
                copy(code.userCode)
                browser.open(code.verificationURL)
                let token = try await flow.token(for: code)
                guard generation == self.generation else { return }
                github = .finishing
                let login = try await flow.login(token: token)
                guard generation == self.generation else { return }
                try store.save(Connection(token: token, account: login), for: .github)
                github = .connected(login: login)
                browser.close()
            } catch {
                guard generation == self.generation else { return }
                github = .failed(Self.describe(error))
            }
        }
    }

    /// GitHub's page for the code shown, again: the person closed the sheet before approving.
    func reopenGitHub() {
        if case let .waiting(code) = github { browser.open(code.verificationURL) }
    }

    /// Opens a page in the in-app browser: where the authorization is revoked.
    func open(_ url: URL) {
        browser.open(url)
    }

    /// Stops a connect in flight; what was connected before stays.
    func cancelGitHub() {
        supersede()
        browser.close()
        github = Self.standing(store)
    }

    /// Forgets the GitHub token on this phone; with a clear refused before, every connection.
    func disconnectGitHub() {
        if leftBehind.words != nil { return forget() }
        supersede()
        do {
            try store.clear(.github)
            github = .disconnected
        } catch {
            github = .failed("The token could not be removed from this phone's keychain: \(error)")
        }
    }

    /// Every connection forgotten, and every control secret, for a sign-out, a demotion or a
    /// takeover: the generation moves first, so nothing in flight can save behind the clear. A
    /// keychain that refuses the clear is said on the row rather than shown as disconnected, and
    /// either refusal is said on the sign-in screen (`unforgotten`).
    func forget() {
        forgetConnections()
        forgetControlSecrets()
        sayUnforgotten()
    }

    private func forgetConnections() {
        supersede()
        supersedeOnePassword()
        browser.close()
        secrets.clearing {
            do {
                try store.clearAll()
                github = .disconnected
                onePassword = .disconnected
                leftBehind.words = nil
            } catch {
                let words = "the connections' tokens could not be removed from this phone's keychain: \(error)"
                github = .failed(Self.sentence(words))
                onePassword = .failed(Self.sentence(words))
                leftBehind.words = words
            }
        }
    }

    private func forgetControlSecrets() {
        do {
            try clearControlSecrets()
            leftBehind.controlSecrets = nil
        } catch {
            leftBehind.controlSecrets = "the controls' secrets could not be removed from this phone's keychain: \(error)"
        }
    }

    private func sayUnforgotten() {
        let left = [leftBehind.words, leftBehind.controlSecrets].compactMap { $0 }
        unforgotten = left.isEmpty ? nil : left.joined(separator: "; and ")
    }

    private static func sentence(_ words: String) -> String {
        words.prefix(1).uppercased() + words.dropFirst()
    }

    /// What the last `forget()` could not remove, in words the sign-in screen can say after a
    /// sign-out; nil when it removed everything.
    private(set) var unforgotten: String?

    /// Ends the flow in flight, if any, and answers the generation the next one runs under.
    @discardableResult
    private func supersede() -> Int {
        generation += 1
        task?.cancel()
        task = nil
        return generation
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? GitHubDeviceFlow.Failure { return failure.description }
        if let url = error as? URLError { return "GitHub could not be reached: \(url.localizedDescription)" }
        return "\(error)"
    }
}

/// The pasteboard as `Connections` needs it: whether it changed, and emptying it. Neither reads
/// its contents, so neither puts up the paste prompt.
@MainActor
protocol Pasteboard {
    var changeCount: Int { get }
    func clear()
}

struct SystemPasteboard: Pasteboard {
    var changeCount: Int { UIPasteboard.general.changeCount }
    func clear() { UIPasteboard.general.items = [] }
}

/// A `forget()` the keychain refused: its words, kept in the app's defaults until a clear of every
/// connection succeeds, so the tools hand out nothing a login that is gone connected — whoever
/// signs in next — and each launch tries the clear again; and whether this install has launched
/// before, since an uninstall takes the defaults and leaves the keychain.
/// The `topo secret` requests in flight, and the clears of the 1Password token they must not run
/// across. A request is let in, under one lock, only while no clear is running; a clear, under the
/// same lock, cancels every request in flight before it starts, and a request cancelled is never
/// answered with what it read. So a request either answers before a clear or answers nothing, and
/// one let in after a refused clear sees its words. A clear does not wait for a request: its
/// cancel ends `op` (`OnePasswordRun`), and a sign-out stays synchronous.
final class SecretRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var clearRunning = false
    private var running: [UUID: Task<ToolReply, Never>] = [:]

    static let stopped = ToolReply.failed("Stopped: 1Password was disconnected, or the app signed out, while this ran.\n")
    static let whileClearing = ToolReply.failed("1Password is being disconnected; ask again once it is.\n")

    /// Runs `body` as one request, unless a clear is running or `refusal` answers one, both read
    /// under the lock a clear takes.
    func run(refusal: () -> ToolReply?, _ body: @escaping @Sendable () async -> ToolReply) async -> ToolReply {
        let id = UUID()
        let started = lock.withLock { () -> Result<Task<ToolReply, Never>, Refusal> in
            if clearRunning { return .failure(Refusal(reply: Self.whileClearing)) }
            if let reply = refusal() { return .failure(Refusal(reply: reply)) }
            let task = Task { await body() }
            running[id] = task
            return .success(task)
        }
        let task: Task<ToolReply, Never>
        switch started {
        case .failure(let refusal): return refusal.reply
        case .success(let running): task = running
        }
        let reply = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return lock.withLock {
            running[id] = nil
            return task.isCancelled ? Self.stopped : reply
        }
    }

    /// Runs a clear of the token: every request in flight cancelled first, none let in until it
    /// has finished.
    func clearing(_ clear: () -> Void) {
        lock.withLock {
            clearRunning = true
            running.values.forEach { $0.cancel() }
        }
        clear()
        lock.withLock { clearRunning = false }
    }

    private struct Refusal: Error { let reply: ToolReply }
}

final class ConnectionsLeftBehind: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "zone.hexagon.topo.connections.left-behind"
    private let installedKey = "zone.hexagon.topo.connections.installed"
    private let controlSecretsKey = "zone.hexagon.topo.control-secrets.left-behind"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var words: String? {
        get { defaults.string(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
    }

    /// The same for the control secrets (`ControlSecrets`), kept apart so a refusal of theirs
    /// refuses the controls' secrets alone and not the connections.
    var controlSecrets: String? {
        get { defaults.string(forKey: controlSecretsKey) }
        set { defaults.set(newValue, forKey: controlSecretsKey) }
    }

    /// Whether this install has launched before: false on the first launch after an install,
    /// when the keychain may still hold an earlier install's tokens.
    var installed: Bool {
        get { defaults.bool(forKey: installedKey) }
        set { defaults.set(newValue, forKey: installedKey) }
    }
}

/// The in-app browser, as `Connections` uses it.
@MainActor
protocol Browser {
    func open(_ url: URL)
    func close()
}

/// `WebAuth`, the sheet the Claude sign-in opens, with no callback: the flows here end by the app
/// closing it (the device flow once GitHub has answered) or by the person.
@MainActor
final class WebAuthBrowser: Browser {
    private let web = WebAuth()

    init() {}

    func open(_ url: URL) {
        web.open(url) {}
    }

    func close() {
        web.close()
    }
}

#if DEBUG
extension DebugRun {
    static let connectGitHubVariable = "TOPO_DEBUG_CONNECT_GITHUB"
    static let onePasswordTokenVariable = "TOPO_DEBUG_ONEPASSWORD_TOKEN"

    /// `TOPO_DEBUG_ONEPASSWORD_TOKEN=<ops_…>`: connects 1Password at launch as a paste does — the
    /// token checked with `op vault list` in the guest and saved with the vaults it reaches — and
    /// prints each state the row takes (the vaults' names or 1Password's refusal, never the token),
    /// so a simulator run can then call `topo secret` against a real vault. The token arrives as
    /// the launch's environment and nowhere else, as the setup token does.
    @MainActor static func connectOnePassword(_ connections: Connections,
                                              environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard let token = environment[onePasswordTokenVariable], !token.isEmpty else { return }
        connections.connectOnePassword(pasted: token)
        var said = ""
        while !Task.isCancelled {
            let now = "\(connections.onePassword)".replacingOccurrences(of: token, with: "[token]")
            if now != said { print("[topo-debug] 1password: \(now)"); said = now }
            if case .verifying = connections.onePassword {} else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    /// `TOPO_DEBUG_CONNECT_GITHUB=1`: connects GitHub at launch as the screen's Connect does — a
    /// real code from github.com, copied, and GitHub's page for it in the sheet — printing each
    /// state the connection takes (never a token or the device code), so a simulator shows the
    /// flow against GitHub itself. Approving it is a person's; with nobody there the code expires.
    @MainActor static func connectGitHub(_ connections: Connections,
                                         environment: [String: String] = ProcessInfo.processInfo.environment) async {
        guard environment[connectGitHubVariable] == "1" else { return }
        // The sheet anchors on the key window, which the first frame makes.
        while !UIApplication.shared.connectedScenes.contains(where: { ($0 as? UIWindowScene)?.keyWindow != nil }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        connections.connectGitHub()
        var said = ""
        while !Task.isCancelled {
            let now = switch connections.github {
            // The code the person types and where; never the device code, which polls for the token.
            case let .waiting(code): "waiting for \(code.userCode) at \(code.verificationURL.absoluteString)"
            case let state: "\(state)"
            }
            if now != said { print("[topo-debug] github: \(now)"); said = now }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }
}
#endif
