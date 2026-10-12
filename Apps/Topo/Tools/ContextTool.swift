import Foundation
import TopoTools
import TopoTurn

/// `topo context`: the mind's hand on its own context. It shows how full the context is and where
/// it is compacted, sets that threshold on this phone, and asks for a compaction. It changes this
/// device's setting and the guest's own conversation, and nothing of the person's.
struct ContextTool: Tool {
    /// How the context stands, as the chat's harness has it.
    struct Facts: Sendable, Equatable {
        var context: Int?
        var window: Int?
        var setting: Compaction.Setting
        var compacting = false
        var last: String?
    }

    let facts: @MainActor @Sendable () -> Facts
    let set: @MainActor @Sendable (Compaction.Setting) -> Void
    /// Asks for a compaction and answers at once: true when it is now waiting, false when one
    /// already was or there is no guest to ask.
    let compact: @MainActor @Sendable () -> Bool

    let name = "context"
    let summary = "your own context: how full it is, when it is compacted, and compacting it now"
    let usage = """
    topo context                        how full your context is, the model's window, the tokens it is compacted at
                                        and where that came from, and what the last compaction asked for here did
    topo context threshold <auto|\(Compaction.lowest)–100>
                                        when your context is compacted by itself: auto is Claude Code's own, a number
                                        is that share of the window less \(Compaction.reserved) tokens, in whole percent. Kept on
                                        this phone; it holds from this turn's end, since your process is replaced then
    topo context compact                compact your context now. It is queued and runs once this turn has ended, so
                                        the answer says only that it is waiting; topo context afterwards says what it did

    A threshold can only be under Claude Code's own, so 100 is the same as auto.
    """

    func run(_ arguments: [String]) async -> ToolReply {
        await MainActor.run { answer(arguments) }
    }

    @MainActor
    private func answer(_ arguments: [String]) -> ToolReply {
        switch arguments.first {
        case nil, "show":
            guard arguments.count <= 1 else { return .usage("topo context takes nothing after show\n\n\(usage)\n") }
            return .ok(Self.show(facts()))
        case "threshold":
            guard arguments.count == 2, let setting = Compaction.Setting(arguments[1]) else {
                return .usage("topo context threshold takes auto or a whole number from \(Compaction.lowest) to 100; nothing was changed\n\n\(usage)\n")
            }
            set(setting)
            var now = facts()
            now.setting = setting
            return .ok(Self.show(now) + "The threshold holds from this turn's end.\n")
        case "compact":
            guard arguments.count == 1 else { return .usage("topo context compact takes nothing more\n\n\(usage)\n") }
            guard compact() else {
                return .failed(facts().compacting ? "a compaction is already waiting or running\n" : "there is no guest to compact on this phone\n")
            }
            return .ok("queued: your context is compacted once this turn has ended. topo context says what it did.\n")
        default:
            return .usage("topo context does not take \(arguments[0].prefix(40))\n\n\(usage)\n")
        }
    }

    static func show(_ facts: Facts) -> String {
        var lines = ["context: \(facts.context.map { "\($0) tokens" } ?? "not known until the next reply")"]
        if let window = facts.window {
            let limit = Compaction.threshold(window: window, setting: facts.setting)
            lines.append("window: \(window) tokens")
            lines.append("compacted at: \(limit) tokens (\(source(facts.setting)))")
        } else {
            lines.append("window: not known until the next reply")
            lines.append("compacted at: \(source(facts.setting))")
        }
        lines.append("last compaction: \(facts.compacting ? "waiting or running" : facts.last ?? "none asked for in this launch")")
        return lines.joined(separator: "\n") + "\n"
    }

    static func source(_ setting: Compaction.Setting) -> String {
        switch setting {
        case .auto: "auto, Claude Code's own"
        case .percent(let percent): "\(percent)%, set on this phone"
        }
    }
}
