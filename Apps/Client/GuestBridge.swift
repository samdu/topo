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
    /// Returns once nothing the guest is doing can still write about an input — no turn in flight,
    /// one nobody listens to any more included, and no process being ended — and answers whether
    /// the last process ended was confirmed gone, so that its transcript is final.
    func settle() async -> Bool
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
        case .unresolved: "Topo was cut off before answering. Ask again when you want the answer."
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

/// What became of words the guest was given ahead of their turn (`GuestBridge.hear`), by the
/// person's nonce, since no turn of the log names them yet: the guest's turn on them beginning,
/// and ending with its reply, or with none.
enum GuestHeard: Sendable, Equatable {
    case began(String)
    case ended(String, reply: String?)
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
    /// The inputs given to the guest on the person's words before their turn was in the log,
    /// oldest first: each waits here, under the person's nonce, until the turn is saved and the
    /// input bound to it (`GuestBridge.bind`). Nil in a file written before there were any.
    var early: [Early]?

    /// An input given to the guest ahead of its turn. The reply's nonce and parents are the
    /// turn's ref's, which only the save assigns, so until then the person's nonce names it.
    struct Early: Codable, Equatable, Sendable {
        /// The nonce the person's words were said under, which their turn will carry.
        var person: String
        /// The input's uuid, which the guest's transcript keeps.
        var input: String
        /// What the input told the guest, fixed when it was sent.
        var covers: Coverage
        var session: String?
        var sentAt: Date
        var state: Pending.State
        /// The guest's answer, once it has answered.
        var text: String?
        /// The record this becomes, once its turn is saved, while another holds `pending`.
        var bound: Pending?
    }

    /// The nonces of the person's turns whose replies were last known in the log, newest last:
    /// words said under one are not given ahead of a read that would show their turn there.
    var settled: [String]?
    static let settledLimit = 32

    /// An input given to the guest whose reply is not in the log yet.
    struct Pending: Codable, Equatable, Sendable {
        enum State: String, Codable, Sendable {
            /// Sent, and what became of it not known yet.
            case sent
            /// Answered by the guest: the reply is its own, still to be in the log.
            case answered
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
        /// The guest's answer, once it is known: what is owed the log without reading the
        /// guest's transcript again.
        var text: String?
        /// The person's nonce, for an input given ahead of its turn (`Early`).
        var person: String?
        /// The nonces the person's turns it answers were said under.
        var said: [String]?
        /// Inputs given ahead whose turns the log moved past, counted in `covers`: they leave
        /// `early` when this input's reply lands.
        var passed: [String]?
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
    /// The transcript could not be read, or may still be being written: nothing is known, so the
    /// record stays as it is, nothing is sent, and the next attempt reads again.
    case unknown

