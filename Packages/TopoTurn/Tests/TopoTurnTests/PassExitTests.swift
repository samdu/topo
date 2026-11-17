import Foundation
import Testing
import TopoCore
import TopoCoreTesting
@testable import TopoTurn

/// Holds the next save of the lease alone until released, and then lets it reach the store, as a
/// CloudKit request in flight does; once armed, fails the next fetch by ID that names a turn, or
/// leaves records out of the change feed (a feed behind the log).
final class RenewalGate: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    private let lock = NSLock()
    private var holdLeaseSave = false, failTurnFetch = false
    private var hidden: Set<RecordID> = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var held = false
    private var landed = 0
    init(_ base: any RecordDatabase) { self.base = base }
    func arm(holdLeaseSave: Bool = true, failTurnFetch: Bool = false, hide: Set<RecordID> = []) {
        lock.withLock { self.holdLeaseSave = holdLeaseSave; self.failTurnFetch = failTurnFetch; hidden = hide }
    }
    var holding: Bool { lock.withLock { held } }
    /// Saves of the lease alone that have reached the store.
    var leaseSavesLanded: Int { lock.withLock { landed } }
    func release() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { waiter = nil; held = false }; return waiter }
        w?.resume()
    }
    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        let leaseOnly = records.count == 1 && records[0].id == Lease.recordID
        let hold = lock.withLock { () -> Bool in
            guard leaseOnly, holdLeaseSave else { return false }
            holdLeaseSave = false
            return true
        }
        if hold { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { waiter = c; held = true } } }
        let saved = try await base.save(records)
        if leaseOnly { lock.withLock { landed += 1 } }
        return saved
    }
    func fetch(_ ids: [RecordID], through base: any RecordDatabase) async throws -> [RecordID: Record] {
        let fail = lock.withLock { () -> Bool in
            guard failTurnFetch, ids.contains(where: { Turn.ref(ofRecordNamed: $0.name) != nil }) else { return false }
            failTurnFetch = false
            return true
        }
        if fail { throw RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet)) }
        return try await base.fetch(ids)
    }
    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        let hide = lock.withLock { hidden }
        return try await base.records(ofType: type).filter { !hide.contains($0.id) }
    }
}

/// Set once, from any task.
final class Ended: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() { lock.withLock { done = true } }
    var isSet: Bool { lock.withLock { done } }
}

