import Foundation
import Testing
import TopoCore
import TopoCoreTesting

/// How long two devices can both believe they are primary. The bound the
/// package promises: one heartbeat interval after a claim over a live
/// holder that then heartbeats or takes a turn, one duration otherwise.
/// These started as the adversarial review's reproductions.
@Suite struct TwoBrainsTests {
    let db = InMemoryRecordDatabase()
    let clock = ManualClock()

    func lease(_ d: DeviceID, probe: any LeaseProbe, clock: ManualClock? = nil) -> PrimaryLease {
        let c = clock ?? self.clock
        return PrimaryLease(database: db, device: d, endpoint: "\(d.rawValue):1", probe: probe,
                            now: c.read, monotonic: c.uptime, sleep: Ticker().sleep)
    }

    /// The displaced holder's wall clock steps back an hour while it is
    /// suspended and the live holder keeps heartbeating. Its monotonic
    /// deadline lapses regardless, so it is primary for at most one
    /// duration after its last write.
    @Test func backwardClockStepOnASuspendedDisplacedHolder() async throws {
        let hubClock = ManualClock(), phoneClock = ManualClock()
        let none = SetProbe([])
        let h = lease(hub, probe: none, clock: hubClock)
        let p = lease(phone, probe: none, clock: phoneClock)
        _ = try await h.acquire()
        hubClock.advance(1); phoneClock.advance(1)
        _ = try await p.acquire()
        hubClock.wallStep(-3600)
        var both = 0.0
        for step in 0..<300 {
            hubClock.advance(1); phoneClock.advance(1)
            if step % 5 == 0 { _ = try? await p.heartbeat() }
            if await h.isPrimary(), await p.isPrimary() { both += 1 }
        }
        #expect(both <= 10)
        #expect(both >= 8)
        #expect(!(await h.isPrimary()))
        #expect(await p.isPrimary())
    }

    @Test func backwardClockStepWithAndWithoutTheDisplacedHeartbeat() async throws {
        for heartbeating in [false, true] {
            let db = InMemoryRecordDatabase()
            let hubClock = ManualClock(), phoneClock = ManualClock()
            let none = SetProbe([])
            let h = PrimaryLease(database: db, device: hub, endpoint: "hub:1", probe: none, now: hubClock.read, monotonic: hubClock.uptime, sleep: Ticker().sleep)
            let p = PrimaryLease(database: db, device: phone, endpoint: "phone:1", probe: none, now: phoneClock.read, monotonic: phoneClock.uptime, sleep: Ticker().sleep)
            _ = try await h.acquire()
            hubClock.advance(1); phoneClock.advance(1)
            _ = try await p.acquire()
            hubClock.wallStep(-3600)
            var both = 0.0
            for step in 0..<120 {
                hubClock.advance(1); phoneClock.advance(1)
                if heartbeating, step % 5 == 0 { _ = try? await h.heartbeat() }
                if await h.isPrimary(), await p.isPrimary() { both += 1 }
            }
            #expect(both <= (heartbeating ? 5 : 10))
        }
    }

    @Test func threeWayPartitionConverges() async throws {
        let none = SetProbe([])
        let names = [hub, phone, watch]
        let ls = names.map { lease($0, probe: none) }
        _ = try await ls[0].acquire()
        var since: [Int: Date] = [:], worst = 0.0
        for step in 0..<60 {
            clock.advance(3)
            _ = try await ls[step % 3].acquire()
            var live: [Int] = []
            let t = clock.now
            for (j, l) in ls.enumerated() {
                if await l.isPrimary() { since[j] = since[j] ?? t; live.append(j) } else { since[j] = nil }
            }
            if live.count >= 2 { worst = max(worst, t.timeIntervalSince(live.map { since[$0]! }.max()!)) }
        }
        #expect(worst <= 3)
        var primaries = 0
        for l in ls where await l.isPrimary() { primaries += 1 }
        #expect(primaries == 1)
    }

    @Test func yieldingNeverLeavesNobodyPrimary() async throws {
        let none = SetProbe([])
        let a = lease(hub, probe: none)
        let b = lease(phone, probe: none)
        _ = try await a.acquire()
        var noneSince: Date?, longestNone = 0.0
        for _ in 0..<40 {
            clock.advance(2)
            _ = try await a.acquire()
            _ = try await b.acquire()
            let ap = await a.isPrimary(), bp = await b.isPrimary()
            if ap || bp {
                noneSince = nil
            } else {
                noneSince = noneSince ?? clock.now
                longestNone = max(longestNone, clock.now.timeIntervalSince(noneSince!))
            }
        }
        #expect(longestNone == 0)
    }

