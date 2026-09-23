#if os(iOS)
import Foundation
import TopoCore
import TopoTurn
import TopoUserland

/// What the bridge needs of the guest: the resident Claude Code (`ResidentConversation` in the app,
/// a scripted one in the suites) and where its home is on this side, since the session
/// transcripts Claude Code writes are under it.
protocol GuestConversation: Sendable {
    /// The guest's home, which Claude Code's transcripts are under (`GuestTranscript`).
    var home: URL { get }
    /// Returns once the resident process is up; throws `GuestBridgeError.notReady` with the
    /// reason while it cannot be: the userland still downloading, the guest failing to start, or
    /// the app in the background.
    func ready() async throws
    /// Starts the resident process if it can be started, and says nothing if it cannot.
    func warm() async
    /// The model the resident process asks; a change replaces it once idle.
    func use(model: String?) async
    /// The session id the resident process resumes, nil for a fresh one.
    func sessionID() async -> String?
    func residentPID() async -> Int32?
    /// Sends one input under `id`. Throws, having written nothing, when it is refused.
    func send(_ text: String, id: String) async throws -> AsyncStream<GuestSession.TurnUpdate>
    /// Returns once a process being ended has been, so its transcript is final.
    func settle() async
    /// Forgets the conversation: the next process starts a fresh session.
    func forget() async
    /// Where the guest stands, for the diagnostics screen.
    func status() async -> String
}

enum GuestBridgeError: Error, Equatable, CustomStringConvertible {
    /// The guest cannot take a turn yet: the userland's own status line says why.
    case notReady(String)
    /// The guest received this turn and was cut off before answering it. It is not sent again by
    /// itself, since it may have run tools; the person asks again.
    case unresolved
    /// The turn never reached the guest, or the guest failed before receiving it; the next pass
    /// asks again.
    case failed(String)

    var description: String {
        switch self {
        case .notReady(let why): "Topo is not ready to answer yet: \(why)"
        case .unresolved: "Topo was cut off before answering that. It is not asked again by itself; ask again when you want the answer."
        case .failed(let why): "The reply failed: \(why)"
        }
    }
}

/// What the guest is doing, for Topo on the glass: a turn sent (to which process), each of its
/// updates, and the turn gone.
enum GuestActivity: Sendable {
    /// `answering` is the person's turns the input answers, so each line of a turn names it.
    case began(pid: Int32?, answering: [TurnRef])
    case update(GuestSession.TurnUpdate)
    case gone(answering: [TurnRef])
}

/// Which turns of the log the guest has seen, as graph coverage rather than a position: a set of
/// refs, kept per device as runs of sequence numbers. A turn is covered only when it was in what
/// the guest was given, so a branch that arrives late, with an earlier timestamp than turns
/// already covered, is still found unseen.
struct Coverage: Codable, Equatable, Sendable {
    /// Per device, sorted, disjoint runs of sequence numbers.
    private(set) var runs: [String: [ClosedRange<Int64>]] = [:]

    init() {}

    init(_ refs: some Sequence<TurnRef>) {
        insert(refs)
    }

    func contains(_ ref: TurnRef) -> Bool {
        runs[ref.device.rawValue]?.contains { $0.contains(ref.sequence) } ?? false
    }

    var count: Int { runs.values.reduce(0) { $0 + $1.reduce(0) { $0 + Int($1.count) } } }

    mutating func insert(_ refs: some Sequence<TurnRef>) {
        var added: [String: [Int64]] = [:]
        for ref in refs { added[ref.device.rawValue, default: []].append(ref.sequence) }
        for (device, sequences) in added {
            let all = (runs[device] ?? []).flatMap { Array($0) } + sequences
            runs[device] = Self.runs(of: Set(all).sorted())
        }
    }

    mutating func formUnion(_ other: Coverage) {
        for (device, ranges) in other.runs {
            insert(ranges.flatMap { $0.map { TurnRef(device: DeviceID(device), sequence: $0) } })
        }
    }

    private static func runs(of sorted: [Int64]) -> [ClosedRange<Int64>] {
        var out: [ClosedRange<Int64>] = []
        for value in sorted {
            if let last = out.last, last.upperBound + 1 == value {
                out[out.count - 1] = last.lowerBound...value
            } else {
                out.append(value...value)
            }
        }
        return out
    }
}

