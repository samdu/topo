import Foundation
import TopoCore

/// The reply the mind is writing now, handed as it is written to the phones that nudged for the
/// turn it answers (`HubMind.nudge`), each over its own connection (`ReplyFrame`).
///
/// One turn at a time, as the mind answers: `begin` names the person turns the reply answers,
/// `write` hands each piece the brain reads off Claude Code's stream once the turn is its own
/// (after its input's echo), and `end` closes it. A follower names the turn it is for by its mark
/// (the eight letters or digits of the turn's nonce the phone's marks carry) and is handed only a
/// reply that answers that turn: `.turn` with the refs it answers first, then its frames. One that
/// comes while that reply is being written is handed what it has missed first, in one frame of
/// words per message, so it draws the same text. Everything is handed under one lock, in the order
/// it was written, and synchronously: a follower's hand sends and does not wait, so nothing here
/// waits on a phone.
///
/// Words a phone handed over before their turn was saved (`NativeBrain.hearAhead`) are answered
/// outside any request, so their reply has a lane of its own (`beginHeard`): named by `.heard` with
/// the person's nonce, which the turn will be saved under, and handed to the followers of that
/// nonce's mark. While it stands the request lane hands those followers nothing, so a follower is
/// handed the heard reply's catch-up or its continuation, and never a second beginning of it.
public final class ReplyCast: @unchecked Sendable {
    public typealias Hand = @Sendable (ReplyFrame) -> Void

    private let lock = NSLock()
    /// The reply being written: the marks of the turns it answers, the frame that names them, and
    /// its frames so far, words of one message run together.
    private var current: (marks: Set<String>, turn: ReplyFrame, frames: [ReplyFrame], handedWords: Bool)?
    /// The reply to words heard ahead, while the mind is on them.
    private var heard: (mark: String, turn: ReplyFrame, frames: [ReplyFrame], handedWords: Bool)?
    private var followers: [UUID: (mark: String, hand: Hand)] = [:]

    public init() {}

    /// Whether the request lane hands a follower of `mark` anything: not while the heard lane is
    /// that follower's.
    private func requestLane(_ mark: String, _ marks: Set<String>) -> Bool {
        marks.contains(mark) && heard?.mark != mark
    }

    /// The mind is asked to answer `answering`: what is written from here is that reply's.
    func begin(_ answering: [Turn]) {
        lock.withLock {
            let marks = Set(answering.map { HubMind.mark(of: $0.nonce) })
            let turn = ReplyFrame.turn(answering.map(\.ref))
            current = (marks, turn, [], false)
            for follower in followers.values where requestLane(follower.mark, marks) { follower.hand(turn) }
        }
    }

    /// A piece of the reply being written. Nothing outside a `begin` and its `end`.
    func write(_ frame: ReplyFrame) {
        lock.withLock {
            guard var reply = current else { return }
            reply.frames = Self.appending(frame, to: reply.frames)
            let following = followers.values.filter { requestLane($0.mark, reply.marks) }
            if case .text = frame, !reply.handedWords, !following.isEmpty {
                reply.handedWords = true
                Perf.mark("hub.stream.first followers=\(following.count)")
            }
            current = reply
            for follower in following { follower.hand(frame) }
        }
    }

    /// The mind's turn on the reply being written ended with no reply to come from it (the
    /// brain's answer threw): its followers are handed `.cut`.
    func cut() {
        lock.withLock {
            guard let reply = current else { return }
            for follower in followers.values where requestLane(follower.mark, reply.marks) { follower.hand(.cut) }
        }
    }

    /// The reply's turn is over, answered or not.
    func end() {
        lock.withLock { current = nil }
    }

    /// The mind has the person's words said under `nonce`, ahead of their turn: what is written
    /// on the heard lane from here is their reply's.
    func beginHeard(_ nonce: String) {
        lock.withLock {
            let mark = HubMind.mark(of: nonce)
            let turn = ReplyFrame.heard(nonce)
            heard = (mark, turn, [], false)
            for follower in followers.values where follower.mark == mark { follower.hand(turn) }
        }
    }

    /// A piece of the reply to words heard ahead. Nothing outside a `beginHeard` and its `endHeard`.
    func writeHeard(_ frame: ReplyFrame) {
        lock.withLock {
            guard var reply = heard else { return }
            reply.frames = Self.appending(frame, to: reply.frames)
            let following = followers.values.filter { $0.mark == reply.mark }
            if case .text = frame, !reply.handedWords, !following.isEmpty {
                reply.handedWords = true
                Perf.mark("hub.stream.first followers=\(following.count) heard")
            }
            heard = reply
            for follower in following { follower.hand(frame) }
        }
    }

    /// The mind's turn on words heard ahead ended with no reply to come from it: `.cut`.
    func cutHeard() {
        lock.withLock {
            guard let reply = heard else { return }
            for follower in followers.values where follower.mark == reply.mark { follower.hand(.cut) }
        }
    }

    /// The mind's turn on words heard ahead is over.
    func endHeard() {
        lock.withLock { heard = nil }
    }

    private static func appending(_ frame: ReplyFrame, to frames: [ReplyFrame]) -> [ReplyFrame] {
        var frames = frames
        if case .text(let more) = frame, case .text(let had)? = frames.last {
            frames[frames.count - 1] = .text(had + more)
        } else {
            frames.append(frame)
        }
        return frames
    }

    /// Hands `hand` the reply to the turn `mark` names, from what has been written of it already
    /// if it is being written now, until `stop` with the id returned.
    func follow(_ mark: String, _ hand: @escaping Hand) -> UUID {
        let id = UUID()
        let mark = mark.lowercased()
        lock.withLock {
            if let reply = heard, reply.mark == mark {
                hand(reply.turn)
                reply.frames.forEach(hand)
            } else if let reply = current, reply.marks.contains(mark) {
                hand(reply.turn)
                reply.frames.forEach(hand)
            }
            followers[id] = (mark, hand)
        }
        return id
    }

    func stop(_ id: UUID) {
        lock.withLock { followers[id] = nil }
    }

    /// `hand`, while `on` says so: from the first frame handed with `on` false, nothing more of
    /// the reply is handed but `.cut`, which carries no words, so a reply stopped mid-stream is
    /// not resumed with a gap in it. For the hub's "Stream replies to the phone", which turned off
    /// stops a stream in progress.
    public static func gated(_ hand: @escaping Hand, while on: @escaping @Sendable () -> Bool) -> Hand {
        let stopped = Latch()
        return { frame in
            if frame != .cut, stopped.trip(if: !on()) { return }
            hand(frame)
        }
    }

    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var tripped = false
        /// True from the first call whose `condition` is true.
        func trip(if condition: Bool) -> Bool { lock.withLock { if condition { tripped = true }; return tripped } }
    }

    /// How many follow now, for the suites.
    var following: Int { lock.withLock { followers.count } }
}
