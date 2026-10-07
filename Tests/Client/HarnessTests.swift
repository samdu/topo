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
            let line = Harness.limbInfo(outcome)
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
/// real `Harness` over the in-memory log, with the guest as the brain — a `GuestBridge` over a
/// `ScriptedGuest` answering from a scripted transport, its ledger and its home kept per device and
/// across that device's relaunches — and holds what landed in the log, what the harness shows, and
/// what the guest was told.
@MainActor
final class HarnessIntegrationTests: XCTestCase {
    fileprivate let phone = DeviceID("phone")
    private var homes: [String: URL] = [:]

    /// The brain a harness in these scenarios answers with, over the scenario's scripted answers.
    /// `defaults` and `device` say which device, and which launch of it, the harness is.
    fileprivate func brain(_ transport: ScriptedTransport, device: DeviceID, defaults: UserDefaults) -> any Brain {
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

    /// The line the chat shows when the model failed with `message` before the guest received the
    /// turn, in the bridge's words: the scripted guest's process ends with it as its stderr.
    fileprivate func failureShown(_ message: String) -> String {
        GuestBridgeError.failed("the process ended mid-turn: \(message)").description
    }

    fileprivate func makeDefaults() -> UserDefaults {
        let name = "topo.tests.harness.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    fileprivate func harness(_ database: any RecordDatabase, device: DeviceID? = nil, defaults: UserDefaults,
                             transport: ScriptedTransport,
                             ensureZone: @escaping @Sendable () async throws -> Void = {},
                             pause: @escaping @Sendable (Duration) async throws -> Void = { _ in throw CancellationError() },
                             now: @escaping @Sendable () -> TimeInterval = PrimaryLease.continuousUptime) -> Harness {
        Harness(database: database, tokens: FixedToken(), device: device ?? phone, ensureZone: ensureZone,
                defaults: defaults, brain: brain(transport, device: device ?? phone, defaults: defaults),
                leaseSleep: parked, pause: pause, now: now)
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

    /// A read that threw is not a read: with no connection on a launch over a log that holds
    /// turns, `hasRead` stays false and the transcript empty, so Topo is not placed into a page
    /// about to fill; the first read that gets through marks it and brings the turns.
    func testAFailedFirstReadIsNotARead() async throws {
        let db = InMemoryRecordDatabase()
        try await limb(db, "Anything from Helen?")
        let flaky = ReadFailingDatabase(db)
        await flaky.setFailing(true)
        let harness = harness(flaky, defaults: makeDefaults(), transport: ScriptedTransport())
        let first = await harness.refresh()
        XCTAssertFalse(first)
        XCTAssertFalse(harness.hasRead, "a read that threw was taken for the log")
        XCTAssertTrue(harness.turns.isEmpty)
        // The bar's notice, in the log's own words: the two lines `ChatNotices` holds them to.
        XCTAssertEqual(harness.error, "iCloud is out of reach. Topo will try again.")
        await harness.refresh()
        XCTAssertFalse(harness.hasRead, "a second failure marked it")
        await flaky.setFailing(false)
        let read = await harness.refresh()
        XCTAssertTrue(read)
        XCTAssertTrue(harness.hasRead)
        XCTAssertEqual(harness.turns.map(\.text), ["Anything from Helen?"])
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

    /// A nonce minted elsewhere (a widget's cue) goes on the line once: again while it is
    /// outstanding is nothing, and again once its turn is in the log is nothing.
    func testWillSendWithNonceDeduplicates() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport((200, reply("Out tonight."))))
        await harness.refresh()
        XCTAssertTrue(harness.willSend("widget bins: tapped done", nonce: "N1"))
        XCTAssertTrue(harness.willSend("widget bins: tapped done", nonce: "N1"))
        XCTAssertEqual(harness.owed.map(\.nonce), ["N1"], "outstanding: a second entry for one nonce")
        await harness.retry()
        XCTAssertTrue(harness.said("N1"))
        XCTAssertTrue(harness.willSend("widget bins: tapped done", nonce: "N1"))
        XCTAssertEqual(harness.owed.count, 0, "landed: the nonce went on the line again")
        await harness.retry()
        let people = try await log(db).filter { $0.role == .person }
        XCTAssertEqual(people.map(\.nonce), ["N1"])
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

    // MARK: A turn open

    /// A turn is open from its first step, while iCloud is still being reached and the guest has
    /// been told nothing, through the wait on the model with no word from it, until the reply is
    /// in the log; Topo, following the harness, is at work for all of it and idle once it is
    /// over. Nothing is drawn here: he hears of the turn from the harness itself.
    func testATurnIsOpenFromItsFirstStepUntilItsReplyAndTopoIsNotIdleMeanwhile() async throws {
        let db = InMemoryRecordDatabase()
        let seen = Seen()
        let mascot = Mascot(model: "claude-haiku-4-5")
        let reaching = Answers(), posedReaching = Answers(), asking = Answers(), posedAsking = Answers()
        let pose: @Sendable () async -> Bool = {
            // The change reaches him a hop behind the harness.
            for _ in 0..<200 {
                if await MainActor.run(body: { mascot.state.input.activity == "thinking" }) { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }
        let transport = ScriptedTransport((200, reply("Tonight.")))
        transport.duringRequest = {
            // The model has the turn and has said nothing.
            await asking.set(await MainActor.run { seen.harness?.turnOpen ?? false })
            await posedAsking.set(await pose())
        }
        let harness = harness(db, defaults: makeDefaults(), transport: transport, ensureZone: {
            await reaching.set(await MainActor.run { seen.harness?.turnOpen ?? false })
            await posedReaching.set(await pose())
        })
        seen.harness = harness
        mascot.follow(harness)
        XCTAssertFalse(harness.turnOpen)
        XCTAssertEqual(mascot.state.input.activity, "idle")

        await harness.send("When are the bins?")

        let (wasReaching, wasAsking) = await (reaching.value, asking.value)
        let (topoReaching, topoAsking) = await (posedReaching.value, posedAsking.value)
        XCTAssertEqual(wasReaching, true, "no turn was open while iCloud was being reached")
        XCTAssertEqual(topoReaching, true, "Topo was idle while iCloud was being reached")
        XCTAssertEqual(wasAsking, true, "no turn was open while the model had it")
        XCTAssertEqual(topoAsking, true, "Topo was idle with the turn waiting on the model")
        XCTAssertFalse(harness.turnOpen, "the turn stayed open after its reply")
        try await eventually("Topo idle after the reply") { mascot.state.input.activity == "idle" }
    }

    /// A second turn, sent over the runner the first one made, is open before any of its steps
    /// has said where it is: here while a debug launch holds the reply, which is before the
    /// runner is asked anything.
    func testALaterTurnIsOpenBeforeItsFirstStep() async throws {
        let db = InMemoryRecordDatabase()
        let transport = ScriptedTransport((200, reply("One.")), (200, reply("Two.")))
        let harness = harness(db, defaults: makeDefaults(), transport: transport)
        let mascot = Mascot(model: "claude-haiku-4-5")
        mascot.follow(harness)
        await harness.send("one")
        XCTAssertFalse(harness.turnOpen)

        setenv(DebugRun.replyDelayVariable, "0.5", 1)
        defer { unsetenv(DebugRun.replyDelayVariable) }
        let second = Task { await harness.send("two") }
        try await eventually("the second turn open with no step taken") { harness.turnOpen && harness.status == nil }
        XCTAssertEqual(transport.sent.count, 1, "the model already had the second turn")
        try await eventually("Topo at work for it") { mascot.state.input.activity == "thinking" }
        await second.value
        XCTAssertFalse(harness.turnOpen)
        let turns = try await log(db).map(\.text)
        XCTAssertEqual(turns, ["one", "One.", "two", "Two."])
    }

    /// A turn whose reply failed is closed as the failure is put up, before the reads that
    /// follow it: no turn is open while the chat is told the turn failed.
    func testATurnWhoseReplyFailedIsClosedBeforeTheReadsThatFollow() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport((500, "{}")))
        var openWhenFailed: Bool?
        harness.onTurnFailed = { [weak harness] _ in openWhenFailed = harness?.turnOpen }
        await harness.send("When are the bins?")
        XCTAssertNotNil(harness.error)
        XCTAssertEqual(openWhenFailed, false, "the turn was still open as its failure was told")
        XCTAssertFalse(harness.turnOpen)
    }

    /// A turn that never reached the log is not open either: the line has stopped, and nothing
    /// is waiting on a model.
    func testATurnThatFailedIsNotOpen() async throws {
        let db = InMemoryRecordDatabase()
        let harness = harness(db, defaults: makeDefaults(), transport: ScriptedTransport((200, reply("never"))),
                              ensureZone: { throw Unexpected() })
        var openWhenFailed: Bool?
        harness.onTurnFailed = { [weak harness] _ in openWhenFailed = harness?.turnOpen }
        await harness.send("When are the bins?")
        XCTAssertNotNil(harness.error)
        XCTAssertTrue(harness.hasWaiting)
        XCTAssertEqual(openWhenFailed, false)
        XCTAssertFalse(harness.turnOpen)
    }

    /// A sign-out during a turn closes it.
    func testASignOutClosesAnOpenTurn() async throws {
        let db = InMemoryRecordDatabase()
        let seen = Seen()
        let transport = ScriptedTransport((200, reply("never")))
        transport.duringRequest = { await seen.harness?.forget() }
        let harness = harness(db, defaults: makeDefaults(), transport: transport)
        seen.harness = harness
        let mascot = Mascot(model: "claude-haiku-4-5")
        mascot.follow(harness)
        await harness.send("When are the bins?")
        XCTAssertFalse(harness.turnOpen)
        try await eventually("Topo idle after the sign-out") { mascot.state.input.activity == "idle" }
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
        XCTAssertTrue(info.hasPrefix("Saved. hub will answer"), info)
        XCTAssertEqual(ChatNotices.Said(phone).notice, .info(info), "the harness's info is not the bar's notice")

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
        // The hub's guest has seen none of the log, so it is sent one input: the log so far, oldest
        // first, then the words. Written out rather than rendered, so the order is held here.
        XCTAssertEqual(hubTransport.sent, [[
            "[The conversation so far, from the log on their devices — the last 2 turns, oldest first:]\n\n"
                + "Them: one\n\nYou, answering on another device: one back\n\n[They now say:]\n\ntwo",
        ]])
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

    func testAReplyIsSavedWhenTheLeasesHeartbeatsRanLateAndNoOtherDeviceClaimed() async throws {
        let db = InMemoryRecordDatabase()
        let clock = TestClock()
        let transport = ScriptedTransport((200, reply("a long answer")))
        // The answer outlasts the lease and no heartbeat lands: the only primary, late.
        transport.duringRequest = { clock.advance(34) }
        let phone = harness(db, defaults: makeDefaults(), transport: transport)
        phone.adopt(PrimaryLease(database: db, device: self.phone, endpoint: nil, probe: NoSocketProbe(),
                                 now: { clock.wall }, monotonic: clock.now, sleep: parked))

        await phone.send("hello")

        let read = try await log(db).map(\.text)
        XCTAssertEqual(read, ["hello", "a long answer"], "the reply is saved under a fresh claim")
        XCTAssertNil(phone.error)
        XCTAssertEqual(phone.turns.map(\.text), ["hello", "a long answer"])
        XCTAssertEqual(transport.sent, [["hello"]])
    }

    func testADisplacedReplyIsWrittenByTheNextPassWithoutAskingAgainOnceTheTakerIsGone() async throws {
        let db = InMemoryRecordDatabase()
        let clock = TestClock()
        let hubLease = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                                    now: { clock.wall }, monotonic: clock.now, sleep: parked)
        let transport = ScriptedTransport((200, reply("the guest's answer")))
        transport.duringRequest = { _ = try? await hubLease.acquire() }
        let phone = harness(db, defaults: makeDefaults(), transport: transport)
        phone.adopt(PrimaryLease(database: db, device: self.phone, endpoint: nil, probe: NoSocketProbe(),
                                 now: { clock.wall }, monotonic: clock.now, sleep: parked))

        await phone.send("hello")
        let displaced = try await log(db).map(\.text)
        XCTAssertEqual(displaced, ["hello"])
        XCTAssertEqual(phone.error, Harness.describe(TurnRunnerError.displaced))

        // The taker never answers and its lease lapses: the phone's next pass claims, and writes
        // the reply its guest already finished rather than asking for another.
        clock.advance(11)
        await phone.answerPending()

        let read = try await log(db).map(\.text)
        XCTAssertEqual(read, ["hello", "the guest's answer"])
        XCTAssertEqual(phone.turns.map(\.text), ["hello", "the guest's answer"])
        XCTAssertEqual(transport.sent, [["hello"]], "the guest is not asked a second time")
        XCTAssertNil(phone.error)
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

    // MARK: The line that stopped, sent again by the loop

    /// The phone on 2026-09-26: a typed turn stops the line because iCloud is out of reach —
    /// reads refused, so the writer cannot be made and the transcript cannot be read — and the
    /// chat says Topo will try again. For ten passes the log cannot be read, and a pass that
    /// cannot read makes no attempt and counts for nothing. The first pass whose read gets
    /// through sends the line, under the nonce it was first said with, with nobody pressing
    /// anything and no relaunch, and the read failure it was showing goes.
    func testTheLoopSendsAStoppedLineOnTheFirstPassThatCanRead() async throws {
        let memory = InMemoryRecordDatabase()
        let db = FailingDatabase(memory)
        await db.refuseReads(true)
        let beats = Beats()
        let clock = TestClock()
        let attempts = Attempts()
        let seen = Seen()
        let phone = harness(db, defaults: makeDefaults(), transport: ScriptedTransport((200, reply("Done."))),
                            ensureZone: { await attempts.noteIfSending(seen, pass: await beats.passes + 1) },
                            pause: { try await beats.pause($0) }, now: clock.now)
        seen.harness = phone
        await phone.send("water the plants")
        XCTAssertEqual(phone.waiting, ["water the plants"], "the turn went while iCloud was out of reach")
        XCTAssertTrue(phone.hasWaiting)
        let nonce = try XCTUnwrap(phone.owed.first?.nonce)
        await attempts.reset()

        let open = Task { await phone.answering(every: .seconds(5)) }
        for pass in 1...10 {
            try await eventually("pass \(pass)") { await beats.passes >= pass }
            if pass < 10 {
                clock.advance(5)
                await beats.tick()
            }
        }
        let whileUnread = await attempts.passes
        XCTAssertEqual(whileUnread, [], "a pass that could not read the log tried to send the line")
        XCTAssertEqual(phone.waiting, ["water the plants"])
        XCTAssertNotNil(phone.error, "the chat does not say why the turn is waiting")

        await db.refuseReads(false)
        clock.advance(5)
        await beats.tick()
        try await eventually("pass 11") { await beats.passes >= 11 }
        open.cancel()
        await open.value

        XCTAssertTrue(phone.waiting.isEmpty, "the first pass that could read did not send the line")
        let sent = await attempts.passes
        XCTAssertEqual(sent, [11])
        let turns = try await log(memory)
        XCTAssertEqual(turns.map(\.text), ["water the plants", "Done."], "the loop did not send the stopped line")
        XCTAssertEqual(turns.first?.nonce, nonce, "the retry said the words under a second nonce")
        XCTAssertNil(phone.error, "the chat still says the read failed")
    }

    /// The log can be read, the zone cannot be reached, and the loop keeps trying and backs off
    /// in time as it fails: at five seconds a pass, the first attempt on the first pass, then one,
    /// two, four and eight intervals after each failure, then twelve for good. An attempt is the
    /// line being sent (the harness busy), counted by the pass it ran in; the answering pass's
    /// own reach for the zone is not one.
    func testTheLoopBacksOffWhileTheLineKeepsFailing() async throws {
        let db = InMemoryRecordDatabase()
        let beats = Beats()
        let clock = TestClock()
        let attempts = Attempts()
        let seen = Seen()
        let phone = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(),
                            ensureZone: {
                                await attempts.noteIfSending(seen, pass: await beats.passes + 1)
                                throw RecordDatabaseError.unavailable(underlying: Unexpected())
                            },
                            pause: { try await beats.pause($0) }, now: clock.now)
        seen.harness = phone
        await phone.send("water the plants")
        await attempts.reset()

        let open = Task { await phone.answering(every: .seconds(5)) }
        for pass in 1...41 {
            try await eventually("pass \(pass)") { await beats.passes >= pass }
            clock.advance(5)
            await beats.tick()
        }
        open.cancel()
        await open.value

        let passes = await attempts.passes
        XCTAssertEqual(passes, [1, 2, 4, 8, 16, 28, 40], "the loop's attempts are not backing off as they fail")
        XCTAssertEqual(phone.waiting, ["water the plants"])
    }

    /// A push wakes the loop for a pass now, and pushes can come thick and fast. The backoff is
    /// time from the failed attempt, so twelve wakes with no time passing send the line not once
    /// more; the first wake after the interval has passed sends it.
    func testWakesDoNotBringTheNextAttemptForward() async throws {
        let db = InMemoryRecordDatabase()
        let beats = Beats()
        let clock = TestClock()
        let attempts = Attempts()
        let seen = Seen()
        let phone = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(),
                            ensureZone: {
                                await attempts.noteIfSending(seen, pass: await beats.passes + 1)
                                throw RecordDatabaseError.unavailable(underlying: Unexpected())
                            },
                            pause: { try await beats.pause($0) }, now: clock.now)
        seen.harness = phone
        await phone.send("water the plants")
        await attempts.reset()

        let open = Task { await phone.answering(every: .seconds(5)) }
        try await eventually("the first pass") { await beats.passes >= 1 }
        let first = await attempts.passes.count
        XCTAssertEqual(first, 1, "the first pass did not send the stopped line")

        for _ in 1...12 { await phone.wake() }
        let afterWakes = await attempts.passes.count
        XCTAssertEqual(afterWakes, 1, "twelve wakes in no time sent the line \(afterWakes - 1) more times")

        clock.advance(5)
        await phone.wake()
        let afterInterval = await attempts.passes.count
        XCTAssertEqual(afterInterval, 2, "the wake after the interval did not send the line")
        open.cancel()
        await open.value
    }

    /// The backoff is elapsed time, not what the phone's clock says. After the first failure and
    /// then a second, the line waits ten seconds; the person setting the clock a minute ahead and
    /// a push waking the loop does not send it early, and setting it an hour back does not hold it
    /// past the ten seconds that actually pass.
    func testSettingThePhonesClockDoesNotMoveTheNextAttempt() async throws {
        let db = InMemoryRecordDatabase()
        let beats = Beats()
        let clock = TestClock()
        let attempts = Attempts()
        let seen = Seen()
        let phone = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(),
                            ensureZone: {
                                await attempts.noteIfSending(seen, pass: await beats.passes + 1)
                                throw RecordDatabaseError.unavailable(underlying: Unexpected())
                            },
                            pause: { try await beats.pause($0) }, now: clock.now)
        seen.harness = phone
        await phone.send("water the plants")
        await attempts.reset()

        let open = Task { await phone.answering(every: .seconds(5)) }
        try await eventually("the first pass") { await beats.passes >= 1 }
        clock.advance(5)
        await phone.wake()
        let second = await attempts.passes.count
        XCTAssertEqual(second, 2, "the attempt one interval after the first failure did not go")

        // The next attempt is due ten seconds from now.
        let before = clock.wall
        clock.setWall(by: 60)
        XCTAssertEqual(clock.wall.timeIntervalSince(before), 60)
        await phone.wake()
        let afterForward = await attempts.passes.count
        XCTAssertEqual(afterForward, 2, "setting the clock a minute ahead sent the line early")

        clock.setWall(by: -3_600)
        clock.advance(5)
        await phone.wake()
        let halfway = await attempts.passes.count
        XCTAssertEqual(halfway, 2, "the line went five seconds into a ten-second wait")
        clock.advance(5)
        await phone.wake()
        let due = await attempts.passes.count
        XCTAssertEqual(due, 3, "setting the clock an hour back held the line past the ten seconds that passed")
        open.cancel()
        await open.value
    }

