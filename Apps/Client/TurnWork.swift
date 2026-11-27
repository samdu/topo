import Foundation
import Observation
import TopoCore
#if os(iOS)
import TopoUserland
#endif

/// One step of a turn's work as the transcript's work row draws it: a thought, or a tool call
/// with its outcome once that lands.
struct WorkStep: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// `text` is what the model thought, when the stream carried it.
        case thought(text: String?)
        case call(name: String, summary: String, input: String)
    }
    struct Outcome: Equatable, Sendable {
        let ok: Bool
        /// The size of what came back, as the result's UTF-8 text.
        let bytes: Int
        let text: String
    }
    let id: String
    let kind: Kind
    var outcome: Outcome?

    /// The glyph the closed row draws for the step: a kind of work, the one rule the Discord
    /// strip and Daphne's row share (buddy-channels `discord/classify.ts`), narrowed to the tools
    /// a Topo has.
    var glyph: String {
        switch kind {
        case .thought: return "💭"
        case .call(let name, _, _):
            switch name {
            case "WebSearch", "WebFetch": return "🌐"
            case "Read", "Grep", "Glob", "LS", "NotebookRead": return "🔎"
            case "Write", "Edit", "MultiEdit", "NotebookEdit": return "📝"
            case "Agent", "Task": return "🤖"
            case "Bash": return "💻"
            default: return "🧰"
            }
        }
    }

    var isCall: Bool { if case .call = kind { true } else { false } }
}

/// What the guest did between the words of each turn this device ran: the steps of the turn in
/// flight, and of the last few that ended, by the nonce of the person's turn they answer.
///
/// A step in full — a command, what it printed — can hold a connection's token, so the work is
/// this device's alone, kept in memory and never in the log, the disk or a line of the
/// diagnostics. A relaunch starts with none; the end of a login takes it all (`LoginLife.onEnd`,
/// which a takeover's and a viewer's arrival also run).
@MainActor @Observable
final class TurnWork {
    /// The steps of each turn, by the nonce of the person's turn they answer.
    private(set) var steps: [String: [WorkStep]] = [:]
    /// The nonce whose turn the guest is answering now; nil between turns.
    private(set) var live: String?
    /// The turns kept, newest last; the oldest goes past `keep`.
    private var order: [String] = []
    static let keep = 40
    /// The most characters of steps kept across every turn: past it the oldest turns go, never
    /// the live one, since a turn can make any number of steps of up to 96K characters each.
    static let budget = 4_000_000
    private var sizes: [String: Int] = [:]

    #if os(iOS)
    /// Which turn a guest turn answers, by the refs it names: the harness's turns know their
    /// nonces.
    private var nonceOf: (TurnRef) -> String? = { _ in nil }

    /// Follows the chat's guest beside Topo and the keeper's sounds: what the harness was already
    /// telling is told on, and the work hears of it after.
    func follow(_ harness: Harness) {
        nonceOf = { [weak harness] ref in harness?.turns.first { $0.ref == ref }?.nonce }
        let before = harness.onGuest
        harness.onGuest = { [weak self] activity in
            before?(activity)
            self?.follow(activity)
        }
        LoginLife.shared.onEnd { [weak self] in self?.forget() }
    }

    func follow(_ activity: GuestActivity) {
        switch activity {
        case .began(_, let answering, let heard):
            let nonce = heard ?? answering.last.flatMap(nonceOf)
            live = nonce
            if let nonce { begin(nonce) }
        case .update(.event(let event)):
            guard let live else { return }
            take(event, into: live)
        case .update(.ended), .gone:
            live = nil
        }
    }

    func take(_ event: StreamEvent, into nonce: String) {
        switch event {
        case .thought(let text):
            steps[nonce, default: []].append(WorkStep(id: "\(nonce)-\(steps[nonce]?.count ?? 0)", kind: .thought(text: text)))
            grew(nonce, by: text?.count ?? 0)
        case .toolInput(let id, let name, let summary, let input):
            steps[nonce, default: []].append(WorkStep(id: id, kind: .call(name: name, summary: summary, input: input)))
            grew(nonce, by: input.count + summary.count)
        case .toolResult(let isError, let text, let id?):
            guard var list = steps[nonce], let i = list.firstIndex(where: { $0.id == id && $0.isCall }) else { return }
            list[i].outcome = .init(ok: !isError, bytes: text.utf8.count,
                                    text: ToolStep.cap(text, ToolStep.resultMax).text)
            steps[nonce] = list
            grew(nonce, by: list[i].outcome?.text.count ?? 0)
        default:
            break
        }
    }
    #endif

    /// A turn begun again (an answer asked for again) starts its steps again.
    func begin(_ nonce: String) {
        steps[nonce] = []
        sizes[nonce] = 0
        order.removeAll { $0 == nonce }
        order.append(nonce)
        while order.count > Self.keep { drop(order.removeFirst()) }
    }

    /// Counts what a turn's steps hold, and lets the oldest turns go past the budget.
    func grew(_ nonce: String, by characters: Int) {
        sizes[nonce, default: 0] += characters
        while sizes.values.reduce(0, +) > Self.budget, let oldest = order.first(where: { $0 != live }) {
            order.removeAll { $0 == oldest }
            drop(oldest)
        }
    }

    private func drop(_ nonce: String) {
        steps[nonce] = nil
        sizes[nonce] = nil
    }

    /// Everything, at the end of a login.
    func forget() {
        steps = [:]
        order = []
        sizes = [:]
        live = nil
    }

}
