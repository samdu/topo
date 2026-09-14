import TopoAuth
import TopoCore
import TopoCoreTesting
import TopoTurn
import XCTest

@testable import Topo

/// The lines the chat shows when a turn does not finish on this device. The words are in the log
/// by the time any of them is shown, so none of them may read as "say it again": a second send is
/// a second turn, and the one already in the log is answered by whichever primary next runs a pass.
@MainActor
final class HarnessTests: XCTestCase {
    private let outcomes: [LeaseOutcome] = [
        .held(by: Lease(holder: DeviceID("hub"), endpoint: nil, epoch: 2, expiresAt: Date())),
        .unreachable(Lease(holder: DeviceID("hub"), endpoint: nil, epoch: 2, expiresAt: Date())),
        .contended,
    ]

    func testNoLeaseOutcomeAsksThePersonToSayItAgain() {
        for outcome in outcomes {
            let line = Harness.describe(outcome)
            XCTAssertFalse(line.lowercased().contains("try again"), "\(outcome): \(line)")
            XCTAssertTrue(line.hasSuffix("."), "\(outcome): \(line)")
        }
    }

    func testDisplacementSaysTheWordsAreInTheLog() {
        let line = Harness.describe(TurnRunnerError.displaced)
        XCTAssertTrue(line.contains("in the log"), line)
        XCTAssertFalse(line.lowercased().contains("try again"), line)
    }
}

/// The phone harness as an orchestrator: the persistent line of unsettled turns, the relaunch that
/// finds it, the answering loop, and the handover between primary and viewer. Each test drives a
/// real `Harness` over the in-memory log, with the Messages API behind a scripted transport, and
/// holds what landed in the log, what the harness shows, and what went to the model.
@MainActor
final class HarnessIntegrationTests: XCTestCase {
    private let phone = DeviceID("phone")