    /// `request` is the nonce of the reply being asked for now, nil when only asked what is owed.
    static func of(_ pending: GuestLedger.Pending, verdict: GuestTranscript.Verdict,
                   request: String?) -> Reconciliation {
        // A record already known received — the guest answered it, or read it and was cut off —
        // stays received whatever a later read finds: a transcript not written yet, or since
        // cleared away, is no evidence that it never arrived.
        let verdict = verdict == .notReceived && pending.state != .sent ? .unresolved : verdict
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
    /// Nonces whose words, still on their way to the guest, are to stop there (`stopHearing`).
    private var stopping: Set<String> = []
    private var queue: [CheckedContinuation<Void, Never>] = []
    private var warming = false
    /// Which session and process wrote each reply this bridge returned, by its nonce.
    private var provenance: [String: (session: String?, pid: Int32?)] = [:]
    /// The replies this bridge returned in this launch, by nonce, newest last: a request for one
    /// of them that was waiting behind the request that got it is handed the same words rather
    /// than asking the guest a second time.
    private var recent: [(nonce: String, text: String)] = []
    /// Counts sign-outs. An answer started under an earlier count was for a login that has gone:
    /// it records nothing, sends nothing and hands no reply back, wherever it was waiting when the
    /// count moved — the guest's own turn included — and neither does `owed`.
    private var login = 0
    /// The guest's turns on inputs given ahead of their turn, by input: each is listened to by a
    /// task of the bridge's own, so the caller that gave the words can fail or go without the
    /// turn being lost, and holds the requests' one slot until it ends.
    private var flights: [String: Task<Void, Never>] = [:]
    /// What such a turn reported of its model and usage, for the reply made of it.
    private var flown: [String: (model: String?, usage: StreamEvent.Usage?)] = [:]
    /// The nonces `hear` is at work on, each with the calls for the same nonce waiting on it.
    private var hearing: [String: [CheckedContinuation<Bool, Never>]] = [:]
    private let heardObserver: @Sendable (GuestHeard) async -> Void

    /// `file` is the ledger; everything the bridge knows across launches is read from it here, or,
    /// when it cannot be read, at each request until it can.
    init(conversation: any GuestConversation, ledger file: URL,
         observe: @escaping @Sendable (GuestActivity) async -> Void = { _ in },
         heard: @escaping @Sendable (GuestHeard) async -> Void = { _ in }) {
        self.conversation = conversation
        self.file = file
        self.observe = observe
        heardObserver = heard
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
        // A request bound to words the guest was given ahead of their turn is answered by that
        // input: waited for while the guest is still on it, and handed over without the slot,
        // which a later input given ahead may be holding.
        // Words given ahead that nothing bound to their turn, which is the one turn asked here:
        // this is their request, and their input is its answer.
        if request.answering.count == 1, let person = request.answering.first, request.parents == [person.ref] {
            await bind(nonce: person.nonce, person: person, reply: request.nonce)
            try stillCurrent(login)
        }
        if readLedger() {
            promote()
            if let heard = ledger.pending, heard.nonce == request.nonce, heard.person != nil {
                // Words given ahead that the log has moved past go here as on the path below,
                // counted with this input once its reply lands.
                let passed = passed(in: request.context)
                let named = Array(Set(heard.passed ?? []).union(passed.inputs))
                ledger.pending?.passed = named
                ledger.pending?.covers.formUnion(passed.received)
                ledger.pending?.parents = request.parents
                ledger.pending?.answering = request.answering.map(\.ref)
                try? save()
                if let flight = flights[heard.input] {
                    await flight.value
                    try stillCurrent(login)
                }
                if let now = ledger.pending, now.input == heard.input, now.nonce == request.nonce,
                   now.state == .answered, let text = now.text {
                    provenance[request.nonce] = provenance[request.nonce] ?? (now.session, nil)
                    return reply(text, to: request, usage: flown[now.input]?.usage, model: flown[now.input]?.model)
                }
                // Anything else — cut off, never received, not known yet — is the record's to
                // say, read below as any outstanding input's is.
            }
        }
        if asking { await withCheckedContinuation { queue.append($0) } }
        asking = true
        defer { release() }
        // The wait for the slot can span a sign-out: a request from before it asks nothing now.
        try stillCurrent(login)

        // A ledger that cannot be read may hold an input the guest received: nothing is sent
        // until it can be read and that input reconciled.
        guard readLedger() else { throw GuestBridgeError.failed(Self.ledgerUnreadable) }
        // What an input the log moved past carried: the guest received it, so it is not told
        // again, but it is counted seen only when this request's reply lands, which covers it.
        var received = Coverage()
        if let known = recent.last(where: { $0.nonce == request.nonce }) {
            return reply(known.text, to: request, usage: nil, model: nil)
        }
        // An input given ahead of its turn and left with no end known, by a launch that was
        // killed: read off the guest's transcript before anything else is sent.
        guard await settleEarly() else {
            try stillCurrent(login)
            throw GuestBridgeError.failed(Self.unknown)
        }
        try stillCurrent(login)
        repeat { reconciling: while let pending = ledger.pending {
            let verdict = await verdict(on: pending)
            // The read waited on the guest: a sign-out meanwhile makes it about a login that has
            // gone, and a record that moved meanwhile is read again.
            try stillCurrent(login)
            guard ledger.pending == pending else { continue reconciling }
            switch Reconciliation.of(pending, verdict: verdict, request: request.nonce) {
            case .clear:
                try record(nil)
            case .answered(let text):
                // The ledger keeps the input until the reply is in the log (`landed`).
                provenance[request.nonce] = (pending.session, nil)
                ledger.pending?.state = .answered
                ledger.pending?.text = text
                try? save()
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
                throw GuestBridgeError.failed(Self.unknown)
            }
            break reconciling
        } } while promote()

        // Words given ahead whose turn this request shows in the log some other way — answered
        // by another device, moved past, or one head of a fork: the guest received them, so they
        // are not told again, and the reply it made of them is not written.
        // They leave the ledger when the reply to the input that counts them lands: an input
        // that is never received, or never answered, leaves them to be found again.
        let passed = passed(in: request.context + request.answering)
        received.formUnion(passed.received)

        await conversation.use(model: ClaudeModel.effective(request.model).rawValue)
        Perf.mark("turn.bridge.begin")
        try await conversation.ready()
        Perf.mark("turn.bridge.guestReady")
        let session = await conversation.sessionID()
        let fresh = session == nil || session != ledger.session
        if fresh {
            // A fresh session, or another one than the ledger's, has seen none of the log.
            ledger.session = session
            ledger.seen = Coverage()
            received = Coverage()
        }
        // What inputs still waiting on their turns told this session is not told again.
        let waiting = fresh ? Coverage() : outstanding()
        let unseen = request.context.filter {
            !ledger.seen.contains($0.ref) && !received.contains($0.ref) && !waiting.contains($0.ref)
        }
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
                                       session: session, sentAt: Date(), state: .sent,
                                       said: request.answering.map(\.nonce), passed: Array(passed.inputs)))
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
                // After a sign-out the ledger is the next login's, and the session is not.
                guard self.login == login else { break }
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

