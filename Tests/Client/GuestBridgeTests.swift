import TopoAuth
import TopoCore
import TopoCoreTesting
import TopoTurn
import TopoUserland
import XCTest

@testable import Topo

/// The bridge between the log and the guest, over the in-memory log and a guest whose session
/// transcript is a real file. Every test that plays a crash makes a new bridge from the ledger on
/// disk and a new runner, as a relaunch would, and never carries the old bridge's memory over:
/// what the new one knows is what was written down, and what the guest's own transcript says.
@MainActor
final class GuestBridgeTests: XCTestCase {
    private var directory: URL!
    private let phone = DeviceID("phone")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var home: URL { directory.appendingPathComponent("home") }
    private var ledgerFile: URL { directory.appendingPathComponent("ledger.json") }

    /// One launch of the phone: a bridge read from the ledger on disk, over a guest with this
    /// script, and a runner of its own.
    private func launch(_ database: any RecordDatabase, _ script: ScriptedGuest.Answer...,
                        device: DeviceID? = nil) async throws -> (TurnRunner, GuestBridge, ScriptedGuest) {
        let guest = ScriptedGuest(home: home, script: script)
        let bridge = GuestBridge(conversation: guest, ledger: ledgerFile)
        let device = device ?? phone
        let log = TurnLog(database: database)
        let lease = PrimaryLease(database: database, device: device, endpoint: nil, probe: NoSocketProbe(), sleep: parked)
        let runner = TurnRunner(log: log, writer: try await log.writer(for: device), lease: lease, brain: bridge)
        return (runner, bridge, guest)
    }

    private func log(_ database: any RecordDatabase) async throws -> [Turn] {
        try await TurnLog(database: database).read().ordered
    }

    /// A turn another device writes, continuing the log as it stands.
    @discardableResult
    private func write(_ database: any RecordDatabase, _ role: TurnRole, _ text: String, device: String) async throws -> Turn {
        let log = TurnLog(database: database)
        return try await log.writer(for: DeviceID(device)).append(role, text, continuing: try await log.read())
    }

    // MARK: - Reconciliation, the function

    func testReconciliationOfEachVerdict() {
        let pending = GuestLedger.Pending(input: "in", nonce: "answer/a", parents: [], answering: [], covers: Coverage(),
                                          session: "S1", sentAt: Date(), state: .sent)
        var askedAgain = pending
        askedAgain.askAgain = true
        XCTAssertEqual(Reconciliation.of(pending, verdict: .notReceived, request: "answer/a"), .clear)
        XCTAssertEqual(Reconciliation.of(pending, verdict: .notReceived, request: nil), .clear)
        XCTAssertEqual(Reconciliation.of(pending, verdict: .answered("hi"), request: "answer/a"), .answered("hi"))
        XCTAssertEqual(Reconciliation.of(pending, verdict: .answered("hi"), request: "answer/b"),
                       .owed(OwedReply(parents: [], nonce: "answer/a", text: "hi")))
        XCTAssertEqual(Reconciliation.of(pending, verdict: .answered("hi"), request: nil),
                       .owed(OwedReply(parents: [], nonce: "answer/a", text: "hi")))
        XCTAssertEqual(Reconciliation.of(pending, verdict: .unresolved, request: "answer/a"), .unresolved)
        XCTAssertEqual(Reconciliation.of(askedAgain, verdict: .unresolved, request: "answer/a"), .askAgain)
        XCTAssertEqual(Reconciliation.of(pending, verdict: .unresolved, request: "answer/b"), .superseded)
        XCTAssertEqual(Reconciliation.of(pending, verdict: .unresolved, request: nil), .hold)
    }

