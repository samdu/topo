import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// The phone beside a hub: a hub's fresh lease is deferred to without a socket (`HubLeaseProbe`),
/// an expired one is claimed, every other holder is what it was to `NoSocketProbe`, and a phone
/// that knows a hub answers gives its brain nothing ahead of the lease unless iCloud is away.
@Suite struct HubLeaseTests {
    static let hub = DeviceID("mac-" + UUID().uuidString.lowercased())
    static let parked: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

    /// How many times a lease asked its probe, and what the hub probe answered.
    final class Counting: LeaseProbe, @unchecked Sendable {
        private let lock = NSLock()
        private var asked = 0
        var count: Int { lock.withLock { asked } }
        func confirms(_ lease: Lease) async -> Bool {
            lock.withLock { asked += 1 }
            return await HubLeaseProbe().confirms(lease)
        }
    }

    @Test func aHubIsMacAndAWholeUUIDAndNothingElseIs() {
        #expect(HubLeaseProbe.isHub(Self.hub))
        #expect(HubLeaseProbe.isHub(DeviceID("mac-" + UUID().uuidString)))
        // What `DeviceIdentity` mints on every platform, a macOS build of the client's included.
        for name in ["mac-1a2b3c4d", "ios-1A2B3C4D", "watch-1A2B3C4D", "tv-1A2B3C4D", "hub", "phone", "mac-",
                     "mac-" + UUID().uuidString + "x", "MAC-" + UUID().uuidString, "ios-" + UUID().uuidString] {
            #expect(!HubLeaseProbe.isHub(DeviceID(name)), "\(name)")
        }
    }

    /// A phone launched while the hub holds a fresh lease has yielded to nothing, and with no
    /// socket it once claimed over the hub on its first turn. It defers: the lease is the hub's
    /// still, the turn is not primary, and the brain is neither asked nor told the words.
    @Test func aFreshPhoneDoesNotClaimOverAHubsLiveLease() async throws {
        let db = InMemoryRecordDatabase()
        let clock = Elapsed()
        let hub = PrimaryLease(database: db, device: Self.hub, endpoint: "10.0.0.2:1234", probe: NoSocketProbe(),
                               now: clock.now, monotonic: clock.uptime, sleep: Self.parked)
        guard case .primary = try await hub.takeOver() else { Issue.record("the hub should take the lease"); return }
        let brain = ScriptedBrain(.success("from the phone"))
        brain.hears = true
        let probe = Counting()
        let (runner, lease) = try await makeRunner(database: db, brain: brain, probe: probe, clock: clock)
        clock.advance(9)
        do {
            _ = try await runner.run("bins?", model: .sonnet, nonce: "n1", known: [])
            Issue.record("expected not primary")
        } catch TurnRunnerError.notPrimary(let outcome) {
            guard case .held(let by) = outcome else { Issue.record("expected held, got \(outcome)"); return }
            #expect(by.holder == Self.hub)
        }
        #expect(probe.count == 1)
        #expect(!(await lease.isPrimary()))
        #expect(await hub.isPrimary())
        #expect(Lease(record: try #require(try await db.fetch(Lease.recordID)))?.holder == Self.hub)
        #expect(brain.heard.isEmpty)
        #expect(brain.requests.isEmpty)
        #expect(await runner.standing == .elsewhere)
        #expect(try await TurnLog(database: db).read().isEmpty)
    }

