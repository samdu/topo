import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// A store whose change feed is behind on the turns a test names, as the zone's feed is just after
/// a phone's save; a fetch by ID finds them.
final class FeedLag: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    private let lock = NSLock()
    private var hidden: Set<RecordID> = []
    init(_ inner: any RecordDatabase) { base = inner }
    func hide(_ ref: TurnRef) { _ = lock.withLock { hidden.insert(Turn.recordID(for: ref)) } }
    func unhide(_ ref: TurnRef) { _ = lock.withLock { hidden.remove(Turn.recordID(for: ref)) } }
    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        let all = try await base.records(ofType: type)
        let hidden = lock.withLock { self.hidden }
        return all.filter { !hidden.contains($0.id) }
    }
}

/// The end mark of the pass whose trigger is `trigger`, the last such, once it has one.
func ended(_ marks: Marks, after trigger: String) -> String? {
    let all = marks.all
    guard let start = all.lastIndex(of: trigger) else { return nil }
    return all[start...].first { $0.hasPrefix("hub.pass.end") }
}

/// A phone's heads-up (`HubMind.headsUp`): the pass it begins gets ready while the phone's save is
/// out, and asks the brain once the turn it is told of is read, on a renewal of its own.
@Suite(.serialized) struct HubComingTests {
    func quiet(_ h: HubRig, over database: (any RecordDatabase)? = nil, bound: Duration = .seconds(30)) -> HubMind {
        let configuration = h.configuration
        return HubMind(database: database ?? h.db, device: h.hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                       brain: h.brain, login: { await MindLogin.check(configuration) },
                       model: { .sonnet }, timing: fast, poll: .seconds(3600), answeringPoll: .seconds(3600),
                       comingBound: bound)
    }

    func started(_ hub: HubMind) async -> Bool {
        await eventually { let s = await hub.snapshot(); return s.holds && s.passes == 1 && s.lastPass != nil }
    }

    /// The phone's turn under a nonce the test chose, so its mark is known before it is saved.
    @discardableResult
    func phoneSays(_ text: String, _ h: HubRig, nonce: String, hiddenFrom feed: FeedLag? = nil) async throws -> Turn {
        let log = TurnLog(database: h.db)
        let turn = try await log.writer(for: h.phoneID).append(.person, text, continuing: try await log.read(), nonce: nonce)
        feed?.hide(turn.ref)
        return turn
    }

    @Test func aHeadsUpThenItsTurnIsAskedOnceOnARenewalOfItsOwn() async throws {
        let h = try HubRig()
        let feed = FeedLag(h.db)
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let hub = quiet(h, over: feed)
            await hub.turnOn()
            #expect(await started(hub))
            let lease = try #require(await h.lease())
            let ticket = try #require(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "AB12cd34"))
            // A second heads-up while the first's pass is asked for or waits is no.
            #expect(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ff00ff00") == nil)
            #expect(await eventually { marks.all.contains { $0.hasPrefix("hub.pass.read") } })
            let person = try await phoneSays("hello", h, nonce: "ab12cd34-0000-4000-8000-000000000000", hiddenFrom: feed)
            ticket.saved(person.ref)
            // The nudge down the heads-up's connection is the waiting pass's to answer.
            #expect(await within(10) { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34") } == true)
            #expect(try await h.replies().count == 1)
            #expect(h.rig.inputs == ["hello"])
            #expect(await hub.snapshot().lastPass?.trigger == .coming)
            try await Task.sleep(for: .milliseconds(300))
            // Mutant: the nudge queued for a pass after the one that answered it.
            #expect(await hub.snapshot().passes == 2)
            await hub.turnOff()
        }
        let pass = Array(marks.all[try #require(marks.all.lastIndex { $0.hasPrefix("hub.pass.trigger") })...])
        #expect(pass.first == "hub.pass.trigger coming")
        #expect(marks.all.contains { $0.hasPrefix("hub.coming.received nudge=AB12cd34") })
        #expect(pass.contains { $0.hasPrefix("hub.pass.waited") && $0.hasSuffix(" saved") })
        let leaseMark = try #require(pass.first { $0.hasPrefix("hub.pass.lease") })
        let age = try #require(leaseMark.split(separator: " ").first { $0.hasPrefix("age=") }.flatMap { Int($0.dropFirst(4)) })
        #expect(Double(age) <= TurnRunner.askWithin(fast) * 1000)
    }

    @Test func aHeadsUpWhoseTurnNeverComesEndsAtItsBoundAskingNothing() async throws {
        let h = try HubRig()
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let hub = quiet(h, bound: .milliseconds(600))
            await hub.turnOn()
            #expect(await started(hub))
            let lease = try #require(await h.lease())
            let began = Date()
            _ = try #require(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34"))
            #expect(await eventually { ended(marks, after: "hub.pass.trigger coming") != nil })
            #expect(Date().timeIntervalSince(began) >= 0.6)
            #expect(await hub.snapshot().lastPass?.outcome == .nothing)
            await hub.turnOff()
        }
        #expect(marks.all.contains { $0.hasPrefix("hub.pass.waited") && $0.hasSuffix(" gone") })
        #expect(!marks.all.contains { $0.hasPrefix("hub.pass.asked") })
        #expect(h.rig.inputs.isEmpty)
        #expect(try await h.replies().isEmpty)
    }

