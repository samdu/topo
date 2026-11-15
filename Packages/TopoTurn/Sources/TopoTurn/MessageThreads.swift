import Foundation

/// Whether the resident sends its turns on a message thread: the conversation held on Anthropic's
/// side between requests, so each request carries only the new messages rather than the whole
/// history. Claude Code turns its thread client on with one environment variable set to `1`; the
/// name is a value here, so the mind can follow a rename without an app update.
///
/// On, the conversation is kept on Anthropic's servers, encrypted in memory, for up to an hour
/// after its last request, with no way to delete it sooner, and outside zero data retention. It
/// is on unless the person or the mind turns it off. A name Claude Code no longer reads costs
/// nothing but the saving: the resident sends every request whole, as with it off, and only
/// `topo context threads`, from what the proxy saw, tells the two apart.
public enum MessageThreads {
    public struct Setting: Sendable, Equatable {
        public var on: Bool
        /// The variable the launch sets to `value` while on: always one `variable(_:)` takes.
        public var variable: String

        public init(on: Bool, variable: String) {
            self.on = on
            self.variable = MessageThreads.variable(variable) ?? MessageThreads.defaultVariable
        }

        public static let off = Setting(on: false, variable: MessageThreads.defaultVariable)
        /// What a device that has never been told otherwise runs with.
        public static let standard = Setting(on: true, variable: MessageThreads.defaultVariable)

        /// The setting as `defaults` keeps it: `standard` for what was never set, and a kept name
        /// `variable(_:)` does not take read as `defaultVariable`.
        public init(defaults: UserDefaults) {
            let on = defaults.object(forKey: MessageThreads.key) == nil ? true : defaults.bool(forKey: MessageThreads.key)
            self.init(on: on, variable: defaults.string(forKey: MessageThreads.variableKey) ?? MessageThreads.defaultVariable)
        }

        public func keep(in defaults: UserDefaults) {
            defaults.set(on, forKey: MessageThreads.key)
            defaults.set(variable, forKey: MessageThreads.variableKey)
        }

        /// The variable a launch sets, or nil while off.
        public var launched: String? { on ? variable : nil }
    }

    /// Claude Code's own name at its pin (2.1.316).
    public static let defaultVariable = "CLAUDE_CODE_TETHER_LIVE"
    /// The one value a launch gives it.
    public static let value = "1"

    /// Where the setting is kept on this device: on or off, and the name.
    public static let key = "messageThreads"
    public static let variableKey = "messageThreadsVariable"

    /// The longest name taken.
    public static let longest = 64

    /// The one reader of a name: `CLAUDE_CODE_` and then upper-case letters, digits and single
    /// underscores, at most `longest` long, with `TETHER`, `THREADS` or `MESSAGE_THREAD` in it (`meaningParts`), and
    /// none with a part that names a credential, a provider, a skip, a URL, a proxy, settings or
    /// the environment (`refusedParts`). `default` is `defaultVariable`. Anything else is no name. Claude Code reads
    /// some 800 `CLAUDE_CODE_` variables, any of which a launch's `1` would change, and a list of
    /// the ones that are safe cannot be written for a version not yet out; a rename of this one
    /// keeps what it is about, so the reader takes only names that say so, and a rename that does
    /// not is an app update.
    public static func variable(_ word: String) -> String? {
        let name = word.trimmingCharacters(in: .whitespaces)
        if name.lowercased() == "default" { return defaultVariable }
        guard name.count <= longest, name.wholeMatch(of: /CLAUDE_CODE_[A-Z0-9]+(_[A-Z0-9]+)*/) != nil,
              meaningParts.contains(where: name.contains) else { return nil }
        guard !refusedParts.contains(where: name.contains) else { return nil }
        return name
    }

    /// What a name has to be about: one of these is in every name `variable(_:)` takes.
    /// `THREAD` alone is not enough: the pin's other three names with it are about other threads
    /// (`AUTO_MODE_COMPACT_THREAD_RULE`, `AUTO_MODE_THREAD_ASK_HELD`, `HOOKS_SAME_THREAD`, the last
    /// of which moves the hooks, the SessionStart hook's included).
    public static let meaningParts = ["TETHER", "THREADS", "MESSAGE_THREAD"]

    /// Why `word` is no name, for the person or the mind to read.
    public static func refusal(_ word: String) -> String {
        let name = word.trimmingCharacters(in: .whitespaces)
        if name.count > longest { return "a name is at most \(longest) characters" }
        if name.wholeMatch(of: /CLAUDE_CODE_[A-Z0-9]+(_[A-Z0-9]+)*/) == nil {
            return "a name is CLAUDE_CODE_ then capitals, digits and single underscores"
        }
        if !meaningParts.contains(where: name.contains) {
            return "a name has TETHER, THREADS or MESSAGE_THREAD in it; a rename without one is an app update"
        }
        if let part = refusedParts.first(where: name.contains) { return "a name with \(part) in it is refused" }
        return "no name"
    }

    /// Parts of a name that make it one the mind may not set: what would change who the
    /// resident signs in as, which provider or URL it reaches, or a check it skips.
    public static let refusedParts = [
        "TOKEN", "KEY", "SECRET", "AUTH", "PASSWORD", "CREDENTIAL", "_USE_", "SKIP", "URL", "PROXY", "PROVIDER",
        "DANGEROUS", "BYPASS", "SANDBOX", "SIMPLE", "SHELL", "REMOTE", "MANAGED", "SETTINGS", "ENV", "HOOK", "MODE", "WORKER",
    ]
}