    private func makeDefaults() -> UserDefaults {
        let name = "topo.tests.harness.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func harness(_ database: any RecordDatabase, device: DeviceID? = nil, defaults: UserDefaults,
                         transport: ScriptedTransport,
                         ensureZone: @escaping @Sendable () async throws -> Void = {},
                         pause: @escaping @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() }) -> Harness {
        Harness(database: database, tokens: FixedToken(), device: device ?? phone, ensureZone: ensureZone,
                defaults: defaults, transport: transport, leaseSleep: parked, pause: pause)
    }

    private func log(_ database: any RecordDatabase) async throws -> [Turn] {
        try await TurnLog(database: database).read().ordered
    }

    /// A person's turn written the way a watch or a pad writes one: a limb continuing the log.
    @discardableResult
    private func limb(_ database: any RecordDatabase, _ text: String, device: String = "watch") async throws -> Turn {
        let log = TurnLog(database: database)
        let writer = try await log.writer(for: DeviceID(device))
        return try await writer.append(.person, text, continuing: try await log.read())
    }

    /// Another device's lease, claimed over whoever holds it: a hub waking, or a device with no socket.
    private func claim(_ database: any RecordDatabase, as device: String) async throws -> PrimaryLease {
        let lease = PrimaryLease(database: database, device: DeviceID(device), endpoint: nil, probe: NoSocketProbe(),
                                 sleep: parked)
        guard case .primary = try await lease.acquire() else {
            XCTFail("\(device) should have claimed the lease")
            throw Unexpected()
        }
        return lease
    }

    // MARK: A turn as primary

    func testSendingAsPrimaryWritesThePersonsTurnAndTheReplyAsItsChild() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let transport = ScriptedTransport((200, reply("Put them out tonight.")))
        let harness = harness(db, defaults: defaults, transport: transport)

        await harness.send("  I forgot the bins  ")

        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["I forgot the bins", "Put them out tonight."])
        XCTAssertEqual(turns.map(\.role), [.person, .assistant])
        guard turns.count == 2 else { return XCTFail("expected 2 turns in the log, found \(turns.map(\.text))") }
        XCTAssertEqual(turns[0].ref.device, phone)
        XCTAssertEqual(turns[1].parents, [turns[0].ref], "the reply answers the person's turn")
        XCTAssertEqual(harness.turns.map(\.ref), turns.map(\.ref), "the screen shows what is in the log")
        XCTAssertFalse(harness.busy)
        XCTAssertNil(harness.error)
        XCTAssertNil(harness.status)
        XCTAssertTrue(harness.waiting.isEmpty)
        XCTAssertNil(defaults.data(forKey: "topo.harness.outbox"), "nothing is owed on disk")
        XCTAssertEqual(transport.sent, [["I forgot the bins"]])
        let lease = await db.current(Lease.recordID)
        XCTAssertEqual(Lease(record: try XCTUnwrap(lease))?.holder, phone)
    }

    // MARK: A failed model call

    func testAFailedModelCallLeavesTheTurnInTheLogAndTheNextPassAnswersItOnce() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let transport = ScriptedTransport(
            (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            (200, reply("Here now.")))
        let harness = harness(db, defaults: defaults, transport: transport)

        await harness.send("bins?")

        let read1 = try await log(db).map(\.text)
        XCTAssertEqual(read1, ["bins?"], "the words are in the log without a reply")
        XCTAssertEqual(harness.error, "Overloaded")
        XCTAssertTrue(harness.waiting.isEmpty, "a turn in the log is settled: sending it again would be a second turn")
        XCTAssertFalse(harness.hasWaiting)
        XCTAssertNil(defaults.data(forKey: "topo.harness.outbox"))

        await harness.answerPending()
        let answered = try await log(db)
        XCTAssertEqual(answered.map(\.text), ["bins?", "Here now."])
        guard answered.count == 2 else { return XCTFail("expected 2 turns in the log, found \(answered.map(\.text))") }
        XCTAssertEqual(answered[1].parents, [answered[0].ref])
        XCTAssertNil(harness.error, "an answer clears the failure")
        XCTAssertEqual(harness.turns.map(\.text), ["bins?", "Here now."])

        await harness.answerPending()
        let read2 = try await log(db).map(\.text)
        XCTAssertEqual(read2, ["bins?", "Here now."], "one reply, not two")
        XCTAssertEqual(transport.sent, [["bins?"], ["bins?"]], "the second pass found nothing to answer")
    }

    // MARK: A turn that did not reach the log

    func testATurnWhoseWriteWasNotAcknowledgedIsKeptAndItsRetryWritesItOnce() async throws {
        let db = FailingDatabase(InMemoryRecordDatabase())
        let defaults = makeDefaults()
        let transport = ScriptedTransport((200, reply("Calling.")))
        let harness = harness(db, defaults: defaults, transport: transport)
        await db.loseAcknowledgementOfNextTurn()

        await harness.send("call Helen")

        let read3 = try await log(db.wrapped).map(\.text)
        XCTAssertEqual(read3, ["call Helen"], "the write committed")
        XCTAssertEqual(harness.waiting, ["call Helen"], "but the harness does not know it did, so it is still owed")
        XCTAssertTrue(harness.hasWaiting)
        XCTAssertNotNil(harness.error)
        XCTAssertTrue(transport.sent.isEmpty, "no model call for a turn not known to be in the log")

        await harness.retry()

        let read4 = try await log(db.wrapped).map(\.text)
        XCTAssertEqual(read4, ["call Helen", "Calling."], "one person turn, one reply")
        XCTAssertTrue(harness.waiting.isEmpty)
        XCTAssertNil(harness.error)
        XCTAssertEqual(transport.sent, [["call Helen"]], "the model heard the words once")
    }

    func testWordsSaidBehindAStoppedTurnWaitInOrder() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let zone = Switch()
        await zone.set(false)
        let transport = ScriptedTransport((200, reply("one")), (200, reply("two")))
        let harness = harness(db, defaults: defaults, transport: transport, ensureZone: {
            guard await zone.isOn else { throw RecordDatabaseError.unavailable(underlying: Unexpected()) }
        })

        await harness.send("call Helen")
        await harness.send("and book the flights")
        XCTAssertEqual(harness.waiting, ["call Helen", "and book the flights"])
        let read5 = try await log(db).isEmpty
        XCTAssertTrue(read5)

        await zone.set(true)
        await harness.retry()

        let read6 = try await log(db).map(\.text)
        XCTAssertEqual(read6, ["call Helen", "one", "and book the flights", "two"])
        XCTAssertTrue(harness.waiting.isEmpty)
    }

    // MARK: Relaunch

    func testARelaunchRecoversATurnThatCommittedWithoutWritingItTwice() async throws {
        let db = FailingDatabase(InMemoryRecordDatabase())
        let defaults = makeDefaults()
        await db.loseAcknowledgementOfNextTurn()
        let before = harness(db, defaults: defaults, transport: ScriptedTransport())
        await before.send("call Helen")
        XCTAssertEqual(before.waiting, ["call Helen"])

        // The app goes away; a new harness starts over the same disk and the same log.
        let transport = ScriptedTransport((200, reply("Calling.")))
        let relaunched = harness(db, defaults: defaults, transport: transport)
        XCTAssertEqual(relaunched.waiting, ["call Helen"], "the unsettled turn survived the launch")
        XCTAssertTrue(relaunched.hasWaiting)

        await relaunched.retry()

        let turns = try await log(db.wrapped)
        XCTAssertEqual(turns.map(\.text), ["call Helen", "Calling."], "the retry found the committed turn")
        guard turns.count == 2 else { return XCTFail("expected 2 turns in the log, found \(turns.map(\.text))") }
        XCTAssertEqual(turns[1].parents, [turns[0].ref])
        XCTAssertTrue(relaunched.waiting.isEmpty)
        XCTAssertNil(defaults.data(forKey: "topo.harness.outbox"))
        XCTAssertEqual(transport.sent, [["call Helen"]])
    }

    func testARelaunchSendsATurnThatNeverReachedTheLog() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let offline = harness(db, defaults: defaults, transport: ScriptedTransport(),
                              ensureZone: { throw RecordDatabaseError.unavailable(underlying: Unexpected()) })
        await offline.send("water the plants")
        XCTAssertEqual(offline.waiting, ["water the plants"])
        let read7 = try await log(db).isEmpty
        XCTAssertTrue(read7)

        let transport = ScriptedTransport((200, reply("Done.")))
        let relaunched = harness(db, defaults: defaults, transport: transport)
        await relaunched.retry()

        let read8 = try await log(db).map(\.text)
        XCTAssertEqual(read8, ["water the plants", "Done."])
        XCTAssertTrue(relaunched.waiting.isEmpty)
    }

    func testARelaunchAfterASettledTurnOwesNothing() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let first = ScriptedTransport((500, "{}"))
        await harness(db, defaults: defaults, transport: first).send("bins?")
        let read9 = try await log(db).map(\.text)
        XCTAssertEqual(read9, ["bins?"])

        let transport = ScriptedTransport((200, reply("Tonight.")))
        let relaunched = harness(db, defaults: defaults, transport: transport)
        XCTAssertTrue(relaunched.waiting.isEmpty, "a turn known to be in the log is not carried across the launch")
        await relaunched.retry()
        let read10 = try await log(db).map(\.text)
        XCTAssertEqual(read10, ["bins?"], "and the retry writes nothing")
        XCTAssertTrue(transport.sent.isEmpty)

        // The reply it is owed comes from the answering pass, once.
        await relaunched.answerPending()
        let read11 = try await log(db).map(\.text)
        XCTAssertEqual(read11, ["bins?", "Tonight."])
    }

    // MARK: Not primary

    func testNotPrimaryWritesTheTurnAsALimbAndThePrimaryAnswersIt() async throws {
        let db = InMemoryRecordDatabase()
        let phoneTransport = ScriptedTransport((200, reply("one back")))
        let phone = harness(db, defaults: makeDefaults(), transport: phoneTransport)
        await phone.send("one")

        // A hub takes the lease over the phone; the phone yields to it.
        let hubLease = try await claim(db, as: "hub")

        await phone.send("two")

        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["one", "one back", "two"], "the words are in the log, unanswered")
        guard turns.count == 3 else { return XCTFail("expected 3 turns in the log, found \(turns.map(\.text))") }
        XCTAssertEqual(turns[2].ref.device, self.phone)
        XCTAssertEqual(turns[2].role, .person)
        XCTAssertEqual(phoneTransport.sent.count, 1, "a device that is not primary does not call the model")
        XCTAssertTrue(phone.waiting.isEmpty)
        XCTAssertNil(phone.error)
        let info = try XCTUnwrap(phone.info)
        XCTAssertTrue(info.hasPrefix("hub "), info)
        XCTAssertTrue(info.contains("What you said is in the log"), info)

        // The phone's own pass leaves the answer to the primary.
        await phone.answerPending()
        XCTAssertEqual(phoneTransport.sent.count, 1)
        XCTAssertNil(phone.error)

        let hubTransport = ScriptedTransport((200, reply("two back")))
        let hub = harness(db, device: DeviceID("hub"), defaults: makeDefaults(), transport: hubTransport)
        hub.adopt(hubLease)
        await hub.answerPending()

        let answered = try await log(db)
        XCTAssertEqual(answered.map(\.text), ["one", "one back", "two", "two back"])
        guard answered.count == 4 else { return XCTFail("expected 4 turns in the log, found \(answered.map(\.text))") }
        XCTAssertEqual(answered[3].parents, [answered[2].ref])
        XCTAssertEqual(answered[3].ref.device, DeviceID("hub"))
        XCTAssertEqual(hubTransport.sent, [["one", "one back", "two"]])
        XCTAssertEqual(phoneTransport.sent.count, 1)
    }

    // MARK: Displacement

    func testALeaseLostDuringTheModelCallWritesNoReplyAndSaysWhere() async throws {
        let db = InMemoryRecordDatabase()
        let hubLease = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                                    sleep: parked)
        let transport = ScriptedTransport((200, reply("second brain")))
        transport.duringRequest = { _ = try? await hubLease.acquire() }
        let phone = harness(db, defaults: makeDefaults(), transport: transport)

        await phone.send("hello")

        XCTAssertEqual(transport.sent, [["hello"]], "the model was asked")
        let read12 = try await log(db).map(\.text)
        XCTAssertEqual(read12, ["hello"], "a displaced device writes no reply")
        XCTAssertFalse(phone.turns.contains { $0.role == .assistant })
        XCTAssertEqual(phone.error, Harness.describe(TurnRunnerError.displaced))
        XCTAssertTrue(phone.waiting.isEmpty, "the words are in the log, so nothing is owed on this device")
        let hubHolds = await hubLease.isPrimary()
        XCTAssertTrue(hubHolds)

        let hubTransport = ScriptedTransport((200, reply("from the hub")))
        let hub = harness(db, device: DeviceID("hub"), defaults: makeDefaults(), transport: hubTransport)
        hub.adopt(hubLease)
        await hub.answerPending()
        let read13 = try await log(db).map(\.text)
        XCTAssertEqual(read13, ["hello", "from the hub"])
    }

    // MARK: Handover

    func testARoleRecordHandsPrimaryToTheTakerAndBack() async throws {
        let db = InMemoryRecordDatabase()
        let pad = DeviceID("pad")
        let phoneTransport = ScriptedTransport((200, reply("one back")), (200, reply("three back")))
        let padTransport = ScriptedTransport((200, reply("two back")))
        let phoneHarness = harness(db, defaults: makeDefaults(), transport: phoneTransport)
        let padHarness = harness(db, device: pad, defaults: makeDefaults(), transport: padTransport)
        let phoneRole = RoleSelector(database: db, device: phone, defaults: makeDefaults(), isSignedIn: { true },
                                     ensureZone: {}, sleep: lapsing(db))
        let padRole = RoleSelector(database: db, device: pad, defaults: makeDefaults(), isSignedIn: { false },
                                   ensureZone: {}, sleep: lapsing(db))

        await phoneRole.decide()
        XCTAssertEqual(phoneRole.role, .primary)
        await phoneHarness.send("one")
        await padRole.decide()
        XCTAssertEqual(padRole.role, .viewer)

        // Something said on the phone is waiting when the pad takes over.
        phoneHarness.willSend("two")
        let padTaken = await padRole.takePrimary()
        let padLease = try XCTUnwrap(padTaken)
        padHarness.adopt(padLease)

        // The phone's pass finds its role record written as viewer and demotes.
        let demoted = await phoneRole.demotionRecorded()
        XCTAssertTrue(demoted)
        await phoneHarness.demote()
        phoneRole.acceptDemotion()
        XCTAssertEqual(phoneRole.role, .viewer)
        XCTAssertTrue(phoneHarness.waiting.isEmpty, "what was waiting went into the log")
        XCTAssertNil(phoneHarness.error)
        let read15 = try await log(db).map(\.text)
        XCTAssertEqual(read15, ["one", "one back", "two"])
        XCTAssertEqual(phoneTransport.sent.count, 1, "the demoted phone asked the model nothing for it")

        await padHarness.answerPending()
        let read16 = try await log(db).map(\.text)
        XCTAssertEqual(read16, ["one", "one back", "two", "two back"])
        XCTAssertEqual(padTransport.sent.count, 1)

        // And back: the phone takes primary, the pad demotes, the phone answers again.
        let phoneTaken = await phoneRole.takePrimary()
        let phoneLease = try XCTUnwrap(phoneTaken)
        phoneHarness.adopt(phoneLease)
        XCTAssertEqual(phoneRole.role, .primary)
        let padDemoted = await padRole.demotionRecorded()
        XCTAssertTrue(padDemoted)
        await padHarness.demote()
        padRole.acceptDemotion()

        await phoneHarness.send("three")
        await padHarness.answerPending()

        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["one", "one back", "two", "two back", "three", "three back"])
        guard turns.count == 6 else { return XCTFail("expected 6 turns in the log, found \(turns.map(\.text))") }
        XCTAssertEqual(turns[5].ref.device, phone)
        XCTAssertEqual(phoneTransport.sent.count, 2)
        XCTAssertEqual(padTransport.sent.count, 1, "the demoted pad answers nothing")
    }

    // MARK: The answering loop

    func testTheAnsweringLoopAnswersWhileRunningAndNothingOnceStopped() async throws {
        let db = InMemoryRecordDatabase()
        let transport = ScriptedTransport((200, reply("first back")), (200, reply("second back")),
                                          (200, reply("third back")))
        let beats = Beats()
        let phone = harness(db, defaults: makeDefaults(), transport: transport, pause: { try await beats.pause($0) })
        try await limb(db, "first")

        let open = Task { await phone.answering(every: .seconds(5)) }
        try await eventually("the first pass") { await beats.passes >= 1 }
        let read18 = try await log(db).map(\.text)
        XCTAssertEqual(read18, ["first", "first back"])
        XCTAssertEqual(phone.turns.map(\.text), ["first", "first back"], "the pass refreshed the screen")
        let intervals = await beats.intervals
        XCTAssertEqual(intervals, [.seconds(5)])

        try await limb(db, "second")
        await beats.tick()
        try await eventually("the second pass") { await beats.passes >= 2 }
        let read19 = try await log(db).map(\.text)
        XCTAssertEqual(read19, ["first", "first back", "second", "second back"])

        // The chat closes: the loop's task is cancelled, and the loop returns.
        open.cancel()
        await open.value
        try await limb(db, "third")
        XCTAssertEqual(transport.sent.count, 2)
        let passesWhileClosed = await beats.passes
        XCTAssertEqual(passesWhileClosed, 2)

        // The chat opens again: a new loop answers what arrived while it was closed.
        let reopened = Task { await phone.answering(every: .seconds(5)) }
        try await eventually("the pass after reopening") { await beats.passes >= 3 }
        reopened.cancel()
        await reopened.value
        let read20 = try await log(db).map(\.text)
        XCTAssertEqual(read20,
                       ["first", "first back", "second", "second back", "third", "third back"])
        XCTAssertEqual(transport.sent.count, 3)
    }

    /// What a silent push does: a limb writes, and the paused loop answers with no tick of its
    /// pause, through the loop rather than beside it.
    func testAWakeRunsTheNextPassWithoutWaitingOutThePause() async throws {
        let db = InMemoryRecordDatabase()
        let transport = ScriptedTransport((200, reply("first back")), (200, reply("second back")))
        let beats = Beats()
        let phone = harness(db, defaults: makeDefaults(), transport: transport, pause: { try await beats.pause($0) })
        try await limb(db, "first")

        let open = Task { await phone.answering(every: .seconds(5)) }
        try await eventually("the first pass") { await beats.passes >= 1 }

        try await limb(db, "second")
        await phone.wake()
        let woken = try await log(db).map(\.text)
        XCTAssertEqual(woken, ["first", "first back", "second", "second back"], "the wake returns once its pass has run")
        XCTAssertEqual(phone.turns.map(\.text), woken)
        try await eventually("the loop pausing again") { await beats.passes >= 2 }
        XCTAssertEqual(transport.sent.count, 2, "one model call per turn: no pass ran beside the loop's")

        open.cancel()
        await open.value
        // Nothing is answering, so a push that lands now wakes nothing and does not wait.
        await phone.wake()
        XCTAssertEqual(transport.sent.count, 2)
    }
}

