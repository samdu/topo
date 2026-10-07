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
        let lease = steadyLease(database, device)
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
        XCTAssertEqual(Reconciliation.of(pending, verdict: .unreadable, request: "answer/a"), .unknown)
        XCTAssertEqual(Reconciliation.of(pending, verdict: .unreadable, request: "answer/b"), .unknown)
        XCTAssertEqual(Reconciliation.of(pending, verdict: .unreadable, request: nil), .unknown)
        XCTAssertEqual(Reconciliation.of(pending, verdict: .answered("hi"), request: "answer/a"), .answered("hi"))
        XCTAssertEqual(Reconciliation.of(pending, verdict: .answered("hi"), request: "answer/b"),
                       .owed(OwedReply(parents: [], nonce: "answer/a", text: "hi")))
        XCTAssertEqual(Reconciliation.of(pending, verdict: .answered("hi"), request: nil),
                       .owed(OwedReply(parents: [], nonce: "answer/a", text: "hi")))
        XCTAssertEqual(Reconciliation.of(pending, verdict: .unresolved, request: "answer/a"), .unresolved)
        XCTAssertEqual(Reconciliation.of(askedAgain, verdict: .unresolved, request: "answer/a"), .askAgain)
        XCTAssertEqual(Reconciliation.of(pending, verdict: .unresolved, request: "answer/b"), .superseded)
        XCTAssertEqual(Reconciliation.of(pending, verdict: .unresolved, request: nil), .hold)

        // Known received — answered, or read and cut off — is never cleared by a read that does
        // not find the input.
        for state in [GuestLedger.Pending.State.unresolved, .answered] {
            var known = pending
            known.state = state
            XCTAssertEqual(Reconciliation.of(known, verdict: .notReceived, request: "answer/a"), .unresolved, "\(state)")
            XCTAssertEqual(Reconciliation.of(known, verdict: .notReceived, request: "answer/b"), .superseded, "\(state)")
            XCTAssertEqual(Reconciliation.of(known, verdict: .notReceived, request: nil), .hold, "\(state)")
            known.askAgain = true
            XCTAssertEqual(Reconciliation.of(known, verdict: .notReceived, request: "answer/a"), .askAgain, "\(state)")
        }
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

    /// The input was sent and the app was killed; on the next launch the guest's transcript cannot
    /// be read. A read that failed is not an answer: the record stays, nothing is sent, and once
    /// the transcript reads again the turn is what it is — here, received and cut off.
    func testATranscriptThatCannotBeReadSendsNothingAndKeepsTheRecord() async throws {
        let db = InMemoryRecordDatabase()
        let (first, _, firstGuest) = try await launch(db, .hang)
        let killed = Task { try await first.run("delete my old drafts", model: .sonnet5) }
        try await eventually("the guest to read the input") { firstGuest.inputs.count == 1 }
        _ = killed

        let transcript = home.appendingPathComponent(".claude/projects/-home-topo/S1.jsonl")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: transcript.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript.path) }
        try XCTSkipIf((try? Data(contentsOf: transcript)) != nil, "missing coverage: this host reads a file with no permissions")

        let (second, bridge, guest) = try await launch(db, .reply("Deleted."))
        let before = await bridge.current.pending
        do {
            _ = try await second.answerPending(model: .sonnet5)
            XCTFail("a turn was answered over a transcript that could not be read")
        } catch let error as GuestBridgeError {
            XCTAssertEqual(error, .failed(GuestBridge.unknown))
        }
        XCTAssertTrue(guest.inputs.isEmpty, "the input was sent again over an unreadable transcript")
        let kept = await bridge.current.pending
        XCTAssertNotNil(kept)
        XCTAssertEqual(kept, before, "the record changed on a read that failed")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: transcript.path)
        let answered = try await second.answerPending(model: .sonnet5)
        XCTAssertNil(answered)
        XCTAssertTrue(guest.inputs.isEmpty)
        let state = await bridge.current.pending?.state
        XCTAssertEqual(state, .unresolved)
    }

    /// The same with the folder of transcripts unlistable rather than the file unreadable: a
    /// listing that failed is no answer, so the record stays and nothing is sent until it lists.
    func testATranscriptFolderThatCannotBeListedSendsNothingAndKeepsTheRecord() async throws {
        let db = InMemoryRecordDatabase()
        let (first, _, firstGuest) = try await launch(db, .hang)
        let killed = Task { try await first.run("delete my old drafts", model: .sonnet5) }
        try await eventually("the guest to read the input") { firstGuest.inputs.count == 1 }
        _ = killed

        let folder = home.appendingPathComponent(".claude/projects/-home-topo")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        try XCTSkipIf((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil,
                      "missing coverage: this host lists a folder with no permissions")

        let (second, bridge, guest) = try await launch(db, .reply("Deleted."))
        let before = await bridge.current.pending
        do {
            _ = try await second.answerPending(model: .sonnet5)
            XCTFail("a turn was answered over a folder of transcripts that could not be listed")
        } catch let error as GuestBridgeError {
            XCTAssertEqual(error, .failed(GuestBridge.unknown))
        }
        XCTAssertTrue(guest.inputs.isEmpty, "the input was sent again over an unlisted folder")
        let kept = await bridge.current.pending
        XCTAssertEqual(kept, before, "the record changed on a listing that failed")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        let answered = try await second.answerPending(model: .sonnet5)
        XCTAssertNil(answered)
        XCTAssertTrue(guest.inputs.isEmpty)
        let state = await bridge.current.pending?.state
        XCTAssertEqual(state, .unresolved)
    }

    /// The input was sent and the app was killed; on the next launch the bridge's own ledger is
    /// not a ledger (torn in half). A ledger that cannot be read is not an empty one: nothing is
    /// sent, nothing is written over the file, and once it reads again — in the same launch — the
    /// turn is what it is: received and cut off.
    func testALedgerThatCannotBeDecodedSendsNothingAndIsNotWrittenOver() async throws {
        let db = InMemoryRecordDatabase()
        let (first, _, firstGuest) = try await launch(db, .hang)
        let killed = Task { try await first.run("delete my old drafts", model: .sonnet5) }
        try await eventually("the guest to read the input") { firstGuest.inputs.count == 1 }
        _ = killed
        let recorded = try Data(contentsOf: ledgerFile)
        let torn = Data(recorded.prefix(recorded.count / 2))
        try torn.write(to: ledgerFile)

        let (second, bridge, guest) = try await launch(db, .reply("Deleted."))
        try await assertRefusedOverAnUnreadLedger(second, bridge)
        XCTAssertTrue(guest.inputs.isEmpty, "the input was sent again over a ledger that could not be read")
        XCTAssertEqual(try Data(contentsOf: ledgerFile), torn, "the ledger was written over")

        try recorded.write(to: ledgerFile)
        let answered = try await second.answerPending(model: .sonnet5)
        XCTAssertNil(answered)
        XCTAssertTrue(guest.inputs.isEmpty, "an input the guest received was sent again")
        let state = await bridge.current.pending?.state
        XCTAssertEqual(state, .unresolved)
    }

    /// The same with a ledger the process cannot open: refused, not written over, and read again
    /// by the next request once it can be.
    func testALedgerThatCannotBeOpenedSendsNothingAndIsReadAgain() async throws {
        let db = InMemoryRecordDatabase()
        let (first, _, firstGuest) = try await launch(db, .hang)
        let killed = Task { try await first.run("delete my old drafts", model: .sonnet5) }
        try await eventually("the guest to read the input") { firstGuest.inputs.count == 1 }
        _ = killed
        let recorded = try Data(contentsOf: ledgerFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: ledgerFile.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ledgerFile.path) }
        try XCTSkipIf((try? Data(contentsOf: ledgerFile)) != nil, "missing coverage: this host reads a file with no permissions")

        let (second, bridge, guest) = try await launch(db, .reply("Deleted."))
        try await assertRefusedOverAnUnreadLedger(second, bridge)
        XCTAssertTrue(guest.inputs.isEmpty, "the input was sent again over a ledger that could not be read")

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ledgerFile.path)
        XCTAssertEqual(try Data(contentsOf: ledgerFile), recorded, "the ledger was written over")
        let answered = try await second.answerPending(model: .sonnet5)
        XCTAssertNil(answered)
        XCTAssertTrue(guest.inputs.isEmpty, "an input the guest received was sent again")
        let state = await bridge.current.pending?.state
        XCTAssertEqual(state, .unresolved)
    }

    /// Two passes over a ledger that cannot be read: each refused with the reason, nothing owed,
    /// nothing held as unresolved, and the diagnostics row saying why.
    private func assertRefusedOverAnUnreadLedger(_ runner: TurnRunner, _ bridge: GuestBridge) async throws {
        for _ in 0..<2 {
            do {
                _ = try await runner.answerPending(model: .sonnet5)
                XCTFail("a turn was answered over a ledger that could not be read")
            } catch let error as GuestBridgeError {
                XCTAssertEqual(error, .failed(GuestBridge.ledgerUnreadable))
            }
        }
        let owed = await bridge.owed()
        XCTAssertNil(owed)
        await bridge.askAgain()
        let described = await bridge.describe()
        XCTAssertTrue(described.contains("ledger could not be read"), described)
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
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            // The lost acknowledgement, and not the reply refused for any other reason.
            guard case RecordDatabaseError.unavailable = underlying else {
                return XCTFail("the reply failed before its save: \(underlying)")
            }
        }
        let armed = await db.acknowledgementStillToLose
        XCTAssertFalse(armed, "the reply's save never reached the log")
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

    /// A turn cut off and then moved past: the guest is not told it again, but nothing it carried
    /// counts as seen until the reply to the turn that moved past it is in the log. With that
    /// reply's append refused, the coverage has not moved; once it is written, it has.
    func testMovingPastACutOffTurnAdvancesTheCoverageOnlyWhenTheReplyLands() async throws {
        let db = RefusingReplies()
        let (runner, bridge, guest) = try await launch(db, .cutOff, .reply("Fine."))
        let cut = try? await runner.run("run the report", model: .sonnet5)
        XCTAssertNil(cut)
        let seenBefore = await bridge.current.seen
        let logged = try await log(db)
        let report = try XCTUnwrap(logged.first)

        await db.refuse(true)
        let refused = try? await runner.run("never mind", model: .sonnet5)
        XCTAssertNil(refused)
        XCTAssertEqual(guest.inputs, ["run the report", "never mind"], "the guest was told the cut-off turn again")
        let afterRefusal = await bridge.current
        XCTAssertEqual(afterRefusal.seen, seenBefore, "the coverage moved before the reply landed")
        XCTAssertFalse(afterRefusal.seen.contains(report.ref))
        XCTAssertNotNil(afterRefusal.pending)

        await db.refuse(false)
        _ = try await runner.answerPending(model: .sonnet5)
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["run the report", "never mind", "Fine."])
        let landed = await bridge.current
        XCTAssertTrue(turns.allSatisfy { landed.seen.contains($0.ref) }, "the coverage did not catch up once it landed")
        XCTAssertEqual(guest.inputs.count, 2)
    }

    /// Claude Code ended the turn with an error result and lives on, its transcript not yet
    /// written: the bridge does not read it, the turn is unresolved, and nothing is sent again.
    func testAnErrorResultIsUnresolvedAndNothingIsSentAgain() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .errorResult("API Error: 529 Overloaded"), .reply("Too late."))
        do {
            _ = try await runner.run("run the report", model: .sonnet5)
            XCTFail("a turn that ended in an error result was answered")
        } catch TurnRunnerError.replyFailed(_, let underlying) {
            XCTAssertEqual(underlying as? GuestBridgeError, .unresolved)
        }
        let state = await bridge.current.pending?.state
        XCTAssertEqual(state, .unresolved)
        let answered = try await runner.answerPending(model: .sonnet5)
        XCTAssertNil(answered)
        XCTAssertEqual(guest.inputs, ["run the report"], "a turn the guest received was sent again")
    }

    /// The error result said Claude Code received the turn, and its transcript never shows the
    /// input: a record known received is not cleared by a read that does not find it, so no
    /// later pass sends the turn again.
    func testAnErrorResultStaysUnresolvedWhateverTheTranscriptLaterSays() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .errorResult("API Error: 529 Overloaded"), .reply("Too late."))
        let failed = try? await runner.run("run the report", model: .sonnet5)
        XCTAssertNil(failed)
        for _ in 0..<3 {
            let answered = try await runner.answerPending(model: .sonnet5)
            XCTAssertNil(answered)
        }
        XCTAssertEqual(guest.inputs, ["run the report"], "a turn the guest received was sent again")
        let state = await bridge.current.pending?.state
        XCTAssertEqual(state, .unresolved)
        let unresolved = await bridge.unresolved()
        XCTAssertEqual(unresolved.count, 1)
    }

    /// The answer stopped listening — its task cancelled — while the guest still had the turn,
    /// before Claude Code wrote the input to its transcript. Nothing is concluded: the record
    /// stays as sent, the next pass waits for the guest's turn to end, and then writes its reply
    /// without asking again.
    func testAnAnswerCancelledMidTurnConcludesNothingAndTheNextPassWaitsForTheTurn() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .hangUnwritten)
        let asking = Task { try await runner.run("delete my old drafts", model: .sonnet5) }
        try await eventually("the guest to take the input") { guest.inputs.count == 1 }
        asking.cancel()
        if case .success = await asking.result { XCTFail("a cancelled answer was answered") }
        let kept = await bridge.current.pending
        XCTAssertEqual(kept?.state, .sent, "a turn still with the guest was concluded")

        let pass = Task { try await runner.answerPending(model: .sonnet5) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(guest.inputs.count, 1, "the input was sent again while the guest still had it")
        guest.finishHanging(with: "Deleted three.")
        _ = try await pass.value
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["delete my old drafts", "Deleted three."])
        XCTAssertEqual(guest.inputs.count, 1)
        let pending = await bridge.current.pending
        XCTAssertNil(pending)
    }

    /// The process a turn went to exited, and its end was not confirmed: what it wrote may still
    /// be being written, so a transcript without the input says nothing yet. The record stays and
    /// nothing is sent until an end is confirmed; then the turn, never received, goes.
    func testAnEndNotConfirmedConcludesNothingUntilOneIs() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .notReceived("exited"), .reply("Here."))
        guest.confirmEnds(false)
        let first = try? await runner.run("where?", model: .sonnet5)
        XCTAssertNil(first)
        let kept = await bridge.current.pending
        XCTAssertEqual(kept?.state, .sent, "a record was concluded from a process not confirmed gone")
        do {
            _ = try await runner.answerPending(model: .sonnet5)
            XCTFail("a turn was answered while its process was not confirmed gone")
        } catch let error as GuestBridgeError {
            XCTAssertEqual(error, .failed(GuestBridge.unknown))
        }
        XCTAssertEqual(guest.inputs, ["where?"])

        guest.confirmEnds(true)
        let reply = try await runner.answerPending(model: .sonnet5)
        XCTAssertEqual(reply?.text, "Here.")
        XCTAssertEqual(guest.inputs, ["where?", "where?"])
    }

    /// Another device answered a turn this phone sent while what became of it here is not known
    /// (the transcripts unlisted). The reply found under its nonce settles the request, and counts
    /// nothing seen the guest may never have been told: the next input tells it both.
    func testAReplyFoundForAnInputNotKnownReceivedCountsNothingSeen() async throws {
        let db = InMemoryRecordDatabase()
        let (first, _, firstGuest) = try await launch(db, .reply("Noted."), .hangUnwritten)
        _ = try await first.run("hello", model: .sonnet5)
        let killed = Task { try await first.run("call Helen", model: .sonnet5, nonce: "said-once") }
        try await eventually("the input to go") { firstGuest.inputs.count == 2 }
        _ = killed
        let logged = try await log(db)
        let call = try XCTUnwrap(logged.first { $0.text == "call Helen" })
        _ = try await TurnLog(database: db).writer(for: DeviceID("hub"))
            .append(.assistant, "Calling.", parents: [call.ref], nonce: TurnRunner.replyNonce(for: [call.ref]))

        let folder = home.appendingPathComponent(".claude/projects/-home-topo")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        try XCTSkipIf((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) != nil,
                      "missing coverage: this host lists a folder with no permissions")
        let (second, bridge, guest) = try await launch(db, .reply("You asked me to call Helen."))
        let retried = try await second.run("call Helen", model: .sonnet5, nonce: "said-once")
        XCTAssertEqual(retried.assistant.text, "Calling.")
        XCTAssertTrue(guest.inputs.isEmpty)
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
        XCTAssertFalse(ledger.seen.contains(call.ref), "a turn the guest may never have had was counted seen")
        XCTAssertFalse(ledger.seen.contains(retried.assistant.ref), "another device's reply was counted the guest's")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        _ = try await second.run("what did I ask?", model: .sonnet5)
        let input = try XCTUnwrap(guest.inputs.last)
        XCTAssertTrue(input.contains("Them: call Helen"), input)
        XCTAssertTrue(input.contains("You, answering on another device: Calling."), input)
        XCTAssertTrue(input.hasSuffix("what did I ask?"), input)
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

    /// At most `contextLimit` unseen turns go in one input, cut at the bridge: 60 turns the guest
    /// has not seen, and the input carries the newest 40.
    func testAFreshSessionIsGivenAtMostTheLimitOfUnseenTurns() async throws {
        let db = InMemoryRecordDatabase()
        for n in 1...60 {
            try await write(db, n.isMultiple(of: 2) ? .assistant : .person, "t\(n)", device: "pad")
        }
        let (runner, _, guest) = try await launch(db, .reply("Caught up."))
        _ = try await runner.run("now", model: .sonnet5)
        let input = try XCTUnwrap(guest.inputs.first)
        let lines = input.components(separatedBy: "\n\n")
        let turns = lines.filter { $0.hasPrefix("Them: ") || $0.hasPrefix("You, answering on another device: ") }
        XCTAssertEqual(turns.count, GuestBridge.contextLimit)
        XCTAssertEqual(GuestBridge.contextLimit, 40)
        XCTAssertTrue(input.contains("the last 40 turns"), input)
        XCTAssertEqual(turns.first, "Them: t21")
        XCTAssertEqual(turns.last, "You, answering on another device: t60")
        XCTAssertFalse(lines.contains("You, answering on another device: t20"))
        XCTAssertEqual(lines.last, "now")
    }

    /// A session that has seen the log is told every turn it has not seen, however many: 41 turns
    /// from another device between two of the phone's all reach the guest, oldest first, and the
    /// next input carries none of them again.
    func testAnExistingSessionIsToldEveryTurnItHasNotSeenBeyondTheLimit() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("Noted."), .reply("Caught up."), .reply("Fine."))
        _ = try await runner.run("first", model: .sonnet5)
        let missed = GuestBridge.contextLimit + 1
        for n in 1...missed {
            try await write(db, n.isMultiple(of: 2) ? .assistant : .person, "m\(n)", device: "pad")
        }
        _ = try await runner.run("now", model: .sonnet5)
        XCTAssertEqual(guest.inputs.count, 2)
        let input = guest.inputs[1]
        XCTAssertTrue(input.hasPrefix("[Meanwhile"), input)
        let lines = input.components(separatedBy: "\n\n")
        let told = lines.filter { $0.hasPrefix("Them: ") || $0.hasPrefix("You, answering on another device: ") }
        XCTAssertEqual(told.count, missed, "an unseen turn was left out of the input")
        XCTAssertEqual(told.first, "Them: m1")
        XCTAssertEqual(told.last, "Them: m\(missed)")
        XCTAssertFalse(input.contains("Them: first"), "the guest was told what it had seen")

        _ = try await runner.run("again", model: .sonnet5)
        XCTAssertEqual(guest.inputs.last, "again", "the next input told the guest something again")
        let ledger = await bridge.current
        let turns = try await log(db)
        XCTAssertTrue(turns.allSatisfy { ledger.seen.contains($0.ref) })
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
        XCTAssertNotNil(harness.guest, "the brain is the guest")
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
        let before = try GuestLedger.load(ledgerFile)
        XCTAssertNotNil(before.pending, "no input outstanding to forget")
        XCTAssertGreaterThan(before.seen.count, 0)
        let resident = await guest.sessionID()
        XCTAssertEqual(resident, "S1")

        await harness.forget()
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
        let lease = steadyLease(db, phone)
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
            "began 7 for phone/1 -> thinking 0",
            "started -> thinking 0",
            "text -> thinking 0",
            "usage -> thinking 1234",
            "ended answered -> idle 1234",
            "gone for phone/1 -> idle 1234",
        ])
        XCTAssertEqual(mascot.state.model, "claude-haiku-4-5-20251001")

        seen = []
        await harness.send("run the report")
        XCTAssertEqual(seen, [
            "began 7 for phone/3 -> thinking 1234",
            "started -> thinking 1234",
            "tool Bash -> building 1234",
            "ended abandoned -> idle 1234",
            "gone for phone/3 -> idle 1234",
        ])
    }

    private static func label(_ activity: GuestActivity) -> String {
        switch activity {
        case .began(let pid, let answering): "began \(pid.map(String.init) ?? "none") for \(DebugRun.refs(answering))"
        case .gone(let answering): "gone for \(DebugRun.refs(answering))"
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

    /// Sign-out while an answer waits for the guest to be ready: when the wait ends, the answer
    /// belongs to a login that has gone, so it records nothing and sends nothing.
    func testSignOutWhileAnAnswerWaitsForTheGuestRecordsAndSendsNothing() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.reply("Noted."), .reply("Too late.")])
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let bridge = GuestBridge(conversation: guest, ledger: ledgerFile)
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!, brain: bridge, leaseSleep: parked,
                              pause: { _ in throw CancellationError() })
        await harness.send("the word is marmalade")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerFile.path), "no ledger to forget")

        guest.holdReady()
        // Asked through the runner directly, as the answering pass asks, so no cancellation of
        // the chat's own task is what stops it: only the sign-out.
        let log = TurnLog(database: db)
        try await log.writer(for: DeviceID("watch")).append(.person, "and now?", continuing: try await log.read())
        let lease = steadyLease(db, phone)
        let runner = TurnRunner(log: log, writer: try await log.writer(for: phone), lease: lease, brain: bridge)
        let waiting = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the answer to wait at ready") { guest.readyHeld }

        await harness.forget()
        try await eventually("the ledger to go") { !FileManager.default.fileExists(atPath: ledgerFile.path) }
        guest.releaseReady()
        let result = await waiting.result
        if case .success = result { XCTFail("an answer begun before the sign-out finished after it") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a record was written after the sign-out")
        XCTAssertEqual(guest.inputs, ["the word is marmalade"], "an input was sent after the sign-out")
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
    }

    /// Sign-out while an answering pass is mid-turn: the guest has the input and holds its result
    /// until after the sign-out. Asked through the runner directly, so nothing cancels the pass —
    /// only the login it began under going. The guest's answer comes back to a bridge whose login
    /// has gone: no reply is handed to the runner, nothing is appended, and no ledger is written.
    func testSignOutWhileAPassIsMidTurnAppendsNothingAndWritesNoLedger() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.reply("Noted."), .hang])
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let bridge = GuestBridge(conversation: guest, ledger: ledgerFile)
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!, brain: bridge, leaseSleep: parked,
                              pause: { _ in throw CancellationError() })
        await harness.send("the word is marmalade")

        let log = TurnLog(database: db)
        try await log.writer(for: DeviceID("watch")).append(.person, "and now?", continuing: try await log.read())
        let lease = steadyLease(db, phone)
        let runner = TurnRunner(log: log, writer: try await log.writer(for: phone), lease: lease, brain: bridge)
        let answering = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the guest to take the watch's turn") { guest.inputs.count == 2 }

        await harness.forget()
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "the sign-out left the ledger")
        guest.finishHanging(with: "Too late.")
        let result = await answering.result
        if case .success(let reply) = result { XCTFail("a pass begun before the sign-out wrote \(reply?.text ?? "nil") after it") }

        let turns = try await self.log(db)
        XCTAssertEqual(turns.map(\.text), ["the word is marmalade", "Noted.", "and now?"], "a reply was appended after the sign-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a ledger was written after the sign-out")
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
        XCTAssertEqual(ledger.seen.count, 0)
    }

    /// The same through the harness's own pass, as the answering loop runs it: the sign-out
    /// cancels the pass in flight, the guest's late answer reaches nobody, and nothing is appended
    /// or recorded.
    func testSignOutCancelsTheHarnessPassInFlightAndNothingLands() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.reply("Noted."), .hang])
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let bridge = GuestBridge(conversation: guest, ledger: ledgerFile)
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!, brain: bridge, leaseSleep: parked,
                              pause: { _ in throw CancellationError() })
        await harness.send("the word is marmalade")
        try await write(db, .person, "and now?", device: "watch")

        let pass = Task { await harness.answerPending() }
        try await eventually("the guest to take the watch's turn") { guest.inputs.count == 2 }
        await harness.forget()
        guest.finishHanging(with: "Too late.")
        await pass.value

        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["the word is marmalade", "Noted.", "and now?"], "a reply was appended after the sign-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a ledger was written after the sign-out")
        XCTAssertTrue(harness.turns.isEmpty, "the pass drew on a screen the sign-out cleared")
        XCTAssertNil(harness.error)
    }

    /// The far end of a takeover signs this device out: what was waiting goes into the log as a
    /// limb's, and the brain forgets the conversation as a sign-out does — a viewer holds no login,
    /// so it keeps no ledger and no session of the guest's.
    func testADemotionForgetsTheLedgerAndTheGuestSession() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.reply("Noted.")])
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!,
                              brain: GuestBridge(conversation: guest, ledger: ledgerFile), leaseSleep: parked,
                              pause: { _ in throw CancellationError() })
        await harness.send("the word is marmalade")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerFile.path), "no ledger to forget")
        harness.willSend("and then")

        await harness.demote()
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["the word is marmalade", "Noted.", "and then"], "what was waiting was lost")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a viewer kept the ledger")
        let session = await guest.sessionID()
        XCTAssertNil(session, "a viewer kept the guest's session")
        XCTAssertEqual(guest.inputs, ["the word is marmalade"])
    }

    /// A takeover while the guest is part-way through a reply: the row that drew what it had
    /// written goes with the turn, since nothing the guest says of its ending is followed after.
    func testADemotionWhileAReplyIsBeingWrittenDropsItsRow() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.hangWriting("Marmalade is")])
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let (bridge, relay) = Harness.guestBrain(guest, ledger: ledgerFile)
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!,
                              brain: bridge, relay: relay, leaseSleep: parked,
                              pause: { _ in throw CancellationError() })
        let sending = Task { await harness.send("the word is marmalade") }
        for _ in 0..<500 where harness.writing != "Marmalade is" { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(harness.writing, "Marmalade is", "the reply was never drawn as written")

        await harness.demote()
        XCTAssertNil(harness.writing, "a viewer kept the row of a reply nobody is writing")
        guest.finishHanging(with: "Marmalade is a preserve.")
        await sending.value
        XCTAssertNil(harness.writing)
    }

    /// A spoken turn the guest answers in two messages, a tool call between them: whoever reads
    /// it aloud is told of the second message's start with nothing written, so the boundary is
    /// heard even when both messages open with the same words.
    func testTheReaderIsToldWhenTheGuestBeginsAnotherMessage() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.hangWritingTwice("Let me look. ", "Let me look. It is")])
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let (bridge, relay) = Harness.guestBrain(guest, ledger: ledgerFile)
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: UserDefaults(suiteName: name)!,
                              brain: bridge, relay: relay, leaseSleep: parked,
                              pause: { _ in throw CancellationError() })
        var heard: [String?] = []
        let nonce = harness.willSend("where is it?")
        harness.markSpoken(nonce)
        harness.onWriting = { text, answering in
            XCTAssertEqual(answering, nonce)
            heard.append(text)
        }
        let sending = Task { await harness.retry() }
        for _ in 0..<500 where heard.count < 3 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(heard, ["Let me look. ", "", "Let me look. It is"])
        guest.finishHanging(with: "It is on the shelf.")
        await sending.value
    }

    /// Sign-out while a send has not yet written the person's turn — iCloud still being reached:
    /// the outbox went with the login, and so do the words. Nothing reaches the log, and the guest
    /// is asked nothing.
    func testSignOutBeforeTheTurnIsInTheLogWritesNothing() async throws {
        let db = InMemoryRecordDatabase()
        let guest = ScriptedGuest(home: home, script: [.reply("Too late.")])
        let zone = Gate()
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone,
                              ensureZone: { await zone.pass() }, defaults: UserDefaults(suiteName: name)!,
                              brain: GuestBridge(conversation: guest, ledger: ledgerFile), leaseSleep: parked,
                              pause: { _ in throw CancellationError() })
        let sending = Task { await harness.send("hello") }
        try await eventually("the send to reach iCloud") { await zone.waiting }

        await harness.forget()
        await zone.open()
        await sending.value
        let turns = try await log(db)
        XCTAssertTrue(turns.isEmpty, "words from before the sign-out were written after it: \(turns.map(\.text))")
        XCTAssertTrue(guest.inputs.isEmpty, "the guest was asked after the sign-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a ledger was written after the sign-out")
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
// MARK: - Words given to the guest ahead of their turn (#278)

