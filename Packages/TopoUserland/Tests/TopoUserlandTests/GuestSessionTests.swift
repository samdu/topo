import XCTest
@testable import TopoUserland

/// The resident session against a scripted process and a clock moved by hand: turns one at a time,
/// the way out (a turn finished inside the grace, one abandoned at the teardown point), the way
/// back (resumed by the kept session id), and the ways a turn can end without its result.
final class GuestSessionTests: XCTestCase {
    private var directory: URL!
    private var launcher: ScriptedLauncher!
    private var clock: ManualClock!
    private let bound: Duration = .seconds(180)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)")
        launcher = ScriptedLauncher()
        clock = ManualClock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: SessionFile { SessionFile(url: directory.appendingPathComponent(".guest-session")) }

    private func session() -> GuestSession {
        GuestSession(launcher: launcher, store: store, turnBound: bound, sleep: clock.sleep)
    }

    /// A session with its process resident, in the foreground.
    private func resident() async throws -> (GuestSession, ScriptedProcess) {
        let session = session()
        await session.foreground()
        try await session.ready()
        return (session, try XCTUnwrap(launcher.last))
    }

    /// Collects a turn's updates until it ends.
    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [GuestSession.TurnUpdate] = []
        var updates: [GuestSession.TurnUpdate] { lock.withLock { all } }
        func add(_ update: GuestSession.TurnUpdate) { lock.withLock { all.append(update) } }
        var ends: [GuestSession.TurnEnd] {
            updates.compactMap { if case .ended(let end) = $0 { return end } else { return nil } }
        }
        var events: [StreamEvent] {
            updates.compactMap { if case .event(let event) = $0 { return event } else { return nil } }
        }
    }

    private func collect(_ stream: AsyncStream<GuestSession.TurnUpdate>) -> (Collected, Task<Void, Never>) {
        let collected = Collected()
        let task = Task { for await update in stream { collected.add(update) } }
        return (collected, task)
    }

    private func answer(_ process: ScriptedProcess, _ text: String, session id: String = "S1") {
        process.emit(Lines.`init`(id))
        process.emit(Lines.text(text))
        process.emit(Lines.result(text, session: id))
    }

    // MARK: - Turns

    func testTwoTurnsGoToOneResidentProcessAndTheSessionIdIsKept() async throws {
        let (session, process) = try await resident()
        XCTAssertEqual(launcher.resumed, [nil], "a first start resumes nothing")

        let (first, firstDone) = collect(try await session.send("remember marmalade"))
        await eventually("the first turn written") { process.turns.count == 1 }
        answer(process, "ok")
        await firstDone.value
        XCTAssertEqual(first.ends, [.answered(.init(isError: false, subtype: "success", text: "ok", session: "S1",
                                                   duration: .milliseconds(1200)))])
        XCTAssertTrue(first.events.contains(.started(session: "S1", model: "claude-haiku-4-5-20251001")))
        XCTAssertTrue(first.events.contains(.usage(.init(model: "claude-haiku-4-5-20251001", context: 113, output: 5))))

        let (second, secondDone) = collect(try await session.send("which word?"))
        await eventually("the second turn written") { process.turns.count == 2 }
        answer(process, "marmalade")
        await secondDone.value
        XCTAssertEqual(second.ends.count, 1)
        XCTAssertEqual(launcher.processes.count, 1, "the second turn started a second process")
        XCTAssertEqual(process.turns, ["remember marmalade", "which word?"])
        XCTAssertEqual(store.load(), "S1")
    }

    func testASecondSendWhileATurnIsInFlightIsRefused() async throws {
        let (session, process) = try await resident()
        let (first, done) = collect(try await session.send("one"))
        do {
            _ = try await session.send("two")
            XCTFail("a second turn was taken while the first was in flight")
        } catch GuestSession.Refusal.turnInFlight {
        }
        XCTAssertEqual(process.turns, ["one"], "the refused turn reached the process")
        answer(process, "done")
        await done.value
        XCTAssertEqual(first.ends.count, 1)
        _ = try await session.send("two")
        await eventually("the next turn after the first ended") { process.turns == ["one", "two"] }
    }

    func testNothingIsSentWithNothingResident() async throws {
        let session = session()
        do {
            _ = try await session.send("hello")
            XCTFail("a turn was taken with nothing resident")
        } catch GuestSession.Refusal.notResident {
        }
        do {
            try await session.ready()
            XCTFail("ready in the background")
        } catch GuestSession.Refusal.notResident {
        }
        XCTAssertTrue(launcher.processes.isEmpty)
    }

    // MARK: - The stream

    func testAMalformedLineOrAnUnknownEventIsReportedAndTheTurnGoesOn() async throws {
        let (session, process) = try await resident()
        let (turn, done) = collect(try await session.send("hi"))
        await eventually("written") { process.turns.count == 1 }
        process.emit("not json at all")
        process.emit(#"{"type":"future_event","subtype":"shiny"}"#)
        process.emit(#"{"type":"result","is_error":false,"subtype":"success","result":"hi","session_id":"S1"}"#.replacingOccurrences(of: "\"type\":\"result\",", with: ""))
        answer(process, "hi")
        await done.value
        XCTAssertTrue(turn.events.contains(.malformed("not json at all")))
        XCTAssertTrue(turn.events.contains(.other("future_event/shiny")))
        XCTAssertEqual(turn.ends.count, 1)
        guard case .answered = turn.ends.first else { return XCTFail("\(turn.ends)") }
    }

    func testAnErrorResultFailsTheTurnAndKeepsTheProcess() async throws {
        let (session, process) = try await resident()
        let (turn, done) = collect(try await session.send("hi"))
        await eventually("written") { process.turns.count == 1 }
        process.emit(Lines.`init`("S1"))
        process.emit(Lines.result("API Error: 529 overloaded", session: "S1", error: true))
        await done.value
        guard case .failed(.result(let result)) = turn.ends.first else { return XCTFail("\(turn.ends)") }
        XCTAssertEqual(result.text, "API Error: 529 overloaded")
        XCTAssertFalse(process.terminated, "an error Claude Code reported itself restarted a healthy process")
        _ = try await session.send("again")
    }

    func testTheProcessEndingMidTurnFailsItWithItsStderrAndNothingOfItReachesTheNext() async throws {
        let (session, process) = try await resident()
        process.errors = "panic: something\n"
        let (turn, done) = collect(try await session.send("hi"))
        await eventually("written") { process.turns.count == 1 }
        process.emit(Lines.`init`("S1"))
        process.close()
        await done.value
        XCTAssertEqual(turn.ends, [.failed(.exited("panic: something\n"))])
        // A process that died mid-turn is replaced, resuming the session it had begun.
        await eventually("a replacement") { launcher.processes.count == 2 }
        try await session.ready()
        XCTAssertEqual(launcher.resumed, [nil, "S1"])
        let next = try XCTUnwrap(launcher.last)
        let (second, secondDone) = collect(try await session.send("next"))
        process.emit(Lines.result("stale", session: "S1"))
        await eventually("written") { next.turns.count == 1 }
        answer(next, "fresh")
        await secondDone.value
        XCTAssertEqual(second.ends.count, 1)
        guard case .answered(let result) = second.ends.first else { return XCTFail("\(second.ends)") }
        XCTAssertEqual(result.text, "fresh")
        XCTAssertEqual(process.turns, ["hi"], "a turn was sent again")
    }

    func testATurnSilentPastTheBoundFailsTheProcessRestartsAndItsLateEventsGoNowhere() async throws {
        let (session, process) = try await resident()
        let (turn, done) = collect(try await session.send("hi"))
        await eventually("written") { process.turns.count == 1 }
        process.emit(Lines.`init`("S1"))
        await eventually("the watchdog asleep") { await clock.pending == 1 }
        // A line inside the bound resets it.
        await clock.advance(by: .seconds(170))
        process.emit(Lines.text("thinking"))
        await eventually("the line counted") { turn.events.count >= 2 }
        await clock.advance(by: .seconds(20))
        await eventually("the watchdog asleep again") { await clock.pending == 1 }
        XCTAssertTrue(turn.ends.isEmpty, "a turn that was still talking was ended")
        await clock.advance(by: bound)
        await done.value
        XCTAssertEqual(turn.ends, [.failed(.silent(bound))])
        await eventually("the silent process ended") { process.terminated }
        await eventually("a replacement") { launcher.processes.count == 2 }
        try await session.ready()
        let next = try XCTUnwrap(launcher.last)
        let (second, secondDone) = collect(try await session.send("next"))
        process.emit(Lines.result("late answer", session: "S1"))
        await eventually("written") { next.turns.count == 1 }
        answer(next, "on time")
        await secondDone.value
        guard case .answered(let result) = second.ends.first else { return XCTFail("\(second.ends)") }
        XCTAssertEqual(result.text, "on time")
        XCTAssertFalse(second.events.contains(.text("late answer")))
    }

    // MARK: - The way out and back

    func testATurnFinishingInsideTheGraceIsDeliveredOnceAndTheNextForegroundResumes() async throws {
        let (session, process) = try await resident()
        let (turn, done) = collect(try await session.send("long one"))
        await eventually("written") { process.turns.count == 1 }
        process.emit(Lines.`init`("S1"))

        let background = Task { await session.background(budget: .seconds(15)) }
        await eventually("the teardown waiting on the turn") { await clock.pending == 2 }
        XCTAssertFalse(process.terminated, "the process was ended with its turn still inside the grace")
        answer(process, "finished", session: "S1")
        let outcome = await background.value
        await done.value

        XCTAssertEqual(turn.ends.count, 1)
        guard case .answered = turn.ends.first else { return XCTFail("\(turn.ends)") }
        guard case .ended(.finished, let termination) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(termination.confirmed)
        XCTAssertTrue(process.terminated)
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .idle, "something is resident in the background")
        XCTAssertEqual(process.turns, ["long one"], "a turn was sent again")

        await session.foreground()
        try await session.ready()
        XCTAssertEqual(launcher.resumed, [nil, "S1"], "the next foreground did not resume the same session")
    }

    func testATurnStillRunningAtTheTeardownPointIsAbandonedOnceAndNeverSentAgain() async throws {
        let (session, process) = try await resident()
        let (turn, done) = collect(try await session.send("very long one"))
        await eventually("written") { process.turns.count == 1 }
        process.emit(Lines.`init`("S1"))

        let background = Task { await session.background(budget: .seconds(15)) }
        await eventually("the teardown waiting on the turn") { await clock.pending == 2 }
        await clock.advance(by: .seconds(15))
        let outcome = await background.value
        await done.value
        guard case .ended(.abandoned, let termination) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(termination.confirmed)
        XCTAssertEqual(turn.ends, [.abandoned])
        XCTAssertTrue(process.terminated)
        // What the ended process might still have said goes nowhere.
        process.emit(Lines.result("too late", session: "S1"))

        await session.foreground()
        try await session.ready()
        XCTAssertEqual(launcher.resumed, [nil, "S1"])
        XCTAssertEqual(process.turns, ["very long one"])
        XCTAssertEqual(launcher.last?.turns, [], "the abandoned turn was sent again")
        XCTAssertEqual(turn.ends, [.abandoned], "the abandoned turn ended twice")
    }

    func testAnIdleProcessIsEndedAtOnceOnTheWayOut() async throws {
        let (session, process) = try await resident()
        let outcome = await session.background(budget: .seconds(15))
        guard case .ended(nil, let termination) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(termination.confirmed)
        XCTAssertTrue(process.terminated)
        let pending = await clock.pending
        XCTAssertEqual(pending, 0, "the budget was waited out with no turn in flight")
    }

    func testTheExpirationHandlerEndsATeardownThatIsStillWaiting() async throws {
        let (session, process) = try await resident()
        let (turn, done) = collect(try await session.send("long"))
        await eventually("written") { process.turns.count == 1 }
        let background = Task { await session.background(budget: .seconds(15)) }
        await eventually("waiting") { await clock.pending == 2 }
        await session.expire()
        let outcome = await background.value
        await done.value
        guard case .ended(.abandoned, _) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(turn.ends, [.abandoned])
    }

    func testComingBackBeforeTheTeardownKeepsTheProcessAndItsTurn() async throws {
        let (session, process) = try await resident()
        let (turn, done) = collect(try await session.send("long"))
        await eventually("written") { process.turns.count == 1 }
        let background = Task { await session.background(budget: .seconds(15)) }
        await eventually("waiting") { await clock.pending == 2 }
        await session.foreground()
        let outcome = await background.value
        XCTAssertEqual(outcome, .kept)
        XCTAssertFalse(process.terminated)
        answer(process, "done")
        await done.value
        XCTAssertEqual(turn.ends.count, 1)
        XCTAssertEqual(launcher.processes.count, 1)
    }

    func testABackgroundOlderThanTheForegroundAfterItChangesNothing() async throws {
        let session = session()
        await session.foreground(generation: 1)
        try await session.ready()
        let process = try XCTUnwrap(launcher.last)
        await session.foreground(generation: 3)
        let outcome = await session.background(budget: .seconds(15), generation: 2)
        XCTAssertEqual(outcome, .kept)
        XCTAssertFalse(process.terminated, "a stale background ended the process the foreground wanted")
    }

    // MARK: - Races

    func testBackgroundWhileTheStartIsPendingLeavesNothingResident() async throws {
        let session = session()
        launcher.holdNextLaunch()
        await session.foreground()
        await eventually("the start pending") { launcher.launchHeld }
        let background = Task { await session.background(budget: .seconds(15)) }
        // Give the background call the actor before the start lands.
        await eventually("the background waiting on the start") { await session.currentPhase == .starting }
        try? await Task.sleep(for: .milliseconds(50))
        launcher.release()
        _ = await background.value
        let process = try XCTUnwrap(launcher.last)
        XCTAssertTrue(process.terminated, "a start that landed in the background was left running")
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .idle)
    }

    func testForegroundWhileTheTeardownIsPendingKeepsTheReplacementAlive() async throws {
        let (session, process) = try await resident()
        process.holdNextTermination()
        let background = Task { await session.background(budget: .seconds(15)) }
        await eventually("the teardown pending") { process.terminationHeld }
        await session.foreground()
        process.release()
        let outcome = await background.value
        guard case .ended = outcome else { return XCTFail("\(outcome)") }
        await eventually("a replacement") { launcher.processes.count == 2 }
        try await session.ready()
        let replacement = try XCTUnwrap(launcher.last)
        XCTAssertFalse(replacement.terminated, "the pending teardown ended the replacement")
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .resident)
        _ = try await session.send("after")
        await eventually("the replacement took the turn") { replacement.turns == ["after"] }
    }

    // MARK: - Resume

    func testAResumeThatFailsStartsFreshAndSaysSo() async throws {
        store.save("GONE")
        let session = session()
        await session.foreground()
        try await session.ready()
        let first = try XCTUnwrap(launcher.last)
        XCTAssertEqual(launcher.resumed, ["GONE"])
        // What a resume of a session that is not on disk writes, then its exit.
        first.errors = "No conversation found with session ID: GONE\n"
        first.emit(Lines.result("", session: "GONE", error: true))
        first.close()
        await eventually("a fresh start") { launcher.processes.count == 2 }
        XCTAssertEqual(launcher.resumed, ["GONE", nil])
        XCTAssertNil(store.load(), "the session that failed to resume is still kept")
        try await session.ready()
        let fresh = try XCTUnwrap(launcher.last)
        let (turn, done) = collect(try await session.send("hello"))
        await eventually("written") { fresh.turns.count == 1 }
        answer(fresh, "hi", session: "S2")
        await done.value
        XCTAssertEqual(turn.ends.count, 1)
        XCTAssertEqual(store.load(), "S2")
    }

    // MARK: - The model and the conversation

    /// A change of model during a turn is made once the turn has ended: the process answering it is
    /// not ended under it, and the next process is started with the new model.
    func testAModelChangeDuringATurnRestartsTheProcessOnlyAfterTheTurnEnds() async throws {
        let session = GuestSession(launcher: launcher, store: store, model: "claude-sonnet-5", turnBound: bound,
                                   sleep: clock.sleep)
        await session.foreground()
        try await session.ready()
        let first = try XCTUnwrap(launcher.last)
        let (turn, done) = collect(try await session.send("a long one", id: "input-1"))
        await eventually("written") { first.turns.count == 1 }
        XCTAssertEqual(first.ids, ["input-1"], "the input's id went out with it")

        await session.use(model: "claude-opus-5")
        // Give the actor every chance to act on the change while the turn is in flight.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(first.terminated, "the model change ended the process mid-turn")
        XCTAssertEqual(launcher.processes.count, 1)

        answer(first, "done")
        await done.value
        XCTAssertEqual(turn.ends.count, 1)
        await eventually("the process replaced after the turn") { launcher.processes.count == 2 }
        XCTAssertTrue(first.terminated)
        XCTAssertEqual(launcher.models, ["claude-sonnet-5", "claude-opus-5"])
        XCTAssertEqual(launcher.resumed, [nil, "S1"], "the replacement resumes the conversation")
        try await session.ready()
        _ = try await session.send("next")
        await eventually("the replacement took the next turn") { launcher.last?.turns == ["next"] }
    }

    /// An idle process is replaced at once, and the same model again changes nothing.
    func testAModelChangeWhileIdleRestartsAtOnceAndTheSameModelDoesNot() async throws {
        let session = GuestSession(launcher: launcher, store: store, model: "claude-sonnet-5", turnBound: bound,
                                   sleep: clock.sleep)
        await session.foreground()
        try await session.ready()
        await session.use(model: "claude-sonnet-5")
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(launcher.processes.count, 1, "the same model restarted the process")
        await session.use(model: "claude-fable-5-1")
        await eventually("replaced") { launcher.processes.count == 2 }
        XCTAssertEqual(launcher.models, ["claude-sonnet-5", "claude-fable-5-1"])
        let model = await session.currentModel
        XCTAssertEqual(model, "claude-fable-5-1")
    }

    /// Forgetting the conversation clears the kept id, and the replacement starts fresh.
    func testForgettingTheConversationStartsAFreshSession() async throws {
        store.save("OLD")
        let session = session()
        await session.foreground()
        try await session.ready()
        await session.forgetSession()
        XCTAssertNil(store.load())
        await eventually("replaced") { launcher.processes.count == 2 }
        XCTAssertEqual(launcher.resumed, ["OLD", nil])
    }
}