    /// Sign-out starts the backoff again: a line that has failed long enough to wait most of a
    /// minute is gone with the login, and a turn said after it is sent on the next pass that can
    /// read, with no time passing, rather than when the last login's backoff said.
    func testSignOutStartsTheBackoffAgain() async throws {
        let db = InMemoryRecordDatabase()
        let beats = Beats()
        let clock = TestClock()
        let attempts = Attempts()
        let seen = Seen()
        let phone = harness(db, defaults: makeDefaults(), transport: ScriptedTransport(),
                            ensureZone: {
                                await attempts.noteIfSending(seen, pass: await beats.passes + 1)
                                throw RecordDatabaseError.unavailable(underlying: Unexpected())
                            },
                            pause: { try await beats.pause($0) }, now: clock.now)
        seen.harness = phone
        await phone.send("water the plants")
        await attempts.reset()

        let first = Task { await phone.answering(every: .seconds(5)) }
        for pass in 1...3 {
            try await eventually("pass \(pass)") { await beats.passes >= pass }
            clock.advance(5)
            await beats.tick()
        }
        try await eventually("pass 4") { await beats.passes >= 4 }
        // Attempts on passes 1, 2 and 4 have failed, the last at 15 s: the next is due at 35 s.
        let before = await attempts.passes
        XCTAssertEqual(before, [1, 2, 4])

        await phone.forget()
        await first.value
        XCTAssertTrue(phone.waiting.isEmpty, "the line outlived the sign-out")

        phone.willSend("and the ferns")
        await attempts.reset()
        let second = Task { await phone.answering(every: .seconds(5)) }
        try await eventually("the first pass after sign-in") { await beats.passes >= 5 }
        let after = await attempts.passes
        XCTAssertEqual(after, [5], "the turn after sign-out waited out the last login's backoff")
        second.cancel()
        await second.value
    }

