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

    enum OnePassword: Equatable {
        case disconnected
        /// A pasted token being checked with `op vault list` in the guest.
        case verifying
        case connected(vaults: String)
        case failed(String)
    }

    private(set) var github: GitHub
    private(set) var onePassword: OnePassword

    /// Where Topo's GitHub App is installed on repositories: a user token reaches only those.
    static let githubInstall = URL(string: "https://github.com/apps/\(githubAppSlug)/installations/new")!
    static let githubAppSlug = "topo-hexagon-zone"
    /// Where a person makes a service account for the vault they choose.
    static let onePasswordServiceAccounts = URL(string: "https://my.1password.com/developer-tools/infrastructure-secrets/serviceaccount")!

    let store: ConnectionStore
    private let flow: GitHubConnecting
    private let op: OnePasswordRunning
    /// Puts the code on the pasteboard, which is a write and asks nothing of the person.
    private let copy: @MainActor (String) -> Void
    /// The in-app browser: the system's web-authentication sheet (`WebAuth`), which is Safari,
    /// so Password AutoFill fills a login there and a GitHub session already in Safari is used.
    private let browser: Browser
    private var generation = 0
    private var task: Task<Void, Never>?
    private var onePasswordGeneration = 0
    private var onePasswordTask: Task<Void, Never>?

    init(store: ConnectionStore = KeychainConnectionStore(), flow: GitHubConnecting = GitHubDeviceFlow(),
         onePassword: OnePasswordRunning = GuestOnePassword(),
         copy: @escaping @MainActor (String) -> Void = { UIPasteboard.general.string = $0 },
         browser: Browser = WebAuthBrowser()) {
        self.store = store
        self.flow = flow
        self.op = onePassword
        self.copy = copy
        self.browser = browser
        github = (try? store.load(.github)).flatMap { $0 }.map { .connected(login: $0.account) } ?? .disconnected
        self.onePassword = (try? store.load(.onePassword)).flatMap { $0 }.map { .connected(vaults: $0.account) } ?? .disconnected
    }

    /// Takes a pasted service-account token, checks it with `op vault list` in the guest, and
    /// saves it with the vaults it reaches only when that answers with at least one. The text must
    /// be one `ops_` token and nothing else.
    func connectOnePassword(pasted: String) {
        let token = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = supersedeOnePassword()
        guard token.hasPrefix("ops_"), token.count > 4, token.count < 8192,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            onePassword = .failed("That is not a 1Password service-account token, which starts ops_. Copy the token 1Password showed when the service account was made.")
            return
        }
        onePassword = .verifying
        onePasswordTask = Task { [op, store] in
            do {
                let exit = try await op.run(OnePasswordVaults.arguments, token: token)
                guard generation == self.onePasswordGeneration else { return }
                guard exit.status == 0, let vaults = OnePasswordVaults.read(exit.output) else {
                    let said = exit.errors.trimmingCharacters(in: .whitespacesAndNewlines)
                    onePassword = .failed("1Password refused the token: \(said.isEmpty ? "status \(exit.status)" : said)")
                    return
                }
                guard !vaults.isEmpty else {
                    onePassword = .failed("The service account reaches no vault. Give it one in 1Password and paste the token again.")
                    return
                }
                let names = vaults.map(\.name).joined(separator: ", ")
                try store.save(Connection(token: token, account: names), for: .onePassword)
                onePassword = .connected(vaults: names)
            } catch {
                guard generation == self.onePasswordGeneration else { return }
                onePassword = .failed("The token could not be checked: \(error)")
            }
        }
    }

    /// Stops a check in flight; what was connected before stays.
    func cancelOnePassword() {
        supersedeOnePassword()
        onePassword = (try? store.load(.onePassword)).flatMap { $0 }.map { .connected(vaults: $0.account) } ?? .disconnected
    }

    /// Forgets the service-account token on this phone.
    func disconnectOnePassword() {
        supersedeOnePassword()
        do {
            try store.clear(.onePassword)
            onePassword = .disconnected
        } catch {
            onePassword = .failed("The token could not be removed from this phone's keychain: \(error)")
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
        supersedeOnePassword()
        try? store.clearAll()
        github = .disconnected
        onePassword = .disconnected
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
