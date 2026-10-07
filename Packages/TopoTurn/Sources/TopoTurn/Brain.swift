import Foundation
import TopoCore

/// What a brain is asked: the person's turns to answer, and the log they were said in.
public struct BrainRequest: Sendable, Equatable {
    /// The log as it was read for this answer, in order, without the turns being answered.
    public var context: [Turn]
    /// The person's turns the reply answers: the one just said, or the heads of the log waiting
    /// for a reply.
    public var answering: [Turn]
    /// The parents the reply is written with.
    public var parents: [TurnRef]
    /// The reply's nonce (`TurnRunner.replyNonce(for:)`), the same on every device.
    public var nonce: String
    public var model: ClaudeModel

    public init(context: [Turn], answering: [Turn], parents: [TurnRef], nonce: String, model: ClaudeModel) {
        self.context = context
        self.answering = answering
        self.parents = parents
        self.nonce = nonce
        self.model = model
    }
}

/// A reply a brain finished that the log does not hold yet: found after a crash, after the log had
/// moved on from the request it answered. It is written, under its own nonce and parents, before
/// anything else is asked.
public struct OwedReply: Sendable, Equatable {
    public var parents: [TurnRef]
    public var nonce: String
    public var text: String

    public init(parents: [TurnRef], nonce: String, text: String) {
        self.parents = parents
        self.nonce = nonce
        self.text = text
    }
}

/// What answers the person: the one seam between `TurnRunner` and a model. Everything about the
/// log — the lease, the nonces, the atomic append with its heartbeat — is the runner's; a brain
/// only turns a request into a reply, and hears when that reply is in the log.
public protocol Brain: Sendable {
    /// The reply to `request`. For a request bound to words the brain has heard (`hear`, `bind`)
    /// it is the reply to those words, waited for while it is still being written, and nothing
    /// is asked a second time.
    func answer(_ request: BrainRequest) async throws -> Reply
    /// The person's words, said under `nonce`, before their turn is in the log: the brain starts
    /// on them now. `context` is the log as this device last read it, which may be behind, and
    /// nil when it has not read it: a brain with no conversation of its own to go on waits.
    /// Returns once the words are recorded and handed over, not when they are answered; true
    /// when the brain has them, under this call or an earlier one for the nonce, and false when
    /// it did not begin, which leaves the turn to be asked by `answer` once it is saved.
    func hear(_ words: String, nonce: String, context: [Turn]?, model: ClaudeModel) async -> Bool
    /// The words heard under `nonce` are in the log as `person`, and their reply goes under the
    /// nonce `reply`. Nothing for a nonce the brain did not hear.
    func bind(nonce: String, person: Turn, reply: String) async
    /// The words heard under `nonce` were taken back: no turn of them will be saved.
    func withdrawn(nonce: String) async
    /// The reply under `nonce` is in the log as `reply`: written now, or found there by its nonce.
    func landed(_ reply: Turn, nonce: String) async
    /// Person turns this brain holds as unresolved on this device: asked, and cut off with no
    /// answer. `answerPending` does not answer them; the person asks again.
    func unresolved() async -> Set<TurnRef>
    /// A reply this brain finished whose request the log has moved on from, if there is one.
    func owed() async -> OwedReply?
    /// The model setting changed; a brain that holds a process may restart it once idle.
    func use(model: ClaudeModel) async
    /// Sign-out: whatever the brain keeps of the last login's conversation goes.
    func forget() async
    /// One line for the diagnostics screen: what the brain is and where it stands.
    func describe() async -> String
}

extension Brain {
    public func hear(_ words: String, nonce: String, context: [Turn]?, model: ClaudeModel) async -> Bool { false }
    public func bind(nonce: String, person: Turn, reply: String) async {}
    public func withdrawn(nonce: String) async {}
    public func landed(_ reply: Turn, nonce: String) async {}
    public func unresolved() async -> Set<TurnRef> { [] }
    public func owed() async -> OwedReply? { nil }
    public func use(model: ClaudeModel) async {}
    public func forget() async {}
}

/// A reply as the harness keeps it.
public struct Reply: Sendable, Equatable {
    public var text: String
    public var model: String
    /// Every token of context the reply was written over, cached or not.
    public var context: Int
    public var outputTokens: Int

    public init(text: String, model: String, context: Int, outputTokens: Int) {
        self.text = text
        self.model = model
        self.context = context
        self.outputTokens = outputTokens
    }

    /// A reply found already in the log: its text is the turn's, and nothing else is known.
    init(recovered turn: Turn, model: ClaudeModel) {
        self.init(text: turn.text, model: model.rawValue, context: 0, outputTokens: 0)
    }
}
