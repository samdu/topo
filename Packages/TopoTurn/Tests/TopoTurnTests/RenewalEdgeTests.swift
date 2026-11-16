import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// The next lease-only save lands in the store and its answer is lost.
final class LandsUnanswered: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    private let lock = NSLock()
    private var armed = false
    private(set) var leaseOnlySaves = 0
    init(_ base: any RecordDatabase) { self.base = base }
    func arm() { lock.withLock { armed = true } }
    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        let leaseOnly = records.count == 1 && records[0].id == Lease.recordID
        let lose = lock.withLock { () -> Bool in
            if leaseOnly { leaseOnlySaves += 1 }
            guard armed, leaseOnly else { return false }
            armed = false
            return true
        }
        let saved = try await base.save(records)
        if lose { throw RecordDatabaseError.unavailable(underlying: URLError(.timedOut)) }
        return saved
    }
}

/// The renewal a pass sends beside the reply's marker, at its edges.
@Suite(.serialized) struct RenewalEdgeTests {
    /// A renewal that lands with its answer lost is asked the long way, finds the lease still this
    /// device's, and the turn is answered once at the same epoch.
    @Test func aRenewalThatLandedUnansweredIsTakenTheLongWayAndAnsweredOnce() async throws {
        let store = InMemoryRecordDatabase()
        let db = LandsUnanswered(store)
        let brain = ScriptedBrain(.success("hello"))
        let (runner, lease) = try await makeRunner(database: db, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("claim"); return }
        let before = try #require(await store.current(Lease.recordID).flatMap(Lease.init(record:)))
        let log = TurnLog(database: store)
        _ = try await log.writer(for: DeviceID("phone")).append(.person, "hi", continuing: try await log.read(), nonce: "p1")
        db.arm()
        let reply = try await runner.answerPending(model: .sonnet)
        let after = try #require(await store.current(Lease.recordID).flatMap(Lease.init(record:)))
        #expect(reply?.text == "hello")
        #expect(brain.requests.count == 1)
        #expect(after.epoch == before.epoch)
        #expect(after.holder == DeviceID("mac-hub"))
        #expect(try await log.read().ordered.filter { $0.role == .assistant }.count == 1)
        await lease.abandon()
    }

    /// A phone's claim between two passes, which no probe confirms: the pass's renewal is refused,
    /// the lease is yielded to the phone, and the brain is asked nothing.
    @Test func aPhonesClaimBetweenPassesThatNoProbeConfirmsAsksTheBrainNothing() async throws {
        let store = InMemoryRecordDatabase()
        let brain = ScriptedBrain(.success("never"))
        let (runner, lease) = try await makeRunner(database: store, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("claim"); return }
        let log = TurnLog(database: store)
        _ = try await log.writer(for: DeviceID("phone")).append(.person, "hi", continuing: try await log.read(), nonce: "p1")
        let phone = PrimaryLease(database: store, device: DeviceID("phone"), endpoint: nil, probe: NoSocketProbe(),
                                 sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        _ = try await phone.takeOver()
        #expect(await lease.isPrimary())
        do {
            _ = try await runner.answerPending(model: .sonnet)
            Issue.record("the pass answered")
        } catch TurnRunnerError.notPrimary {
        }
        #expect(brain.requests.isEmpty)
        #expect(await store.current(Lease.recordID).flatMap(Lease.init(record:))?.holder == DeviceID("phone"))
        await lease.abandon(); await phone.abandon()
    }

    /// A limb turn over the runner's kept read when this device wrote since that read: nothing on a
    /// stale head, and no second copy.
    @Test func aKeptReadThatMissesThisDevicesOwnWriteWritesNothing() async throws {
        let store = InMemoryRecordDatabase()
        let log = TurnLog(database: store)
        let writer = try await log.writer(for: DeviceID("phone"))
        _ = try await writer.append(.person, "first", continuing: try await log.read(), nonce: "a")
        let stale = try await log.read()
        _ = try await writer.append(.person, "second", continuing: try await log.read(), nonce: "b")
        do {
            _ = try await writer.append(.person, "third", continuing: stale, nonce: "c", justRead: true)
            Issue.record("wrote over a stale read")
        } catch TurnLogError.incompleteTranscript {
        }
        #expect(try await log.read().ordered.map(\.text) == ["first", "second"])
    }
}
