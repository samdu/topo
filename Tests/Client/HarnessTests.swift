import AVFoundation
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
/// holds what landed in the log, what the harness shows, and what went to the model. The same
/// scenarios run again with the guest as the brain (`HarnessGuestIntegrationTests`).
@MainActor
class HarnessIntegrationTests: XCTestCase {
    fileprivate let phone = DeviceID("phone")

    /// The brain a harness in these scenarios answers with, over the scenario's scripted answers.
    /// `defaults` and `device` say which device, and which launch of it, the harness is.
    fileprivate func brain(_ transport: ScriptedTransport, device: DeviceID, defaults: UserDefaults) -> any Brain {
        messagesBrain(over: transport)
    }

    /// The line the chat shows when the model failed with `message`: the API's own words.
    fileprivate func failureShown(_ message: String) -> String { message }

    /// What a brain that has seen none of the log is asked, for `words` said after `unseen`: the
    /// Messages API is sent the history, one message per turn.
    fileprivate func asked(unseen: [(TurnRole, String)], saying words: String) -> [String] {
        unseen.map(\.1) + [words]
    }

    fileprivate func makeDefaults() -> UserDefaults {
        let name = "topo.tests.harness.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    fileprivate func harness(_ database: any RecordDatabase, device: DeviceID? = nil, defaults: UserDefaults,
                             transport: ScriptedTransport,
                             ensureZone: @escaping @Sendable () async throws -> Void = {},
                             pause: @escaping @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() }) -> Harness {
        Harness(database: database, tokens: FixedToken(), device: device ?? phone, ensureZone: ensureZone,
                defaults: defaults, brain: brain(transport, device: device ?? phone, defaults: defaults),
                leaseSleep: parked, pause: pause)
    }

    fileprivate func log(_ database: any RecordDatabase) async throws -> [Turn] {
        try await TurnLog(database: database).read().ordered
    }

    /// A person's turn written the way a watch or a pad writes one: a limb continuing the log.
    @discardableResult
    fileprivate func limb(_ database: any RecordDatabase, _ text: String, device: String = "watch") async throws -> Turn {
        let log = TurnLog(database: database)
        let writer = try await log.writer(for: DeviceID(device))
        return try await writer.append(.person, text, continuing: try await log.read())
    }

    /// Another device's lease, claimed over whoever holds it: a hub waking, or a device with no socket.
    fileprivate func claim(_ database: any RecordDatabase, as device: String) async throws -> PrimaryLease {
        let lease = PrimaryLease(database: database, device: DeviceID(device), endpoint: nil, probe: NoSocketProbe(),
                                 sleep: parked)
        guard case .primary = try await lease.acquire() else {
            XCTFail("\(device) should have claimed the lease")
            throw Unexpected()
        }
        return lease
    }

    // MARK: The first read

    /// The transcript is the log's once it has been read: `hasRead` is false until the first
    /// refresh ends, true after it whether the log held anything, and false again after a
    /// sign-out, which empties what the transcript draws.
    func testTheFirstReadIsMarkedAndASignOutClearsIt() async throws {
        let db = InMemoryRecordDatabase()
        try await limb(db, "Anything from Helen?")
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport())
        XCTAssertFalse(harness.hasRead)
        XCTAssertTrue(harness.turns.isEmpty)
        await harness.refresh()
        XCTAssertTrue(harness.hasRead)
        XCTAssertEqual(harness.turns.map(\.text), ["Anything from Helen?"])
        await harness.forget()
        XCTAssertFalse(harness.hasRead)
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

    /// The context Topo wears is everything the reply was written over: input and both cache
    /// counts. A cached conversation is mostly cache reads, so input alone would show him a
    /// nearly empty context on a nearly full one.
    func testTheContextOfAReplyCountsItsCacheAndReachesTopo() async throws {
        let db = InMemoryRecordDatabase()
        let cached = #"{"id":"msg","type":"message","model":"claude-haiku-4-5","content":[{"type":"text","text":"Tonight."}],"stop_reason":"end_turn","usage":{"input_tokens":10,"cache_read_input_tokens":90000,"cache_creation_input_tokens":2500,"output_tokens":4}}"#
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport((200, cached)))

        await harness.send("When are the bins?")

        XCTAssertNil(harness.error)
        XCTAssertEqual(harness.context, 92_510)
        let mascot = Mascot(model: "claude-haiku-4-5")
        mascot.harness(model: "claude-haiku-4-5", tokens: harness.context)
        XCTAssertEqual(mascot.state.tokens, 92_510)
    }

    /// A sign-out takes the last reply's context with it. The app keeps one `Mascot` across logins
    /// and the chat hands it the harness's context as it appears, so a context left behind is the
    /// last person's load worn by the next one until their first reply.
    func testASignOutTakesTheContextAndTopoWearsNone() async throws {
        let db = InMemoryRecordDatabase()
        let full = #"{"id":"msg","type":"message","model":"claude-haiku-4-5","content":[{"type":"text","text":"Tonight."}],"stop_reason":"end_turn","usage":{"input_tokens":10,"cache_read_input_tokens":259000,"cache_creation_input_tokens":0,"output_tokens":4}}"#
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport((200, full)))
        let mascot = Mascot(model: "claude-haiku-4-5")

        await harness.send("When are the bins?")
        mascot.harness(model: "claude-haiku-4-5", tokens: harness.context)
        XCTAssertEqual(mascot.state.tokens, 259_010)

        await harness.forget()
        XCTAssertNil(harness.context, "the last login's context outlived the sign-out")
        // The next sign-in's chat appears and hands Topo what the harness has.
        mascot.harness(model: "claude-haiku-4-5", tokens: harness.context)
        XCTAssertEqual(mascot.state.tokens, 0, "Topo wore the last login's load after a sign-out")
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
        XCTAssertEqual(harness.error, failureShown("Overloaded"))
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

    // MARK: The row at the end of the transcript

    /// The row draws the turn it holds until that turn is in the log. A write that never reached
    /// the log leaves the words owed under their own nonce, so the row stays in flight, the
    /// harness sends them again from the outbox, and the way back is offered.
    func testAWriteThatNeverReachedTheLogLeavesOneOutboxEntryAndTheRowInFlight() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let zone = Switch()
        await zone.set(false)
        let harness = harness(db, defaults: defaults, transport: ScriptedTransport(), ensureZone: {
            guard await zone.isOn else { throw RecordDatabaseError.unavailable(underlying: Unexpected()) }
        })

        let nonce = harness.willSend("water the plants")
        await harness.retry()

        let turns = try await log(db)
        XCTAssertTrue(turns.isEmpty, "nothing reached the log: \(turns.map(\.text))")
        XCTAssertEqual(harness.waiting, ["water the plants"], "one entry on the line, not two")
        XCTAssertFalse(harness.said(nonce), "the row is in flight: the turn is not in the log")
        XCTAssertTrue(harness.canWithdraw(nonce), "the words can be taken back off a stopped line")

        // And the line's own way forward still works: the same words, the same nonce, one turn.
        await zone.set(true)
        await harness.retry()
        let sent = try await log(db).map(\.text)
        XCTAssertEqual(sent, ["water the plants"])
        XCTAssertTrue(harness.said(nonce))
        XCTAssertTrue(harness.waiting.isEmpty)
    }

    /// Taking the words back and saying them again is one turn under one nonce: the entry the
    /// first send made is off the line before the second is put on it.
    func testTakingBackATurnThatNeverLandedMakesTheResendOneTurn() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let zone = Switch()
        await zone.set(false)
        let transport = ScriptedTransport((200, reply("Done.")))
        let harness = harness(db, defaults: defaults, transport: transport, ensureZone: {
            guard await zone.isOn else { throw RecordDatabaseError.unavailable(underlying: Unexpected()) }
        })

        let first = harness.willSend("water the plans")
        await harness.retry()
        XCTAssertEqual(harness.waiting, ["water the plans"])

        let taken = await harness.withdraw(first)
        XCTAssertTrue(taken, "the words were not taken back")
        XCTAssertTrue(harness.waiting.isEmpty, "the entry is still on the line")
        XCTAssertNil(defaults.data(forKey: "topo.harness.outbox"), "and still on disk")
        XCTAssertFalse(harness.canWithdraw(first), "there is nothing left to take back")

        // The words, changed, said again: a second nonce, and the first one sends nothing.
        await zone.set(true)
        let second = harness.willSend("water the plants")
        XCTAssertNotEqual(second, first)
        await harness.retry()

        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["water the plants", "Done."], "one turn, not two")
        XCTAssertEqual(turns.filter { $0.role == .person }.count, 1)
        XCTAssertTrue(harness.said(second))
        XCTAssertFalse(harness.said(first), "the withdrawn nonce wrote a turn of its own")
        XCTAssertEqual(transport.sent, [["water the plants"]], "the model heard the words once")
        XCTAssertTrue(harness.waiting.isEmpty)
    }

    /// The write committed and the acknowledgement was lost. The read that follows the failure
    /// finds the turn, so the row clears on it: the words are said, whatever this device is still
    /// owed on disk, and what is left is the reply, which the retry brings under the same nonce.
    func testALostAcknowledgementIsFoundByTheReadAfterItAndClearsTheRow() async throws {
        let db = FailingDatabase(InMemoryRecordDatabase())
        let defaults = makeDefaults()
        let transport = ScriptedTransport((200, reply("Calling.")))
        let harness = harness(db, defaults: defaults, transport: transport)
        await db.loseAcknowledgementOfNextTurn()

        let row = NextTurn()
        row.text = "call Helen"
        let nonce = try XCTUnwrap(row.send(via: harness))
        await harness.retry()

        XCTAssertEqual(harness.waiting, ["call Helen"], "the turn is still owed on this device")
        XCTAssertTrue(harness.said(nonce), "the read after the failure found the committed turn")
        XCTAssertFalse(row.canWithdraw(in: harness), "so there is nothing to take back")
        XCTAssertFalse(row.sending(in: harness), "the row is still drawing a turn that is in the log")
        XCTAssertTrue(row.clearIfLanded(in: harness), "the row kept the words of a turn that landed")
        XCTAssertEqual(row.text, "", "the words stayed in the row")
        XCTAssertNil(row.sent, "the row is still holding the turn")

        await harness.retry()
        let turns = try await log(db.wrapped)
        XCTAssertEqual(turns.map(\.text), ["call Helen", "Calling."], "one person's turn, one reply")
        XCTAssertEqual(turns.filter { $0.role == .person }.count, 1)
        XCTAssertEqual(transport.sent, [["call Helen"]])
        XCTAssertTrue(harness.waiting.isEmpty)
    }

    /// The same lost acknowledgement, with the read after it lost too: this device has every
    /// reason to believe the words never landed, and the row offers the way back. The withdrawal
    /// asks the log itself, and that is what refuses it — the entry stays, so the retry goes
    /// under the nonce the turn already carries and writes nothing twice.
    func testTakingBackIsRefusedByTheLogItselfWhenTheTurnIsAlreadyThere() async throws {
        let db = FailingDatabase(InMemoryRecordDatabase())
        let defaults = makeDefaults()
        let transport = ScriptedTransport((200, reply("Calling.")))
        let harness = harness(db, defaults: defaults, transport: transport)
        await db.goDarkAfterTheNextTurn()

        let nonce = harness.willSend("call Helen")
        await harness.retry()
        XCTAssertEqual(harness.waiting, ["call Helen"])
        XCTAssertFalse(harness.said(nonce), "nothing this device could read said the turn had landed")
        XCTAssertTrue(harness.canWithdraw(nonce), "so the row offers the way back")

        await db.refuseReads(false)
        let taken = await harness.withdraw(nonce)
        XCTAssertFalse(taken, "the words were taken back although they are in the log")
        XCTAssertTrue(harness.said(nonce), "asking the log is what found the turn, and the row clears")
        XCTAssertEqual(harness.waiting, ["call Helen"], "the entry stays, so the retry is under this nonce")
        XCTAssertFalse(harness.canWithdraw(nonce), "and the way back is gone")

        await harness.retry()
        let turns = try await log(db.wrapped)
        XCTAssertEqual(turns.map(\.text), ["call Helen", "Calling."], "one person's turn, one reply")
        XCTAssertEqual(turns.filter { $0.role == .person }.count, 1)
        XCTAssertEqual(transport.sent, [["call Helen"]], "the model heard the words once")
    }

    /// A read that failed is not an answer either: the words stay owed under their own nonce and
    /// the line's own retry is what sends them, so nothing is taken back on what this device
    /// merely hopes is true.
    func testTakingBackIsRefusedWhenTheLogCannotBeRead() async throws {
        let db = FailingDatabase(InMemoryRecordDatabase())
        let defaults = makeDefaults()
        let harness = harness(db, defaults: defaults, transport: ScriptedTransport(),
                              ensureZone: { throw RecordDatabaseError.unavailable(underlying: Unexpected()) })

        let nonce = harness.willSend("water the plants")
        await harness.retry()
        XCTAssertEqual(harness.waiting, ["water the plants"])

        await db.refuseReads(true)
        let taken = await harness.withdraw(nonce)
        XCTAssertFalse(taken, "the words were taken back on a log nobody could read")
        XCTAssertEqual(harness.waiting, ["water the plants"], "and they are still owed")
        XCTAssertNotNil(harness.error)
    }

    /// An attempt is a write that may be landing as the way back is asked for, so it is not
    /// offered while one is running. The moment that matters is the one before the turn is
    /// written — the zone, the lease, the read — where the words are owed and no turn of theirs
    /// is in the log yet, and that is where this asks.
    func testTakingBackIsNotOfferedWhileAnAttemptIsInFlight() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let transport = ScriptedTransport((200, reply("Tonight.")))
        let probe = Probe()
        let answer = Answers()
        let harness = harness(db, defaults: defaults, transport: transport,
                              ensureZone: { await answer.set(await MainActor.run { probe.ask() }) })
        let nonce = harness.willSend("bins?")
        probe.set { harness.canWithdraw(nonce) }
        XCTAssertTrue(harness.canWithdraw(nonce), "the words are owed and nothing is attempting them")

        await harness.retry()

        let offered = await answer.value
        XCTAssertEqual(offered, false, "the way back was offered while the turn was being written")
        let answered = try await log(db).map(\.text)
        XCTAssertEqual(answered, ["bins?", "Tonight."])
    }

    /// The reply failed and the person's turn is in the log: the words are said, so the row
    /// clears and the bubble that lands is the one that was being written in. Nothing is owed on
    /// this device, and the answering pass is what brings the reply.
    func testAFailedModelReplyClearsTheRowAndLeavesTheTurnToTheNextPass() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let transport = ScriptedTransport(
            (529, #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            (200, reply("Tonight.")))
        let harness = harness(db, defaults: defaults, transport: transport)

        let row = NextTurn()
        row.text = "bins?"
        let nonce = try XCTUnwrap(row.send(via: harness))
        await harness.retry()

        let written = try await log(db).map(\.text)
        XCTAssertEqual(written, ["bins?"])
        XCTAssertTrue(harness.said(nonce), "the words are in the log")
        XCTAssertTrue(harness.waiting.isEmpty, "and nothing is owed, so the row is not in flight")
        XCTAssertFalse(row.sending(in: harness), "the row is still drawing the turn as on its way")
        XCTAssertFalse(row.canWithdraw(in: harness), "what is in the log cannot be taken back")
        XCTAssertTrue(row.clearIfLanded(in: harness), "the row kept the words of a turn that landed")
        XCTAssertEqual(row.text, "", "the words stayed in the row although the turn is in the log")
        XCTAssertNil(row.sent)
        XCTAssertEqual(harness.error, failureShown("Overloaded"))

        await harness.answerPending()
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["bins?", "Tonight."], "one turn, answered once")
        XCTAssertEqual(turns.filter { $0.role == .person }.count, 1)
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
        XCTAssertEqual(hubTransport.sent, [asked(unseen: [(.person, "one"), (.assistant, "one back")], saying: "two")])
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

    // MARK: The reply that is read aloud

    /// A reply written by another primary — the hub, or a phone holding the lease.
    @discardableResult
    private func elsewhere(_ database: any RecordDatabase, _ text: String,
                           device: String = "hub") async throws -> Turn {
        let log = TurnLog(database: database)
        let writer = try await log.writer(for: DeviceID(device))
        return try await writer.append(.assistant, text, continuing: try await log.read())
    }

    /// The decision to read a reply aloud is the harness's own path, not a view's: behind the
    /// lock nothing is drawn. A reply this phone wrote reaches it once.
    func testAReplyThisPhoneWroteReachesTheReplyHandlerOnce() async throws {
        let db = InMemoryRecordDatabase()
        let transport = ScriptedTransport((200, reply("Put them out tonight.")))
        let harness = harness(db, defaults: makeDefaults(), transport: transport)
        let heard = Said()
        harness.onReply = { heard.add($0.text); return true }

        await harness.send("I forgot the bins")
        await harness.refresh()

        XCTAssertEqual(heard.texts, ["Put them out tonight."],
                       "the person's own turn is not a reply, and the reply comes once")
    }

    /// The log's shared path: another primary answered, and a pass brought the reply here. It
    /// reaches the same one decision point, once, though no turn of it was written on this phone.
    func testAReplyAnotherDeviceWroteReachesTheReplyHandlerOnce() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport())
        let heard = Said()
        harness.onReply = { heard.add($0.text); return true }

        try await limb(db, "what is the capital of France")
        try await elsewhere(db, "Paris.")
        await harness.refresh()
        await harness.refresh()

        XCTAssertEqual(heard.texts, ["Paris."], "read once, however many passes read the log")
    }

    /// Both paths see a reply this phone wrote: `show` as it lands and `refresh` on the next
    /// pass. It is offered once.
    func testAReplyBothPathsSeeIsOfferedOnce() async throws {
        let db = InMemoryRecordDatabase()
        let transport = ScriptedTransport((200, reply("Paris.")))
        let harness = harness(db, defaults: makeDefaults(), transport: transport)
        let heard = Said()
        harness.onReply = { heard.add($0.text); return true }

        await harness.send("what is the capital of France")
        await harness.refresh()
        await harness.answerPending()

        XCTAssertEqual(heard.texts, ["Paris."])
    }

    /// The gap at the start: the screen reads the log and sends what an earlier launch left owed
    /// before it installs the handler, so a reply can land with nothing listening. It is offered
    /// when the handler arrives, and once.
    func testAReplyThatLandedBeforeTheHandlerWasInstalledIsOfferedOnce() async throws {
        let db = InMemoryRecordDatabase()
        let transport = ScriptedTransport((200, reply("Paris.")))
        let harness = harness(db, defaults: makeDefaults(), transport: transport)

        // No handler yet: the chat is still doing what it does before it installs one.
        await harness.send("what is the capital of France")
        await harness.refresh()

        let heard = Said()
        harness.onReply = { heard.add($0.text); return true }
        XCTAssertEqual(heard.texts, ["Paris."], "the reply that arrived unheard is offered on install")

        await harness.refresh()
        harness.onReply = { heard.add($0.text); return true }
        XCTAssertEqual(heard.texts, ["Paris."], "and not again, by either path")
    }

    /// The words said before the app went away survive the relaunch in the outbox, and what made
    /// them a spoken turn survives with them: a fresh harness over the same store and log sends
    /// them, and the reply is still one to read aloud though no press happened on this run.
    func testASpokenTurnPersistedAcrossARelaunchIsStillReadAloud() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()

        // The launch that said it and went away before it could be sent.
        let before = harness(db, defaults: defaults, transport: ScriptedTransport())
        before.markSpoken(before.willSend("what is the capital of France"))

        // The launch that finds it: a new harness over the same defaults and the same log.
        let after = harness(db, defaults: defaults,
                            transport: ScriptedTransport((200, reply("Paris."))))
        await after.retry()
        let landed = try await log(db).map(\.text)
        XCTAssertEqual(landed, ["what is the capital of France", "Paris."])

        let heard = Said()
        after.onReply = { reply in
            guard let asked = after.spokenTurn(answeredBy: reply) else { return true }
            after.answeredAloud(asked)
            heard.add(reply.text)
            return true
        }
        XCTAssertEqual(heard.texts, ["Paris."], "the reply to what was said before the relaunch")

        await after.refresh()
        XCTAssertEqual(heard.texts, ["Paris."], "and it is owed no second reading")
    }

    /// A turn that ends in a failure says so as it ends, naming itself: the screen's error line
    /// cannot say whose turn stopped, and a wait that reads it would hold the phone awake to its
    /// ceiling for a reply nothing is bringing. A turn still going is not named.
    func testAFailedTurnNamesItselfAndOneStillGoingDoesNot() async throws {
        let db = InMemoryRecordDatabase()
        let transport = ScriptedTransport(
            (500, #"{"type":"error","error":{"type":"api_error","message":"Internal"}}"#),
            (200, reply("Rome.")))
        let harness = harness(db, defaults: makeDefaults(), transport: transport)
        let failed = Said()
        harness.onTurnFailed = { failed.add($0) }

        let first = harness.willSend("what is the capital of France")
        let second = harness.willSend("and of Italy")
        await harness.retry()

        XCTAssertEqual(failed.texts, [first], "the turn that stopped, as it stopped")
        XCTAssertFalse(failed.texts.contains(second), "the one behind it was answered")
        XCTAssertNotNil(harness.error)
    }

    /// Read replies aloud off at the release: the turn is not one whose reply is read, so nothing
    /// records it as spoken. A launch that turns the setting on afterwards would otherwise speak
    /// a reply from last week.
    func testATurnSentWithRepliesNotReadAloudIsNotSpokenAfterARelaunch() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let before = harness(db, defaults: defaults,
                             transport: ScriptedTransport((200, reply("Paris."))))
        // Nothing marks it: the wait refused, so the chat recorded no mark.
        before.willSend("what is the capital of France")
        await before.retry()

        // A later launch, with the setting turned on: the reply is history, not an answer to
        // anything this phone is waiting to hear.
        let after = harness(db, defaults: defaults, transport: ScriptedTransport())
        await after.refresh()
        let heard = Said()
        after.onReply = { reply in
            guard let asked = after.spokenTurn(answeredBy: reply) else { return true }
            after.answeredAloud(asked)
            heard.add(reply.text)
            return true
        }
        XCTAssertEqual(heard.texts, [], "nothing spoken was owed a reading")
    }

    /// The chat's own handler, as the screen installs it: the mark is the decision, so a reply
    /// whose turn is marked is read whatever the setting reads now.
    @MainActor
    private func install(_ harness: Harness, _ speaker: Speaker, _ said: Said) {
        harness.onReply = { reply in
            guard let asked = harness.spokenTurn(answeredBy: reply) else { return true }
            guard speaker.speak(reply.text, answering: asked) else { return false }
            harness.answeredAloud(asked)
            said.add(reply.text)
            return true
        }
    }

    /// The setting governs what a release decides, not what a turn already released is owed: a
    /// question asked aloud and answered after Read replies aloud was turned off is still that
    /// question's answer, and leaving it unread would strand its mark and its hold. What ends the
    /// hold is `speak` taking the reply, which is `testTheKeeperDoesNotStopBetweenTheWaitAndTheReply`.
    func testAReplyIsReadWhenItsTurnIsMarkedWhateverTheSettingReadsNow() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let harness = harness(db, defaults: defaults,
                              transport: ScriptedTransport((200, reply("Paris."))))
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let speaker = try await makeSpeaker(seams, audio, center)
        let said = Said()
        install(harness, speaker, said)

        // The release, with the setting on: the wait is held and the turn marked.
        let nonce = harness.willSend("what is the capital of France")
        XCTAssertTrue(speaker.awaitReply(nonce, readAloud: true).spoken)
        harness.markSpoken(nonce)

        // The setting goes off before the reply lands. What it governs is the next release.
        await harness.retry()
        XCTAssertEqual(said.texts, ["Paris."], "the turn was marked, so its reply is read")
        XCTAssertEqual(defaults.stringArray(forKey: "topo.harness.spoken"), nil, "and the mark is cleared")
        XCTAssertEqual(speaker.report.speaks, 1)
    }

    /// Two things asked aloud and left unanswered by an app that went away: what a person coming
    /// back is owed is the answer to the last thing they said, not a backlog read at them — and
    /// each reply spoken cuts off the one before it anyway, so a backlog offered in order is only
    /// the last one heard with the others clipped.
    func testARelaunchOwedTwoRepliesReadsTheNewestAndClearsTheRest() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let before = harness(db, defaults: defaults,
                             transport: ScriptedTransport((200, reply("Paris.")), (200, reply("Rome."))))
        before.markSpoken(before.willSend("what is the capital of France"))
        await before.retry()
        before.markSpoken(before.willSend("and of Italy"))
        await before.retry()
        XCTAssertEqual(defaults.stringArray(forKey: "topo.harness.spoken")?.count, 2,
                       "both turns went away owed a reading")

        // The relaunch: the log read, then the handler installed.
        let after = harness(db, defaults: defaults, transport: ScriptedTransport())
        await after.refresh()
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let speaker = try await makeSpeaker(seams, audio, center)
        let said = Said()
        install(after, speaker, said)

        XCTAssertEqual(said.texts, ["Rome."], "the newest is read, and the older never reaches the speaker")
        XCTAssertEqual(speaker.report.speaks, 1)
        XCTAssertEqual(defaults.stringArray(forKey: "topo.harness.spoken"), nil, "both marks are cleared")
        XCTAssertEqual(speaker.report.text, "Rome.", "and it is the one being read, not one cut off")
    }

    /// The keeper refusing on a fresh queue is the same refusal as a rebuild that will not come
    /// back: nothing renders, so nothing is read, and the reply is still owed.
    func testAReplyWhoseHoldCannotStartIsOfferedAgainAndSpokenOnce() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let harness = harness(db, defaults: defaults,
                              transport: ScriptedTransport((200, reply("Paris."))))
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let speaker = try await makeSpeaker(seams, audio, center)
        let said = Said()
        install(harness, speaker, said)

        // The first engine this reply's hold builds will not start.
        seams.playEngineRefusals = 1
        harness.markSpoken(harness.willSend("what is the capital of France"))
        await harness.retry()
        XCTAssertEqual(said.texts, [], "nothing rendered for it, so nothing was read")
        XCTAssertEqual(speaker.report.speaks, 0)
        XCTAssertFalse(speaker.holding, "and nothing is held for a reply that was not taken")
        XCTAssertEqual(defaults.stringArray(forKey: "topo.harness.spoken")?.count, 1, "the mark stays")

        // The next pass builds an engine that starts.
        await harness.refresh()
        XCTAssertEqual(said.texts, ["Paris."])
        XCTAssertEqual(speaker.report.speaks, 1)
        await harness.refresh()
        XCTAssertEqual(said.texts, ["Paris."], "spoken once")
    }

    /// A typed turn asks for no hold: the chat never calls `awaitReply` for one, so the phone
    /// suspends behind the lock as it always did while its reply is on its way.
    func testATypedSendHoldsNothing() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let harness = harness(db, defaults: defaults,
                              transport: ScriptedTransport((200, reply("Rome."))))
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let speaker = try await makeSpeaker(seams, audio, center)
        let said = Said()
        install(harness, speaker, said)

        // Typed: nothing marks it and nothing waits for it.
        harness.willSend("and of Italy")
        XCTAssertFalse(speaker.holding, "a typed send holds nothing while its reply is pending")
        await harness.retry()
        XCTAssertEqual(said.texts, [], "a typed turn's reply stays quiet")
        XCTAssertFalse(speaker.holding)
    }

    /// The other half of the refusal: the session activates, but the queue the reply would be read
    /// on will not come back. Taking the reply there would clear its mark and end its wait for a
    /// reading that never happens, and the turn would be silent for good.
    func testAReplyWhoseQueueWillNotRebuildIsOfferedAgainAndSpokenOnce() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let harness = harness(db, defaults: defaults,
                              transport: ScriptedTransport((200, reply("Paris."))))
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let voice = Voice(engine: ScriptedVoice())
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        try await eventually("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) })

        let said = Said()
        harness.onReply = { [harness] reply in
            guard let asked = harness.spokenTurn(answeredBy: reply) else { return true }
            guard speaker.speak(reply.text, answering: asked) else { return false }
            harness.answeredAloud(asked)
            said.add(reply.text)
            return true
        }

        // The release: the wait stands and the keeper is rendering for it.
        let nonce = harness.willSend("what is the capital of France")
        XCTAssertTrue(speaker.awaitReply(nonce, readAloud: true).held)
        harness.markSpoken(nonce)

        // An interruption leaves the queue dead, and the engine the reply's rebuild would be read
        // on will not start.
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        try await eventually("the engine to be marked dead") { !speaker.keeping }
        seams.playEngineRefusals = 1

        await harness.retry()
        XCTAssertEqual(said.texts, [], "the queue would not come back, so the reply was not taken")
        XCTAssertEqual(speaker.report.speaks, 0)
        XCTAssertTrue(speaker.holding, "the wait for that turn stands")
        XCTAssertEqual(defaults.stringArray(forKey: "topo.harness.spoken"), [nonce],
                       "and its mark stays, so the reply is still owed")

        // The next pass, with an engine that starts: the same reply, read once.
        await harness.refresh()
        XCTAssertEqual(said.texts, ["Paris."])
        XCTAssertEqual(speaker.report.speaks, 1)
        await harness.refresh()
        XCTAssertEqual(said.texts, ["Paris."], "spoken once")
    }

    /// A reply the speaker could not take — a call still holding the session at the moment it
    /// landed — is not done with: the turn stays marked spoken, the reply is offered again on the
    /// next pass, and when the session comes back it is read once and the mark cleared once.
    func testAReplyTheSpeakerRefusedIsOfferedAgainAndSpokenOnce() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let harness = harness(db, defaults: defaults,
                              transport: ScriptedTransport((200, reply("Paris."))))
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = Voice(engine: ScriptedVoice())
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        try await eventually("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) })

        // What the chat installs: only a reply the speaker took is done with.
        let said = Said()
        harness.onReply = { [harness] reply in
            guard let asked = harness.spokenTurn(answeredBy: reply) else { return true }
            guard speaker.speak(reply.text, answering: asked) else { return false }
            harness.answeredAloud(asked)
            said.add(reply.text)
            return true
        }

        // The session will not activate while the reply lands.
        seams.activationError = Seams.Refused()
        harness.markSpoken(harness.willSend("what is the capital of France"))
        await harness.retry()
        XCTAssertEqual(said.texts, [], "the speaker refused it")
        XCTAssertEqual(speaker.report.speaks, 0)

        // The call ends, and the next pass offers the same reply again.
        seams.activationError = nil
        await harness.refresh()
        XCTAssertEqual(said.texts, ["Paris."], "read when the session came back")
        XCTAssertEqual(speaker.report.speaks, 1)

        // And it is done with now: neither offered nor spoken again.
        await harness.refresh()
        XCTAssertEqual(said.texts, ["Paris."])
        XCTAssertEqual(speaker.report.speaks, 1, "spoken once")
        speaker.stop()
    }

    /// What the chat installs there, end to end: a reply continuing from a turn the microphone
    /// sent is spoken, and one continuing from a typed turn is not.
    func testOnlyTheReplyToASpokenTurnIsSpokenFromTheReplyHandler() async throws {
        let db = InMemoryRecordDatabase()
        let transport = ScriptedTransport((200, reply("Paris.")), (200, reply("Rome.")))
        let harness = harness(db, defaults: makeDefaults(), transport: transport)
        let said = Said()
        harness.onReply = { [harness] reply in
            guard let asked = harness.spokenTurn(answeredBy: reply) else { return true }
            harness.answeredAloud(asked)
            said.add(reply.text)
            return true
        }

        // Spoken: the press said so when it put the words on the line.
        harness.markSpoken(harness.willSend("what is the capital of France"))
        await harness.retry()
        XCTAssertEqual(said.texts, ["Paris."])

        // Typed: nothing said so, so nothing is read aloud.
        await harness.send("and of Italy")
        XCTAssertEqual(said.texts, ["Paris."], "a typed turn's reply stays quiet")
    }

}