        // The turn ran while nothing held the actor: a sign-out meanwhile makes whatever it came
        // to a login's that has gone. Nothing is recorded — the ledger went with the login — and
        // no reply is handed to the runner to write.
        guard self.login == login else { throw CancellationError() }
        guard let end else {
            // This task stopped listening — cancelled — with the turn still the guest's. Nothing
            // is known of it: the record stays as it was sent, and the next request reads the
            // transcript once the guest's turn is over (`settle`).
            throw CancellationError()
        }
        if case .answered(let result) = end {
            if ledger.pending?.input == id {
                ledger.pending?.state = .answered
                ledger.pending?.text = result.text ?? ""
                try? save()
            }
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
        // Anything else is read off the transcript once nothing can still be writing it.
        let final = await conversation.settle()
        guard self.login == login else { throw CancellationError() }
        guard let pending = ledger.pending, pending.input == id else { throw GuestBridgeError.failed(Self.describe(end)) }
        // A process not confirmed gone may still be writing: the record stays, and the next
        // request reads again.
        guard final else { throw GuestBridgeError.failed(Self.unknown) }
        switch GuestTranscript.verdict(for: id, home: conversation.home, session: pending.session, since: pending.sentAt) {
        case .notReceived:
            try? record(nil)
            throw GuestBridgeError.failed(Self.describe(end))
        case .answered(let text):
            ledger.pending?.state = .answered
            ledger.pending?.text = text
            try? save()
            return reply(text, to: request, usage: usage, model: model)
        case .unresolved:
            ledger.pending?.state = .unresolved
            try? save()
            throw GuestBridgeError.unresolved
        case .unreadable:
            // The record stays: the next request reads again before it sends anything.
            throw GuestBridgeError.failed(Self.unknown)
        }
    }

    /// Why a turn waits when the guest's transcript could not be read, or the process the turn
    /// went to is not confirmed gone, so its transcript may still be being written.
    static let unknown = "whether the guest received the turn is not known yet (its transcript could not be read, or may still be being written); nothing is sent until it is"

    /// Why a turn waits when the bridge's own ledger could not be read.
    static let ledgerUnreadable = "the record of what the guest was sent could not be read, so whether it received the turn is not known; nothing is sent until it can be"