    /// The hub went quiet: one duration after its last renewal its lease has expired, and the
    /// phone claims it without asking the probe and answers.
    @Test func aPhoneClaimsAHubsLeaseOnceItHasExpired() async throws {
        let db = InMemoryRecordDatabase()
        let clock = Elapsed()
        let hub = PrimaryLease(database: db, device: Self.hub, endpoint: nil, probe: NoSocketProbe(),
                               now: clock.now, monotonic: clock.uptime, sleep: Self.parked)
        guard case .primary = try await hub.takeOver() else { Issue.record("the hub should take the lease"); return }
        let brain = ScriptedBrain(.success("from the phone"))
        let probe = Counting()
        let (runner, lease) = try await makeRunner(database: db, brain: brain, probe: probe, clock: clock,
                                                   standing: .elsewhere)
        clock.advance(10)
        let result = try await runner.run("bins?", model: .sonnet)
        #expect(result.assistant.text == "from the phone")
        #expect(probe.count == 0, "an expired lease is claimed without a probe")
        #expect(await lease.isPrimary())
        #expect(await lease.held?.epoch == 2)
        #expect(await runner.standing == .mine)
    }

    /// Any holder but a hub is what it was to `NoSocketProbe`: a fresh lease of another phone's,
    /// or of a device named as a client on a Mac names itself, is claimed over on the first turn.
    @Test(arguments: ["ios-1A2B3C4D", "mac-1a2b3c4d"])
    func aFreshLeaseOfAnyOtherDeviceIsClaimedOverAsBefore(_ holder: String) async throws {
        let db = InMemoryRecordDatabase()
        let other = PrimaryLease(database: db, device: DeviceID(holder), endpoint: nil, probe: NoSocketProbe(),
                                 sleep: Self.parked)
        guard case .primary = try await other.acquire() else { Issue.record("\(holder) should claim"); return }
        let brain = ScriptedBrain(.success("from the phone"))
        let probe = Counting()
        let (runner, lease) = try await makeRunner(database: db, brain: brain, probe: probe)
        let result = try await runner.run("bins?", model: .sonnet)
        #expect(result.assistant.text == "from the phone")
        #expect(probe.count == 1)
        #expect(await lease.isPrimary())
        #expect(await runner.standing == .mine)
    }

