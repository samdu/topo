import XCTest

/// The two controls at the leading edge of the chat's navigation bar, in the running chat: the
/// model, which opens the model slider across the middle of the bar, and the mute, each standing
/// apart. Read off the controls' own labels and values and, for the model, off the badge's debug
/// report (`DebugRun.ChatReport`), which carries the harness's own setting apart from the model
/// a request carries for it, and where Topo is: a slider that changed what it says and left the
/// harness alone is caught by the first, a choice that moved a debug build off its pin by the
/// second, and a Topo who did not come to the stop chosen by the third.
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

    /// The model's control opens the slider under the bar, at its leading edge; a stop pressed
    /// is the model chosen, said by the control and set on the harness, a debug build still asks
    /// its pin after every choice, and Topo comes to hang under that stop, under each in turn;
    /// shut, he leaves for where his placement has him. The mute and then the model stand apart
    /// at the bar's leading edge, and neither is on the composer's glass.
    func testTheSliderChoosesTheModelTheHarnessAsksAndTopoHangsUnderTheStopChosen() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "")
        let model = app.buttons["chat-model"], mute = app.buttons["chat-mute"], mic = ChatReading.microphone(app)
        XCTAssertTrue(model.waitForExistence(timeout: 60), "the bar has no model control")
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "the chat screen")
        for control in [model, mute] {
            XCTAssertLessThan(control.frame.maxY, mic.frame.minY, "\(control.identifier) is on the glass")
            XCTAssertLessThan(control.frame.midX, app.windows.firstMatch.frame.midX, "\(control.identifier) is not at the bar's leading edge")
        }
        XCTAssertLessThan(mute.frame.maxX, model.frame.minX, "the mute at \(mute.frame) and the model at \(model.frame) do not stand apart")
        for old in ["composer-model", "composer-mute", "composer-models"] {
            XCTAssertFalse(app.descendants(matching: .any)[old].exists, "\(old) is still on the glass")
        }
        XCTAssertFalse(app.buttons["chat-model-opus"].exists, "the slider is open before it is asked for")
        let (_, home) = try ChatReading.wait(app, "standing before the slider opens") { _, topo in topo.standing }
        model.tap()
        XCTAssertTrue(becomes(model, "label == 'Close the model slider'"), "the control does not say the slider is open")
        for (alias, name) in [("opus", "Opus"), ("fable", "Fable"), ("sonnet", "Sonnet")] {
            let stop = app.buttons["chat-model-\(alias)"]
            XCTAssertTrue(stop.waitForExistence(timeout: 10), "the slider has no stop for \(alias)")
            let bar = app.navigationBars.firstMatch.frame
            XCTAssertGreaterThanOrEqual(stop.frame.minY, bar.maxY - 0.5, "\(alias)'s stop at \(stop.frame) is in the bar at \(bar)")
            XCTAssertLessThan(stop.frame.minY, bar.maxY + bar.height, "\(alias)'s stop at \(stop.frame) is not under the bar at \(bar)")
            XCTAssertLessThan(stop.frame.maxY, mic.frame.minY, "\(alias)'s stop at \(stop.frame) is on the composer")
            stop.tap()
            XCTAssertTrue(becomes(model, "value == '\(name)'"), "\(alias) pressed, and the control says \(String(describing: model.value))")
            XCTAssertTrue(becomes(stop, "isSelected == true"), "\(alias) pressed, and its stop is not the one chosen")
            let deadline = Date().addingTimeInterval(10)
            while ChatReading.chat(app)?.model != alias, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            let chat = try XCTUnwrap(ChatReading.chat(app), "the chat reports nothing")
            XCTAssertEqual(chat.model, alias, "the slider says \(name) and the harness was set to \(chat.model ?? "nothing")")
            XCTAssertEqual(chat.effectiveModel, Self.pin, "choosing \(alias) moved a debug build off its pin")
            let (_, topo) = try ChatReading.wait(app, "hanging under \(alias)'s stop") { _, topo in
                guard topo.standing, let box = topo.box, let offset = ChatReading.offset(topo, mic: mic) else { return false }
                // Under the stop's middle, or held by the screen's edge with the stop still over him.
                let middle = box.midX + offset.dx
                return abs(middle - stop.frame.midX) < 2
                    || (abs(middle - stop.frame.midX) < box.width / 2 && box.minX + offset.dx < stop.frame.minX + 2)
            }
            let box = try XCTUnwrap(topo.box), visible = try XCTUnwrap(topo.visibleRect)
            let slider = app.descendants(matching: .any)["chat-models"].frame
            XCTAssertGreaterThanOrEqual(box.minY, visible.minY, "\(alias): he is over the bar")
            XCTAssertGreaterThanOrEqual(box.minY + offset(of: topo, mic).dy, slider.maxY, "\(alias): he is over the slider at \(slider)")
            XCTAssertLessThan(box.minY + offset(of: topo, mic).dy, slider.maxY + box.height, "\(alias): he is not hanging under the slider at \(slider)")
            ChatReading.attach(app, "slider-\(alias)", to: self)
        }
        model.tap()
        XCTAssertTrue(becomes(app.buttons["chat-model-opus"], "exists == false"), "the slider did not shut")
        XCTAssertTrue(becomes(model, "label == 'Choose the model'"), "the control still says the slider is open")
        let (_, away) = try ChatReading.wait(app, "back where he stood with the slider shut") { _, topo in
            topo.standing && ChatReading.near(topo.frame, home.frame)
        }
        XCTAssertEqual(away.placement, "roam", "the slider left him another placement")
        XCTAssertTrue(becomes(model, "value == 'Sonnet'"), "the model chosen did not outlive the slider")
    }

    /// The slider opens with the keyboard up and the row being typed in, the stop pressed is the
    /// model chosen, a finger drawn along the line chooses the stop it ends nearest, and what was
    /// written is still in the field after, with the keyboard up.
    func testTheSliderChoosesAModelOverTheKeyboard() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "", softwareKeyboard: true)
        let model = app.buttons["chat-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 60), "the bar has no model control")
        ChatReading.raiseKeyboard(app)
        let field = ChatReading.field(app)
        field.typeText("Hi")
        model.tap()
        let sonnet = app.buttons["chat-model-sonnet"], opus = app.buttons["chat-model-opus"], fable = app.buttons["chat-model-fable"]
        XCTAssertTrue(opus.waitForExistence(timeout: 10), "the slider did not open over the keyboard")
        opus.tap()
        XCTAssertTrue(becomes(model, "value == 'Opus'"), "a stop pressed over the keyboard chose nothing")
        XCTAssertEqual(ChatReading.chat(app)?.model, "opus")
        ChatReading.attach(app, "slider-over-keyboard", to: self)
        // The knob is at the top of the stop's column, on the line.
        let knob = { (stop: XCUIElement) in stop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)) }
        knob(opus).press(forDuration: 0.05, thenDragTo: knob(fable))
        XCTAssertTrue(becomes(model, "value == 'Fable'"), "a finger drawn to Fable chose \(String(describing: model.value))")
        XCTAssertEqual(field.value as? String, "Hi", "choosing a model took what was written")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "choosing a model took the keyboard away")
        sonnet.tap()
        XCTAssertTrue(becomes(model, "value == 'Sonnet'"))
        model.tap()
        XCTAssertTrue(becomes(opus, "exists == false"), "the slider did not shut")
    }

    /// What the look calls a model is what the bar calls it: the stop's name and the control's
    /// value, for the one the look renames and no other, and the debug pin is no stop.
    func testTheBarCallsAModelWhatTheLookCallsIt() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "", look: #"{"mind": {"opus": "Opus 5.5"}}"#)
        let model = app.buttons["chat-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 60), "the bar has no model control")
        model.tap()
        let opus = app.buttons["chat-model-opus"]
        XCTAssertTrue(opus.waitForExistence(timeout: 10), "the slider did not open")
        XCTAssertEqual(opus.label, "Opus 5.5")
        XCTAssertEqual(app.buttons["chat-model-sonnet"].label, "Sonnet")
        XCTAssertFalse(app.buttons["chat-model-haiku"].exists, "the slider offers the debug pin as a choice")
        opus.tap()
        XCTAssertTrue(becomes(model, "value == 'Opus 5.5'"), "the control says \(String(describing: model.value))")
        XCTAssertEqual(ChatReading.chat(app)?.model, "opus")
        app.buttons["chat-model-sonnet"].tap()
        XCTAssertTrue(becomes(model, "value == 'Sonnet'"))
    }

    /// A press on the microphone shuts the slider, and the press still reaches the microphone.
    func testAPressOnTheMicrophoneShutsTheSlider() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "")
        let mic = ChatReading.microphone(app), model = app.buttons["chat-model"]
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the chat screen, with its microphone")
        model.tap()
        let opus = app.buttons["chat-model-opus"]
        XCTAssertTrue(opus.waitForExistence(timeout: 10), "the slider did not open")
        let before = try XCTUnwrap(ChatReading.mic(mic), "the microphone reports nothing")
        mic.press(forDuration: 0.2)
        ChatReading.answerPrompt()
        XCTAssertTrue(becomes(opus, "exists == false"), "a press on the microphone left the slider open")
        XCTAssertEqual(ChatReading.mic(mic)?.presses, before.presses + 1, "the press did not reach the microphone")
        XCTAssertTrue(becomes(model, "label == 'Choose the model'"), "the control still says the slider is open")
    }

    /// At each end of what a document may ask of the bar — the largest font a document's size is
    /// drawn at with the widest and tallest slider and the largest of everything in it, and the
    /// smallest of each — the mute and the model are inside the navigation bar, in order, clear
    /// of each other and of the badge, and the open slider is under the bar and inside the
    /// screen's width, above the microphone, with every stop still chosen by a press. On the
    /// phone this suite runs on, which is wider than the narrowest.
    func testAtEachEndOfTheBarsRangesTheControlsStayInTheBarAndTheSliderUnderIt() throws {
        let largest = #"{"bar": {"font": {"size": 400}, "slider": {"width": 560, "height": 44, "padding": 24, "drop": 24, "inset": 80, "stop": 28, "knob": 28, "labelSpacing": 16, "labelFont": {"size": 400}}}}"#
        let smallest = #"{"bar": {"font": {"size": 4}, "slider": {"width": 96, "height": 24, "padding": 4, "drop": 0, "inset": 8, "stop": 2, "knob": 2, "labelSpacing": 0, "labelFont": {"size": 4}}}}"#
        for (what, look) in [("largest", largest), ("smallest", smallest)] {
            let app = ChatReading.launch(transcript: "empty", tuning: "", look: look)
            let model = app.buttons["chat-model"], mute = app.buttons["chat-mute"], badge = app.buttons["topo-debug-chat"]
            XCTAssertTrue(model.waitForExistence(timeout: 60), "\(what): the bar has no model control")
            XCTAssertTrue(mute.exists && badge.waitForExistence(timeout: 10), "\(what): the bar is without its mute or its badge")
            let bar = app.navigationBars.firstMatch.frame.insetBy(dx: -0.5, dy: -0.5)
            for (name, control) in [("model", model), ("mute", mute)] {
                XCTAssertTrue(bar.contains(control.frame), "\(what): the \(name) at \(control.frame) is out of the bar at \(bar)")
                XCTAssertGreaterThan(control.frame.width, 0, "\(what): the \(name) has no width")
            }
            XCTAssertLessThanOrEqual(mute.frame.maxX, model.frame.minX + 0.5, "\(what): the mute at \(mute.frame) is over the model at \(model.frame)")
            XCTAssertLessThanOrEqual(model.frame.maxX, badge.frame.minX + 0.5, "\(what): the model at \(model.frame) is over the badge at \(badge.frame)")
            model.tap()
            let slider = app.descendants(matching: .any)["chat-models"]
            XCTAssertTrue(slider.waitForExistence(timeout: 10), "\(what): the slider did not open")
            let screen = app.windows.firstMatch.frame, mic = ChatReading.microphone(app)
            XCTAssertGreaterThanOrEqual(slider.frame.minY, bar.maxY - 1, "\(what): the slider at \(slider.frame) is in the bar at \(bar)")
            XCTAssertLessThan(slider.frame.maxY, mic.frame.minY, "\(what): the slider at \(slider.frame) is on the composer")
            XCTAssertGreaterThanOrEqual(slider.frame.minX, screen.minX, "\(what): the slider at \(slider.frame) is off the screen")
            XCTAssertLessThanOrEqual(slider.frame.maxX, screen.maxX, "\(what): the slider at \(slider.frame) is off the screen")
            ChatReading.attach(app, "bar-\(what)", to: self)
            for (alias, name) in [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet")] {
                let stop = app.buttons["chat-model-\(alias)"]
                XCTAssertTrue(stop.exists, "\(what): no stop for \(alias)")
                stop.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                XCTAssertTrue(becomes(model, "value == '\(name)'"), "\(what): a press on \(alias)'s stop chose \(String(describing: model.value))")
            }
            app.terminate()
        }
    }

    /// Waits, bounded, for `element` to be as `predicate` says: what a tap changes is drawn by the
    /// app's next update, which a snapshot taken on the line after the tap can come before.
    /// From the report's space to the screen's.
    private func offset(of topo: ChatReading.Topo, _ mic: XCUIElement) -> CGVector {
        ChatReading.offset(topo, mic: mic) ?? .zero
    }

    private func becomes(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
