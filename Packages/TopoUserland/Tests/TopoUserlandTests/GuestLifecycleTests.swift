import XCTest
@testable import TopoUserland

/// The lifecycle between iOS and the session: the background task asked for on the way out, the
/// budget read a tick later, and the task ended once nothing is resident.
@MainActor
final class GuestLifecycleTests: XCTestCase {
    private final class FakeTime: BackgroundTime {
        var remaining: TimeInterval = .greatestFiniteMagnitude
        private(set) var begun: [Int] = []
        private(set) var ended: [Int] = []
        private var next = 100
        var expirations: [Int: @MainActor () -> Void] = [:]

        func begin(expiration: @escaping @MainActor () -> Void) -> Int {
            next += 1
            begun.append(next)
            expirations[next] = expiration
            return next
        }

        func end(_ task: Int) { ended.append(task) }

        var open: [Int] { begun.filter { !ended.contains($0) } }
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
}
