import Foundation
import Observation
import TopoAuth
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

    private(set) var github: GitHub

    /// Where the person revokes Topo's authorization, which a disconnect does not: GitHub's list
    /// of the OAuth apps they have authorized.
    static let githubAuthorizations = URL(string: "https://github.com/settings/applications")!

    let store: ConnectionStore
    private let flow: GitHubConnecting
    /// Puts the code on the pasteboard, which is a write and asks nothing of the person.
    private let copy: @MainActor (String) -> Void
    /// The in-app browser: the system's web-authentication sheet (`WebAuth`), which is Safari,
    /// so Password AutoFill fills a login there and a GitHub session already in Safari is used.
    private let browser: Browser
    /// A `forget()` the keychain refused, kept across launches, so no later login is handed what
    /// an earlier one connected.
    let leftBehind: ConnectionsLeftBehind
    private var generation = 0
    private var task: Task<Void, Never>?

    init(store: ConnectionStore = KeychainConnectionStore(), flow: GitHubConnecting = GitHubDeviceFlow(),
         copy: @escaping @MainActor (String) -> Void = { UIPasteboard.general.string = $0 },
         browser: Browser = WebAuthBrowser(), leftBehind: ConnectionsLeftBehind = ConnectionsLeftBehind()) {
        self.store = store
        self.flow = flow
        self.copy = copy
        self.browser = browser
        self.leftBehind = leftBehind
        github = Self.standing(store)
        // A clear refused before, at a sign-out, a takeover or a demotion: tried again at each
        // launch, since until it succeeds the tokens there are a login's that is gone.
        if leftBehind.words != nil { forget() }
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

    /// Every connection forgotten, for a sign-out, a demotion or a takeover: the generation moves
    /// first, so nothing in flight can save behind the clear. A keychain that refuses the clear is
    /// said on the row rather than shown as disconnected.
    func forget() {
        supersede()
        browser.close()
        do {
            try store.clearAll()
            github = .disconnected
            unforgotten = nil
            leftBehind.words = nil
        } catch {
            let words = "the GitHub token could not be removed from this phone's keychain: \(error)"
            github = .failed(Self.sentence(words))
            unforgotten = words
            leftBehind.words = words
        }
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

/// A `forget()` the keychain refused: its words, kept in the app's defaults until a clear of every
/// connection succeeds, so the tools hand out nothing a login that is gone connected — whoever
/// signs in next — and each launch tries the clear again.
final class ConnectionsLeftBehind: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "zone.hexagon.topo.connections.left-behind"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var words: String? {
        get { defaults.string(forKey: key) }
        set { defaults.set(newValue, forKey: key) }
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
