import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// The reply as the hub's mind writes it, handed to the nudge that asked for its turn's.
final class Frames: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [ReplyFrame] = []
    var frames: [ReplyFrame] { lock.withLock { all } }
    var hand: ReplyCast.Hand { { [self] frame in lock.withLock { all.append(frame) } } }

    /// The words the frames draw, built as the phone builds them (`ReplyWords`).
    var words: String {
        var messages: [String] = []
        for frame in frames {
            switch frame {
            case .turn, .heard: messages = []
            case .message: messages.append("")
            case .text(let more):
                if messages.isEmpty { messages.append("") }
                messages[messages.count - 1] += more
            case .tool, .cut: break
            }
        }
        return messages.filter { !$0.allSatisfy(\.isWhitespace) }.joined(separator: "\n\n")
    }
}

@Suite(.serialized) struct HubStreamTests {
    func quiet(_ h: HubRig) -> HubMind {
        let configuration = h.configuration
        return HubMind(database: h.db, device: h.hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                       brain: h.brain, login: { await MindLogin.check(configuration) },
                       model: { .sonnet }, timing: fast, poll: .seconds(3600), answeringPoll: .seconds(3600))
    }

    func started(_ hub: HubMind) async -> Bool {
        await eventually { let s = await hub.snapshot(); return s.holds && s.passes == 1 && s.lastPass != nil }
    }

    @Test func theReplysPiecesReachTheNudgeInOrderBeforeThePassEnds() async throws {
        let h = try HubRig()
        let hub = quiet(h)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        let person = try await h.phoneSays("STREAM please")
        let frames = Frames()
        let answered = AnswerBox<Bool>()
        Task {
            let read = await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: HubMind.mark(of: person.nonce), stream: frames.hand)
            answered.lock.withLock { answered.value = read }
        }
        // The reply's words arrive while the mind is still on the turn, held before its result.
        #expect(await eventually { frames.words == "One. Two.\n\nThree." })
        // Mutant: frames handed at the pass's end, or the turn's own pieces held back.
        #expect(answered.lock.withLock { answered.value } == nil)
        #expect(try await h.replies().isEmpty)
        #expect(frames.frames.first == .turn([person.ref]))
        #expect(frames.frames == [.turn([person.ref]), .message, .text("One. "), .text("Two."), .tool, .message, .text("Three.")])
        // Nothing of the tool call's input or of the sub-agent's words is handed.
        #expect(!frames.frames.contains { if case .text(let t) = $0 { t.contains("SECRET") || t.contains("SUBAGENT") } else { false } })
        try Data().write(to: h.rig.log.appending(path: "release"))
        #expect(await eventually { answered.lock.withLock { answered.value } == true })
        // What was streamed is the reply the log holds, byte for byte, and no `cut` ends it.
        #expect(try await h.replies().map(\.text) == [frames.words])
        #expect(!frames.frames.contains(.cut))
        await hub.turnOff()
    }

    @Test func aNudgeForAnotherTurnIsHandedNothing() async throws {
        let h = try HubRig()
        let hub = quiet(h)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        try await h.phoneSays("STREAM please")
        try Data().write(to: h.rig.log.appending(path: "release"))
        let frames = Frames()
        // Mutant: every follower handed every reply.
        #expect(await within(15) { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: "zz99zz99", stream: frames.hand) } == true)
        #expect(try await h.replies().count == 1)
        #expect(frames.frames.isEmpty)
        await hub.turnOff()
    }

    @Test func aNudgeThatComesMidReplyIsHandedWhatItMissedFirst() async throws {
        let h = try HubRig()
        let hub = quiet(h)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        let person = try await h.phoneSays("STREAM please")
        let mark = HubMind.mark(of: person.nonce)
        // The first nudge starts the pass; a second phone's comes once words are written.
        let early = Frames()
        Task { _ = await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: mark, stream: early.hand) }
        #expect(await eventually { early.words.hasPrefix("One. Two.") })
        let late = Frames()
        let answered = AnswerBox<Bool>()
        Task {
            let read = await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: mark, stream: late.hand)
            answered.lock.withLock { answered.value = read }
        }
        #expect(await eventually { late.words == "One. Two.\n\nThree." })
        // Mutant: a follower handed only what is written after it came.
        #expect(late.frames.first == .turn([person.ref]))
        try Data().write(to: h.rig.log.appending(path: "release"))
        #expect(await eventually { answered.lock.withLock { answered.value } == true })
        await hub.turnOff()
    }

    /// A turn the mind is cut off on (here a stall) ends its stream with `.cut`, which a phone
    /// tells apart from a dropped socket; a reply that lands ends with none.
    @Test func aTurnCutOffEndsItsStreamWithACut() async throws {
        let h = try HubRig(silence: .seconds(2))
        let hub = quiet(h)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        let person = try await h.phoneSays("STREAM please")
        let frames = Frames()
        let answered = AnswerBox<Bool>()
        Task {
            let read = await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: HubMind.mark(of: person.nonce), stream: frames.hand)
            answered.lock.withLock { answered.value = read }
        }
        #expect(await eventually { frames.words.hasPrefix("One.") })
        // Mutant: no `cut` handed when the brain's answer throws.
        #expect(await eventually { frames.frames.last == .cut })
        #expect(frames.frames.filter { $0 == .cut }.count == 1)
        #expect(await eventually { answered.lock.withLock { answered.value } == false })
        #expect(try await h.replies().isEmpty)
        await hub.turnOff()
    }

    /// The hub's switch for streaming, turned off mid-reply, stops the stream it is handed through:
    /// nothing more of the reply's words, while a `cut` still goes.
    @Test func aGatedHandStopsAtTheFirstFrameWithTheGateShut() {
        let frames = Frames()
        let on = AnswerBox<Bool>()
        on.lock.withLock { on.value = true }
        let hand = ReplyCast.gated(frames.hand, while: { on.lock.withLock { on.value } ?? false })
        hand(.turn([TurnRef(device: DeviceID("phone-a"), sequence: 1)])); hand(.message); hand(.text("One. "))
        on.lock.withLock { on.value = false }
        hand(.text("Two."))
        // Mutant: the gate read only when the follower began.
        on.lock.withLock { on.value = true }
        hand(.text("Three."))
        hand(.cut)
        #expect(frames.words == "One. ")
        #expect(frames.frames.last == .cut)
    }

    @Test func aStreamEndsWithTheMindAndHandsNothingAfter() async throws {
        let h = try HubRig()
        let hub = quiet(h)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        let person = try await h.phoneSays("STREAM please")
        let frames = Frames()
        let answered = AnswerBox<Bool>()
        Task {
            let read = await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: HubMind.mark(of: person.nonce), stream: frames.hand)
            answered.lock.withLock { answered.value = read }
        }
        #expect(await eventually { frames.words.hasPrefix("One.") })
        await hub.turnOff()
        #expect(await eventually { answered.lock.withLock { answered.value } == false })
        // The turn the stop cut off ends with a `cut`, before the nudge is answered.
        #expect(frames.frames.last == .cut)
        let count = frames.frames.count
        try Data().write(to: h.rig.log.appending(path: "release"))
        try await Task.sleep(for: .milliseconds(500))
        #expect(frames.frames.count == count)
        #expect(try await h.replies().isEmpty)
    }
}