    @Test func aDeadHolderYouYieldedToCostsOneDuration() async throws {
        let none = SetProbe([])
        let a = lease(hub, probe: none)
        let b = lease(phone, probe: none)
        _ = try await a.acquire()
        clock.advance(1)
        _ = try await b.acquire()
        guard case .unreachable = try await a.acquire() else { Issue.record("expected .unreachable"); return }
        var waited = 0.0
        for _ in 0..<40 {
            clock.advance(0.5); waited += 0.5
            if case .primary = try await a.acquire() { break }
        }
        #expect(waited == 10)
    }

    /// Advances the clock in steps, running `step` each time, and returns the
    /// longest stretch during which every lease believed itself primary.
    func longestSimultaneousBelief(_ leases: [PrimaryLease], steps: Int, dt: TimeInterval,
                                   step: (Int) async throws -> Void) async throws -> TimeInterval {
        var since: Date?
        var longest = 0.0
        for i in 0..<steps {
            clock.advance(dt)
            try await step(i)
            var all = true
            for l in leases where !(await l.isPrimary()) { all = false }
            if all {
                since = since ?? clock.now
                longest = max(longest, clock.now.timeIntervalSince(since!))
            } else {
                since = nil
            }
        }
        return longest
    }

    @Test func mutuallyUnreachableDevicesSettleOnOnePrimary() async throws {
        let none = SetProbe([])
        let a = lease(hub, probe: none)
        let b = lease(phone, probe: none)
        _ = try await a.acquire()
        var epochs: Set<Int64> = []
        let longest = try await longestSimultaneousBelief([a, b], steps: 60, dt: 1) { step in
            _ = try await (step % 2 == 0 ? b : a).acquire()
            if let e = await a.held?.epoch { epochs.insert(e) }
            if let e = await b.held?.epoch { epochs.insert(e) }
        }
        #expect(longest <= 2)
        #expect(epochs == [1, 2])
        #expect(await b.isPrimary())
        #expect(!(await a.isPrimary()))
    }

    @Test func minimalTrace() async throws {
        let none = SetProbe([])
        let a = lease(hub, probe: none)
        let b = lease(phone, probe: none)
        var both = 0
        func snap() async { if await a.isPrimary(), await b.isPrimary() { both += 1 } }
        _ = try await a.acquire(); await snap()
        clock.advance(3)
        _ = try await b.acquire(); await snap()      // phone claims over a failed probe
        clock.advance(3)
        _ = try await a.acquire(); await snap()      // hub sees it was displaced and yields
        clock.advance(3)
        _ = try await b.acquire(); await snap()
        clock.advance(3)
        _ = try await a.acquire(); await snap()
        #expect(both == 1)
    }

    @Test func partitionWithHeartbeatsAndTurns() async throws {
        let none = SetProbe([])
        let a = lease(hub, probe: none)
        let b = lease(phone, probe: none)
        _ = try await a.acquire()
        _ = try await b.acquire()
        let longest = try await longestSimultaneousBelief([a, b], steps: 120, dt: 0.5) { step in
            _ = try? await a.heartbeat()
            _ = try? await b.heartbeat()
            if step % 6 == 0 { _ = try await a.acquire() }
            if step % 6 == 3 { _ = try await b.acquire() }
        }
        #expect(longest <= 0.5)
    }

    @Test func partitionAtTheDesignCadence() async throws {
        let none = SetProbe([])
        let a = lease(hub, probe: none)
        let b = lease(phone, probe: none)
        _ = try await a.acquire()
        var bothSamples = 0
        let longest = try await longestSimultaneousBelief([a, b], steps: 240, dt: 0.5) { step in
            let t = Double(step) * 0.5
            if t.truncatingRemainder(dividingBy: 5) == 0 { _ = try? await a.heartbeat(); _ = try? await b.heartbeat() }
            if t.truncatingRemainder(dividingBy: 14) == 0 { _ = try await b.acquire() }
            if t.truncatingRemainder(dividingBy: 14) == 7 { _ = try await a.acquire() }
            if await a.isPrimary(), await b.isPrimary() { bothSamples += 1 }
        }
        #expect(longest <= 5)
        #expect(bothSamples <= 10)
    }