/// A speaker over the seams, with a voice that is ready.
@MainActor
private func makeSpeaker(_ seams: Seams, _ audio: AudioSession, _ center: NotificationCenter) async throws -> Speaker {
    let voice = Voice(engine: ScriptedVoice())
    voice.load(base: URL(fileURLWithPath: "/dev/null"))
    try await eventually("the voice to load") { voice.state == .ready }
    return Speaker(audio: audio, voice: voice, center: center,
                   makeEngine: { seams.makePlayEngine(rate: Voice.rate) })
}

// MARK: - Doubles

/// What the reply handler was given, in order.
@MainActor
private final class Said {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}

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
/// acknowledgement looks like from the writer's side; and able to refuse every read, which is
/// what a device that cannot reach CloudKit sees when it asks whether a turn is there.
private actor FailingDatabase: RecordDatabase {
    let wrapped: InMemoryRecordDatabase
    private var loseNextTurnAcknowledgement = false
    private var refusingReads = false
    private var darkAfterLostAcknowledgement = false

    init(_ wrapped: InMemoryRecordDatabase) { self.wrapped = wrapped }

    func loseAcknowledgementOfNextTurn() { loseNextTurnAcknowledgement = true }
    func refuseReads(_ on: Bool) { refusingReads = on }
    /// The device that went off the network in the middle of the write: the turn is committed,
    /// the acknowledgement is lost, and nothing after it can read the log to find out.
    func goDarkAfterTheNextTurn() {
        loseNextTurnAcknowledgement = true
        darkAfterLostAcknowledgement = true
    }

    func save(_ records: [Record]) async throws -> [Record] {
        let saved = try await wrapped.save(records)
        if loseNextTurnAcknowledgement, records.contains(where: { $0.type == Turn.recordType }) {
            loseNextTurnAcknowledgement = false
            refusingReads = darkAfterLostAcknowledgement
            throw RecordDatabaseError.unavailable(underlying: Unexpected())
        }
        return saved
    }

    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        try refuse()
        return try await wrapped.fetch(ids)
    }
    func query(_ query: RecordQuery) async throws -> [Record] {
        try refuse()
        return try await wrapped.query(query)
    }
    func records(ofType type: String) async throws -> [Record] {
        try refuse()
        return try await wrapped.records(ofType: type)
    }

    private func refuse() throws {
        guard refusingReads else { return }
        throw RecordDatabaseError.unavailable(underlying: Unexpected())
    }
}