extension GuestBridgeTests {
    /// One launch of the app over `defaults`, which a relaunch shares with the launch before it.
    private func harness(_ db: any RecordDatabase, _ guest: ScriptedGuest, defaults: UserDefaults? = nil,
                         patience: Duration = .seconds(3600)) -> (Harness, GuestBridge) {
        let (bridge, relay) = Harness.guestBrain(guest, ledger: ledgerFile)
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone, ensureZone: {},
                              defaults: defaults ?? makeDefaults(),
                              brain: bridge, relay: relay, leaseSleep: parked,
                              pause: { _ in throw CancellationError() }, patience: patience)
        return (harness, bridge)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "topo.tests.bridge.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// A phone that has taken a turn as the one answering, and been closed: what its next launch
    /// finds on disk. Returns the defaults that launch shares.
    private func aPhoneThatAnswered(_ db: Outage) async throws -> UserDefaults {
        let defaults = makeDefaults()
        let (harness, _) = harness(db, ScriptedGuest(home: home, script: [.reply("Hi.")]), defaults: defaults)
        await harness.send("hello")
        XCTAssertEqual(harness.turns.map(\.text), ["hello", "Hi."])
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        return defaults
    }

    // MARK: A turn ready the moment the app is launched

    /// A cold launch with a turn already on the line, on a phone that was the one answering, and
    /// iCloud slow to answer anything: the guest has the words while nothing has been saved or
    /// even read, and the turn lands when iCloud answers, asked once.
    func testAColdLaunchWithATurnReadyGivesItToTheGuestBeforeICloudAnswers() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        let guest = ScriptedGuest(home: home, script: [.reply("Shared.")])
        let (harness, _) = harness(db, guest, defaults: defaults)
        await db.stall(true)
        let nonce = harness.willSend("share this link")
        let sending = Task { await harness.retry() }
        try await eventually("the guest's reply, with iCloud still out") { harness.replies[nonce] == "Shared." }
        XCTAssertEqual(guest.inputs, ["share this link"])
        XCTAssertFalse(harness.hasRead)
        await db.stall(false)
        await sending.value
        XCTAssertEqual(harness.turns.suffix(2).map(\.text), ["share this link", "Shared."])
        XCTAssertEqual(guest.inputs.count, 1)
        XCTAssertTrue(harness.replies.isEmpty)
    }

    /// The same launch with iCloud failing every call: the guest answers, the notice says iCloud
    /// is behind, and the retry that gets through saves both.
    func testAColdLaunchWithATurnReadyAndICloudAwayIsAnsweredAndSavedLater() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        let guest = ScriptedGuest(home: home, script: [.reply("Shared.")])
        let (harness, _) = harness(db, guest, defaults: defaults)
        await db.away(true)
        let nonce = harness.willSend("share this link")
        await harness.retry()
        try await eventually("the guest's reply") { harness.replies[nonce] == "Shared." }
        XCTAssertEqual(harness.failure?.source, .sync)
        XCTAssertEqual(harness.unlanded.map(\.nonce), [nonce])
        await db.away(false)
        await harness.retry()
        XCTAssertEqual(harness.turns.suffix(2).map(\.text), ["share this link", "Shared."])
        XCTAssertEqual(guest.inputs.count, 1)
    }

    /// A launch that does not know it was the one answering gives iCloud the lease's patience
    /// first: the guest has nothing while that runs, and the words once it has run out.
    func testALaunchThatDoesNotKnowWhereItStandsGivesICloudItsPatienceThenTheGuestTheWords() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        defaults.set("elsewhere", forKey: "topo.harness.standing")
        let guest = ScriptedGuest(home: home, script: [.reply("Shared.")])
        let (harness, _) = harness(db, guest, defaults: defaults, patience: .milliseconds(300))
        await db.stall(true)
        let nonce = harness.willSend("share this link")
        let sending = Task { await harness.retry() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(guest.inputs.isEmpty, "the guest was given the words before iCloud had its patience")
        try await eventually("the guest's reply, once the patience ran out") { harness.replies[nonce] == "Shared." }
        await db.stall(false)
        await sending.value
        XCTAssertEqual(harness.turns.suffix(2).map(\.text), ["share this link", "Shared."])
        XCTAssertEqual(guest.inputs.count, 1)
    }

    /// A launch on a phone that was a limb to a hub, with iCloud answering: the lease says the
    /// hub holds it, so the words go into the log for the hub and this phone's guest is not asked.
    func testALaunchThatFindsTheHubHoldingTheLeaseSendsTheTurnToTheHub() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        defaults.set("elsewhere", forKey: "topo.harness.standing")
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: Confirms(), sleep: parked)
        let took = try await hub.takeOver()
        guard case .primary = took else { return XCTFail("the hub did not take the lease") }
        let guest = ScriptedGuest(home: home, script: [.reply("never")])
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: Confirms(), sleep: parked))
        await harness.send("share this link")
        XCTAssertTrue(guest.inputs.isEmpty, "a turn the hub answers ran this phone's guest")
        XCTAssertEqual(harness.turns.last?.text, "share this link")
        XCTAssertTrue(harness.unlanded.isEmpty)
        XCTAssertTrue(harness.replies.isEmpty)
    }

    /// The same phone with the lease's call failing: it cannot be asked who holds it, so the
    /// guest answers; when iCloud is back and the hub still holds the lease, the phone hands
    /// back: the words go to the log for the hub, and what its own guest wrote is not drawn.
    func testAPhoneThatWasALimbAnswersWhileTheLeaseCannotBeAskedAndHandsBackAfter() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        defaults.set("elsewhere", forKey: "topo.harness.standing")
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: Confirms(), sleep: parked)
        let took = try await hub.takeOver()
        guard case .primary = took else { return XCTFail("the hub did not take the lease") }
        let guest = ScriptedGuest(home: home, script: [.reply("From the phone.")])
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: Confirms(), sleep: parked))
        await db.away(true)
        let nonce = harness.willSend("share this link")
        await harness.retry()
        try await eventually("the guest's reply") { harness.replies[nonce] == "From the phone." }
        XCTAssertEqual(harness.failure?.source, .sync)

        await db.away(false)
        await harness.retry()
        XCTAssertEqual(harness.turns.last?.text, "share this link", "the words did not reach the log for the hub")
        XCTAssertEqual(harness.turns.last?.role, .person)
        XCTAssertTrue(harness.replies.isEmpty, "this phone's reply is drawn for a turn the hub answers")
        XCTAssertEqual(guest.inputs.count, 1)
    }

    /// Warm, the app back from the background with its runner standing: a turn said while iCloud
    /// is slow is with the guest before the lease or the save has answered.
    func testAWarmPhoneGivesTheGuestTheWordsWhileTheLeaseAndTheSaveAreStillOut() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("Shared.")])
        let (harness, _) = harness(db, guest)
        await harness.send("hello")
        // The chat's loop has read the log, as it does every few seconds while it is open.
        await harness.refresh()
        await db.stall(true)
        let saved = await db.wrapped.writes.count
        let nonce = harness.willSend("share this link")
        let sending = Task { await harness.retry() }
        try await eventually("the guest's reply, with iCloud still out") { harness.replies[nonce] == "Shared." }
        let since = await db.wrapped.writes.count
        XCTAssertEqual(since, saved, "something was saved before the guest answered")
        await db.stall(false)
        await sending.value
        XCTAssertEqual(harness.turns.map(\.text), ["hello", "Hi.", "share this link", "Shared."])
        XCTAssertEqual(guest.inputs.count, 2)
    }

    /// iCloud is away and the guest is not: two messages are each answered, once, with nothing
    /// saved, and when iCloud is back each reply lands after its person's turn under that turn's
    /// nonce, with no second input.
    func testWordsSaidInAnOutageAreAnsweredOnceAndLandInOrderWhenICloudIsBack() async throws {
        let db = Outage()
        let (runner, bridge, guest) = try await launch(db, .reply("Paris."), .reply("Berlin."))
        await db.away(true)
        do {
            _ = try await runner.run("capital of France?", model: .sonnet5, nonce: "n1", known: [])
            XCTFail("a turn was saved with iCloud away")
        } catch TurnRunnerError.unsaved {}
        let second = await runner.hear("and Germany?", model: .sonnet5, nonce: "n2", known: [])
        XCTAssertTrue(second)
        try await eventually("both answers") { await bridge.unsaved() == ["n1": "Paris.", "n2": "Berlin."] }
        XCTAssertEqual(guest.inputs, ["capital of France?", "and Germany?"])
        let waiting = await bridge.current
        XCTAssertEqual(waiting.seen.count, 0, "turns the log does not hold were counted seen")
        XCTAssertNil(waiting.pending)
        let nothing = await db.wrapped.writes.filter { $0.type == Turn.recordType }
        XCTAssertTrue(nothing.isEmpty)

        await db.away(false)
        let first = try await runner.run("capital of France?", model: .sonnet5, nonce: "n1", known: [])
        let next = try await runner.run("and Germany?", model: .sonnet5, nonce: "n2", known: [])
        XCTAssertEqual(guest.inputs.count, 2, "a turn the guest had answered was asked again")
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["capital of France?", "Paris.", "and Germany?", "Berlin."])
        XCTAssertEqual(first.assistant.nonce, TurnRunner.replyNonce(for: [first.person.ref]))
        XCTAssertEqual(next.assistant.parents, [next.person.ref])
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
        XCTAssertEqual(ledger.early, [])
        XCTAssertTrue(turns.allSatisfy { ledger.seen.contains($0.ref) })
        let left = await bridge.unsaved()
        XCTAssertTrue(left.isEmpty)
    }

    /// The usual turn: the save lands while the guest is still writing. The input given ahead is
    /// bound to the turn and its answer is the reply; nothing is sent a second time.
    func testATurnSavedWhileTheGuestIsStillWritingIsAnsweredByTheInputItWasGiven() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .hangUnwritten)
        let asking = Task { try await runner.run("where are my keys?", model: .sonnet5, nonce: "n1", known: []) }
        try await eventually("the turn bound to the input") { await bridge.current.pending?.person == "n1" }
        let pending = await bridge.current.pending
        let bound = try XCTUnwrap(pending)
        XCTAssertEqual(bound.state, .sent)
        let saved = try await log(db)
        let person = try XCTUnwrap(saved.first)
        XCTAssertEqual(bound.nonce, TurnRunner.replyNonce(for: [person.ref]))
        XCTAssertEqual(bound.parents, [person.ref])
        guest.finishHanging(with: "On the hook.")
        let result = try await asking.value
        XCTAssertEqual(result.assistant.text, "On the hook.")
        XCTAssertEqual(guest.inputs, ["where are my keys?"])
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
        XCTAssertTrue(ledger.seen.contains(result.person.ref) && ledger.seen.contains(result.assistant.ref))
    }

    /// The app was killed with the guest on words given ahead, and the guest finished them: the
    /// next launch saves the turn and writes that reply, asking nothing.
    func testACrashBetweenHearingAndSavingWritesTheGuestsReplyWithoutAskingAgain() async throws {
        let db = Outage()
        let (first, firstBridge, _) = try await launch(db, .reply("Paris."))
        await db.away(true)
        _ = try? await first.run("capital of France?", model: .sonnet5, nonce: "n1", known: [])
        try await eventually("the answer") { await firstBridge.unsaved()["n1"] != nil }
        // The record as a launch killed mid-turn leaves it: sent, and nothing known of its end.
        var killed = try GuestLedger.load(ledgerFile)
        killed.early?[0].state = .sent
        killed.early?[0].text = nil
        try killed.save(ledgerFile)
        await db.away(false)

        let (second, bridge, guest) = try await launch(db)
        let result = try await second.run("capital of France?", model: .sonnet5, nonce: "n1", known: [])
        XCTAssertEqual(result.assistant.text, "Paris.")
        XCTAssertTrue(guest.inputs.isEmpty, "the guest was asked again")
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
        XCTAssertEqual(ledger.early, [])
    }

    /// The same crash, found by the next words given ahead rather than by the turn's own retry:
    /// the record is read off the guest's transcript before anything is sent.
    func testAnInputLeftSentByACrashIsReadOffTheTranscriptBeforeTheNextIsGiven() async throws {
        let db = Outage()
        let (first, firstBridge, _) = try await launch(db, .reply("Paris."))
        await db.away(true)
        _ = try? await first.run("capital of France?", model: .sonnet5, nonce: "n1", known: [])
        try await eventually("the answer") { await firstBridge.unsaved()["n1"] != nil }
        var killed = try GuestLedger.load(ledgerFile)
        killed.early?[0].state = .sent
        killed.early?[0].text = nil
        try killed.save(ledgerFile)

        await db.away(false)
        let (_, bridge, guest) = try await launch(db, .reply("Berlin."))
        let heard = await bridge.hear("and Germany?", nonce: "n2", context: [], model: .sonnet5)
        XCTAssertTrue(heard)
        try await eventually("both answers") { await bridge.unsaved() == ["n1": "Paris.", "n2": "Berlin."] }
        XCTAssertEqual(guest.inputs, ["and Germany?"])
    }

    /// Words given ahead that the guest never received are given again by the retry; ones it
    /// received and was cut off on are unresolved once their turn is saved, and never sent again.
    func testWordsNeverReceivedAreGivenAgainAndWordsCutOffAreNot() async throws {
        let db = Outage()
        let (runner, bridge, guest) = try await launch(db, .notReceived("exited"), .cutOff)
        await db.away(true)
        _ = try? await runner.run("first", model: .sonnet5, nonce: "n1", known: [])
        try await eventually("the first input gone") { await bridge.current.early == [] }
        _ = try? await runner.run("first", model: .sonnet5, nonce: "n1", known: [])
        try await eventually("the second input cut off") { await bridge.current.early?.first?.state == .unresolved }
        XCTAssertEqual(guest.inputs, ["first", "first"])

        await db.away(false)
        do {
            _ = try await runner.run("first", model: .sonnet5, nonce: "n1", known: [])
            XCTFail("a turn cut off was answered")
        } catch TurnRunnerError.replyFailed(let person, let underlying) {
            XCTAssertEqual(underlying as? GuestBridgeError, .unresolved)
            let unresolved = await bridge.unresolved()
            XCTAssertEqual(unresolved, [person.ref])
        }
        XCTAssertEqual(guest.inputs.count, 2, "a turn the guest received was sent again")
    }

    /// A reply the guest finished and iCloud refused is owed, and is written before the next
    /// turn even while the guest is on words given after it; an input whose end is not known, or
    /// that was cut off, keeps anything from being given ahead.
    func testAnOwedReplyIsWrittenFirstWhileALaterInputIsWithTheGuest() async throws {
        let db = RefusingReplies()
        let (runner, bridge, guest) = try await launch(db, .reply("Paris."), .hangUnwritten)
        await db.refuse(true)
        _ = try? await runner.run("capital of France?", model: .sonnet5, nonce: "n1", known: [])
        let stuck = await bridge.current.pending
        XCTAssertEqual(stuck?.state, .answered)
        await db.refuse(false)

        let asking = Task { try await runner.run("and Germany?", model: .sonnet5, nonce: "n2", known: []) }
        try await eventually("the owed reply and the next turn") { try await self.log(db).count == 3 }
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["capital of France?", "Paris.", "and Germany?"])
        XCTAssertEqual(turns[2].parents, [turns[1].ref], "the next turn does not continue the owed reply")
        guest.finishHanging(with: "Berlin.")
        _ = try await asking.value
        XCTAssertEqual(guest.inputs, ["capital of France?", "and Germany?"])
    }

    /// Every reply whose turn is saved is one this device owes: the one in `pending`, and one
    /// bound and waiting behind it. The screen keeps both until the log has them.
    func testAReplyBoundAndWaitingBehindAnotherIsOwedToo() async throws {
        let first = TurnRef(device: phone, sequence: 1), second = TurnRef(device: phone, sequence: 2)
        func owed(_ input: String, _ ref: TurnRef, _ person: String, _ text: String) -> GuestLedger.Pending {
            GuestLedger.Pending(input: input, nonce: TurnRunner.replyNonce(for: [ref]), parents: [ref], answering: [ref],
                                covers: Coverage(), session: "S1", sentAt: Date(), state: .answered, text: text,
                                person: person, said: [person])
        }
        var ledger = GuestLedger()
        ledger.session = "S1"
        ledger.pending = owed("in-1", first, "n1", "Paris.")
        ledger.early = [GuestLedger.Early(person: "n2", input: "in-2", covers: Coverage(), session: "S1", sentAt: Date(),
                                          state: .answered, text: "Berlin.", bound: owed("in-2", second, "n2", "Berlin.")),
                        GuestLedger.Early(person: "n3", input: "in-3", covers: Coverage(), session: "S1", sentAt: Date(),
                                          state: .answered, text: "Rome.")]
        try FileManager.default.createDirectory(at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: ledgerFile)
        let (_, bridge, _) = try await launch(InMemoryRecordDatabase())
        let owedAhead = await bridge.owedAhead()
        XCTAssertEqual(owedAhead, ["n1", "n2"])
        let unsaved = await bridge.unsaved()
        XCTAssertEqual(unsaved, ["n1": "Paris.", "n2": "Berlin.", "n3": "Rome."])
    }

    func testNothingIsGivenAheadOverAnInputCutOff() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .cutOff)
        _ = try? await runner.run("delete the drafts", model: .sonnet5)
        let cutOff = await bridge.current.pending
        XCTAssertEqual(cutOff?.state, .unresolved)
        let heard = await bridge.hear("and the bins", nonce: "n2", context: [], model: .sonnet5)
        XCTAssertFalse(heard)
        XCTAssertEqual(guest.inputs.count, 1)
    }

    /// What an input given ahead told the guest is fixed when it is sent: a limb's turn that
    /// reached the log before the save is not counted seen with it, and goes with the next input.
    func testATurnThatLandedBetweenTheWordsAndTheirSaveIsToldWithTheNextInput() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("Noted."), .reply("And noted."), .reply("No."))
        _ = try await runner.run("hello", model: .sonnet5)
        let known = try await log(db)
        let heard = await runner.hear("buy milk", model: .sonnet5, nonce: "n2", known: known)
        XCTAssertTrue(heard)
        let limb = try await write(db, .person, "from the watch", device: "watch")
        _ = try await runner.run("buy milk", model: .sonnet5, nonce: "n2", known: known)
        let seen = await bridge.current.seen
        XCTAssertFalse(seen.contains(limb.ref), "a turn the guest was never told was counted seen")
        _ = try await runner.run("anything else?", model: .sonnet5)
        XCTAssertTrue(guest.inputs.last?.contains("from the watch") == true, guest.inputs.last ?? "")
    }

    /// Words given ahead whose turn another device answered: the guest received them, so they
    /// are not told again, and what it made of them is never written.
    func testWordsGivenAheadAndAnsweredElsewhereAreCountedSeenAndTheirReplyIsNotWritten() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("mine"), .reply("ok"))
        let heard = await bridge.hear("what time is it?", nonce: "n1", context: [], model: .sonnet5)
        XCTAssertTrue(heard)
        try await eventually("the answer") { await bridge.unsaved()["n1"] == "mine" }
        // The words went into the log as a limb's, and the hub answered them.
        let log = TurnLog(database: db)
        let person = try await log.writer(for: phone).append(.person, "what time is it?", parents: [], nonce: "n1")
        try await write(db, .assistant, "the hub's", device: "hub")

        _ = try await runner.run("thanks", model: .sonnet5)
        let turns = try await self.log(db)
        XCTAssertEqual(turns.map(\.text), ["what time is it?", "the hub's", "thanks", "ok"])
        let told = try XCTUnwrap(guest.inputs.last)
        XCTAssertTrue(told.contains("the hub's"), told)
        XCTAssertFalse(told.contains("Them: what time is it?"), told)
        let ledger = await bridge.current
        XCTAssertEqual(ledger.early, [])
        XCTAssertTrue(ledger.seen.contains(person.ref))
    }

    /// Sign-out with the guest on words given ahead: nothing of them is recorded or kept after.
    func testSignOutWhileTheGuestIsOnWordsGivenAheadKeepsNothing() async throws {
        let db = Outage()
        let (runner, bridge, guest) = try await launch(db, .hangUnwritten)
        await db.away(true)
        _ = try? await runner.run("remember this", model: .sonnet5, nonce: "n1", known: [])
        let sent = await bridge.current.early?.first?.state
        XCTAssertEqual(sent, .sent)
        await bridge.forget()
        guest.finishHanging(with: "Remembered.")
        try await Task.sleep(for: .milliseconds(100))
        let ledger = await bridge.current
        XCTAssertNil(ledger.early)
        XCTAssertNil(ledger.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a ledger was written after the sign-out")
        let left = await bridge.unsaved()
        XCTAssertTrue(left.isEmpty)
    }

    func testWordsTakenBackAreForgotten() async throws {
        let db = Outage()
        let (runner, bridge, _) = try await launch(db, .reply("Paris."))
        await db.away(true)
        _ = try? await runner.run("capital of France?", model: .sonnet5, nonce: "n1", known: [])
        try await eventually("the answer") { await bridge.unsaved()["n1"] != nil }
        await bridge.withdrawn(nonce: "n1")
        let ledger = await bridge.current
        XCTAssertEqual(ledger.early, [])
    }

    func testALedgerWrittenBeforeWordsWereGivenAheadStillReads() throws {
        let old = #"{"seen":{"runs":{}},"pending":{"input":"i","nonce":"n","parents":[],"answering":[],"covers":{"runs":{}},"sentAt":0,"state":"sent","askAgain":false}}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: ledgerFile)
        let ledger = try GuestLedger.load(ledgerFile)
        XCTAssertEqual(ledger.pending?.state, .sent)
        XCTAssertNil(ledger.pending?.text)
        XCTAssertNil(ledger.early)
    }

    // MARK: The row

    /// iCloud is away: the words stay on the line, the reply is drawn under them as it is written
    /// and stays once whole, across the next message's start; the notice says iCloud is behind and
    /// nothing is told failed. When iCloud is back the log's turns replace all of it.
    func testAnUnsavedTurnsWordsAndReplyStayDrawnUntilTheyLand() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Paris."), .hangWriting("Ber")])
        let (harness, _) = harness(db, guest)
        await harness.refresh()
        await harness.answerPending()
        var failed: [String] = []
        harness.onTurnFailed = { failed.append($0) }
        await db.away(true)

        let first = harness.willSend("capital of France?")
        await harness.retry()
        try await eventually("the first reply") { harness.replies[first] == "Paris." }
        XCTAssertEqual(harness.failure?.source, .sync)
        XCTAssertEqual(harness.unlanded.map(\.nonce), [first])
        XCTAssertTrue(harness.turns.isEmpty)

        let second = harness.willSend("and Germany?")
        await harness.retry()
        try await eventually("the second being written") { harness.replies[second] == "Ber" }
        XCTAssertEqual(harness.replies[first], "Paris.", "a finished reply went when the next began")
        XCTAssertTrue(harness.writingAhead)
        XCTAssertEqual(NextTurn().queued(in: harness).before.map(\.reply?.text), ["Paris.", "Ber"])
        // The row that holds the first draws its reply under itself, and the second's below.
        let row = NextTurn()
        XCTAssertTrue(row.resume(from: harness))
        XCTAssertEqual(row.answer(in: harness)?.text, "Paris.")
        XCTAssertEqual(row.queued(in: harness).after.map(\.reply?.text), ["Ber"])
        XCTAssertTrue(row.behind(in: harness).isEmpty)

        guest.finishHanging(with: "Berlin.")
        try await eventually("the second reply") { harness.replies[second] == "Berlin." }
        await db.away(false)
        await harness.retry()
        XCTAssertEqual(harness.turns.map(\.text), ["capital of France?", "Paris.", "and Germany?", "Berlin."])
        XCTAssertTrue(harness.replies.isEmpty, "a landed reply is still drawn as unsaved")
        XCTAssertTrue(harness.unlanded.isEmpty)
        XCTAssertNil(harness.failure)
        XCTAssertEqual(guest.inputs.count, 2)
        XCTAssertEqual(failed, [first, second], "each wait for a reply to land ends once, when the guest is done")
    }

    /// The person's turn landed and the reply's save did not: the reply stays drawn, and the
    /// next pass writes it.
    func testAReplyWhoseSaveFailedStaysDrawnAndIsWrittenByTheNextPass() async throws {
        let db = RefusingReplies()
        let guest = ScriptedGuest(home: home, script: [.reply("Paris.")])
        let (harness, _) = harness(db, guest)
        await harness.refresh()
        await harness.answerPending()
        await db.refuse(true)
        let nonce = harness.willSend("capital of France?")
        await harness.retry()
        XCTAssertEqual(harness.turns.map(\.text), ["capital of France?"])
        XCTAssertEqual(harness.replies[nonce], "Paris.", "a reply iCloud refused was dropped from the screen")
        XCTAssertEqual(NextTurn().behind(in: harness).map(\.text), ["Paris."])
        XCTAssertEqual(harness.failure?.source, .sync)
        await db.refuse(false)
        await harness.answerPending()
        XCTAssertEqual(harness.turns.map(\.text), ["capital of France?", "Paris."])
        XCTAssertTrue(harness.replies.isEmpty)
        XCTAssertEqual(guest.inputs.count, 1)
    }

    /// Sign-out with words given ahead and unsaved: the screen keeps none of it.
    /// A launch whose runner is made while the guest is still coming up, with no read of the log
    /// yet: the turn is saved before the guest has the words it was already being given, and is
    /// answered by that one input.
    func testATurnSavedWhileTheGuestIsStillComingUpIsGivenToItOnce() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        let guest = ScriptedGuest(home: home, script: [.reply("Shared."), .reply("Shared again.")])
        guest.holdReady()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.willSend("share this link")
        let sending = Task { await harness.retry() }
        try await eventually("the person's turn in the log") { try await self.log(db).last?.text == "share this link" }
        try await eventually("the guest asked for") { guest.readyHeld }
        guest.releaseReady()
        await sending.value
        XCTAssertEqual(guest.inputs, ["share this link"])
        let turns = try await log(db)
        XCTAssertEqual(turns.suffix(2).map(\.text), ["share this link", "Shared."])
    }

    /// Where the phone stood with the lease goes with a sign-out, and a turn in flight across
    /// it does not write it back.
    func testASignOutWithATurnInFlightKeepsNoStanding() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        let (harness, _) = harness(db, ScriptedGuest(home: home, script: [.reply("late")]), defaults: defaults)
        await harness.refresh()
        await harness.answerPending()
        await db.stall(true)
        harness.willSend("from before the sign-out")
        let sending = Task { await harness.retry() }
        try await Task.sleep(for: .milliseconds(100))
        await harness.forget()
        await db.stall(false)
        await sending.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(defaults.string(forKey: "topo.harness.standing"))
    }

    /// The same at a demotion, with the turn saved and the guest still on it.
    func testADemotionWithATurnInFlightKeepsNoStanding() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        let guest = ScriptedGuest(home: home, script: [.hangUnwritten])
        let (harness, _) = harness(db, guest, defaults: defaults)
        await harness.refresh()
        let sending = Task { await harness.send("still being answered") }
        try await eventually("the turn saved and with the guest") {
            try await self.log(db).last?.text == "still being answered" && guest.inputs.count == 1
        }
        await harness.demote()
        guest.finishHanging(with: "late")
        await sending.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(defaults.string(forKey: "topo.harness.standing"))
    }

    /// A sign-out while the lease is still being asked: the brain is given nothing when the
    /// lease answers, and nothing is recorded for the login that follows.
    func testASignOutWhileTheLeaseIsAskedGivesTheGuestNothing() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("late")])
        let (harness, bridge) = harness(db, guest)
        await harness.refresh()
        await harness.answerPending()
        await db.stall(true)
        harness.willSend("from before the sign-out")
        let sending = Task { await harness.retry() }
        try await Task.sleep(for: .milliseconds(100))
        await harness.forget()
        await db.stall(false)
        await sending.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(guest.inputs.isEmpty, "words from before the sign-out reached the guest: \(guest.inputs)")
        let ledger = await bridge.current
        XCTAssertNil(ledger.early)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a ledger was written after the sign-out")
        XCTAssertTrue(harness.replies.isEmpty)
    }

    /// A turn the guest was given as words, in the log by the time the next words are given: it
    /// is not told back to the guest as another device's turn.
    func testWordsGivenAheadAreNotToldBackAsAnotherDevicesTurn() async throws {
        let db = InMemoryRecordDatabase()
        let (_, bridge, guest) = try await launch(db, .reply("Paris."), .reply("Berlin."))
        let heard = await bridge.hear("capital of France?", nonce: "n1", context: [], model: .sonnet5)
        XCTAssertTrue(heard)
        try await eventually("the answer") { await bridge.unsaved()["n1"] == "Paris." }
        let person = try await TurnLog(database: db).writer(for: phone).append(.person, "capital of France?", parents: [], nonce: "n1")
        let next = await bridge.hear("and Germany?", nonce: "n2", context: [person], model: .sonnet5)
        XCTAssertTrue(next)
        XCTAssertEqual(guest.inputs.last, "and Germany?")
    }

    /// The harness's half: a hub takes the lease while two messages wait behind slow iCloud. The
    /// first was given to the guest as the phone that answered; the second never is.
    func testALineBehindATurnTheHubAnswersIsNotGivenToThisPhonesGuest() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("never")])
        let (harness, bridge) = harness(db, guest)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: Confirms(), sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: Confirms(), sleep: parked)
        let took = try await hub.takeOver()
        guard case .primary = took else { return XCTFail("the hub did not take the lease") }
        await db.stall(true)
        harness.willSend("first")
        harness.willSend("second")
        let sending = Task { await harness.retry() }
        try await eventually("the first with the guest") { guest.inputs.count == 2 }
        await db.stall(false)
        await sending.value
        XCTAssertEqual(harness.turns.suffix(2).map(\.text), ["first", "second"])
        guest.finishHanging(with: "the phone's")
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(guest.inputs, ["hello", "first"])
        XCTAssertTrue(harness.replies.isEmpty)
        _ = bridge
    }

    /// A phone that answered finds a hub's lease it cannot confirm, so its words go to the log
    /// as a limb's with its guest already on them. The hub never answers and its lease lapses:
    /// the phone answers the turn with the reply its guest made, asked once.
    func testAPhoneThatComesToAnswerATurnItHandedBackWritesTheReplyItsGuestMade() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("the phone's answer"), .reply("a second answer"))
        let heard = await bridge.hear("what time is it?", nonce: "n1", context: [], model: .sonnet5)
        XCTAssertTrue(heard)
        try await eventually("the answer") { await bridge.unsaved()["n1"] == "the phone's answer" }
        _ = try await TurnLog(database: db).writer(for: phone).append(.person, "what time is it?", parents: [], nonce: "n1")
        _ = try await runner.answerPending(model: .sonnet5)
        XCTAssertEqual(guest.inputs, ["what time is it?"])
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["what time is it?", "the phone's answer"])
    }

    /// The same through the harness: a hub takes the lease and goes, the phone that answered
    /// cannot confirm it, so its words go to the log as a limb's with its guest already on
    /// them. When the hub's lease lapses the phone's pass writes the reply its guest made, asked
    /// once, and the line is given ahead again from there.
    func testAPhoneThatHandsATurnBackAndThenAnswersItAsksItsGuestOnce() async throws {
        let db = Outage()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("the phone's answer"),
                                                       .reply("third"), .reply("fourth")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        let took = try await hub.takeOver()
        guard case .primary = took else { return XCTFail("the hub did not take the lease") }

        harness.willSend("what time is it?")
        await harness.retry()
        try await eventually("the guest done with the words") { guest.inputs.count == 2 }
        XCTAssertEqual(harness.turns.last?.text, "what time is it?")
        XCTAssertEqual(harness.turns.last?.role, .person)
        XCTAssertTrue(harness.replies.isEmpty, "this phone's reply is drawn for a turn another device holds")

        clock.advance(11)
        await harness.answerPending()
        XCTAssertEqual(guest.inputs.count, 2, "the guest was asked the same words again")
        XCTAssertEqual(harness.turns.last?.text, "the phone's answer")

        // The lease is the phone's again: two more messages are both with the guest ahead of iCloud.
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.stall(true)
        let third = harness.willSend("and now?")
        let fourth = harness.willSend("and then?")
        let sending = Task { await harness.retry() }
        try await eventually("both answered with iCloud out") {
            harness.replies[third] == "third" && harness.replies[fourth] == "fourth"
        }
        await db.stall(false)
        await sending.value
        XCTAssertEqual(harness.turns.suffix(4).map(\.text), ["and now?", "third", "and then?", "fourth"])
        XCTAssertEqual(guest.inputs.count, 4)
    }

    /// An input asked once its turn was saved, its reply still owed the log: a launch with no
    /// read is not given the same words ahead.
    func testWordsAnOwedReplyAnswersAreNotGivenAheadByTheNextLaunch() async throws {
        let db = Outage()
        let (runner, _, guest) = try await launch(db, .reply("Paris."))
        _ = try await runner.run("warm up", model: .sonnet5, nonce: "n0")
        guest.then(.reply("Berlin."), .reply("again"))
        await db.refuseReplies(true)
        _ = try? await runner.run("and Germany?", model: .sonnet5, nonce: "n1")
        let (_, relaunched, again) = try await launch(db, .reply("again"))
        let pending = await relaunched.current.pending
        XCTAssertEqual(pending?.state, .answered)
        let heard = await relaunched.hear("and Germany?", nonce: "n1", context: nil, model: .sonnet5)
        XCTAssertTrue(heard, "words the guest has answered were not held as heard")
        XCTAssertTrue(again.inputs.isEmpty)
    }

    /// A launch with no read of the log does not give the guest words whose reply the ledger
    /// last knew in the log: the outbox kept them only because the app was killed first.
    func testWordsWhoseReplyLandedAreNotGivenAgainByALaunchWithNoRead() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("Paris."), .reply("again"))
        _ = try await runner.run("capital of France?", model: .sonnet5, nonce: "n1", known: [])
        let heard = await bridge.hear("capital of France?", nonce: "n1", context: nil, model: .sonnet5)
        XCTAssertFalse(heard)
        XCTAssertEqual(guest.inputs.count, 1)
        // And the same for a turn that was asked only once it was saved.
        guest.then(.reply("Berlin."))
        _ = try await runner.run("and Germany?", model: .sonnet5, nonce: "n2")
        let second = await bridge.hear("and Germany?", nonce: "n2", context: nil, model: .sonnet5)
        XCTAssertFalse(second)
    }

    /// The guest's session is lost between two messages of an outage: what the first input told
    /// the old session is not counted seen by the new one when its reply lands.
    func testAnInputFromASessionTheGuestLeftCountsNothingSeenWhenItLands() async throws {
        let db = Outage()
        let (runner, bridge, guest) = try await launch(db, .reply("Hi."), .reply("one"), .reply("two"), .reply("three"))
        _ = try await runner.run("hello", model: .sonnet5)
        let known = try await log(db)
        await db.away(true)
        _ = try? await runner.run("first", model: .sonnet5, nonce: "n1", known: known)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "one" }
        guest.startFresh()
        let heard = await runner.hear("second", model: .sonnet5, nonce: "n2", known: known)
        XCTAssertTrue(heard)
        try await eventually("the second answer") { await bridge.unsaved()["n2"] == "two" }
        await db.away(false)
        let first = try await runner.run("first", model: .sonnet5, nonce: "n1", known: known)
        _ = try await runner.run("second", model: .sonnet5, nonce: "n2", known: known)
        let ledger = await bridge.current
        XCTAssertEqual(ledger.session, "S-fresh-1")
        XCTAssertFalse(ledger.seen.contains(first.assistant.ref), "a reply the new session never saw was counted seen")
        _ = try await runner.run("third", model: .sonnet5)
        XCTAssertTrue(guest.inputs.last?.contains("one") == true, guest.inputs.last ?? "")
    }

    /// A session begun by words given ahead is the one the next words are given to: they are
    /// not told the conversation so far a second time.
    func testASecondInputToASessionTheFirstBeganIsNotToldTheConversationAgain() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("Hi."), .reply("one"), .reply("two"))
        _ = try await runner.run("hello", model: .sonnet5)
        let known = try await log(db)
        guest.startFresh()
        _ = await bridge.hear("first", nonce: "n1", context: known, model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "one" }
        _ = await bridge.hear("second", nonce: "n2", context: known, model: .sonnet5)
        XCTAssertEqual(guest.inputs.last, "second")
    }

    /// An input a killed launch recorded and never sent is not held as heard: the next launch
    /// reads the transcript, finds the guest never had it, and gives the words.
    func testWordsRecordedAndNeverSentAreGivenByTheNextLaunch() async throws {
        let db = InMemoryRecordDatabase()
        var ledger = GuestLedger()
        ledger.session = "S1"
        ledger.early = [GuestLedger.Early(person: "n1", input: UUID().uuidString.lowercased(), covers: Coverage(), session: "S1",
                                          sentAt: Date(), state: .sent)]
        try FileManager.default.createDirectory(at: ledgerFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(ledger).write(to: ledgerFile)
        let (_, bridge, guest) = try await launch(db, .reply("Paris."))
        let heard = await bridge.hear("capital of France?", nonce: "n1", context: nil, model: .sonnet5)
        XCTAssertTrue(heard)
        XCTAssertEqual(guest.inputs, ["capital of France?"])
    }

    func testSignOutForgetsWhatWasGivenAhead() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Paris.")])
        let (harness, bridge) = harness(db, guest)
        await harness.refresh()
        await harness.answerPending()
        await db.away(true)
        let nonce = harness.willSend("capital of France?")
        await harness.retry()
        try await eventually("the reply") { harness.replies[nonce] == "Paris." }
        await harness.forget()
        XCTAssertTrue(harness.replies.isEmpty)
        let left = await bridge.unsaved()
        XCTAssertTrue(left.isEmpty)
        await db.away(false)
        await harness.refresh()
        XCTAssertTrue(harness.turns.isEmpty, "words from before a sign-out reached the log")
    }
}

