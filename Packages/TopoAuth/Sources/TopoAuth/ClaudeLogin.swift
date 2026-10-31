import Foundation

/// Claude Code's own login, wherever its `claude` runs: `claude auth login --claudeai`, `claude
/// auth status --json` and `claude auth logout`. The OAuth client, the redirect, the code exchange
/// and the stored credential are all Claude Code's; what drives it (`SignIn`) opens the URLs it
/// hands out, carries a pasted `code#state` to it, and keeps nothing.
public protocol ClaudeLogin: Sendable {
    /// Returns once a login can run, telling `progress` what it waits on meanwhile.
    func prepare(progress: @escaping @Sendable (String) -> Void) async throws
    /// Starts `claude auth login`. `heard` is told what it says, from its browser URL to its end,
    /// on whatever thread it says it.
    func begin(_ heard: @escaping @Sendable (LoginEvent) -> Void) async throws -> any LoginAttempt
    /// What `claude auth status --json` says.
    func status() async throws -> ClaudeLoginStatus
    /// `claude auth logout`, and the credential gone whether or not it could run. True when the
    /// credential is gone.
    func logout() async -> Bool
    /// Removes the credential where it rests, at once, with nothing run: the start of a launch
    /// that finds a sign-out owed.
    func discardCredential()
}

/// One running `claude auth login`.
public protocol LoginAttempt: Sendable {
    /// Writes what the paste page showed to the login's stdin.
    func paste(_ code: String) async throws
    /// Ends the process, which says nothing more after.
    func end() async
}

/// What a running login says.
public enum LoginEvent: Equatable, Sendable {
    /// The URL it asked its browser to open: the loopback variant, whose redirect comes back to
    /// its own listener.
    case browser(URL)
    /// The URL it printed: the paste-page variant, for when the loopback cannot be reached.
    case pastePage(URL)
    /// It exited.
    case ended(LoginEnd)
}

public enum LoginEnd: Equatable, Sendable {
    /// Exit 0: the credential is written.
    case succeeded
    /// `Login failed: …`, or another exit 1, with what it said.
    case failed(String)
    /// Ended from outside, or gone without saying.
    case stopped
}

/// `claude auth status --json`, the fields read of it.
public struct ClaudeLoginStatus: Codable, Equatable, Sendable {
    public var loggedIn: Bool
    public var authMethod: String?
    public var subscriptionType: String?

    public init(loggedIn: Bool, authMethod: String? = nil, subscriptionType: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.subscriptionType = subscriptionType
    }

    /// Signed in with a Claude.ai login, which is what loads the person's connectors.
    public var isClaudeAI: Bool { loggedIn && authMethod == "claude.ai" }

    /// The status in `output`: the JSON object it prints, read from its first brace to its last,
    /// so a line of anything else around it is not the status. Nil when there is none.
    public static func parse(_ output: String) -> ClaudeLoginStatus? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}"), start < end else { return nil }
        return try? JSONDecoder().decode(ClaudeLoginStatus.self, from: Data(output[start...end].utf8))
    }

    /// The diagnostics row: the method and the subscription, never a token.
    public var summary: String {
        guard loggedIn else { return "signed out" }
        return [authMethod, subscriptionType].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Whether this device is signed in, kept for the callers that ask before any guest is up (the
/// role at launch, the memory, the sign-in screen's first frame). It holds the fact and the
/// subscription, no token, and is refreshed from `auth status` at every guest boot and after a
/// login or a logout.
public struct LoginCache: @unchecked Sendable {
    public let defaults: UserDefaults
    public static let key = "zone.hexagon.topo.claude-login"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static var standard: LoginCache { LoginCache() }

    public var status: ClaudeLoginStatus? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(ClaudeLoginStatus.self, from: $0) }
    }

    public var isSignedIn: Bool { status?.loggedIn == true }

    public func save(_ status: ClaudeLoginStatus) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        defaults.set(data, forKey: Self.key)
    }

    public func clear() { defaults.removeObject(forKey: Self.key) }
}

/// The two keychain items a build before Claude Code's own login kept the Claude.ai tokens in.
/// The first launch of this one deletes both and asks for one more sign-in, which is the
/// migration: nothing is carried from them into Claude Code.
public enum LoginMigration {
    public static let items = [KeychainItem(service: "zone.hexagon.topo.claude", account: "claude"),
                               KeychainItem(service: "zone.hexagon.topo.claude", account: "claude-guest")]
    public static let signInAgainKey = "zone.hexagon.topo.sign-in-again"

    /// Deletes the items there are, and answers whether there were any, which is a phone that was
    /// signed in under the old login: the sign-in screen then says why it is asking again, until
    /// the next sign-in.
    @discardableResult
    public static func run(items: [KeychainItem] = items, defaults: UserDefaults = .standard) -> Bool {
        var found = false
        for item in items where (try? item.read()) != nil {
            found = true
            try? item.delete()
        }
        if found { defaults.set(true, forKey: signInAgainKey) }
        return found
    }
}
