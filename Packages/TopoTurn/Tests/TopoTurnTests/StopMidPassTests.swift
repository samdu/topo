import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// Holds the next lease-only save, or the next read of the log, until released: the save is sent
/// and lands after the release, as a CloudKit request in flight would.
final class StopGate: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    private let lock = NSLock()
    private var holdLeaseSave = false, holdRead = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var holdingNow = false
    init(_ base: any RecordDatabase) { self.base = base }
    func armLeaseSave() { lock.withLock { holdLeaseSave = true } }
    func armRead() { lock.withLock { holdRead = true } }
    var holding: Bool { lock.withLock { holdingNow } }
    func release() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { waiter = nil; holdingNow = false }; return waiter }
        w?.resume()
    }
    private func hold() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.withLock { waiter = c; holdingNow = true }
        }
    }
    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        let gate = lock.withLock { () -> Bool in
            guard holdLeaseSave, records.count == 1, records[0].id == Lease.recordID else { return false }
            holdLeaseSave = false
            return true
        }
        if gate { await hold() }
        return try await base.save(records)
    }
    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        let gate = lock.withLock { () -> Bool in
            guard holdRead, type == Turn.recordType else { return false }
            holdRead = false
            return true
        }
        if gate { await hold() }
        return try await base.records(ofType: type)
    }
}

private func waitFor(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

/// A stop (the hub's `HubMind.stop`: the pass cancelled, then `lease.abandon()`) that lands while
/// a pass with a turn to answer is in flight claims nothing after it and asks the brain nothing:
/// the pass's claims are made since its mark of the lease's abandons, and the lease refuses them.
@Suite(.serialized) struct StopMidPassTests {
    private func setUp(_ arm: (StopGate) -> Void) async throws
        -> (gate: StopGate, store: InMemoryRecordDatabase, runner: TurnRunner, lease: PrimaryLease, brain: ScriptedBrain) {
        let store = InMemoryRecordDatabase()
        let gate = StopGate(store)
        let brain = ScriptedBrain(.success("hello"))
        let (runner, lease) = try await makeRunner(database: gate, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { throw CancellationError() }
        let log = TurnLog(database: store)
        _ = try await log.writer(for: DeviceID("phone")).append(.person, "hi", continuing: try await log.read(), nonce: "p1")
        arm(gate)
        return (gate, store, runner, lease, brain)
    }

    /// `cancelling` false is an abandon alone: the lease's refusal is the guard, and nothing leans
    /// on a database that throws for a cancelled task (CloudKit's need not).
    private func stopMidPass(cancelling: Bool, _ arm: (StopGate) -> Void) async throws
        -> (epochBefore: Int64, epochAfter: Int64, primaryAfter: Bool, asked: Int) {
        let (gate, store, runner, lease, brain) = try await setUp(arm)
        let before = try #require(await store.current(Lease.recordID).flatMap(Lease.init(record:)))
        let pass = Task { try await runner.answerPending(model: .sonnet) }
        #expect(await waitFor { gate.holding })
        if cancelling { pass.cancel() }
        await lease.abandon()
        gate.release()
        _ = await pass.result
        let after = try #require(await store.current(Lease.recordID).flatMap(Lease.init(record:)))
        let primary = await lease.isPrimary()
        let asked = brain.requests.count
        await lease.abandon()
        return (before.epoch, after.epoch, primary, asked)
    }

    @Test(arguments: [true, false])
    func aStopWhileTheRenewalIsOutClaimsNothingAndAsksNothing(cancelling: Bool) async throws {
        // Mutant: the refused renewal's `acquire()` made without the pass's mark.
        let r = try await stopMidPass(cancelling: cancelling) { $0.armLeaseSave() }
        #expect(r.epochAfter == r.epochBefore, "claimed after the abandon: epoch \(r.epochBefore) -> \(r.epochAfter)")
        #expect(!r.primaryAfter, "the lease is held after the abandon")
        #expect(r.asked == 0, "the brain was asked after the abandon")
    }

    @Test(arguments: [true, false])
    func aStopWhileThePassReadsTheLogClaimsNothingAndAsksNothing(cancelling: Bool) async throws {
        // Mutant: the first `acquire()` of the pass made without its mark.
        let r = try await stopMidPass(cancelling: cancelling) { $0.armRead() }
        #expect(r.epochAfter == r.epochBefore, "claimed after the abandon: epoch \(r.epochBefore) -> \(r.epochAfter)")
        #expect(!r.primaryAfter, "the lease is held after the abandon")
        #expect(r.asked == 0, "the brain was asked after the abandon")
    }

    /// A mark handed in is the one the claims are judged by: a pass begun after an abandon, under
    /// a mark taken before it, claims nothing.
    @Test func aPassUnderAMarkFromBeforeAnAbandonClaimsNothing() async throws {
        let (_, store, runner, lease, brain) = try await setUp { _ in }
        let mark = await lease.abandons
        await lease.abandon()
        let before = try #require(await store.current(Lease.recordID).flatMap(Lease.init(record:)))
        await #expect(throws: TurnRunnerError.self) { try await runner.answerPending(since: mark, choosing: { .sonnet }) }
        let after = try #require(await store.current(Lease.recordID).flatMap(Lease.init(record:)))
        #expect(after.epoch == before.epoch)
        #expect(!(await lease.isPrimary()))
        #expect(brain.requests.isEmpty)
    }
}