// MARK: - Doubles

/// The Messages API's far end: answers from a queue and records what each request carried.
private final class ScriptedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]
    private var _sent: [[String]] = []
    /// Runs while a request is in flight, before its answer.
    var duringRequest: (@Sendable () async -> Void)?

    init(_ replies: (Int, String)...) { self.replies = replies }

    /// The contents of each request's messages, in order.
    var sent: [[String]] { lock.withLock { _sent } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let contents = (body?["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String } ?? []
        lock.withLock { _sent.append(contents) }
        await duringRequest?()
        return lock.withLock {
            let (status, text) = replies.isEmpty ? (500, "{}") : replies.removeFirst()
            return (Data(text.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
}

private func reply(_ text: String) -> String {
    #"{"id":"msg","type":"message","model":"claude-haiku-4-5","content":[{"type":"text","text":"\#(text)"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
}

private struct FixedToken: TokenProvider {
    func accessToken() async throws -> String { "tok" }
}

private struct Unexpected: Error {}

/// A heartbeat loop that never beats inside a test: the lease is renewed by the turns themselves.
private let parked: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

/// The in-memory log, able to commit the next person's turn and then throw, which is what a lost
/// acknowledgement looks like from the writer's side.
private actor FailingDatabase: RecordDatabase {
    let wrapped: InMemoryRecordDatabase
    private var loseNextTurnAcknowledgement = false

    init(_ wrapped: InMemoryRecordDatabase) { self.wrapped = wrapped }

    func loseAcknowledgementOfNextTurn() { loseNextTurnAcknowledgement = true }

    func save(_ records: [Record]) async throws -> [Record] {
        let saved = try await wrapped.save(records)
        if loseNextTurnAcknowledgement, records.contains(where: { $0.type == Turn.recordType }) {
            loseNextTurnAcknowledgement = false
            throw RecordDatabaseError.unavailable(underlying: Unexpected())
        }
        return saved
    }

    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await wrapped.records(ofType: type) }
}

private actor Switch {
    private(set) var isOn = true
    func set(_ on: Bool) { isOn = on }
}

/// The answering loop's pause, driven by the test: each pause counts a finished pass and waits
/// for `tick()`, and a cancelled loop is released at once.
private actor Beats {
    private(set) var passes = 0
    private(set) var intervals: [Duration] = []
    private var permits = 0
    private var waiter: CheckedContinuation<Void, any Error>?

    func pause(_ interval: Duration) async throws {
        passes += 1
        intervals.append(interval)
        try Task.checkCancellation()
        if permits > 0 {
            permits -= 1
            return
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { await self.release() }
        }
    }

    func tick() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            permits += 1
        }
    }

    private func release() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

/// Waits for something the test can observe, failing rather than hanging when it never comes.
@MainActor
private func eventually(_ what: String, within seconds: TimeInterval = 10,
                        _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !(try await condition()) {
        guard Date() < deadline else {
            XCTFail("timed out waiting for \(what)")
            throw Unexpected()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// A takeover's wait as real time would leave the record: the sleep is instant, so the lease the
/// wait was for is backdated to lapsed.
private func lapsing(_ db: InMemoryRecordDatabase) -> @Sendable (TimeInterval) async throws -> Void {
    { _ in
        if var record = await db.current(Lease.recordID) {
            record.fields["expiresAt"] = .date(Date(timeIntervalSinceNow: -1))
            _ = try await db.save(record)
        }
    }
}