    func landed(_ reply: Turn, nonce: String) async {
        // Unread, the ledger stays as it is on disk; the reply is in the log under its nonce, and
        // the record is reconciled against it once the ledger can be read.
        guard readLedger() else { return }
        let waiting = ledger.early?.firstIndex { $0.bound?.nonce == nonce }
        let held = ledger.pending?.nonce == nonce ? ledger.pending : nil
        guard let pending = held ?? waiting.flatMap({ ledger.early?[$0].bound }) else { return }
        // What the input covered is seen only once the guest is known to have received it: it
        // answered, or read it and was cut off. A reply another device wrote under the nonce, for
        // an input whose fate here is not known, settles the request and counts nothing, so
        // those turns go with the next input rather than never. The reply is seen only when it is
        // the guest's own.
        // An input that went to a session the guest has since left told this one nothing.
        let current = pending.session == nil || ledger.session == nil || pending.session == ledger.session
        if pending.state != .sent, current {
            ledger.seen.formUnion(pending.covers)
            if let session = pending.session { ledger.session = session }
        }
        // Another device's reply under the same nonce is not what the guest wrote, and is told.
        if pending.state == .answered, current, pending.text == nil || pending.text == reply.text { ledger.seen.insert([reply.ref]) }
        settle(pending.said ?? [])
        if pending.state != .sent, let passed = pending.passed { ledger.early?.removeAll { passed.contains($0.input) && $0.bound == nil } }
        flown[pending.input] = nil
        if held != nil { ledger.pending = nil } else if let waiting { ledger.early?.remove(at: waiting) }
        // The next input bound and waiting for the slot takes it.
        promote()
        try? save()
    }

    func unresolved() async -> Set<TurnRef> {
        guard readLedger(), let pending = ledger.pending, pending.state == .unresolved, !pending.askAgain else { return [] }
        return Set(pending.answering)
    }