    /// A success clears the backoff: after a run of failures, a line that went and a new turn
    /// that stops it again is sent on the very next pass, not when the old backoff said.
    func testALineThatWentStartsItsBackoffAgain() async throws {
        let memory = InMemoryRecordDatabase()
        let db = FailingDatabase(memory)
        let zone = Switch()
        await zone.set(false)
        let beats = Beats()
        let clock = TestClock()
        let phone = harness(db, defaults: makeDefaults(),
                            transport: ScriptedTransport((200, reply("Done.")), (200, reply("Also done."))),
                            ensureZone: {
                                guard await zone.isOn else { throw RecordDatabaseError.unavailable(underlying: Unexpected()) }
                            },
                            pause: { try await beats.pause($0) }, now: clock.now)
        await phone.send("water the plants")

        let open = Task { await phone.answering(every: .seconds(5)) }
        for pass in 1...7 {
            try await eventually("pass \(pass)") { await beats.passes >= pass }
            clock.advance(5)
            await beats.tick()
        }
        try await eventually("pass 8") { await beats.passes >= 8 }
        // The loop is paused after pass 8, at 35 s. Its attempts on passes 1, 2, 4 and 8 have
        // failed; its next would be no sooner than 75 s, pass 16.
        await zone.set(true)
        await phone.retry()
        XCTAssertTrue(phone.waiting.isEmpty, "the button's retry did not send the line")

        await db.refuseReads(true)
        await phone.send("and the ferns")
        XCTAssertEqual(phone.waiting, ["and the ferns"])
        await db.refuseReads(false)
        clock.advance(5)
        await beats.tick()
        try await eventually("pass 9") { await beats.passes >= 9 }
        XCTAssertTrue(phone.waiting.isEmpty, "the backoff from before the line went was carried over")
        open.cancel()
        await open.value

        let turns = try await log(memory).filter { $0.role == .person }.map(\.text)
        XCTAssertEqual(turns, ["water the plants", "and the ferns"])
    }

