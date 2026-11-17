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
        // The zone's change feed alone: mutant, the whole read, its fetch by ID included.
        #expect(db.fetched.isEmpty)
    }

    @Test func aPassReadsTheReplysMarkerAndTheChoiceInTheLogsOneFetch() async throws {
        let store = InMemoryRecordDatabase()
        let db = RecordingDatabase(inner: store)
        let brain = ScriptedBrain(.success("hello"), .success("again"))
        let (runner, lease) = try await makeRunner(database: db, device: "mac-hub", brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        let said = SaidModels()
        // What was fetched by the time the brain is asked.
        let asked = SaidFetches()
        brain.duringAnswer = { asked.add(db.fetched) }
        try await limbSays("hi", in: store, nonce: "w1")
        db.reset()
        #expect(try await runner.answerPending(since: nil, choosingFrom: { said.add($0); return $0 ?? .sonnet })?.text == "hello")
        // Mutant: the marker, or the choice, fetched in a request of its own.
        #expect(asked.all.last?.count == 1)
        let marker = TurnLog.markerID(appendedUnder: TurnRunner.replyNonce(for: [TurnRef(device: DeviceID("watch"), sequence: 1)]))
        let probe = Set(asked.all.last?.first ?? [])
        #expect(probe.isSuperset(of: [ModelChoice.recordID, marker]))
        #expect(said.all == [nil])

        try await ModelChoice.say(.opus, by: DeviceID("watch"), to: store)
        try await limbSays("and now", in: store, nonce: "w2")
        db.reset()
        #expect(try await runner.answerPending(since: nil, choosingFrom: { said.add($0); return $0 ?? .sonnet })?.text == "again")
        #expect(asked.all.last?.count == 1)
        #expect(said.all == [nil, .opus])
        #expect(brain.requests.map(\.model) == [.sonnet, .opus])
    }

    /// A pass that asks for the lease the long way finds a reply another device wrote while it
    /// asked: the marker is fetched after the claim, not only with the log before it.
    @Test func aReplyWrittenWhileThePassAsksForTheLeaseIsFoundAndTheBrainAskedNothing() async throws {
        let store = InMemoryRecordDatabase()
        let nonce = TurnRunner.replyNonce(for: [TurnRef(device: DeviceID("watch"), sequence: 1)])
        let db = ReplyDuringClaim(store, nonce: nonce, failRenewal: false)
        let brain = ScriptedBrain(.success("never"))
        // Never claimed: the pass asks for the lease with `acquire()`.
        let (runner, _) = try await makeRunner(database: db, brain: brain)
        try await limbSays("hi", in: store, nonce: "w1")
        db.arm()
        let reply = try await runner.answerPending(model: .sonnet)
        // Mutant: the marker fetched with the log, before the claim, taken as the answer.
        #expect(reply?.text == "theirs")
        #expect(brain.requests.isEmpty)
        #expect(brain.landedNonces == [nonce])
    }

    /// The same when the renewal of a lease held fresh could not be sent and the long way claims it.
    @Test func aReplyWrittenWhileAFailedRenewalIsAskedTheLongWayIsFound() async throws {
        let store = InMemoryRecordDatabase()
        let nonce = TurnRunner.replyNonce(for: [TurnRef(device: DeviceID("watch"), sequence: 1)])
        let db = ReplyDuringClaim(store, nonce: nonce, failRenewal: true)
        let brain = ScriptedBrain(.success("never"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        try await limbSays("hi", in: store, nonce: "w1")
        db.arm()
        let reply = try await runner.answerPending(model: .sonnet)
        // Mutant: no marker asked after the long way's claim.
        #expect(reply?.text == "theirs")
        #expect(brain.requests.isEmpty)
    }

    /// The renewal of a lease held fresh goes out once the feed shows a turn to answer, beside the
    /// log's fetch by ID rather than after it: the fetch here waits for the renewal to land.
    @Test func theRenewalIsSentBesideTheLogsFetchByID() async throws {
        let store = InMemoryRecordDatabase()
        let db = RenewalFirst(store)
        let brain = ScriptedBrain(.success("hello"))
        let (runner, lease) = try await makeRunner(database: db, brain: brain)
        guard case .primary = try await lease.acquire() else { Issue.record("the lease should be claimed"); return }
        try await limbSays("hi", in: store, nonce: "w1")
        db.arm()
        #expect(try await runner.answerPending(model: .sonnet)?.text == "hello")
        // Mutant: the renewal sent once the fetch by ID has answered.
        #expect(db.order == ["renewal", "probe"])
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

/// Once armed: a save of the lease alone fails as CloudKit unreachable when `failRenewal`, and the
/// first fetch of the lease record writes, before it answers, a pad's reply to the log under
/// `nonce`, as another device answering while this one asks for the lease.
final class ReplyDuringClaim: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    private let store: InMemoryRecordDatabase
    private let nonce: String
    private let failRenewal: Bool
    private let lock = NSLock()
    private var armed = false
    private var failing = false
    init(_ store: InMemoryRecordDatabase, nonce: String, failRenewal: Bool) {
        self.store = store
        base = store
        self.nonce = nonce
        self.failRenewal = failRenewal
    }
    func arm() { lock.withLock { armed = true; failing = failRenewal } }
    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        let fail = lock.withLock { () -> Bool in
            guard failing, records.count == 1, records[0].id == Lease.recordID else { return false }
            failing = false
            return true
        }
        if fail { throw RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet)) }
        return try await base.save(records)
    }
    func fetch(_ ids: [RecordID], through base: any RecordDatabase) async throws -> [RecordID: Record] {
        let write = lock.withLock { () -> Bool in
            guard armed, ids == [Lease.recordID] else { return false }
            armed = false
            return true
        }
        if write {
            let log = TurnLog(database: store)
            let parents = try await log.read().heads
            _ = try await log.writer(for: DeviceID("pad")).append(.assistant, "theirs", parents: parents, nonce: nonce)
        }
        return try await base.fetch(ids)
    }
}

