import CryptoKit
import Foundation
import TopoCore

public enum TurnRunnerError: Error {
    /// This device does not hold the primary lease; the outcome says who does.
    case notPrimary(LeaseOutcome)
    /// Another device took the lease while the model was answering. The person's turn is in the
    /// log, the reply is not: whoever is primary now answers it. A lease that only lapsed, its
    /// heartbeats late and nobody else claiming, is not this: the reply's batch claims it afresh.
    case displaced
    /// The person's turn is in the log and the reply is not; `underlying` says why (an API
    /// error, or `displaced`). The caller keeps `person` and owes nothing for it.
    case replyFailed(person: Turn, underlying: any Error)
    /// The person's turn is not in the log, `underlying` says why, and the brain has the words
    /// all the same (`hear`): it is answering them, and the reply is written by the attempt under
    /// the same nonce that gets the turn into the log.
    case unsaved(underlying: any Error)
}

/// A probe for a device with no socket yet: every holder looks unreachable, so a live holder
/// elsewhere is claimed over on the first turn. The lease's own rules bound the damage: the
/// displaced holder yields on its next heartbeat and waits a duration before claiming back.
public struct NoSocketProbe: LeaseProbe {
    public init() {}
    public func confirms(_ lease: Lease) async -> Bool { false }
}

