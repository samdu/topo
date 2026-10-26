import XCTest
@testable import TopoUserland

/// A freezer the test scripts: whether the stop is confirmed, whether the way back takes its ports
/// back, and how many times each was asked.
final class ScriptedFreezer: GuestFreezer, @unchecked Sendable {
    private let lock = NSLock()
    private var stopAnswer = true
    private var resumeAnswer = true
    private var stopCalls = 0
    private var resumeCalls = 0
    private var holding = false
    private var gate: CheckedContinuation<Void, Never>?

    /// The next stop waits for `releaseStop` before it answers.
    func holdStop() { lock.withLock { holding = true } }
    func releaseStop() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holding = false
            defer { gate = nil }
            return gate
        }
        waiting?.resume()
    }

    func answer(stop: Bool? = nil, resume: Bool? = nil) {
        lock.withLock {
            if let stop { stopAnswer = stop }
            if let resume { resumeAnswer = resume }
        }
    }
    var stops: Int { lock.withLock { stopCalls } }
    var resumes: Int { lock.withLock { resumeCalls } }

    func stop() async -> Bool {
        let held = lock.withLock { stopCalls += 1; return holding }
        if held { await withCheckedContinuation { continuation in lock.withLock { gate = continuation } } }
        return lock.withLock { stopAnswer }
    }
    func resume() async -> Bool { lock.withLock { resumeCalls += 1; return resumeAnswer } }
}

/// #501: an idle resident is kept across a background, stopped, and continued on the way back
/// once its ports are taken back; anything short of that is the cold start the way out made before.
final class GuestFreezeTests: XCTestCase {
    private var directory: URL!
    private var launcher: ScriptedLauncher!
    private var freezer: ScriptedFreezer!
    private var clock: ManualClock!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("freeze-\(UUID().uuidString)")
        launcher = ScriptedLauncher()
        freezer = ScriptedFreezer()
        clock = ManualClock()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: SessionFile { SessionFile(url: directory.appendingPathComponent(".guest-session")) }
    private var cutURL: URL { directory.appendingPathComponent(".guest-cut.json") }

    private func resident() async throws -> (GuestSession, ScriptedProcess) {
        let session = GuestSession(launcher: launcher, store: store, freezer: freezer, sleep: clock.sleep)
        await session.foreground()
        try await session.ready()
        return (session, try XCTUnwrap(launcher.last))
    }

    private func answer(_ process: ScriptedProcess, _ text: String, session id: String = "S1") {
        process.emit(Lines.`init`(id))
        process.emit(Lines.text(text))
        process.emit(Lines.result(text, session: id))
    }

    private func turn(_ session: GuestSession, _ process: ScriptedProcess, _ text: String) async throws {
        let updates = try await session.send(text)
        let count = process.turns.count
        answer(process, "ok")
        for await _ in updates {}
        XCTAssertGreaterThanOrEqual(process.turns.count, count)
    }

    func testAnIdleProcessIsFrozenAndTheWayBackContinuesTheSameOne() async throws {
        let (session, process) = try await resident()
        let outcome = await session.background(budget: .seconds(15))
        XCTAssertEqual(outcome, .frozen)
        XCTAssertFalse(process.terminated, "a frozen process was ended")
        XCTAssertEqual(freezer.stops, 1)
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .frozen)

        // Nothing goes to a frozen process from behind another app: refused, as with nothing resident.
        do {
            _ = try await session.send("from a limb")
            XCTFail("a turn went to a frozen process in the background")
        } catch let refusal as GuestSession.Refusal {
            XCTAssertEqual(refusal, .notResident)
        }
        XCTAssertEqual(process.turns, [])