/// The bridge's bookkeeping, one file on disk beside the session id: which session the guest's
/// conversation is, what of the log it has seen, and the one input outstanding, recorded before
/// it is sent.
struct GuestLedger: Codable, Equatable, Sendable {
    /// The session `seen` belongs to: a different one has seen none of it.
    var session: String?
    var seen = Coverage()
    var pending: Pending?

    /// An input given to the guest whose reply is not in the log yet.
    struct Pending: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            /// Sent, and what became of it not known yet.
            case sent
            /// Received and cut off with no answer: not sent again unless the person asks.
            case unresolved
        }
        /// The input's uuid, which the guest's transcript keeps.
        var input: String
        /// The reply's nonce, and the parents it is written with.
        var nonce: String
        var parents: [TurnRef]
        /// The person's turns it answers.
        var answering: [TurnRef]
        /// Every turn the input was built from: what the guest has seen once it is answered.
        var covers: Coverage
        /// The session it went to, once known.
        var session: String?
        var sentAt: Date
        var state: State
        /// The person asked again: the next request for it is sent afresh.
        var askAgain = false
    }

    /// The ledger on disk. No file is an empty ledger: nothing was ever sent, or sign-out took it
    /// away. A file that cannot be read or decoded throws, and is never taken for an empty one,
    /// since what it cannot say is whether an input it records was received.
    static func load(_ url: URL) throws -> GuestLedger {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return GuestLedger()
        }
        return try JSONDecoder().decode(GuestLedger.self, from: data)
    }

    func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Reconciliation: what to do about the outstanding input, from what the guest's own transcript
/// says became of it and the request being answered now. One pure function, so every case is a
/// value a test can make.
enum Reconciliation: Equatable {
    /// Never received: nothing the guest could do was done. The record goes, nothing it carried
    /// is counted seen, and whatever it carried is still unseen for the next input.
    case clear
    /// This request, already answered in the guest: the reply is written without asking again.
    case answered(String)
    /// An earlier request the log has moved on from, answered in the guest: its reply is owed the
    /// log, under its own nonce.
    case owed(OwedReply)
    /// This request, received and cut off: refused, never re-sent by itself.
    case unresolved
    /// This request, cut off, and the person asked again: sent afresh.
    case askAgain
    /// An earlier request, received and cut off, that the log has moved past: the guest saw it,
    /// so what it carried counts as seen, and the record goes.
    case superseded
    /// Nothing is being asked, and the outstanding input was cut off: it stays unresolved.
    case hold
    /// The transcript could not be read: nothing is known, so the record stays as it is, nothing
    /// is sent, and the next attempt reads again.
    case unknown

    /// `request` is the nonce of the reply being asked for now, nil when only asked what is owed.
    static func of(_ pending: GuestLedger.Pending, verdict: GuestTranscript.Verdict,
                   request: String?) -> Reconciliation {
        switch verdict {
        case .unreadable:
            return .unknown
        case .notReceived:
            return .clear
        case .answered(let text):
            guard request == pending.nonce else {
                return .owed(OwedReply(parents: pending.parents, nonce: pending.nonce, text: text))
            }
            return .answered(text)
        case .unresolved:
            guard let request else { return .hold }
            guard request == pending.nonce else { return .superseded }
            return pending.askAgain ? .askAgain : .unresolved
        }
    }
}