/// The in-memory log behind a link that can go: while away, every call fails `unavailable` and
/// nothing reaches the store.
private actor Outage: RecordDatabase {
    let wrapped = InMemoryRecordDatabase()
    private var gone = false
    private var stalled = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func away(_ on: Bool) { gone = on }

    /// Refuses every save that carries an assistant's turn: the reply's batch fails, the rest lands.
    private var noReplies = false
    func refuseReplies(_ on: Bool) { noReplies = on }

    /// While stalled every call waits, answered by nothing: iCloud slow rather than failing.
    func stall(_ on: Bool) {
        stalled = on
        guard !on else { return }
        held.forEach { $0.resume() }
        held = []
    }

    private func reach() async throws {
        if stalled { await withCheckedContinuation { held.append($0) } }
        if gone { throw RecordDatabaseError.unavailable(underlying: Refused()) }
    }

    func save(_ records: [Record]) async throws -> [Record] {
        try await reach()
        if noReplies, records.contains(where: { $0.type == Turn.recordType && $0.fields["role"] == .string(TurnRole.assistant.rawValue) }) {
            throw RecordDatabaseError.unavailable(underlying: Refused())
        }
        return try await wrapped.save(records)
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await reach(); return try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await reach(); return try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await reach(); return try await wrapped.records(ofType: type) }
}

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
    var acknowledgementStillToLose: Bool { loseNext }

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

