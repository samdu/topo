import XCTest

/// The work row's three depths on the screen of a running app: the chat launched over the `long`
/// fixture with `TOPO_DEBUG_WORK=steps` (`DebugRun.work`), whose steps stand under the last turn
/// of the person's. Closed, it says the count of calls; a tap opens a line per step; a tap on a
/// line opens that step in full; "show all" opens a long result on its sheet. Each depth is
/// attached.
@MainActor
final class WorkRowTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testTheRowOpensToItsStepsAndAStepToItsInputAndResult() throws {
        let app = ChatReading.launch(transcript: "long", tuning: "", environment: ["TOPO_DEBUG_WORK": "steps"])
        let closed = app.buttons["4 calls"]
        XCTAssertTrue(closed.waitForExistence(timeout: 60), "the closed row and its count")
        XCTAssertFalse(app.staticTexts["Grep"].exists, "the steps are drawn while the row is closed")
        ChatReading.attach(app, "1 closed", to: self)

        closed.tap()
        let bash = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Compare with last week's log")).firstMatch
        XCTAssertTrue(bash.waitForExistence(timeout: 10), "the open row's line for the Bash call")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "command: diff")).firstMatch.exists,
                       "the Bash call's input is drawn before its line is opened")
        ChatReading.attach(app, "2 open", to: self)

        bash.tap()
        let command = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "command: diff")).firstMatch
        XCTAssertTrue(command.waitForExistence(timeout: 10), "the Bash call's command, opened")
        XCTAssertTrue(app.staticTexts["grep: last-week.log: No such file or directory"].exists, "its result")
        ChatReading.attach(app, "3 a call opened", to: self)

        let thought = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "thought")).firstMatch
        thought.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "The person wants to know")).firstMatch
            .waitForExistence(timeout: 10), "the thought's text, opened")

        let search = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "certificate rotation warning")).firstMatch
        search.tap()
        let all = app.buttons["show all"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), "a long result shows its head and a way to all of it")
        ChatReading.attach(app, "4 a thought and a long result opened", to: self)
        all.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), "the sheet with the whole result")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "(60 of 60)")).firstMatch.exists,
                      "the sheet holds the result's last line")
        ChatReading.attach(app, "5 the whole result", to: self)
    }
}
