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

    /// Where Topo's GitHub App is installed on repositories: a user token reaches only those.
    static let githubInstall = URL(string: "https://github.com/apps/\(githubAppSlug)/installations/new")!
    static let githubAppSlug = "topo-hexagon-zone"

    let store: ConnectionStore
    private let flow: GitHubConnecting
    /// Puts the code on the pasteboard, which is a write and asks nothing of the person.
    private let copy: @MainActor (String) -> Void
    /// The in-app browser: the system's web-authentication sheet (`WebAuth`), which is Safari,
    /// so Password AutoFill fills a login there and a GitHub session already in Safari is used.
    private let browser: Browser
    private var generation = 0
    private var task: Task<Void, Never>?

    init(store: ConnectionStore = KeychainConnectionStore(), flow: GitHubConnecting = GitHubDeviceFlow(),
         copy: @escaping @MainActor (String) -> Void = { UIPasteboard.general.string = $0 },
         browser: Browser = WebAuthBrowser()) {
        self.store = store
        self.flow = flow
        self.copy = copy
        self.browser = browser
        github = (try? store.load(.github)).flatMap { $0 }.map { .connected(login: $0.account) } ?? .disconnected
    }

    /// Starts connecting GitHub: a code from GitHub, copied and shown, and GitHub's page for it
    /// opened in the in-app browser; then the poll, the login and the save.
    func connectGitHub() {
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

    /// Opens a page in the in-app browser: where the App is installed, where a token is revoked.
    func open(_ url: URL) {
        browser.open(url)
    }

    /// Stops a connect in flight; what was connected before stays.
    func cancelGitHub() {
        supersede()
        browser.close()
        github = (try? store.load(.github)).flatMap { $0 }.map { .connected(login: $0.account) } ?? .disconnected
    }

    /// Forgets the GitHub token on this phone.
    func disconnectGitHub() {
        supersede()
        do {
            try store.clear(.github)
            github = .disconnected
        } catch {
            github = .failed("The token could not be removed from this phone's keychain: \(error)")
        }
    }

    /// Every connection forgotten, for a sign-out or a demotion: the generation moves first, so
    /// nothing in flight can save behind the clear.
    func forget() {
        supersede()
        try? store.clearAll()
        github = .disconnected
        browser.close()
    }

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