/// A wait the test opens: whoever passes it waits until `open`.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Bool { !waiters.isEmpty }

    func pass() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private let parked: @Sendable (TimeInterval) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }

/// A lease whose clocks stand still, so it never lapses under a runner however long a step takes:
/// these suites are about the bridge, and a lease lapsing on a slow host would fail a reply's
/// append as displaced — nothing written — and read as the bridge's fault.
private func steadyLease(_ database: any RecordDatabase, _ device: DeviceID) -> PrimaryLease {
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    return PrimaryLease(database: database, device: device, endpoint: nil, probe: NoSocketProbe(),
                        now: { epoch }, monotonic: { 0 }, sleep: parked)
}

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

/// The lease's two clocks, moved together by the test.
private final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var passed: TimeInterval = 1_000
    var elapsed: TimeInterval { lock.withLock { passed } }
    var wall: Date { Date(timeIntervalSince1970: 1_800_000_000 + elapsed) }
    func advance(_ seconds: TimeInterval) { lock.withLock { passed += seconds } }
}

private struct Confirms: LeaseProbe {
    func confirms(_ lease: Lease) async -> Bool { true }
}
// MARK: - Words given ahead: hand-backs, withdrawals and relaunches

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var value: Bool { lock.withLock { on } }
    func set() { lock.withLock { on = true } }
}

/// Reads get through and every save is refused: a lease call or a save that fails with the log readable.
private actor SavesRefused: RecordDatabase {
    let wrapped = InMemoryRecordDatabase()
    private var refusing = false
    func refuse(_ on: Bool) { refusing = on }
    func save(_ records: [Record]) async throws -> [Record] {
        if refusing { throw RecordDatabaseError.unavailable(underlying: Refused()) }
        return try await wrapped.save(records)
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await wrapped.records(ofType: type) }
}

extension GuestBridgeTests {

    // Recipe 1, `.contended`: the lease is abandoned while acquire is stalled.
    func testContendedHandBackThenThePassAsksOnce() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("the phone's answer"), .reply("SECOND INPUT")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        let lease = PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(), sleep: parked)
        harness.adopt(lease)
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.stall(true)
        let nonce = harness.willSend("what time is it?")
        let sending = Task { await harness.retry() }
        try await eventually("answered ahead") { harness.replies[nonce] == "the phone's answer" }
        await lease.abandon()
        await db.stall(false)
        await sending.value
        XCTAssertEqual(harness.turns.last?.text, "what time is it?")
        XCTAssertEqual(harness.turns.last?.role, .person)
        await harness.answerPending()
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs.count, 2, "the guest was asked the same words again")
        XCTAssertEqual(turns.map(\.text), ["hello", "Hi.", "what time is it?", "the phone's answer"])
        XCTAssertEqual(turns.last?.nonce, TurnRunner.replyNonce(for: [turns[2].ref]))
    }

    // Recipe 1 with the guest still on the words at the hand-back and when the pass asks.
    func testHandBackWhileTheGuestIsStillWritingThenThePassAsksOnce() async throws {
        let db = Outage()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("SECOND INPUT")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        _ = try await hub.takeOver()
        harness.willSend("what time is it?")
        await harness.retry()
        try await eventually("the guest on the words") { guest.inputs.count == 2 }
        XCTAssertEqual(harness.turns.last?.role, .person)
        clock.advance(11)
        let done = Flag()
        let pass = Task { await harness.answerPending(); done.set() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(done.value, "the pass returned while the guest was still writing")
        XCTAssertEqual(guest.inputs.count, 2)
        guest.finishHanging(with: "the phone's answer")
        try await eventually("the pass returned") { done.value }
        await pass.value
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs.count, 2)
        XCTAssertEqual(turns.map(\.text), ["hello", "Hi.", "what time is it?", "the phone's answer"])
    }

    // Recipe 1 across a relaunch between the hand-back and the pass.
    func testHandBackThenRelaunchThenThePassAsksNothing() async throws {
        let db = Outage()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("the phone's answer")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        _ = try await hub.takeOver()
        let nonce = harness.willSend("what time is it?")
        await harness.retry()
        try await eventually("the guest done") { await harness.guest?.unsaved()[nonce] == "the phone's answer" }
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "elsewhere" }

        let again = ScriptedGuest(home: home, script: [.reply("SECOND INPUT")])
        let (relaunched, _) = self.harness(db, again, defaults: defaults)
        relaunched.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                      now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await relaunched.refresh()
        clock.advance(11)
        await relaunched.answerPending()
        let turns = try await log(db)
        XCTAssertTrue(again.inputs.isEmpty, "the relaunch asked the guest again: \(again.inputs)")
        XCTAssertEqual(turns.map(\.text), ["hello", "Hi.", "what time is it?", "the phone's answer"])
    }

    // Two messages, both answered ahead, both handed back; the hub never answers, the phone does.
    func testTwoMessagesHandedBackThenAnsweredHere() async throws {
        let db = Outage()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("answer one"), .reply("answer two"), .reply("EXTRA")])
        let defaults = makeDefaults()
        let (harness, bridge) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        _ = try await hub.takeOver()
        await db.stall(true)
        let n1 = harness.willSend("first question")
        let n2 = harness.willSend("second question")
        let sending = Task { await harness.retry() }
        try await eventually("both answered ahead") { harness.replies[n1] == "answer one" && harness.replies[n2] == "answer two" }
        await db.stall(false)
        await sending.value
        clock.advance(11)
        await harness.answerPending()
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs.count, 3)
        // The log moved past the first message before this phone answered: its reply is not written.
        XCTAssertEqual(turns.suffix(3).map(\.text), ["first question", "second question", "answer two"])

        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let again = ScriptedGuest(home: home, script: [.reply("answer three"), .reply("EXTRA")])
        let (relaunched, bridge2) = self.harness(db, again, defaults: defaults)
        relaunched.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                      now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await relaunched.refresh()
        XCTAssertTrue(relaunched.replies.isEmpty, "a relaunch draws a reply the log moved past: \(relaunched.replies)")
        await relaunched.send("third question")
        await relaunched.refresh()
        let ledger = await bridge2.current
        XCTAssertEqual(ledger.early ?? [], [], "an input the log moved past is still kept")
        XCTAssertTrue(relaunched.replies.isEmpty, "still drawn after another whole turn: \(relaunched.replies)")
    }

    // Words taken back while on their way stop.
    func testWordsTakenBackWhileOnTheirWayStop() async throws {
        let db = InMemoryRecordDatabase()
        let (_, bridge, guest) = try await launch(db, .hangUnwritten, .reply("never"))
        let first = await bridge.hear("first", nonce: "n1", context: [], model: .sonnet5)
        XCTAssertTrue(first)
        let second = Task { await bridge.hear("second", nonce: "n2", context: [], model: .sonnet5) }
        try await Task.sleep(for: .milliseconds(50))
        await bridge.withdrawn(nonce: "n2")
        guest.finishHanging(with: "done")
        let heard = await second.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(heard)
        XCTAssertEqual(guest.inputs, ["first"])
    }

    // The same through the person's own withdrawal: the line stopped with the log readable,
    // the second message still waiting for the guest to finish the first.
    func testAPersonsWithdrawalWhileTheWordsWaitForTheGuest() async throws {
        let db = SavesRefused()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("to the withdrawn words"), .reply("EXTRA")])
        let defaults = makeDefaults()
        let (harness, bridge) = harness(db, guest, defaults: defaults)
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.refuse(true)
        harness.willSend("first")
        let n2 = harness.willSend("second")
        await harness.retry()
        XCTAssertEqual(guest.inputs, ["hello", "first"])
        let took = await harness.withdraw(n2)
        XCTAssertTrue(took, "the withdrawal was refused")
        XCTAssertEqual(harness.owed.map(\.text), ["first"])
        guest.finishHanging(with: "first's answer")
        try await Task.sleep(for: .milliseconds(300))
        let ledger = await bridge.current
        await harness.refresh()
        XCTAssertEqual(guest.inputs, ["hello", "first"], "words the person took back were given to the guest after")
        XCTAssertFalse((ledger.early ?? []).contains { $0.person == n2 }, "the ledger keeps an input for words no turn will carry")
    }

    // Coverage: the phone's guest answered ahead, the hub answered the turn under the same nonce.
    private func hubReplyCoverage(heardAhead: Bool) async throws -> (told: String, counted: Bool) {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply(heardAhead ? "the phone's answer" : "ok"), .reply("ok"))
        if heardAhead {
            let heard = await bridge.hear("what time is it?", nonce: "n1", context: [], model: .sonnet5)
            XCTAssertTrue(heard)
            try await eventually("the answer") { await bridge.unsaved()["n1"] == "the phone's answer" }
        }
        let person = try await TurnLog(database: db).writer(for: phone).append(.person, "what time is it?", parents: [], nonce: "n1")
        let hubs = try await TurnLog(database: db).writer(for: DeviceID("hub"))
            .append(.assistant, "the hub's answer", parents: [person.ref], nonce: TurnRunner.replyNonce(for: [person.ref]))
        // The limb write's acknowledgement was lost, so the words are still on the line: sent again.
        let result = try await runner.run("what time is it?", model: .sonnet5, nonce: "n1", known: try await log(db))
        XCTAssertEqual(result.assistant.text, "the hub's answer")
        let counted = await bridge.current.seen.contains(hubs.ref)
        _ = try await runner.run("thanks", model: .sonnet5)
        return (guest.inputs.last ?? "", counted)
    }

    func testControl_NoWordsAheadTheHubsReplyIsTold() async throws {
        let (told, counted) = try await hubReplyCoverage(heardAhead: false)
        XCTAssertFalse(counted)
        XCTAssertTrue(told.contains("the hub's answer"), told)
    }

    func testWordsAheadTheHubsReplyIsTold() async throws {
        let (told, counted) = try await hubReplyCoverage(heardAhead: true)
        XCTAssertFalse(counted, "the hub's reply is counted seen though the guest was never told it")
        XCTAssertTrue(told.contains("the hub's answer"), told)
    }

    // A hear that was not cancelled, following one that was.
    func testAHearFollowingACancelledOne() async throws {
        let db = InMemoryRecordDatabase()
        let (_, bridge, guest) = try await launch(db, .hangUnwritten, .reply("later"))
        _ = await bridge.hear("first", nonce: "n1", context: [], model: .sonnet5)
        let owner = Task { await bridge.hear("second", nonce: "n2", context: [], model: .sonnet5) }
        try await Task.sleep(for: .milliseconds(50))
        owner.cancel()
        let follower = Task { await bridge.hear("second", nonce: "n2", context: [], model: .sonnet5) }
        try await Task.sleep(for: .milliseconds(50))
        guest.finishHanging(with: "done")
        _ = await owner.value
        let b = await follower.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(b, "a hear nobody cancelled was told the words were not begun")
    }

    // The answer-side bind: an Early mid-flight, a hear waiting on the slot, a cancelled hear.
    func testAnAnswerForAnEarlyStillInFlightReal() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .hangUnwritten, .reply("SECOND"))
        let heard = await bridge.hear("q", nonce: "n1", context: [], model: .sonnet5)
        XCTAssertTrue(heard)
        _ = try await TurnLog(database: db).writer(for: phone).append(.person, "q", parents: [], nonce: "n1")
        let done = Flag()
        let pass = Task { let turn = try await runner.answerPending(model: .sonnet5); done.set(); return turn }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(guest.inputs, ["q"])
        guest.finishHanging(with: "A")
        try await eventually("the pass returned") { done.value }
        _ = try await pass.value
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs, ["q"])
        XCTAssertEqual(turns.map(\.text), ["q", "A"])
    }

    func testAnAnswerWhileItsHearWaitsForTheSlot() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .hangUnwritten, .reply("B"), .reply("EXTRA"))
        _ = await bridge.hear("first", nonce: "n1", context: [], model: .sonnet5)
        let waiting = Task { await bridge.hear("second", nonce: "n2", context: [], model: .sonnet5) }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await TurnLog(database: db).writer(for: phone).append(.person, "second", parents: [], nonce: "n2")
        let done = Flag()
        let pass = Task { let turn = try await runner.answerPending(model: .sonnet5); done.set(); return turn }
        try await Task.sleep(for: .milliseconds(150))
        guest.finishHanging(with: "A")
        try await eventually("the pass returned") { done.value }
        _ = try await pass.value
        _ = await waiting.value
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs, ["first", "second"])
        XCTAssertEqual(turns.map(\.text), ["second", "B"])
    }

    func testAnAnswerWhileItsHearWaitsForTheSlotAndIsCancelled() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .hangUnwritten, .reply("B"), .reply("EXTRA"))
        _ = await bridge.hear("first", nonce: "n1", context: [], model: .sonnet5)
        let waiting = Task { await bridge.hear("second", nonce: "n2", context: [], model: .sonnet5) }
        try await Task.sleep(for: .milliseconds(50))
        _ = try await TurnLog(database: db).writer(for: phone).append(.person, "second", parents: [], nonce: "n2")
        let done = Flag()
        let pass = Task { let turn = try await runner.answerPending(model: .sonnet5); done.set(); return turn }
        try await Task.sleep(for: .milliseconds(150))
        waiting.cancel()
        guest.finishHanging(with: "A")
        try await eventually("the pass returned") { done.value }
        _ = try await pass.value
        _ = await waiting.value
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs, ["first", "second"])
        XCTAssertEqual(turns.map(\.text), ["second", "B"])
        // And the slot is free: another turn goes through.
        let more = await bridge.hear("third", nonce: "n3", context: turns, model: .sonnet5)
        XCTAssertTrue(more)
    }

    // Recipe 4 through the harness: a plain answer whose reply save was refused, a relaunch
    // with the words still on the line and iCloud away, then iCloud back.
    func testAnOwedPlainReplyAcrossARelaunchInAnOutage() async throws {
        let db = Outage()
        let defaults = makeDefaults()
        let guest = ScriptedGuest(home: home, script: [.reply("Berlin."), .reply("EXTRA")])
        let (first, _) = harness(db, guest, defaults: defaults)
        await db.refuseReplies(true)
        let n1 = first.willSend("and Germany?")
        await first.retry()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        XCTAssertEqual(guest.inputs, ["and Germany?"])

        let again = ScriptedGuest(home: home, script: [.reply("AGAIN")])
        let (second, bridge) = harness(db, again, defaults: defaults)
        let pending = await bridge.current.pending
        XCTAssertEqual(pending?.state, .answered)
        XCTAssertNil(pending?.person)
        XCTAssertTrue(second.willSend("and Germany?", nonce: n1))
        await db.away(true)
        await second.retry()
        XCTAssertTrue(again.inputs.isEmpty)
        await db.away(false)
        await db.refuseReplies(false)
        await second.retry()
        let turns = try await log(db)
        XCTAssertTrue(again.inputs.isEmpty)
        XCTAssertEqual(turns.map(\.text), ["and Germany?", "Berlin."])
        XCTAssertTrue(second.owed.isEmpty)
    }

    // A cold launch on a phone that answered, the guest still coming up, the hub holding the lease.
    func testAColdLaunchWithTheGuestComingUpAndTheHubHolding() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: Confirms(), sleep: parked)
        _ = try await hub.takeOver()
        let guest = ScriptedGuest(home: home, script: [.reply("never")])
        guest.holdReady()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: Confirms(), sleep: parked))
        await harness.refresh()
        await harness.send("share this link")
        XCTAssertEqual(harness.turns.last?.text, "share this link")
        guest.releaseReady()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(guest.inputs.isEmpty, "the guest was given a turn the hub answers, after the lease said so: \(guest.inputs)")
    }

    // The same warm: the runner standing, the hub taking the lease between two turns.
    func testAWarmPhoneWithTheGuestComingUpAndTheHubHolding() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("never")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: Confirms(), sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: Confirms(), sleep: parked)
        _ = try await hub.takeOver()
        guest.holdReady()
        await harness.send("share this link")
        XCTAssertEqual(harness.turns.last?.text, "share this link")
        guest.releaseReady()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(guest.inputs, ["hello"], "the guest was given a turn the hub answers, after the lease said so")
    }

    // The ordinary hand-back: two messages in a row, the first answered ahead, the hub answers once.
    func testTwoMessagesHandedBackTheHubAnswersARelaunchDrawsNothingOfItsOwn() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("answer one"), .reply("answer two")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: Confirms(), sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: Confirms(), sleep: parked)
        _ = try await hub.takeOver()
        await db.stall(true)
        let n1 = harness.willSend("first question")
        harness.willSend("second question")
        let sending = Task { await harness.retry() }
        try await eventually("the first answered ahead") { harness.replies[n1] == "answer one" }
        await db.stall(false)
        await sending.value
        XCTAssertEqual(harness.turns.suffix(2).map(\.text), ["first question", "second question"])
        try await write(db, .assistant, "the hub's one answer to both", device: "hub")
        await harness.refresh()
        XCTAssertTrue(harness.replies.isEmpty)
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "elsewhere" }

        let again = ScriptedGuest(home: home, script: [.reply("EXTRA")])
        let (relaunched, _) = self.harness(db, again, defaults: defaults)
        relaunched.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: Confirms(), sleep: parked))
        await relaunched.refresh()
        await relaunched.answerPending()
        await relaunched.refresh()
        XCTAssertTrue(relaunched.replies.isEmpty, "the phone draws its own guest's reply beside the hub's, for good: \(relaunched.replies)")
    }
}

