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

    @Test func aLeaseOnTheDefaultClocksLapsesInRealTime() async throws {
        let db = InMemoryRecordDatabase()
        let p = PrimaryLease(database: db, device: phone, endpoint: nil, probe: StubProbe.allDead,
                             timing: LeaseTiming(duration: 0.05, heartbeat: 60), sleep: Ticker().sleep)
        _ = try await p.acquire()
        #expect(await p.isPrimary())
        try await Task.sleep(for: .milliseconds(80))
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
