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

    /// `nonce` names the append of the person's turn; a caller that keeps it and passes the same
    /// one again after a failure gets the turn already in the log rather than a second copy.
    public func run(_ text: String, model: ClaudeModel, nonce: String = UUID().uuidString) async throws -> Result {
        let outcome = try await lease.acquire()
        guard case .primary = outcome else { throw TurnRunnerError.notPrimary(outcome) }

        let before = try await log.read()
        let at = Date()
        let person = try await writer.append(.person, text, continuing: before, at: at, nonce: nonce)
        if person.at != at {
            // A retry: the person's turn was written by an earlier attempt. If that attempt also
            // got its reply into the log before it was cut off, that is the reply.
            let now = try await log.read()
            if let answered = now.ordered.first(where: { $0.role == .assistant && $0.parents.contains(person.ref) }) {
                return Result(person: person, assistant: answered,
                              reply: Reply(text: answered.text, model: model.rawValue, stopReason: nil, inputTokens: 0, outputTokens: 0))
            }
        }
        do {
            let history = before.ordered.suffix(historyLimit - 1) + [person]
            let reply = try await api.complete(Self.messages(from: history), model: model, system: Self.systemPrompt)
            // The reply and a heartbeat of the lease are one atomic batch: a claim made during
            // the call, or between the call and this write, refuses the batch and nothing lands.
            guard let assistant = try await writer.append(.assistant, reply.text, parents: [person.ref], renewing: lease) else {
                throw TurnRunnerError.displaced
            }
            return Result(person: person, assistant: assistant, reply: reply)
        } catch {
            throw TurnRunnerError.replyFailed(person: person, underlying: error)
        }
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
