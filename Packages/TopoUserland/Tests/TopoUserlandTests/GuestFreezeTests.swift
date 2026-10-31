import TopoCore
import XCTest
@testable import TopoUserland

/// A freezer the test scripts: whether the stop is confirmed, whether the way back takes its ports
/// back, whether the continue is sent and confirmed, how many times each was asked, and a hold on
/// the stop, the ports and the confirmation.
final class ScriptedFreezer: GuestFreezer, @unchecked Sendable {
    private let lock = NSLock()
    private var stopAnswer = true
    private var prepareAnswer = true
    private var confirmAnswer = true
    private var stopCalls = 0
    private var prepareCalls = 0
    private var continueCalls = 0
    private var holds: Set<Step> = []
    private var gates: [Step: CheckedContinuation<Void, Never>] = [:]

    enum Step: Hashable { case stop, prepare, confirm }

    /// The next `step` waits for `release(step)` before it answers.
    func hold(_ step: Step) { lock.withLock { _ = holds.insert(step) } }
    func release(_ step: Step) {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holds.remove(step)
            return gates.removeValue(forKey: step)
        }
        waiting?.resume()
    }

    func answer(stop: Bool? = nil, prepare: Bool? = nil, confirm: Bool? = nil) {
        lock.withLock {
            if let stop { stopAnswer = stop }
            if let prepare { prepareAnswer = prepare }
            if let confirm { confirmAnswer = confirm }
        }
    }
    var stops: Int { lock.withLock { stopCalls } }
    var prepares: Int { lock.withLock { prepareCalls } }
    /// How many continues were sent: the one thing that wakes the guest.
    var continues: Int { lock.withLock { continueCalls } }

    /// Waits while `step` is held. The check and the gate are one step under the lock, so a
    /// release landing between them cannot be missed.
    private func pass(_ step: Step) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let held = lock.withLock { () -> Bool in
                guard holds.contains(step) else { return false }
                gates[step] = continuation
                return true
            }
            if !held { continuation.resume() }
        }
    }

    func stop() async -> Bool {
        lock.withLock { stopCalls += 1 }
        await pass(.stop)
        return lock.withLock { stopAnswer }
    }
    func prepare() async -> Bool {
        lock.withLock { prepareCalls += 1 }
        await pass(.prepare)
        return lock.withLock { prepareAnswer }
    }
    func continueNow() -> Bool {
        lock.withLock { continueCalls += 1 }
        return true
    }
    func confirm() async -> Bool {
        await pass(.confirm)
        return lock.withLock { confirmAnswer }
    }
}

/// Whether Claude Code is signed in, as a test sets it.
final class Login: @unchecked Sendable {
    private let lock = NSLock()
    private var on = true
    var signedIn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}

/// #501: an idle resident is kept across a background, stopped, and continued on the way back
/// once its ports are taken back; anything short of that is the cold start the way out made before.
final class GuestFreezeTests: XCTestCase {
    private var directory: URL!
    private var launcher: ScriptedLauncher!
    private var freezer: ScriptedFreezer!
    private var clock: ManualClock!
    private var login: Login!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("freeze-\(UUID().uuidString)")
        launcher = ScriptedLauncher()
        freezer = ScriptedFreezer()
        clock = ManualClock()
        login = Login()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var store: SessionFile { SessionFile(url: directory.appendingPathComponent(".guest-session")) }
    private var cutURL: URL { directory.appendingPathComponent(".guest-cut.json") }