    /// A failed read's notice is about the last read, so the next read that gets through takes it
    /// down, with nothing on the line to send.
    func testAReadThatGetsThroughClearsTheReadFailure() async throws {
        let db = FailingDatabase(InMemoryRecordDatabase())
        let phone = harness(db, defaults: makeDefaults(), transport: ScriptedTransport())
        await db.refuseReads(true)
        await phone.refresh()
        XCTAssertEqual(phone.error, "iCloud is out of reach. Topo will try again.")
        await db.refuseReads(false)
        await phone.refresh()
        XCTAssertNil(phone.error, "a read got through and the chat still says it did not")
    }

    /// A read that gets through takes down the read's failure and no other, however alike their
    /// words: a turn that could not be written says "iCloud is out of reach" in the same words a
    /// failed read did, and it stands, with the turn still on the line, until the turn goes.
    func testAReadThatGetsThroughLeavesATurnsFailureInTheSameWords() async throws {
        let db = FailingDatabase(InMemoryRecordDatabase())
        let phone = harness(db, defaults: makeDefaults(), transport: ScriptedTransport())
        await db.refuseReads(true)
        await phone.refresh()
        XCTAssertEqual(phone.failure, Harness.Failure(words: "iCloud is out of reach. Topo will try again.", source: .read))
        await db.refuseReads(false)
        await db.refuseWrites(true)
        await phone.send("water the plants")
        XCTAssertEqual(phone.waiting, ["water the plants"], "the turn was not written, so it is still owed")
        XCTAssertEqual(phone.failure, Harness.Failure(words: "iCloud is out of reach. Topo will try again.", source: .other),
                       "the turn's failure is not the read's")
        let read = await phone.refresh()
        XCTAssertTrue(read)
        XCTAssertEqual(phone.error, "iCloud is out of reach. Topo will try again.",
                       "a read that got through took down the failure of a turn it was not about")
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

    /// Replies muted at the release: the turn is not one whose reply is read, so nothing
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

    /// Muted between the release and the reply, the reply is read by nobody, and nothing is left
    /// standing for it: the turn's mark is cleared and its wait ended, so a muted phone is not kept
    /// awake for a reply it will not read and the reply is not offered again.
    func testAReplyThatLandsMutedIsNotReadAndLeavesNoMarkAndNoWait() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let harness = harness(db, defaults: defaults,
                              transport: ScriptedTransport((200, reply("Paris."))))
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let speaker = try await makeSpeaker(seams, audio, center)
        defer { speaker.stop() }
        // Wired as the chat wires them, and muted after the release.
        var readsAloud = true
        SpokenReply.wire(harness: harness, speaker: speaker) { readsAloud }

        let nonce = harness.willSend("what is the capital of France")
        XCTAssertTrue(speaker.awaitReply(nonce, readAloud: readsAloud).spoken)
        harness.markSpoken(nonce)
        XCTAssertEqual(speaker.awaiting, [nonce])
        readsAloud = false

        await harness.retry()
        XCTAssertEqual(speaker.report.speaks, 0, "a muted reply was read")
        XCTAssertFalse(speaker.speaking)
        XCTAssertEqual(speaker.awaiting, [], "the wait outlived the reply nobody will hear")
        XCTAssertEqual(defaults.stringArray(forKey: "topo.harness.spoken"), nil, "the mark outlived it too")
    }

