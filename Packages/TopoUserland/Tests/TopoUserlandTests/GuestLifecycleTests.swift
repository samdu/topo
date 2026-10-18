import XCTest
@testable import TopoUserland

/// The lifecycle between iOS and the session: the background task asked for on the way out, the
/// budget read a tick later, and the task ended once nothing is resident.
@MainActor
final class GuestLifecycleTests: XCTestCase {
    private final class FakeTime: BackgroundTime {
        var remaining: TimeInterval = .greatestFiniteMagnitude
        /// iOS refuses the next grace asked for.
        var refuseNext = false
        private(set) var begun: [Int] = []
        private(set) var ended: [Int] = []
        private var next = 100
        var expirations: [Int: @MainActor () -> Void] = [:]

        func begin(expiration: @escaping @MainActor () -> Void) -> Int {
            if refuseNext {
                refuseNext = false
                return GraceBudget.refused
            }
            next += 1
            begun.append(next)
            expirations[next] = expiration
            return next
        }

        func end(_ task: Int) { ended.append(task) }

        var open: [Int] { begun.filter { !ended.contains($0) } }
    }

    private final class FakeContinued: ContinuedTask {
        private(set) var completions: [Bool] = []
        private var handler: (@MainActor () -> Void)?
        func onExpiry(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
        func complete(success: Bool) { completions.append(success) }
        func expire() { handler?() }
        var open: Bool { completions.isEmpty }
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("lifecycle-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func make() -> (GuestLifecycle, GuestSession, ScriptedLauncher, ManualClock, FakeTime, Outcomes) {
        let launcher = ScriptedLauncher()
        let clock = ManualClock()
        let time = FakeTime()
        let session = GuestSession(launcher: launcher, store: SessionFile(url: directory.appendingPathComponent("s")),
                                   sleep: clock.sleep)
        let outcomes = Outcomes()
        let lifecycle = GuestLifecycle(session: session, time: time, sleep: clock.sleep,
                                       report: { outcomes.all.append($0) })
        return (lifecycle, session, launcher, clock, time, outcomes)
    }

    @MainActor
    private final class Outcomes {
        var all: [GuestSession.BackgroundOutcome] = []
    }

    func testTheBudgetIsTheGrantLessTheExpiryMarginAndTheReserve() {
        XCTAssertEqual(GraceBudget.teardownDelay(remaining: 28.2), .milliseconds(15_200))
        XCTAssertEqual(GraceBudget.teardownDelay(remaining: 10), .zero, "a short grant waits for nothing")
        XCTAssertEqual(GraceBudget.teardownDelay(remaining: .greatestFiniteMagnitude), .seconds(15),
                       "an infinite reading is taken as the measured grant")
        XCTAssertEqual(GraceBudget.teardownDelay(remaining: .infinity), .seconds(15))
        XCTAssertEqual(GraceBudget.teardownDelay(remaining: .nan), .seconds(15))
    }

    func testTheWayOutEndsTheProcessThenTheBackgroundTask() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)

        let turn = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        lifecycle.didEnterBackground()
        XCTAssertEqual(time.open.count, 1, "no background time was asked for")
        time.remaining = 28.2
        await eventually("the first tick asleep") { await clock.pending == 2 }
        await clock.advance(by: GraceBudget.firstTick)
        await eventually("the teardown waiting on the turn") { await clock.pending == 2 }
        XCTAssertEqual(time.open.count, 1, "the background task ended with the turn still running")
        await clock.advance(by: .milliseconds(15_200))
        await eventually("the background task ended") { time.open.isEmpty }
        XCTAssertTrue(process.terminated, "the process outlived the background task")
        XCTAssertEqual(outcomes.all.count, 1)
        guard case .ended(.abandoned, let termination)? = outcomes.all.first else { return XCTFail("\(outcomes.all)") }
        XCTAssertTrue(termination.confirmed)
        var ends: [GuestSession.TurnEnd] = []
        for await update in turn { if case .ended(let end) = update { ends.append(end) } }
        XCTAssertEqual(ends, [.abandoned])
    }

