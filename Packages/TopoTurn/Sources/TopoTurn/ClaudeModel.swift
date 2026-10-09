import Foundation

/// The models the phone harness offers, each by its family's alias: Claude Code resolves `sonnet`,
/// `opus` and `fable` to the latest of the family it knows, so what is sent carries no version and a
/// newer model is a newer Claude Code (the guest's pin, `scripts/model-manifest.sh`) and no change
/// here. Sonnet is the default; the others are a setting. Haiku is not offered — it is what `pinned`
/// forces a debug build onto, so it is a case without being a choice, named by its dated id because
/// that is what the proxy writes at the wire (`APIProxy.pinnedModel`), and `allCases` (the model menu)
/// is written out rather than synthesised to keep it that way.
public enum ClaudeModel: String, CaseIterable, Sendable, Codable, Identifiable {
    case sonnet
    case opus
    case fable
    case haiku = "claude-haiku-4-5-20251001"

    public static let `default` = ClaudeModel.sonnet
    /// What the chat offers, smallest to largest, which is the order of Topo's heads. Haiku is
    /// deliberately absent.
    public static let allCases: [ClaudeModel] = [.sonnet, .opus, .fable]
    public var id: String { rawValue }

    /// The model a kept setting names: one of the aliases, or a model id of an offered family, which
    /// is what a build that sent ids kept (`claude-opus-5` is Opus). Nil for anything else, Haiku
    /// included, since it is not a choice.
    public init?(setting: String) {
        let kept = setting.lowercased()
        guard let model = Self.allCases.first(where: { kept == $0.rawValue || kept.hasPrefix("claude-\($0.rawValue)-") })
        else { return nil }
        self = model
    }

    /// The model every call goes to whatever the setting says, or nil when the setting is obeyed.
    ///
    /// A debug build is pinned to Haiku. Debug is what a simulator run, an engineer's build and
    /// `swift test` all are, and such a build is signed into a real Claude subscription — Sam's,
    /// through the seeded setup token — so a stray turn spends his account. Pinning the cheapest
    /// model makes the cost of an accidental turn a rounding error rather than a judgement call.
    /// Only a release build lets the menu choose.
    public static let pinned: ClaudeModel? = {
        #if DEBUG
        .haiku
        #else
        nil
        #endif
    }()

    /// The model a request actually carries: the pin when there is one, the asked-for model
    /// otherwise. Every call path goes through here, so there is one place the pin can be read.
    public static func effective(_ requested: ClaudeModel) -> ClaudeModel { pinned ?? requested }

    /// The family's name, which is what the app calls the model where the look names no other
    /// (`Look.Mind`).
    public var displayName: String {
        switch self {
        case .sonnet: "Sonnet"
        case .opus: "Opus"
        case .fable: "Fable"
        case .haiku: "Haiku"
        }
    }
}
