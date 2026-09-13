import XCTest

/// The microphone, pressed. Nothing else in the suite touches it: the client tests exercise
/// objects and `scripts/simulator-run.sh` sends a typed turn, and a press is a gesture on the
/// running app, which only an XCUITest makes. What the test holds is that the app is still
/// running, on the chat screen with the button back to "Hold to talk", after a tap, a hold and a
/// release. A crash on the press is an app that is no longer running, whatever the cause, which
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

        // A tap opens the microphone until the next press: the tap is on the input, the engine
        // is running and buffers are arriving for as long as this waits.
        mic.press(forDuration: 0.1)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived the press")
        _ = app.images["Listening; press to send"].waitForExistence(timeout: 3)
        XCTAssertEqual(app.state, .runningForeground, "the app survived two seconds of listening")

        // The next press ends it: the audio is taken and decoded, and nothing heard sends nothing.
        mic.press(forDuration: 0.1)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived the release")

        // A hold: down past the tap limit, then up.
        mic.press(forDuration: 1.5)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3), "the app survived the hold")
        XCTAssertTrue(app.images["Hold to talk"].waitForExistence(timeout: 15), "the session ended and the button is back to rest")
        XCTAssertEqual(app.state, .runningForeground)
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
