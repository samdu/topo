import BackgroundTasks
import os
import TopoUserland
import XCTest

@testable import Topo

final class ContinuedTurnTests: XCTestCase {
    @MainActor
    func testATurnsRequestFailsRatherThanQueuesAndCarriesTheFixedWords() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("BGContinuedProcessingTaskRequest is iOS 26 on") }
        let identifier = "\(ContinuedTurns.prefix).\(UUID().uuidString)"
        let request = ContinuedTurns.request(identifier: identifier)
        XCTAssertEqual(request.identifier, identifier)
        XCTAssertEqual(request.strategy, .fail, "a turn's task is worth having now or not at all")
        XCTAssertEqual(request.title, "Topo")
        XCTAssertEqual(request.subtitle, "Still working. Tap to keep it going", "the pill is drawn on the lock screen: fixed words, never the turn's")
    }

    /// At expiry, or the person's cancel, the pill says the turn is stopping before the way out runs.
    @MainActor
    func testAtExpiryThePillSaysTheTurnIsStoppingBeforeTheWayOutRuns() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("BGContinuedProcessingTask is iOS 26 on") }
        let seen = OSAllocatedUnfairLock(initialState: [String]())
        let expire = ContinuedTurnTask.expiration(retitle: { title, subtitle in seen.withLock { $0.append("\(title) — \(subtitle)") } },
                                                  then: { seen.withLock { $0.append("the way out") } })
        expire()
        XCTAssertEqual(seen.withLock { $0 }, ["Topo — Stopping. Open Topo to carry on", "the way out"])
    }

    func testTheIdentifierIsUnderTheWildcardThePlistPermits() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("BGContinuedProcessingTaskRequest is iOS 26 on") }
        let permitted = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        XCTAssertTrue(permitted.contains("\(ContinuedTurns.prefix).*"), "\(permitted)")
    }

    @MainActor
    func testEachTurnRegistersItsOwnIdentifierAndSubmitsThatOne() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("BGContinuedProcessingTaskRequest is iOS 26 on") }
        let seen = Seen()
        let scheduler = ContinuedTurns.Scheduler(
            register: { identifier, _ in seen.registered.append(identifier); return true },
            submit: { request, answer in
                // The request reaches the submit already made, at the send on the main actor, so a
                // queue that runs late submits the request of an app that was in front.
                XCTAssertEqual(request.strategy, .fail)
                XCTAssertEqual(request.title, ContinuedTurns.title)
                seen.submitted.append(request.identifier)
                answer(nil)
            })
        let lifecycle = Self.lifecycle()
        for turn in 1...2 {
            ContinuedTurns.submit(turn: turn, to: lifecycle, log: { line in MainActor.assumeIsolated { seen.lines.append(line) } },
                                  scheduler: scheduler)
        }
        // iOS refuses a handler registered for the wildcard pattern itself: each request's own
        // identifier is the one registered, and never one registered twice, which ends the app.
        XCTAssertEqual(seen.registered, seen.submitted)
        XCTAssertEqual(Set(seen.registered).count, 2, "\(seen.registered)")
        for identifier in seen.registered {
            XCTAssertTrue(identifier.hasPrefix("\(ContinuedTurns.prefix)."), identifier)
            XCTAssertFalse(identifier.contains("*"), identifier)
        }
        XCTAssertEqual(seen.lines, ["continued: asked for turn 1", "continued: asked for turn 2"])
    }

    @MainActor
    func testARefusedRegistrationSubmitsNothing() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("BGContinuedProcessingTaskRequest is iOS 26 on") }
        let seen = Seen()
        let scheduler = ContinuedTurns.Scheduler(
            register: { _, _ in false },
            submit: { request, answer in seen.submitted.append(request.identifier); answer(nil) })
        ContinuedTurns.submit(turn: 1, to: Self.lifecycle(), log: { line in MainActor.assumeIsolated { seen.lines.append(line) } },
                              scheduler: scheduler)
        XCTAssertEqual(seen.submitted, [])
        XCTAssertEqual(seen.lines.count, 1)
        XCTAssertTrue(seen.lines.first?.hasSuffix("is not permitted; the turn has the grace alone") == true, "\(seen.lines)")
    }

    @MainActor
    func testARefusedSubmissionIsLoggedAsRefused() throws {
        guard #available(iOS 26, *) else { throw XCTSkip("BGContinuedProcessingTaskRequest is iOS 26 on") }
        let seen = Seen()
        let scheduler = ContinuedTurns.Scheduler(
            register: { _, _ in true },
            submit: { _, answer in answer(ContinuedTurns.Refusal(description: "ineligible")) })
        ContinuedTurns.submit(turn: 3, to: Self.lifecycle(), log: { line in MainActor.assumeIsolated { seen.lines.append(line) } },
                              scheduler: scheduler)
        XCTAssertEqual(seen.lines, ["continued: refused (ineligible); the turn has the grace alone"])
    }

    /// What the scheduler was handed and what was logged.
    @MainActor
    private final class Seen {
        var registered: [String] = []
        var submitted: [String] = []
        var lines: [String] = []
    }

    /// A lifecycle over a session that is never started.
    @MainActor
    private static func lifecycle() -> GuestLifecycle {
        let store = SessionFile(url: FileManager.default.temporaryDirectory.appendingPathComponent("continued-\(UUID().uuidString)"))
        let session = GuestSession(launcher: ClaudeLauncher(environment: { [:] }), store: store)
        return GuestLifecycle(session: session, time: ApplicationBackgroundTime())
    }
}