    @Test func aHeadsUpWhileAPassRunsIsRefused() async throws {
        let h = try HubRig()
        let gated = GatedReads(h.db)
        let hub = quiet(h, over: gated)
        await hub.turnOn()
        #expect(await started(hub))
        let lease = try #require(await h.lease())
        // Mutant: a heads-up taken for a lease this Mac does not hold.
        #expect(await hub.headsUp(holder: lease.holder, epoch: lease.epoch + 1, mark: "ab12cd34") == nil)
        #expect(await hub.headsUp(holder: h.phoneID, epoch: lease.epoch, mark: "ab12cd34") == nil)
        gated.close()
        await hub.trigger(.push)
        #expect(await eventually { gated.holding == 1 })
        #expect(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34") == nil)
        gated.open()
        #expect(await eventually { await hub.snapshot().passes == 2 })
        #expect(await hub.headsUp(holder: lease.holder, epoch: lease.epoch + 1, mark: "ab12cd34") == nil)
        await hub.turnOff()
        #expect(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34") == nil)
    }

    @Test func aStopOrASleepDuringTheWaitReturnsAtOnceAndHoldsNoLease() async throws {
        for sleeping in [false, true] {
            let h = try HubRig()
            let marks = Marks()
            try await Perf.$observer.withValue({ marks.add($0) }) {
                let hub = quiet(h)
                await hub.turnOn()
                #expect(await started(hub))
                let lease = try #require(await h.lease())
                let ticket = try #require(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34"))
                let nudge = Task { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34") }
                #expect(await eventually { marks.all.contains("hub.pass.trigger coming") && marks.all.contains { $0.hasPrefix("hub.pass.read") } })
                let began = Date()
                if sleeping { await hub.willSleep() } else { await hub.turnOff() }
                // Mutant: neither the stop nor the cancelled pass ends the wait, which then waits out the 30 s bound.
                #expect(Date().timeIntervalSince(began) < 5)
                #expect(await !hub.snapshot().holds)
                #expect(await nudge.value == false)
                // The ref arriving after the stop reaches nothing.
                ticket.saved(.init(device: h.phoneID, sequence: 1))
                try await Task.sleep(for: .milliseconds(300))
                #expect(h.rig.inputs.isEmpty)
                if sleeping { await hub.didWake(); await hub.turnOff() }
            }
        }
    }

    @Test func aTurnAlreadyWaitingIsAnsweredWithNoWait() async throws {
        let h = try HubRig()
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let hub = quiet(h)
            await hub.turnOn()
            #expect(await started(hub))
            let lease = try #require(await h.lease())
            try await phoneSays("hello", h, nonce: "ab12cd34-0000-4000-8000-000000000000")
            _ = try #require(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34"))
            #expect(try await eventually { try await h.replies().count == 1 })
            await hub.turnOff()
        }
        #expect(!marks.all.contains { $0.hasPrefix("hub.pass.waited") })
        #expect(h.rig.inputs == ["hello"])
    }

