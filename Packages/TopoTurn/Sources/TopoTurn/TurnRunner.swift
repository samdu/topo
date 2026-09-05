import Foundation
import TopoCore

public enum TurnRunnerError: Error {
    /// This device does not hold the primary lease; the outcome says who does.
    case notPrimary(LeaseOutcome)
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
/// turn carries on from them; the reply is appended as a child of the person's turn.
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

    public func run(_ text: String, model: ClaudeModel) async throws -> Result {
        let outcome = try await lease.acquire()
        guard case .primary = outcome else { throw TurnRunnerError.notPrimary(outcome) }

        let before = try await log.read()
        let person = try await writer.append(.person, text, continuing: before)
        let history = before.ordered.suffix(historyLimit - 1) + [person]
        let reply = try await api.complete(Self.messages(from: history), model: model, system: Self.systemPrompt)
        let assistant = try await writer.append(.assistant, reply.text, parents: [person.ref])
        return Result(person: person, assistant: assistant, reply: reply)
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