    /// What the look calls a model is what the notice says is being asked: the mind renames Opus,
    /// and the turn in flight says the new name.
    func testTheAskingNoticeSaysTheLooksNameForTheModel() async throws {
        let transport = ScriptedTransport((200, reply("Paris.")))
        let harness = harness(InMemoryRecordDatabase(), defaults: makeDefaults(), transport: transport)
        harness.model = .opus
        var mind = Look.Mind()
        mind.opus = "Opus 5.5"
        harness.mind = mind
        let seen = Said()
        transport.duringRequest = { await MainActor.run { seen.add(harness.status ?? "") } }
        await harness.send("what is the capital of France")
        XCTAssertEqual(seen.texts, ["Asking Opus 5.5…"])
        XCTAssertEqual(harness.name(of: .sonnet), "Sonnet", "a name the look did not set changed")
    }

    /// Muted, what the guest writes of a spoken turn's reply is not read as it comes; with the
    /// mute lifted while it is still being written, it is read from its first sentence, since
    /// nothing of it has been.
    func testAMutedReplyIsNotReadAsItIsWrittenAndIsOnceTheMuteIsLifted() async throws {
        let harness = harness(InMemoryRecordDatabase(), defaults: makeDefaults(),
                              transport: ScriptedTransport((200, reply("Paris."))))
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let speaker = try await makeSpeaker(seams, audio, center)
        defer { speaker.stop() }
        var readsAloud = false
        SpokenReply.wire(harness: harness, speaker: speaker) { readsAloud }
        let nonce = harness.willSend("what is the capital of France")
        harness.markSpoken(nonce)

        harness.onWriting?("Paris is the capital. ", nonce)
        XCTAssertFalse(speaker.speaking, "read as it was written, muted")
        XCTAssertEqual(speaker.report.speaks, 0)
        readsAloud = true
        harness.onWriting?("Paris is the capital. It is on the Seine. ", nonce)
        XCTAssertTrue(speaker.speaking, "the mute was lifted and nothing is read")
        XCTAssertEqual(speaker.report.speaks, 1)
    }

