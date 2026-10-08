import XCTest

/// The two controls at the leading edge of the chat's navigation bar, in the running chat: the
/// model, a menu, and the mute. Read off the controls' own labels and values and, for the model,
/// off the badge's debug report (`DebugRun.ChatReport`), which carries the harness's own setting
/// apart from the model a request carries for it: a menu that changed what it says and left the
/// harness alone is caught by the first, and a choice that moved a debug build off its pin by
/// the second.
///
/// Both settings outlive a launch, so neither test assumes the state it starts in, and each leaves
/// replies read aloud and the first model chosen.
@MainActor
final class BarControlsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The model a debug build asks whatever is chosen (`ClaudeModel.effective`).
    static let pin = "claude-haiku-4-5-20251001"

    /// The mute is one control with two states, and a press changes which it is.
    func testTheMuteInTheBarTurnsReadingAloudOffAndOnAgain() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "")
        let mute = app.buttons["chat-mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 60), "the bar has no mute")
        if mute.label == "Read replies aloud" { mute.tap() }
        XCTAssertTrue(becomes(mute, "label == 'Mute replies'"), "replies are not read aloud to begin with: \(mute.label)")
        mute.tap()
        XCTAssertTrue(becomes(mute, "label == 'Read replies aloud'"), "a press did not mute: \(mute.label)")
        ChatReading.attach(app, "muted", to: self)
        mute.tap()
        XCTAssertTrue(becomes(mute, "label == 'Mute replies'"), "a second press did not unmute: \(mute.label)")
    }

    /// The model's control opens a menu of the models the chat offers; the one pressed is the
    /// model chosen, said by the control and set on the harness, and a debug build still asks its
    /// pin after every choice. Neither control is on the glass.
    func testTheMenuChoosesTheModelTheHarnessAsksUnderTheDebugPin() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "")
        let model = app.buttons["chat-model"], mic = ChatReading.microphone(app)
        XCTAssertTrue(model.waitForExistence(timeout: 60), "the bar has no model control")
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "the chat screen")
        for control in [model, app.buttons["chat-mute"]] {
            XCTAssertLessThan(control.frame.maxY, mic.frame.minY, "\(control.identifier) is on the glass")
            XCTAssertLessThan(control.frame.midX, app.windows.firstMatch.frame.midX, "\(control.identifier) is not at the bar's leading edge")
        }
        XCTAssertLessThan(model.frame.midX, app.buttons["chat-mute"].frame.midX, "the mute is before the model")
        for old in ["composer-model", "composer-mute", "composer-models"] {
            XCTAssertFalse(app.descendants(matching: .any)[old].exists, "\(old) is still on the glass")
        }
        for (alias, name) in [("opus", "Opus"), ("fable", "Fable"), ("sonnet", "Sonnet")] {
            try choose(name, from: model, in: app)
            XCTAssertTrue(becomes(model, "value == '\(name)'"), "\(alias) chosen, and the control says \(String(describing: model.value))")
            let deadline = Date().addingTimeInterval(10)
            while ChatReading.chat(app)?.model != alias, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            let chat = try XCTUnwrap(ChatReading.chat(app), "the chat reports nothing")
            XCTAssertEqual(chat.model, alias, "the menu says \(name) and the harness was set to \(chat.model ?? "nothing")")
            XCTAssertEqual(chat.effectiveModel, Self.pin, "choosing \(alias) moved a debug build off its pin")
        }
        ChatReading.attach(app, "model-chosen", to: self)
    }

    /// The menu opens with the keyboard up and the row being typed in, the one pressed is the
    /// model chosen, and what was written is still in the field after.
    func testTheMenuChoosesAModelOverTheKeyboard() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "", softwareKeyboard: true)
        let model = app.buttons["chat-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 60), "the bar has no model control")
        ChatReading.raiseKeyboard(app)
        let field = ChatReading.field(app)
        field.typeText("Hi")
        try choose("Opus", from: model, in: app, shot: "menu-over-keyboard")
        XCTAssertTrue(becomes(model, "value == 'Opus'"), "a model pressed over the keyboard chose nothing")
        XCTAssertEqual(ChatReading.chat(app)?.model, "opus")
        XCTAssertEqual(field.value as? String, "Hi", "choosing a model took what was written")
        try choose("Sonnet", from: model, in: app)
        XCTAssertTrue(becomes(model, "value == 'Sonnet'"))
    }

    /// What the look calls a model is what the bar calls it: the menu's item and the control's
    /// value, for the one the look renames and no other.
    func testTheBarCallsAModelWhatTheLookCallsIt() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "", look: #"{"mind": {"opus": "Opus 5.5"}}"#)
        let model = app.buttons["chat-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 60), "the bar has no model control")
        model.tap()
        XCTAssertTrue(app.buttons["Opus 5.5"].waitForExistence(timeout: 10), "the menu does not offer Opus by the look's name")
        XCTAssertTrue(app.buttons["Sonnet"].exists, "the menu renamed a model the look did not")
        XCTAssertFalse(app.buttons["Haiku"].exists, "the menu offers the debug pin as a choice")
        app.buttons["Opus 5.5"].tap()
        XCTAssertTrue(becomes(model, "value == 'Opus 5.5'"), "the control says \(String(describing: model.value))")
        XCTAssertEqual(ChatReading.chat(app)?.model, "opus")
        try choose("Sonnet", from: model, in: app)
        XCTAssertTrue(becomes(model, "value == 'Sonnet'"))
    }

    /// At each end of what a document may ask of the bar — the largest font a document's size is
    /// drawn at with the controls furthest apart, and the smallest with none between them — the
    /// model and the mute are inside the navigation bar, in order, clear of each other and of
    /// the badge, and the model still opens its menu. On the phone this suite runs on, which is
    /// wider than the narrowest.
    func testAtEachEndOfTheBarsRangesBothControlsStayInTheBarBesideTheBadge() throws {
        for (what, look) in [("largest", #"{"bar": {"font": {"size": 400}, "spacing": 64}}"#),
                             ("smallest", #"{"bar": {"font": {"size": 4}, "spacing": 0}}"#)] {
            let app = ChatReading.launch(transcript: "empty", tuning: "", look: look)
            let model = app.buttons["chat-model"], mute = app.buttons["chat-mute"], badge = app.buttons["topo-debug-chat"]
            XCTAssertTrue(model.waitForExistence(timeout: 60), "\(what): the bar has no model control")
            XCTAssertTrue(mute.exists && badge.waitForExistence(timeout: 10), "\(what): the bar is without its mute or its badge")
            let bar = app.navigationBars.firstMatch.frame
            for (name, control) in [("model", model), ("mute", mute)] {
                XCTAssertTrue(bar.insetBy(dx: -0.5, dy: -0.5).contains(control.frame),
                              "\(what): the \(name) at \(control.frame) is out of the bar at \(bar)")
                XCTAssertGreaterThan(control.frame.width, 0, "\(what): the \(name) has no width")
            }
            XCTAssertLessThanOrEqual(model.frame.maxX, mute.frame.minX + 0.5, "\(what): the model at \(model.frame) is over the mute at \(mute.frame)")
            XCTAssertLessThanOrEqual(mute.frame.maxX, badge.frame.minX + 0.5, "\(what): the mute at \(mute.frame) is over the badge at \(badge.frame)")
            ChatReading.attach(app, "bar-\(what)", to: self)
            try choose("Opus", from: model, in: app)
            XCTAssertTrue(becomes(model, "value == 'Opus'"), "\(what): the model's menu chose nothing")
            try choose("Sonnet", from: model, in: app)
            app.terminate()
        }
    }

    /// Opens the menu and presses the model called `name`.
    private func choose(_ name: String, from model: XCUIElement, in app: XCUIApplication, shot: String? = nil) throws {
        model.tap()
        let item = app.buttons[name]
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the menu does not offer \(name)")
        if let shot { ChatReading.attach(app, shot, to: self) }
        item.tap()
    }

    /// Waits, bounded, for `element` to be as `predicate` says: what a tap changes is drawn by the
    /// app's next update, which a snapshot taken on the line after the tap can come before.
    private func becomes(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