    func testCoverageIsASetOfRefsKeptAsRuns() throws {
        var seen = Coverage([TurnRef(device: phone, sequence: 1), TurnRef(device: phone, sequence: 2),
                             TurnRef(device: phone, sequence: 4)])
        seen.insert([TurnRef(device: DeviceID("watch"), sequence: 1), TurnRef(device: phone, sequence: 3)])
        XCTAssertEqual(seen.runs[phone.rawValue], [1...4])
        XCTAssertTrue(seen.contains(TurnRef(device: DeviceID("watch"), sequence: 1)))
        XCTAssertFalse(seen.contains(TurnRef(device: DeviceID("watch"), sequence: 2)))
        XCTAssertEqual(seen.count, 5)
        let decoded = try JSONDecoder().decode(Coverage.self, from: JSONEncoder().encode(seen))
        XCTAssertEqual(decoded, seen)
    }

    // MARK: - A turn lost or doubled

    /// The guest answered and the reply never reached the log; the app is killed. The next launch
    /// finds the reply in the guest's transcript and writes it without asking again.
    func testACrashAfterTheGuestAnsweredRecoversTheReplyWithoutAskingAgain() async throws {
        let db = RefusingReplies()
        let (first, _, firstGuest) = try await launch(db, .reply("Paris."))
        await db.refuse(true)
        do {
            _ = try await first.run("What is the capital of France?", model: .sonnet5)
            XCTFail("the reply was written")
        } catch TurnRunnerError.replyFailed {}
        XCTAssertEqual(firstGuest.inputs, ["What is the capital of France?"])
        await db.refuse(false)

        let (second, bridge, guest) = try await launch(db)
        // The reply is owed the log: the pass writes it first, and then nothing waits.
        _ = try await second.answerPending(model: .sonnet5)
        XCTAssertTrue(guest.inputs.isEmpty, "the guest was asked again")
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["What is the capital of France?", "Paris."])
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
        XCTAssertTrue(turns.allSatisfy { ledger.seen.contains($0.ref) }, "the bookkeeping did not catch up")
        let again = try await second.answerPending(model: .sonnet5)
        XCTAssertNil(again)
    }

    /// The same, found by the typed turn's own retry under its nonce: one reply, one nonce.
    func testARetryAfterAFailedAppendWritesOneReplyUnderOneNonce() async throws {
        let db = RefusingReplies()
        let (first, _, _) = try await launch(db, .reply("Calling."))
        await db.refuse(true)
        do {
            _ = try await first.run("call Helen", model: .sonnet5, nonce: "said-once")
            XCTFail("the reply was written")
        } catch TurnRunnerError.replyFailed {}
        await db.refuse(false)

        let (second, _, guest) = try await launch(db)
        let result = try await second.run("call Helen", model: .sonnet5, nonce: "said-once")
        XCTAssertEqual(result.assistant.text, "Calling.")
        XCTAssertTrue(guest.inputs.isEmpty)
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["call Helen", "Calling."])
        XCTAssertEqual(turns.last?.nonce, TurnRunner.replyNonce(for: [turns[0].ref]))
    }

    /// The input was read and the app was killed with no reply: the next launch leaves the turn
    /// unresolved and sends nothing; asking again, which the person chooses, sends it once.
    func testACrashAfterTheInputWasReadLeavesItUnresolvedAndSendsNothing() async throws {
        let db = InMemoryRecordDatabase()
        let (first, _, firstGuest) = try await launch(db, .hang)
        let killed = Task { try await first.run("delete my old drafts", model: .sonnet5) }
        try await eventually("the guest to read the input") { firstGuest.inputs.count == 1 }
        _ = killed  // the app is killed here: nothing of it runs again

        let (second, bridge, guest) = try await launch(db)
        let answered = try await second.answerPending(model: .sonnet5)
        XCTAssertNil(answered, "a turn the guest was cut off answering was answered by itself")
        XCTAssertTrue(guest.inputs.isEmpty, "an input the guest received was sent again")
        let logged1 = try await log(db)
        let person = try XCTUnwrap(logged1.first)
        let unresolved = await bridge.unresolved()
        XCTAssertEqual(unresolved, [person.ref])
        let state = await bridge.current.pending?.state
        XCTAssertEqual(state, .unresolved)
        let still = try await second.answerPending(model: .sonnet5)
        XCTAssertNil(still)
        XCTAssertTrue(guest.inputs.isEmpty)

        await bridge.askAgain()
        guest.then(.reply("Deleted three."))
        let reply = try await second.answerPending(model: .sonnet5)
        XCTAssertEqual(reply?.text, "Deleted three.")
        XCTAssertEqual(guest.inputs, ["delete my old drafts"], "asked again once, because the person asked")
        let noneLeft = await bridge.unresolved()
        XCTAssertTrue(noneLeft.isEmpty)
    }

    /// CloudKit took the reply and the app died before the bookkeeping moved. The next launch finds
    /// the reply in the log by its nonce and catches up; nothing is sent for it, and the next turn
    /// is told nothing it has already seen.
    func testACrashAfterCloudKitAcceptedTheReplyCatchesUpWithNothingSent() async throws {
        let db = RefusingReplies()
        let (first, _, _) = try await launch(db, .reply("Paris."))
        await db.loseNextReplyAcknowledgement()
        do {
            _ = try await first.run("capital of France?", model: .sonnet5)
            XCTFail("the acknowledgement arrived")
        } catch TurnRunnerError.replyFailed {}
        let logged2 = try await log(db)
        XCTAssertEqual(logged2.map(\.text), ["capital of France?", "Paris."], "the reply is in the log")

        let (second, bridge, guest) = try await launch(db, .reply("Berlin."))
        let result = try await second.run("and Germany?", model: .sonnet5)
        XCTAssertEqual(result.assistant.text, "Berlin.")
        XCTAssertEqual(guest.inputs, ["and Germany?"], "the guest was told what it had already seen")
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["capital of France?", "Paris.", "and Germany?", "Berlin."])
        XCTAssertEqual(Set(turns.map(\.nonce)).count, 4, "a reply was written twice")
        let ledger = await bridge.current
        XCTAssertTrue(turns.allSatisfy { ledger.seen.contains($0.ref) })
    }

    /// A reply the guest finished for a turn the log has moved on from (the person said more before
    /// the reply was written) is written first, under its own nonce, and never asked for again.
    func testAnOwedReplyIsWrittenBeforeTheNextTurnUnderItsOwnNonce() async throws {
        let db = RefusingReplies()
        let (first, _, _) = try await launch(db, .reply("Paris."))
        await db.refuse(true)
        let firstTurn = try? await first.run("capital of France?", model: .sonnet5)
        XCTAssertNil(firstTurn)
        await db.refuse(false)

        let (second, _, guest) = try await launch(db, .reply("Berlin."))
        _ = try await second.run("and Germany?", model: .sonnet5)
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["capital of France?", "Paris.", "and Germany?", "Berlin."])
        XCTAssertEqual(turns[1].nonce, TurnRunner.replyNonce(for: [turns[0].ref]))
        XCTAssertEqual(turns[2].parents, [turns[1].ref], "the next turn continues the owed reply")
        XCTAssertEqual(guest.inputs, ["and Germany?"])
    }

    /// The guest finished a reply whose write failed, and another device then said something and
    /// had it answered, so the log's head is a reply and no person's turn waits. The next pass
    /// still writes the owed reply, under its own nonce, without asking the guest.
    func testAnOwedReplyIsWrittenByTheAnsweringPassWhenTheHeadIsAReply() async throws {
        let db = RefusingReplies()
        let (first, _, _) = try await launch(db, .reply("Paris."))
        await db.refuse(true)
        let refused = try? await first.run("capital of France?", model: .sonnet5)
        XCTAssertNil(refused)
        await db.refuse(false)
        try await write(db, .person, "and Spain?", device: "watch")
        try await write(db, .assistant, "Madrid.", device: "hub")

        let (second, bridge, guest) = try await launch(db)
        _ = try await second.answerPending(model: .sonnet5)
        XCTAssertTrue(guest.inputs.isEmpty, "the guest was asked again")
        let turns = try await log(db)
        XCTAssertEqual(turns.filter { $0.text == "Paris." }.count, 1)
        let paris = try XCTUnwrap(turns.first { $0.text == "Paris." })
        let question = try XCTUnwrap(turns.first { $0.text == "capital of France?" })
        XCTAssertEqual(paris.parents, [question.ref])
        XCTAssertEqual(paris.nonce, TurnRunner.replyNonce(for: [question.ref]))
        let pending = await bridge.current.pending
        XCTAssertNil(pending)
        let again = try await second.answerPending(model: .sonnet5)
        XCTAssertNil(again)
        let after = try await log(db)
        XCTAssertEqual(after.count, turns.count, "a second pass wrote something")
    }

    /// Two limbs spoke at once: one reply joins both, and the guest hears both.
    func testAnsweringAForkWritesOneReply() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, _, guest) = try await launch(db, .reply("Both done."))
        let root = try await write(db, .person, "start", device: "pad")
        let watch = TurnLog(database: db)
        let fromWatch = try await watch.writer(for: DeviceID("watch")).append(.person, "buy milk", parents: [root.ref])
        let fromPad = try await watch.writer(for: DeviceID("pad")).append(.person, "buy eggs", parents: [root.ref])

        let reply = try await runner.answerPending(model: .sonnet5)
        XCTAssertEqual(Set(try XCTUnwrap(reply).parents), [fromWatch.ref, fromPad.ref])
        let again = try await runner.answerPending(model: .sonnet5)
        XCTAssertNil(again)
        let logged3 = try await log(db)
        XCTAssertEqual(logged3.filter { $0.role == .assistant }.count, 1)
        XCTAssertEqual(guest.inputs.count, 1)
        let input = try XCTUnwrap(guest.inputs.first)
        XCTAssertTrue(input.contains("buy milk") && input.contains("buy eggs"), input)
        XCTAssertTrue(input.contains("start"), input)
    }

    /// A turn cut off at the teardown (no crash) is unresolved; the person saying something new
    /// moves past it, and the guest is not told again what it already read.
    func testAnAbandonedTurnIsUnresolvedAndANewTurnMovesPastIt() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .cutOff, .reply("Fine."))
        do {
            _ = try await runner.run("run the report", model: .sonnet5)
            XCTFail("an abandoned turn was answered")
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            XCTAssertEqual(underlying as? GuestBridgeError, .unresolved)
        }
        let answered = try await runner.answerPending(model: .sonnet5)
        XCTAssertNil(answered)
        XCTAssertEqual(guest.inputs, ["run the report"])

        _ = try await runner.run("never mind", model: .sonnet5)
        XCTAssertEqual(guest.inputs, ["run the report", "never mind"])
        let unresolved = await bridge.unresolved()
        XCTAssertTrue(unresolved.isEmpty)
    }

    /// The process ended after writing its reply and before its result line: the transcript has
    /// the answer, so it is written, not asked for again.
    func testAReplyTheProcessWroteBeforeItExitedIsWritten() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, _, guest) = try await launch(db, .answeredThenExited("Tuesday."))
        let result = try await runner.run("when is it?", model: .sonnet5)
        XCTAssertEqual(result.assistant.text, "Tuesday.")
        XCTAssertEqual(guest.inputs.count, 1)
    }

    /// A failure before the guest received the input is retried by the next pass, as any failed
    /// reply is, and the bookkeeping holds nothing for it.
    func testAFailureBeforeReceiptIsRetriedByTheNextPass() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .notReceived("exited"), .reply("Here."))
        let first = try? await runner.run("where?", model: .sonnet5)
        XCTAssertNil(first)
        let pending = await bridge.current.pending
        XCTAssertNil(pending)
        let reply = try await runner.answerPending(model: .sonnet5)
        XCTAssertEqual(reply?.text, "Here.")
        XCTAssertEqual(guest.inputs, ["where?", "where?"])
    }

    // MARK: - The guest misses a turn

    /// A limb's turn between two of the phone's reaches the guest before the next.
    func testALimbsTurnBetweenTwoPhoneTurnsReachesTheGuestAsContext() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, _, guest) = try await launch(db, .reply("Noted."), .reply("Both."))
        _ = try await runner.run("remember the bins", model: .sonnet5)
        try await write(db, .person, "and the recycling", device: "watch")
        _ = try await runner.run("what did I say?", model: .sonnet5)
        XCTAssertEqual(guest.inputs.first, "remember the bins")
        let second = try XCTUnwrap(guest.inputs.last)
        XCTAssertTrue(second.contains("Them: and the recycling"), second)
        XCTAssertTrue(second.hasSuffix("what did I say?"), second)
        XCTAssertFalse(second.contains("remember the bins"), "the guest was told what it had seen")
    }

    /// A reply another primary wrote reaches the guest too.
    func testAnotherPrimarysReplyReachesTheGuestAsContext() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, _, guest) = try await launch(db, .reply("One."), .reply("Three."))
        _ = try await runner.run("one", model: .sonnet5)
        try await write(db, .person, "two", device: "watch")
        try await write(db, .assistant, "Two, from the hub.", device: "hub")
        _ = try await runner.run("three", model: .sonnet5)
        let input = try XCTUnwrap(guest.inputs.last)
        XCTAssertTrue(input.contains("Them: two"), input)
        XCTAssertTrue(input.contains("You, answering on another device: Two, from the hub."), input)
    }

    /// A branch that arrives late, with a timestamp earlier than anything the guest has seen, is
    /// still delivered: what was seen is a set of turns, not a point in time.
    func testALateBranchWithAnEarlierTimestampIsStillDelivered() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, _, guest) = try await launch(db, .reply("A."), .reply("B."))
        let first = try await runner.run("first", model: .sonnet5)
        let late = TurnLog(database: db)
        _ = try await late.writer(for: DeviceID("pad")).append(.person, "said offline, long ago",
                                                               parents: [first.person.ref], at: .distantPast)
        _ = try await runner.run("second", model: .sonnet5)
        let input = try XCTUnwrap(guest.inputs.last)
        XCTAssertTrue(input.contains("said offline, long ago"), input)
        XCTAssertFalse(input.contains("Them: first"), input)
    }

    /// Nothing is counted seen until the reply to it is in the log.
    func testTheBookkeepingAdvancesOnlyOnAWrittenReply() async throws {
        let db = RefusingReplies()
        let (runner, bridge, _) = try await launch(db, .reply("Refused."))
        await db.refuse(true)
        let refused = try? await runner.run("hello", model: .sonnet5)
        XCTAssertNil(refused)
        let logged4 = try await log(db)
        let person = try XCTUnwrap(logged4.first)
        let ledger = await bridge.current
        XCTAssertFalse(ledger.seen.contains(person.ref), "seen before its reply was written")
        XCTAssertNotNil(ledger.pending)
    }

    /// A session that has seen nothing — a fresh one after a resume failed — is given the last
    /// turns of the log, and told that is what they are.
    func testAFreshSessionIsGivenTheLogSoFar() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, _, guest) = try await launch(db, .reply("Noted."), .reply("Marmalade."))
        _ = try await runner.run("the word is marmalade", model: .sonnet5)
        guest.startFresh()
        _ = try await runner.run("what was the word?", model: .sonnet5)
        let input = try XCTUnwrap(guest.inputs.last)
        XCTAssertTrue(input.hasPrefix("[The conversation so far, from the log on their devices — the last 2 turns"), input)
        XCTAssertTrue(input.contains("Them: the word is marmalade"), input)
        XCTAssertTrue(input.contains("You, answering on another device: Noted."), input)
    }

    /// At most `contextLimit` unseen turns go in one input.
    func testAFreshSessionIsGivenAtMostTheLimit() {
        let turns = (1...60).map { Turn(ref: TurnRef(device: DeviceID("pad"), sequence: Int64($0)), parents: [],
                                        role: .person, text: "t\($0)", at: Date()) }
        let answering = Turn(ref: TurnRef(device: phone, sequence: 1), parents: [], role: .person, text: "now", at: Date())
        let input = GuestBridge.render(unseen: Array(turns.suffix(GuestBridge.contextLimit)), answering: [answering], fresh: true)
        XCTAssertTrue(input.contains("the last 40 turns"), input)
        XCTAssertFalse(input.contains("Them: t20\n"), input)
        XCTAssertTrue(input.contains("Them: t21"), input)
    }

    // MARK: - The model

    func testTheModelSettingReachesTheGuest() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("ok"))
        _ = try await runner.run("hi", model: .opus5)
        await bridge.use(model: .fable51)
        XCTAssertEqual(guest.models, [ClaudeModel.effective(.opus5).rawValue, ClaudeModel.effective(.fable51).rawValue])
    }

    // MARK: - No fallback

    /// The app composes the guest and nothing else.
    func testTheAppComposesTheGuestAsItsOnlyBrain() {
        let harness = Harness.standard(tokens: StoredTokenProvider(store: InMemoryTokenStore(nil)),
                                       database: InMemoryRecordDatabase())
        XCTAssertNotNil(harness.guest)
        XCTAssertFalse(harness.brain is MessagesAPIBrain)
    }

    /// A guest that is not ready leaves the person's turn in the log unanswered, with the reason
    /// shown; the answering pass answers it once the guest is ready.
    func testAGuestNotReadyLeavesTheTurnUnansweredWithTheReason() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home)
        guest.refuse("rootfs downloading 1.2 MB of 4.1 MB; claude code waiting for a network")
        let bridge = GuestBridge(conversation: guest, ledger: ledgerFile)
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!, brain: bridge, leaseSleep: parked,
                              pause: { _ in throw CancellationError() })

        await harness.send("hello")
        let logged5 = try await log(db)
        XCTAssertEqual(logged5.map(\.text), ["hello"])
        let error = try XCTUnwrap(harness.error)
        XCTAssertTrue(error.contains("rootfs downloading 1.2 MB of 4.1 MB"), error)
        XCTAssertTrue(guest.inputs.isEmpty)
        await harness.answerPending()
        let logged6 = try await log(db)
        XCTAssertEqual(logged6.map(\.text), ["hello"])

        guest.refuse(nil)
        guest.then(.reply("Hello."))
        await harness.answerPending()
        let logged7 = try await log(db)
        XCTAssertEqual(logged7.map(\.text), ["hello", "Hello."])
        XCTAssertNil(harness.error)
    }

    /// Sign-out forgets the bridge's ledger — the input outstanding and what the guest has seen —
    /// together with the guest's session, so the next login's first turn goes to a fresh session
    /// that is given the log as the conversation so far, and nothing of the last one is reconciled.
    func testSignOutForgetsTheLedgerAndTheGuestSession() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.reply("Noted."), .cutOff])
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!,
                              brain: GuestBridge(conversation: guest, ledger: ledgerFile), leaseSleep: parked,
                              pause: { _ in throw CancellationError() })
        await harness.send("the word is marmalade")
        await harness.send("run the report")
        XCTAssertNotNil(harness.unfinished)
        let before = GuestLedger.load(ledgerFile)
        XCTAssertNotNil(before.pending, "no input outstanding to forget")
        XCTAssertGreaterThan(before.seen.count, 0)
        let resident = await guest.sessionID()
        XCTAssertEqual(resident, "S1")

        harness.forget()
        try await eventually("the ledger to go") { !FileManager.default.fileExists(atPath: ledgerFile.path) }
        let forgotten = await guest.sessionID()
        XCTAssertNil(forgotten, "the guest's session outlived the sign-out")
        XCTAssertNil(harness.unfinished)

        // The next launch: the session id the guest kept (none), the ledger on disk (none).
        let relaunched = ScriptedGuest(home: home, script: [.reply("Hello.")], session: forgotten)
        let bridge = GuestBridge(conversation: relaunched, ledger: ledgerFile)
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
        XCTAssertNil(ledger.session)
        XCTAssertEqual(ledger.seen.count, 0)
        let unresolved = await bridge.unresolved()
        XCTAssertTrue(unresolved.isEmpty)
        let owed = await bridge.owed()
        XCTAssertNil(owed)
        let log = TurnLog(database: db)
        let lease = PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(), sleep: parked)
        let runner = TurnRunner(log: log, writer: try await log.writer(for: phone), lease: lease, brain: bridge)
        _ = try await runner.run("hello", model: .sonnet5)
        let input = try XCTUnwrap(relaunched.inputs.first)
        XCTAssertTrue(input.hasPrefix("[The conversation so far"), input)
        XCTAssertTrue(input.contains("Them: run the report"), input)
    }

    /// Topo on the glass follows the chat's guest through the real wiring — the bridge's
    /// activity, the relay, `onGuest` as `Mascot.follow(_:)` installs it — in order: the turn
    /// begins, each update moves him, and the turn going leaves him idle.
    func testTheMascotFollowsTheGuestsTurnInOrder() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi.", context: 1234), .cutOff])
        let (bridge, relay) = Harness.guestBrain(guest, ledger: ledgerFile)
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!, brain: bridge, relay: relay,
                              leaseSleep: parked, pause: { _ in throw CancellationError() })
        let mascot = Mascot(model: "claude-sonnet-5")
        mascot.follow(harness)
        let installed = try XCTUnwrap(harness.onGuest, "following the harness installed nothing")
        var seen: [String] = []
        harness.onGuest = { activity in
            installed(activity)
            let state = mascot.state
            seen.append("\(Self.label(activity)) -> \(state.activity.rawValue) \(state.tokens)")
        }

        await harness.send("hello")
        XCTAssertEqual(seen, [
            "began 7 -> idle 0",
            "started -> idle 0",
            "text -> idle 0",
            "usage -> idle 1234",
            "ended answered -> idle 1234",
            "gone -> idle 1234",
        ])
        XCTAssertEqual(mascot.state.model, "claude-haiku-4-5-20251001")

        seen = []
        await harness.send("run the report")
        XCTAssertEqual(seen, [
            "began 7 -> idle 1234",
            "started -> idle 1234",
            "tool Bash -> building 1234",
            "ended abandoned -> idle 1234",
            "gone -> idle 1234",
        ])
    }

    private static func label(_ activity: GuestActivity) -> String {
        switch activity {
        case .began(let pid): "began \(pid.map(String.init) ?? "none")"
        case .gone: "gone"
        case .update(.event(.started)): "started"
        case .update(.event(.text)): "text"
        case .update(.event(.usage)): "usage"
        case .update(.event(.toolUse(let name, _))): "tool \(name)"
        case .update(.event(let other)): "\(other)"
        case .update(.ended(.answered)): "ended answered"
        case .update(.ended(.abandoned)): "ended abandoned"
        case .update(.ended(.failed)): "ended failed"
        }
    }

    /// The person's control for a cut-off turn: shown, and asking again sends it once.
    func testAnUnfinishedTurnIsShownAndAskedAgainOnlyWhenThePersonAsks() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.cutOff])
        let bridge = GuestBridge(conversation: guest, ledger: ledgerFile)
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!, brain: bridge, leaseSleep: parked,
                              pause: { _ in throw CancellationError() })

        await harness.send("run the report")
        XCTAssertEqual(harness.unfinished?.text, "run the report")
        XCTAssertEqual(harness.error, GuestBridgeError.unresolved.description)
        await harness.answerPending()
        XCTAssertEqual(guest.inputs.count, 1, "the loop asked again by itself")

        guest.then(.reply("Report sent."))
        await harness.askAgain()
        XCTAssertEqual(guest.inputs, ["run the report", "run the report"])
        let logged8 = try await log(db)
        XCTAssertEqual(logged8.map(\.text), ["run the report", "Report sent."])
        XCTAssertNil(harness.unfinished)
    }
}