    /// A reply being read as it is written, stopped by the mute, stays stopped: what the guest
    /// writes while muted does not make the speaker forget it stopped that reply, so lifting the
    /// mute does not begin it again from the top, and when it lands it is not read either, with
    /// its mark and its wait both gone.
    func testAReplyStoppedByTheMuteIsNotBegunAgainWhenTheMuteIsLifted() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let harness = harness(db, defaults: defaults,
                              transport: ScriptedTransport((200, reply("One sentence. Two of them. Three."))))
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let speaker = try await makeSpeaker(seams, audio, center)
        defer { speaker.stop() }
        var readsAloud = true
        SpokenReply.wire(harness: harness, speaker: speaker) { readsAloud }
        let nonce = harness.willSend("count sentences")
        XCTAssertTrue(speaker.awaitReply(nonce, readAloud: readsAloud).spoken)
        harness.markSpoken(nonce)

        harness.onWriting?("One sentence. ", nonce)
        XCTAssertTrue(speaker.speaking, "the reply is not read as it is written")
        let begun = speaker.report.speaks

        // The mute, pressed: what is being read stops, and what was waited for is let go.
        readsAloud = false
        SpokenReply.muteChanged(readsAloud: false, speaker: speaker)
        XCTAssertFalse(speaker.speaking, "muting did not stop the reply being read")
        XCTAssertEqual(speaker.awaiting, [], "muting left the wait standing")
        harness.onWriting?("One sentence. Two of them. ", nonce)
        XCTAssertFalse(speaker.speaking)