extension GuestBridgeTests {

    // A sign-out with a second message still waiting for the guest to finish the first.
    func testASignOutWithWordsWaitingForTheGuest() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("AFTER SIGN-OUT")])
        let defaults = makeDefaults()
        let (harness, bridge) = harness(db, guest, defaults: defaults)
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.stall(true)
        harness.willSend("first")
        harness.willSend("second")
        let sending = Task { await harness.retry() }
        try await eventually("the first with the guest") { guest.inputs.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        await harness.forget()
        guest.finishHanging(with: "late")
        await db.stall(false)
        await sending.value
        try await Task.sleep(for: .milliseconds(300))
        let ledger = await bridge.current
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs, ["hello", "first"])
        XCTAssertNil(ledger.early)
        XCTAssertNil(ledger.pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a ledger was written after the sign-out")
        XCTAssertNil(defaults.string(forKey: "topo.harness.standing"))
        XCTAssertEqual(turns.map(\.text), ["hello", "Hi."])
        XCTAssertTrue(harness.replies.isEmpty)
    }

    // A demotion in the same place.
    func testADemotionWithWordsWaitingForTheGuest() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("AFTER DEMOTION")])
        let defaults = makeDefaults()
        let (harness, bridge) = harness(db, guest, defaults: defaults)
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.stall(true)
        harness.willSend("first")
        harness.willSend("second")
        let sending = Task { await harness.retry() }
        try await eventually("the first with the guest") { guest.inputs.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        let demoting = Task { await harness.demote() }
        try await Task.sleep(for: .milliseconds(100))
        await db.stall(false)
        await demoting.value
        await sending.value
        guest.finishHanging(with: "late")
        try await Task.sleep(for: .milliseconds(300))
        let ledger = await bridge.current
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs, ["hello", "first"])
        XCTAssertNil(ledger.early)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a ledger was written after the demotion")
        XCTAssertNil(defaults.string(forKey: "topo.harness.standing"))
        XCTAssertEqual(turns.map(\.text), ["hello", "Hi.", "first", "second"])
        XCTAssertTrue(harness.replies.isEmpty)
    }
}

/// Commits the next save that carries a person's turn and then fails it: a lost acknowledgement.
private actor LostAck: RecordDatabase {
    let wrapped = InMemoryRecordDatabase()
    private var loseNextPerson = false
    func loseNextPersonAcknowledgement() { loseNextPerson = true }
    func save(_ records: [Record]) async throws -> [Record] {
        let saved = try await wrapped.save(records)
        if loseNextPerson, records.contains(where: { Turn(record: $0)?.role == .person }) {
            loseNextPerson = false
            throw RecordDatabaseError.unavailable(underlying: Refused())
        }
        return saved
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await wrapped.records(ofType: type) }
}

extension GuestBridgeTests {

    // Coverage through the harness: the limb write's acknowledgement is lost, the hub answers
    // the turn and goes, the stopped line is sent again.
    func testALostAcknowledgementOnTheLimbWriteThenTheHubAnswers() async throws {
        let db = LostAck()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("the phone's answer"), .reply("ok"), .reply("EXTRA")])
        let defaults = makeDefaults()
        let (harness, bridge) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        _ = try await hub.takeOver()
        await db.loseNextPersonAcknowledgement()
        let nonce = harness.willSend("what time is it?")
        await harness.retry()
        try await eventually("the guest done") { await harness.guest?.unsaved()[nonce] == "the phone's answer" }
        let before = try await log(db)
        XCTAssertEqual(harness.owed.map(\.nonce), [nonce], "the line did not stop on the lost acknowledgement")
        let person = try XCTUnwrap(before.last { $0.role == .person && $0.nonce == nonce })
        let hubs = try await TurnLog(database: db).writer(for: DeviceID("hub"))
            .append(.assistant, "the hub's answer", parents: [person.ref], nonce: TurnRunner.replyNonce(for: [person.ref]))
        clock.advance(11)
        await harness.refresh()
        await harness.retry()
        let ledger = await bridge.current
        let counted = ledger.seen.contains(hubs.ref)
        XCTAssertEqual(harness.turns.last?.text, "the hub's answer")
        await harness.send("thanks")
        let told = guest.inputs.last ?? ""
        XCTAssertFalse(counted, "the hub's reply is counted seen though the guest was never told it")
        XCTAssertTrue(told.contains("the hub's answer"), "the guest is never told the reply the log holds: \(told)")
    }

    // `.contended` with three on the line: what order the guest is given them in.
    func testContendedWithThreeOnTheLine() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("r-a"), .reply("r-b"), .reply("r-c"), .reply("r-d")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        let lease = PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(), sleep: parked)
        harness.adopt(lease)
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.stall(true)
        harness.willSend("X")
        harness.willSend("E")
        harness.willSend("F")
        let sending = Task { await harness.retry() }
        try await eventually("X with the guest") { guest.inputs.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        await lease.abandon()
        await db.stall(false)
        try await Task.sleep(for: .milliseconds(300))
        guest.finishHanging(with: "rX")
        let done = Flag()
        Task { await sending.value; done.set() }
        try await eventually("the line drained") { done.value }
        try await Task.sleep(for: .milliseconds(300))
        await harness.answerPending()
        await harness.refresh()
        let order = guest.inputs.dropFirst().map { String($0.split(separator: "\n").last ?? "") }
        XCTAssertEqual(order, ["X", "E", "F"], "the guest was given the line out of order")
    }
}

extension GuestBridgeTests {
    // A ledger written by hand: `pending` empty with a
    // bound input still in `early` (what a `record(nil)` with no `promote` after it leaves), then a bind.
    func testABindAfterPromoteHasMovedTheList() async throws {
        let db = InMemoryRecordDatabase()
        let ref1 = TurnRef(device: phone, sequence: 1)
        var ledger = GuestLedger()
        ledger.session = "S1"
        let boundX = GuestLedger.Pending(input: "input-x", nonce: "reply-x", parents: [ref1], answering: [ref1],
                                         covers: Coverage([ref1]), session: "S1", sentAt: Date(), state: .answered,
                                         text: "x's answer", person: "nx", said: ["nx"])
        ledger.early = [
            GuestLedger.Early(person: "nx", input: "input-x", covers: Coverage(), session: "S1", sentAt: Date(),
                              state: .answered, text: "x's answer", bound: boundX),
            GuestLedger.Early(person: "nz", input: "input-z", covers: Coverage(), session: "S1", sentAt: Date(),
                              state: .answered, text: "z's answer", bound: nil),
        ]
        try ledger.save(ledgerFile)
        let (_, bridge, _) = try await launch(db)
        let personX = Turn(ref: ref1, parents: [], role: .person, text: "x", at: Date(), nonce: "nx")
        await bridge.bind(nonce: "nx", person: personX, reply: "reply-x")
        let after = await bridge.current
        XCTAssertNil(after.early?.first { $0.person == "nz" }?.bound, "the other input was bound to this turn's record")
    }
}

// MARK: - Words given ahead: demotion, kept replies and coverage of the log moved past

extension GuestBridgeTests {

    // (d) A demotion with a second message parked behind the first's guest turn. `demote()` moves the
    // harness's login and then reads and writes the log before it reaches `brain.forget()`; the
    // guest finishes the first inside that window.
    func testADemotionStillSavingGivesTheGuestTheWordsThatWereWaiting() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("AFTER DEMOTION")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.stall(true)
        harness.willSend("first")
        harness.willSend("second")
        let sending = Task { await harness.retry() }
        try await eventually("the first with the guest") { guest.inputs.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        let demoting = Task { await harness.demote() }
        try await Task.sleep(for: .milliseconds(100))
        // The demotion is under way, its writes of the line still out. The guest finishes the first.
        guest.finishHanging(with: "late")
        try await Task.sleep(for: .milliseconds(300))
        let during = guest.inputs
        let written = FileManager.default.fileExists(atPath: ledgerFile.path)
            ? (try? GuestLedger.load(ledgerFile))?.early?.map(\.person).count ?? 0 : 0
        await db.stall(false)
        await demoting.value
        await sending.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(during, ["hello", "first"], "words from before the demotion were given to the guest after it began")
        XCTAssertLessThanOrEqual(written, 1, "an input for words from before the demotion was recorded on disk after it began")
        XCTAssertTrue(harness.replies.isEmpty, "the demoted screen draws a reply its guest made after the demotion: \(harness.replies.values.sorted())")
    }

    // (d) The same with no runner yet: the launch's own giving (`reach`), the guest still coming up.
    func testADemotionStillSavingGivesTheGuestTheWordsALaunchWasGiving() async throws {
        let db = Outage()
        let defaults = try await aPhoneThatAnswered(db)
        let guest = ScriptedGuest(home: home, script: [.reply("AFTER DEMOTION")])
        guest.holdReady()
        let (harness, _) = harness(db, guest, defaults: defaults)
        await harness.refresh()
        await db.stall(true)
        harness.willSend("from before the demotion")
        let sending = Task { await harness.retry() }
        try await eventually("the guest asked for") { guest.readyHeld }
        let demoting = Task { await harness.demote() }
        try await Task.sleep(for: .milliseconds(100))
        guest.releaseReady()
        try await Task.sleep(for: .milliseconds(300))
        let during = guest.inputs
        await db.stall(false)
        await demoting.value
        await sending.value
        XCTAssertEqual(during, [], "words from before the demotion were given to the guest after it began")
    }

    // (a) A reply kept after its batch failed (`replyFailed`, kept), then a limb's turn continuing
    // the person's turn: the bridge still owes the reply and the next pass writes it.
    func testAKeptReplyStaysDrawnWhenALimbsTurnContinuesItsTurn() async throws {
        let db = RefusingReplies()
        let guest = ScriptedGuest(home: home, script: [.reply("Paris."), .reply("Noted.")])
        let (harness, bridge) = harness(db, guest)
        await harness.refresh()
        await harness.answerPending()
        await db.refuse(true)
        let nonce = harness.willSend("capital of France?")
        await harness.retry()
        XCTAssertEqual(harness.replies[nonce], "Paris.", "control: the kept reply is drawn")
        try await write(db, .person, "and from the watch", device: "watch")
        await harness.refresh()
        let owed = await bridge.owed()
        XCTAssertEqual(owed?.text, "Paris.", "control: the bridge still owes the reply")
        XCTAssertEqual(harness.replies[nonce], "Paris.", "a reply this phone still owes the log left the screen")
        await db.refuse(false)
        await harness.answerPending()
        let turns = try await log(db)
        XCTAssertTrue(turns.map(\.text).contains("Paris."), "control: this phone wrote the reply: \(turns.map(\.text))")
    }

    // (a) The same reply, and the only child of its turn is this phone's own next message, written
    // as a limb's because a hub took the lease meanwhile.
    func testAKeptReplyStaysDrawnWhenThisPhonesNextTurnGoesToTheHub() async throws {
        let db = RefusingReplies()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Paris."), .reply("the phone's second"), .reply("EXTRA")])
        let defaults = makeDefaults()
        let (harness, bridge) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.refresh()
        await harness.answerPending()
        await db.refuse(true)
        let first = harness.willSend("capital of France?")
        await harness.retry()
        XCTAssertEqual(harness.replies[first], "Paris.", "control: the kept reply is drawn")
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        let took = try await hub.takeOver()
        guard case .primary = took else { return XCTFail("the hub did not take the lease") }
        await harness.send("and Germany?")
        XCTAssertEqual(harness.turns.map(\.text), ["capital of France?", "and Germany?"])
        let owed = await bridge.owed()
        XCTAssertEqual(owed?.text, "Paris.", "control: the bridge still owes the first reply")
        XCTAssertEqual(harness.replies[first], "Paris.", "a reply this phone still owes the log left the screen")
        await db.refuse(false)
        clock.advance(11)
        await harness.answerPending()
        let turns = try await log(db)
        XCTAssertTrue(turns.map(\.text).contains("Paris."), "control: this phone wrote the reply: \(turns.map(\.text))")
    }