/// The guest's start: a failure is not kept, so the start that follows it tries again.
@MainActor
final class StartOnceTests: XCTestCase {
    func testAFailedStartIsTriedAgainAndASuccessIsKept() async throws {
        let once = StartOnce<Int>()
        var attempts = 0
        let start: @MainActor () async throws -> Int = {
            attempts += 1
            if attempts == 1 { throw Refused() }
            return 42
        }
        do {
            _ = try await once.value(start)
            XCTFail("the first start succeeded")
        } catch is Refused {}
        let second = try await once.value(start)
        XCTAssertEqual(second, 42, "a start after a failure was not tried again")
        let third = try await once.value(start)
        XCTAssertEqual(third, 42)
        XCTAssertEqual(attempts, 2, "a start that worked was run again")
    }

    /// Every caller waiting on a start that fails hears the failure; the next call starts afresh.
    func testCallersWaitingOnAFailingStartShareItsFailure() async throws {
        let once = StartOnce<Int>()
        var attempts = 0
        var gate: CheckedContinuation<Void, Never>?
        let failing: @MainActor () async throws -> Int = {
            attempts += 1
            await withCheckedContinuation { gate = $0 }
            throw Refused()
        }
        let first = Task { @MainActor in try await once.value(failing) }
        let second = Task { @MainActor in try await once.value(failing) }
        while gate == nil { await Task.yield() }
        for _ in 0..<10 { await Task.yield() }
        gate?.resume()
        let answers = [await first.result, await second.result]
        XCTAssertTrue(answers.allSatisfy { if case .failure = $0 { true } else { false } })
        XCTAssertEqual(attempts, 1, "two callers started twice")
        let recovered = try await once.value { 7 }
        XCTAssertEqual(recovered, 7)
    }
}