        await session.foreground()
        try await session.ready()
        XCTAssertEqual(freezer.resumes, 1)
        let back = await session.currentPhase
        XCTAssertEqual(back, .resident)
        XCTAssertEqual(launcher.processes.count, 1, "the way back started another process")
        try await turn(session, process, "hello again")
        XCTAssertEqual(process.turns, ["hello again"])
    }

    /// A turn sent on the way back, before the continue has landed, waits for it rather than being
    /// refused or written to a stopped process.
    func testATurnSentAsTheAppComesBackWaitsForTheContinue() async throws {
        let (session, process) = try await resident()
        let got1 = await session.background(budget: .seconds(15))

        XCTAssertEqual(got1, .frozen)
        await session.foreground()
        try await turn(session, process, "straight away")
        XCTAssertEqual(freezer.resumes, 1)
        XCTAssertEqual(process.turns, ["straight away"])
    }

    /// Ports that cannot be taken back are a cold start: the frozen process ended, never continued,
    /// and a fresh one resumes the same conversation.
    func testPortsNotTakenBackEndTheProcessAndStartAnother() async throws {
        let (session, process) = try await resident()
        try await turn(session, process, "first")
        let got2 = await session.background(budget: .seconds(15))

        XCTAssertEqual(got2, .frozen)
        freezer.answer(resume: false)
        await session.foreground()
        try await session.ready()
        XCTAssertTrue(process.terminated)
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertEqual(launcher.resumed, [nil, "S1"])
    }

    /// A stop that is not confirmed may leave a task to take one more step on the way back, so the
    /// process is ended as the way out did before.
    func testAStopNotConfirmedEndsTheProcess() async throws {
        let (session, process) = try await resident()
        freezer.answer(stop: false)
        let outcome = await session.background(budget: .seconds(15))
        guard case .ended(nil, let termination) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(termination.confirmed)
        XCTAssertTrue(process.terminated)
        let phase = await session.currentPhase
        XCTAssertEqual(phase, .idle)
    }

    /// A turn in flight at the way out that finishes inside the grace leaves an idle process, which
    /// is frozen; one still running at the teardown point is abandoned and ended as before.
    func testATurnFinishedInsideTheGraceIsFrozenAndOneCutShortIsEnded() async throws {
        let (session, process) = try await resident()
        let updates = try await session.send("long one")
        await eventually("written") { process.turns.count == 1 }
        let background = Task { await session.background(budget: .seconds(15)) }
        await eventually("waiting on the turn") { await self.clock.pending == 2 }
        answer(process, "done")
        for await _ in updates {}
        let got3 = await background.value

        XCTAssertEqual(got3, .frozen)
        XCTAssertFalse(process.terminated)

        await session.foreground()
        try await session.ready()
        let cut = try await session.send("very long one")
        await eventually("written") { process.turns.count == 2 }
        let second = Task { await session.background(budget: .seconds(15)) }
        await eventually("waiting on the turn") { await self.clock.pending == 2 }
        await clock.advance(by: .seconds(15))
        guard case .ended(.abandoned, _) = await second.value else { return XCTFail("not ended") }
        for await _ in cut {}
        XCTAssertTrue(process.terminated)
        XCTAssertEqual(freezer.stops, 1, "a process with its turn abandoned was frozen")
    }

    /// Background tasks frozen with the process are told to the next one only if iOS ends the app
    /// while it is away: the note is kept as it freezes, and cleared when it is continued.
    func testACutIsKeptAsItFreezesAndClearedWhenItIsContinued() async throws {
        let (session, process) = try await resident()
        let updates = try await session.send("log for ten minutes")
        await eventually("written") { process.turns.count == 1 }
        process.emit(Lines.`init`("S1"))
        process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a"}]}"#)
        process.emit(Lines.result("started", session: "S1"))
        for await _ in updates {}
        let got4 = await session.background(budget: .seconds(15))

        XCTAssertEqual(got4, .frozen)
        let kept = try XCTUnwrap(CutFile(url: cutURL).load())
        XCTAssertEqual(kept.frozen, true)
        XCTAssertTrue(kept.words.contains("iOS ended the app while it was away"), kept.words)
        XCTAssertTrue(kept.words.contains("a background task you had started"), kept.words)

        await session.foreground()
        try await session.ready()
        XCTAssertFalse(FileManager.default.fileExists(atPath: cutURL.path), "a continued process left its note")
    }

    /// A frozen process holds the login a sign-out takes away: it is ended stopped, never continued.
    func testASignOutEndsAFrozenProcess() async throws {
        let (session, process) = try await resident()
        let got5 = await session.background(budget: .seconds(15))

        XCTAssertEqual(got5, .frozen)
        let termination = await session.forgetSession()
        XCTAssertEqual(termination?.confirmed, true)
        XCTAssertTrue(process.terminated)
        XCTAssertEqual(freezer.resumes, 0, "a process of a forgotten conversation was continued")
        await session.foreground()
        try await session.ready()
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertEqual(launcher.resumed.last ?? "none", nil, "the next process resumed the forgotten conversation")
    }

    /// Back in front while the stop is still landing: the way back waits for it, then continues.
    func testComingBackWhileTheStopLandsContinuesAfterIt() async throws {
        let (session, process) = try await resident()
        freezer.holdStop()
        let outcome = Task { await session.background(budget: .seconds(15)) }
        await eventually("the stop under way") { self.freezer.stops == 1 }
        await session.foreground()
        XCTAssertEqual(freezer.resumes, 0, "the continue went ahead of the stop")
        freezer.releaseStop()
        let got6 = await outcome.value

        XCTAssertEqual(got6, .kept)
        try await session.ready()
        XCTAssertEqual(freezer.resumes, 1)
        try await turn(session, process, "here")
        XCTAssertFalse(process.terminated)
        XCTAssertEqual(launcher.processes.count, 1)
    }
}
