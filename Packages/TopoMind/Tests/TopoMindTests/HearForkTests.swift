import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// A store whose change feed is behind on one device's turns while `lagging`, as CloudKit's can be
/// behind a save answered a moment before: fetches by ID still find them.
final class LaggingFeed: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    let device: DeviceID
    private let lock = NSLock()
    private var _lagging = true
    private var _failing = false
    var lagging: Bool {
        get { lock.withLock { _lagging } }
        set { lock.withLock { _lagging = newValue } }
    }
    /// Every read of the feed fails while set.
    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }

    init(_ base: any RecordDatabase, hiding device: DeviceID) {
        self.base = base
        self.device = device
    }

    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        if failing { throw RecordDatabaseError.unavailable(underlying: CancellationError()) }
        let all = try await base.records(ofType: type)
        guard lagging, type == Turn.recordType else { return all }
        return all.filter { Turn(record: $0)?.ref.device != device }
    }
}

/// Words heard ahead whose turn is not the log's one head when a pass finds it: one of several
/// heads, or behind the head with no reply of its own. The words are written to the mind once,
/// their reply reaches the log bound to their turn before anything said after them is asked, and
/// the rest are asked as their own input.
@Suite(.serialized) struct HearForkTests {
    let pad = DeviceID("pad-9z8y7x6w")

