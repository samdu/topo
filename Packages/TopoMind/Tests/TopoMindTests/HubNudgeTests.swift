import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// The phone's nudge, as the hub's listener hands it to the mind: a pass now, answered when the
/// pass that read after it has ended.
/// `work`'s answer, or nil if it has none within `seconds`: a nudge that is never answered fails
/// its test rather than hanging it.
final class AnswerBox<T: Sendable>: @unchecked Sendable {
    let lock = NSLock()
    var value: T?
}

func within<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
    let box = AnswerBox<T>()
    Task { let v = await work(); box.lock.withLock { box.value = v } }
    let deadline = Date() + seconds
    while Date() < deadline {
        if let v = box.lock.withLock({ box.value }) { return v }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return box.lock.withLock { box.value }
}

@Suite(.serialized) struct HubNudgeTests {
    /// A hub with no poll to speak of: only a start, a trigger or a nudge runs a pass.
    @Test func aBatchFromTheInboxIsATurnTheMindAnswersAndIsRefusedWhileOff() async throws {
        let h = try HubRig()
        let hub = quiet(h)
        // Mutant: a batch written while this Mac does not answer, for a phone to answer instead.
        #expect(await hub.hear("ignored") == false)
        await hub.turnOn()
        #expect(await eventually { let s = await hub.snapshot(); return s.holds && s.passes >= 1 })
        #expect(await hub.hear("Calendar: dentist at 3."))
        #expect(try await eventually { try await !h.replies().isEmpty })
        let turns = try await TurnLog(database: h.db).read().ordered
        let told = try #require(turns.first { $0.role == .person })
        #expect(told.text.hasPrefix(Inbox.heading) && told.text.hasSuffix("Calendar: dentist at 3."))
        #expect(told.ref.device == h.hubID)
        #expect(try await h.replies().count == 1)
        #expect(Inbox.isNothing(" nothing to report.\n") && !Inbox.isNothing("Nothing to report, except the dentist."))
    }

    func quiet(_ h: HubRig, over database: (any RecordDatabase)? = nil) -> HubMind {
        let configuration = h.configuration
        return HubMind(database: database ?? h.db, device: h.hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                       brain: h.brain, login: { await MindLogin.check(configuration) },
                       model: { .sonnet }, timing: fast, poll: .seconds(3600), answeringPoll: .seconds(3600))
    }

    func started(_ hub: HubMind) async -> Bool {
        await eventually { let s = await hub.snapshot(); return s.holds && s.passes == 1 && s.lastPass != nil }
    }

