import XCTest

/// The microphone, pressed. Nothing else in the suite touches it: the client tests exercise
/// objects and `scripts/simulator-run.sh` sends a typed turn, and a press is a gesture on the
/// running app, which only an XCUITest makes. What the test holds is that the app is still
/// running, on the chat screen with the button back to "Hold to talk", after a tap, a hold and a
/// release, and that the hold's session ran its microphone (`VoiceInput.sessions`, read from the
/// button's debug-only accessibility value). A crash on the press is an app that is no longer running, whatever the cause, which
/// is the class `VoiceInput.begin`'s `do`/`catch` cannot see: an Objective-C exception out of
/// `installTap`, or a runtime trap.
///
/// The app is launched signed in with a placeholder token (`DebugRun.signIn` takes it from the
/// environment; a press in the simulator hears nothing, so nothing is sent and the token is never
/// presented to the API) and past the first-run question, which is the chat screen with its
/// microphone. The two permission prompts of a fresh simulator are answered through SpringBoard.
///
/// Two launches, one per branch of `VoiceInput.begin`. The simulator has no Metal, so Parakeet is
/// never resident there: the on-device branch runs over `TOPO_DEBUG_EAR=stub` (the tap, the
/// sample sink's conversion off the audio thread, the caption loop, the decode at the release,
/// with an engine that hears nothing) and the CoreML decode itself is out of reach. The other
/// launch takes the fallback branch, `SFSpeechRecognizer`'s.
@MainActor
final class MicrophonePressTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAPressOnTheEarsPathLeavesTheAppRunning() {
        let app = launch(environment: ["TOPO_DEBUG_EAR": "stub"])
        tapHoldAndRelease(app)
    }

    func testAPressOnTheFallbackLeavesTheAppRunning() {
        let app = launch(environment: [:])
        tapHoldAndRelease(app)
    }

    private func launch(environment: [String: String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment.merge(environment) { _, new in new }
        app.launchArguments += ["-firstRunAnswered", "YES"]
        app.launch()
        return app
    }

    /// The button in any of its states. Its label is `VoiceInput`'s state in words.
    private func microphone(in app: XCUIApplication) -> XCUIElement {
        app.images.matching(NSPredicate(format: "label == 'Hold to talk' OR label BEGINSWITH 'Listening'")).firstMatch
    }

    private func tapHoldAndRelease(_ app: XCUIApplication) {
        let mic = microphone(in: app)
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the chat screen, with its microphone")

        // The first press on a fresh simulator meets the microphone and speech prompts, and its
        // release while they are up starts nothing (`VoiceInput.pressUp` during `starting`).
        mic.press(forDuration: 0.5)
        allowPrompts()
        XCTAssertEqual(app.state, .runningForeground, "the app survived the permission prompts")

        // A tap. Released before the microphone is running it starts nothing, by design
        // (`VoiceInput.pressUp` during `starting`), and a synthesised tap is shorter than the
        // permission hops and the engine start, so this holds only that the press was survived;
        // if it did open the microphone hands-free, the next press closes it.
        mic.press(forDuration: 0.1)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived the tap")
        if app.images["Listening; press to send"].waitForExistence(timeout: 3) {
            mic.press(forDuration: 0.1)
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived closing the hands-free session")
        }
        XCTAssertTrue(app.images["Hold to talk"].waitForExistence(timeout: 15), "the button is at rest before the hold")
        let before = report(app)

        // A hold, longer than the start and past the tap limit, then the release: the tap is on
        // the input and buffers arrive for the length of it, then the audio is taken and
        // decoded, and nothing heard sends nothing. The count is what proves the microphone ran.
        mic.press(forDuration: 1.5)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived the hold")
        XCTAssertTrue(app.images["Hold to talk"].waitForExistence(timeout: 15), "the session ended and the button is back to rest")
        // The microphone ran, or the one refusal a simulator host may have: no audio input at
        // all, a Mac without a microphone. A refusal for any other reason (a permission, the
        // recogniser, the engine) is a fault on the press and fails here.
        let after = report(app)
        if after.sessions == before.sessions + 1 {
            XCTAssertNil(after.refusal, "the hold's session ran its microphone: \(after.raw)")
        } else {
            XCTAssertEqual(after.refusal, "no audio input", "the hold started no microphone: \(after.raw)")
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// Sessions whose microphone ran, and why the last press started none, from the button's
    /// debug-only accessibility value ("<n> heard[; <refusal>]").
    private struct Report {
        var sessions: Int
        var refusal: String?
        var raw: String
    }

    private func report(_ app: XCUIApplication) -> Report {
        let raw = microphone(in: app).value as? String ?? ""
        let parts = raw.components(separatedBy: "; ")
        let sessions = Int(parts[0].split(separator: " ").first ?? "") ?? -1
        return Report(sessions: sessions, refusal: parts.count > 1 ? parts[1] : nil, raw: raw)
    }

    /// Taps through whatever permission prompts are up, microphone then speech. Nothing to do on
    /// a simulator that has already answered them.
    private func allowPrompts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN {'Allow', 'OK'}")).firstMatch
        for _ in 0..<2 where allow.waitForExistence(timeout: 3) {
            allow.tap()
        }
    }
}
