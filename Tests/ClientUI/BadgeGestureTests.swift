import XCTest

/// The badge's two gestures, which are the only way into the settings and the diagnostics now
/// that the title is gone. A tap and a hold on one control is a thing a unit test cannot reach:
/// the hold is a `simultaneousGesture` beside the button's own, so what one press opens, and
/// that it does not open both, is only answered by pressing it.
///
/// The app is launched signed in with a placeholder token and past the first-run question, with
/// an ear that never loads, so nothing here asks for the microphone and no permission prompt is
/// raised. Nothing is sent: no press reaches `VoiceInput` and the token never reaches the API.
@MainActor
final class BadgeGestureTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testATapOpensTheSettings() throws {
        let app = launch()
        badge(in: app).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "the tap did not open the settings")
        XCTAssertFalse(app.navigationBars["Diagnostics"].exists, "the tap also opened the diagnostics")
    }

    func testAHoldOpensTheDiagnostics() throws {
        let app = launch()
        badge(in: app).press(forDuration: 1)
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 10),
                      "the hold did not open the diagnostics")
        XCTAssertFalse(app.navigationBars["Settings"].exists, "the hold also opened the settings")
    }

    /// The badge is the element carrying the chat's debug report, and it is a button. A toolbar
    /// item's container carries its one child's identifier too, so the type is what names the one
    /// that is the badge.
    private func badge(in app: XCUIApplication) -> XCUIElement {
        let badge = app.buttons["topo-debug-chat"]
        XCTAssertTrue(badge.waitForExistence(timeout: 60), "the chat screen, with its badge")
        return badge
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        // Neither model is wanted here, and an ear that never loads is one nothing asks the
        // microphone for.
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        app.launchArguments += ["-firstRunAnswered", "YES"]
        app.launch()
        return app
    }
}
