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
        let before = try GuestLedger.load(ledgerFile)
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
            "began 7 for phone/1 -> idle 0",
            "started -> idle 0",
            "text -> idle 0",
            "usage -> idle 1234",
            "ended answered -> idle 1234",
            "gone for phone/1 -> idle 1234",
        ])
        XCTAssertEqual(mascot.state.model, "claude-haiku-4-5-20251001")

        seen = []
        await harness.send("run the report")
        XCTAssertEqual(seen, [
            "began 7 for phone/3 -> idle 1234",
            "started -> idle 1234",
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

        harness.forget()
        try await eventually("the ledger to go") { !FileManager.default.fileExists(atPath: ledgerFile.path) }
        guest.releaseReady()
        let result = await waiting.result
        if case .success = result { XCTFail("an answer begun before the sign-out finished after it") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerFile.path), "a record was written after the sign-out")
        XCTAssertEqual(guest.inputs, ["the word is marmalade"], "an input was sent after the sign-out")
        let ledger = await bridge.current
        XCTAssertNil(ledger.pending)
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