    @Test func anotherDevicesTurnDuringTheWaitIsAnsweredAtOnce() async throws {
        let h = try HubRig()
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let hub = quiet(h)
            await hub.turnOn()
            #expect(await started(hub))
            let lease = try #require(await h.lease())
            _ = try #require(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34"))
            #expect(await eventually { marks.all.contains("hub.pass.trigger coming") && marks.all.contains { $0.hasPrefix("hub.pass.read") } })
            let log = TurnLog(database: h.db)
            _ = try await log.writer(for: DeviceID("pad-99887766")).append(.person, "from the pad", continuing: try await log.read())
            let pushed = Date()
            await hub.trigger(.push)
            // Mutant: a trigger during the wait left until the heads-up's bound, 30 s on.
            #expect(try await eventually(10) { try await h.replies().count == 1 })
            #expect(Date().timeIntervalSince(pushed) < 10)
            await hub.turnOff()
        }
        #expect(marks.all.contains { $0.hasPrefix("hub.pass.waited") && $0.hasSuffix(" other") })
        #expect(h.rig.inputs == ["from the pad"])
    }

    /// Another trigger whose turn the feed does not show yet holds the heads-up's pass a second
    /// at most: the pass ends, and that turn is read again by a pass of its own.
    @Test func anotherTriggerWhoseTurnTheFeedIsBehindOnIsNotHeldBack() async throws {
        let h = try HubRig()
        let feed = FeedLag(h.db)
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let hub = quiet(h, over: feed)
            await hub.turnOn()
            #expect(await started(hub))
            let lease = try #require(await h.lease())
            _ = try #require(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34"))
            #expect(await eventually { marks.all.contains("hub.pass.trigger coming") && marks.all.contains { $0.hasPrefix("hub.pass.read") } })
            let log = TurnLog(database: h.db)
            let pad = try await log.writer(for: DeviceID("pad-99887766")).append(.person, "from the pad", continuing: try await log.read())
            feed.hide(pad.ref)
            let nudged = Date()
            let answered = Task { await hub.nudge(holder: lease.holder, epoch: lease.epoch, mark: String(pad.nonce.prefix(8))) }
            // Mutant: the wait after another trigger left at the heads-up's bound, 30 s on.
            #expect(await eventually(5) { ended(marks, after: "hub.pass.trigger coming") != nil })
            #expect(Date().timeIntervalSince(nudged) < 3)
            feed.unhide(pad.ref)
            #expect(try await eventually(10) { try await h.replies().count == 1 })
            #expect(await answered.value)
            await hub.turnOff()
        }
        #expect(marks.all.contains { $0.hasPrefix("hub.pass.waited") && $0.hasSuffix(" other") })
        #expect(h.rig.inputs == ["from the pad"])
    }

    /// A push that lands before the phone's word of its save (its turn's own push, ahead of the
    /// feed) leaves the heads-up standing: the pass reads the feed again and goes on waiting.
    @Test func aPushAheadOfTheSavedLineLeavesTheHeadsUpStanding() async throws {
        let h = try HubRig()
        let feed = FeedLag(h.db)
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let hub = quiet(h, over: feed)
            await hub.turnOn()
            #expect(await started(hub))
            let lease = try #require(await h.lease())
            let ticket = try #require(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34"))
            #expect(await eventually { marks.all.contains("hub.pass.trigger coming") && marks.all.contains { $0.hasPrefix("hub.pass.read") } })
            let person = try await phoneSays("hello", h, nonce: "ab12cd34-0000-4000-8000-000000000000", hiddenFrom: feed)
            await hub.trigger(.push)
            #expect(await eventually { marks.all.contains { $0.hasPrefix("hub.pass.waited") && $0.hasSuffix(" other") } })
            ticket.saved(person.ref)
            #expect(try await eventually { try await h.replies().count == 1 })
            // Mutant: the timer of the wait the push answered ends the heads-up as it is cancelled.
            #expect(marks.all.contains { $0.hasPrefix("hub.pass.waited") && $0.hasSuffix(" saved") })
            await hub.turnOff()
        }
        #expect(h.rig.inputs == ["hello"])
    }

    @Test func aLeaseTakenDuringTheWaitAsksTheBrainNothing() async throws {
        let h = try HubRig()
        let feed = FeedLag(h.db)
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let hub = quiet(h, over: feed)
            await hub.turnOn()
            #expect(await started(hub))
            let lease = try #require(await h.lease())
            let ticket = try #require(await hub.headsUp(holder: lease.holder, epoch: lease.epoch, mark: "ab12cd34"))
            #expect(await eventually { marks.all.contains("hub.pass.trigger coming") && marks.all.contains { $0.hasPrefix("hub.pass.read") } })
            // The phone takes the lease, and the hub's heartbeat meets the claim.
            let phone = PrimaryLease(database: h.db, device: h.phoneID, endpoint: nil, probe: NoSocketProbe(), timing: fast)
            _ = try await phone.takeOver()
            #expect(await eventually { await !hub.snapshot().holds })
            let person = try await phoneSays("hello", h, nonce: "ab12cd34-0000-4000-8000-000000000000", hiddenFrom: feed)
            ticket.saved(person.ref)
            #expect(await eventually { ended(marks, after: "hub.pass.trigger coming") != nil })
            #expect(await hub.snapshot().lastPass?.outcome == .elsewhere)
            await phone.abandon()
            await hub.turnOff()
        }
        #expect(h.rig.inputs.isEmpty)
        #expect(try await h.replies().isEmpty)
    }
}
