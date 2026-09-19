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
        // The rows the sheet is for. Their order is the screenshots' to show; that each is there
        // at all is cheap enough to hold here.
        for row in ["Model", "Read replies aloud", "Vocabulary", "Where it lives", "Diagnostics",
                    "About Topo", "Sign out"] {
            XCTAssertTrue(app.descendants(matching: .any)[row].exists, "the settings have no \(row)")
        }
    }

    /// A hold just past the gesture's own threshold.
    func testAShortHoldOpensTheDiagnosticsAndNothingElse() throws {
        try holdOpensOnlyTheDiagnostics(for: 1)
    }

    /// A hold a person actually makes. It is a case of its own because what a press leaves
    /// behind depends on how long it was: the release of a long one is where a second action
    /// would fire, and a badge whose release is not exclusive opens the settings over the
    /// diagnostics on the way up.
    func testALongHoldOpensTheDiagnosticsAndNothingElse() throws {
        try holdOpensOnlyTheDiagnostics(for: 2.5)
    }

    private func holdOpensOnlyTheDiagnostics(for hold: TimeInterval) throws {
        let app = launch()
        badge(in: app).press(forDuration: hold)
        // Asked first, because a release that is also a tap puts the settings up over the
        // diagnostics and this is the symptom that says so.
        XCTAssertFalse(app.navigationBars["Settings"].waitForExistence(timeout: 3),
                       "a \(hold)s hold left the settings on screen")
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 10),
                      "a \(hold)s hold did not open the diagnostics")
        // One sheet is presented at a time, so Diagnostics standing says nothing about whether
        // the same press also asked for the settings. What answers that is dismissing this one
        // and looking at what the press left behind it.
        app.navigationBars["Diagnostics"].buttons["Done"].tap()
        XCTAssertFalse(app.navigationBars["Settings"].waitForExistence(timeout: 5),
                       "a \(hold)s hold also opened the settings")
        XCTAssertTrue(app.buttons["topo-debug-chat"].waitForExistence(timeout: 10),
                      "the chat is back with nothing over it")
    }

    /// A hold whose release the button never sees: the finger leaves the badge before it lifts.
    /// The mark that hold left behind must not swallow the next tap.
    func testATapAfterAHoldDraggedOffTheBadgeStillOpensTheSettings() throws {
        let app = launch()
        let badge = badge(in: app)
        badge.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 1,
                   thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 10),
                      "the hold did not open the diagnostics")
        app.navigationBars["Diagnostics"].buttons["Done"].tap()
        XCTAssertTrue(app.buttons["topo-debug-chat"].waitForExistence(timeout: 10),
                      "the chat is back")
        badge.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10),
                      "the tap after a dragged-off hold opened nothing")
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