        // Lifted, with the reply still being written and then landing.
        readsAloud = true
        SpokenReply.muteChanged(readsAloud: true, speaker: speaker)
        harness.onWriting?("One sentence. Two of them. Three. ", nonce)
        XCTAssertFalse(speaker.speaking, "the reply the mute stopped was begun again")
        await harness.retry()
        XCTAssertFalse(speaker.speaking, "the reply the mute stopped was read when it landed")
        XCTAssertEqual(speaker.report.speaks, begun, "it was begun again from the top")
        XCTAssertEqual(defaults.stringArray(forKey: "topo.harness.spoken"), nil, "its mark outlived it")
        XCTAssertEqual(speaker.awaiting, [])
    }

    /// A question asked aloud, with replies not muted, is that question's answer when it lands,
    /// and leaving it unread would strand its mark and its hold. What ends the hold is `speak`
    /// taking the reply, which is `testTheKeeperDoesNotStopBetweenTheWaitAndTheReply`.
    func testAReplyIsReadWhenItsTurnIsMarkedAndRepliesAreNotMuted() async throws {
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

        // The release, with replies not muted: the wait is held and the turn marked.
        let nonce = harness.willSend("what is the capital of France")
        XCTAssertTrue(speaker.awaitReply(nonce, readAloud: true).spoken)
        harness.markSpoken(nonce)

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

    /// A spoken reply that lands while the microphone is held waits for it, and its turn stays
    /// owed until it is heard: through a release whose reading the session refuses, and through
    /// the next ordinary press on the microphone, whose own release reads it at last. The chat's
    /// read-aloud (`SpokenReply`) and the speaker's `settled` are wired as the chat wires them,
    /// and the owed mark is the harness's own, on disk.
    func testAReplyRefusedWhenTheMicrophoneClosesIsReadAfterTheNextPress() async throws {
        let db = InMemoryRecordDatabase()
        let defaults = makeDefaults()
        let harness = harness(db, defaults: defaults, transport: ScriptedTransport((200, reply("Paris."))))
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let speaker = try await makeSpeaker(seams, audio, center)
        let ear = Ear(vocabulary: Vocabulary(defaults: makeDefaults()),
                      engine: ScriptedEngine(bare: "and of Italy", boosted: "and of Italy"))
        ear.load(parakeet: URL(fileURLWithPath: "/dev/null"), ctc: URL(fileURLWithPath: "/dev/null"))
        try await eventually("the ear to load") { ear.ready }
        let voice = VoiceInput(audio: audio, ear: ear, center: center, makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) }, permission: { true })
        defer { speaker.stop(); voice.cancel() }
        speaker.microphoneOpen = { voice.listening }
        harness.onReply = { SpokenReply.read($0, harness: harness, speaker: speaker) }
        speaker.settled = { harness.answeredAloud($0) }
        let press = MicPress()
        let sent = Said()
        let drawn = { Composer.MicState(voice, speaking: speaker.speaking) }
        let owed = { defaults.stringArray(forKey: "topo.harness.spoken") ?? [] }
        func hold() async throws {
            try await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
            let format = voice.sink.format
            let frames = AVAudioFrameCount(format.sampleRate)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = 0.1 * sin(Float(frame) * 0.05) }
            voice.sink.append(buffer)
        }

        // A question said aloud; its turn is marked spoken.
        let asked = harness.willSend("what is the capital of France")
        harness.markSpoken(asked)
        XCTAssertEqual(owed(), [asked])

        // The microphone is held when the reply lands: it waits, and the turn stays owed.
        await press.gesture(true, drawn: drawn(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertTrue(voice.listening)
        await harness.retry()
        XCTAssertTrue(speaker.waitingForMicrophone, "the reply did not wait for the held microphone")
        XCTAssertEqual(speaker.report.speaks, 0)
        XCTAssertEqual(owed(), [asked], "the turn was settled while its reply waited")

        // The release sends what was held; the session refuses the reading.
        seams.playEngineRefusals = 1
        try await hold()
        await press.gesture(false, drawn: drawn(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertEqual(sent.texts, ["and of Italy"])
        XCTAssertFalse(speaker.speaking)
        XCTAssertTrue(speaker.waitingForMicrophone, "the refused reply was dropped")
        XCTAssertEqual(owed(), [asked], "the turn is no longer owed a reading after the refusal")

        // The next ordinary press and release: the reply is still owed through the press, and the
        // release reads it and settles the turn.
        XCTAssertEqual(drawn().appearance, .idle)
        await press.gesture(true, drawn: drawn(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertTrue(voice.listening)
        XCTAssertTrue(speaker.waitingForMicrophone, "the press on the idle microphone dropped the unheard reply")
        XCTAssertEqual(owed(), [asked], "the press settled the turn with its reply unheard")
        try await hold()
        await press.gesture(false, drawn: drawn(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertEqual(sent.texts, ["and of Italy", "and of Italy"])
        try await eventually("the reply to be read") { speaker.report.started }
        XCTAssertEqual(speaker.report.text, "Paris.")
        XCTAssertEqual(owed(), [], "the reply was read, so the turn is owed nothing")
        XCTAssertEqual(drawn().appearance, .stop)
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

/// The in-memory database whose reads throw while told to, as CloudKit's do with no connection.
private actor ReadFailingDatabase: RecordDatabase {
    let wrapped: InMemoryRecordDatabase
    private var failing = false

    init(_ wrapped: InMemoryRecordDatabase) { self.wrapped = wrapped }

    func setFailing(_ on: Bool) { failing = on }

    private func check() throws {
        if failing { throw RecordDatabaseError.unavailable(underlying: URLError(.notConnectedToInternet)) }
    }

    func save(_ records: [Record]) async throws -> [Record] { try await wrapped.save(records) }

    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] {
        try check()
        return try await wrapped.fetch(ids)
    }

    func query(_ query: RecordQuery) async throws -> [Record] {
        try check()
        return try await wrapped.query(query)
    }

    func records(ofType type: String) async throws -> [Record] {
        try check()
        return try await wrapped.records(ofType: type)
    }
}

/// What the reply handler was given, in order.
@MainActor
private final class Said {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}

/// The far end of the scripted guest's model: answers from a queue and records what each request carried.
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
    private var refusingWrites = false
    private var darkAfterLostAcknowledgement = false

    init(_ wrapped: InMemoryRecordDatabase) { self.wrapped = wrapped }

    func loseAcknowledgementOfNextTurn() { loseNextTurnAcknowledgement = true }
    func refuseReads(_ on: Bool) { refusingReads = on }
    func refuseWrites(_ on: Bool) { refusingWrites = on }
    /// The device that went off the network in the middle of the write: the turn is committed,
    /// the acknowledgement is lost, and nothing after it can read the log to find out.
    func goDarkAfterTheNextTurn() {
        loseNextTurnAcknowledgement = true
        darkAfterLostAcknowledgement = true
    }

    func save(_ records: [Record]) async throws -> [Record] {
        if refusingWrites { throw RecordDatabaseError.unavailable(underlying: Unexpected()) }
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

/// The passes of the answering loop in which the line was sent.
private actor Attempts {
    private(set) var passes: [Int] = []
    func note(_ pass: Int) { passes.append(pass) }
    func reset() { passes = [] }
    /// Notes the pass if the harness is sending its line, which is when it is busy: the
    /// answering pass reaches for the zone too, and is not an attempt.
    func noteIfSending(_ seen: Seen, pass: Int) async {
        guard await MainActor.run(body: { seen.harness?.busy ?? false }) else { return }
        note(pass)
    }
}

/// The phone's two clocks, moved by the test: `now` is the elapsed time the harness's backoff
/// reads, and `wall` is what the phone's clock says, which the person can set anywhere. Time
/// passing moves both; setting the clock moves the wall alone.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var elapsed: TimeInterval = 1_000
    private var shown = Date(timeIntervalSince1970: 1_800_000_000)
    var now: @Sendable () -> TimeInterval { { [self] in lock.withLock { elapsed } } }
    var wall: Date { lock.withLock { shown } }
    func advance(_ seconds: TimeInterval) { lock.withLock { elapsed += seconds; shown += seconds } }
    func setWall(by seconds: TimeInterval) { lock.withLock { shown += seconds } }
}

/// The harness a closure made before it needs to ask about it.
@MainActor private final class Seen {
    weak var harness: Harness?
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
