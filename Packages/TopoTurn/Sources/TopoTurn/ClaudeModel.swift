import Foundation

/// The models the phone harness offers. Sonnet is the default; the others are a setting. Haiku is
/// not offered — it is what `pinned` forces a debug build onto, so it is a case without being a
/// choice, and `allCases` (the picker) is written out rather than synthesised to keep it that way.
public enum ClaudeModel: String, CaseIterable, Sendable, Codable, Identifiable {
    case sonnet5 = "claude-sonnet-5"
    case opus5 = "claude-opus-5"
    case fable51 = "claude-fable-5-1"
    case haiku45 = "claude-haiku-4-5-20251001"

    public static let `default` = ClaudeModel.sonnet5
    /// What the chat menu offers. Haiku is deliberately absent.
    public static let allCases: [ClaudeModel] = [.sonnet5, .opus5, .fable51]
    public var id: String { rawValue }

    /// The model every call goes to whatever the setting says, or nil when the setting is obeyed.
    ///
    /// A debug build is pinned to Haiku. Debug is what a simulator run, an engineer's build and
    /// `swift test` all are, and such a build is signed into a real Claude subscription — Sam's,
    /// through the seeded setup token — so a stray turn spends his account. Pinning the cheapest
    /// model makes the cost of an accidental turn a rounding error rather than a judgement call.
    /// Only a release build lets the picker choose.
    public static let pinned: ClaudeModel? = {
        #if DEBUG
        .haiku45
        #else
        nil
        #endif
    }()

    /// The model a request actually carries: the pin when there is one, the asked-for model
    /// otherwise. Every call path goes through here, so there is one place the pin can be read.
    public static func effective(_ requested: ClaudeModel) -> ClaudeModel { pinned ?? requested }

    public var displayName: String {
        switch self {
        case .sonnet5: "Sonnet 5"
        case .opus5: "Opus 5"
        case .fable51: "Fable 5.1"
        case .haiku45: "Haiku 4.5"
        }
    }
}
