import CryptoKit
import Foundation
import TopoCore

public enum TurnRunnerError: Error {
    /// This device does not hold the primary lease; the outcome says who does.
    case notPrimary(LeaseOutcome)
    /// The lease was lost while the model was answering. The person's turn is in the log, the
    /// reply is not: whoever is primary now answers it.
    case displaced
    /// The person's turn is in the log and the reply is not; `underlying` says why (an API
    /// error, or `displaced`). The caller keeps `person` and owes nothing for it.
    case replyFailed(person: Turn, underlying: any Error)
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
/// Each turn takes the primary lease first and runs only as its holder. The person's turn is
/// appended before the model is called, so a failed call leaves the words in the log and the next
/// turn carries on from them; the reply is appended as a child of the person's turn in one atomic
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
/// each reply is appended, which is how a sign-out stops a turn or a pass already under way.
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
    /// How many turns of history go to the model with the new one.
    public var historyLimit = 40

    public static let systemPrompt = """
    You are Topo, one person's assistant, speaking with them on their own device. Be brief and \
    concrete. When they tell you something they forgot, help them act on it now.
    """

    public init(log: TurnLog, writer: TurnWriter, lease: PrimaryLease, brain: any Brain) {
        self.log = log
        self.writer = writer
        self.lease = lease
        self.brain = brain
    }

    /// Where a turn is, told to the caller as it goes, so a screen never shows nothing while
    /// CloudKit or the model takes its time.
    public enum Progress: Sendable, Equatable {
        case takingLease
        case saving
        /// The person's turn is in the log; the model has it now.
        case asking(person: Turn)
        case savingReply
    }

    /// `nonce` names the append of the person's turn; a caller that keeps it and passes the same
    /// one again after a failure gets the turn already in the log rather than a second copy.
    /// `progress` is called at each step, on no particular actor.
    public func run(_ text: String, model: ClaudeModel, nonce: String = UUID().uuidString,
                    progress: (@Sendable (Progress) async -> Void)? = nil) async throws -> Result {
        await progress?(.takingLease)
        let outcome = try await lease.acquire()
        guard case .primary = outcome else { throw TurnRunnerError.notPrimary(outcome) }

        await progress?(.saving)
        try await settleOwed()
        let before = try await log.read()
        let at = Date()
        let person = try await writer.append(.person, text, continuing: before, at: at, nonce: nonce)
        await progress?(.asking(person: person))
        let replyNonce = Self.replyNonce(for: [person.ref])
        if person.at != at {
            // A retry: the person's turn was written by an earlier attempt. If that attempt also
            // got its reply into the log before it was cut off, that is the reply.
            if let answered = try await log.turn(appendedUnder: replyNonce) {
                await brain.landed(answered, nonce: replyNonce)
                return Result(person: person, assistant: answered, reply: Reply(recovered: answered, model: model))
            }
        }
        do {
            // On a retry `before` already holds the recovered person turn; it goes to the model once.
            let context = before.ordered.filter { $0.ref != person.ref }
            let request = BrainRequest(context: context, answering: [person],
                                       history: context.suffix(historyLimit - 1) + [person],
                                       parents: [person.ref], nonce: replyNonce, model: model)
            let reply = try await brain.answer(request)
            await progress?(.savingReply)
            // A caller that stopped — a sign-out cancels the turn in flight — writes nothing more.
            try Task.checkCancellation()
            // The reply and a heartbeat of the lease are one atomic batch: a claim made during
            // the call, or between the call and this write, refuses the batch and nothing lands.
            guard let assistant = try await writer.append(.assistant, reply.text, parents: [person.ref],
                                                          nonce: replyNonce, renewing: lease) else {
                throw TurnRunnerError.displaced
            }
            await brain.landed(assistant, nonce: replyNonce)
            return Result(person: person, assistant: assistant, reply: reply)
        } catch {
            throw TurnRunnerError.replyFailed(person: person, underlying: error)
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
    public func answerPending(model: ClaudeModel) async throws -> Turn? {
        var transcript = try await log.read()
        guard transcript.isComplete else { return nil }
        // An owed reply is written whatever the head is: another device may have answered past
        // the turn it belongs to, and nothing else would ever write it.
        let waiting = Self.awaitsReply(transcript, skipping: await brain.unresolved())
        if !waiting {
            guard await brain.owed() != nil else { return nil }
        }
        let outcome = try await lease.acquire()
        guard case .primary = outcome else { throw TurnRunnerError.notPrimary(outcome) }
        if try await settleOwed() {
            // The owed reply moved the log; what waits is read again.
            transcript = try await log.read()
        }
        let unresolved = await brain.unresolved()
        guard transcript.isComplete, Self.awaitsReply(transcript, skipping: unresolved) else { return nil }
        let nonce = Self.replyNonce(for: transcript.heads)
        if let answered = try await log.turn(appendedUnder: nonce) {
            await brain.landed(answered, nonce: nonce)
            return answered
        }
        let skipped = await brain.unresolved()
        let answering = transcript.heads.compactMap { transcript[$0] }
            .filter { $0.role == .person && !skipped.contains($0.ref) }
        // Settling what was owed can find the waiting turn cut off: nothing is left to answer.
        guard !answering.isEmpty else { return nil }
        let ordered = transcript.ordered
        let request = BrainRequest(context: ordered.filter { turn in !answering.contains { $0.ref == turn.ref } },
                                   answering: answering, history: Array(ordered.suffix(historyLimit)),
                                   parents: transcript.heads, nonce: nonce, model: model)
        let reply = try await brain.answer(request)
        // A pass that was stopped — a sign-out cancels the one in flight — writes nothing.
        try Task.checkCancellation()
        guard let assistant = try await writer.append(.assistant, reply.text, continuing: transcript,
                                                      nonce: nonce, renewing: lease) else {
            throw TurnRunnerError.displaced
        }
        await brain.landed(assistant, nonce: nonce)
        return assistant
    }

    /// Writes the reply the brain owes the log, if it owes one, and answers whether the log moved.
    /// Found already there under its nonce — another primary's, or this device's own write whose
    /// acknowledgement was lost — it is not written again; the brain hears where it is either way.
    @discardableResult
    private func settleOwed() async throws -> Bool {
        guard let owed = await brain.owed() else { return false }
        if let there = try await log.turn(appendedUnder: owed.nonce) {
            await brain.landed(there, nonce: owed.nonce)
            return false
        }
        try Task.checkCancellation()
        guard let turn = try await writer.append(.assistant, owed.text, parents: owed.parents,
                                                 nonce: owed.nonce, renewing: lease) else {
            throw TurnRunnerError.displaced
        }
        await brain.landed(turn, nonce: owed.nonce)
        return true
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

    /// Turns as the API takes them: roles alternate, so consecutive turns of one role are joined,
    /// and the list starts with the person.
    static func messages(from turns: some Sequence<Turn>) -> [ChatMessage] {
        var out: [ChatMessage] = []
        for turn in turns {
            let role: ChatMessage.Role = turn.role == .person ? .user : .assistant
            if out.isEmpty, role == .assistant { continue }
            if let last = out.last, last.role == role {
                out[out.count - 1].content += "\n\n" + turn.text
            } else {
                out.append(ChatMessage(role: role, content: turn.text))
            }
        }
        return out
    }
}
