import XCTest

/// The chat's two screens before there is a conversation, as the app draws them: the question
/// over a log read and found empty, and the placeholder over a log not read yet. Each is reached
/// through `TOPO_DEBUG_LOG`, a stand-in for iCloud's log that takes no save and answers every
/// read with nothing, or fails every read.
@MainActor
final class FirstRunScreenTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Over an empty log the chat asks the question, Topo holding it on a sign with the line
    /// under the transcript saying the rest, and the answer typed into the composer goes on the
    /// line: the question goes and the words are in the transcript as a turn on its way. The
    /// stand-in takes no save, so nothing here shows the turn reaching a log, and the launch
    /// argument that asks the question on every run also keeps `firstRunAnswered` from being
    /// what takes it away.
    func testAnEmptyLogAsksTheQuestionAndItsAnswerIsDrawnOnItsWay() {
        // The answer stays on the line, which is on disk: the next suite's launch is not left it.
        addTeardownBlock { @MainActor in
            let app = XCUIApplication()
            app.launchEnvironment["TOPO_DEBUG_OUTBOX"] = ""
            app.launchEnvironment["TOPO_DEBUG_LOG"] = "unread"
            app.launchEnvironment["TOPO_CLAUDE_SETUP_TOKEN"] = "ui-test-placeholder"
            app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"
            app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"
            app.launchArguments += ["-firstRunAnswered", "YES"]
            app.launch()
            app.terminate()
        }
        let app = launch(log: "empty")
        let question = app.descendants(matching: .any).matching(identifier: "first-run").firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 60), "an empty log asked nothing")
        XCTAssertTrue(question.label.hasPrefix("What did you forget this week?"), "the question says \"\(question.label)\"")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "reading-log").firstMatch.exists,
                       "the placeholder stands over a log that has been read")
        attach(app, "first-run-question")

        ChatReading.raiseKeyboard(app)
        let field = ChatReading.field(app)
        field.typeText("The bins on Thursday")
        app.buttons["Send"].tap()

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
        XCTAssertTrue(reading.label.hasSuffix("Reading your conversation…"), "the placeholder says \"\(reading.label)\"")
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
