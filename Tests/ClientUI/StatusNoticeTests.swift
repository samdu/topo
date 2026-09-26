import XCTest

/// Where the chat's notices are drawn: in the navigation bar beside the badge, and not over the
/// composer. Only a running app lays out a toolbar, so this is a UI test.
///
/// The turn never settles: the app is launched with `TOPO_DEBUG_REPLY_DELAY`, which holds the
/// harness before the model call, so a notice stands for the length of the test on any host —
/// the status of the turn in flight on one with an iCloud account behind the simulator, the
/// failure on one without. Either is a notice, and both are held to the same place.
@MainActor
final class StatusNoticeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheNoticesAreInTheNavigationBarBesideTheBadge() throws {
        let app = launch()
        let flank = app.buttons["Type instead"]
        XCTAssertTrue(flank.waitForExistence(timeout: 60), "the chat screen, with the glass under it")
        flank.tap()
        let field = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'What to say'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the flank put no row at the end of the transcript")
        field.typeText("What's the weather like?")
        app.buttons["Send"].tap()

        let notices = app.descendants(matching: .any).matching(identifier: "topo-notices").firstMatch
        XCTAssertTrue(notices.waitForExistence(timeout: 30), "a turn went and no notice said so")
        let words = notices.staticTexts.firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 10), "the notices hold no words")
        XCTAssertFalse(words.label.isEmpty, "the notice is empty")

        let badge = app.buttons["topo-debug-chat"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "no badge in the navigation bar")
        attach(app)
        XCTAssertLessThanOrEqual(abs(words.frame.midY - badge.frame.midY), badge.frame.height / 2,
                                 "the notice \"\(words.label)\" at \(words.frame) is not in the bar beside the badge at \(badge.frame)")
        let inFlight = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'What to say'")).firstMatch
        XCTAssertTrue(inFlight.waitForExistence(timeout: 10), "the row left the transcript when the turn went")
        XCTAssertLessThanOrEqual(words.frame.maxY, inFlight.frame.minY,
                                 "the notice at \(words.frame) is under the row at \(inFlight.frame)")
    }

    // MARK: -

    private func attach(_ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "notices"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Signed in with a placeholder token, past the first-run question, with nothing on the line
    /// and neither model resident, and the turn held before the model call.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_DEBUG_OUTBOX"] = ""
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_REPLY_DELAY"] = "600"
        app.launchArguments += ["-firstRunAnswered", "YES"]
        app.launch()
        return app
    }
}