    func testComingBackWithinTheFirstTickEndsTheTaskAndEndsNothing() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        lifecycle.didEnterBackground()
        await eventually("the first tick asleep") { await clock.pending == 1 }
        lifecycle.willEnterForeground()
        await clock.advance(by: GraceBudget.firstTick)
        await eventually("the background task ended") { time.open.isEmpty }
        XCTAssertFalse(process.terminated)
        XCTAssertTrue(outcomes.all.isEmpty)
        XCTAssertEqual(launcher.processes.count, 1)
    }

    func testTheExpirationHandlerHoldsTheTaskUntilTheTeardownIsConfirmed() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let turn = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        lifecycle.didEnterBackground()
        time.remaining = 28
        await eventually("the first tick asleep") { await clock.pending == 2 }
        await clock.advance(by: GraceBudget.firstTick)
        await eventually("the teardown waiting") { await clock.pending == 2 }
        let task = try XCTUnwrap(time.open.first)
        process.holdNextTermination()
        time.expirations[task]?()
        await eventually("the teardown running") { process.terminationHeld }
        XCTAssertEqual(time.open, [task], "the background task ended with the process still alive")
        process.release()
        await eventually("the background task ended") { time.open.isEmpty }
        XCTAssertTrue(process.terminated)
        XCTAssertEqual(process.bounds, [GraceBudget.expiredTeardownBound],
                       "a teardown after the expiry was not bounded by what the handler leaves")
        guard case .ended(.abandoned, let termination)? = outcomes.all.first else { return XCTFail("\(outcomes.all)") }
        XCTAssertTrue(termination.confirmed)
        var ends: [GuestSession.TurnEnd] = []
        for await update in turn { if case .ended(let end) = update { ends.append(end) } }
        XCTAssertEqual(ends, [.abandoned])
    }

    func testATeardownStillRunningJustShortOfTheEndIsLetGoAndSaidSo() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        _ = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        lifecycle.didEnterBackground()
        time.remaining = 28
        await eventually("the first tick asleep") { await clock.pending == 2 }
        await clock.advance(by: GraceBudget.firstTick)
        await eventually("the teardown waiting") { await clock.pending == 2 }
        let task = try XCTUnwrap(time.open.first)
        process.holdNextTermination()
        time.expirations[task]?()
        await eventually("the teardown running") { process.terminationHeld }
        await eventually("the hold asleep") { await clock.pending == 1 }
        await clock.advance(by: GraceBudget.expiryHold - .milliseconds(1))
        XCTAssertEqual(time.open, [task], "the task was let go before the hold ran out")
        await clock.advance(by: .milliseconds(1))
        await eventually("the background task ended") { time.open.isEmpty }
        XCTAssertEqual(outcomes.all, [.outOfTime])
        process.release()
        await eventually("the teardown answered") { outcomes.all.count == 2 }
        XCTAssertEqual(time.ended.count, 1, "the task was ended twice")
    }

    func testAnExpiryFromABackgroundThatIsOverChangesNothing() async throws {
        let (lifecycle, session, launcher, clock, time, _) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        _ = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        await session.expire(generation: 0)
        lifecycle.didEnterBackground()
        time.remaining = 28
        await eventually("the first tick asleep") { await clock.pending == 2 }
        await clock.advance(by: GraceBudget.firstTick)
        await eventually("the teardown waiting on the turn, not ended at once") { await clock.pending == 2 }
        XCTAssertFalse(process.terminated)
    }

    func testAnEndTheBoundRunsOutOnStillEndsTheTaskAndSaysNotConfirmed() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let stuck = GuestProcess.Termination(status: nil, signalled: 13, running: 2, pipesClosed: false,
                                             elapsed: .milliseconds(7_010),
                                             stragglers: ["2 (claude, parent 1): exiting, last syscall 22"])
        process.answerNextEnd(with: stuck)
        lifecycle.didEnterBackground()
        time.remaining = 28
        await eventually("the first tick asleep") { await clock.pending == 1 }
        await clock.advance(by: GraceBudget.firstTick)
        // Holding the task past the grace gets the app killed, so an end the bound ran out on
        // lets the task go and says so, naming what stayed.
        await eventually("the background task ended") { time.open.isEmpty }
        XCTAssertEqual(process.bounds, [GraceBudget.teardownBound])
        XCTAssertEqual(outcomes.all, [.ended(turn: nil, termination: stuck)])
        XCTAssertEqual(outcomes.all.first?.description,
                       "ended, no turn in flight; termination NOT confirmed: not reaped, 13 signalled, 2 still running, pipes open, in 7010 ms; still there: 2 (claude, parent 1): exiting, last syscall 22")
    }

    // MARK: - The continued-processing task

    private func answer(_ process: ScriptedProcess, _ text: String) {
        process.emit(Lines.`init`("S1"))
        process.emit(Lines.text(text))
        process.emit(Lines.result(text, session: "S1"))
    }

    func testTheProgressRisesWithTimeAndNeverReachesTheEnd() {
        XCTAssertEqual(TurnProgress.completed(after: 0), 0)
        XCTAssertEqual(TurnProgress.completed(after: -1), 0)
        XCTAssertEqual(TurnProgress.completed(after: .nan), 0)
        XCTAssertEqual(TurnProgress.completed(after: TurnProgress.halfway), TurnProgress.total / 2)
        XCTAssertLessThan(TurnProgress.completed(after: 1e12), TurnProgress.total, "the bar filled before the turn ended")
        let tick = 2.0
        var elapsed = 0.0
        while elapsed < 3 * 3600 {
            XCTAssertGreaterThan(TurnProgress.completed(after: elapsed + tick), TurnProgress.completed(after: elapsed),
                                 "progress stood still at \(elapsed) s, which iOS expires")
            elapsed += tick
        }
    }

    func testATurnThatEndsInTheForegroundCompletesItsTask() {
        let (lifecycle, _, _, _, _, _) = make()
        lifecycle.willEnterForeground()
        let turn = lifecycle.turnBegan()
        let task = FakeContinued()
        lifecycle.held(task, turn: turn)
        XCTAssertTrue(lifecycle.holdsContinuedTask)
        lifecycle.turnEnded(turn, succeeded: true)
        XCTAssertEqual(task.completions, [true])
        XCTAssertFalse(lifecycle.holdsContinuedTask)
    }

    func testATaskArrivingAfterItsTurnEndedOrOnTheGraceIsCompletedAtOnce() async throws {
        let (lifecycle, session, _, _, time, _) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let fast = lifecycle.turnBegan()
        lifecycle.turnEnded(fast, succeeded: true)
        let late = FakeContinued()
        lifecycle.held(late, turn: fast)
        XCTAssertEqual(late.completions, [true], "a task for a turn already over was held")

        let turn = lifecycle.turnBegan()
        lifecycle.didEnterBackground()
        XCTAssertEqual(time.open.count, 1, "the grace was not begun with no task held")
        let after = FakeContinued()
        lifecycle.held(after, turn: turn)
        XCTAssertEqual(after.completions, [false], "a task arriving on the grace was held beside it")
        XCTAssertFalse(lifecycle.holdsContinuedTask)
    }

    func testTheContinuedTaskCarriesTheTurnPastTheGraceAndIsCompletedAfterTheTeardown() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        let turn = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)

        lifecycle.didEnterBackground()
        XCTAssertTrue(time.begun.isEmpty, "the grace was begun beside the continued task")
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        // Far past any grace, the turn still runs, its process speaking inside the watchdog's bound.
        for _ in 0..<4 {
            process.emit(Lines.text("working"))
            await clock.advance(by: .seconds(170))
            await eventually("the watchdog asleep again") { await clock.pending == 1 }
        }
        XCTAssertFalse(process.terminated, "the turn was cut off while the continued task held")
        XCTAssertTrue(task.open)

        process.holdNextTermination()
        answer(process, "done")
        var ends: [GuestSession.TurnEnd] = []
        for await update in turn { if case .ended(let end) = update { ends.append(end) } }
        guard case .answered? = ends.first else { return XCTFail("\(ends)") }
        lifecycle.turnEnded(number, succeeded: true)
        await eventually("the teardown running") { process.terminationHeld }
        XCTAssertTrue(task.open, "the task was completed with the process still alive")
        process.release()
        await eventually("the task completed") { !task.open }
        XCTAssertEqual(task.completions, [true])
        XCTAssertEqual(process.bounds, [GraceBudget.teardownBound])
        guard case .ended(.finished, let termination)? = outcomes.all.first else { return XCTFail("\(outcomes.all)") }
        XCTAssertTrue(termination.confirmed)
        XCTAssertTrue(time.begun.isEmpty)
    }

    func testAnExpiredContinuedTaskHandsTheTurnToTheGraceOnAGrantReadAtTheTick() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        let turn = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        await clock.advance(by: .seconds(120))

        task.expire()
        XCTAssertEqual(time.open.count, 1, "the grace was not begun at the expiry")
        XCTAssertTrue(task.open, "the expired task was completed before the grace's assertion could land")
        await eventually("the tick asleep") { await clock.pending == 2 }
        time.remaining = 25
        await clock.advance(by: GraceBudget.firstTick)
        await eventually("the task completed at the tick") { task.completions == [false] }
        XCTAssertEqual(outcomes.all, [.handedToGrace])
        await eventually("the deadline set") { await clock.pending == 2 }
        await clock.advance(by: .milliseconds(12_000 - 1))
        // The watchdog and the deadline both still asleep: the turn was not cut early.
        let standing = await clock.pending
        XCTAssertEqual(standing, 2, "the turn was cut before the grace's budget")
        XCTAssertFalse(process.terminated, "the turn was cut before the grace's budget")
        await clock.advance(by: .milliseconds(1))
        await eventually("the grace ended") { time.open.isEmpty }
        XCTAssertTrue(process.terminated)
        XCTAssertEqual(outcomes.all.count, 2)
        guard case .ended(.abandoned, _)? = outcomes.all.last else { return XCTFail("\(outcomes.all)") }
        var ends: [GuestSession.TurnEnd] = []
        for await update in turn { if case .ended(let end) = update { ends.append(end) } }
        XCTAssertEqual(ends, [.abandoned])
        lifecycle.turnEnded(number, succeeded: false)
        XCTAssertEqual(task.completions, [false], "the task was completed twice")
    }

    func testAnExpiryWithNoGrantReadAtTheTickEndsTheProcessAndHoldsTheTask() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        let turn = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        task.expire()
        await eventually("the tick asleep") { await clock.pending == 2 }
        process.holdNextTermination()
        // `time.remaining` is still infinite at the tick: a grace nothing has shown.
        await clock.advance(by: GraceBudget.firstTick)
        await eventually("the teardown running") { process.terminationHeld }
        XCTAssertEqual(outcomes.all, [.graceUnread])
        XCTAssertTrue(task.open, "the task was let go on a grace nothing has shown, the process alive")
        process.release()
        await eventually("the task completed") { !task.open }
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(process.bounds, [GraceBudget.expiredTeardownBound])
        for await _ in turn {}
    }

    func testAnUnreadGraceHoldsTheTaskThroughTheWholeExpiredTeardown() async throws {
        let (lifecycle, session, launcher, clock, _, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        _ = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        task.expire()
        await eventually("the tick asleep") { await clock.pending == 2 }
        process.holdNextTermination()
        await clock.advance(by: GraceBudget.firstTick)
        await eventually("the teardown running") { process.terminationHeld }
        await eventually("the hold asleep") { await clock.pending == 1 }
        // The teardown is told to end only at the tick, and may take its whole expired bound.
        await clock.advance(by: GraceBudget.expiredTeardownBound - .milliseconds(100))
        XCTAssertTrue(task.open, "the task was let go inside the expired teardown's bound, the process alive")
        process.release()
        await eventually("the task completed") { !task.open }
        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(outcomes.all.contains(.outOfTime), "\(outcomes.all)")
    }

    func testAnExpiredTaskGivingWayInFrontLeavesNoWayOutCarried() async throws {
        let (lifecycle, _, _, _, time, _) = make()
        lifecycle.willEnterForeground()
        let first = lifecycle.turnBegan()
        let one = FakeContinued()
        lifecycle.held(one, turn: first)
        lifecycle.didEnterBackground()
        one.expire()
        XCTAssertEqual(time.begun.count, 1)
        // Back in front, the turn over and the next one's task held, before the way out answers.
        lifecycle.willEnterForeground()
        lifecycle.turnEnded(first, succeeded: true)
        let second = lifecycle.turnBegan()
        let two = FakeContinued()
        lifecycle.held(two, turn: second)
        XCTAssertEqual(one.completions, [false])
        XCTAssertTrue(two.open)
        // An expiry in front: let go, with no grace begun for a way out nobody is carrying.
        two.expire()
        XCTAssertEqual(two.completions, [false])
        XCTAssertEqual(time.begun.count, 1, "a second grace was begun over the first")
        await eventually("every grace ended") { time.open.isEmpty }
    }

    func testATurnEndingBeforeTheTickCompletesTheExpiredTaskUnsuccessfullyOnceTheProcessIsGone() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        let turn = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        task.expire()
        await eventually("the tick asleep") { await clock.pending == 2 }
        process.holdNextTermination()
        answer(process, "done")
        for await _ in turn {}
        lifecycle.turnEnded(number, succeeded: true)
        await eventually("the teardown running") { process.terminationHeld }
        XCTAssertTrue(task.open, "the expired task was let go with the process alive")
        process.release()
        await eventually("the task completed") { !task.open }
        XCTAssertEqual(task.completions, [false], "an expired task was completed as a success")
        await clock.advance(by: GraceBudget.firstTick)
        XCTAssertEqual(task.completions, [false], "the task was completed twice")
        _ = time; _ = outcomes
    }

    func testASecondSendBeforeTheFirstsEndIsHeardHoldsItsOwnTask() {
        let (lifecycle, _, _, _, _, _) = make()
        lifecycle.willEnterForeground()
        let first = lifecycle.turnBegan()
        let one = FakeContinued()
        lifecycle.held(one, turn: first)
        let second = lifecycle.turnBegan()
        let two = FakeContinued()
        lifecycle.held(two, turn: second)
        XCTAssertTrue(two.open, "the second turn's task was refused for the first's")
        XCTAssertTrue(one.open, "the first turn's task was let go before its end was heard")
        lifecycle.turnEnded(first, succeeded: false)
        XCTAssertEqual(one.completions, [false], "the first task was not completed with its own turn's result")
        XCTAssertTrue(two.open, "the first turn's end let the second's task go")
        XCTAssertTrue(lifecycle.holdsContinuedTask)
        lifecycle.turnEnded(second, succeeded: true)
        XCTAssertEqual(two.completions, [true])

        // A parked task that iOS expires before its turn's end is heard is completed then.
        let third = lifecycle.turnBegan()
        let three = FakeContinued()
        lifecycle.held(three, turn: third)
        _ = lifecycle.turnBegan()
        three.expire()
        XCTAssertEqual(three.completions, [false])
        lifecycle.turnEnded(third, succeeded: true)
        XCTAssertEqual(three.completions, [false], "the parked task was completed twice")
    }

    func testATaskStartingAfterItsTurnIsCompletedWithThatTurnsResult() {
        let (lifecycle, _, _, _, _, _) = make()
        lifecycle.willEnterForeground()
        let failed = lifecycle.turnBegan()
        lifecycle.turnEnded(failed, succeeded: false)
        let late = FakeContinued()
        lifecycle.held(late, turn: failed)
        XCTAssertEqual(late.completions, [false], "a task for a turn that was not answered was completed as a success")

        // Its turn over but its end not heard yet when the task starts: completed at that end.
        let first = lifecycle.turnBegan()
        _ = lifecycle.turnBegan()
        let behind = FakeContinued()
        lifecycle.held(behind, turn: first)
        XCTAssertTrue(behind.open, "completed before its turn's result was known")
        lifecycle.turnEnded(first, succeeded: false)
        XCTAssertEqual(behind.completions, [false])

        // An answered turn's result is still known many turns on.
        let answered = lifecycle.turnBegan()
        lifecycle.turnEnded(answered, succeeded: true)
        for _ in 0..<20 { lifecycle.turnEnded(lifecycle.turnBegan(), succeeded: false) }
        let older = FakeContinued()
        lifecycle.held(older, turn: answered)
        XCTAssertEqual(older.completions, [true])

        // Overtaken, its end not heard, and the app already behind another: not held at all.
        let overtaken = lifecycle.turnBegan()
        _ = lifecycle.turnBegan()
        lifecycle.didEnterBackground()
        let away = FakeContinued()
        lifecycle.held(away, turn: overtaken)
        XCTAssertEqual(away.completions, [false], "a late task was kept behind another app")
        lifecycle.turnEnded(overtaken, succeeded: true)
        XCTAssertEqual(away.completions, [false], "the task was completed twice")
    }

    func testAnExpiredTaskHoldsTheAppForNoLaterWayOut() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        let turn = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        task.expire()
        XCTAssertEqual(time.open.count, 1)
        // Back and away again before the tick, the turn still running.
        lifecycle.willEnterForeground()
        await eventually("kept") { outcomes.all.contains(.kept) }
        XCTAssertTrue(time.open.isEmpty)
        lifecycle.didEnterBackground()
        XCTAssertEqual(time.open.count, 1, "the expired task was taken as holding the app, and nothing does")
        await eventually("both ticks asleep") { await clock.pending == 3 }
        time.remaining = 25
        await clock.advance(by: GraceBudget.firstTick)
        await eventually("the expired task completed") { task.completions == [false] }
        await eventually("the deadline set") { await clock.pending == 2 }
        await clock.advance(by: .seconds(12))
        await eventually("the turn cut at the grace's budget") { process.terminated }
        for await _ in turn {}
    }

    func testANewTurnsTaskIsHeldOverAnExpiredOneInFront() async throws {
        let (lifecycle, session, launcher, clock, _, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        let turn = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let expired = FakeContinued()
        lifecycle.held(expired, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        expired.expire()
        lifecycle.willEnterForeground()
        await eventually("kept") { outcomes.all.contains(.kept) }
        answer(process, "done")
        for await _ in turn {}
        lifecycle.turnEnded(number, succeeded: true)
        let next = lifecycle.turnBegan()
        let fresh = FakeContinued()
        lifecycle.held(fresh, turn: next)
        XCTAssertTrue(fresh.open, "a new turn's task was refused for an expired one")
        XCTAssertEqual(expired.completions, [false])
        await clock.advance(by: GraceBudget.firstTick)
        XCTAssertTrue(fresh.open, "the expired task's tick let the new task go")
        XCTAssertEqual(expired.completions, [false], "the expired task was completed twice")
    }

    func testATurnThatFailsCompletesItsTaskUnsuccessfully() {
        let (lifecycle, _, _, _, _, _) = make()
        lifecycle.willEnterForeground()
        let turn = lifecycle.turnBegan()
        let task = FakeContinued()
        lifecycle.held(task, turn: turn)
        lifecycle.turnEnded(turn, succeeded: false)
        XCTAssertEqual(task.completions, [false])
    }

    func testATurnThatFailsBehindAnotherAppCompletesTheCarryingTaskUnsuccessfully() async throws {
        let (lifecycle, session, launcher, clock, _, _) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        let turn = lifecycle.carry(try await session.send("long"), turn: number)
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        process.emit(Lines.`init`("S1"))
        process.emit(Lines.result("no", session: "S1", error: true))
        for await _ in turn {}
        await eventually("the task completed") { !task.open }
        XCTAssertEqual(task.completions, [false])
    }

    func testCarryTellsAnAnsweredTurnAsASuccess() async throws {
        let (lifecycle, session, launcher, _, _, _) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        let turn = lifecycle.carry(try await session.send("hi"), turn: number)
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        answer(process, "hello")
        var ended = false
        for await update in turn { if case .ended(.answered) = update { ended = true } }
        XCTAssertTrue(ended, "the answer was not passed on")
        await eventually("the task completed") { !task.open }
        XCTAssertEqual(task.completions, [true])
    }

    func testAGraceExpiryBeforeTheTickEndsTheTurnAtOnce() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        _ = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        task.expire()
        await eventually("the first tick asleep") { await clock.pending == 2 }
        let grace = try XCTUnwrap(time.open.first)
        time.expirations[grace]?()
        await eventually("the grace ended") { time.open.isEmpty }
        await clock.advance(by: GraceBudget.firstTick)
        XCTAssertTrue(process.terminated)
        await eventually("the task completed") { task.completions == [false] }
        XCTAssertEqual(process.bounds, [GraceBudget.expiredTeardownBound])
        guard case .ended(.abandoned, _)? = outcomes.all.last else { return XCTFail("\(outcomes.all)") }
    }

    func testComingBackWithTheTurnRunningKeepsTheTaskForTheNextWayOut() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        let turn = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        lifecycle.willEnterForeground()
        await eventually("kept") { outcomes.all == [.kept] }
        XCTAssertTrue(task.open, "the task was let go with its turn still running")
        XCTAssertFalse(process.terminated)

        lifecycle.didEnterBackground()
        XCTAssertTrue(time.begun.isEmpty, "the second way out began the grace with the task held")
        answer(process, "done")
        for await _ in turn {}
        lifecycle.turnEnded(number, succeeded: true)
        await eventually("the task completed") { !task.open }
        XCTAssertEqual(task.completions, [true])
        XCTAssertTrue(process.terminated)
    }

    func testAContinuedExpiryInTheForegroundLetsTheTaskGoAndTheGraceTakesTheWayOut() async throws {
        let (lifecycle, session, _, clock, time, _) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let number = lifecycle.turnBegan()
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        task.expire()
        XCTAssertEqual(task.completions, [false])
        XCTAssertFalse(lifecycle.holdsContinuedTask)
        lifecycle.didEnterBackground()
        XCTAssertEqual(time.open.count, 1, "the way out had no grace")
        await eventually("the first tick asleep") { await clock.pending == 1 }
    }

    func testALimitForABackgroundThatIsOverChangesNothing() async throws {
        let (lifecycle, session, launcher, clock, _, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        _ = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        await session.limit(budget: .zero, generation: 1)
        let task = FakeContinued()
        lifecycle.held(task, turn: lifecycle.turnBegan())
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        await session.limit(budget: .zero, generation: 1)
        await clock.advance(by: .seconds(60))
        answer(process, "done")
        await eventually("the way out answered") { !outcomes.all.isEmpty }
        guard case .ended(.finished, _)? = outcomes.all.first else {
            return XCTFail("a stale limit cut the turn: \(outcomes.all)")
        }
    }

    func testARefusedGraceAtTheExpiryEndsTheProcessAndHoldsTheTaskUntilItIsGone() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        _ = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        process.holdNextTermination()
        time.refuseNext = true
        task.expire()
        XCTAssertEqual(outcomes.all, [.graceRefused])
        await eventually("the teardown running") { process.terminationHeld }
        XCTAssertTrue(task.open, "the task was let go with the process alive and no grace")
        process.release()
        await eventually("the task completed") { !task.open }
        XCTAssertEqual(task.completions, [false])
        XCTAssertEqual(process.bounds, [GraceBudget.expiredTeardownBound])
        guard case .ended(.abandoned, _)? = outcomes.all.last else { return XCTFail("\(outcomes.all)") }
        XCTAssertTrue(time.open.isEmpty)
    }

    func testARefusedGraceThenComingBackStillLetsTheExpiredTaskGo() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        _ = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        await eventually("the way out waiting on the turn") { await clock.pending == 1 }
        time.refuseNext = true
        task.expire()
        lifecycle.willEnterForeground()
        await eventually("the way out answered") { outcomes.all.count == 2 }
        // The hold's sleep, beside the watchdog's while the turn is still open (`kept`).
        let sleepers = outcomes.all.last == .kept ? 2 : 1
        await eventually("the hold asleep") { await clock.pending == sleepers }
        await clock.advance(by: GraceBudget.expiryHold)
        // Whether the teardown or the foreground came first, the expired task is let go at the latest
        // when the hold runs out, with the turn still open.
        await eventually("the task completed") { task.completions == [false] }
        lifecycle.turnEnded(number, succeeded: true)
        XCTAssertEqual(task.completions, [false], "the task was completed twice")
    }

    func testAStaleWayOutsAnswerLeavesTheTaskANewerOneIsCarrying() async throws {
        let (lifecycle, session, launcher, clock, time, outcomes) = make()
        lifecycle.willEnterForeground()
        await eventually("resident") { await session.currentPhase == .resident }
        let process = try XCTUnwrap(launcher.last)
        let number = lifecycle.turnBegan()
        _ = try await session.send("long")
        await eventually("written") { process.turns.count == 1 }
        let task = FakeContinued()
        lifecycle.held(task, turn: number)
        lifecycle.didEnterBackground()
        lifecycle.willEnterForeground()
        lifecycle.didEnterBackground()
        await eventually("the first way out answered") { outcomes.all.contains(.kept) }
        XCTAssertTrue(task.open, "a stale answer completed the task the newer way out carries")
        process.holdNextTermination()
        answer(process, "done")
        lifecycle.turnEnded(number, succeeded: true)
        await eventually("the teardown running") { process.terminationHeld }
        XCTAssertTrue(task.open, "the task was completed with the process alive")
        process.release()
        await eventually("the task completed") { !task.open }
        XCTAssertEqual(task.completions, [true])
        XCTAssertTrue(time.begun.isEmpty)
        _ = clock
    }
}
