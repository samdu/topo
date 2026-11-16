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
}
