import XCTest

/// The row the next turn is written in, driven from outside the app. Three things here are only
/// answered by a running app: that the control on the glass raises the keyboard and the row is
/// what takes it, that what is typed reaches the row, and that a turn on its way holds its words
/// in the row with no way to type over them.
///
/// The turn never settles: the app is launched with `TOPO_DEBUG_REPLY_DELAY`, which holds the
/// harness before the model call and so before the person's turn is written, on any host — one
/// with an iCloud account behind the simulator and one without. So the row stays in flight for
/// the length of the test wherever it runs, and no turn reaches the API.
///
/// Every state it puts the row in is photographed into the result bundle, which is where the
/// screenshots on the PR come from: `xcrun xcresulttool export attachments`.
@MainActor
final class DraftRowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The keyboard flank is the way to the keyboard, and the row is what has it: a control that
    /// raised a keyboard with nothing focused would be a person typing into nothing.
    func testTheKeyboardFlankRaisesTheKeyboardIntoTheRow() throws {
        let app = launch()
        XCTAssertFalse(field(in: app).exists, "the row is drawn before anything asks for it")

        keyboardFlank(in: app).tap()

        let field = field(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the flank put no row at the end of the transcript")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10), "the flank raised no keyboard")
        XCTAssertTrue(field.hasKeyboardFocus, "the keyboard is up with the row not focused")
        shot(app, "empty")
    }

    /// What is typed is in the row, and sending it leaves the words there under a spinner with
    /// the field closed to typing: the turn is on its way and what it says cannot change.
    func testWhatIsWrittenStaysInTheRowWhileTheTurnIsOnItsWay() throws {
        let app = launch()
        keyboardFlank(in: app).tap()
        let field = field(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the row is at the end of the transcript")
        field.typeText(Self.words)
        XCTAssertEqual(field.value as? String, Self.words, "what was typed is not in the row")
        XCTAssertTrue(field.isEnabled, "the row cannot be typed into before the turn is sent")
        shot(app, "written")

        app.buttons["Send"].tap()

        let sending = app.descendants(matching: .any)["Sending"]
        XCTAssertTrue(sending.waitForExistence(timeout: 10), "the turn went with nothing saying so")
        XCTAssertFalse(app.buttons["Send"].exists,
                       "the send control is still in the slot while the turn is on its way")
        let inFlight = self.field(in: app)
        XCTAssertTrue(inFlight.waitForExistence(timeout: 5), "the words left the row when the turn went")
        XCTAssertEqual(inFlight.value as? String, Self.words, "the row is not holding the words that went")
        XCTAssertFalse(inFlight.isEnabled, "the words on their way can still be typed over")
        shot(app, "in-flight")

        // What the chat says under the row when the write stopped rather than merely taking its
        // time: the error line, and the line's own way forward. A simulator with an iCloud
        // account behind it reaches neither — its turn is genuinely on its way — so this waits
        // and photographs what it finds rather than asserting either way.
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Send \\\"'")).firstMatch
            .waitForExistence(timeout: 15)
        shot(app, "failed")
    }

    // MARK: -

    /// Long enough to wrap in the bubble on a phone, which is what the row is for.
    static let words = "Remind me to pick up Daphne's food on the way home"

    /// The field in the row. A vertically growing `TextField` is a text view to XCUITest, and a
    /// one-line one is a text field, so both are asked for by the label the row gives it.
    private func field(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'What to say'")).firstMatch
    }

    private func keyboardFlank(in app: XCUIApplication) -> XCUIElement {
        let flank = app.buttons["Type instead"]
        XCTAssertTrue(flank.waitForExistence(timeout: 60), "the chat screen, with the glass under it")
        return flank
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "draft-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Signed in with a placeholder token and past the first-run question, with neither model
    /// resident — nothing here presses the microphone — and the turn held before the model call
    /// so the row it is sent from stays in flight.
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
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

private extension XCUIElement {
    /// Whether this element is the one the keyboard is typing into.
    var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
