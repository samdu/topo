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

    /// The glyph the closed row draws for the step: the web and the shell, then the keeper's own
    /// kinds of tool (`KeeperSounds.tone(forTool:)`), the glyphs the Discord strip and Daphne's
    /// row draw (buddy-channels `discord/classify.ts`).
    var glyph: String {
        switch kind {
        case .thought: return "💭"
        case .call(let name, _, _):
            // The keeper's own kinds of tool, with the web and the shell drawn apart.
            switch name {
            case "WebSearch", "WebFetch": return "🌐"
            case "Bash": return "💻"
            default:
                #if os(iOS)
                switch KeeperSounds.tone(forTool: name) {
                case .read: return "🔎"
                case .write: return "📝"
                case .delegate: return "🤖"
                default: return "🧰"
                }
                #else
                return "🧰"
                #endif
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
    /// the newest, since a turn can make any number of steps of up to 96K characters each.
    static let budget = 4_000_000
    private var sizes: [String: Int] = [:]

    #if os(iOS)
    /// Which turn a guest turn answers, by the refs it names: the harness's turns know their
    /// nonces.
    private var nonceOf: (TurnRef) -> String? = { _ in nil }

    /// Follows the chat's guest beside Topo and the keeper's sounds: what the harness was already
    /// telling is told on, and the work hears of it after.
    func follow(_ harness: Harness, login: LoginLife = .shared) {
        nonceOf = { [weak harness] ref in harness?.turns.first { $0.ref == ref }?.nonce }
        let before = harness.onGuest
        harness.onGuest = { [weak self] activity in
            before?(activity)
            self?.follow(activity)
        }
        login.onEnd { [weak self] in self?.forget() }
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
            grew(nil, by: 0)
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

    /// Counts what a turn's steps hold, and lets the oldest turns go past the budget. The newest
    /// turn with steps, running or ended, and the turn running are never let go by it: a turn's
    /// row does not vanish as its reply lands, and the next turn's first step lets it go if it
    /// is still over.
    func grew(_ nonce: String?, by characters: Int) {
        if let nonce { sizes[nonce, default: 0] += characters }
        // The newest turn with steps, which a turn begun after it and ending with none does not
        // displace, and the turn running.
        let kept = Set([order.last { steps[$0]?.isEmpty == false }, live].compactMap { $0 })
        while sizes.values.reduce(0, +) > Self.budget, let oldest = order.first(where: { !kept.contains($0) }) {
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