    /// The phone was the one answering, and the hub woke and took the lease: the phone's next
    /// heartbeat finds the hub's claim and yields, with no turn asking. Its runner stands
    /// elsewhere from then on, so the next words are not heard ahead of the lease and the turn
    /// goes to the hub; and that is what the harness keeps for the next launch.
    @Test func aHeartbeatThatYieldsToAHubStopsTheBrainHearingAhead() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("one"))
        brain.hears = true
        let (runner, lease) = try await makeRunner(database: db, brain: brain, probe: HubLeaseProbe())
        _ = try await runner.run("first", model: .sonnet, nonce: "n0", known: [])
        #expect(await runner.standing == .mine)
        let hub = PrimaryLease(database: db, device: Self.hub, endpoint: nil, probe: NoSocketProbe(), sleep: Self.parked)
        guard case .primary = try await hub.takeOver() else { Issue.record("the hub should take the lease"); return }
        #expect(!(try await lease.heartbeat()))

        #expect(await runner.currentStanding() == .elsewhere)
        #expect(!(await runner.hear("early", model: .sonnet, nonce: "n1", known: [])))
        do {
            _ = try await runner.run("second", model: .sonnet, nonce: "n2", known: [])
            Issue.record("expected not primary")
        } catch TurnRunnerError.notPrimary(let outcome) {
            guard case .held = outcome else { Issue.record("expected held, got \(outcome)"); return }
        }
        #expect(brain.heard.map(\.nonce) == ["n0"], "words the hub answers ran this device's brain")
        #expect(await hub.isPrimary())
    }

    /// A yield to another phone is left as it was: the runner still stands where the last call
    /// to the lease put it.
    @Test func aHeartbeatThatYieldsToAnotherPhoneLeavesTheStandingAlone() async throws {
        let db = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("one"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain, probe: HubLeaseProbe())
        _ = try await runner.run("first", model: .sonnet)
        let other = PrimaryLease(database: db, device: DeviceID("ios-1A2B3C4D"), endpoint: nil, probe: NoSocketProbe(),
                                 sleep: Self.parked)
        guard case .primary = try await other.acquire() else { Issue.record("the other phone should claim"); return }
        #expect(!(try await lease.heartbeat()))
        #expect(await lease.yielded?.holder == DeviceID("ios-1A2B3C4D"))
        #expect(await runner.currentStanding() == .mine)
    }

    /// iCloud away is not a hub answering: a phone that knows a hub holds the lease, and has
    /// yielded to it, still answers by itself when the lease cannot be asked.
    @Test func aPhoneThatKnowsAHubStillAnswersWhenICloudIsAway() async throws {
        let store = InMemoryRecordDatabase()
        let db = Outage(store)
        let brain = ScriptedBrain(.success("from the phone"))
        brain.hears = true
        let (runner, lease) = try await makeRunner(database: db, brain: brain, probe: HubLeaseProbe())
        _ = try await runner.run("first", model: .sonnet, nonce: "n0", known: [])
        let hub = PrimaryLease(database: store, device: Self.hub, endpoint: nil, probe: NoSocketProbe(), sleep: Self.parked)
        guard case .primary = try await hub.takeOver() else { Issue.record("the hub should take the lease"); return }
        #expect(!(try await lease.heartbeat()))
        #expect(await runner.currentStanding() == .elsewhere)

        db.away = true
        do {
            _ = try await runner.run("are you there", model: .sonnet, nonce: "n1", known: [])
            Issue.record("expected the turn to be unsaved")
        } catch TurnRunnerError.unsaved {
        }
        #expect(brain.heard.map(\.nonce) == ["n0", "n1"], "the brain hears when the lease cannot be asked")
        #expect(await runner.hear("still there", model: .sonnet, nonce: "n2", known: []))
        #expect(brain.heard.map(\.nonce) == ["n0", "n1", "n2"])
    }

    // MARK: A standing from before the lease could have moved

    /// A phone that was the one answering is suspended past its lease's duration and the hub
    /// takes the lease meanwhile: nothing yielded, so it still stands `.mine`. Before it gives its
    /// brain anything it looks at the lease, finds the hub answering, and stands elsewhere: the
    /// turn is not this device's to answer and the brain is never told the words.
    @Test func aLapsedPhoneThatTheHubTookOverFromDoesNotTellItsBrainTheWords() async throws {
        let db = InMemoryRecordDatabase()
        let clock = Elapsed()
        let brain = ScriptedBrain(.success("one"))
        brain.hears = true
        let (runner, lease) = try await makeRunner(database: db, brain: brain, probe: HubLeaseProbe(), clock: clock)
        _ = try await runner.run("first", model: .sonnet, nonce: "n0", known: [])
        #expect(await runner.standing == .mine)
        clock.advance(11)
        let hub = PrimaryLease(database: db, device: Self.hub, endpoint: nil, probe: NoSocketProbe(),
                               now: clock.now, monotonic: clock.uptime, sleep: Self.parked)
        guard case .primary = try await hub.takeOver() else { Issue.record("the hub should take the lease"); return }
        #expect(await lease.yielded == nil, "nothing yielded: the phone was not running")

        #expect(!(await runner.hear("early", model: .sonnet, nonce: "n1", known: [])))
        do {
            _ = try await runner.run("second", model: .sonnet, nonce: "n2", known: [])
            Issue.record("expected not primary")
        } catch TurnRunnerError.notPrimary(let outcome) {
            guard case .held(let by) = outcome else { Issue.record("expected held, got \(outcome)"); return }
            #expect(by.holder == Self.hub)
        }
        #expect(brain.heard.map(\.nonce) == ["n0"], "words the hub answers ran this device's brain")
        #expect(await runner.currentStanding() == .elsewhere)
    }

    /// The same phone killed rather than suspended: a launch that kept `.mine` and has held no
    /// lease since finds the hub's and gives its brain nothing.
    @Test func aRelaunchThatKeptMineDoesNotTellItsBrainTheWordsTheHubAnswers() async throws {
        let db = InMemoryRecordDatabase()
        let hub = PrimaryLease(database: db, device: Self.hub, endpoint: nil, probe: NoSocketProbe(), sleep: Self.parked)
        guard case .primary = try await hub.takeOver() else { Issue.record("the hub should take the lease"); return }
        let brain = ScriptedBrain(.success("from the phone"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain, probe: HubLeaseProbe(), standing: .mine)
        #expect(!(await runner.hear("early", model: .sonnet, nonce: "n1", known: [])))
        await #expect(throws: TurnRunnerError.self) {
            _ = try await runner.run("bins?", model: .sonnet, nonce: "n1", known: [])
        }
        #expect(brain.heard.isEmpty)
        #expect(brain.requests.isEmpty)
        #expect(await runner.standing == .elsewhere)
    }

    /// The same lapsed phone with no hub in the record: the brain hears the words ahead of the
    /// lease as before, after one read of the lease record, which the send's several hears share;
    /// and a turn on a lease held fresh reads nothing of the lease before it hears.
    @Test func aLapsedPhoneWithNoHubHearsAheadAfterOneReadOfTheLease() async throws {
        let db = RecordingDatabase(inner: InMemoryRecordDatabase())
        let clock = Elapsed()
        let brain = ScriptedBrain(.success("one"), .success("two"), .success("three"))
        brain.hears = true
        let (runner, lease) = try await makeRunner(database: db, brain: brain, probe: HubLeaseProbe(), clock: clock)
        _ = try await runner.run("first", model: .sonnet, nonce: "n0", known: [])

        db.reset()
        _ = try await runner.run("fresh", model: .sonnet, nonce: "n1", known: [])
        #expect(db.leaseFetches == 0, "a turn on a fresh lease read the lease")

        clock.advance(11)
        #expect(!(await lease.isPrimary()))
        db.reset()
        #expect(await runner.hear("lapsed", model: .sonnet, nonce: "n2", known: []))
        #expect(db.leaseFetches == 1)
        #expect(await runner.hear("lapsed", model: .sonnet, nonce: "n2", known: []))
        let result = try await runner.run("lapsed", model: .sonnet, nonce: "n2", known: [])
        #expect(result.assistant.text == "three")
        #expect(db.leaseFetches == 2, "one look, shared by the send, and the turn's own acquire")
        #expect(brain.heard.map(\.nonce) == ["n0", "n1", "n2"])
        #expect(await runner.standing == .mine)
        #expect(await lease.isPrimary())
    }

    /// iCloud away after the lease lapsed: the look cannot be had, and the phone answers by itself.
    @Test func aLapsedPhoneWithICloudAwayStillHearsAhead() async throws {
        let store = InMemoryRecordDatabase()
        let db = Outage(store)
        let clock = Elapsed()
        let brain = ScriptedBrain(.success("one"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain, probe: HubLeaseProbe(), clock: clock)
        _ = try await runner.run("first", model: .sonnet, nonce: "n0", known: [])
        clock.advance(11)
        db.away = true
        #expect(await runner.hear("are you there", model: .sonnet, nonce: "n1", known: []))
        #expect(brain.heard.map(\.nonce) == ["n0", "n1"])
    }

    /// A look stuck behind an operation that never answers — a save held at the gate with no
    /// bound of the store's own — is given up at the lease's patience, and the phone answers by
    /// itself as for iCloud away, rather than waiting on the gate.
    @Test func aLookStuckAtTheGateIsGivenUpAtTheLeasesPatience() async throws {
        let db = HeldSave(InMemoryRecordDatabase())
        let clock = Elapsed()
        let brain = ScriptedBrain(.success("one"))
        brain.hears = true
        let id = DeviceID("phone")
        let log = TurnLog(database: db)
        let timing = LeaseTiming(duration: 3, heartbeat: 1)
        let lease = PrimaryLease(database: db, device: id, endpoint: nil, probe: HubLeaseProbe(), timing: timing,
                                 now: clock.now, monotonic: clock.uptime, sleep: Self.parked)
        let runner = TurnRunner(log: log, writer: try await log.writer(for: id), lease: lease, brain: brain)
        _ = try await runner.run("first", model: .sonnet, nonce: "n0", known: [])
        clock.advance(4)
        await db.holdNextSave()
        let stuck = Task { try await lease.acquire() }
        while !(await db.holding) { await Task.yield() }

        let began = ContinuousClock.now
        let hearing = Task { await runner.hear("still there", model: .sonnet, nonce: "n1", known: []) }
        // Polled rather than awaited, so a look that waits on the gate fails here and does not hang.
        while brain.heard.count < 2, ContinuousClock.now - began < .seconds(timing.patience) + .seconds(3) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let took = ContinuousClock.now - began
        #expect(brain.heard.map(\.nonce) == ["n0", "n1"], "the look waited on the gate past its bound")
        #expect(took >= .seconds(timing.patience) - .milliseconds(50))
        #expect(took < .seconds(timing.patience) + .seconds(2))
        await db.release()
        _ = await hearing.value
        _ = try? await stuck.value
    }

    /// A look's answer is kept one heartbeat interval and no longer: a "nobody else" from before a
    /// hub's takeover stands for at most the window a held lease's heartbeats leave, and a look
    /// after it finds the hub.
    @Test func aLooksAnswerIsKeptForAHeartbeatIntervalAndNoLonger() async throws {
        let db = InMemoryRecordDatabase()
        let clock = Elapsed()
        let brain = ScriptedBrain(.success("one"))
        brain.hears = true
        let (runner, _) = try await makeRunner(database: db, brain: brain, probe: HubLeaseProbe(), clock: clock)
        _ = try await runner.run("first", model: .sonnet, nonce: "n0", known: [])
        clock.advance(11)
        #expect(await runner.hear("one", model: .sonnet, nonce: "n1", known: []))
        let hub = PrimaryLease(database: db, device: Self.hub, endpoint: nil, probe: NoSocketProbe(),
                               now: clock.now, monotonic: clock.uptime, sleep: Self.parked)
        guard case .primary = try await hub.takeOver() else { Issue.record("the hub should take the lease"); return }
        clock.advance(4.9)
        #expect(await runner.hear("two", model: .sonnet, nonce: "n2", known: []), "inside the window the answer kept stands")
        clock.advance(0.2)
        #expect(!(await runner.hear("three", model: .sonnet, nonce: "n3", known: [])))
        #expect(await runner.standing == .elsewhere)
        #expect(brain.heard.map(\.nonce) == ["n0", "n1", "n2"])
    }

    /// A lease held fresh is trusted without a look, so a heartbeat out at the gate holds up no
    /// hearing: the brain hears at once.
    @Test func aFreshLeaseHearsWithoutWaitingOnTheGate() async throws {
        let db = HeldSave(InMemoryRecordDatabase())
        let brain = ScriptedBrain(.success("one"))
        brain.hears = true
        let id = DeviceID("phone")
        let log = TurnLog(database: db)
        let timing = LeaseTiming(duration: 3, heartbeat: 1)
        let lease = PrimaryLease(database: db, device: id, endpoint: nil, probe: HubLeaseProbe(), timing: timing,
                                 sleep: Self.parked)
        let runner = TurnRunner(log: log, writer: try await log.writer(for: id), lease: lease, brain: brain)
        _ = try await runner.run("first", model: .sonnet, nonce: "n0", known: [])
        await db.holdNextSave()
        let beating = Task { try await lease.heartbeat() }
        while !(await db.holding) { await Task.yield() }

        let began = ContinuousClock.now
        #expect(await runner.hear("now", model: .sonnet, nonce: "n1", known: []))
        #expect(ContinuousClock.now - began < .milliseconds(500), "a fresh lease's hearing waited on the gate")
        await db.release()
        _ = try? await beating.value
    }
}