    @Test func aNudgeRunsOnePassAndIsAnsweredOnceItsReplyIsIn() async throws {
        let h = try HubRig()
        let hub = quiet(h)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        try await h.phoneSays("hello")
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await h.replies().isEmpty)
        #expect(await within(10) { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34") } == true)
        // Answered when the pass has ended: the reply is already in the log.
        #expect(try await h.replies().count == 1)
        #expect(await hub.snapshot().lastPass?.trigger == .nudge)
        #expect(await hub.snapshot().passes == 2)
        await hub.turnOff()
    }

    @Test func nudgesDuringAPassRunExactlyOneMoreAfterIt() async throws {
        let h = try HubRig()
        let gated = GatedReads(h.db)
        let hub = quiet(h, over: gated)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        let person = try await h.phoneSays("hello")
        gated.close()
        let mark = HubMind.mark(of: person.nonce)
        let first = Task { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: mark) }
        #expect(await eventually { gated.holding == 1 })
        // Two more while that pass is held reading the log: one more pass serves both.
        let second = Task { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: mark) }
        let third = Task { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: mark) }
        try await Task.sleep(for: .milliseconds(300))
        // The pass under way goes on and answers; the next one is held at its read.
        gated.releaseHeld()
        #expect(await within(10) { await first.value } == true)
        #expect(await eventually { gated.holding == 1 })
        // Not answered by the pass that was under way when they came: the one after it.
        try await Task.sleep(for: .milliseconds(300))
        let early = AnswerBox<Bool>()
        Task { _ = await second.value; early.lock.withLock { early.value = true } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(early.lock.withLock { early.value } == nil, "answered by the pass that read before it")
        gated.open()
        #expect(await within(10) { await second.value } == true)
        #expect(await within(10) { await third.value } == true)
        #expect(await hub.snapshot().passes == 3)
        try await Task.sleep(for: .milliseconds(500))
        #expect(await hub.snapshot().passes == 3)
        #expect(try await h.replies().count == 1)
        #expect(gated.mostAtOnce == 1)
        await hub.turnOff()
    }

    @Test func aNudgeForATurnTheLogDoesNotHaveYetIsReadAgainAFewTimes() async throws {
        let h = try HubRig()
        let hub = quiet(h)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        // A mark no turn in the log carries: as a turn the change feed has not caught up with.
        #expect(await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: "zz99zz99"))
        // The nudge's pass and the passes after it, a second apart, in case the feed was behind.
        #expect(await hub.snapshot().passes == 2 + HubMind.againAfterNudgeLimit)
        try await Task.sleep(for: .seconds(1.5))
        #expect(await hub.snapshot().passes == 2 + HubMind.againAfterNudgeLimit)

        // A turn that is in the log, already answered: one pass and no more.
        let person = try await h.phoneSays("hello")
        #expect(await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: HubMind.mark(of: person.nonce)))
        let passes = await hub.snapshot().passes
        #expect(try await h.replies().count == 1)
        #expect(await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: HubMind.mark(of: person.nonce)))
        try await Task.sleep(for: .seconds(1.5))
        #expect(await hub.snapshot().passes == passes + 1)
        await hub.turnOff()
    }

    @Test func aNudgeForAnotherLeaseOrAMindNotAnsweringRunsNothing() async throws {
        let h = try HubRig()
        let hub = quiet(h)
        #expect(await hub.nudge(holder: h.hubID, epoch: 1, mark: "a") == false)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        #expect(await hub.nudge(holder: h.phoneID, epoch: lease.epoch, mark: "a") == false)
        #expect(await hub.nudge(holder: lease.holder, epoch: lease.epoch + 1, mark: "a") == false)
        #expect(await hub.snapshot().passes == 1)
        await hub.willSleep()
        #expect(await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: "a") == false)
        await hub.didWake()
        await hub.turnOff()
    }

    @Test func aNudgeWaitingWhenTheMindStopsIsAnsweredNo() async throws {
        let h = try HubRig()
        let hub = quiet(h)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        try await h.phoneSays("SLOW hello")
        let waiting = Task { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: "a") }
        #expect(await eventually { h.rig.inputs.contains("SLOW hello") })
        // One more while that pass runs, waiting for the pass after it.
        let behind = Task { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: "b") }
        try await Task.sleep(for: .milliseconds(200))
        await hub.turnOff()
        #expect(await within(10) { await waiting.value } == false)
        #expect(await within(10) { await behind.value } == false)
        #expect(try await h.replies().isEmpty)
    }

    /// With no nudge and no push the poll still answers: nothing depends on the nudge.
    @Test func noNudgeStillAnswersByThePoll() async throws {
        let h = try HubRig()
        let configuration = h.configuration
        let hub = HubMind(database: h.db, device: h.hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                          brain: h.brain, login: { await MindLogin.check(configuration) },
                          model: { .sonnet }, timing: fast, poll: .seconds(3600), answeringPoll: .milliseconds(300))
        await hub.turnOn()
        #expect(await started(hub))
        try await h.phoneSays("hello")
        #expect(try await eventually(5) { try await h.replies().count == 1 })
        #expect(await hub.snapshot().lastPass?.trigger == .poll)
        await hub.turnOff()
    }
}
