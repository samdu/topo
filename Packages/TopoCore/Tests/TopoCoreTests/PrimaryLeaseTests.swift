import Foundation
import Testing
import TopoCore
import TopoCoreTesting

@Suite struct ContinuousUptimeTests {
    @Test func defaultMonotonicClockOnlyGoesForwardAndTracksRealTime() async throws {
        let a = PrimaryLease.continuousUptime()
        try await Task.sleep(for: .milliseconds(20))
        let b = PrimaryLease.continuousUptime()
        #expect(a > 0)
        #expect(b - a >= 0.02)
        #expect(b - a < 5)
    }

    /// The only test here on the real clocks, so its lease has to be longer than a loaded
    /// machine takes to claim one: at fifty milliseconds the claim itself could eat the lease
    /// and the holder was no longer primary by the line after it (#94).
    @Test func aLeaseOnTheDefaultClocksLapsesInRealTime() async throws {
        let db = InMemoryRecordDatabase()
        let p = PrimaryLease(database: db, device: phone, endpoint: nil, probe: StubProbe.allDead,
                             timing: LeaseTiming(duration: 1, heartbeat: 60), sleep: Ticker().sleep)
        _ = try await p.acquire()
        #expect(await p.isPrimary())
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(!(await p.isPrimary()))
    }
}

@Suite struct PrimaryLeaseTests {
    let db = InMemoryRecordDatabase()
    let clock = ManualClock()

    func lease(_ device: DeviceID, probe: StubProbe = .allAlive, ticker: Ticker = Ticker()) -> PrimaryLease {
        PrimaryLease(database: db, device: device, endpoint: "\(device.rawValue).local:1",
                     probe: probe, now: clock.read, monotonic: clock.uptime, sleep: ticker.sleep)
    }

    @Test func firstClaimCreatesTheRecord() async throws {
        let p = lease(phone)
        let outcome = try await p.acquire()
        let held = try #require(await p.held)
        #expect(outcome == .primary(held))
        #expect(held.holder == phone && held.epoch == 1)
        #expect(held.expiresAt == clock.now + 10)
        #expect(await p.isPrimary())
    }

    @Test func theFirstClaimIsWonByExactlyOneDevice() async throws {
        // A staked record names no endpoint, so no probe can confirm it.
        let p = lease(phone, probe: .allDead), h = lease(hub, probe: .allDead)
        let (a, b) = try await (p.claimIfNone(), h.claimIfNone())
        #expect(a != b)
        #expect(!(try await p.claimIfNone()))
        let pHeld = await p.held, hHeld = await h.held
        #expect(pHeld == nil && hHeld == nil)
        let record = try #require(await db.current(Lease.recordID))
        #expect(Lease(record: record)?.holder == (a ? phone : hub))
        // The winner takes it properly on its first turn; the loser defers.
        let winner = a ? p : h
        guard case .primary = try await winner.acquire() else { Issue.record("winner should hold"); return }
    }

    @Test func aClaimOverALapsedVersionFailsIfAHeartbeatLandedFirst() async throws {
        let h = lease(hub)
        _ = try await h.acquire()
        clock.advance(11)
        let lapsed = try #require(await db.current(Lease.recordID))
        // The holder heartbeats between the read and the claim: the version moved.
        clock.advance(-2)
        #expect(try await h.heartbeat())
        let p = lease(phone, probe: .allDead)
        clock.advance(2)
        #expect(!(try await p.claim(overLapsed: lapsed)))
        #expect(!(await p.isPrimary()))
        // Read again, lapsed for real, the claim goes through.
        clock.advance(11)
        let again = try #require(await db.current(Lease.recordID))
        #expect(try await p.claim(overLapsed: again))
        #expect(await p.isPrimary())
        #expect(await p.held?.epoch == 2)
        // Not over a fresh one, and not over its own.
        let fresh = try #require(await db.current(Lease.recordID))
        #expect(!(try await h.claim(overLapsed: fresh)))
    }

    @Test func anAbandonedLeaseStopsHeartbeatingAndLapses() async throws {
        let ticker = Ticker()
        let p = lease(phone, ticker: ticker)
        _ = try await p.acquire()
        #expect(await p.isPrimary())
        await p.abandon()
        #expect(!(await p.isPrimary()))
        #expect(await p.held == nil)
        let before = try #require(await db.current(Lease.recordID)).changeTag
        await ticker.tick(); await ticker.tick()
        #expect(try #require(await db.current(Lease.recordID)).changeTag == before)
        clock.advance(11)
        #expect(Lease(record: try #require(await db.current(Lease.recordID)))?.isExpired(at: clock.now) == true)
    }