/// The guest as the phone's brain: the resident Claude Code answers each turn, and the reply is
/// written to the log by the runner under the nonce contract the log already keeps, so the log
/// cannot tell it from any other reply.
///
/// The guest keeps its own conversation, so it is sent only what it has not seen: the person's
/// words, after any turns of the log it has not been given (a limb's turn, another primary's
/// reply) as a "meanwhile" block — or, for a session with nothing seen, the last `contextLimit`
/// turns of the log. What it has seen is `GuestLedger.seen`, advanced only once the reply to an
/// input is in the log.
///
/// Before an input goes, the ledger records it (`pending`), with the uuid it carries. After any
/// crash, exit or teardown the bridge reads the guest's own transcript for that uuid
/// (`GuestTranscript`) and reconciles (`Reconciliation`): never received, it is sent; answered,
/// the reply is written without asking again; received and unanswered, it is unresolved — shown,
/// and asked again only when the person asks, since it may have run tools.
actor GuestBridge: Brain {
    /// How many turns of the log a session that has seen nothing is given; the older ones are its
    /// history, counted seen without being told. A session that has seen the log is told every
    /// turn it has not seen, however many: what it was told is all it knows of the conversation.
    static let contextLimit = 40

    private let conversation: any GuestConversation
    private let file: URL
    private let observe: @Sendable (GuestActivity) async -> Void
    private var ledger = GuestLedger()
    /// Whether `ledger` is the one on disk. Until it is, nothing is sent, nothing is written over
    /// the file, and every request reads it again; `ledgerUnread` says why the last read failed.
    private var loaded = false
    private var ledgerUnread: String?
    /// Whether a request is with the guest; the next waits its turn in `queue`, since the guest
    /// takes one turn at a time.
    private var asking = false
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var warming = false
    /// Which session and process wrote each reply this bridge returned, by its nonce.
    private var provenance: [String: (session: String?, pid: Int32?)] = [:]
    /// The replies this bridge returned in this launch, by nonce, newest last: a request for one
    /// of them that was waiting behind the request that got it is handed the same words rather
    /// than asking the guest a second time.
    private var recent: [(nonce: String, text: String)] = []
    /// Counts sign-outs. An answer started under an earlier count was for a login that has gone:
    /// it records nothing and sends nothing, wherever it was waiting when the count moved.
    private var login = 0

    /// `file` is the ledger; everything the bridge knows across launches is read from it here, or,
    /// when it cannot be read, at each request until it can.
    init(conversation: any GuestConversation, ledger file: URL,
         observe: @escaping @Sendable (GuestActivity) async -> Void = { _ in }) {
        self.conversation = conversation
        self.file = file
        self.observe = observe
        do {
            ledger = try GuestLedger.load(file)
            loaded = true
        } catch {
            ledgerUnread = String(describing: error)
        }
    }

    // MARK: - Brain

    func answer(_ request: BrainRequest) async throws -> Reply {
        let login = self.login
        if asking { await withCheckedContinuation { queue.append($0) } }
        asking = true
        defer {
            // Handed to the next request waiting, if there is one, so nothing slips in between.
            if queue.isEmpty { asking = false } else { queue.removeFirst().resume() }
        }

        // A ledger that cannot be read may hold an input the guest received: nothing is sent
        // until it can be read and that input reconciled.
        guard readLedger() else { throw GuestBridgeError.failed(Self.ledgerUnreadable) }
        // What an input the log moved past carried: the guest received it, so it is not told
        // again, but it is counted seen only when this request's reply lands, which covers it.
        var received = Coverage()
        if let known = recent.last(where: { $0.nonce == request.nonce }) {
            return reply(known.text, to: request, usage: nil, model: nil)
        }
        if let pending = ledger.pending {
            switch Reconciliation.of(pending, verdict: verdict(on: pending), request: request.nonce) {
            case .clear:
                try record(nil)
            case .answered(let text):
                // The ledger keeps the input until the reply is in the log (`landed`).
                provenance[request.nonce] = (pending.session, nil)
                return reply(text, to: request, usage: nil, model: nil)
            case .owed:
                // The runner writes an owed reply before it asks; one still here is a write that
                // did not happen, and the next attempt makes it.
                throw GuestBridgeError.failed("a reply the guest finished is still to be written")
            case .unresolved:
                ledger.pending?.state = .unresolved
                try save()
                throw GuestBridgeError.unresolved
            case .askAgain:
                break
            case .superseded:
                received = pending.covers
                try record(nil)
            case .hold:
                break
            case .unknown:
                throw GuestBridgeError.failed(Self.unreadable)
            }
        }

        await conversation.use(model: ClaudeModel.effective(request.model).rawValue)
        try await conversation.ready()
        let session = await conversation.sessionID()
        let fresh = session == nil || session != ledger.session
        if fresh {
            // A fresh session, or another one than the ledger's, has seen none of the log.
            ledger.session = session
            ledger.seen = Coverage()
            received = Coverage()
        }
        let unseen = request.context.filter { !ledger.seen.contains($0.ref) && !received.contains($0.ref) }
        let told = fresh ? Array(unseen.suffix(Self.contextLimit)) : unseen
        let input = Self.render(unseen: told, answering: request.answering, fresh: fresh && !told.isEmpty)
        // What the guest has seen once this is answered: what the input tells it, what it received
        // of an input the log moved past, and, for a fresh session alone, the history before the
        // last `contextLimit` turns, which it is never told.
        var covers = Coverage(told.map(\.ref) + request.answering.map(\.ref))
        covers.formUnion(received)
        if fresh { covers.insert(request.context.map(\.ref)) }
        let id = UUID().uuidString.lowercased()
        // `ready` can wait a long time, and a sign-out can come while it does.
        try stillCurrent(login)
        // Written before the input goes: after a crash this is how the transcript is asked.
        try record(GuestLedger.Pending(input: id, nonce: request.nonce, parents: request.parents,
                                       answering: request.answering.map(\.ref),
                                       covers: covers,
                                       session: session, sentAt: Date(), state: .sent))
        let pid = await conversation.residentPID()
        try stillCurrent(login)
        let updates: AsyncStream<GuestSession.TurnUpdate>
        do {
            updates = try await conversation.send(input, id: id)
        } catch {
            // Refused before anything was written: not received.
            if self.login == login { try? record(nil) }
            throw GuestBridgeError.failed(String(describing: error))
        }

        let answering = request.answering.map(\.ref)
        await observe(.began(pid: pid, answering: answering))
        var model: String?, usage: StreamEvent.Usage?, end: GuestSession.TurnEnd?
        for await update in updates {
            await observe(.update(update))
            switch update {
            case .event(.started(let started, let startedModel)):
                model = startedModel
                if ledger.pending?.input == id {
                    ledger.pending?.session = started
                    try? save()
                }
                provenance[request.nonce] = (started, pid)
            case .event(.usage(let reported)):
                usage = reported
            case .ended(let ended):
                end = ended
            case .event:
                break
            }
        }
        await observe(.gone(answering: answering))

        if case .answered(let result) = end {
            return reply(result.text ?? "", to: request, usage: usage, model: model)
        }
        if case .failed(.result) = end {
            // An error result is Claude Code's own word that it received the turn and ended it
            // without an answer. The process lives on and may still be writing its transcript,
            // so the transcript is not read: the turn is unresolved, never sent again by itself.
            if ledger.pending?.input == id {
                ledger.pending?.state = .unresolved
                try? save()
            }
            throw GuestBridgeError.unresolved
        }
        // Anything else is read off the transcript once the process it went to is gone.
        await conversation.settle()
        guard let pending = ledger.pending, pending.input == id else { throw GuestBridgeError.failed(Self.describe(end)) }
        switch GuestTranscript.verdict(for: id, home: conversation.home, session: pending.session, since: pending.sentAt) {
        case .notReceived:
            try? record(nil)
            throw GuestBridgeError.failed(Self.describe(end))
        case .answered(let text):
            return reply(text, to: request, usage: usage, model: model)
        case .unresolved:
            ledger.pending?.state = .unresolved
            try? save()
            throw GuestBridgeError.unresolved
        case .unreadable:
            // The record stays: the next request reads again before it sends anything.
            throw GuestBridgeError.failed(Self.unreadable)
        }
    }

    /// Why a turn waits when the guest's transcript could not be read.
    static let unreadable = "the guest's transcript could not be read, so whether it received the turn is not known; nothing is sent until it can be"

    /// Why a turn waits when the bridge's own ledger could not be read.
    static let ledgerUnreadable = "the record of what the guest was sent could not be read, so whether it received the turn is not known; nothing is sent until it can be"

    func landed(_ reply: Turn, nonce: String) async {
        // Unread, the ledger stays as it is on disk; the reply is in the log under its nonce, and
        // the record is reconciled against it once the ledger can be read.
        guard readLedger(), let pending = ledger.pending, pending.nonce == nonce else { return }
        ledger.seen.formUnion(pending.covers)
        ledger.seen.insert([reply.ref])
        if let session = pending.session { ledger.session = session }
        try? record(nil)
    }

    func unresolved() async -> Set<TurnRef> {
        guard readLedger(), let pending = ledger.pending, pending.state == .unresolved, !pending.askAgain else { return [] }
        return Set(pending.answering)
    }

    func owed() async -> OwedReply? {
        guard !asking, readLedger(), let pending = ledger.pending else { return nil }
        switch Reconciliation.of(pending, verdict: verdict(on: pending), request: nil) {
        case .clear:
            try? record(nil)
        case .owed(let owed):
            return owed
        case .hold where pending.state != .unresolved:
            ledger.pending?.state = .unresolved
            try? save()
        default:
            break
        }
        return nil
    }

    func use(model: ClaudeModel) async {
        await conversation.use(model: ClaudeModel.effective(model).rawValue)
    }

    func forget() async {
        login += 1
        ledger = GuestLedger()
        loaded = true
        ledgerUnread = nil
        try? FileManager.default.removeItem(at: file)
        provenance = [:]
        recent = []
        await conversation.forget()
    }

    func describe() async -> String {
        var parts = ["Claude Code in the guest: \(await conversation.status())"]
        if let why = ledgerUnread {
            parts.append("the bridge's ledger could not be read (\(why)); nothing is sent until it can be")
            return parts.joined(separator: "; ")
        }
        parts.append("seen \(ledger.seen.count) turns" + (ledger.session.map { " of session \($0)" } ?? ""))
        if let pending = ledger.pending {
            parts.append(pending.state == .unresolved ? "a turn cut off, waiting to be asked again" : "a turn with the guest")
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - What the app asks besides

    /// The person chose to ask again the turn that was cut off: the next request for it is sent.
    func askAgain() {
        guard readLedger(), ledger.pending?.state == .unresolved else { return }
        ledger.pending?.askAgain = true
        try? save()
    }

    /// Starts the resident process when it can be, without waiting on it: what warms the guest as
    /// the chat comes forward, so the first turn is ready by the time the words are.
    func warm() async {
        guard !warming else { return }
        warming = true
        defer { warming = false }
        await conversation.warm()
    }

    /// Returns once the guest can take a turn: the userland fetched and the resident process up.
    func ready() async throws {
        try await conversation.ready()
    }

    /// The session and the resident process that wrote the reply under `nonce`, if this bridge
    /// asked for it in this launch.
    func provenance(of nonce: String) -> (session: String?, pid: Int32?)? {
        provenance[nonce]
    }

    /// The ledger as it stands, for the suites.
    var current: GuestLedger { ledger }

    // MARK: - Inside

    /// Throws when the answer was begun under a login that has since signed out, or its task was
    /// cancelled: what it would record or send belongs to nobody now.
    private func stillCurrent(_ login: Int) throws {
        guard login == self.login else { throw CancellationError() }
        try Task.checkCancellation()
    }

    /// Reads the ledger from disk while the last read of it failed, and answers whether the
    /// ledger in memory is the one on disk. Only then may anything be sent or recorded.
    @discardableResult
    private func readLedger() -> Bool {
        guard !loaded else { return true }
        do {
            ledger = try GuestLedger.load(file)
            ledgerUnread = nil
            loaded = true
            return true
        } catch {
            ledgerUnread = String(describing: error)
            return false
        }
    }

    private func verdict(on pending: GuestLedger.Pending) -> GuestTranscript.Verdict {
        GuestTranscript.verdict(for: pending.input, home: conversation.home, session: pending.session,
                                since: pending.sentAt)
    }

    private func reply(_ text: String, to request: BrainRequest, usage: StreamEvent.Usage?, model: String?) -> Reply {
        recent.removeAll { $0.nonce == request.nonce }
        recent.append((request.nonce, text))
        if recent.count > 16 { recent.removeFirst(recent.count - 16) }
        return Reply(text: text, model: model ?? ClaudeModel.effective(request.model).rawValue, stopReason: nil,
              inputTokens: usage?.context ?? 0, outputTokens: usage?.output ?? 0)
    }

    private func record(_ pending: GuestLedger.Pending?) throws {
        ledger.pending = pending
        try save()
    }

    private func save() throws { try ledger.save(file) }

    private static func describe(_ end: GuestSession.TurnEnd?) -> String {
        switch end {
        case .failed(let failure): "\(failure)"
        case .abandoned: "the turn was abandoned before the guest received it"
        case .answered, nil: "the turn ended without an answer"
        }
    }

    /// The input for the guest: the turns of the log it has not seen, oldest first, then the
    /// person's words. A session that has seen nothing is told the turns are the conversation so
    /// far; one that has seen the log is told they happened meanwhile, elsewhere.
    static func render(unseen: [Turn], answering: [Turn], fresh: Bool) -> String {
        let words = answering.map(\.text).joined(separator: "\n\n")
        guard !unseen.isEmpty else { return words }
        let header = fresh
            ? "[The conversation so far, from the log on their devices — the last \(unseen.count) turns, oldest first:]"
            : "[Meanwhile, on their other devices — turns of this conversation you have not seen, oldest first:]"
        let lines = unseen.map { turn in
            (turn.role == .person ? "Them: " : "You, answering on another device: ") + turn.text
        }
        return ([header] + lines + ["[They now say:]", words]).joined(separator: "\n\n")
    }
}
#endif