    // (b) `movePast` on the heard fast path: the input the log moved past went to a session the
    // guest has since left, so the session that answers was never given its words.
    func testWordsGivenToASessionTheGuestLeftAreNotCountedSeenWhenTheLogMovesPastThem() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"), .reply("answer two"), .reply("ok"))
        let one = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        XCTAssertTrue(one)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        // The resume fails: the next process is a fresh session, which knows none of the first.
        guest.startFresh()
        let two = await bridge.hear("second question", nonce: "n2", context: [], model: .sonnet5)
        XCTAssertTrue(two)
        try await eventually("the second answer") { await bridge.unsaved()["n2"] == "answer two" }
        XCTAssertEqual(guest.inputs, ["first question", "second question"])
        // Both reach the log as a limb's turns, and then this phone answers the head.
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        _ = try await writer.append(.person, "second question", parents: [p1.ref], nonce: "n2")
        _ = try await runner.answerPending(model: .sonnet5)
        XCTAssertEqual(guest.inputs.count, 2)
        let ledger = await bridge.current
        XCTAssertFalse(ledger.seen.contains(p1.ref), "a turn only a session the guest left was given is counted seen (after the heard path)")
        _ = try await runner.run("thanks", model: .sonnet5)
        let told = guest.inputs.last ?? ""
        XCTAssertTrue(told.contains("first question"), "the session that answers is never told a turn of the log: \(told)")
    }

    // (b) What an input the log moved past told the guest, when the request that found it so is
    // then refused by a guest not ready: the next attempt.
    func testAnInputTheLogMovedPastIsNotToldAgainAfterAGuestNotReady() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"), .reply("answer two"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "second question", parents: [p1.ref])
        guest.refuse("the userland is still downloading")
        do {
            _ = try await runner.answerPending(model: .sonnet5)
            XCTFail("answered by a guest that was not ready")
        } catch {}
        guest.refuse(nil)
        _ = try await runner.answerPending(model: .sonnet5)
        XCTAssertEqual(guest.inputs.last, "second question", "words the guest was given as an input are told to it again")
    }
}

// MARK: - Words given ahead: a demotion under way, and inputs never received

private actor SlowSaves: RecordDatabase {
    let wrapped = InMemoryRecordDatabase()
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func hold(_ on: Bool) {
        holding = on
        guard !on else { return }
        held.forEach { $0.resume() }
        held = []
    }

    func save(_ records: [Record]) async throws -> [Record] {
        if holding { await withCheckedContinuation { held.append($0) } }
        return try await wrapped.save(records)
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await wrapped.records(ofType: type) }
}

extension GuestBridgeTests {

    private enum Meanwhile { case nothing, theLoopMidPass, aSend }

    /// A phone that is the one answering, its guest still writing the reply to a first message
    /// whose turn is saved, and a second message parked behind that turn in the bridge. Another
    /// device takes over; this phone has asked the lease nothing since, so its runner still
    /// stands `mine`. iCloud turns slow to take a write, the demotion begins and waits on its
    /// write of the line, and the guest finishes the first inside that wait (`demote()` has
    /// told the bridge to stop the second, and it does). Then `meanwhile` happens on the main
    /// actor, with the demotion still waiting.
    private func aDemotionWaitingOnItsWrites(_ meanwhile: Meanwhile) async throws
        -> (during: [String], standing: String?, ledgerOnDisk: Bool, replies: [String: String]) {
        let db = SlowSaves()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("AFTER DEMOTION"), .reply("AFTER DEMOTION 2")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let first = harness.willSend("first")
        let sending = Task { await harness.retry() }
        try await eventually("the first saved, and with the guest") { guest.inputs.count == 2 && harness.said(first) }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        let took = try await hub.takeOver()
        guard case .primary = took else { XCTFail("the hub did not take the lease"); throw Refused() }
        harness.willSend("second")
        let sendingSecond = Task { await harness.retry() }
        try await Task.sleep(for: .milliseconds(100))
        await db.hold(true)
        // The chat's answering loop is in a pass begun before the demotion: the memory's sync
        // (`onPass`, `memory.sync()` in the app) is out.
        let gate = Gate()
        var looping: Task<Void, Never>?
        if meanwhile == .theLoopMidPass {
            harness.onPass = { await gate.pass() }
            looping = Task { await harness.answering(every: .seconds(5)) }
            try await eventually("the loop mid-pass") { await gate.waiting }
        }
        let demoting = Task { await harness.demote() }
        try await Task.sleep(for: .milliseconds(100))
        guest.finishHanging(with: "late")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(guest.inputs, ["hello", "first"], "control: the bridge stopped the second when the demotion began")
        var typing: Task<Void, Never>?
        switch meanwhile {
        case .nothing: break
        case .theLoopMidPass: await gate.open()
        case .aSend: typing = Task { await harness.send("typed while the demotion waits") }
        }
        try await Task.sleep(for: .milliseconds(500))
        let during = guest.inputs
        await db.hold(false)
        await demoting.value
        await sending.value
        await sendingSecond.value
        await looping?.value
        await typing?.value
        try await Task.sleep(for: .milliseconds(300))
        return (during, defaults.string(forKey: "topo.harness.standing"),
                FileManager.default.fileExists(atPath: ledgerFile.path), harness.replies)
    }

    /// Control: with nothing else on the main actor the fourth pass's fix holds.
    func testADemotionWaitingOnItsWritesGivesTheGuestNothing() async throws {
        let after = try await aDemotionWaitingOnItsWrites(.nothing)
        XCTAssertEqual(after.during, ["hello", "first"])
        XCTAssertNil(after.standing)
        XCTAssertFalse(after.ledgerOnDisk)
        XCTAssertTrue(after.replies.isEmpty)
    }

    /// A. `demote()` moves `login` first and keeps `runner` and `pending` live across its awaits,
    /// and sets `busy = false` before its writes. The answering loop checks `login` only after
    /// `retryStoppedLine` (Harness.swift:1053-1054), so a pass begun before the demotion drains
    /// the line under the new login: `hearLine()` gives the guest what `stopHearing` stopped.
    func testADemotionWithTheLoopMidPassGivesTheGuestNoneOfTheLine() async throws {
        let after = try await aDemotionWaitingOnItsWrites(.theLoopMidPass)
        XCTAssertEqual(after.during, ["hello", "first"], "words from before the demotion were given to the guest after it began")
        XCTAssertNil(after.standing, "a standing was kept after the demotion")
        XCTAssertFalse(after.ledgerOnDisk, "a ledger was written after the demotion")
        XCTAssertTrue(after.replies.isEmpty, "the demoted screen draws a reply: \(after.replies)")
    }

    /// A, by the other door: anything that calls `drain()` while the demotion waits — the
    /// composer, a widget cue's `retry()`.
    func testASendWhileTheDemotionWaitsGivesTheGuestNoneOfTheLine() async throws {
        let after = try await aDemotionWaitingOnItsWrites(.aSend)
        XCTAssertFalse(after.during.contains { $0.hasSuffix("second") }, "words from before the demotion were given to the guest after it began: \(after.during)")
        XCTAssertEqual(after.during, ["hello", "first"], "the guest was given words while the demotion waited: \(after.during)")
        XCTAssertNil(after.standing, "a standing was kept after the demotion")
        XCTAssertFalse(after.ledgerOnDisk, "a ledger was written after the demotion")
    }

    /// B. `passed(in:)` on the asked path: the Earlies leave the ledger with `record(Pending…)`
    /// (GuestBridge.swift:465-466), and what they told rides on that record's `covers`. An input
    /// then never received is cleared with everything it carried (`record(nil)`, :544, :478,
    /// :399), so the turn the guest was given as its own input is told to it again.
    func testAnInputTheLogMovedPastIsNotToldAgainWhenTheNextInputIsNeverReceived() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"),
                                                       .notReceived("the process went before it read the input"),
                                                       .reply("answer two"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "second question", parents: [p1.ref])
        do {
            _ = try await runner.answerPending(model: .sonnet5)
            XCTFail("answered by a guest that never received the input")
        } catch {}
        XCTAssertEqual(guest.inputs.last, "second question", "control: the input that was not received did not tell the words again")
        let kept = await bridge.current
        XCTAssertEqual(kept.early?.map(\.person) ?? [], ["n1"], "the input the log moved past left the ledger with an input the guest never received")
        _ = try await runner.answerPending(model: .sonnet5)
        XCTAssertEqual(guest.inputs.last, "second question", "words the guest was given as an input are told to it again")
    }

    /// The same with the guest's session unchanged and the turn that follows said on this phone.
    func testWordsAHubAnsweredAreNotToldAgainWhenTheNextInputIsNeverReceived() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"),
                                                       .notReceived("the process went before it read the input"),
                                                       .reply("answer two"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        // The turn reaches the log as a limb's and a hub answers it.
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        _ = try await TurnLog(database: db).writer(for: DeviceID("hub"))
            .append(.assistant, "the hub's answer", parents: [p1.ref], nonce: TurnRunner.replyNonce(for: [p1.ref]))
        _ = try? await runner.run("second question", model: .sonnet5, nonce: "n2")
        _ = try await runner.answerPending(model: .sonnet5)
        XCTAssertEqual(guest.inputs.count, 3, "the second question was not asked again after it was never received")
        let told = guest.inputs.last ?? ""
        XCTAssertTrue(told.contains("second question"), told)
        XCTAssertFalse(told.contains("Them: first question"), "words the guest was given as an input are told to it again as another device's: \(told)")
    }

    /// A phone that was the one answering is told, mid-reply, that another device took the
    /// lease: its guest is given nothing of the next message ahead.
    func testAPhoneDisplacedMidReplyGivesItsGuestNothingOfTheNextMessageAhead() async throws {
        let db = InMemoryRecordDatabase()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("THE PHONE'S SECOND")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let first = harness.willSend("first")
        let sending = Task { await harness.retry() }
        try await eventually("the first saved, and with the guest") { guest.inputs.count == 2 && harness.said(first) }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        let took = try await hub.takeOver()
        guard case .primary = took else { return XCTFail("the hub did not take the lease") }
        guest.finishHanging(with: "the phone's first")
        await sending.value
        XCTAssertEqual(harness.error, "Another device took over mid-reply. Your words are in the log.", "control: the reply was displaced")
        await harness.send("second")
        XCTAssertEqual(harness.turns.last?.text, "second", "control: the second went to the log as a limb's")
        XCTAssertEqual(guest.inputs, ["hello", "first"], "a phone told it was displaced gave its guest the next message")
    }
}

extension GuestBridgeTests {
    /// A, with natural timing and no gate: the fourth pass's recipe (d) — every call to iCloud
    /// stalled, two messages, the guest finishing the first inside the demotion — with the chat's
    /// answering loop simply running and the other device's takeover in the log. The phone's own
    /// stalled lease call answers first here, so the guest is given nothing more; the loop's pass
    /// still drains the line under the new login, and its run keeps a standing after the demotion.
    func testADemotionInAStallWithTheLoopRunning() async throws {
        let db = Outage()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("AFTER DEMOTION"), .reply("AFTER DEMOTION 2")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        _ = try await hub.takeOver()
        await db.stall(true)
        harness.willSend("first")
        harness.willSend("second")
        let sending = Task { await harness.retry() }
        try await eventually("the first with the guest") { guest.inputs.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        let looping = Task { await harness.answering(every: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        let demoting = Task { await harness.demote() }
        try await Task.sleep(for: .milliseconds(100))
        guest.finishHanging(with: "late")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(guest.inputs, ["hello", "first"], "control: nothing more while everything is stalled")
        await db.stall(false)
        try await Task.sleep(for: .milliseconds(500))
        let during = guest.inputs
        await demoting.value
        await sending.value
        await looping.value
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(during, ["hello", "first"], "words from before the demotion were given to the guest after it began")
        XCTAssertNil(defaults.string(forKey: "topo.harness.standing"), "a standing was kept after the demotion")
    }

    /// The person's turn is saved and its acknowledgement lost, so the line stops with the
    /// guest's reply drawn; a limb's turn then continues that turn and this phone's pass answers
    /// it. The stopped line sent again finds its turn moved past: the guest is not asked again,
    /// no second answer is written, and the line is settled.
    func testAStoppedLineSentAgainAfterTheLogMovedPastItsTurnAsksNothing() async throws {
        let db = LostAck()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("the phone's answer"), .reply("to the watch"), .reply("ASKED AGAIN")])
        let defaults = makeDefaults()
        let (harness, _) = harness(db, guest, defaults: defaults)
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.loseNextPersonAcknowledgement()
        let nonce = harness.willSend("what time is it?")
        await harness.retry()
        try await eventually("the guest done") { await harness.guest?.unsaved()[nonce] == "the phone's answer" }
        XCTAssertEqual(harness.owed.map(\.nonce), [nonce], "control: the line stopped on the lost acknowledgement")
        XCTAssertEqual(harness.replies[nonce], "the phone's answer", "control: the reply is drawn")
        try await write(db, .person, "and tomorrow?", device: "watch")
        await harness.refresh()
        await harness.answerPending()
        XCTAssertEqual(guest.inputs.last, "and tomorrow?", "control: the pass answered the limb's turn, telling nothing again")
        await harness.retry()
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs.filter { $0.contains("what time is it?") }.count, 1, "the guest was given the same words twice: \(guest.inputs)")
        XCTAssertFalse(turns.map(\.text).contains("ASKED AGAIN"), "a second answer to the words was written: \(turns.map(\.text))")
        XCTAssertEqual(turns.suffix(3).map(\.text), ["what time is it?", "and tomorrow?", "to the watch"])
        XCTAssertFalse(harness.hasWaiting, "the line still holds a turn the log has")
        XCTAssertTrue(harness.replies.isEmpty)
        XCTAssertNil(harness.failure)
    }
}

// MARK: - Words given ahead: a retry racing its own earlier save, and a demotion racing a launch

private actor TurnSavesHeld: RecordDatabase {
    let wrapped = InMemoryRecordDatabase()
    private var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    var waiting: Bool { !held.isEmpty }

    func hold(_ on: Bool) {
        holding = on
        guard !on else { return }
        held.forEach { $0.resume() }
        held = []
    }

    func save(_ records: [Record]) async throws -> [Record] {
        if holding, records.contains(where: { $0.type == Turn.recordType }) {
            await withCheckedContinuation { held.append($0) }
        }
        return try await wrapped.save(records)
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await wrapped.records(ofType: type) }
}

extension GuestBridgeTests {

    /// A harness whose relay the test keeps, and whose first reach of iCloud waits at `zone`.
    private func r6Harness(_ db: any RecordDatabase, _ guest: ScriptedGuest, defaults: UserDefaults,
                           zone: Gate? = nil) -> (Harness, GuestBridge, GuestRelay) {
        let (bridge, relay) = Harness.guestBrain(guest, ledger: ledgerFile)
        let harness = Harness(database: db, tokens: InMemoryTokenStore(nil).provider, device: phone,
                              ensureZone: { await zone?.pass() }, defaults: defaults,
                              brain: bridge, relay: relay, leaseSleep: parked,
                              pause: { _ in throw CancellationError() }, patience: .seconds(3600))
        return (harness, bridge, relay)
    }

    private func r6Defaults() -> UserDefaults {
        let name = "topo.tests.bridge.r6.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// A launch whose first send is still reaching iCloud when a demotion begins: the runner
    /// that attempt makes is not kept, so nothing claims the lease back from the device that
    /// took over, and a send during the demotion's wait gives the guest none of the line.
    func testADemotionWhileTheLaunchIsStillReachingICloudGivesTheGuestNoneOfTheLine() async throws {
        let db = TurnSavesHeld()
        let zone = Gate()
        let guest = ScriptedGuest(home: home, script: [.reply("GIVEN DURING THE DEMOTION"), .reply("GIVEN DURING THE DEMOTION 2")])
        let defaults = r6Defaults()
        let (harness, _, _) = r6Harness(db, guest, defaults: defaults, zone: zone)
        // The device that took over holds the lease, live.
        let other = PrimaryLease(database: db, device: DeviceID("other-phone"), endpoint: nil, probe: NoSocketProbe(), sleep: parked)
        let took = try await other.takeOver()
        guard case .primary = took else { return XCTFail("the other device did not take the lease") }
        await harness.refresh()
        // This launch's first message: its attempt is making the runner, iCloud slow to answer.
        harness.willSend("said before the demotion")
        let sending = Task { await harness.retry() }
        try await eventually("the send reaching iCloud") { await zone.waiting }
        // The far end of the takeover: the demotion begins, and waits on its write of the line.
        await db.hold(true)
        let demoting = Task { await harness.demote() }
        try await eventually("the demotion waiting on its write") { await db.waiting }
        XCTAssertTrue(harness.busy, "control: the demotion holds the line")
        XCTAssertTrue(guest.inputs.isEmpty, "control: nothing given before the demotion")
        // iCloud answers the attempt begun before the demotion.
        await zone.open()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(guest.inputs.isEmpty, "control: the attempt itself gives nothing")
        let leaseDuring = try await db.fetch([Lease.recordID])[Lease.recordID]
        let holderDuring = leaseDuring.flatMap { Lease(record: $0) }?.holder
        // The person types while the demotion waits (or a widget cue's `retry()` runs).
        let typing = Task { await harness.send("typed while the demotion waits") }
        try await Task.sleep(for: .milliseconds(500))
        let during = guest.inputs
        XCTAssertTrue(harness.busy, "control: the demotion is still waiting")
        await db.hold(false)
        await demoting.value
        await sending.value
        await typing.value
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(during, [], "the guest was given the line while the demotion waited on its writes: \(during)")
        XCTAssertEqual(holderDuring, DeviceID("other-phone"), "the demoted phone took the lease back from the device that took over")
        XCTAssertFalse(harness.busy)
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["said before the demotion", "typed while the demotion waits"], "control: the line reached the log as a limb's")
        XCTAssertNil(defaults.string(forKey: "topo.harness.standing"))
    }

