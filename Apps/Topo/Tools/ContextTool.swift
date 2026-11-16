import Foundation
import TopoTools
import TopoTurn

/// `topo context`: the mind's hand on its own context. It shows how full the context is and where
/// it is compacted, sets that threshold on this phone, and asks for a compaction; and it says
/// whether turns go on a message thread, inferred from what the last requests uploaded, turns that
/// off or on, and renames the variable that asks Claude Code for it. It changes this device's
/// settings and the guest's own conversation, and nothing of the person's.
struct ContextTool: Tool {
    /// How the context stands, as the chat's harness has it.
    struct Facts: Sendable, Equatable {
        var context: Int?
        var window: Int?
        var setting: Compaction.Setting
        var compacting = false
        var last: String?
        var threads: MessageThreads.Setting = .standard
        /// The last requests' uploads, oldest first (`ThreadSampler`).
        var sent: [ThreadSampler.Note] = []
        var now = Date()
    }

    let facts: @MainActor @Sendable () -> Facts
    let set: @MainActor @Sendable (Compaction.Setting) -> Void
    /// Asks for a compaction and answers at once: true when it is now waiting, false when one
    /// already was or there is no guest to ask.
    let compact: @MainActor @Sendable () -> Bool
    let setThreads: @MainActor @Sendable (MessageThreads.Setting) -> Void

    let name = "context"
    let summary = "your own context: how full it is, when it is compacted, compacting it now, and message threads"
    let usage = """
    topo context                        how full your context is, the model's window, the tokens it is compacted at
                                        and where that came from, and what the last compaction asked for here did
    topo context threshold <auto|\(Compaction.lowest)–100>
                                        when your context is compacted by itself: auto is Claude Code's own, a number
                                        is that share of the window less \(Compaction.reserved) tokens, in whole percent. Kept on
                                        this phone; it holds from this turn's end, since your process is replaced then
    topo context compact                compact your context now. It is queued and runs once this turn has ended, so
                                        the answer says only that it is waiting; topo context afterwards says what it did

    topo context threads                whether your turns are sent on a message thread, and the last requests, each
                                        judged by what it uploaded against the context it was sent: a small upload is
                                        a thread continued (only what was new went), one the size of the context is the
                                        whole conversation (a thread begun, or none), and anything else can't be told.
                                        Inferred: nothing of the app's reads a request
    topo context threads <on|off>       send turns on a thread or not. On, the conversation is held on Anthropic's
                                        side, encrypted in memory, up to an hour after its last request, with no way to
                                        delete it sooner, and outside zero data retention; and Claude Code also sends
                                        Anthropic and Datadog its telemetry, naming the person's account, which
                                        topo context threads says whole, on and off, with what off still sends. Off,
                                        every request carries the whole conversation. Kept on this phone; it holds
                                        from this turn's end, since your process is replaced then
    topo context threads variable <NAME|default>
                                        the variable your launch sets to 1 to ask Claude Code for threads, if Claude
                                        Code renames it: CLAUDE_CODE_ then capitals, digits and single underscores,
                                        with TETHER, THREADS or MESSAGE_THREAD in it, and no part a credential's, a
                                        provider's, a URL's, a hook's or the like; default is \(MessageThreads.defaultVariable)

    A threshold can only be under Claude Code's own, so 100 is the same as auto.
    A launch that asked for threads under a name Claude Code does not read sends every request whole, and
    nothing fails: only the requests themselves tell, so after a change check that a turn's requests go small.
    A whole upload has other causes too: a thread begun, Claude Code sending without a thread once the
    conversation holds a web search's results or its tools changed, a thread Anthropic dropped and Claude Code
    made again, or a request carrying a big tool result in a short conversation. Sizes are compressed, so very
    repetitive words read small. Judge by several turns' requests, not one.
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
        case "threads":
            return threads(Array(arguments.dropFirst()))
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

    @MainActor
    private func threads(_ arguments: [String]) -> ToolReply {
        var setting = facts().threads
        switch arguments.first {
        case nil:
            return .ok(Self.threads(facts()))
        case "on", "off":
            guard arguments.count == 1 else { return .usage("topo context threads \(arguments[0]) takes nothing more\n\n\(usage)\n") }
            setting.on = arguments[0] == "on"
        case "variable":
            guard arguments.count == 2 else {
                return .usage("topo context threads variable takes one name, or default; nothing was changed\n\n\(usage)\n")
            }
            guard let name = MessageThreads.variable(arguments[1]) else {
                return .usage("\(MessageThreads.refusal(arguments[1])); nothing was changed\n\n\(usage)\n")
            }
            setting.variable = name
        default:
            return .usage("topo context threads does not take \(arguments[0].prefix(40))\n\n\(usage)\n")
        }
        setThreads(setting)
        var now = facts()
        now.threads = setting
        return .ok(Self.threads(now) + "This holds from this turn's end.\n")
    }

    /// The setting, then each request, as its upload read.
    static func threads(_ facts: Facts) -> String {
        let setting = facts.threads
        let name = setting.variable == MessageThreads.defaultVariable ? "Claude Code's own name at its pin" : "renamed on this phone"
        var lines = [setting.on ? "threads: on, asked for with \(setting.variable)=\(MessageThreads.value) (\(name))"
                                : "threads: off (the variable, when on: \(setting.variable), \(name))"]
        if setting.on {
            lines.append("held: on Anthropic's side, encrypted in memory, up to an hour after the last request; no delete; not zero data retention")
            lines.append("also sent: \(MessageThreads.alsoSent)")
            lines.append("off: \(MessageThreads.whenOff)")
        } else {
            lines.append("off: \(MessageThreads.whenOff)")
            lines.append("on would send: \(MessageThreads.alsoSent)")
        }
        guard !facts.sent.isEmpty else {
            lines.append("requests: none seen since this app launched or the last login ended")
            return lines.joined(separator: "\n") + "\n"
        }
        lines.append("requests, oldest first, judged by their uploads (inferred, never read):")
        for sent in facts.sent {
            let ago = max(0, Int(facts.now.timeIntervalSince(sent.at).rounded()))
            let upload = sent.bytes.map { "\(TurnTimeline.size($0)) for \(sent.tokens) tokens" }
                ?? "upload not told apart (no one connection, or more than one, sent anything) for \(sent.tokens) tokens"
            lines.append("  \(ago) s ago  \(Self.kindWords[sent.kind] ?? sent.kind.rawValue)  \(upload)")
        }
        let small = facts.sent.filter { $0.kind == .thread }.count
        let newest = Self.kindWords[facts.sent[facts.sent.count - 1].kind] ?? ""
        lines.append((small == 0 ? "small uploads: none of these" : "small uploads: \(small) of \(facts.sent.count)") + "; the newest: \(newest)")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A request's kind in words.
    static let kindWords: [ThreadSampler.Kind: String] = [
        .thread: "small upload: on a thread", .whole: "whole conversation", .unknown: "can't tell",
    ]

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