    private func resident() async throws -> (GuestSession, ScriptedProcess) {
        let login = self.login!
        let session = GuestSession(launcher: launcher, store: store, freezer: freezer, sleep: clock.sleep,
                                   signedIn: { login.signedIn })
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
        await eventually("written") { process.turns.last == text }
        answer(process, "ok")
        for await _ in updates {}
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
        XCTAssertEqual(freezer.continues, 1)
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
        let frozen = await session.background(budget: .seconds(15))
        XCTAssertEqual(frozen, .frozen)
        freezer.hold(.prepare)
        await session.foreground()
        await eventually("the ports being taken back") { self.freezer.prepares == 1 }
        let sending = Task { try await session.send("straight away") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(process.turns, [], "a turn was written to a process not yet continued")
        freezer.release(.prepare)
        let updates = try await sending.value
        await eventually("written") { process.turns.count == 1 }
        answer(process, "ok")
        for await _ in updates {}
        XCTAssertEqual(freezer.continues, 1)
        XCTAssertEqual(process.turns, ["straight away"])
    }

    /// Ports that cannot be taken back are a cold start: the frozen process ended, never continued,
    /// and a fresh one resumes the same conversation.
    func testPortsNotTakenBackEndTheProcessAndStartAnother() async throws {
        let (session, process) = try await resident()
        try await turn(session, process, "first")
        let got2 = await session.background(budget: .seconds(15))

        XCTAssertEqual(got2, .frozen)
        freezer.answer(prepare: false)
        await session.foreground()
        try await session.ready()
        XCTAssertTrue(process.terminated)
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertEqual(launcher.resumed, [nil, "S1"])
    }

    /// A continue sent and not confirmed — a task still parked at the stop — is a cold start: the
    /// process ended and a fresh one resumes the conversation.
    func testAContinueNotConfirmedEndsTheProcessAndStartsAnother() async throws {
        let (session, process) = try await resident()
        try await turn(session, process, "first")
        let frozen = await session.background(budget: .seconds(15))
        XCTAssertEqual(frozen, .frozen)
        freezer.answer(confirm: false)
        await session.foreground()
        try await session.ready()
        XCTAssertEqual(freezer.continues, 1)
        XCTAssertTrue(process.terminated)
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertEqual(launcher.resumed, [nil, "S1"])
    }

    /// Claude Code's login ending a frozen process with background tasks leaves the next process,
    /// which resumes the conversation, told it was ended rather than that iOS ended the app.
    func testALoginEndingAFrozenProcessRewritesItsCut() async throws {
        let (session, process) = try await resident()
        let updates = try await session.send("log for ten minutes")
        await eventually("written") { process.turns.count == 1 }
        process.emit(Lines.`init`("S1"))
        process.emit(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"a"}]}"#)
        process.emit(Lines.result("started", session: "S1"))
        for await _ in updates {}
        let frozen = await session.background(budget: .seconds(15))
        XCTAssertEqual(frozen, .frozen)
        XCTAssertEqual(CutFile(url: cutURL).load()?.frozen, true)
        await session.withoutResident { }
        XCTAssertTrue(process.terminated)
        let kept = try XCTUnwrap(CutFile(url: cutURL).load())
        XCTAssertNotEqual(kept.frozen, true, "the next process would be told iOS ended the app")
    }

    /// Claude Code's login waits for a stop still sending SIGSTOP before it runs its own `claude`.
    func testALoginWaitsForAStopStillUnderWay() async throws {
        let (session, process) = try await resident()
        freezer.hold(.stop)
        let outcome = Task { await session.background(budget: .seconds(15)) }
        await eventually("the stop under way") { self.freezer.stops == 1 }
        let ran = Flag()
        let login = Task { await session.withoutResident { ran.set() } }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(ran.isSet, "the login ran while the stop was still under way")
        freezer.release(.stop)
        await login.value
        _ = await outcome.value
        XCTAssertTrue(ran.isSet)
        XCTAssertTrue(process.terminated)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isSet: Bool { lock.withLock { on } }
        func set() { lock.withLock { on = true } }
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
        freezer.hold(.stop)
        let freezing = Task { await session.background(budget: .seconds(15)) }
        await eventually("the stop under way") { self.freezer.stops == 1 }
        XCTAssertEqual(CutFile(url: cutURL).load()?.frozen, true, "the cut was not kept before the stop, where iOS may end the app")
        freezer.release(.stop)
        let got4 = await freezing.value

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
        XCTAssertEqual(freezer.continues, 0, "a process of a forgotten conversation was continued")
        await session.foreground()
        try await session.ready()
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertEqual(launcher.resumed.last ?? "none", nil, "the next process resumed the forgotten conversation")
    }

    /// P1: a sign-out that lands while the way back is taking its ports back ends the frozen
    /// process stopped, and the continue is never sent: the gate that sends it reads the phase on
    /// the session's actor, after the end has made it stopping.
    func testASignOutBeforeTheContinueIsSentEndsTheProcessStoppedAndSendsNone() async throws {
        let (session, process) = try await resident()
        let frozen = await session.background(budget: .seconds(15))
        XCTAssertEqual(frozen, .frozen)
        freezer.hold(.prepare)
        await session.foreground()
        await eventually("the ports being taken back") { self.freezer.prepares == 1 }
        let forgetting = Task { await session.forgetSession() }
        await eventually("the frozen process ended while the ports were held") { process.terminated }
        freezer.release(.prepare)
        let termination = await forgetting.value
        XCTAssertEqual(termination?.confirmed, true)
        try await session.ready()
        XCTAssertEqual(freezer.continues, 0, "a process of the login that went was continued")
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertEqual(launcher.resumed.last ?? "none", nil, "the next process resumed the forgotten conversation")
    }

    /// A sign-out that lands once the continue has been sent, before it is confirmed, waits for
    /// the thaw and ends the process as the running one it is: the continue came first.
    func testASignOutAfterTheContinueWasSentEndsTheRunningProcess() async throws {
        let (session, process) = try await resident()
        let frozen = await session.background(budget: .seconds(15))
        XCTAssertEqual(frozen, .frozen)
        freezer.hold(.confirm)
        await session.foreground()
        await eventually("the continue sent") { self.freezer.continues == 1 }
        let forgetting = Task { await session.forgetSession() }
        freezer.release(.confirm)
        let termination = await forgetting.value
        XCTAssertEqual(termination?.confirmed, true)
        XCTAssertTrue(process.terminated)
        try await session.ready()
        XCTAssertEqual(freezer.continues, 1)
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertEqual(launcher.resumed.last ?? "none", nil, "the next process resumed the forgotten conversation")
    }

    /// Claude Code's login and logout end a frozen process stopped, as a sign-out does, and none
    /// is continued while one is under way.
    func testALoginWhileFrozenEndsTheProcessStoppedAndSendsNoContinue() async throws {
        let (session, process) = try await resident()
        try await turn(session, process, "first")
        let frozen = await session.background(budget: .seconds(15))
        XCTAssertEqual(frozen, .frozen)
        freezer.hold(.prepare)
        await session.foreground()
        await eventually("the ports being taken back") { self.freezer.prepares == 1 }
        let login = Task { await session.withoutResident { process.terminated } }
        await eventually("the frozen process ended for the login") { process.terminated }
        freezer.release(.prepare)
        let endedFirst = await login.value
        XCTAssertTrue(endedFirst, "the login ran with the frozen process still there")
        try await session.ready()
        XCTAssertEqual(freezer.continues, 0, "a process was continued across Claude Code's login")
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertEqual(launcher.resumed.last ?? "none", "S1", "the login lost the conversation")
    }

    /// A frozen process is continued only while Claude Code is still signed in; signed out, the
    /// way back is a cold start.
    func testAFrozenProcessIsNotContinuedOnceSignedOut() async throws {
        let (session, process) = try await resident()
        let frozen = await session.background(budget: .seconds(15))
        XCTAssertEqual(frozen, .frozen)
        login.signedIn = false
        await session.foreground()
        try await session.ready()
        XCTAssertEqual(freezer.continues, 0, "a process was continued with Claude Code signed out")
        XCTAssertTrue(process.terminated)
        XCTAssertEqual(launcher.processes.count, 2)
    }

    /// P1: a stop still sending SIGSTOP when a sign-out ends the process is waited out before the
    /// next process launches, so it cannot stop that one.
    func testAStopStillUnderWayIsWaitedOutBeforeTheNextLaunch() async throws {
        let (session, process) = try await resident()
        freezer.hold(.stop)
        let outcome = Task { await session.background(budget: .seconds(15)) }
        await eventually("the stop under way") { self.freezer.stops == 1 }
        await session.foreground()
        _ = await session.forgetSession()
        XCTAssertTrue(process.terminated)
        let ready = Task { try await session.ready() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(launcher.processes.count, 1, "a process launched while the old stop was still under way")
        freezer.release(.stop)
        try await ready.value
        _ = await outcome.value
        XCTAssertEqual(launcher.processes.count, 2)
        XCTAssertEqual(freezer.continues, 0)
    }

    /// P1: back in front while a stop is landing that then is not confirmed: the way back does not
    /// continue it but ends it and starts a fresh process.
    func testComingBackOverAStopNotConfirmedIsAColdStart() async throws {
        let (session, process) = try await resident()
        freezer.hold(.stop)
        let outcome = Task { await session.background(budget: .seconds(15)) }
        await eventually("the stop under way") { self.freezer.stops == 1 }
        await session.foreground()
        freezer.answer(stop: false)
        freezer.release(.stop)
        _ = await outcome.value
        try await session.ready()
        XCTAssertEqual(freezer.continues, 0, "a guest whose stop was not confirmed was continued")
        XCTAssertTrue(process.terminated)
        XCTAssertEqual(launcher.processes.count, 2)
    }

    /// The way back marks its steps, and a cold one says so rather than that it continued.
    func testTheWayBackIsMarkedContinuedOrCold() async throws {
        let marks = Marks()
        try await Perf.$observer.withValue({ marks.add($0) }) {
            let (session, _) = try await resident()
            _ = await session.background(budget: .seconds(15))
            await session.foreground()
            try await session.ready()
            freezer.answer(prepare: false)
            _ = await session.background(budget: .seconds(15))
            await session.foreground()
            try await session.ready()
        }
        let way = marks.all.filter { $0.hasPrefix("resident.freeze") || $0.hasPrefix("resident.frozen") || $0.hasPrefix("resident.thaw") }
        XCTAssertEqual(way, ["resident.freeze.begin", "resident.frozen", "resident.thaw.begin", "resident.thaw.continued",
                             "resident.freeze.begin", "resident.frozen", "resident.thaw.begin", "resident.thaw.cold"])
    }

    private final class Marks: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        var all: [String] { lock.withLock { names } }
        func add(_ name: String) { lock.withLock { names.append(name) } }
    }

    /// Back in front while the stop is still landing: the way back waits for it, then continues.
    func testComingBackWhileTheStopLandsContinuesAfterIt() async throws {
        let (session, process) = try await resident()
        freezer.hold(.stop)
        let outcome = Task { await session.background(budget: .seconds(15)) }
        await eventually("the stop under way") { self.freezer.stops == 1 }
        await session.foreground()
        XCTAssertEqual(freezer.continues, 0, "the continue went ahead of the stop")
        freezer.release(.stop)
        let got6 = await outcome.value

        XCTAssertEqual(got6, .kept)
        try await session.ready()
        XCTAssertEqual(freezer.continues, 1)
        try await turn(session, process, "here")
        XCTAssertFalse(process.terminated)
        XCTAssertEqual(launcher.processes.count, 1)
    }
}
