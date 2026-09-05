import Foundation
import Testing
import TopoCore
import TopoCoreTesting

@Suite struct PrimaryLeaseTests {
    let db = InMemoryRecordDatabase()
    let clock = ManualClock()

    func lease(_ device: DeviceID, probe: StubProbe = .allAlive) -> PrimaryLease {
        PrimaryLease(database: db, device: device, endpoint: "\(device.rawValue).local:1",
                     probe: probe, now: clock.read)
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

    @Test func holderThatCannotHeartbeatIsNotPrimaryAfterExpiry() async throws {
        let p = lease(phone)
        _ = try await p.acquire()
        clock.advance(10)
        #expect(!(await p.isPrimary()))
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

    @Test func displacedHolderRetakesOnlyIfTheNewHolderIsDead() async throws {
        let h = lease(hub)
        _ = try await h.acquire()
        clock.advance(1)
        _ = try await lease(phone, probe: .allDead).acquire()
        guard case .held(let by) = try await h.acquire() else { Issue.record("expected .held"); return }
        #expect(by.holder == phone && by.epoch == 2)

        let h2 = lease(hub, probe: .allDead)
        _ = try await h2.acquire()
        #expect(await h2.held?.epoch == 3)
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

    @Test func claimingWhileTheRecordKeepsChangingGivesUp() async throws {
        let mover = lease(hub)
        _ = try await mover.acquire()
        // Every time the phone tries to write, the hub has already heartbeated.
        await db.setBeforeSave { records in
            if records.first?.string("holder") == phone.rawValue {
                _ = try? await mover.heartbeat()
            }
        }
        let p = lease(phone, probe: .allDead)
        #expect(try await p.acquire() == .contended)
        #expect(!(await p.isPrimary()))
        #expect(await mover.isPrimary())
    }
}