private func waitFor(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

/// Every way out of a pass waits for the renewal it sent beside the log's fetch by ID, so a stop
/// that waits for the pass (the hub's `HubMind.stop`) returns with no write of the lease to land.
@Suite(.serialized) struct PassExitTests {
    private func limbSays(_ words: String, in store: InMemoryRecordDatabase, nonce: String) async throws -> Turn {
        let log = TurnLog(database: store)
        return try await log.writer(for: DeviceID("watch")).append(.person, words, continuing: try await log.read(), nonce: nonce)
    }

    /// Runs a pass with the renewal held, and says whether it ended before the renewal was let go.
    private func passEndsBeforeItsRenewal(_ arm: (RenewalGate, InMemoryRecordDatabase) async throws -> Void) async throws
        -> (endedEarly: Bool, landedBeforeEnd: Bool, asked: Int) {
        let store = InMemoryRecordDatabase()
        let gate = RenewalGate(store)
        let brain = ScriptedBrain(.success("never"))
        let (runner, lease) = try await makeRunner(database: gate, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { throw CancellationError() }
        try await arm(gate, store)
        let ended = Ended()
        let landedAtEnd = Ended()
        let pass = Task {
            _ = try? await runner.answerPending(model: .sonnet)
            if gate.leaseSavesLanded > 1 { landedAtEnd.set() }
            ended.set()
        }
        #expect(await waitFor { gate.holding })
        try await Task.sleep(for: .milliseconds(200))
        let early = ended.isSet
        gate.release()
        await pass.value
        await lease.abandon()
        return (early, landedAtEnd.isSet, brain.requests.count)
    }

    @Test func aPassWhoseFeedIsBehindWaitsForItsRenewal() async throws {
        let r = try await passEndsBeforeItsRenewal { gate, store in
            _ = try await limbSays("hi", in: store, nonce: "w1")
            let second = try await limbSays("and another", in: store, nonce: "w2")
            gate.arm(hide: [Turn.recordID(for: second.ref)])
        }
        // Mutant: the pass returns nil for a read still incomplete without waiting for the renewal.
        #expect(!r.endedEarly, "the pass returned with its renewal still out")
        #expect(r.landedBeforeEnd)
        #expect(r.asked == 0)
    }

    @Test func aPassWhoseProbeThrowsWaitsForItsRenewal() async throws {
        let r = try await passEndsBeforeItsRenewal { gate, store in
            _ = try await limbSays("hi", in: store, nonce: "w1")
            gate.arm(failTurnFetch: true)
        }
        // Mutant: a throw out of the pass leaves the renewal out.
        #expect(!r.endedEarly, "the pass threw with its renewal still out")
        #expect(r.landedBeforeEnd)
        #expect(r.asked == 0)
    }

    /// The renewal answered while the log's fetch by ID was out, and then the pass was stopped (the
    /// hub's order: cancelled, then the lease abandoned): the brain is asked nothing.
    @Test func aPassStoppedAfterItsRenewalAnsweredAsksNothing() async throws {
        let store = InMemoryRecordDatabase()
        let gate = MarkerGate(store)
        let brain = ScriptedBrain(.success("after the stop"))
        let (runner, lease) = try await makeRunner(database: gate, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        _ = try await limbSays("hi", in: store, nonce: "w1")
        gate.arm()
        let pass = Task { try await runner.answerPending(model: .sonnet) }
        #expect(await waitFor { gate.holding && gate.leaseSavesLanded > 0 })
        pass.cancel()
        await lease.abandon()
        gate.release()
        _ = await pass.result
        // Mutant: no check for cancellation before the brain is asked.
        #expect(brain.requests.isEmpty, "a stopped pass asked the brain")
        #expect(gate.turnSaves == 0)
    }

    /// The feed shows the watch's turn waiting, and only the fetch by ID sees the phone's newer
    /// turn continuing it: the pass answers from the read the probe made, which waits on that.
    @Test func aFeedBehindOnTheNewestTurnIsNotAnswered() async throws {
        let store = InMemoryRecordDatabase()
        let log = TurnLog(database: store)
        let phone = try await log.writer(for: DeviceID("phone"))
        let zero = try await phone.append(.person, "zero", parents: [])
        let a0 = try await log.writer(for: DeviceID("pad")).append(.assistant, "a0", parents: [zero.ref])
        let first = try await log.writer(for: DeviceID("watch")).append(.person, "first", parents: [a0.ref])
        _ = try await phone.append(.person, "second", parents: [first.ref])
        let db = FeedHidesNewest(base: store, device: "phone")
        #expect(TurnRunner.awaitsReply(try await TurnLog(database: db).feed()))
        let brain = ScriptedBrain(.success("answers only the first"))
        let (runner, lease) = try await makeRunner(database: db, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        // Mutant: the pass goes on with the feed's transcript rather than the probe's.
        #expect(try await runner.answerPending(model: .sonnet) == nil)
        #expect(brain.requests.isEmpty)
        await lease.abandon()
    }

    /// An owed reply settled beside a waiting person's turn forks the log: the answer continues
    /// both heads, the owed reply and the person's turn, as read after the settle.
    @Test func anOwedReplyIsSettledAndTheTurnAnsweredOverTheLogAsReadAfter() async throws {
        let store = InMemoryRecordDatabase()
        let log = TurnLog(database: store)
        let watch = try await log.writer(for: DeviceID("watch"))
        let p1 = try await watch.append(.person, "q1", parents: [])
        let a1 = try await log.writer(for: DeviceID("pad")).append(.assistant, "a1", parents: [p1.ref])
        let p2 = try await watch.append(.person, "q2", parents: [a1.ref])
        let brain = ScriptedBrain(.success("r"))
        brain.owes = OwedReply(parents: [a1.ref], nonce: "owed-nonce", text: "owed")
        let (runner, lease) = try await makeRunner(database: store, device: "mac-hub", brain: brain)
        let reply = try #require(try await runner.answerPending(model: .sonnet))
        let owed = try #require(try await log.read().ordered.first { $0.text == "owed" })
        // Mutant: no read of the log after the owed reply moved it.
        #expect(Set(reply.parents) == [owed.ref, p2.ref])
        #expect(reply.nonce == TurnRunner.replyNonce(for: [owed.ref, p2.ref]))
        await lease.abandon()
    }

    /// The log's fetch by ID fails once the renewal has landed: the pass throws, the brain unasked.
    @Test func aProbeThatFailsAfterTheRenewalAsksTheBrainNothing() async throws {
        let store = InMemoryRecordDatabase()
        let gate = RenewalGate(store)
        let brain = ScriptedBrain(.success("never"))
        let (runner, lease) = try await makeRunner(database: gate, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        _ = try await limbSays("hi", in: store, nonce: "w1")
        let before = gate.leaseSavesLanded
        gate.arm(holdLeaseSave: false, failTurnFetch: true)
        await #expect(throws: RecordDatabaseError.self) { try await runner.answerPending(model: .sonnet) }
        #expect(brain.requests.isEmpty)
        #expect(gate.leaseSavesLanded == before + 1, "the renewal was sent beside the fetch")
        await lease.abandon()
    }
}

/// More of a pass's ways through the log, beside a renewal that has landed.
@Suite(.serialized) struct PassReadTests {
    private func limbSays(_ words: String, in store: InMemoryRecordDatabase, nonce: String) async throws {
        let log = TurnLog(database: store)
        _ = try await log.writer(for: DeviceID("watch")).append(.person, words, continuing: try await log.read(), nonce: nonce)
    }

    /// A reply comes to be owed while the log is fetched by ID, under a lease held fresh that a
    /// pad claimed since: the owed write is refused, and the brain is asked nothing.
    @Test func aReplyOwedMidPassUnderALeaseTakenAsksTheBrainNothing() async throws {
        let store = InMemoryRecordDatabase()
        let db = AfterRenewal(store)
        let brain = ScriptedBrain(.success("never"))
        let (runner, lease) = try await makeRunner(database: db, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        try await limbSays("hi", in: store, nonce: "w1")
        let first = try #require(try await TurnLog(database: store).read().heads.first)
        let pad = PrimaryLease(database: store, device: DeviceID("pad"), endpoint: nil, probe: NoSocketProbe(),
                               sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
        _ = try await pad.takeOver()
        db.then = { brain.owes = OwedReply(parents: [first], nonce: "owed-nonce", text: "owed") }
        db.arm()
        do {
            _ = try await runner.answerPending(model: .sonnet)
            Issue.record("the pass answered")
        } catch TurnRunnerError.notPrimary {
        } catch TurnRunnerError.displaced {
        }
        #expect(brain.requests.isEmpty)
        #expect(try await TurnLog(database: store).read().ordered.map(\.text) == ["hi"])
        await lease.abandon(); await pad.abandon()
    }

    /// The same on a lease nobody took: the owed reply is written, then the turn answered once,
    /// over the log as read after it.
    @Test func aReplyOwedMidPassIsWrittenThenTheTurnAnswered() async throws {
        let store = InMemoryRecordDatabase()
        let db = AfterRenewal(store)
        let brain = ScriptedBrain(.success("answer"))
        let (runner, lease) = try await makeRunner(database: db, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        let log = TurnLog(database: store)
        let p0 = try await log.writer(for: DeviceID("watch")).append(.person, "zero", parents: [])
        let a0 = try await log.writer(for: DeviceID("pad")).append(.assistant, "a0", parents: [p0.ref])
        _ = try await log.writer(for: DeviceID("watch")).append(.person, "hi", parents: [a0.ref])
        db.then = { brain.owes = OwedReply(parents: [a0.ref], nonce: "owed-nonce", text: "owed") }
        db.arm()
        _ = try await runner.answerPending(model: .sonnet)
        #expect(brain.requests.count == 1)
        let texts = try await log.read().ordered.map(\.text)
        #expect(texts.contains("owed") && texts.contains("answer"))
        #expect(try await log.read().heads.count == 1)
        await lease.abandon()
    }

    /// The feed is behind on this device's own newest turn, which continues the waiting turn's
    /// parent beside it: nothing is answered this pass.
    @Test func aFeedBehindOnThisDevicesOwnNewestTurnIsNotAnswered() async throws {
        let store = InMemoryRecordDatabase()
        let log = TurnLog(database: store)
        let watch = try await log.writer(for: DeviceID("watch"))
        let hub = try await log.writer(for: DeviceID("mac-hub"))
        let p1 = try await watch.append(.person, "q1", parents: [])
        let a1 = try await hub.append(.assistant, "a1", parents: [p1.ref], nonce: TurnRunner.replyNonce(for: [p1.ref]))
        _ = try await watch.append(.person, "q2", parents: [a1.ref])
        _ = try await hub.append(.assistant, "x", parents: [a1.ref], nonce: "x")
        let db = FeedHidesNewest(base: store, device: "mac-hub")
        let brain = ScriptedBrain(.success("r"))
        let (runner, lease) = try await makeRunner(database: db, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        #expect(try await runner.answerPending(model: .sonnet) == nil)
        #expect(brain.requests.isEmpty)
        #expect(try await log.read().ordered.map(\.text) == ["q1", "a1", "q2", "x"])
        await lease.abandon()
    }
}

/// Once armed: the next fetch by ID naming a turn waits (2 s at most) for a save of the lease
/// alone to land, then runs `then` (which may throw) before answering.
final class AfterRenewal: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    private let lock = NSLock()
    private var armed = false, renewed = false
    private var _then: (@Sendable () async throws -> Void)?
    var then: (@Sendable () async throws -> Void)? {
        get { lock.withLock { _then } }
        set { lock.withLock { _then = newValue } }
    }
    init(_ base: any RecordDatabase) { self.base = base }
    func arm() { lock.withLock { armed = true; renewed = false } }
    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        let saved = try await base.save(records)
        if records.count == 1, records[0].id == Lease.recordID { lock.withLock { renewed = true } }
        return saved
    }
    func fetch(_ ids: [RecordID], through base: any RecordDatabase) async throws -> [RecordID: Record] {
        let hit = lock.withLock { () -> Bool in
            guard armed, ids.contains(where: { Turn.ref(ofRecordNamed: $0.name) != nil }) else { return false }
            armed = false
            return true
        }
        if hit {
            for _ in 0..<200 where !lock.withLock({ renewed }) { try await Task.sleep(for: .milliseconds(10)) }
            try await then?()
        }
        return try await base.fetch(ids)
    }
}

/// The feed has not caught up with `device`'s newest turn alone.
struct FeedHidesNewest: ForwardingDatabase {
    let base: any RecordDatabase
    let device: String
    func records(ofType type: String, through base: any RecordDatabase) async throws -> [Record] {
        let all = try await base.records(ofType: type)
        let newest = all.filter { $0.string("device") == device }.compactMap { $0.int("sequence") }.max()
        return all.filter { !($0.string("device") == device && $0.int("sequence") == newest) }
    }
}

/// Holds the next fetch by ID that names a reply's marker (the log's probe) until released,
/// counting saves of the lease alone that landed and saves of turns.
final class MarkerGate: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    private let lock = NSLock()
    private var armed = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var held = false
    private var leaseLanded = 0, turns = 0
    init(_ base: any RecordDatabase) { self.base = base }
    func arm() { lock.withLock { armed = true } }
    var holding: Bool { lock.withLock { held } }
    var leaseSavesLanded: Int { lock.withLock { leaseLanded } }
    var turnSaves: Int { lock.withLock { turns } }
    func release() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { waiter = nil; held = false }; return waiter }
        w?.resume()
    }
    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        let saved = try await base.save(records)
        lock.withLock {
            if records.count == 1, records[0].id == Lease.recordID { leaseLanded += 1 }
            if records.contains(where: { Turn.ref(ofRecordNamed: $0.id.name) != nil }) { turns += 1 }
        }
        return saved
    }
    func fetch(_ ids: [RecordID], through base: any RecordDatabase) async throws -> [RecordID: Record] {
        let hold = lock.withLock { () -> Bool in
            guard armed, ids.contains(where: { $0.name.hasPrefix("append/") }) else { return false }
            armed = false
            return true
        }
        if hold { await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { waiter = c; held = true } } }
        return try await base.fetch(ids)
    }
}