    @Test func heartbeatExtendsWithoutChangingEpoch() async throws {
        let p = lease(phone)
        _ = try await p.acquire()
        clock.advance(5)
        #expect(try await p.heartbeat())
        let held = try #require(await p.held)
        #expect(held.epoch == 1 && held.expiresAt == clock.now + 10)
        clock.advance(9)
        #expect(await p.isPrimary())
    }

    @Test func heartbeatsRunOnTheirOwnOnceGranted() async throws {
        let ticker = Ticker()
        let p = lease(phone, ticker: ticker)
        _ = try await p.acquire()
        #expect(await eventually { await ticker.sleeping == 1 })
        clock.advance(5)
        await ticker.tick()
        let due = clock.now + 10
        #expect(await eventually { await p.held?.expiresAt == due })
        #expect(await p.held?.epoch == 1)
        #expect(await eventually { await ticker.sleeping == 1 })
    }

    @Test func heartbeatLoopEndsWhenDisplaced() async throws {
        let hubTicker = Ticker()
        let h = lease(hub, ticker: hubTicker)
        _ = try await h.acquire()
        #expect(await eventually { await hubTicker.sleeping == 1 })
        clock.advance(1)
        _ = try await lease(phone, probe: .allDead).acquire()
        await hubTicker.tick()
        #expect(await eventually { await h.held == nil })
        #expect(!(await h.isPrimary()))
        #expect(await hubTicker.sleeping == 0)
    }

    @Test func holderThatCannotHeartbeatIsNotPrimaryAfterExpiry() async throws {
        let p = lease(phone)
        _ = try await p.acquire()
        clock.advance(10)
        #expect(!(await p.isPrimary()))
        #expect(try await !p.heartbeat())
        #expect(await p.held == nil)
    }

    @Test func retakingOwnLapsedLeaseIsANewClaim() async throws {
        let p = lease(phone)
        _ = try await p.acquire()
        clock.advance(60)
        #expect(!(await p.isPrimary()))
        _ = try await p.acquire()
        #expect(await p.held?.epoch == 2)
        #expect(await p.isPrimary())
    }

    @Test func liveHolderKeepsTheLease() async throws {
        _ = try await lease(hub).acquire()
        clock.advance(3)
        let probe = StubProbe.allAlive
        let p = lease(phone, probe: probe)
        let outcome = try await p.acquire()
        guard case .held(let by) = outcome else { Issue.record("expected .held, got \(outcome)"); return }
        #expect(by.holder == hub)
        #expect(await probe.asked == [hub])
        #expect(!(await p.isPrimary()))
    }

    @Test func deadHolderIsReplacedOnAFailedProbeBeforeExpiry() async throws {
        _ = try await lease(hub).acquire()
        clock.advance(1)
        let probe = StubProbe.allDead
        let p = lease(phone, probe: probe)
        let outcome = try await p.acquire()
        let held = try #require(await p.held)
        #expect(outcome == .primary(held))
        #expect(held.holder == phone && held.epoch == 2)
        #expect(await probe.asked == [hub])
    }

    @Test func expiredLeaseIsClaimedWithoutProbing() async throws {
        _ = try await lease(hub).acquire()
        clock.advance(10)
        let probe = StubProbe.allAlive
        let p = lease(phone, probe: probe)
        _ = try await p.acquire()
        #expect(await p.held?.holder == phone)
        #expect(await probe.asked.isEmpty)
    }

    @Test func slowProbeStillMintsAFreshLease() async throws {
        _ = try await lease(hub).acquire()
        clock.advance(1)
        let slow = SlowProbe(clock: clock, cost: 12, answer: false)
        let p = PrimaryLease(database: db, device: phone, endpoint: nil, probe: slow, now: clock.read, sleep: Ticker().sleep)
        guard case .primary(let l) = try await p.acquire() else { Issue.record("expected .primary"); return }
        #expect(l.expiresAt == clock.now + 10)
        #expect(await p.isPrimary())
    }

    @Test func displacedHolderLearnsOnHeartbeat() async throws {
        let h = lease(hub)
        _ = try await h.acquire()
        clock.advance(1)
        _ = try await lease(phone, probe: .allDead).acquire()
        #expect(await h.isPrimary())
        #expect(try await !h.heartbeat())
        #expect(!(await h.isPrimary()))
        #expect(await h.held == nil)
    }

    @Test func aBatchSavedWithAHeartbeatLandsOnlyWhileTheLeaseIsHeld() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        let first = Record(type: "Note", id: RecordID("note/1"))
        clock.advance(2)
        let saved = try #require(try await h.heartbeat(saving: [first]))
        #expect(saved.map(\.id) == [first.id])
        #expect(await db.current(first.id) != nil)
        let held = try #require(await h.held)
        #expect(held.epoch == 1 && held.expiresAt == clock.now + 10)