// MARK: - Doubles

/// The in-memory log, able to refuse every reply's save (nothing written) and to commit the next
/// reply and throw (a lost acknowledgement).
private actor RefusingReplies: RecordDatabase {
    let wrapped = InMemoryRecordDatabase()
    private var refusing = false
    private var loseNext = false

    func refuse(_ on: Bool) { refusing = on }
    func loseNextReplyAcknowledgement() { loseNext = true }

    private func isReply(_ records: [Record]) -> Bool {
        records.contains { Turn(record: $0)?.role == .assistant }
    }

    func save(_ records: [Record]) async throws -> [Record] {
        if refusing, isReply(records) { throw RecordDatabaseError.unavailable(underlying: Refused()) }
        let saved = try await wrapped.save(records)
        if loseNext, isReply(records) {
            loseNext = false
            throw RecordDatabaseError.unavailable(underlying: Refused())
        }
        return saved
    }

    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await wrapped.records(ofType: type) }
}

private struct Refused: Error {}

private let parked: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

private extension InMemoryTokenStore {
    var provider: StoredTokenProvider { StoredTokenProvider(store: self) }
}

@MainActor
private func eventually(_ what: String, within seconds: TimeInterval = 10, _ condition: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while !(try await condition()) {
        guard Date() < deadline else {
            XCTFail("timed out waiting for \(what)")
            throw Refused()
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
