import Foundation
import Testing
import TopoCore
import TopoCoreTesting
import TopoTurn
@testable import TopoMind

/// Holds the next save of the lease alone, the next fetch of the lease, or the next read of the
/// log once it is answered, until released: a save held is sent, and lands after the release, as a
/// CloudKit request in flight would.
final class PassGate: ForwardingDatabase, @unchecked Sendable {
    enum Hold { case leaseSave, leaseFetch, logRead }
    let base: any RecordDatabase
    private let lock = NSLock()
    private var armed: Hold?
    private var waiter: CheckedContinuation<Void, Never>?
    private var held = false
    init(_ base: any RecordDatabase) { self.base = base }
    func arm(_ hold: Hold) { lock.withLock { armed = hold } }
    var holding: Bool { lock.withLock { held } }
    func release() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { waiter = nil; held = false }; return waiter }
        w?.resume()
    }
    private func hold() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { waiter = c; held = true } }
    }
    private func take(_ hold: Hold, if matches: Bool) -> Bool {
        lock.withLock {
            guard matches, armed == hold else { return false }
            armed = nil
            return true
        }
    }
    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        if take(.leaseSave, if: records.count == 1 && records[0].id == Lease.recordID) { await hold() }
        return try await base.save(records)
    }
    func fetch(_ ids: [RecordID], through base: any RecordDatabase) async throws -> [RecordID: Record] {
        if take(.leaseFetch, if: ids == [Lease.recordID]) { await hold() }
        return try await base.fetch(ids)
    }
    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        let read = try await base.records(ofType: type)
        if take(.logRead, if: type == Turn.recordType) { await hold() }
        return read
    }
}

/// The hub's own probe, as `SocketLeaseProbe` reaches it: the hub's `holds` answers.
final class SelfProbe: LeaseProbe, @unchecked Sendable {
    var hub: HubMind?
    func confirms(_ lease: Lease) async -> Bool {
        guard let hub else { return false }
        return await hub.holds(lease.holder, epoch: lease.epoch)
    }
}

/// The switch turned off while a pass with a turn to answer is in flight: nothing is claimed after
/// the stop's abandon, the brain is not asked, and the lease lapses one duration later.
@Suite struct HubStopMidPassTests {
    private func switchOff(during hold: PassGate.Hold) async throws {
        let h = try HubRig()
        let gate = PassGate(h.db)
        let probe = SelfProbe()
        let configuration = h.configuration
        // Heartbeats rare enough that the save of the lease the gate catches is the pass's renewal.
        let timing = LeaseTiming(duration: 8, heartbeat: 4)
        let hub = HubMind(database: gate, device: h.hubID, endpoint: "127.0.0.1:1", probe: probe,
                          brain: h.brain, login: { await MindLogin.check(configuration) },
                          model: { .sonnet }, timing: timing, poll: .milliseconds(100))
        probe.hub = hub
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().holds })
        #expect(await eventually { await hub.snapshot().phase == .answering })
        let before = try #require(await h.lease())
        if hold == .leaseSave { gate.arm(hold) }
        try await h.phoneSays("hello there")
        if hold == .logRead { gate.arm(hold) }
        #expect(await eventually { gate.holding })
        let off = Task { await hub.turnOff() }
        #expect(await eventually { await hub.snapshot().holds == false })
        gate.release()
        await off.value
        let after = try #require(await h.lease())
        #expect(await hub.snapshot().phase == .off)
        // Mutant: a pass's claims made without the session's mark.
        #expect(after.epoch == before.epoch, "the lease was claimed after the switch went off")
        #expect(!(await hub.snapshot().holds), "the hub holds the lease with the switch off")
        #expect(!h.rig.inputs.contains { $0.contains("hello there") }, "the brain was asked after the switch went off")
        try await Task.sleep(for: .seconds(9))
        #expect(try #require(await h.lease()).isExpired(at: Date()), "the lease is still being renewed after the switch went off")
    }

    @Test func switchOffWhileAPassRenewsTheLeaseLeavesNoLeaseHeld() async throws {
        try await switchOff(during: .leaseSave)
    }

    @Test func switchOffWhileAPassReadsTheLogLeavesNoLeaseHeld() async throws {
        try await switchOff(during: .logRead)
    }

    /// A stop that lands while a pass asks for a lapsed lease, with a turn waiting: that `acquire()`
    /// is refused, and the runner the pass goes on to, under the session's mark, claims nothing
    /// either and asks the brain nothing.
    @Test func switchOffWhileAPassAsksForALapsedLeaseLeavesNoLeaseHeld() async throws {
        let h = try HubRig()
        let gate = PassGate(h.db)
        let configuration = h.configuration
        // No heartbeat runs, so the lease lapses a second after the start's takeover.
        let hub = HubMind(database: gate, device: h.hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                          brain: h.brain, login: { await MindLogin.check(configuration) }, model: { .sonnet },
                          timing: LeaseTiming(duration: 1, heartbeat: 3600), poll: .seconds(3600), answeringPoll: .seconds(3600),
                          leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().phase == .answering })
        #expect(await eventually { await hub.snapshot().holds == false })
        let before = try #require(await h.lease())
        try await h.phoneSays("hello there")
        gate.arm(.leaseFetch)
        await hub.trigger(.push)
        #expect(await eventually { gate.holding })
        let abandons = await hub.lease.abandons
        let off = Task { await hub.turnOff() }
        #expect(await eventually { await hub.lease.abandons > abandons })
        gate.release()
        await off.value
        // Mutant: the runner handed no mark (`answerPending(since: nil, …)`), so it takes one after the abandon.
        #expect(try #require(await h.lease()).epoch == before.epoch, "the lease was claimed after the switch went off")
        #expect(await hub.lease.held == nil, "the hub holds the lease with the switch off")
        #expect(!h.rig.inputs.contains { $0.contains("hello there") }, "the brain was asked after the switch went off")
    }

    /// A stop that lands between a pass's look at the lease and its `acquire()` of a lapsed lease:
    /// the lease lapses as soon as it is claimed and heartbeats never run, so every pass asks for
    /// it, and the Mac goes to sleep and wakes again and again while the passes run back to back.
    /// After each sleep the lease holds nothing. The window is one suspension of a pass's several,
    /// so a run hits it a few times rather than every time.
    @Test func aSleepAmongPassesThatAskForTheLeaseLeavesNothingHeld() async throws {
        let h = try HubRig()
        let hub = HubMind(database: h.db, device: h.hubID, endpoint: "127.0.0.1:1", probe: Confirming(),
                          brain: h.brain, login: { .signedIn("test") }, model: { .sonnet },
                          timing: LeaseTiming(duration: 0.001, heartbeat: 3600), poll: .zero, answeringPoll: .zero,
                          leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        await hub.turnOn()
        #expect(await eventually { await hub.snapshot().phase == .answering })
        for round in 0..<300 {
            try await Task.sleep(for: .microseconds(Int.random(in: 0...3000)))
            await hub.willSleep()
            // Mutant: the pass's `acquire()` of a lapsed lease made without the session's mark.
            if await hub.lease.held != nil {
                Issue.record("a claim landed after the sleep's abandon, round \(round)")
                break
            }
            await hub.didWake()
        }
        await hub.turnOff()
    }
}