final class SaidFetches: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[[RecordID]]] = []
    func add(_ fetched: [[RecordID]]) { lock.withLock { seen.append(fetched) } }
    var all: [[[RecordID]]] { lock.withLock { seen } }
}

final class SaidModels: @unchecked Sendable {
    private let lock = NSLock()
    private var said: [ClaudeModel?] = []
    func add(_ model: ClaudeModel?) { lock.withLock { said.append(model) } }
    var all: [ClaudeModel?] { lock.withLock { said } }
}

/// Once armed, the next fetch by ID naming a turn waits (2 s at most) for a save of the lease alone
/// to land, and the order the two landed in is kept.
final class RenewalFirst: ForwardingDatabase, @unchecked Sendable {
    let base: any RecordDatabase
    private let lock = NSLock()
    private var armed = false
    private var watching = false
    private var renewed = false
    private var _order: [String] = []
    init(_ base: any RecordDatabase) { self.base = base }
    func arm() { lock.withLock { armed = true; watching = true; renewed = false; _order = [] } }
    var order: [String] { lock.withLock { _order } }
    func save(_ records: [Record], through base: any RecordDatabase) async throws -> [Record] {
        let saved = try await base.save(records)
        if records.count == 1, records[0].id == Lease.recordID {
            lock.withLock { if watching, !renewed { renewed = true; _order.append("renewal") } }
        }
        return saved
    }
    func fetch(_ ids: [RecordID], through base: any RecordDatabase) async throws -> [RecordID: Record] {
        let probe = lock.withLock { armed && ids.contains { Turn.ref(ofRecordNamed: $0.name) != nil } }
        if probe {
            lock.withLock { armed = false }
            for _ in 0..<200 where !lock.withLock({ renewed }) { try await Task.sleep(for: .milliseconds(10)) }
        }
        let fetched = try await base.fetch(ids)
        if probe { lock.withLock { _order.append("probe") } }
        return fetched
    }
}

final class ChoiceCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.withLock { n += 1 } }
    var count: Int { lock.withLock { n } }
}