/// What the test asks the harness in the middle of a turn, from wherever that turn is.
@MainActor private final class Probe {
    private var question: (() -> Bool)?
    func set(_ question: @escaping () -> Bool) { self.question = question }
    /// True where no question was asked, so a probe that never ran fails the test rather than
    /// passing it.
    func ask() -> Bool { question?() ?? true }
}

/// One answer, written where the test can read it after.
private actor Answers {
    private(set) var value: Bool?
    func set(_ answer: Bool) { value = answer }
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

/// Every scenario of `HarnessIntegrationTests` again, with the guest as the brain: a `GuestBridge`
/// over a `ScriptedGuest` answering from the same scripted transport, its ledger and its home kept
/// per device and across that device's relaunches. What the log holds, what the harness shows, and
/// what was asked hold as they do with the Messages API; where the guest is told something other
/// than the Messages API's history (it keeps its own conversation) or says a failure in its own
/// words, the test is overridden below with the guest's expectation and says why.
@MainActor
final class HarnessGuestIntegrationTests: HarnessIntegrationTests {
    private var homes: [String: URL] = [:]

    fileprivate override func brain(_ transport: ScriptedTransport, device: DeviceID, defaults: UserDefaults) -> any Brain {
        let key = "\(ObjectIdentifier(defaults).hashValue)/\(device.rawValue)"
        let directory: URL
        if let known = homes[key] {
            directory = known
        } else {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("guest-\(UUID().uuidString)")
            homes[key] = directory
            addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        }
        let guest = ScriptedGuest(home: directory.appendingPathComponent("home"), transport: transport)
        return GuestBridge(conversation: guest, ledger: directory.appendingPathComponent("ledger.json"))
    }

    /// A failure before the guest received the turn, in the bridge's words: the scripted guest's
    /// process ends with the API's message as its stderr.
    fileprivate override func failureShown(_ message: String) -> String {
        GuestBridgeError.failed("the process ended mid-turn: \(message)").description
    }

    /// The guest keeps its own conversation, so a session that has seen none of the log is sent
    /// one input: the log so far, then the words.
    fileprivate override func asked(unseen: [(TurnRole, String)], saying words: String) -> [String] {
        let turns = unseen.enumerated().map { index, turn in
            Turn(ref: TurnRef(device: DeviceID("any"), sequence: Int64(index + 1)), parents: [], role: turn.0,
                 text: turn.1, at: Date())
        }
        let person = Turn(ref: TurnRef(device: DeviceID("any"), sequence: 99), parents: [], role: .person, text: words, at: Date())
        return [GuestBridge.render(unseen: turns, answering: [person], fresh: true)]
    }
}
