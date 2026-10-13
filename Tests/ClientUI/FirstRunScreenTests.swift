import XCTest

/// The chat's two screens before there is a conversation, as the app draws them: the question
/// over a log read and found empty, and the placeholder over a log not read yet. Each is reached
/// through `TOPO_DEBUG_LOG`, which stands a log in memory, or one no read returns from, in the
/// place of iCloud's.
@MainActor
final class FirstRunScreenTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Over an empty log the question stands over the chat, and its typed answer is the first
    /// turn: the question goes and the words are in the transcript.
    func testAnEmptyLogAsksTheQuestionAndItsAnswerIsTheFirstTurn() {
        let app = launch(log: "empty")
        let question = app.descendants(matching: .any).matching(identifier: "first-run").firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 60), "an empty log asked nothing")
        XCTAssertTrue(app.staticTexts["What did you forget this week?"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "reading-log").firstMatch.exists,
                       "the placeholder stands over a log that has been read")
        attach(app, "first-run-question")

        let field = app.textFields["Type it instead"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the question has no field")
        field.tap()
        field.typeText("The bins on Thursday")
        app.buttons["Go"].tap()

        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: question)], timeout: 20)
        XCTAssertTrue(app.staticTexts["The bins on Thursday"].waitForExistence(timeout: 20),
                      "the answer is not in the transcript")
        attach(app, "first-run-answered")
    }

    /// Until the log has been read the chat says it is reading it, and asks nothing.
    func testAnUnreadLogSaysItIsBeingReadAndAsksNothing() {
        let app = launch(log: "unread")
        let reading = app.descendants(matching: .any).matching(identifier: "reading-log").firstMatch
        XCTAssertTrue(reading.waitForExistence(timeout: 60), "an unread log drew no placeholder")
        XCTAssertEqual(reading.label, "Reading your conversation…")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "first-run").firstMatch.exists,
                       "the question was asked before the log was read")
        attach(app, "reading-log")
    }

    private func launch(log: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TOPO_DEBUG_LOG"] = log
        app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
        app.launchEnvironment["TOPO_DEBUG_KEEP_SPOKEN"] = "1"
        app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
        app.launchEnvironment["TOPO_DEBUG_OUTBOX"] = ""
        app.launchArguments += ["-firstRunAnswered", "NO"]
        app.launch()
        ChatReading.dismissAccountAlert()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        ChatReading.attach(app, name, to: self)
    }
}
