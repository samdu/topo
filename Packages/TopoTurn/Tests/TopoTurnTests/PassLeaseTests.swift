import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// What a pass asks of the lease before the brain is asked, and what it reads beside it.
@Suite struct PassLeaseTests {
    /// A limb's turn in the log for the primary to answer.
    private func limbSays(_ words: String, in store: InMemoryRecordDatabase, nonce: String) async throws {
        let log = TurnLog(database: store)
        _ = try await log.writer(for: DeviceID("watch")).append(.person, words, continuing: try await log.read(), nonce: nonce)
    }

    @Test func aPassOnALeaseHeldFreshRenewsItWithoutReadingItFirst() async throws {
        let store = InMemoryRecordDatabase()
        let db = RecordingDatabase(inner: store)
        let brain = ScriptedBrain(.success("hello"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        try await limbSays("hi", in: store, nonce: "w1")
        db.reset()
        let reply = try await runner.answerPending(model: .sonnet)
        #expect(reply?.text == "hello")
        // Mutant: `acquire()` before every ask, held fresh or not, fetches the lease first.
        #expect(db.leaseFetches == 0)
        // The renewal on its own, then the reply in one batch with a heartbeat.
        #expect(db.saved.filter { $0 == [Lease.recordType] }.count == 1)
        #expect(brain.requests.count == 1)
    }

    @Test func aLeaseTakenSinceThisDeviceLastWroteItAsksTheBrainNothing() async throws {
        let store = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("never"))
        let (runner, lease) = try await makeRunner(database: store, brain: brain, probe: AlwaysConfirms())
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        try await limbSays("hi", in: store, nonce: "w1")
        // Another device claims over the lease this one still holds fresh by its own clocks.
        let other = PrimaryLease(database: store, device: DeviceID("pad"), endpoint: nil, probe: NoSocketProbe(),
                                 sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        _ = try await other.takeOver()
        #expect(await lease.isPrimary())
        do {
            _ = try await runner.answerPending(model: .sonnet)
            Issue.record("the pass answered")
        } catch TurnRunnerError.notPrimary {
        }
        // Mutant: the brain asked on `isPrimary()` alone, before the renewal answered.
        #expect(brain.requests.isEmpty)
    }

    @Test func aPassWithNothingWaitingTouchesNeitherTheLeaseNorTheChoice() async throws {
        let store = InMemoryRecordDatabase()
        let db = RecordingDatabase(inner: store)
        let brain = ScriptedBrain()
        let (runner, lease) = try await makeRunner(database: db, brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        db.reset()
        let chose = ChoiceCount()
        _ = try await runner.answerPending(choosing: { chose.add(); return .sonnet })
        #expect(db.leaseFetches == 0)
        #expect(db.saved.isEmpty)
        #expect(chose.count == 0)
    }

    @Test func aLimbsTurnContinuesTheReadTheRunnerMadeBesideTheLease() async throws {
        let store = InMemoryRecordDatabase()
        let brain = ScriptedBrain()
        // A hub holds the lease fresh: the phone's turn is a limb's.
        let hub = PrimaryLease(database: store, device: DeviceID("mac-\(UUID().uuidString)"), endpoint: "10.0.0.2:1",
                               probe: NoSocketProbe(), sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        _ = try await hub.takeOver()
        try await limbSays("earlier", in: store, nonce: "w1")
        let (runner, _) = try await makeRunner(database: store, brain: brain, probe: HubLeaseProbe(), standing: .elsewhere)
        do {
            _ = try await runner.run("hi", model: .sonnet, nonce: "n1", known: [])
            Issue.record("the phone answered")
        } catch TurnRunnerError.notPrimary {
        }
        let read = await runner.takeRead()
        // Mutant: the read dropped as the lease answers, so the caller reads the log again.
        #expect(read?.ordered.map(\.text) == ["earlier"])
        #expect(await runner.takeRead() == nil)
    }
}

final class ChoiceCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