        clock.advance(1)
        _ = try await lease(phone, probe: .allDead).acquire()
        let second = Record(type: "Note", id: RecordID("note/2"))
        #expect(try await h.heartbeat(saving: [second]) == nil)
        #expect(await db.current(second.id) == nil)
        #expect(!(await h.isPrimary()))
        // Displaced, so it yields to the taker rather than claiming back.
        guard case .unreachable(let taker) = try await h.acquire() else { Issue.record("should yield"); return }
        #expect(taker.holder == phone)
    }

    @Test func aConflictOnTheBatchItselfLeavesTheLeaseHeldAndPropagates() async throws {
        let h = lease(hub)
        _ = try await h.acquire()
        let taken = Record(type: "Note", id: RecordID("note/1"))
        _ = try await db.save([taken])
        await #expect(throws: RecordDatabaseError.self) { try await h.heartbeat(saving: [taken]) }
        #expect(await h.isPrimary())
    }

    @Test func aBatchNotHeldIsRefusedWithoutAWrite() async throws {
        let h = lease(hub)
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/1"))]) == nil)
        #expect(await db.current(RecordID("note/1")) == nil)
    }

    @Test func aBatchAfterHeartbeatsRanLateClaimsAfreshWhileNobodyElseHasClaimed() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        // No heartbeat landed inside the duration: not primary, and nobody took the lease.
        clock.advance(11)
        #expect(!(await h.isPrimary()))
        let note = Record(type: "Note", id: RecordID("note/1"))
        let saved = try #require(try await h.heartbeat(saving: [note]))
        #expect(saved.map(\.id) == [note.id])
        #expect(await db.current(note.id) != nil)
        // A fresh claim, one epoch on, in the batch's own save.
        let held = try #require(await h.held)
        #expect(held.epoch == 2 && held.expiresAt == clock.now + 10)
        #expect(await h.isPrimary())
        let record = try #require(await db.current(Lease.recordID))
        #expect(Lease(record: record) == held)
    }

    @Test func aBatchClaimsAfreshAfterTheHeartbeatLoopFoundTheLeaseLapsed() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        clock.advance(11)
        // The late heartbeat itself finds the lapse: the lease is no longer held.
        #expect(try await !h.heartbeat())
        #expect(await h.held == nil)
        let note = Record(type: "Note", id: RecordID("note/1"))
        #expect(try await h.heartbeat(saving: [note]) != nil)
        #expect(await h.held?.epoch == 2)
        #expect(await h.isPrimary())
    }

    @Test func aBatchClaimsAfreshOverALateHeartbeatOfItsOwnThatLanded() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        // A heartbeat that reached the server and whose answer never came back: the record is
        // this lease at a version the holder never saw.
        let mine = try #require(await db.current(Lease.recordID))
        _ = try await db.save([mine])
        clock.advance(11)
        let note = Record(type: "Note", id: RecordID("note/1"))
        #expect(try await h.heartbeat(saving: [note]) != nil)
        #expect(await db.current(note.id) != nil)
        #expect(await h.held?.epoch == 2)
    }

    @Test func aBatchAfterTheLeaseLapsedIsRefusedOnceAnotherDeviceHasClaimed() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        clock.advance(11)
        // The lapsed lease is anybody's: the phone claims it without a probe.
        guard case .primary = try await lease(phone, probe: .allDead).acquire() else { Issue.record("phone should claim"); return }
        let note = Record(type: "Note", id: RecordID("note/1"))
        #expect(try await h.heartbeat(saving: [note]) == nil)
        #expect(await db.current(note.id) == nil)
        #expect(!(await h.isPrimary()))
        let record = try #require(await db.current(Lease.recordID))
        #expect(Lease(record: record)?.holder == phone)
        // It yields to the claimant, as a displaced holder does.
        guard case .unreachable(let taker) = try await h.acquire() else { Issue.record("should yield"); return }
        #expect(taker.holder == phone)
        // And nothing is left to claim over: a second batch is refused without a read deciding it.
        #expect(try await h.heartbeat(saving: [note]) == nil)
        #expect(await db.current(note.id) == nil)
    }

    @Test func aClaimLandingBetweenTheLapsedHoldersReadAndItsBatchRefusesTheBatch() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        clock.advance(11)
        let p = lease(phone, probe: .allDead)
        let note = Record(type: "Note", id: RecordID("note/1"))
        // The phone claims after the hub has read the record and before the hub's batch is judged.
        let db = db
        await db.setBeforeSave { records in
            guard records.contains(where: { $0.id == note.id }) else { return }
            await db.setBeforeSave(nil)
            _ = try? await p.acquire()
        }
        #expect(try await h.heartbeat(saving: [note]) == nil)
        #expect(await db.current(note.id) == nil)
        #expect(await p.isPrimary())
        #expect(!(await h.isPrimary()))
        let record = try #require(await db.current(Lease.recordID))
        #expect(Lease(record: record)?.holder == phone)
    }

    @Test func aLeaseAbandonedWhileTheBatchReadsTheRecordIsNotClaimedAfresh() async throws {
        let reads = ReadGate(db)
        let h = PrimaryLease(database: reads, device: hub, endpoint: "hub.local:1", probe: StubProbe.allDead,
                             now: clock.read, monotonic: clock.uptime, sleep: Ticker().sleep)
        _ = try await h.acquire()
        clock.advance(11)
        #expect(try await !h.heartbeat())
        // The batch's read of the record is out when the claim is abandoned.
        await reads.hold()
        let note = Record(type: "Note", id: RecordID("note/1"))
        let batch = Task { try await h.heartbeat(saving: [note]) }
        #expect(await eventually { await reads.waiting })
        await h.abandon()
        await reads.release()
        #expect(try await batch.value == nil)
        #expect(await db.current(note.id) == nil)
        #expect(!(await h.isPrimary()))
        let record = try #require(await db.current(Lease.recordID))
        #expect(Lease(record: record)?.epoch == 1)
    }

    @Test func aBatchWhoseClaimWasAbandonedIsNotWrittenUnderALeaseTakenSince() async throws {
        let reads = ReadGate(db)
        let h = PrimaryLease(database: reads, device: hub, endpoint: "hub.local:1", probe: StubProbe.allDead,
                             now: clock.read, monotonic: clock.uptime, sleep: Ticker().sleep)
        _ = try await h.acquire()
        clock.advance(11)
        #expect(try await !h.heartbeat())
        await reads.hold()
        let note = Record(type: "Note", id: RecordID("note/1"))
        let batch = Task { try await h.heartbeat(saving: [note]) }
        #expect(await eventually { await reads.waiting })
        // The claim is abandoned and the same device takes the lease again, all while the
        // batch's read is out.
        await h.abandon()
        guard case .primary(let again) = try await h.acquire() else { Issue.record("should claim again"); return }
        #expect(again.epoch == 2)
        await reads.release()
        #expect(try await batch.value == nil)
        #expect(await db.current(note.id) == nil)
        // The lease taken since is untouched by the batch that was not its own.
        #expect(await h.held == again)
        #expect(await h.isPrimary())
    }

    @Test func aFreshClaimsAnswerAfterALaterClaimLeavesTheLaterClaimHeld() async throws {
        let slow = SlowAnswer(db)
        let h = PrimaryLease(database: slow, device: hub, endpoint: "hub.local:1", probe: StubProbe.allDead,
                             now: clock.read, monotonic: clock.uptime, sleep: Ticker().sleep)
        _ = try await h.acquire()
        clock.advance(11)
        // The batch's fresh claim lands at epoch 2 and its answer does not come back.
        await slow.holdNextAnswer()
        let note = Record(type: "Note", id: RecordID("note/1"))
        let batch = Task { try await h.heartbeat(saving: [note]) }
        #expect(await eventually { await slow.waiting })
        // A turn's `acquire()` reads that claim meanwhile and, holding nothing, claims epoch 3.
        guard case .primary(let later) = try await h.acquire() else { Issue.record("should claim"); return }
        #expect(later.epoch == 3)
        await slow.release()
        // The records landed, and the answer about epoch 2 replaces nothing.
        #expect(try await batch.value?.map(\.id) == [note.id])
        #expect(await h.held == later)
        #expect(await h.isPrimary())
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/2"))]) != nil)
        let record = try #require(await db.current(Lease.recordID))
        #expect(Lease(record: record)?.epoch == 3)
    }

    @Test func aLateHeartbeatsAnswerAfterTheFreshClaimHasRunOutIsNotPrimary() async throws {
        let slow = SlowAnswer(db)
        let h = PrimaryLease(database: slow, device: hub, endpoint: "hub.local:1", probe: StubProbe.allDead,
                             now: clock.read, monotonic: clock.uptime, sleep: Ticker().sleep)
        _ = try await h.acquire()
        clock.advance(4)
        await slow.holdNextAnswer()
        let late = Task { try await h.heartbeat() }
        #expect(await eventually { await slow.waiting })
        clock.advance(11)
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/1"))]) != nil)
        // The fresh claim runs out too before the old heartbeat's answer arrives.
        clock.advance(11)
        await slow.release()
        #expect(try await !late.value)
        #expect(!(await h.isPrimary()))
    }

    private func lease(_ device: DeviceID, on database: any RecordDatabase, ticker: Ticker = Ticker()) -> PrimaryLease {
        PrimaryLease(database: database, device: device, endpoint: "\(device.rawValue).local:1", probe: StubProbe.allDead,
                     now: clock.read, monotonic: clock.uptime, sleep: ticker.sleep)
    }

    @Test func aHeartbeatAnsweredAfterThisDeviceYieldedLeavesItYielded() async throws {
        let slow = LateAnswers(db)
        let h = lease(hub, on: slow), p = lease(phone, on: db)
        _ = try await h.acquire()
        clock.advance(4)
        // The heartbeat lands and its answer does not come back.
        await slow.holdNextSaveAnswer()
        let late = Task { try await h.heartbeat() }
        #expect(await eventually { await slow.savesOut == 1 })
        clock.advance(1)
        guard case .primary = try await p.acquire() else { Issue.record("phone should claim"); return }
        clock.advance(1)
        guard case .unreachable = try await h.acquire() else { Issue.record("hub should yield"); return }
        #expect(!(await h.isPrimary()))
        await slow.releaseSaves()
        #expect(try await !late.value)
        #expect(!(await h.isPrimary()))
        #expect(await p.isPrimary())
        #expect(Lease(record: try #require(await db.current(Lease.recordID)))?.holder == phone)
    }

    @Test func aLeaseAbandonedWhileItsHeartbeatIsOutStaysAbandoned() async throws {
        let slow = LateAnswers(db)
        let ticker = Ticker()
        let h = lease(hub, on: slow, ticker: ticker)
        _ = try await h.acquire()
        #expect(await eventually { await ticker.sleeping == 1 })
        clock.advance(5)
        // The loop's own heartbeat lands and its answer does not come back.
        await slow.holdNextSaveAnswer()
        await ticker.tick()
        #expect(await eventually { await slow.savesOut == 1 })
        await h.abandon()
        #expect(await h.held == nil)
        await slow.releaseSaves()
        for _ in 0..<500 { await Task.yield() }
        #expect(await h.held == nil)
        #expect(!(await h.isPrimary()))
        // Nothing renews the record after it.
        let before = await db.current(Lease.recordID)?.changeTag
        clock.advance(4)
        await ticker.tick()
        await ticker.tick()
        for _ in 0..<500 { await Task.yield() }
        #expect(await db.current(Lease.recordID)?.changeTag == before)
    }

    @Test func aBatchWhoseLeaseWasAbandonedWhileItsSaveWasOutLeavesNothingHeld() async throws {
        let slow = LateAnswers(db)
        let h = lease(hub, on: slow)
        _ = try await h.acquire()
        await slow.holdNextSaveAnswer()
        let note = Record(type: "Note", id: RecordID("note/1"))
        let batch = Task { try await h.heartbeat(saving: [note]) }
        #expect(await eventually { await slow.savesOut == 1 })
        await h.abandon()
        await slow.releaseSaves()
        // The save had landed, so its records are reported; the lease is not taken back.
        #expect(try await batch.value?.map(\.id) == [note.id])
        #expect(await h.held == nil)
        #expect(!(await h.isPrimary()))
    }

    @Test func aLateHeartbeatsConflictAfterAFreshClaimLeavesTheClaimHeld() async throws {
        let slow = LateAnswers(db)
        let h = lease(hub, on: slow)
        _ = try await h.acquire()
        clock.advance(4)
        let gate = SaveGate()
        let db = db
        await db.setBeforeSave { _ in
            await db.setBeforeSave(nil)
            await gate.wait()
        }
        // A heartbeat goes out over the version held and is not yet judged.
        let late = Task { try await h.heartbeat() }
        #expect(await eventually { await gate.isWaiting })
        // A batch heartbeat of the same epoch lands first, so the late one is a conflict with
        // this device's own epoch 1, and its answer does not come back.
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/0"))]) != nil)
        await slow.holdNextSaveAnswer()
        await gate.open()
        #expect(await eventually { await slow.savesOut == 1 })
        clock.advance(11)
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/1"))]) != nil)
        #expect(await h.held?.epoch == 2)
        await slow.releaseSaves()
        _ = try await late.value
        #expect(await h.held?.epoch == 2)
        #expect(await h.isPrimary())
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/2"))]) != nil)
    }

    @Test func aLateConflictAboutATakerSinceGoneLeavesALaterClaimHeld() async throws {
        let slow = LateAnswers(db)
        let h = lease(hub, on: slow), p = lease(phone, on: db)
        _ = try await h.acquire()
        clock.advance(2)
        guard case .primary = try await p.acquire() else { Issue.record("phone should claim"); return }
        await p.abandon()
        // The hub's batch is refused by the phone's lease, and that answer does not come back.
        await slow.holdNextSaveAnswer()
        let batch = Task { try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/1"))]) }
        #expect(await eventually { await slow.savesOut == 1 })
        clock.advance(11)
        guard case .primary(let mine) = try await h.acquire() else { Issue.record("hub should claim"); return }
        #expect(mine.epoch == 3)
        await slow.releaseSaves()
        #expect(try await batch.value == nil)
        #expect(await h.held?.epoch == 3)
        #expect(await h.isPrimary())
    }

    @Test func aTurnsReadOlderThanAFreshClaimDoesNotDisplaceIt() async throws {
        let slow = LateAnswers(db)
        let h = lease(hub, on: slow)
        _ = try await h.acquire()
        clock.advance(11)
        // `acquire()` reads epoch 1 and the answer does not come back.
        await slow.holdNextFetchAnswer()
        let turn = Task { try await h.acquire() }
        #expect(await eventually { await slow.fetchesOut == 1 })
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/1"))]) != nil)
        #expect(await h.held?.epoch == 2)
        await slow.releaseFetches()
        let outcome = try await turn.value
        guard case .primary(let kept) = outcome else { Issue.record("acquire() answered \(outcome)"); return }
        #expect(kept.epoch == 2)
        #expect(await h.isPrimary())
    }

    @Test func aBatchIsRefusedWhenTheRecordIsThisDevicesAtAnotherEpoch() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        clock.advance(11)
        // The phone held the lease in between, and a second instance of the hub holds it now:
        // the record names this device, at an epoch this instance never held.
        _ = try await lease(phone, probe: .allDead).acquire()
        clock.advance(11)
        let second = lease(hub, probe: .allDead)
        guard case .primary(let theirs) = try await second.acquire() else { Issue.record("second should claim"); return }
        #expect(theirs.epoch == 3)
        let note = Record(type: "Note", id: RecordID("note/1"))
        #expect(try await h.heartbeat(saving: [note]) == nil)
        #expect(await db.current(note.id) == nil)
        #expect(await second.isPrimary())
    }

    @Test func aBatchGoesAgainWhenALateHeartbeatOfItsOwnLandsBetweenItsReadAndItsSave() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        clock.advance(11)
        let note = Record(type: "Note", id: RecordID("note/1"))
        let db = db
        await db.setBeforeSave { records in
            guard records.contains(where: { $0.id == note.id }) else { return }
            await db.setBeforeSave(nil)
            // The heartbeat sent before the lapse reaches the server now: same lease, new version.
            if let mine = await db.current(Lease.recordID) { _ = try? await db.save([mine]) }
        }
        #expect(try await h.heartbeat(saving: [note]) != nil)
        #expect(await db.current(note.id) != nil)
        #expect(await h.held?.epoch == 2)
        #expect(await h.isPrimary())
    }

    @Test func aLateHeartbeatsAnswerAfterAFreshClaimLeavesTheClaimHeld() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        clock.advance(4)
        // A heartbeat goes out and its save is slow: held at the server's door.
        let gate = SaveGate()
        let db = db
        await db.setBeforeSave { _ in
            await db.setBeforeSave(nil)
            await gate.wait()
        }
        let late = Task { try await h.heartbeat() }
        #expect(await eventually { await gate.isWaiting })
        clock.advance(11)
        let note = Record(type: "Note", id: RecordID("note/1"))
        #expect(try await h.heartbeat(saving: [note]) != nil)
        #expect(await h.held?.epoch == 2)
        // The heartbeat's save is judged now and loses to the fresh claim: this device's own.
        await gate.open()
        #expect(try await late.value)
        #expect(await h.held?.epoch == 2)
        #expect(await h.isPrimary())
        guard case .primary(let kept) = try await h.acquire() else { Issue.record("yielded to its own claim"); return }
        #expect(kept.epoch == 2)
    }

    @Test func aLateHeartbeatThatLandedAndAnswersAfterAFreshClaimLeavesTheClaimHeld() async throws {
        let slow = SlowAnswer(db)
        let h = PrimaryLease(database: slow, device: hub, endpoint: "hub.local:1", probe: StubProbe.allDead,
                             now: clock.read, monotonic: clock.uptime, sleep: Ticker().sleep)
        _ = try await h.acquire()
        clock.advance(4)
        // The heartbeat reaches the server and its answer does not come back.
        await slow.holdNextAnswer()
        let late = Task { try await h.heartbeat() }
        #expect(await eventually { await slow.waiting })
        clock.advance(11)
        let note = Record(type: "Note", id: RecordID("note/1"))
        #expect(try await h.heartbeat(saving: [note]) != nil)
        #expect(await h.held?.epoch == 2)
        // The answer arrives, about a version the fresh claim has replaced.
        await slow.release()
        #expect(try await late.value)
        #expect(await h.held?.epoch == 2)
        #expect(await h.isPrimary())
        // The claim is still the one held: its heartbeat and its next batch go through.
        #expect(try await h.heartbeat())
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/2"))]) != nil)
        let record = try #require(await db.current(Lease.recordID))
        #expect(Lease(record: record)?.epoch == 2)
    }

    @Test func aFreshClaimSlowerThanTheLeaseIsNotPrimaryWhenItLands() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        clock.advance(11)
        let clock = clock, db = db
        // The save takes longer than the lease is good for, and the wall clock is then set back:
        // the deadline was fixed before the save, on the clock that only goes forward.
        await db.setBeforeSave { _ in
            await db.setBeforeSave(nil)
            clock.advance(11)
            clock.wallStep(-11)
        }
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/1"))]) != nil)
        #expect(!(await h.isPrimary()))
    }

    @Test func anAbandonedLeaseIsNotClaimedAfreshByABatch() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        clock.advance(11)
        #expect(try await !h.heartbeat())
        await h.abandon()
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/1"))]) == nil)
        #expect(await db.current(RecordID("note/1")) == nil)
    }

    @Test func aLeaseLapsedOnTheMonotonicClockAloneIsClaimedAfreshByABatch() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        // The wall clock stepped back across the lapse: the record reads as unexpired, and the
        // holder is not primary all the same.
        clock.advance(11)
        clock.wallStep(-11)
        #expect(!(await h.isPrimary()))
        #expect(try await h.heartbeat(saving: [Record(type: "Note", id: RecordID("note/1"))]) != nil)
        #expect(await h.held?.epoch == 2)
        #expect(await h.isPrimary())
    }

    @Test func displacedHolderDefersToALiveOrUnreachableTakerAndRetakesFromADeadOne() async throws {
        let h = lease(hub, probe: .allDead)
        _ = try await h.acquire()
        clock.advance(1)
        _ = try await lease(phone, probe: .allDead).acquire()

        // The phone took it while the hub was alive; the hub cannot reach
        // the phone but the phone is heartbeating, so the hub yields.
        guard case .unreachable(let taker) = try await h.acquire() else { Issue.record("expected .unreachable"); return }
        #expect(taker.holder == phone && taker.epoch == 2)
        #expect(!(await h.isPrimary()))
        clock.advance(3)
        guard case .unreachable = try await h.acquire() else { Issue.record("expected .unreachable"); return }

        // The phone stops heartbeating: its lease lapses and the hub claims.
        clock.advance(7)
        guard case .primary(let mine) = try await h.acquire() else { Issue.record("expected .primary"); return }
        #expect(mine.epoch == 3)
    }

    @Test func twoColdInstancesOfOneDeviceCreatingTogetherYieldOnePrimary() async throws {
        let none = SetProbe([])
        let a = PrimaryLease(database: db, device: phone, endpoint: "phone:1", probe: none, now: clock.read, sleep: Ticker().sleep)
        let b = PrimaryLease(database: db, device: phone, endpoint: "phone:1", probe: none, now: clock.read, sleep: Ticker().sleep)
        let barrier = Barrier(parties: 2)
        await db.setBeforeSave { _ in await barrier.arrive() }
        async let oa = a.acquire()
        async let ob = b.acquire()
        let outcomes = try await [oa, ob]
        await db.setBeforeSave(nil)
        let primaries = outcomes.filter { if case .primary = $0 { true } else { false } }
        let unreachable = outcomes.filter { if case .unreachable = $0 { true } else { false } }
        #expect(primaries.count == 1)
        #expect(unreachable.count == 1)
        var both = 0.0
        for _ in 0..<10 {
            clock.advance(4)
            _ = try? await a.heartbeat(); _ = try? await b.heartbeat()
            if await a.isPrimary(), await b.isPrimary() { both += 4 }
        }
        #expect(both == 0)
        let aPrimary = await a.isPrimary(), bPrimary = await b.isPrimary()
        #expect(aPrimary != bPrimary)
    }

    @Test func twoInstancesOfOneDeviceAreNotBothPrimary() async throws {
        let a = PrimaryLease(database: db, device: phone, endpoint: "a:1", probe: StubProbe.allDead, now: clock.read, sleep: Ticker().sleep)
        let b = PrimaryLease(database: db, device: phone, endpoint: "b:1", probe: StubProbe.allDead, now: clock.read, sleep: Ticker().sleep)
        _ = try await a.acquire()
        clock.advance(1)
        guard case .primary(let taken) = try await b.acquire() else { Issue.record("expected b to claim"); return }
        #expect(taken.epoch == 2)
        guard case .unreachable = try await a.acquire() else { Issue.record("expected a to yield"); return }
        #expect(!(await a.isPrimary()))
        #expect(await b.isPrimary())
    }

    @Test func restartedHolderReclaimsWhenItsOldEndpointDeniesTheLease() async throws {
        _ = try await lease(hub).acquire()
        clock.advance(2)
        // A fresh instance on the same device: its probe server holds nothing, so it answers no.
        let again = lease(hub, probe: .allDead)
        guard case .primary(let l) = try await again.acquire() else { Issue.record("expected .primary"); return }
        #expect(l.epoch == 2)
    }

    @Test func unparseableLeaseRecordIsClaimedOver() async throws {
        _ = try await db.save(Record(type: Lease.recordType, id: Lease.recordID, fields: ["holder": .string("hub"), "epoch": .int(7)]))
        let p = lease(phone)
        guard case .primary(let l) = try await p.acquire() else { Issue.record("expected .primary"); return }
        #expect(l.epoch == 8)
    }

    @Test func overlappingHeartbeatsDoNotLoseTheLease() async throws {
        let p = lease(phone)
        _ = try await p.acquire()
        let barrier = Barrier(parties: 2)
        await db.setBeforeSave { _ in await barrier.arrive() }
        async let h1 = p.heartbeat()
        async let h2 = p.heartbeat()
        let results = try await [h1, h2]
        #expect(results == [true, true])
        #expect(await p.held != nil)
        #expect(await db.current(Lease.recordID)?.string("holder") == phone.rawValue)
    }

    @Test func lossySaveEchoDoesNotTrap() async throws {
        let lossy = LossySaveDatabase(inner: db)
        let p = PrimaryLease(database: lossy, device: phone, endpoint: nil, probe: StubProbe.allDead, now: clock.read, sleep: Ticker().sleep)
        guard case .primary = try await p.acquire() else { Issue.record("expected .primary"); return }
        #expect(await p.isPrimary())
        #expect(try await p.heartbeat())
    }

    @Test func theHubTakesOverALiveHolderWhoThenYields() async throws {
        let p = lease(phone, probe: .allAlive)
        _ = try await p.acquire()
        clock.advance(2)
        let h = lease(hub, probe: .allAlive)
        guard case .primary(let taken) = try await h.takeOver() else { Issue.record("expected .primary"); return }
        #expect(taken.epoch == 2)
        #expect(await h.isPrimary())
        // The phone learns at its heartbeat, and its next turn defers to the hub.
        #expect(try await !p.heartbeat())
        #expect(!(await p.isPrimary()))
        guard case .held(let by) = try await p.acquire() else { Issue.record("expected .held"); return }
        #expect(by.holder == hub && by.epoch == 2)
        // The hub's next take-over is a renewal, not a new claim.
        clock.advance(5)
        guard case .primary(let again) = try await h.takeOver() else { Issue.record("expected .primary"); return }
        #expect(again.epoch == 2 && again.expiresAt == clock.now + 10)
    }

    @Test func takeOverCreatesWhenNobodyHolds() async throws {
        let h = lease(hub)
        guard case .primary(let l) = try await h.takeOver() else { Issue.record("expected .primary"); return }
        #expect(l.epoch == 1)
        #expect(await h.isPrimary())
    }

    @Test func twoClaimantsRacingForADeadHolderProduceOnePrimary() async throws {
        _ = try await lease(hub).acquire()
        clock.advance(2)

        // Both claimants fetch the same version, then save together.
        let barrier = Barrier(parties: 2)
        await db.setBeforeSave { _ in await barrier.arrive() }
        let hubIsDead = StubProbe { $0.holder != hub }
        let phoneLease = lease(phone, probe: hubIsDead)
        let watchLease = lease(watch, probe: hubIsDead)

        async let a = phoneLease.acquire()
        async let b = watchLease.acquire()
        let outcomes = try await [a, b]

        let primaries = outcomes.compactMap { if case .primary(let l) = $0 { l } else { nil } }
        let deferred = outcomes.compactMap { if case .held(let l) = $0 { l } else { nil } }
        #expect(primaries.count == 1)
        #expect(deferred.count == 1)
        #expect(deferred.first == primaries.first)
        #expect(primaries.first?.epoch == 2)

        let asked = await hubIsDead.asked
        #expect(asked.filter { $0 == hub }.count == 2)
        #expect(asked.contains(primaries.first!.holder))

        let phonePrimary = await phoneLease.isPrimary()
        let watchPrimary = await watchLease.isPrimary()
        #expect(phonePrimary != watchPrimary)
    }

    @Test func losingTheClaimToAHeartbeatingHolderYieldsToIt() async throws {
        let mover = lease(hub)
        _ = try await mover.acquire()
        // Every time the phone tries to write, the hub has just heartbeated.
        await db.setBeforeSave { records in
            if records.first?.string("holder") == phone.rawValue {
                _ = try? await mover.heartbeat()
            }
        }
        let p = lease(phone, probe: .allDead)
        guard case .unreachable(let by) = try await p.acquire() else { Issue.record("expected .unreachable"); return }
        #expect(by.holder == hub)
        #expect(!(await p.isPrimary()))
        #expect(await mover.isPrimary())
    }
}