    func ready(_ h: HubRig, over database: (any RecordDatabase)? = nil) async throws -> (HubMind, Lease) {
        let hub = h.hub(over: database, poll: .seconds(3600))
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().phase == .answering })
        try await h.phoneSays("hello")
        await hub.trigger(.push)
        #expect(try await eventually { try await h.replies().count == 1 })
        try await Task.sleep(for: .milliseconds(300))
        return (hub, try #require(await h.lease()))
    }

    func hear(_ hub: HubMind, _ lease: Lease, _ words: String, nonce: String) async -> Bool {
        await hub.hear(holder: lease.holder, epoch: lease.epoch, nonce: nonce, model: "sonnet", words: words)
    }

    func told(_ h: HubRig, _ words: String) -> Int { h.rig.inputs.filter { $0.contains(words) }.count }

    /// Another device's turn X waits; the phone hands over P before the hub's feed shows X; the
    /// hub answers X, and the phone's save of P continues the read it made before that reply, so
    /// the log forks into [R_X, P]. P is told once, and its reply is its own.
    @Test func aHeardTurnSavedIntoAForkIsAnsweredOnceUnderItsOwnReply() async throws {
        let h = try HubRig()
        let lag = LaggingFeed(h.db, hiding: pad)
        let (hub, lease) = try await ready(h, over: lag)
        let log = TurnLog(database: h.db)
        let x = try await log.writer(for: pad).append(.person, "pad says X", continuing: try await log.read())
        let stale = try await log.read()
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "phone says P", nonce: nonce))
        #expect(await eventually { h.rig.inputs.count == 2 })
        lag.lagging = false
        await hub.trigger(.push)
        #expect(try await eventually { try await h.replies().count == 2 })
        try await Task.sleep(for: .milliseconds(300))
        let person = try await log.writer(for: h.phoneID).append(.person, "phone says P", continuing: stale, nonce: nonce)
        #expect(person.parents == [x.ref])
        await hub.trigger(.push)
        #expect(try await eventually { try await h.replies().count == 3 })
        try await Task.sleep(for: .milliseconds(500))
        // Mutant: the fork's reply asks P's words again.
        #expect(told(h, "phone says P") == 1)
        let reply = try #require(try await h.replies().first { $0.parents.contains(person.ref) })
        #expect(reply.parents == [person.ref])
        #expect(reply.nonce == TurnRunner.replyNonce(for: [person.ref]))
        #expect(reply.text == "echo: phone says P")
        #expect(try await h.replies().count == 3)
        await hub.turnOff()
    }

    /// The pad's X and the phone's P both continue the same reply: P, heard, is answered first and
    /// alone with what the mind made of it, and X is then asked by itself.
    @Test func aHeardTurnBesideAnotherPersonsTurnIsAnsweredFirstAndAlone() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let log = TurnLog(database: h.db)
        let before = try await log.read()
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "phone says P", nonce: nonce))
        #expect(await eventually { h.rig.inputs.count == 2 })
        try await Task.sleep(for: .milliseconds(300))
        let x = try await log.writer(for: pad).append(.person, "pad says X", continuing: before)
        let p = try await log.writer(for: h.phoneID).append(.person, "phone says P", continuing: before, nonce: nonce)
        #expect(try await log.read().heads.count == 2)
        await hub.trigger(.push)
        #expect(try await eventually { try await h.replies().count == 3 })
        try await Task.sleep(for: .milliseconds(500))
        // Mutant: P's words told again beside X's.
        #expect(told(h, "phone says P") == 1)
        let replies = try await h.replies()
        let rp = try #require(replies.first { $0.parents == [p.ref] })
        #expect(rp.nonce == TurnRunner.replyNonce(for: [p.ref]))
        #expect(rp.text == "echo: phone says P")
        let rx = try #require(replies.first { $0.parents.contains(x.ref) })
        #expect(Set(rx.parents) == [x.ref, rp.ref])
        // P's reply was written first: X's continues it.
        #expect(rp.ref.sequence < rx.ref.sequence)
        #expect(h.rig.inputs.last == "pad says X")
        await hub.turnOff()
    }

    /// One phone, two messages back to back: P handed over and heard, then P saved and Q saved as
    /// its child before a pass reads the log. P's reply reaches the log under its own nonce,
    /// before Q is asked; Q is asked alone.
    @Test(arguments: [false, true])
    func twoMessagesBackToBackAnswerEachUnderItsOwnReply(streaming: Bool) async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        let words = streaming ? "STREAM phone says P" : "phone says P"
        #expect(await hear(hub, lease, words, nonce: nonce))
        #expect(await eventually { h.rig.inputs.count == 2 })
        if !streaming { try await Task.sleep(for: .milliseconds(500)) }
        let p = try await h.phoneSays(words, nonce: nonce)
        let q = try await h.phoneSays("phone says Q")
        #expect(q.parents == [p.ref])
        await hub.trigger(.push)
        if streaming {
            // The pass waits for the mind to finish P before it writes or asks anything.
            try await Task.sleep(for: .milliseconds(800))
            #expect(try await h.replies().count == 1)
            #expect(h.rig.inputs.count == 2)
            try Data().write(to: h.rig.log.appending(path: "release"))
        }
        #expect(try await eventually { try await h.replies().count == 3 })
        try await Task.sleep(for: .milliseconds(500))
        let replies = try await h.replies()
        // Mutant: P's reply never written, Q asked alone after a reply the log lacks.
        let rp = try #require(replies.first { $0.parents == [p.ref] })
        #expect(rp.nonce == TurnRunner.replyNonce(for: [p.ref]))
        #expect(rp.text == (streaming ? "One. Two.\n\nThree." : "echo: phone says P"))
        let rq = try #require(replies.first { $0.parents.contains(q.ref) })
        #expect(Set(rq.parents) == [q.ref, rp.ref])
        #expect(rp.ref.sequence < rq.ref.sequence)
        #expect(told(h, "phone says P") == 1)
        #expect(h.rig.inputs.last == "phone says Q")
        await hub.turnOff()
    }

    /// The same back to back with nothing handed over: P is told as what was said meanwhile, Q
    /// answered, one reply. The rule changes nothing of a turn the mind did not hear ahead.
    @Test func twoMessagesBackToBackWithoutAHandOverAreOneReply() async throws {
        let h = try HubRig()
        let (hub, _) = try await ready(h)
        let p = try await h.phoneSays("phone says P")
        let q = try await h.phoneSays("phone says Q")
        await hub.trigger(.push)
        #expect(try await eventually { try await h.replies().count == 2 })
        try await Task.sleep(for: .milliseconds(500))
        #expect(try await h.replies().count == 2)
        #expect(try await h.replies().last?.parents == [q.ref])
        #expect(h.rig.inputs.last?.contains("Them: phone says P") == true)
        #expect(p.parents != [])
        await hub.turnOff()
    }

    /// A turn of another device's in the log, not yet answered (its push not come): a hand-over
    /// is refused, so the mind is never told words ahead of a turn of the log, and a pass is
    /// asked for at once.
    @Test func aHandOverWhileTheLogHoldsAnUntoldTurnIsRefusedAndAsksAPass() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let log = TurnLog(database: h.db)
        _ = try await log.writer(for: pad).append(.person, "pad says X", continuing: try await log.read())
        // Mutant: the gate that does not read the feed.
        #expect(!(await hear(hub, lease, "phone says P", nonce: UUID().uuidString)))
        #expect(try await eventually { try await h.replies().count == 2 })
        #expect(h.rig.inputs == ["hello", "pad says X"])
        await hub.turnOff()
    }

    /// The feed behind on the pad's X when P is handed over, and the phone's save of P continuing
    /// X: P is the log's one head and is answered with its heard reply. X, which the mind was
    /// never told before it heard P, is told with the next input as said meanwhile, with no reply
    /// of its own.
    @Test func aTurnTheFeedWasBehindOnIsToldWithTheNextInput() async throws {
        let h = try HubRig()
        let lag = LaggingFeed(h.db, hiding: pad)
        let (hub, lease) = try await ready(h, over: lag)
        let log = TurnLog(database: h.db)
        let x = try await log.writer(for: pad).append(.person, "pad says X", continuing: try await log.read())
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "phone says P", nonce: nonce))
        #expect(await eventually { h.rig.inputs.count == 2 })
        let p = try await h.phoneSays("phone says P", nonce: nonce)
        #expect(p.parents == [x.ref])
        lag.lagging = false
        await hub.trigger(.push)
        #expect(try await eventually { try await h.replies().count == 2 })
        #expect(try await h.replies().last?.parents == [p.ref])
        try await h.phoneSays("next")
        await hub.trigger(.push)
        #expect(try await eventually { try await h.replies().count == 3 })
        #expect(h.rig.inputs.last?.contains("Them: pad says X") == true)
        #expect(told(h, "phone says P") == 1)
        #expect(try await h.replies().allSatisfy { !$0.parents.contains(x.ref) })
        await hub.turnOff()
    }

    /// A feed that cannot be read when words are handed over: refused, nothing written to the mind.
    @Test func aHandOverWhoseFeedCannotBeReadIsRefused() async throws {
        let h = try HubRig()
        let feed = LaggingFeed(h.db, hiding: pad)
        feed.lagging = false
        let (hub, lease) = try await ready(h, over: feed)
        feed.failing = true
        // Mutant: a failed read taken as a log with nothing waiting.
        #expect(!(await hear(hub, lease, "phone says P", nonce: UUID().uuidString)))
        try await Task.sleep(for: .milliseconds(300))
        #expect(h.rig.inputs == ["hello"])
        await hub.turnOff()
    }

    /// Words the mind was cut off on, their turn saved and then the person's next: the heard turn
    /// gets no reply and is not asked again, the next is answered alone in the same pass, and the
    /// turn after is answered.
    @Test func aHeardTurnCutOffWithATurnAfterItLeavesTheNextAnswered() async throws {
        let h = try HubRig()
        let (hub, lease) = try await ready(h)
        let nonce = UUID().uuidString
        #expect(await hear(hub, lease, "FAIL phone says P", nonce: nonce))
        #expect(await eventually { h.rig.inputs.count == 2 })
        try await Task.sleep(for: .milliseconds(500))
        let p = try await h.phoneSays("FAIL phone says P", nonce: nonce)
        let q = try await h.phoneSays("phone says Q")
        await hub.trigger(.push)
        #expect(try await eventually { try await h.replies().count == 2 })
        try await Task.sleep(for: .milliseconds(500))
        let rq = try #require(try await h.replies().last)
        #expect(rq.parents.contains(q.ref))
        #expect(rq.text == "echo: phone says Q")
        // Mutant: a cut-off heard turn failing the pass, Q never answered. Once Q's reply goes on
        // from it, P is no head the mind holds cut off.
        #expect(try await h.replies().allSatisfy { !$0.parents.contains(p.ref) })
        #expect(h.rig.inputs.last == "phone says Q")
        #expect(told(h, "FAIL phone says P") == 1)
        try await h.phoneSays("after")
        await hub.trigger(.push)
        #expect(try await eventually { try await h.replies().count == 3 })
        #expect(await hub.snapshot().phase == .answering)
        await hub.turnOff()
    }
}
