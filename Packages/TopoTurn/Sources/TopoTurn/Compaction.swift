import Foundation

/// When the mind's context is compacted by itself: Claude Code's own threshold, or a share of the
/// window the person or the mind chose. The arithmetic is Claude Code's at its pin (2.1.285), kept
/// here so the app's scale and the resident's are one.
public enum Compaction {
    public enum Setting: Sendable, Equatable {
        /// Claude Code's own: nothing is said to it.
        case auto
        /// Compacted at this share of the effective window, in whole percent, `lowest` to 100.
        case percent(Int)

        /// What the resident is told (`CLAUDE_AUTOCOMPACT_PCT_OVERRIDE`), or nil to say nothing.
        public var percent: Int? {
            if case .percent(let value) = self { return value }
            return nil
        }

        /// The one reader of a setting as a word: `auto`, or a whole number from `lowest` to 100,
        /// with or without a percent sign. Anything else is no setting.
        public init?(_ word: String) {
            let trimmed = word.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "auto" { self = .auto; return }
            let digits = trimmed.hasSuffix("%") ? String(trimmed.dropLast()) : trimmed
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
                  let value = Int(digits), (Compaction.lowest...100).contains(value) else { return nil }
            self = .percent(value)
        }

        /// The setting as it is kept: 0 for `auto`, the percent otherwise. A number kept that no
        /// setting reads as is `auto`.
        public init(kept: Int) {
            self = (Compaction.lowest...100).contains(kept) ? .percent(kept) : .auto
        }

        public var kept: Int { percent ?? 0 }

        public var word: String { percent.map { "\($0)%" } ?? "auto" }
    }

    /// Where the setting is kept on this device, as `Setting.kept`.
    public static let key = "compactAt"

    /// The lowest share a setting takes. Under Claude Code's fixed prefix (its system prompt, its
    /// tools and the memory, some 29 000 tokens in the guest) a threshold is crossed by every
    /// turn, and Claude Code compacts on each and then stops trying. A quarter of a 200 000
    /// window's effective 180 000 is 45 000, clear of that.
    public static let lowest = 25

    /// What Claude Code keeps of the window for the reply, and how far under the rest it compacts.
    public static let reserved = 20_000
    public static let margin = 13_000

    /// The tokens of context at which Claude Code compacts, for a model of `window` tokens.
    public static func threshold(window: Int, setting: Setting) -> Int {
        let effective = window - reserved
        let own = effective - margin
        guard let percent = setting.percent else { return max(own, 0) }
        // Claude Code's own arithmetic, in floating point as it does it, so the two never differ
        // by a token.
        return max(min(Int((Double(effective) * (Double(percent) / 100)).rounded(.down)), own), 0)
    }

    /// How full the context is on the threshold's scale: easy, getting close, or at it.
    public enum Load: String, Sendable, Equatable { case `default`, warning, reset }

    /// The share of the threshold from which the context is getting close.
    public static let warningShare = 0.75

    public static func load(context: Int, window: Int, setting: Setting) -> Load {
        load(context: context, limit: threshold(window: window, setting: setting))
    }

    /// The same, against a threshold already worked out.
    public static func load(context: Int, limit: Int) -> Load {
        guard limit > 0 else { return .default }
        if context >= limit { return .reset }
        return Double(context) >= Double(limit) * warningShare ? .warning : .default
    }

    /// What a compaction that was asked for came to.
    public enum Outcome: Sendable, Equatable {
        /// Claude Code compacted, from `pre` tokens of context to `post`.
        case done(pre: Int, post: Int)
        /// It was asked and did not: its own reason, or how its turn ended.
        case failed(String)
        /// It could not be asked: the guest is not up.
        case unavailable(String)

        public var words: String {
            switch self {
            case .done(let pre, let post): "\(pre) → \(post) tokens"
            case .failed(let why): "failed: \(why)"
            case .unavailable(let why): "not run: \(why)"
            }
        }
    }
}