/// The phone harness: one turn from the person's words to the assistant's reply, both in the log.
///
/// The brain is started on the person's words first (`hear`), so its answer waits on nothing
/// CloudKit does; the lease is taken and the person's turn appended while it answers, and the
/// turn's writes are made only as the lease's holder. A failed call leaves the words in the log
/// and the next turn carries on from them; the reply is appended as a child of the person's turn in one atomic
/// batch with a heartbeat of the lease, so a device displaced during a long call, or in the moment
/// between the reply arriving and its write, does not write a second brain's answer.
///
/// A reply's nonce is derived from the turns it answers (`replyNonce(for:)`), so the marker the
/// writer saves with it is the same on every device: a retry after a lost acknowledgement, and a
/// second primary answering the same words inside the lease's two-brain window, both find the
/// reply already written rather than writing another. `answerPending` is the log's own path for a
/// limb's words, with no socket to the primary: the limb appends the person's turn and the
/// primary finds and answers it here.
///
/// What answers is a `Brain`, the one seam: the runner builds the request, the brain returns the
/// reply, and the runner writes it. A brain holding a reply the log does not (one it finished just
/// before the app was killed) has it written first, under its own nonce; a person turn the brain
/// holds as unresolved is not answered by `answerPending`; and the brain hears every reply of its
/// requests that is in the log, whichever way it got there.
///
/// A caller that is cancelled writes nothing from then on: the task is checked immediately before
/// the person's turn and each reply is appended, which is how a sign-out stops a turn or a pass
/// already under way.
public actor TurnRunner {
    public struct Result: Sendable {
        public var person: Turn
        public var assistant: Turn
        public var reply: Reply
    }

    private let log: TurnLog
    private let writer: TurnWriter
    private let lease: PrimaryLease
    private let brain: any Brain
    /// Where this device stood when it last asked the lease.
    public private(set) var standing: Standing
    /// True when the last call to the lease failed: iCloud is away, and so is whatever held the
    /// lease, as far as this device can tell. The person is typing here, so this device answers:
    /// the brain hears every turn at once until a call to the lease gets through.
    private var away = false

    /// What a device knows of the lease from the last time it asked: nothing yet, that it held
    /// it, or that another device did.
    public enum Standing: String, Sendable {
        case unknown, mine, elsewhere
    }

    /// `standing` is what the device knew when it last ran, for a launch that kept it.
    public init(log: TurnLog, writer: TurnWriter, lease: PrimaryLease, brain: any Brain, standing: Standing = .unknown) {
        self.standing = standing
        self.log = log
        self.writer = writer
        self.lease = lease
        self.brain = brain
    }

    /// Where a turn is, told to the caller as it goes, so a screen never shows nothing while
    /// CloudKit or the model takes its time.
    public enum Progress: Sendable, Equatable {
        /// The brain has the words, ahead of everything below.
        case heard
        case takingLease
        case saving
        /// The person's turn is in the log; the model has it now.
        case asking(person: Turn)
        case savingReply
    }

    /// `nonce` names the append of the person's turn; a caller that keeps it and passes the same
    /// one again after a failure gets the turn already in the log rather than a second copy.
    /// `progress` is called at each step, on no particular actor. `known` is the log as the
    /// caller last read it, nil when it has not: with it the brain hears the words before
    /// anything is asked of CloudKit (`hear`).
    public func run(_ text: String, model: ClaudeModel, nonce: String = UUID().uuidString, known: [Turn]? = nil,
                    progress: (@Sendable (Progress) async -> Void)? = nil) async throws -> Result {
        Perf.mark("turn.begin")
        // The brain hears the words in a task of its own, so the lease and the save do not wait
        // for it to be ready, nor it for them.
        let brain = self.brain
        let hearNow: @Sendable () -> Task<Bool, Never> = {
            Task {
                let heard = await brain.hear(text, nonce: nonce, context: known, model: model)
                if heard { Perf.mark("turn.heard") }
                return heard
            }
        }
        // With no read of the log to go on, the turn is asked once it is saved, as a turn in the
        // log is, and the brain is told everything the log holds that it has not seen.
        var hearing: Task<Bool, Never>? = hearsAhead && known != nil ? hearNow() : nil
        await progress?(hearing == nil ? .takingLease : .heard)
        let before: Transcript, person: Turn
        let at = Date()
        do {
            // The log is read while the lease is taken: the read asks nothing of the lease, and
            // nothing is done with it unless this device holds it.
            async let reading = log.read()
            let outcome: LeaseOutcome
            do {
                outcome = try await acquire()
            } catch {
                // The lease could not be asked, within its own bound: whoever held it is as far
                // away as iCloud is, and the person is typing here, so the brain hears the words.
                if hearing == nil, known != nil, !(error is CancellationError), !Task.isCancelled { hearing = hearNow() }
                throw error
            }
            Perf.mark("turn.lease.acquired")
            guard case .primary = outcome else { throw TurnRunnerError.notPrimary(outcome) }
            // A caller that stopped while the lease was asked — a sign-out — gives the brain nothing.
            try Task.checkCancellation()
            if hearing == nil {
                if known != nil { hearing = hearNow() }
                await progress?(.saving)
            }

            var read = try await reading
            // An owed reply moved the log; what the turn continues from is read again.
            if try await settleOwed() != nil { read = try await log.read() }
            Perf.mark("turn.log.read")
            // A caller that stopped before the person's turn is in the log writes nothing at all.
            try Task.checkCancellation()
            person = try await writer.append(.person, text, continuing: read, at: at, nonce: nonce, justRead: true)
            before = read
        } catch {
            if case TurnRunnerError.notPrimary = error { throw error }
            guard !(error is CancellationError), await hearing?.value == true else { throw error }
            Perf.mark("turn.unsaved \(Self.kind(of: error))")
            throw TurnRunnerError.unsaved(underlying: error)
        }
        // The words are recorded with the brain, or it did not take them, before the turn is
        // bound: a bind that ran ahead of the record would leave `answer` to ask a second time.
        _ = await hearing?.value
        Perf.mark("turn.person.saved")
        let replyNonce = Self.replyNonce(for: [person.ref])
        // Before anything looks for the reply: a reply found landed is told to the brain by its
        // nonce, which the words it heard carry only from here.
        await brain.bind(nonce: nonce, person: person, reply: replyNonce)
        await progress?(.asking(person: person))
        if person.at != at {
            // A retry: the person's turn was written by an earlier attempt. If that attempt also
            // got its reply into the log before it was cut off, that is the reply.
            if let answered = try await log.turn(appendedUnder: replyNonce) {
                await brain.landed(answered, nonce: replyNonce)
                return Result(person: person, assistant: answered, reply: Reply(recovered: answered, model: model))
            }
        }
        do {
            // On a retry `before` already holds the recovered person turn; it is asked once.
            let request = BrainRequest(context: before.ordered.filter { $0.ref != person.ref }, answering: [person],
                                       parents: [person.ref], nonce: replyNonce, model: model)
            let reply = try await brain.answer(request)
            Perf.mark("turn.brain.answered")
            await progress?(.savingReply)
            // A caller that stopped — a sign-out cancels the turn in flight — writes nothing more.
            try Task.checkCancellation()
            // The reply and a heartbeat of the lease are one atomic batch: a claim made during
            // the call, or between the call and this write, refuses the batch and nothing lands.
            guard let assistant = try await writer.append(.assistant, reply.text, parents: [person.ref],
                                                          nonce: replyNonce, renewing: lease) else {
                // Another device took the lease: it answers from here, and nothing is heard ahead of it.
                standing = .elsewhere
                throw TurnRunnerError.displaced
            }
            Perf.mark("turn.reply.saved")
            await brain.landed(assistant, nonce: replyNonce)
            return Result(person: person, assistant: assistant, reply: reply)
        } catch {
            // The kind of failure and nothing it carries.
            if case TurnRunnerError.displaced = error { Perf.mark("turn.reply.failed displaced") }
            else { Perf.mark("turn.reply.failed \(Self.kind(of: error))") }
            throw TurnRunnerError.replyFailed(person: person, underlying: error)
        }
    }

    /// Starts the brain on the person's words, said under `nonce`, before their turn is in the
    /// log, and answers whether it has them; `run` under the same nonce saves the turn and writes
    /// the reply the brain is already on. Only a device that is the one answering hears ahead of
    /// the lease (`hearsAhead`); any other is heard by its `run`, once the lease has answered or
    /// could not be asked. `known` is the log as the caller last read it; with none, nothing is heard.
    /// Hearing the same nonce again asks nothing more.
    @discardableResult
    public func hear(_ text: String, model: ClaudeModel, nonce: String, known: [Turn]?) async -> Bool {
        guard hearsAhead, let known else { return false }
        let heard = await brain.hear(text, nonce: nonce, context: known, model: model)
        if heard { Perf.mark("turn.heard") }
        return heard
    }

    /// Whether the brain hears words before the lease is asked: this device held the lease when
    /// it last asked, or the lease could not be asked at all. A device that found another holding
    /// it, or has not asked since it launched, asks first: the call is bounded
    /// (`LeaseTiming.patience` a request), and the brain hears as soon as it is answered primary
    /// or fails.
    private var hearsAhead: Bool { away || standing == .mine }

    /// The lease's `acquire()`, with what it found of another holder kept for `hear`.
    private func acquire() async throws -> LeaseOutcome {
        let outcome: LeaseOutcome
        do {
            outcome = try await lease.acquire()
        } catch {
            if !(error is CancellationError) { away = true }
            throw error
        }
        away = false
        switch outcome {
        case .primary: standing = .mine
        case .held, .unreachable: standing = .elsewhere
        case .contended: break
        }
        return outcome
    }

    /// A failure's kind for a mark: the error's type, a database error's case and the record it
    /// names, and the underlying error's domain and code. Nothing a record holds.
    static func kind(of error: any Error) -> String {
        func code(_ underlying: any Error) -> String { "\((underlying as NSError).domain)/\((underlying as NSError).code)" }
        switch error {
        case RecordDatabaseError.serverRecordChanged(let id, _): return "serverRecordChanged \(id.name)"
        case RecordDatabaseError.unknownItem(let id): return "unknownItem \(id.name)"
        case RecordDatabaseError.unavailable(let underlying): return "unavailable \(code(underlying))"
        case RecordDatabaseError.rejected(let underlying): return "rejected \(code(underlying))"
        default: return "\(type(of: error))"
        }
    }

    /// Answers the log as it stands, if its newest turns include a person's turn with no reply:
    /// one reply continuing every head, so a fork is joined rather than answered twice. Nothing
    /// waiting, or a read with turns still missing, returns nil without touching the lease; the
    /// caller reads again later. Otherwise this device takes the lease, and runs only as primary.
    ///
    /// A head the brain holds as unresolved is not answered: it was asked once and cut off, and
    /// only the person asks again. A reply the brain owes the log is written first, and is
    /// written even when no person's turn waits.
    ///
    /// Returns the reply this pass brought: the one it asked for, that reply found already in
    /// the log under its nonce, or, with nothing left to ask, the owed one it wrote. Nil when
    /// there was none.
    public func answerPending(model: ClaudeModel) async throws -> Turn? {
        var transcript = try await log.read()
        guard transcript.isComplete else { return nil }
        // An owed reply is written whatever the head is: another device may have answered past
        // the turn it belongs to, and nothing else would ever write it.
        let waiting = Self.awaitsReply(transcript, skipping: await brain.unresolved())
        if !waiting {
            guard await brain.owed() != nil else { return nil }
        }
        let outcome = try await acquire()
        guard case .primary = outcome else { throw TurnRunnerError.notPrimary(outcome) }
        let settled = try await settleOwed()
        if settled != nil {
            // The owed reply moved the log; what waits is read again.
            transcript = try await log.read()
        }
        let unresolved = await brain.unresolved()
        guard transcript.isComplete, Self.awaitsReply(transcript, skipping: unresolved) else { return settled }
        let nonce = Self.replyNonce(for: transcript.heads)
        // A head this device's brain heard before it was saved, and that reached the log some
        // other way (a limb's write, a crash before the bind): its reply is the one heard.
        // Only as the log's one head: beside another the reply answers a fork, under its nonce.
        if transcript.heads.count == 1, let person = transcript.heads.first.flatMap({ transcript[$0] }), person.role == .person {
            await brain.bind(nonce: person.nonce, person: person, reply: nonce)
        }
        if let answered = try await log.turn(appendedUnder: nonce) {
            await brain.landed(answered, nonce: nonce)
            return answered
        }
        let skipped = await brain.unresolved()
        let answering = transcript.heads.compactMap { transcript[$0] }
            .filter { $0.role == .person && !skipped.contains($0.ref) }
        // Settling what was owed can find the waiting turn cut off: nothing is left to answer.
        guard !answering.isEmpty else { return settled }
        let request = BrainRequest(context: transcript.ordered.filter { turn in !answering.contains { $0.ref == turn.ref } },
                                   answering: answering, parents: transcript.heads, nonce: nonce, model: model)
        let reply = try await brain.answer(request)
        // A pass that was stopped — a sign-out cancels the one in flight — writes nothing.
        try Task.checkCancellation()
        guard let assistant = try await writer.append(.assistant, reply.text, continuing: transcript,
                                                      nonce: nonce, renewing: lease) else {
            // Another device took the lease: it answers from here, and nothing is heard ahead of it.
            standing = .elsewhere
            throw TurnRunnerError.displaced
        }
        await brain.landed(assistant, nonce: nonce)
        return assistant
    }

    /// Writes the reply the brain owes the log, if it owes one, and returns it: the log moved.
    /// Found already there under its nonce — another primary's, or this device's own write whose
    /// acknowledgement was lost — it is not written again and nil is returned; the brain hears
    /// where it is either way.
    @discardableResult
    private func settleOwed() async throws -> Turn? {
        guard let owed = await brain.owed() else { return nil }
        if let there = try await log.turn(appendedUnder: owed.nonce) {
            await brain.landed(there, nonce: owed.nonce)
            return nil
        }
        try Task.checkCancellation()
        guard let turn = try await writer.append(.assistant, owed.text, parents: owed.parents,
                                                 nonce: owed.nonce, renewing: lease) else {
            // Another device took the lease: it answers from here, and nothing is heard ahead of it.
            standing = .elsewhere
            throw TurnRunnerError.displaced
        }
        await brain.landed(turn, nonce: owed.nonce)
        return turn
    }

    /// True when a head of the transcript is the person's, and not one of `skipping`: words
    /// nobody has answered.
    static func awaitsReply(_ transcript: Transcript, skipping: Set<TurnRef> = []) -> Bool {
        transcript.heads.contains { transcript[$0]?.role == .person && !skipping.contains($0) }
    }

    /// The nonce of the reply to these turns, the same on every device: `answer/` and the SHA-256
    /// of the refs in sorted order, so its length is fixed however wide a fork it answers (the
    /// marker's record name carries it, and CloudKit caps a record name at 255 characters).
    public static func replyNonce(for heads: [TurnRef]) -> String {
        let canonical = heads.sorted().map(\.description).joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return "answer/" + digest.map { String(format: "%02x", $0) }.joined()
    }
}
