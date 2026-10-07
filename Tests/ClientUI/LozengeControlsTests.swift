import XCTest

/// The two controls on the glass beside the microphone, in the running chat: the mute, and the
/// model with the slider it opens. Read off the controls' own labels and values, and Topo off the
/// badge's debug report (`DebugRun.ChatReport`), whose frames are in the space he is drawn in; the
/// microphone the system finds says where that space is on the screen.
///
/// Both settings outlive a launch, so neither test assumes the state it starts in, and each leaves
/// replies read aloud and the first model chosen.
final class LozengeControlsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// The mute is one control with two states, and a press changes which it is.
    func testTheMuteOnTheGlassTurnsReadingAloudOffAndOnAgain() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "")
        let mute = app.buttons["composer-mute"]
        XCTAssertTrue(mute.waitForExistence(timeout: 60), "the glass has no mute")
        let labels = ["Mute replies", "Read replies aloud"]
        if mute.label == labels[1] { mute.tap() }
        XCTAssertTrue(becomes(mute, "label == 'Mute replies'"), "replies are not read aloud to begin with: \(mute.label)")
        mute.tap()
        XCTAssertTrue(becomes(mute, "label == 'Read replies aloud'"), "a press did not mute: \(mute.label)")
        ChatReading.attach(app, "muted", to: self)
        mute.tap()
        XCTAssertTrue(becomes(mute, "label == 'Mute replies'"), "a second press did not unmute: \(mute.label)")
    }

    /// The model's control opens the slider; a stop pressed is the model chosen, said by the
    /// control, and Topo comes to stand over that stop, over each in turn; shut, he leaves the
    /// glass for where a roaming Topo stands.
    func testTheSliderChoosesTheModelAndTopoStandsOverTheStopChosen() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "")
        let mic = ChatReading.microphone(app)
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "the chat screen")
        let model = app.buttons["composer-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 10), "the glass has no model control")
        let slider = app.descendants(matching: .any)["composer-models"]
        XCTAssertFalse(app.buttons["composer-model-opus"].exists, "the slider is open before it is asked for")
        model.tap()
        for (alias, name) in [("opus", "Opus"), ("fable", "Fable"), ("sonnet", "Sonnet")] {
            let stop = app.buttons["composer-model-\(alias)"]
            XCTAssertTrue(stop.waitForExistence(timeout: 10), "the slider has no stop for \(alias)")
            stop.tap()
            XCTAssertTrue(becomes(model, "value == '\(name)'"), "\(alias) pressed, and the control says \(String(describing: model.value))")
            let (_, topo) = try ChatReading.wait(app, "standing over \(alias)'s stop") { _, topo in
                guard topo.standing, let box = topo.box, let offset = ChatReading.offset(topo, mic: mic) else { return false }
                return abs(box.midX + offset.dx - stop.frame.midX) < 2
            }
            let box = try XCTUnwrap(topo.box), offset = try XCTUnwrap(ChatReading.offset(topo, mic: mic))
            XCTAssertLessThanOrEqual(box.maxY + offset.dy, stop.frame.maxY + 1, "\(alias): he stands below the stop he is over")
            ChatReading.attach(app, "slider-\(alias)", to: self)
        }
        let sat = try XCTUnwrap(ChatReading.chat(app)?.mascot?.frame, "he is nowhere over the slider")
        model.tap()
        XCTAssertTrue(becomes(slider, "exists == false"), "the slider did not shut")
        // Where he sat hangs below the transcript's foot, so standing inside it he has left.
        let (_, away) = try ChatReading.wait(app, "inside the transcript with the slider shut") { _, topo in
            guard topo.standing, let box = topo.box, let visible = topo.visibleRect else { return false }
            return box.maxY <= visible.maxY + 1 && !ChatReading.near(topo.frame, sat)
        }
        XCTAssertEqual(away.placement, "roam", "the slider left him another placement")
        XCTAssertTrue(becomes(model, "value == 'Sonnet'"), "the model chosen did not outlive the slider")
    }

    /// The slider opens over the keyboard and leaves it up: the row is still being typed in, the
    /// stops are there to press, the one pressed is the model chosen, and shutting the slider
    /// leaves the keyboard where it was.
    func testTheSliderOpensOverTheKeyboardAndLeavesItUp() throws {
        let app = ChatReading.launch(transcript: "empty", tuning: "", softwareKeyboard: true)
        let model = app.buttons["composer-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 60), "the glass has no model control")
        app.buttons["Type instead"].tap()
        let lower = app.buttons["Hide the keyboard"]
        XCTAssertTrue(lower.waitForExistence(timeout: 10), "the keyboard did not come up")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10), "no keyboard on screen")
        model.tap()
        let stop = app.buttons["composer-model-opus"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the slider did not open over the keyboard")
        XCTAssertTrue(app.keyboards.firstMatch.exists && lower.exists, "opening the slider took the keyboard away")
        stop.tap()
        XCTAssertTrue(becomes(model, "value == 'Opus'"), "a stop pressed over the keyboard chose nothing")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "choosing a model took the keyboard away")
        ChatReading.attach(app, "slider-over-keyboard", to: self)
        app.buttons["composer-model-sonnet"].tap()
        XCTAssertTrue(becomes(model, "value == 'Sonnet'"))
        model.tap()
        XCTAssertTrue(becomes(stop, "exists == false"), "the slider did not shut")
        XCTAssertTrue(app.keyboards.firstMatch.exists && lower.exists, "shutting the slider took the keyboard away")
    }

    /// Waits, bounded, for `element` to be as `predicate` says: what a tap changes is drawn by the
    /// app's next update, which a snapshot taken on the line after the tap can come before.
    private func becomes(_ element: XCUIElement, _ predicate: String, timeout: TimeInterval = 10) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
