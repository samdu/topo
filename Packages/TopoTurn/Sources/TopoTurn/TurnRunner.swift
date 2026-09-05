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
public actor TurnRunner {
    public struct Result: Sendable {
        public var person: Turn
        public var assistant: Turn
        public var reply: Reply
    }

    private let log: TurnLog
    private let writer: TurnWriter
    private let lease: PrimaryLease
    private let api: MessagesAPI
    /// How many turns of history go to the model with the new one.
    public var historyLimit = 40

    public static let systemPrompt = """
    You are Topo, one person's assistant, speaking with them on their own device. Be brief and \
    concrete. When they tell you something they forgot, help them act on it now.
    """

    public init(log: TurnLog, writer: TurnWriter, lease: PrimaryLease, api: MessagesAPI) {
        self.log = log
        self.writer = writer
        self.lease = lease
        self.api = api
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
        let before = try await log.read()
        let at = Date()
        let person = try await writer.append(.person, text, continuing: before, at: at, nonce: nonce)
        await progress?(.asking(person: person))
        let replyNonce = Self.replyNonce(for: [person.ref])
        if person.at != at {
            // A retry: the person's turn was written by an earlier attempt. If that attempt also
            // got its reply into the log before it was cut off, that is the reply.
            if let answered = try await log.turn(appendedUnder: replyNonce) {
                return Result(person: person, assistant: answered, reply: Reply(recovered: answered, model: model))
            }
        }
        do {
            // On a retry `before` already holds the recovered person turn; it goes to the model once.
            let history = before.ordered.filter { $0.ref != person.ref }.suffix(historyLimit - 1) + [person]
            let reply = try await api.complete(Self.messages(from: history), model: model, system: Self.systemPrompt)
            await progress?(.savingReply)
            // The reply and a heartbeat of the lease are one atomic batch: a claim made during
            // the call, or between the call and this write, refuses the batch and nothing lands.
            guard let assistant = try await writer.append(.assistant, reply.text, parents: [person.ref],
                                                          nonce: replyNonce, renewing: lease) else {
                throw TurnRunnerError.displaced
            }
            return Result(person: person, assistant: assistant, reply: reply)
        } catch {
            throw TurnRunnerError.replyFailed(person: person, underlying: error)
        }
    }

    /// Answers the log as it stands, if its newest turns include a person's turn with no reply:
    /// one reply continuing every head, so a fork is joined rather than answered twice. Nothing
    /// waiting, or a read with turns still missing, returns nil without touching the lease; the
    /// caller reads again later. Otherwise this device takes the lease, and runs only as primary.
    public func answerPending(model: ClaudeModel) async throws -> Turn? {
        let transcript = try await log.read()
        guard transcript.isComplete, Self.awaitsReply(transcript) else { return nil }
        let outcome = try await lease.acquire()
        guard case .primary = outcome else { throw TurnRunnerError.notPrimary(outcome) }
        let nonce = Self.replyNonce(for: transcript.heads)
        if let answered = try await log.turn(appendedUnder: nonce) { return answered }
        let reply = try await api.complete(Self.messages(from: transcript.ordered.suffix(historyLimit)),
                                           model: model, system: Self.systemPrompt)
        guard let assistant = try await writer.append(.assistant, reply.text, continuing: transcript,
                                                      nonce: nonce, renewing: lease) else {
            throw TurnRunnerError.displaced
        }
        return assistant
    }

    /// True when a head of the transcript is the person's: words nobody has answered.
    static func awaitsReply(_ transcript: Transcript) -> Bool {
        transcript.heads.contains { transcript[$0]?.role == .person }
    }

    /// The nonce of the reply to these turns, the same on every device: `answer/` and the SHA-256
    /// of the refs in sorted order, so its length is fixed however wide a fork it answers (the
    /// marker's record name carries it, and CloudKit caps a record name at 255 characters).
    static func replyNonce(for heads: [TurnRef]) -> String {
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
