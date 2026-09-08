#if DEBUG
import Foundation
import TopoAuth

/// What a debug build takes from its launch environment, so a simulator can be signed in and made
/// to say something without anybody touching the screen. None of it exists in a release build: the
/// whole file is behind `#if DEBUG`, and the model every turn goes to is pinned to Haiku by
/// `ClaudeModel.pinned`, which is behind the same flag.
///
/// The token arrives as an environment variable and nowhere else — not a scheme, not a file, not a
/// build setting — because a variable lives only in the launching shell and the launched process.
/// `scripts/simulator-run.sh` reads it from the vault and hands it to `simctl` as
/// `SIMCTL_CHILD_TOPO_CLAUDE_SETUP_TOKEN`; nothing writes it down.
enum DebugRun {
    static let tokenVariable = "TOPO_CLAUDE_SETUP_TOKEN"
    static let lifetimeVariable = "TOPO_CLAUDE_SETUP_TOKEN_DAYS"
    static let sendVariable = "TOPO_DEBUG_SEND"

    /// Puts a long-lived Claude Code setup token in the store as if a sign-in had just finished, so
    /// the app comes up past the sign-in screen. Does nothing when the variable is absent, which is
    /// every ordinary debug build: an engineer's own sign-in is left exactly as it was.
    ///
    /// A setup token has no refresh token — it is minted for a year and cannot be exchanged — so it
    /// is written with a life short enough to be obviously wrong if it is still there next month and
    /// long enough that no run tries to refresh it. A refresh would fail loudly rather than quietly:
    /// the empty refresh token is rejected and the turn reports it.
    @discardableResult
    static func signIn(store: TokenStore = KeychainTokenStore(),
                       environment: [String: String] = ProcessInfo.processInfo.environment,
                       now: Date = Date()) -> Bool {
        let token = (environment[tokenVariable] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        let days = environment[lifetimeVariable].flatMap(Double.init) ?? 30
        let tokens = Tokens(accessToken: token,
                            refreshToken: "",
                            expiresAt: now.addingTimeInterval(days * 86_400),
                            scopes: ClaudeOAuth.Configuration.claude.scopes)
        do {
            try store.save(tokens)
            say("signed in from \(tokenVariable) for \(Int(days)) days")
            return true
        } catch {
            say("could not write the token to the keychain: \(error)")
            return false
        }
    }

    /// What `TOPO_DEBUG_SEND` asks to be said, or nil.
    static func words(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let text = (environment[sendVariable] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Every line this prints is prefixed, so a script watching `simctl launch --console` can find
    /// them among the system's own noise.
    static func say(_ line: String) { print("[topo-debug] \(line)") }
}

#if os(iOS)
import TopoCore
import TopoTurn

extension DebugRun {
    /// One turn, driven from the launch environment rather than the keyboard: the words go through
    /// the same harness the chat screen uses — the lease, the log, the Messages API — and what came
    /// back is printed. A script asserts on those lines; there is no other way to send a message to
    /// a simulator from a shell without an XCUITest target and a screenful of taps.
    @MainActor
    static func send(with harness: Harness) async {
        guard let text = words() else { return }
        say("model: \(ClaudeModel.effective(harness.model).rawValue) (setting: \(harness.model.rawValue))")
        say("sending: \(text)")
        await harness.send(text)
        await harness.refresh()
        if let error = harness.error {
            say("error: \(error)")
        }
        if let reply = harness.turns.last(where: { $0.role == .assistant }) {
            say("reply: \(reply.text.replacingOccurrences(of: "\n", with: " "))")
        }
        say("turns in the log: \(harness.turns.count)")
        say("done")
    }
}
#endif
#endif
