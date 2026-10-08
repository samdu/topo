import XCTest

/// The person's next turn, driven from outside the app: written in the glass's field while the
/// pane is a row, and drawn at the end of the transcript while it is on its way. What is here is
/// only answered by a running app: that the mark on the resting pane raises the keyboard and the
/// pane's field is what takes it, that the pane is then one row in the order the look gives it,
/// that what is typed on the keyboard reaches the field and is sent from the glass, that a field
/// of many lines grows the pane upward, that a turn on its way is drawn once and cannot be typed
/// over, and that the keyboard goes down by a tap on the transcript's empty space or a drag down
/// it and by neither on a turn's words.
///
/// A sent turn never settles: the app is launched with `TOPO_DEBUG_REPLY_DELAY`, which holds the
/// harness before the model call and so before the person's turn is written, on any host — one
/// with an iCloud account behind the simulator and one without. So the row stays in flight for
/// the length of the test wherever it runs, and no turn reaches the API.
///
/// Every state it puts the pane in is photographed into the result bundle, which is where the
/// screenshots on the PR come from: `xcrun xcresulttool export attachments`.
@MainActor
final class DraftRowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The mark on the resting pane is the way to the keyboard, and the pane's field is what has
    /// it. The pane is then a row: the microphone, the control for everything else, the field and
    /// the send, leading to trailing, level, wider than it was at rest, with the way to the
    /// keyboard gone from it.
    func testTheKeyboardMarkRaisesTheKeyboardIntoThePanesRow() throws {
        let app = launch(owed: "")
        let mark = keyboardMark(in: app)
        let mic = ChatReading.microphone(app), more = app.buttons["composer-more"]
        XCTAssertFalse(ChatReading.fieldShown(app), "the field is there to be typed in before the pane is a row")
        XCTAssertFalse(app.buttons["Send"].exists, "the send is there to be pressed before the pane is a row")
        XCTAssertTrue(more.exists, "the resting pane has no control for everything else")
        XCTAssertLessThan(more.frame.midX, mic.frame.minX, "the control is not on the leading flank")
        XCTAssertGreaterThan(mark.frame.midX, mic.frame.maxX, "the way to the keyboard is not on the trailing flank")
        XCTAssertEqual(mic.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 1, "the resting jewel is not in the middle")
        let resting = mic.frame
        shot(app, "resting")

        mark.tap()

        let field = ChatReading.field(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the mark put no field in the glass")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10), "the mark raised no keyboard")
        XCTAssertTrue(field.hasKeyboardFocus, "the keyboard is up with the field not focused")
        let send = app.buttons["Send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "the row has no send")
        XCTAssertFalse(send.isEnabled, "a send with nothing to send can be pressed")
        XCTAssertFalse(app.buttons["Type instead"].exists, "the way to the keyboard is still on the row")
        XCTAssertFalse(app.buttons["Hide the keyboard"].exists)
        try settled(mic)
        XCTAssertLessThan(mic.frame.width, resting.width, "the jewel is not drawn short in the row")
        XCTAssertLessThan(mic.frame.maxX, more.frame.minX + 1, "the control is not after the jewel")
        XCTAssertLessThan(more.frame.maxX, field.frame.minX + 1, "the field is not after the control")
        XCTAssertLessThan(field.frame.maxX, send.frame.minX + 1, "the send is not after the field")
        XCTAssertLessThan(mic.frame.midX, app.windows.firstMatch.frame.width / 4, "the jewel is not in the pane's leading end")
        for element in [more, field, send] {
            XCTAssertEqual(element.frame.midY, mic.frame.midY, accuracy: 2, "\(element.label) is not level with the jewel")
        }
        XCTAssertLessThan(send.frame.maxY, app.keyboards.element.frame.minY, "the row is under the keyboard")
        shot(app, "row-empty")
    }

    /// What is typed on the keyboard is in the field, and what is written past one line grows the
    /// field and the pane upward, the jewel and the send staying on the pane's bottom line, until
    /// the field has the look's most lines and scrolls inside itself.
    func testWhatIsWrittenGrowsThePaneUpwardToTheLooksLines() throws {
        let app = launch(owed: "")
        keyboardMark(in: app).tap()
        let field = ChatReading.field(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the mark put no field in the glass")
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10), "no keyboard on screen")
        let mic = ChatReading.microphone(app), send = app.buttons["Send"]
        try settled(mic)
        let empty = field.frame, level = mic.frame

        // On the keyboard's own keys, as a thumb does.
        for key in ["H", "i"] {
            let key = app.keyboards.keys[key]
            XCTAssertTrue(key.waitForExistence(timeout: 5), "the keyboard has no such key")
            key.tap()
        }
        XCTAssertEqual(field.value as? String, "Hi", "what was typed on the keyboard is not in the field")
        XCTAssertTrue(send.isEnabled, "the send cannot be pressed with something to send")
        XCTAssertEqual(field.frame.height, empty.height, accuracy: 1, "one line of words made the field taller")
        shot(app, "row-one-line")

        field.typeText(" " + Self.long)
        try settled(mic)
        let tall = field.frame
        XCTAssertGreaterThan(tall.height, empty.height * 2, "a field of many lines is drawn no taller than one")
        XCTAssertEqual(tall.maxY, empty.maxY, accuracy: 1, "the field grew downward")
        XCTAssertEqual(mic.frame.maxY, level.maxY, accuracy: 1, "the jewel left the pane's bottom line")
        XCTAssertEqual(send.frame.midY, mic.frame.midY, accuracy: 2, "the send left the pane's bottom line")
        shot(app, "row-wrapped")

        field.typeText(" " + Self.long + " " + Self.long)
        try settled(mic)
        XCTAssertEqual(field.frame.height, tall.height, accuracy: 1,
                       "the field grew past the look's lines instead of scrolling inside itself")
        XCTAssertLessThan(field.frame.height, empty.height * 6, "the field is taller than the look's five lines")
        XCTAssertGreaterThan(field.frame.minY, 80, "the pane grew up into the navigation bar")
        XCTAssertEqual(field.value as? String, "Hi " + Self.long + " " + Self.long + " " + Self.long,
                       "words written past the field's lines were not kept")
        shot(app, "row-at-limit")
    }

    /// A look that asks for the most lines the reader takes does not grow the pane up behind the
    /// navigation bar: the field takes the lines the room above the keyboard holds and scrolls
    /// inside itself from there, with all that was written kept.
    func testTheLooksMostLinesStopUnderTheNavigationBar() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "", look: #"{"draft": {"maximumLines": 20}}"#,
                                     softwareKeyboard: true)
        ChatReading.raiseKeyboard(app)
        let field = ChatReading.field(app), mic = ChatReading.microphone(app)
        let written = String(repeating: Self.long + " ", count: 5)
        field.typeText(written)
        try settled(mic)
        let bar = app.navigationBars.firstMatch
        XCTAssertTrue(bar.exists, "the chat has no navigation bar")
        XCTAssertGreaterThanOrEqual(field.frame.minY, bar.frame.maxY, "the field at \(field.frame) is behind the bar at \(bar.frame)")
        XCTAssertGreaterThan(field.frame.height, 6 * 20, "the field took no more lines than the default look's")
        XCTAssertLessThan(field.frame.maxY, app.keyboards.element.frame.minY, "the field is under the keyboard")
        XCTAssertEqual(field.value as? String, written, "words written past the room's lines were not kept")
        shot(app, "row-most-lines")
    }

    /// Sending from the glass puts the turn on its way: the words are drawn once, in the row at
    /// the end of the transcript beside a spinner, the field is closed and the keyboard falls
    /// with the pane back at rest.
    func testASentTurnIsDrawnOnceOnItsWayAndTheFieldCloses() throws {
        let app = launch(owed: "")
        keyboardMark(in: app).tap()
        let field = ChatReading.field(app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the mark put no field in the glass")
        field.typeText(Self.words)
        XCTAssertEqual(field.value as? String, Self.words, "what was typed is not in the field")
        XCTAssertTrue(field.isEnabled, "the field cannot be typed into before the turn is sent")
        XCTAssertEqual(drawings(of: Self.words, in: app), 1, "what is being written is drawn other than once")
        XCTAssertFalse(app.descendants(matching: .any)[Self.row].exists, "the row draws what the field is writing")
        shot(app, "written")

        app.buttons["Send"].tap()

        XCTAssertTrue(app.descendants(matching: .any)["Sending"].waitForExistence(timeout: 10), "the turn went with nothing saying so")
        let row = app.descendants(matching: .any)[Self.row]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the words left the screen when the turn went")
        XCTAssertEqual(row.label, Self.words, "the row is not holding the words that went")
        XCTAssertTrue(ChatReading.keyboardGone(app), "the keyboard stayed up over a turn on its way")
        XCTAssertFalse(ChatReading.fieldShown(app), "the field is still there to be typed into over a turn on its way")
        XCTAssertFalse(ChatReading.field(app).isEnabled, "the field takes typing over a turn on its way")
        XCTAssertFalse(app.buttons["Send"].exists, "the send is still there to be pressed over a turn on its way")
        XCTAssertEqual(drawings(of: Self.words, in: app), 1, "the turn on its way is drawn other than once")
        XCTAssertTrue(app.buttons["Type instead"].waitForExistence(timeout: 5), "the pane did not go back to rest")
        shot(app, "in-flight")

        // What the chat says under the row when the write stopped rather than merely taking its
        // time: the error line, and the line's own way forward. A simulator with an iCloud
        // account behind it reaches neither — its turn is genuinely on its way — so this waits
        // and photographs what it finds rather than asserting either way.
        _ = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Send \\\"'")).firstMatch
            .waitForExistence(timeout: 15)
        shot(app, "failed")
    }

    /// An app killed with words said and not yet in the log comes back to the row they were sent
    /// from: the words in it, on their way, with nothing to type over them in. The launch is
    /// given a turn already on the line (`TOPO_DEBUG_OUTBOX`), which is the state a relaunch finds
    /// and the one no suite can reach by sending a turn and killing the app mid-write.
    func testAnAppKilledWithWordsOnTheLineComesBackToTheRowTheyWereSentFrom() throws {
        let app = launch(owed: Self.owed)

        let row = app.descendants(matching: .any)[Self.row]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "the relaunch drew no row at all")
        XCTAssertEqual(row.label, Self.owed, "the row came back without the words on the line")
        XCTAssertTrue(app.descendants(matching: .any)["Sending"].waitForExistence(timeout: 10),
                      "the words came back with nothing saying they are on their way")
        XCTAssertFalse(ChatReading.fieldShown(app), "the words on their way can be typed over")
        XCTAssertFalse(ChatReading.field(app).isEnabled, "the field takes typing over words on their way")
        XCTAssertFalse(app.buttons["Send"].exists, "the send is there over a turn on its way")
        XCTAssertEqual(drawings(of: Self.owed, in: app), 1)
        shot(app, "resumed")
    }

    /// The keyboard goes down by a tap on the transcript's own empty space and by a drag down the
    /// transcript, with the pane back at rest each time. A tap on a turn's words is no such tap:
    /// the keyboard stays where it is.
    func testATapOutsideAndADragDownLowerTheKeyboardAndATapOnATurnDoesNot() throws {
        let app = ChatReading.launch(transcript: "links", tuning: "", softwareKeyboard: true)
        XCTAssertTrue(app.buttons["Type instead"].waitForExistence(timeout: 60), "the chat screen, with the glass under it")
        ChatReading.raiseKeyboard(app)
        XCTAssertTrue(ChatReading.fieldShown(app))

        // A reply's words that are no link (`PreviewTurns.links`), above the keyboard.
        let words = app.staticTexts["see the docs"]
        XCTAssertTrue(words.waitForExistence(timeout: 10), "no turn's words on the screen")
        XCTAssertLessThan(words.frame.maxY, app.keyboards.element.frame.minY, "the turn is under the keyboard")
        words.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertTrue(app.keyboards.element.exists, "a tap on a turn's words lowered the keyboard")
        XCTAssertTrue(ChatReading.fieldShown(app), "a tap on a turn's words took the field away")

        // What is written and left when the keyboard is lowered is the transcript row's to draw
        // and to read: the field at rest says none of it.
        ChatReading.field(app).typeText("bins")
        ChatReading.lowerKeyboard(app)
        XCTAssertTrue(app.buttons["Type instead"].waitForExistence(timeout: 5), "the pane did not go back to rest after the tap")
        XCTAssertFalse(ChatReading.fieldShown(app))
        let left = app.descendants(matching: .any)[Self.row]
        XCTAssertTrue(left.waitForExistence(timeout: 5), "what was written left the screen with the keyboard")
        XCTAssertEqual(left.label, "bins")
        let reads = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'bins' OR value == 'bins'")).count
        XCTAssertEqual(reads, 1, "what was written is read \(reads) times at rest")

        ChatReading.raiseKeyboard(app)
        let window = app.windows.firstMatch
        let from = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        from.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(ChatReading.keyboardGone(app), "a drag down the transcript left the keyboard up")
        XCTAssertTrue(app.buttons["Type instead"].waitForExistence(timeout: 5), "the pane did not go back to rest after the drag")
    }

    // MARK: -

    /// What a launch is given as already said and not yet in the log.
    static let owed = "water the plants"

    /// Long enough to wrap in the bubble on a phone, which is what the row is for.
    static let words = "Remind me to pick up Daphne's food on the way home"

    /// Enough to fill the field's lines on a phone and on a pad.
    static let long = String(repeating: "and then the bins, the plants on the stairs and the post, ", count: 6)

    /// The row at the end of the transcript's words (`DraftRow.identifier`).
    static let row = "draft-row"

    /// How many things on the screen say `words`, by their label or their value: what is written
    /// is drawn in one place.
    private func drawings(of words: String, in app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@ OR value == %@", words, words))
            .allElementsBoundByIndex.filter { $0.elementType == .staticText || $0.elementType == .textView || $0.elementType == .textField }.count
    }

    /// Waits for `element` to stop moving: the pane changes form on the keyboard's curve.
    private func settled(_ element: XCUIElement, timeout: TimeInterval = 5) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var last = element.frame
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            if element.frame == last { return }
            last = element.frame
        }
        XCTFail("\(element.label) was still moving after \(timeout) s")
    }

    private func keyboardMark(in app: XCUIApplication) -> XCUIElement {
        let mark = app.buttons["Type instead"]
        XCTAssertTrue(mark.waitForExistence(timeout: 60), "the chat screen, with the glass under it")
        return mark
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "draft-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Signed in with a placeholder token and past the first-run question, with neither model
    /// resident — nothing here presses the microphone — and the turn held before the model call
    /// so the row it is sent from stays in flight. The keyboard is the one a phone has, on the
    /// screen, whatever the simulator has connected.
    /// `owed` is what is on the harness's line at the launch, in place of whatever the last one
    /// left: a turn said and not settled stays on disk, so every test here says what it wants
    /// rather than inheriting the turn the test before it sent and never landed.
    private func launch(owed: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_DEBUG_OUTBOX"] = owed
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_REPLY_DELAY"] = "600"
        app.launchEnvironment["TOPO_DEBUG_SOFTWARE_KEYBOARD"] = "1"
        app.launchArguments += ["-firstRunAnswered", "YES"]
        app.launch()
        return app
    }
}

private extension XCUIElement {
    /// Whether this element is the one the keyboard is typing into.
    var hasKeyboardFocus: Bool { (value(forKey: "hasKeyboardFocus") as? Bool) ?? false }
}