    /// Control for the above, and the bar's "a send during demotion lost or left on the line":
    /// with the runner already made when the demotion begins, a send during its wait gives the
    /// guest nothing, goes to the log as a limb's behind the line, and `busy` is released.
    func testASendWhileADemotionWaitsReachesTheLogAndNotTheGuest() async throws {
        let db = TurnSavesHeld()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("GIVEN DURING THE DEMOTION"), .reply("GIVEN DURING THE DEMOTION 2")])
        let defaults = r6Defaults()
        let (harness, _, _) = r6Harness(db, guest, defaults: defaults)
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.hold(true)
        harness.willSend("said before the demotion")
        let demoting = Task { await harness.demote() }
        try await eventually("the demotion waiting on its write") { await db.waiting }
        let typing = Task { await harness.send("typed while the demotion waits") }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(guest.inputs, ["hello"], "the guest was given the line while the demotion waited")
        XCTAssertTrue(harness.busy)
        await db.hold(false)
        await demoting.value
        await typing.value
        XCTAssertFalse(harness.busy, "busy left held after the demotion")
        XCTAssertTrue(harness.owed.isEmpty, "the line still holds: \(harness.owed.map(\.text))")
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text), ["hello", "Hi.", "said before the demotion", "typed while the demotion waits"])
        XCTAssertEqual(guest.inputs, ["hello"])
    }

    /// The harness's `movedPast` catch drops what was drawn of
    /// the reply but leaves `hearing` on the turn and does not mark it answered elsewhere, as
    /// the hand-back does (:857). The guest is still on those words, and what it writes next is
    /// drawn as the reply being written at the end of the transcript — under the other
    /// device's turn — until its turn ends; and `onTurnFailed` is told of the turn twice.
    /// The relay is told the guest's next words directly: `ScriptedGuest` cannot write more to a
    /// hanging turn, and `GuestBridge.fly` does exactly this with each update (`observe`).
    func testTheLogMovedPastATurnTheGuestIsStillWritingDrawsNoneOfTheRest() async throws {
        let db = LostAck()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangWriting("It is"), .reply("to the watch")])
        let defaults = r6Defaults()
        let (harness, _, relay) = r6Harness(db, guest, defaults: defaults)
        var failed: [String] = []
        harness.onTurnFailed = { failed.append($0) }
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.loseNextPersonAcknowledgement()
        let nonce = harness.willSend("what time is it?")
        await harness.retry()
        XCTAssertEqual(harness.owed.map(\.nonce), [nonce], "control: the line stopped on the lost acknowledgement")
        try await eventually("the guest writing") { harness.replies[nonce] == "It is" }
        try await write(db, .person, "and tomorrow?", device: "watch")
        await harness.refresh()
        failed = []
        await harness.retry()
        XCTAssertFalse(harness.hasWaiting, "control: the retry found the turn moved past and settled the line")
        XCTAssertEqual(guest.inputs.count, 2, "control: nothing asked")
        XCTAssertNil(harness.writing, "control: what was drawn of the reply went")
        // The guest, still on the words, writes on.
        relay.tell(GuestActivity.update(.event(.writing(" half past nine."))))
        let drawn = harness.writing
        let ahead = harness.writingAhead
        guest.finishHanging(with: "It is half past nine.")
        try await eventually("the guest's turn over") { await harness.guest?.unsaved()[nonce] != nil }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(drawn, "the guest's words for a turn the log moved past are drawn as the reply being written (writingAhead \(ahead)): \(drawn ?? "")")
        XCTAssertEqual(failed, [nonce], "the turn was told failed \(failed.count) times")
        XCTAssertTrue(harness.replies.isEmpty, "a reply that will not be written is drawn: \(harness.replies)")
        XCTAssertNil(harness.writing)
    }

    /// Missed. Words the guest was cut off on ahead of their turn, which the log then moved
    /// past: the `Early` is unresolved and unbound, and `begin` refuses every `hear` while one
    /// stands. It is counted and removed by the next reply to land, the
    /// words are not told again, nothing of it is drawn, and words are given ahead again.
    func testWordsCutOffAheadThatTheLogMovedPastStopBlockingOnceTheNextReplyLands() async throws {
        let db = LostAck()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .errorResult("boom"), .reply("to both"), .reply("to the third")])
        let defaults = r6Defaults()
        let (harness, bridge, _) = r6Harness(db, guest, defaults: defaults)
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.loseNextPersonAcknowledgement()
        let nonce = harness.willSend("run the report")
        await harness.retry()
        XCTAssertEqual(harness.owed.map(\.nonce), [nonce], "control: the line stopped on the lost acknowledgement")
        try await eventually("the guest cut off") { await bridge.current.early?.first?.state == .unresolved }
        try await write(db, .person, "and tomorrow?", device: "watch")
        await harness.refresh()
        await harness.retry()
        XCTAssertFalse(harness.hasWaiting, "control: moved past, the line settled")
        XCTAssertEqual(guest.inputs.count, 2, "control: nothing asked")
        let lingering = await bridge.current
        XCTAssertEqual(lingering.early?.map(\.person) ?? [], [nonce], "control: the input stays until it is counted")
        XCTAssertNil(lingering.pending)
        XCTAssertTrue(harness.replies.isEmpty)
        XCTAssertNil(harness.unfinished)
        // The next thing said here is asked once saved, telling the watch's turn and not the report.
        await harness.send("next")
        let told = guest.inputs.last ?? ""
        XCTAssertEqual(guest.inputs.count, 3)
        XCTAssertTrue(told.contains("Them: and tomorrow?"), "the watch's turn was not told: \(told)")
        XCTAssertFalse(told.contains("run the report"), "words the guest was given are told to it again: \(told)")
        let after = await bridge.current
        XCTAssertEqual(after.early ?? [], [], "the input the log moved past is still in the ledger")
        XCTAssertNil(after.pending)
        let turns = try await log(db)
        XCTAssertEqual(turns.suffix(4).map(\.text), ["run the report", "and tomorrow?", "next", "to both"])
        XCTAssertTrue(after.seen.contains(turns[turns.count - 4].ref), "the turn the guest received is not counted seen")
        // And words are given ahead again.
        let heard = await bridge.hear("third", nonce: "n3", context: harness.turns, model: .sonnet5)
        XCTAssertTrue(heard, "nothing is given ahead after an input the log moved past")
    }

    /// Missed. A phone displaced mid-reply stands `elsewhere` and holds the line off its guest
    /// (`handedBack`); once the lease is its own again it hears ahead again: with every call to
    /// iCloud stalled, the guest has the next message.
    func testAPhoneDisplacedMidReplyHearsAheadAgainOnceTheLeaseIsItsOwn() async throws {
        let db = Outage()
        let clock = Ticks()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .hangUnwritten, .reply("to the third"), .reply("to the fourth")])
        let defaults = r6Defaults()
        let (harness, _, _) = r6Harness(db, guest, defaults: defaults)
        harness.adopt(PrimaryLease(database: db, device: phone, endpoint: nil, probe: NoSocketProbe(),
                                   now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked))
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        let first = harness.willSend("first")
        let sending = Task { await harness.retry() }
        try await eventually("the first saved, and with the guest") { guest.inputs.count == 2 && harness.said(first) }
        let hub = PrimaryLease(database: db, device: DeviceID("hub"), endpoint: nil, probe: NoSocketProbe(),
                               now: { clock.wall }, monotonic: { clock.elapsed }, sleep: parked)
        let took = try await hub.takeOver()
        guard case .primary = took else { return XCTFail("the hub did not take the lease") }
        guest.finishHanging(with: "the phone's first")
        await sending.value
        XCTAssertEqual(harness.error, "Another device took over mid-reply. Your words are in the log.", "control: displaced")
        try await eventually("the standing kept as elsewhere") { defaults.string(forKey: "topo.harness.standing") == "elsewhere" }
        await harness.send("second")
        XCTAssertEqual(guest.inputs.count, 2, "control: the second went to the log as a limb's")
        // The hub goes; its lease lapses; the phone answers the next turn as primary.
        clock.advance(11)
        await harness.send("third")
        XCTAssertEqual(guest.inputs.last?.hasSuffix("third"), true, "control: the phone answered as primary: \(guest.inputs)")
        try await eventually("the standing kept as mine") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        XCTAssertNil(harness.failure, "control: \(harness.error ?? "")")
        let asked = guest.inputs.count
        // Every call to iCloud stalls: only words given ahead of the lease reach the guest.
        await db.stall(true)
        let fourth = Task { await harness.send("fourth") }
        var ahead = false
        for _ in 0..<100 where !ahead {
            ahead = guest.inputs.count > asked
            if !ahead { try await Task.sleep(for: .milliseconds(20)) }
        }
        await db.stall(false)
        await fourth.value
        XCTAssertTrue(ahead, "a phone that regained the lease did not give its guest the next message ahead: \(guest.inputs)")
        let turns = try await log(db)
        XCTAssertEqual(Array(turns.filter { $0.role == .assistant }.map(\.text).suffix(2)), ["to the third", "to the fourth"])
        XCTAssertEqual(turns.filter { $0.text == "the phone's first" }.count, 1, "the owed reply was written \(turns.filter { $0.text == "the phone's first" }.count) times")
    }
}

// MARK: - Sixth pass: a save that ran out and lands late (found by the concurrency lens, reproduced here)

/// The next save that carries a person's turn fails `unavailable` and is still on its way: it
/// lands just ahead of the next save that carries a turn. A request that ran out, applied late.
private actor PersonSaveLandsLate: RecordDatabase {
    let wrapped = InMemoryRecordDatabase()
    private var armed = false
    private var late: [Record]?

    func loseNextPersonSaveUntilTheNextTurnSave() { armed = true }

    func save(_ records: [Record]) async throws -> [Record] {
        if armed, records.contains(where: { Turn(record: $0)?.role == .person }) {
            armed = false
            late = records
            throw RecordDatabaseError.unavailable(underlying: Refused())
        }
        if records.contains(where: { $0.type == Turn.recordType }), let landing = late {
            late = nil
            _ = try await wrapped.save(landing)
        }
        return try await wrapped.save(records)
    }
    func fetch(_ ids: [RecordID]) async throws -> [RecordID: Record] { try await wrapped.fetch(ids) }
    func query(_ query: RecordQuery) async throws -> [Record] { try await wrapped.query(query) }
    func records(ofType type: String) async throws -> [Record] { try await wrapped.records(ofType: type) }
}

extension GuestBridgeTests {
    /// `TurnRunner.run` takes `before` from a read made before
    /// its append and throws `movedPast` when `before.heads` lacks
    /// the person's ref (:180). A retry whose earlier save failed `unavailable` and lands after
    /// the retry's read finds its turn by the marker (`person.at != at`) in a `before` that does
    /// not hold the turn at all: nothing went on from it, and it is told moved past. The harness
    /// settles the line entry and sends the next, whose turn continues the first: the first is
    /// then no head, no pass answers it, and the reply the guest made of it is discarded.
    func testARetryWhoseEarlierSaveLandsAfterItsReadIsAnswered() async throws {
        let db = PersonSaveLandsLate()
        let guest = ScriptedGuest(home: home, script: [.reply("Hi."), .reply("the answer to the first"), .reply("the answer to the second")])
        let defaults = r6Defaults()
        let (harness, bridge, _) = r6Harness(db, guest, defaults: defaults)
        var failed: [String] = []
        harness.onTurnFailed = { failed.append($0) }
        await harness.send("hello")
        await harness.refresh()
        try await eventually("the standing kept") { defaults.string(forKey: "topo.harness.standing") == "mine" }
        await db.loseNextPersonSaveUntilTheNextTurnSave()
        let first = harness.willSend("first question")
        let second = harness.willSend("second question")
        await harness.retry()
        XCTAssertEqual(harness.owed.map(\.nonce), [first, second], "control: the line stopped on the save that ran out")
        try await eventually("the guest answered both, given ahead") { await bridge.unsaved()[second] == "the answer to the second" }
        let before = try await log(db)
        XCTAssertEqual(before.map(\.text), ["hello", "Hi."], "control: the first attempt's save has not landed")
        failed = []
        // The stopped line goes again: the button, the loop's retry, the next send.
        await harness.retry()
        await harness.answerPending()
        await harness.answerPending()
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs.count, 3, "control: the guest was asked nothing twice")
        XCTAssertFalse(harness.hasWaiting, "control: the line is settled")
        XCTAssertEqual(turns.map(\.text), ["hello", "Hi.", "first question", "the answer to the first", "second question", "the answer to the second"],
                       "a turn of this device's own, with nothing after it when its retry ran, has no reply and is no head")
        XCTAssertFalse(failed.contains(first), "the turn was told failed")
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
        XCTAssertEqual(ledger.early ?? [], [])
        XCTAssertTrue(harness.replies.isEmpty)
    }

    // An input given ahead that the log moved past, bound while the pass that counted it waits
    // for the guest: the bind is kept, and the words are not given a second time.
    func testAnEarlyBoundWhileTheRequestThatPassedItWaitsForTheGuest() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"), .reply("answer two"), .reply("ASKED AGAIN"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "second question", parents: [p1.ref])
        guest.holdReady()
        let passing = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the pass waiting for the guest") { guest.readyHeld }
        let reply = TurnRunner.replyNonce(for: [p1.ref])
        await bridge.bind(nonce: "n1", person: p1, reply: reply)
        guest.releaseReady()
        let first = await passing.result
        let kept = await bridge.current.pending
        XCTAssertEqual(kept?.person, "n1", "the request recorded its own input over the bound one: \(first)")
        let answer = try await bridge.answer(BrainRequest(context: [], answering: [p1], parents: [p1.ref], nonce: reply, model: .sonnet5))
        XCTAssertEqual(answer.text, "answer one", "the reply is not the one the guest made of the words it heard")
        // The bound reply is owed like one bound before the pass began: written first, then the
        // pass answers what the watch said.
        _ = try await runner.answerPending(model: .sonnet5)
        _ = try await runner.answerPending(model: .sonnet5)
        let log = try await TurnLog(database: db).read()
        XCTAssertEqual(log.ordered.map(\.text), ["first question", "second question", "answer one", "answer two"])
        XCTAssertEqual(log.heads.count, 1)
        XCTAssertEqual(guest.inputs.filter { $0.contains("first question") }.count, 1, "the guest was given the words twice: \(guest.inputs)")
    }
}

// MARK: - A bind while a request waits for the guest

/// A scripted guest whose `residentPID` can be held, which is the one suspension `answer` has left
/// between writing its record and sending.
private final class PIDGatedGuest: GuestConversation, @unchecked Sendable {
    let inner: ScriptedGuest
    private let lock = NSLock()
    private var holding = false
    private var gate: CheckedContinuation<Void, Never>?

    init(_ inner: ScriptedGuest) { self.inner = inner }

    var home: URL { inner.home }
    func holdPID() { lock.withLock { holding = true } }
    var pidHeld: Bool { lock.withLock { gate != nil } }
    func releasePID() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holding = false
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func ready() async throws { try await inner.ready() }
    func warm() async {}
    func use(model: String?) async { await inner.use(model: model) }
    func sessionID() async -> String? { await inner.sessionID() }
    func residentPID() async -> Int32? {
        if lock.withLock({ holding }) {
            await withCheckedContinuation { continuation in
                let open = lock.withLock { () -> Bool in
                    guard holding else { return true }
                    gate = continuation
                    return false
                }
                if open { continuation.resume() }
            }
        }
        return await inner.residentPID()
    }
    func send(_ text: String, id: String) async throws -> AsyncStream<GuestSession.TurnUpdate> {
        try await inner.send(text, id: id)
    }
    func settle() async -> Bool { await inner.settle() }
    func forget() async { await inner.forget() }
    func status() async -> String { "gated" }
}

private enum BindMoment { case never, beforeThePass, duringTheWait }

extension GuestBridgeTests {
    private static let owedFirst = GuestBridgeError.failed("a reply the guest finished is still to be written")

    // MARK: the loop ends; bar 1 — nothing given twice, nothing lost