    func owed() async -> OwedReply? {
        guard readLedger() else { return nil }
        promote()
        guard let pending = ledger.pending else { return nil }
        // An answer already known is owed as it stands, with no read of the guest's transcript
        // and so no wait for the slot: a later input given ahead may be holding it, and the
        // reply owed is written before that one's turn all the same.
        if pending.state == .answered, let text = pending.text {
            return OwedReply(parents: pending.parents, nonce: pending.nonce, text: text)
        }
        guard !asking else { return nil }
        let login = self.login
        // The read waits on the guest; holding the requests' one slot while it does keeps any
        // request from reconciling or replacing the record meanwhile.
        asking = true
        defer { release() }
        let verdict = await verdict(on: pending)
        // A sign-out while the transcript was waited for leaves nothing owed: the reply was the
        // last login's, and it is never written after it.
        guard self.login == login, ledger.pending == pending else { return nil }
        switch Reconciliation.of(pending, verdict: verdict, request: nil) {
        case .clear:
            try? record(nil)
        case .owed(let owed):
            ledger.pending?.state = .answered
            ledger.pending?.text = owed.text
            try? save()
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

    // MARK: - Words given ahead of their turn

    func hear(_ words: String, nonce: String, context: [Turn]?, model: ClaudeModel) async -> Bool {
        // A second call for a nonce being heard waits for the first's answer and sends nothing.
        if hearing[nonce] != nil {
            return await withCheckedContinuation { hearing[nonce]?.append($0) }
        }
        hearing[nonce] = []
        let heard = await begin(words, nonce: nonce, context: context, model: model)
        stopping.remove(nonce)
        (hearing.removeValue(forKey: nonce) ?? []).forEach { $0.resume(returning: heard) }
        return heard
    }

    /// Gives the guest the words, recorded first, and leaves its turn on them to `fly`. False,
    /// with nothing sent, whenever the ledger cannot say the guest is free to be given them: a
    /// read that failed, an input outstanding whose end is not known or that was cut off. The
    /// turn is then asked by `answer` once it is saved, which reconciles as it always has.
    private func begin(_ words: String, nonce: String, context known: [Turn]?, model: ClaudeModel) async -> Bool {
        let login = self.login
        let context = known ?? []
        guard readLedger() else { return false }
        if holds(nonce), !adrift(nonce) { return true }
        // Words whose turn the log already holds are asked as any turn in the log is: an input
        // for them may have gone and landed before, and is not sent a second time from here.
        // Without a read to show it, the ledger's own memory of the replies that landed says so.
        guard !context.contains(where: { $0.role == .person && $0.nonce == nonce }),
              ledger.settled?.contains(nonce) != true else { return false }
        if asking { await withCheckedContinuation { queue.append($0) } }
        asking = true
        var flying = false
        defer { if !flying { release() } }
        guard self.login == login, !stopping.contains(nonce), readLedger() else { return false }
        // An input a killed launch left with its end unknown is read off the transcript first:
        // one the guest never received is sent now, and not held as heard.
        guard await settleEarly(), self.login == login, !stopping.contains(nonce) else { return false }
        if holds(nonce) { return true }
        guard ledger.settled?.contains(nonce) != true else { return false }
        promote()
        // Words cut off ahead of their turn wait for the person, as a cut-off turn does.
        guard ledger.early?.contains(where: { $0.state == .unresolved }) != true else { return false }
        if let pending = ledger.pending, pending.state != .answered {
            guard pending.state == .sent else { return false }
            let verdict = await verdict(on: pending)
            guard self.login == login, ledger.pending == pending else { return false }
            switch Reconciliation.of(pending, verdict: verdict, request: nil) {
            case .clear:
                guard (try? record(nil)) != nil else { return false }
            case .owed(let owed):
                ledger.pending?.state = .answered
                ledger.pending?.text = owed.text
                try? save()
            default:
                return false
            }
        }

        await conversation.use(model: ClaudeModel.effective(model).rawValue)
        Perf.mark("turn.bridge.begin")
        guard (try? await conversation.ready()) != nil else { return false }
        Perf.mark("turn.bridge.guestReady")
        let session = await conversation.sessionID()
        guard self.login == login, !stopping.contains(nonce) else { return false }
        let fresh = session == nil || session != ledger.session
        // A session with nothing of the conversation in it, and no read of the log to tell it:
        // the words wait for the read rather than be answered by a guest that knows none of it.
        // One that has its own conversation to go on is told what it has missed with a later input.
        guard !(fresh && known == nil) else { return false }
        if fresh {
            ledger.session = session
            ledger.seen = Coverage()
        }
        let waiting = fresh ? Coverage() : outstanding()
        // A turn the guest was given ahead as words is not told back to it as another device's.
        let given = fresh ? [] : Set((ledger.early ?? []).filter { $0.state != .sent || flights[$0.input] != nil }.map(\.person))
        let unseen = context.filter {
            !ledger.seen.contains($0.ref) && !waiting.contains($0.ref) && !($0.role == .person && given.contains($0.nonce))
        }
        let told = fresh ? Array(unseen.suffix(Self.contextLimit)) : unseen
        let input = Self.render(unseen: told, words: words, fresh: fresh && !told.isEmpty)
        // What the guest was told, and nothing the log came to hold after `context` was read:
        // that goes with a later input.
        var covers = Coverage(told.map(\.ref))
        if fresh { covers.insert(context.map(\.ref)) }
        let id = UUID().uuidString.lowercased()
        // Written before the input goes: after a crash this is how the transcript is asked.
        ledger.early = (ledger.early ?? []) + [GuestLedger.Early(person: nonce, input: id, covers: covers, session: session,
                                                                 sentAt: Date(), state: .sent)]
        guard (try? save()) != nil else {
            ledger.early?.removeAll { $0.input == id }
            return false
        }
        let pid = await conversation.residentPID()
        guard self.login == login, !stopping.contains(nonce) else {
            if self.login == login { drop(id) }
            return false
        }
        let updates: AsyncStream<GuestSession.TurnUpdate>
        do {
            updates = try await conversation.send(input, id: id)
        } catch {
            // Refused before anything was written: not received.
            if self.login == login { drop(id) }
            return false
        }
        flying = true
        flights[id] = Task { await self.fly(id, person: nonce, updates: updates, pid: pid, login: login) }
        return true
    }

    /// The guest's turn on an input given ahead, followed to its end whoever is or is not
    /// waiting for it, and concluded onto whichever record holds the input by then: the one made
    /// when it was heard, or the bound one. The rules are `answer`'s own.
    private func fly(_ id: String, person nonce: String, updates: AsyncStream<GuestSession.TurnUpdate>,
                     pid: Int32?, login: Int) async {
        await heardObserver(.began(nonce))
        await observe(.began(pid: pid, answering: []))
        var model: String?, usage: StreamEvent.Usage?, end: GuestSession.TurnEnd?
        for await update in updates {
            await observe(.update(update))
            switch update {
            case .event(.started(let started, let startedModel)):
                model = startedModel
                // After a sign-out the ledger is the next login's, and the session is not.
                guard self.login == login else { break }
                if ledger.pending?.input == id { ledger.pending?.session = started }
                if let index = ledger.early?.firstIndex(where: { $0.input == id }) {
                    ledger.early?[index].session = started
                    ledger.early?[index].bound?.session = started
                }
                // A session begun by this input is the one the next is given to.
                if ledger.session == nil, whereabouts(of: id) != nil { ledger.session = started }
                try? save()
            case .event(.usage(let reported)):
                usage = reported
            case .ended(let ended):
                end = ended
            case .event:
                break
            }
        }
        await observe(.gone(answering: []))
        var reply: String?
        // A sign-out meanwhile makes whatever the turn came to a login's that has gone.
        if self.login == login {
            flown[id] = (model, usage)
            switch end {
            case .answered(let result):
                reply = result.text ?? ""
                conclude(id, .answered, text: reply)
            case .failed(.result):
                // Claude Code's own word that it received the turn and ended it unanswered.
                conclude(id, .unresolved)
            case nil:
                // The stream ended with no end said: nothing is known, and the record stays.
                break
            default:
                // Anything else is read off the transcript once nothing can still be writing it.
                let final = await conversation.settle()
                if self.login == login, final, let (session, sentAt) = whereabouts(of: id) {
                    switch GuestTranscript.verdict(for: id, home: conversation.home, session: session, since: sentAt) {
                    case .notReceived: drop(id)
                    case .answered(let text):
                        reply = text
                        conclude(id, .answered, text: text)
                    case .unresolved: conclude(id, .unresolved)
                    case .unreadable: break
                    }
                }
            }
        }
        let kept = self.login == login && whereabouts(of: id) != nil
        flights[id] = nil
        release()
        // Words taken back while the guest was on them have no record, and no reply to draw.
        if self.login == login { await heardObserver(.ended(nonce, reply: kept ? reply : nil)) }
    }

    func bind(nonce: String, person: Turn, reply: String) async {
        // Words on their way to the guest are recorded, or refused, before their turn is bound:
        // a bind that ran ahead of the record would leave `answer` to send them a second time.
        if hearing[nonce] != nil { _ = await withCheckedContinuation { hearing[nonce]?.append($0) } }
        guard readLedger(), let index = ledger.early?.firstIndex(where: { $0.person == nonce }),
              let early = ledger.early?[index] else { return }
        // What the input told, and the turn it answers: nothing the log holds besides, since the
        // guest was told none of it.
        var covers = early.covers
        covers.insert([person.ref])
        let bound = GuestLedger.Pending(input: early.input, nonce: reply, parents: [person.ref], answering: [person.ref],
                                        covers: covers, session: early.session, sentAt: early.sentAt, state: early.state,
                                        text: early.text, person: nonce, said: [nonce])
        promote()
        // The list may have moved: the input is found again by its uuid.
        guard let index = ledger.early?.firstIndex(where: { $0.input == early.input }) else { return }
        if ledger.pending == nil {
            ledger.early?.remove(at: index)
            ledger.pending = bound
        } else {
            // Another reply is still owed the log: this one takes the slot when that lands.
            ledger.early?[index].bound = bound
        }
        try? save()
    }

    func stopHearing(nonce: String) async {
        if hearing[nonce] != nil { stopping.insert(nonce) }
    }

    func withdrawn(nonce: String) async {
        await stopHearing(nonce: nonce)
        // A bound input's turn is in the log, and what is in the log is said.
        guard readLedger(), ledger.early?.contains(where: { $0.person == nonce && $0.bound == nil }) == true else { return }
        ledger.early?.removeAll { $0.person == nonce && $0.bound == nil }
        try? save()
    }

    /// The nonces among `unsaved()` whose turns are saved and whose replies this device owes
    /// the log: written by the next pass whatever the log has gone on to hold.
    func owedAhead() -> Set<String> {
        guard readLedger() else { return [] }
        // The one in `pending`, and those bound and waiting behind it.
        var owed = Set((ledger.early ?? []).filter { $0.bound != nil && $0.state == .answered }.map(\.person))
        if let pending = ledger.pending, pending.state == .answered, let person = pending.person { owed.insert(person) }
        return owed
    }

    /// The guest's replies to words given ahead that the log does not hold yet, by the person's
    /// nonce: what the screen draws under those words until their turns land.
    func unsaved() -> [String: String] {
        guard readLedger() else { return [:] }
        var replies: [String: String] = [:]
        for early in ledger.early ?? [] where early.state == .answered { replies[early.person] = early.text }
        if let pending = ledger.pending, pending.state == .answered, let person = pending.person { replies[person] = pending.text }
        return replies
    }

    /// Whether the guest was given the words said under `nonce` and their reply is not in the log.
    private func holds(_ nonce: String) -> Bool {
        // An input asked once its turn was saved is the guest's as much as one given ahead.
        ledger.pending?.said?.contains(nonce) == true || ledger.pending?.person == nonce || ledger.early?.contains { $0.person == nonce } == true
    }

    /// The inputs given ahead, and not bound, whose turns are among `turns`: the log holds them
    /// some other way, and they leave `early` when the reply to the input that counts them lands. With them, what the guest's session
    /// received of them, to be counted seen with the input that follows; an input that went to
    /// a session the guest has since left told this one nothing.
    private func passed(in turns: [Turn]) -> (inputs: Set<String>, received: Coverage) {
        var received = Coverage(), inputs: Set<String> = []
        for early in ledger.early ?? [] where early.bound == nil {
            guard let turn = turns.first(where: { $0.role == .person && $0.nonce == early.person }) else { continue }
            if early.state != .sent, early.session == nil || early.session == ledger.session {
                received.formUnion(early.covers)
                received.insert([turn.ref])
            }
            inputs.insert(early.input)
            settle([early.person])
        }
        return (inputs, received)
    }

    /// Whether the input for `nonce` is one a killed launch left unbound with its end unknown.
    private func adrift(_ nonce: String) -> Bool {
        ledger.early?.contains { $0.person == nonce && $0.state == .sent && flights[$0.input] == nil } == true
    }

    /// Remembers that the replies to the turns said under `nonces` are settled in the log.
    private func settle(_ nonces: [String]) {
        guard !nonces.isEmpty else { return }
        ledger.settled = Array(((ledger.settled ?? []).filter { !nonces.contains($0) } + nonces).suffix(GuestLedger.settledLimit))
    }

    /// What the inputs whose replies are not in the log yet told the guest: seen by this session
    /// already, though counted seen only when each lands.
    private func outstanding() -> Coverage {
        var told = Coverage()
        let here = { (session: String?) in session == nil || session == self.ledger.session }
        for early in ledger.early ?? [] where here(early.session) { told.formUnion(early.bound?.covers ?? early.covers) }
        if let pending = ledger.pending, pending.state == .answered, here(pending.session) { told.formUnion(pending.covers) }
        return told
    }

    /// The first input bound and waiting takes `pending` when nothing holds it.
    @discardableResult
    private func promote() -> Bool {
        guard ledger.pending == nil, let index = ledger.early?.firstIndex(where: { $0.bound != nil }) else { return false }
        ledger.pending = ledger.early?[index].bound
        ledger.early?.remove(at: index)
        try? save()
        return true
    }

    /// Reads what became of each input given ahead whose end no task of this launch is following
    /// (the app was killed with the guest on it), off the guest's transcript. False when one
    /// cannot be known yet: nothing is sent until it can.
    private func settleEarly() async -> Bool {
        while let early = ledger.early?.first(where: { $0.state == .sent && flights[$0.input] == nil }) {
            let login = self.login
            guard await conversation.settle(), self.login == login else { return false }
            switch GuestTranscript.verdict(for: early.input, home: conversation.home, session: early.session, since: early.sentAt) {
            case .unreadable: return false
            case .notReceived: drop(early.input)
            case .answered(let text): conclude(early.input, .answered, text: text)
            case .unresolved: conclude(early.input, .unresolved)
            }
            // A record that would not change is one the disk refused: nothing more is known.
            if ledger.early?.contains(early) == true { return false }
        }
        return true
    }

    /// Writes what became of the input `id` onto whichever record holds it.
    private func conclude(_ id: String, _ state: GuestLedger.Pending.State, text: String? = nil) {
        if ledger.pending?.input == id {
            ledger.pending?.state = state
            ledger.pending?.text = text
        }
        if let index = ledger.early?.firstIndex(where: { $0.input == id }) {
            ledger.early?[index].state = state
            ledger.early?[index].text = text
            ledger.early?[index].bound?.state = state
            ledger.early?[index].bound?.text = text
        }
        try? save()
    }

    /// The input `id` was never received: its record goes, and nothing it carried is counted.
    private func drop(_ id: String) {
        if ledger.pending?.input == id { ledger.pending = nil }
        ledger.early?.removeAll { $0.input == id }
        try? save()
    }

    private func whereabouts(of id: String) -> (session: String?, sentAt: Date)? {
        if let pending = ledger.pending, pending.input == id { return (pending.session, pending.sentAt) }
        return ledger.early?.first { $0.input == id }.map { ($0.session, $0.sentAt) }
    }

    func forget() async {
        login += 1
        flown = [:]
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
            switch pending.state {
            case .sent: parts.append("a turn with the guest")
            case .answered: parts.append("a reply from the guest still to be written")
            case .unresolved: parts.append("a turn cut off, waiting to be asked again")
            }
        }
        if let early = ledger.early, !early.isEmpty {
            parts.append("\(early.count) said ahead of iCloud, waiting to be saved")
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

    /// Hands the requests' one slot to the next waiting, if there is one, so nothing slips in
    /// between.
    private func release() {
        if queue.isEmpty { asking = false } else { queue.removeFirst().resume() }
    }

    /// What the guest's transcript says became of `pending`, read only once nothing the guest is
    /// doing can still write it (`settle`): `unreadable`, nothing known, while the last process
    /// ended is not confirmed gone.
    private func verdict(on pending: GuestLedger.Pending) async -> GuestTranscript.Verdict {
        guard await conversation.settle() else { return .unreadable }
        return GuestTranscript.verdict(for: pending.input, home: conversation.home, session: pending.session,
                                       since: pending.sentAt)
    }

    private func reply(_ text: String, to request: BrainRequest, usage: StreamEvent.Usage?, model: String?) -> Reply {
        recent.removeAll { $0.nonce == request.nonce }
        recent.append((request.nonce, text))
        if recent.count > 16 { recent.removeFirst(recent.count - 16) }
        return Reply(text: text, model: model ?? ClaudeModel.effective(request.model).rawValue,
                     context: usage?.context ?? 0, outputTokens: usage?.output ?? 0)
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
        render(unseen: unseen, words: answering.map(\.text).joined(separator: "\n\n"), fresh: fresh)
    }

    static func render(unseen: [Turn], words: String, fresh: Bool) -> String {
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