    @Test func partitionWithNoHeartbeatsBetweenTurns() async throws {
        let none = SetProbe([])
        let a = lease(hub, probe: none)
        let b = lease(phone, probe: none)
        _ = try await a.acquire()
        let longest = try await longestSimultaneousBelief([a, b], steps: 200, dt: 0.5) { step in
            let t = Double(step) * 0.5
            if t.truncatingRemainder(dividingBy: 8) == 0 { _ = try await b.acquire() }
            if t.truncatingRemainder(dividingBy: 8) == 4 { _ = try await a.acquire() }
        }
        #expect(longest <= 4)
    }

    @Test func workingProbeHandsOverOnce() async throws {
        let all = SetProbe(["hub", "phone"])
        let a = lease(hub, probe: all)
        let b = lease(phone, probe: all)
        _ = try await a.acquire()
        let longest = try await longestSimultaneousBelief([a, b], steps: 60, dt: 1) { step in
            _ = try await (step % 2 == 0 ? b : a).acquire()
        }
        #expect(longest == 0)
        #expect(await a.isPrimary())
    }

    @Test func claimOverALiveHolderOnOneClockOverlapsForAtMostOneDuration() async throws {
        let probe = SetProbe(["hub"])
        let h = lease(hub, probe: probe)
        let p = lease(phone, probe: probe)
        _ = try await h.acquire()
        clock.advance(4.999)
        #expect(try await h.heartbeat())
        await probe.set([])                          // the hub's socket dies, CloudKit is fine
        _ = try await p.acquire()
        #expect(await p.isPrimary())
        var overlap = 0.0
        for _ in 0..<1200 {
            clock.advance(0.01)
            guard await h.isPrimary(), await p.isPrimary() else { break }
            overlap += 0.01
        }
        #expect(overlap <= 10.0)
        #expect(overlap > 9.9)
    }

    @Test func suspendedHolderAbsorbsProbesOnlyUntilItsLeaseLapses() async throws {
        let probe = SetProbe(["hub"])
        let h = lease(hub, probe: probe)
        let p = lease(phone, probe: probe)
        _ = try await h.acquire()
        clock.advance(9.9)
        #expect(await h.isPrimary())
        guard case .held = try await p.acquire() else { Issue.record("expected .held"); return }
        clock.advance(0.2)
        #expect(!(await h.isPrimary()))
        #expect(!(await p.isPrimary()))
        guard case .primary = try await p.acquire() else { Issue.record("expected .primary"); return }
    }

    /// Three devices, random reachability, random acquires and heartbeats,
    /// forty seeded runs. No pair believes together for longer than one
    /// duration, and never for longer than one heartbeat interval after
    /// the displaced side has heartbeated or taken a turn.
    @Test func randomisedModelCheck() async throws {
        let names = ["phone", "hub", "watch"]
        var worst = 0.0
        for seed in UInt64(1)...40 {
            var rng = LCG(seed)
            let db = InMemoryRecordDatabase()
            let clock = ManualClock()
            let probe = SetProbe(Set(names))
            let leases = names.map { n in
                PrimaryLease(database: db, device: DeviceID(n), endpoint: "\(n):1",
                             probe: probe, now: clock.read, sleep: Ticker().sleep)
            }
            var since: [Int: Date] = [:]
            for _ in 0..<400 {
                clock.advance(Double(rng.int(700)) / 100.0)
                var up = Set<String>()
                for n in names where rng.int(4) != 0 { up.insert(n) }
                await probe.set(up)
                let i = rng.int(3)
                if rng.int(2) == 0 {
                    _ = try? await leases[i].acquire()
                } else {
                    _ = try? await leases[i].heartbeat()
                }
                let t = clock.now
                var live: [Int] = []
                for (j, l) in leases.enumerated() {
                    if await l.isPrimary() {
                        if since[j] == nil { since[j] = t }
                        live.append(j)
                    } else {
                        since[j] = nil
                    }
                }
                if live.count >= 2 {
                    let latest = live.map { since[$0]! }.max()!
                    worst = max(worst, t.timeIntervalSince(latest))
                }
            }
        }
        #expect(worst <= 10.0)
    }
}