    /// Two inputs given ahead, both bound while one request waits for the guest: the first takes
    /// `pending`, the second waits bound behind it. The request goes round once and no more.
    func testTwoBindsWhileTheRequestWaitsForTheGuest() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"), .reply("answer two"), .reply("answer three"),
                                                       .reply("ASKED AGAIN"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        _ = await bridge.hear("second question", nonce: "n2", context: [], model: .sonnet5)
        try await eventually("the second answer") { await bridge.unsaved()["n2"] == "answer two" }
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        let p2 = try await writer.append(.person, "second question", parents: [p1.ref], nonce: "n2")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "third question", parents: [p2.ref])
        let uses = guest.models.count
        guest.holdReady()
        let passing = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the pass waiting for the guest") { guest.readyHeld }
        await bridge.bind(nonce: "n1", person: p1, reply: TurnRunner.replyNonce(for: [p1.ref]))
        await bridge.bind(nonce: "n2", person: p2, reply: TurnRunner.replyNonce(for: [p2.ref]))
        let during = await bridge.current
        XCTAssertEqual(during.pending?.person, "n1", "control: the first bind took pending")
        XCTAssertEqual(during.early?.compactMap { $0.bound?.person } ?? [], ["n2"], "control: the second waits bound")
        guest.releaseReady()
        let first = await passing.result
        if case .failure(let error) = first, error as? GuestBridgeError == Self.owedFirst {} else { XCTFail("the pass: \(first)") }
        XCTAssertEqual(guest.models.count - uses, 1, "the request went round the guest's wait again")
        let kept = await bridge.current
        XCTAssertEqual(kept.pending?.person, "n1", "the first bound record was lost: \(kept)")
        XCTAssertEqual(kept.early?.compactMap { $0.bound?.person } ?? [], ["n2"], "the second bound record was lost: \(kept)")
        for _ in 0..<4 { _ = try? await runner.answerPending(model: .sonnet5) }
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text).sorted(), ["answer one", "answer three", "answer two", "first question",
                                                     "second question", "third question"])
        XCTAssertEqual(guest.inputs.count, 3, "\(guest.inputs)")
        for words in ["first question", "second question", "third question"] {
            XCTAssertEqual(guest.inputs.filter { $0.contains(words) }.count, 1, "the guest was given \(words) twice: \(guest.inputs)")
        }
        let after = await bridge.current
        XCTAssertNil(after.pending)
        XCTAssertEqual(after.early ?? [], [])
    }

    /// Bound, answered without the slot, written and landed, all while the request waits: `pending`
    /// is nil again when it looks, as it was when it began to wait.
    func testABindAnsweredAndLandedWhileTheRequestWaitsForTheGuest() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"), .reply("answer two"), .reply("ASKED AGAIN"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "second question", parents: [p1.ref])
        let uses = guest.models.count
        guest.holdReady()
        let passing = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the pass waiting for the guest") { guest.readyHeld }
        let reply = TurnRunner.replyNonce(for: [p1.ref])
        await bridge.bind(nonce: "n1", person: p1, reply: reply)
        // The turn's own `run` goes on while the pass waits: handed the heard reply without the
        // slot, it writes it and says so.
        let heard = try await bridge.answer(BrainRequest(context: [], answering: [p1], parents: [p1.ref], nonce: reply, model: .sonnet5))
        XCTAssertEqual(heard.text, "answer one", "control")
        // Written from another writer than the runner's own so the two do not race for a sequence
        // number, which one device's single writer never does.
        let written = try await TurnLog(database: db).writer(for: DeviceID("hub"))
            .append(.assistant, heard.text, parents: [p1.ref], nonce: reply)
        await bridge.landed(written, nonce: reply)
        let between = await bridge.current
        XCTAssertNil(between.pending, "control: pending is as the waiting request left it")
        XCTAssertEqual(guest.models.count - uses, 1, "control: the request is still in its first wait")
        guest.releaseReady()
        let second = try await passing.value
        XCTAssertEqual(second?.text, "answer two")
        XCTAssertEqual(guest.inputs, ["first question", "second question"], "the guest was given something twice, or told what it had")
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text).sorted(), ["answer one", "answer two", "first question", "second question"])
        let after = await bridge.current
        XCTAssertNil(after.pending)
        XCTAssertEqual(after.early ?? [], [])
        XCTAssertTrue(turns.allSatisfy { after.seen.contains($0.ref) }, "coverage: \(after.seen)")
    }

    // MARK: `standing` non-nil

    /// The request's own record, cut off and asked again, is what it goes over; a bind while it
    /// waits lands behind that record, on an Early the request has already named as passed.
    func testABindWhileARequestAskingAgainWaitsForTheGuest() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"), .cutOff, .reply("answer two"), .reply("ASKED AGAIN"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "second question", parents: [p1.ref])
        _ = try? await runner.answerPending(model: .sonnet5)
        let cut = await bridge.current
        XCTAssertEqual(cut.pending?.state, .unresolved, "control: the second question was cut off")
        XCTAssertEqual(cut.early?.map(\.person) ?? [], ["n1"], "control: the words given ahead are still unbound")
        await bridge.askAgain()
        guest.holdReady()
        let passing = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the pass waiting for the guest") { guest.readyHeld }
        let reply = TurnRunner.replyNonce(for: [p1.ref])
        await bridge.bind(nonce: "n1", person: p1, reply: reply)
        let during = await bridge.current
        XCTAssertEqual(during.pending?.askAgain, true, "control: the record asked again still holds pending")
        XCTAssertEqual(during.early?.first?.bound?.nonce, reply, "control: the bind waits behind it")
        XCTAssertEqual(during.settled ?? [], ["n1"], "control: the request named the Early as passed before it was bound")
        guest.releaseReady()
        let second = try await passing.value
        XCTAssertEqual(second?.text, "answer two")
        let kept = await bridge.current
        XCTAssertEqual(kept.pending?.person, "n1", "the bound reply was lost: \(kept)")
        XCTAssertEqual(kept.pending?.text, "answer one")
        // A second hear of the words, their nonce in `settled`: nothing more is given.
        let again = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        XCTAssertTrue(again, "words the guest holds were refused")
        for _ in 0..<3 { _ = try? await runner.answerPending(model: .sonnet5) }
        let turns = try await log(db)
        XCTAssertEqual(turns.map(\.text).sorted(), ["answer one", "answer two", "first question", "second question"])
        XCTAssertEqual(guest.inputs, ["first question", "second question", "second question"],
                       "the guest was given the words twice, or told what it had")
        let after = await bridge.current
        XCTAssertNil(after.pending)
        XCTAssertEqual(after.early ?? [], [])
    }

    // MARK: what a `.superseded` record carried, across iterations

    /// The guest is cut off on the watch's second question (X, in `pending`), having been given
    /// the first ahead (an Early, answered or cut off). The log then holds first → third, and
    /// the pass for the third moves past X. Answers what the guest was sent, in order.
    private func movingPast(earlyCutOff: Bool, bind: BindMoment) async throws -> [String] {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, earlyCutOff ? .cutOff : .reply("answer one"), .cutOff,
                                                       .reply("answer three"), .reply("EXTRA"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        let wanted: GuestLedger.Pending.State = earlyCutOff ? .unresolved : .answered
        try await eventually("the end of the words given ahead") { await bridge.current.early?.first?.state == wanted }
        let p2 = try await write(db, .person, "second question", device: "watch")
        _ = try? await runner.answerPending(model: .sonnet5)
        let cut = await bridge.current
        XCTAssertEqual(cut.pending?.state, .unresolved, "control: the second question was cut off")
        XCTAssertEqual(guest.inputs, ["first question", "second question"], "control")
        let p1 = try await TurnLog(database: db).writer(for: phone).append(.person, "first question", parents: [p2.ref], nonce: "n1")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "third question", parents: [p1.ref])
        let reply = TurnRunner.replyNonce(for: [p1.ref])
        switch bind {
        case .beforeThePass:
            await bridge.bind(nonce: "n1", person: p1, reply: reply)
            _ = try? await runner.answerPending(model: .sonnet5)
        case .never, .duringTheWait:
            guest.holdReady()
            let passing = Task { try? await runner.answerPending(model: .sonnet5) }
            try await eventually("the pass waiting for the guest") { guest.readyHeld }
            let moved = await bridge.current
            XCTAssertNil(moved.pending, "control: the cut-off record was moved past before the wait")
            if bind == .duringTheWait { await bridge.bind(nonce: "n1", person: p1, reply: reply) }
            guest.releaseReady()
            _ = await passing.value
        }
        for _ in 0..<3 { _ = try? await runner.answerPending(model: .sonnet5) }
        let turns = try await log(db)
        XCTAssertTrue(turns.map(\.text).contains("answer three"), "control: the third question was answered: \(turns.map(\.text))")
        return guest.inputs
    }

    /// Control: with no bind, what the cut-off record carried rides on the request's own.
    func testMovingPastWithNoBindTellsTheCutOffTurnOnce() async throws {
        let inputs = try await movingPast(earlyCutOff: true, bind: .never)
        XCTAssertEqual(inputs.filter { $0.contains("second question") }.count, 1, "\(inputs)")
        XCTAssertEqual(inputs.last, "third question")
    }

    /// The new path: X is moved past in the first iteration; the bind made during the wait (a
    /// cut-off Early) is moved past in the second, and `received = pending.covers` forgets X's.
    func testMovingPastTwiceAcrossTheWaitTellsTheCutOffTurnOnce() async throws {
        let inputs = try await movingPast(earlyCutOff: true, bind: .duringTheWait)
        XCTAssertEqual(inputs.filter { $0.contains("second question") }.count, 1, "the guest was told the cut-off turn again: \(inputs)")
    }

    /// The same two records met in one iteration (bound before the pass): the code the diff did
    /// not touch.
    func testMovingPastTwiceInOnePassTellsTheCutOffTurnOnce() async throws {
        let inputs = try await movingPast(earlyCutOff: true, bind: .beforeThePass)
        XCTAssertEqual(inputs.filter { $0.contains("second question") }.count, 1, "the guest was told the cut-off turn again: \(inputs)")
    }

    /// The accepted throw ("still to be written") after X was moved past in the first iteration.
    func testAnOwedBindAfterMovingPastTellsTheCutOffTurnOnce() async throws {
        let inputs = try await movingPast(earlyCutOff: false, bind: .duringTheWait)
        XCTAssertEqual(inputs.filter { $0.contains("first question") }.count, 1, "the words given ahead went twice: \(inputs)")
        XCTAssertEqual(inputs.filter { $0.contains("second question") }.count, 1, "the guest was told the cut-off turn again: \(inputs)")
    }

    // MARK: three iterations

    /// Two Earlies, one answered and one cut off, bound one in each of two waits: the request
    /// goes round twice and stops on the reply that is owed.
    func testABindInEachOfTwoWaits() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"), .cutOff, .reply("answer three"), .reply("EXTRA"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        _ = await bridge.hear("second question", nonce: "n2", context: [], model: .sonnet5)
        try await eventually("the second cut off") { await bridge.current.early?.last?.state == .unresolved }
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        let p2 = try await writer.append(.person, "second question", parents: [p1.ref], nonce: "n2")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "third question", parents: [p2.ref])
        let uses = guest.models.count
        guest.holdReady()
        let passing = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the first wait") { guest.readyHeld }
        await bridge.bind(nonce: "n2", person: p2, reply: TurnRunner.replyNonce(for: [p2.ref]))
        guest.releaseReady()
        guest.holdReady()
        try await eventually("the second wait") { guest.readyHeld && guest.models.count - uses == 2 }
        let between = await bridge.current
        XCTAssertNil(between.pending, "control: the cut-off bind was moved past")
        await bridge.bind(nonce: "n1", person: p1, reply: TurnRunner.replyNonce(for: [p1.ref]))
        guest.releaseReady()
        let first = await passing.result
        if case .failure(let error) = first, error as? GuestBridgeError == Self.owedFirst {} else { XCTFail("the pass: \(first)") }
        XCTAssertEqual(guest.models.count - uses, 2, "the request went round more often than there were binds")
        let kept = await bridge.current
        XCTAssertEqual(kept.pending?.person, "n1", "the bound reply was lost: \(kept)")
        XCTAssertEqual(guest.inputs, ["first question", "second question"], "something was sent: \(guest.inputs)")
    }

    // MARK: a sign-out during the wait

    func testASignOutWhileTheRequestWaitsOverAKeptBindWritesNothing() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"), .reply("SENT AFTER THE SIGN-OUT"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "second question", parents: [p1.ref])
        guest.holdReady()
        let passing = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the pass waiting for the guest") { guest.readyHeld }
        let reply = TurnRunner.replyNonce(for: [p1.ref])
        await bridge.bind(nonce: "n1", person: p1, reply: reply)
        await bridge.forget()
        // A bind that arrives after the sign-out has nothing to bind.
        await bridge.bind(nonce: "n1", person: p1, reply: reply)
        guest.releaseReady()
        let result = await passing.result
        if case .failure(let error) = result, error is CancellationError {} else { XCTFail("the pass: \(result)") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(guest.inputs, ["first question"], "something reached the guest after the sign-out")
        let ledger = await bridge.current
        XCTAssertEqual(ledger, GuestLedger(), "the ledger holds something from before the sign-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a ledger was written after the sign-out")
    }

    /// The same in the second wait, the request having written (a moved-past record cleared) on
    /// its way round.
    func testASignOutInTheSecondWaitWritesNothing() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .cutOff, .reply("SENT AFTER THE SIGN-OUT"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the words cut off") { await bridge.current.early?.first?.state == .unresolved }
        let writer = try await TurnLog(database: db).writer(for: phone)
        let p1 = try await writer.append(.person, "first question", parents: [], nonce: "n1")
        _ = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "second question", parents: [p1.ref])
        let uses = guest.models.count
        guest.holdReady()
        let passing = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the first wait") { guest.readyHeld }
        await bridge.bind(nonce: "n1", person: p1, reply: TurnRunner.replyNonce(for: [p1.ref]))
        guest.releaseReady()
        guest.holdReady()
        try await eventually("the second wait") { guest.readyHeld && guest.models.count - uses == 2 }
        await bridge.forget()
        guest.releaseReady()
        let result = await passing.result
        if case .failure(let error) = result, error is CancellationError {} else { XCTFail("the pass: \(result)") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(guest.inputs, ["first question"], "something reached the guest after the sign-out")
        let ledger = await bridge.current
        XCTAssertEqual(ledger, GuestLedger(), "the ledger holds something from before the sign-out")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a ledger was written after the sign-out")
    }

    // MARK: a cut-off bind for a turn the waiting request never read

    /// The PR's own test with the words cut off rather than answered, and their turn saved beside
    /// the watch's while the request waits: a head the request's read does not hold, and so one
    /// its reply does not go on from. The bound record is the only thing that says the guest
    /// received the words and was cut off.
    func testACutOffBindWhileARequestThatNeverReadItsTurnWaitsForTheGuest() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .cutOff, .reply("answer two"), .reply("ASKED AGAIN"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the words cut off") { await bridge.current.early?.first?.state == .unresolved }
        try await write(db, .person, "second question", device: "watch")
        guest.holdReady()
        let passing = Task { try await runner.answerPending(model: .sonnet5) }
        try await eventually("the pass waiting for the guest") { guest.readyHeld }
        // The words' own turn reaches the log now, beside the watch's, and is bound. (Written by
        // another device than the runner's so the test's two writers do not race for a sequence.)
        let p1 = try await TurnLog(database: db).writer(for: DeviceID("ipad")).append(.person, "first question", parents: [], nonce: "n1")
        await bridge.bind(nonce: "n1", person: p1, reply: TurnRunner.replyNonce(for: [p1.ref]))
        let bound = await bridge.unresolved()
        XCTAssertEqual(bound, [p1.ref], "control: the bound record says the turn was cut off")
        guest.releaseReady()
        let second = await passing.result
        let kept = await bridge.current
        XCTAssertTrue(kept.pending?.person == "n1" || (kept.early ?? []).contains { $0.bound?.person == "n1" },
                      "the cut-off bound record was lost (the pass: \(second)): \(kept)")
        let stillCutOff = await bridge.unresolved()
        XCTAssertEqual(stillCutOff, [p1.ref], "nothing says the turn was cut off any more")
        for _ in 0..<3 { _ = try? await runner.answerPending(model: .sonnet5) }
        let turns = try await log(db)
        XCTAssertEqual(guest.inputs.filter { $0.contains("first question") }.count, 1,
                       "words the guest was cut off on were given to it again, unasked: \(guest.inputs); log \(turns.map(\.text))")
    }

    /// Control: the same turns, read by the request before it began. Its reply goes on from both
    /// heads, so the cut-off turn is moved past, and is never asked again.
    func testACutOffBindBeforeTheRequestReadsItsTurnIsMovedPast() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .cutOff, .reply("answer two"), .reply("ASKED AGAIN"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the words cut off") { await bridge.current.early?.first?.state == .unresolved }
        try await write(db, .person, "second question", device: "watch")
        let p1 = try await TurnLog(database: db).writer(for: DeviceID("ipad")).append(.person, "first question", parents: [], nonce: "n1")
        await bridge.bind(nonce: "n1", person: p1, reply: TurnRunner.replyNonce(for: [p1.ref]))
        for _ in 0..<4 { _ = try? await runner.answerPending(model: .sonnet5) }
        let turns = try await log(db)
        XCTAssertTrue(turns.map(\.text).contains("answer two"), "control: the watch's turn was answered: \(turns.map(\.text))")
        XCTAssertEqual(guest.inputs.filter { $0.contains("first question") }.count, 1,
                       "words the guest was cut off on were given to it again, unasked: \(guest.inputs)")
    }

    // MARK: after the record: `residentPID`, then `send`

    /// The request has written its record and waits on `residentPID`. A bind lands behind it;
    /// another device's reply under the request's nonce is found in the log (`landed`), which
    /// promotes the bound record; then the guest refuses the send, and the refusal's
    /// `record(nil)` (GuestBridge.swift:491) is not asked whose record it clears.
    func testARefusedSendAfterItsRecordWasLandedClearsOnlyItsOwn() async throws {
        let db = InMemoryRecordDatabase()
        let scripted = ScriptedGuest(home: home, script: [.reply("answer one"), .reply("ASKED AGAIN")])
        let guest = PIDGatedGuest(scripted)
        let bridge = GuestBridge(conversation: guest, ledger: ledgerFile)
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        let p1 = try await TurnLog(database: db).writer(for: phone).append(.person, "first question", parents: [], nonce: "n1")
        let p2 = try await TurnLog(database: db).writer(for: DeviceID("watch")).append(.person, "second question", parents: [p1.ref])
        let first = TurnRunner.replyNonce(for: [p1.ref]), second = TurnRunner.replyNonce(for: [p2.ref])
        guest.holdPID()
        let asking = Task {
            try await bridge.answer(BrainRequest(context: [p1], answering: [p2], parents: [p2.ref], nonce: second, model: .sonnet5))
        }
        try await eventually("the request recorded and about to send") { guest.pidHeld }
        let recorded = await bridge.current.pending?.nonce
        XCTAssertEqual(recorded, second, "control: the request's own record is written")
        await bridge.bind(nonce: "n1", person: p1, reply: first)
        let theirs = try await TurnLog(database: db).writer(for: DeviceID("hub"))
            .append(.assistant, "the hub's answer", parents: [p2.ref], nonce: second)
        await bridge.landed(theirs, nonce: second)
        let promoted = await bridge.current.pending?.person
        XCTAssertEqual(promoted, "n1", "control: the bound record took pending when the request's landed")
        scripted.refuse("the resident process went away")
        guest.releasePID()
        let result = await asking.result
        if case .failure = result {} else { XCTFail("control: the send was refused: \(result)") }
        scripted.refuse(nil)
        let kept = await bridge.current
        XCTAssertEqual(kept.pending?.person, "n1", "the refused send cleared a record that was not its own: \(kept)")
        let answer = try await bridge.answer(BrainRequest(context: [], answering: [p1], parents: [p1.ref], nonce: first, model: .sonnet5))
        XCTAssertEqual(answer.text, "answer one", "the reply is not the one the guest made of the words it heard")
        XCTAssertEqual(scripted.inputs.filter { $0.contains("first question") }.count, 1, "the guest was given the words twice: \(scripted.inputs)")
    }
}


extension GuestBridgeTests {
    /// The reply's save failed, and a hub then answers a fork the turn is one head of, under the
    /// fork's nonce: this phone still owes its reply under the turn's own, and draws it until
    /// that one lands.
    func testAnOwedReplyStaysDrawnWhenAnotherDeviceAnswersAForkOfItsTurn() async throws {
        let db = RefusingReplies()
        let guest = ScriptedGuest(home: home, script: [.reply("Paris.")])
        let (harness, _) = harness(db, guest)
        await harness.refresh()
        await harness.answerPending()
        await db.refuse(true)
        let nonce = harness.willSend("capital of France?")
        await harness.retry()
        let person = try XCTUnwrap(harness.turns.first { $0.nonce == nonce })
        let log = TurnLog(database: db.wrapped)
        let other = try await log.writer(for: DeviceID("watch")).append(.person, "and the weather?", parents: [])
        _ = try await log.writer(for: DeviceID("hub")).append(.assistant, "The hub's, to both.", parents: [person.ref, other.ref],
                                                              nonce: TurnRunner.replyNonce(for: [person.ref, other.ref]))
        await harness.refresh()
        XCTAssertTrue(harness.answered(nonce), "control: the log holds a reply naming the turn")
        XCTAssertEqual(harness.replies[nonce], "Paris.", "a reply this phone still owes went from the screen")
        XCTAssertEqual(NextTurn().behind(in: harness).map(\.text), ["Paris."])
        await db.refuse(false)
        await harness.answerPending()
        XCTAssertTrue(harness.turns.contains { $0.text == "Paris." && $0.parents == [person.ref] }, "the owed reply was not written")
        XCTAssertTrue(harness.replies.isEmpty, "a landed reply is still drawn as unsaved")
        XCTAssertEqual(guest.inputs.filter { $0.contains("capital of France?") }.count, 1)
    }

    /// A ledger from before answered records kept their words, one answered and not yet landed:
    /// a reply found under its nonce cannot be told from another device's, so the guest is told it.
    func testAnAnsweredRecordWithNoWordsDoesNotCountAReplyFoundUnderItsNonceSeen() async throws {
        let old = #"{"seen":{"runs":{}},"pending":{"input":"i","nonce":"reply","parents":[],"answering":[],"covers":{"runs":{}},"sentAt":0,"state":"answered","askAgain":false}}"#
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(old.utf8).write(to: ledgerFile)
        let db = InMemoryRecordDatabase()
        let (_, bridge, _) = try await launch(db)
        let theirs = try await TurnLog(database: db).writer(for: DeviceID("hub")).append(.assistant, "the hub's", parents: [], nonce: "reply")
        await bridge.landed(theirs, nonce: "reply")
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending, "the record is settled by the reply in the log")
        XCTAssertFalse(ledger.seen.contains(theirs.ref), "a reply the guest may never have seen was counted seen")
    }

    /// The guest was cut off on the watch's question, and the request for a turn it heard ahead
    /// moves past that record on its way to the heard reply: what the cut-off input told the
    /// guest goes with the reply's record, so it is not told again.
    func testAHeardReplyReachedPastACutOffRecordCarriesWhatThatRecordTold() async throws {
        let db = InMemoryRecordDatabase()
        let (runner, bridge, guest) = try await launch(db, .reply("answer one"), .cutOff, .reply("EXTRA"))
        _ = await bridge.hear("first question", nonce: "n1", context: [], model: .sonnet5)
        try await eventually("the first answer") { await bridge.unsaved()["n1"] == "answer one" }
        let p2 = try await write(db, .person, "second question", device: "watch")
        _ = try? await runner.answerPending(model: .sonnet5)
        let cut = await bridge.current.pending?.state
        XCTAssertEqual(cut, .unresolved, "control: the second question was cut off")
        let p1 = try await TurnLog(database: db).writer(for: phone).append(.person, "first question", parents: [p2.ref], nonce: "n1")
        let nonce = TurnRunner.replyNonce(for: [p1.ref])
        let answer = try await bridge.answer(BrainRequest(context: [p2], answering: [p1], parents: [p1.ref], nonce: nonce, model: .sonnet5))
        XCTAssertEqual(answer.text, "answer one")
        XCTAssertEqual(guest.inputs, ["first question", "second question"], "control: nothing more was sent")
        let kept = await bridge.current.pending
        XCTAssertEqual(kept?.nonce, nonce)
        XCTAssertEqual(kept?.covers.contains(p2.ref), true, "what the cut-off input told the guest is in no record")
    }

    /// A spoken turn answered with iCloud away: the speaker's wait for that turn's reply ends
    /// when the guest is done, read as it was written, and nothing keeps the process awake for
    /// a landing that is not read.
    func testASpokenTurnAnsweredInAnOutageEndsTheSpeakersWait() async throws {
        let db = Outage()
        let guest = ScriptedGuest(home: home, script: [.reply("Paris.")])
        let (harness, _) = harness(db, guest)
        await harness.refresh()
        await harness.answerPending()
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let voice = Voice(engine: ScriptedVoice())
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        try await eventually("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center, makeEngine: { seams.makePlayEngine(rate: Voice.rate) })
        SpokenReply.follow(harness, speaker: speaker)
        await db.away(true)

        let nonce = harness.willSend("capital of France?")
        XCTAssertTrue(speaker.awaitReply(nonce, readAloud: true).held)
        harness.markSpoken(nonce)
        XCTAssertEqual(speaker.awaiting, [nonce], "control: the wait stands")
        await harness.retry()
        try await eventually("the reply") { harness.replies[nonce] == "Paris." }
        try await eventually("the wait to end") { speaker.awaiting.isEmpty }
        XCTAssertEqual(speaker.report.speaks, 1, "the reply was not read as it was written")
        XCTAssertTrue(harness.turns.isEmpty, "control: nothing landed")
    }
}
