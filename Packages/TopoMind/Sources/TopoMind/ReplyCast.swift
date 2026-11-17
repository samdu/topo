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
public final class ReplyCast: @unchecked Sendable {
    public typealias Hand = @Sendable (ReplyFrame) -> Void

    private let lock = NSLock()
    /// The reply being written: the marks of the turns it answers, the frame that names them, and
    /// its frames so far, words of one message run together.
    private var current: (marks: Set<String>, turn: ReplyFrame, frames: [ReplyFrame], handedWords: Bool)?
    private var followers: [UUID: (mark: String, hand: Hand)] = [:]

    public init() {}

    /// The mind is asked to answer `answering`: what is written from here is that reply's.
    func begin(_ answering: [Turn]) {
        lock.withLock {
            let marks = Set(answering.map { HubMind.mark(of: $0.nonce) })
            let turn = ReplyFrame.turn(answering.map(\.ref))
            current = (marks, turn, [], false)
            for follower in followers.values where marks.contains(follower.mark) { follower.hand(turn) }
        }
    }

    /// A piece of the reply being written. Nothing outside a `begin` and its `end`.
    func write(_ frame: ReplyFrame) {
        lock.withLock {
            guard var reply = current else { return }
            if case .text(let more) = frame, case .text(let had)? = reply.frames.last {
                reply.frames[reply.frames.count - 1] = .text(had + more)
            } else {
                reply.frames.append(frame)
            }
            let following = followers.values.filter { reply.marks.contains($0.mark) }
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
            for follower in followers.values where reply.marks.contains(follower.mark) { follower.hand(.cut) }
        }
    }

    /// The reply's turn is over, answered or not.
    func end() {
        lock.withLock { current = nil }
    }

    /// Hands `hand` the reply to the turn `mark` names, from what has been written of it already
    /// if it is being written now, until `stop` with the id returned.
    func follow(_ mark: String, _ hand: @escaping Hand) -> UUID {
        let id = UUID()
        let mark = mark.lowercased()
        lock.withLock {
            if let reply = current, reply.marks.contains(mark) {
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
