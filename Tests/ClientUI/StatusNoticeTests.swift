import UIKit
import XCTest

/// Where the chat's notices are drawn: in the navigation bar beside the badge, and not over the
/// composer. Only a running app lays out a toolbar, so this is a UI test.
///
/// The turn never settles: the app is launched with `TOPO_DEBUG_REPLY_DELAY`, which holds the
/// harness before the model call, so a notice stands for the length of the test on any host —
/// the status of the turn in flight on one with an iCloud account behind the simulator, the
/// failure on one without. Either is a notice, and both are held to the same place. The three
/// things a notice says are each held on their own off `TOPO_DEBUG_NOTICES`, which puts them in
/// the bar whatever the host's iCloud does.
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
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the mark put no field in the glass")
        field.typeText("What's the weather like?")
        app.buttons["Send"].tap()

        let notices = app.descendants(matching: .any).matching(identifier: "topo-notices").firstMatch
        let found = notices.waitForExistence(timeout: 30)
        if !found {
            attach(app)
            let tree = XCTAttachment(string: app.debugDescription + "\n\nREPORT " + String(describing: app.buttons["topo-debug-chat"].value))
            tree.name = "tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(found, "a turn went and no notice said so")
        let words = notices.staticTexts.firstMatch
        XCTAssertTrue(words.waitForExistence(timeout: 10), "the notices hold no words")
        XCTAssertTrue(Self.heldTurn.contains(words.label),
                      "the notice says \"\(words.label)\", none of what a held turn says: \(Self.heldTurn)")

        let badge = app.buttons["topo-debug-chat"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "no badge in the navigation bar")
        attach(app)
        XCTAssertLessThanOrEqual(abs(words.frame.midY - badge.frame.midY), badge.frame.height / 2,
                                 "the notice \"\(words.label)\" at \(words.frame) is not in the bar beside the badge at \(badge.frame)")
        let inFlight = app.descendants(matching: .any)["draft-row"]
        XCTAssertTrue(inFlight.waitForExistence(timeout: 10), "the turn on its way is not drawn at the end of the transcript")
        XCTAssertLessThanOrEqual(words.frame.maxY, inFlight.frame.minY,
                                 "the notice at \(words.frame) is under the row at \(inFlight.frame)")
    }

    /// Each of the three things the notices say, in the harness's words, in the bar: level with
    /// the badge, clear of it to its leading side, and above the transcript's frame, where Topo's
    /// room starts, drawn whole. The failure is wrapped onto a second line rather than cut short.
    /// With two to say at once the bar says one, the more pressing.
    func testEachNoticeSaysItsWordsInTheBarBesideTheBadge() throws {
        for (fixture, said) in Self.fixtures {
            let app = launch(fixture)
            let texts = try words(app, fixture)
            XCTAssertEqual(texts.map(\.label), said, "\(fixture): the notice's words")
            try holdInTheBar(app, texts, fixture)
            whole(texts, in: UIFont.preferredFont(forTextStyle: .caption1), fixture)
            if fixture == "error" {
                let line = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
                XCTAssertGreaterThan(texts[0].frame.height, line * 1.5,
                                     "the failure at \(texts[0].frame) is one line, cut short rather than wrapped")
            }
            app.terminate()
        }
    }

    /// A look whose notice font is absurdly large still leaves every notice in the bar, beside the
    /// badge and above the transcript, at no more than two lines of the largest the bar holds.
    func testAnAbsurdNoticeFontStaysInTheBar() throws {
        let look = #"{"transcript": {"noticeFont": {"size": 400}}}"#
        let tallest = 2 * UIFont.systemFont(ofSize: 15).lineHeight + 1
        for (fixture, said) in Self.fixtures {
            let app = launch(fixture, look: look)
            let texts = try words(app, fixture)
            XCTAssertEqual(texts.map(\.label), said, "\(fixture): the notice's words")
            for text in texts {
                XCTAssertLessThanOrEqual(text.frame.height, tallest,
                                         "\(fixture): \"\(text.label)\" at \(text.frame) is more than two lines of the bar's largest")
            }
            try holdInTheBar(app, texts, fixture)
            whole(texts, in: UIFont.systemFont(ofSize: 15), fixture)
            app.terminate()
        }
    }

    // MARK: -

    /// The least a notice is drawn at, as a share of its font (`look.transcript.noticeLeastScale`):
    /// between the bar's controls and the badge a notice that does not fit its two lines is
    /// drawn smaller before any of it is cut.
    private static let leastScale: CGFloat = 0.65

    /// Each text drawn at a size its words fit at. The accessibility label is the whole string
    /// whatever the bar drew, so what is measured is the drawing's frame, and not that no word
    /// is cut: that follows from the text being scaled before it is truncated, which is the
    /// system's, and is not read off the pixels here. Words that fit the bar's two lines in `font` at the
    /// text's width are drawn as many lines tall as they take. Words that do not are drawn
    /// smaller, so shorter than two lines of `font` — a notice cut short by the line limit is
    /// exactly two tall — and they fit the two lines at the least the bar draws them.
    private func whole(_ texts: [XCUIElement], in font: UIFont, _ fixture: String) {
        for text in texts {
            let said = "\(fixture): \"\(text.label)\" at \(text.frame)"
            let lines = Self.lines(text.label, in: font, wide: text.frame.width)
            guard lines > 2 else {
                let drawn = (text.frame.height / font.lineHeight).rounded()
                XCTAssertLessThanOrEqual(lines, drawn, "\(said) takes \(lines) lines and was drawn \(drawn) tall, cut short")
                continue
            }
            XCTAssertLessThan(text.frame.height, 2 * font.lineHeight - 1,
                              "\(said) takes \(lines) lines at its font and is two of them tall: cut short and not drawn smaller")
            let least = Self.lines(text.label, in: font.withSize(font.pointSize * Self.leastScale), wide: text.frame.width)
            XCTAssertLessThanOrEqual(least, 2, "\(said) does not fit two lines at the least the bar draws it")
        }
    }

    private static func lines(_ words: String, in font: UIFont, wide: CGFloat) -> CGFloat {
        let needed = (words as NSString).boundingRect(
            with: CGSize(width: wide + 1, height: .greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil)
        return (needed.height / font.lineHeight).rounded()
    }

    /// What a turn held before the model call can say: where it is, or iCloud's refusal on a
    /// simulator whose iCloud read is refused.
    private static let heldTurn: Set<String> = [
        "Reaching iCloud…",
        "iCloud refused the read. Check you're signed in on this device.",
        "iCloud is out of reach. Topo will try again.",
    ]

    /// `TOPO_DEBUG_NOTICES`'s fixtures and the words each has to show, in order.
    private static let fixtures: [(String, [String])] = [
        ("busy", ["Reaching iCloud… · 2 waiting"]),
        // The longest status the harness sets, beside the spinner and a two-digit count.
        ("busy-long", ["Checking this device is primary… · 11 waiting"]),
        ("error", ["iCloud refused the read. Check you're signed in on this device."]),
        ("info", ["Saved. Another device will answer here."]),
        // A turn left for another primary while the next is on its way: the bar holds one notice,
        // and the turn in flight is it.
        ("busy-info", ["Reaching iCloud… · 1 waiting"]),
        // A failure while a turn is on its way is the one notice.
        ("error-busy", ["iCloud refused the read. Check you're signed in on this device."]),
    ]

    private func launch(_ fixture: String, look: String = "{}") -> XCUIApplication {
        ChatReading.launch(transcript: "full", tuning: "", look: look,
                           environment: ["TOPO_DEBUG_NOTICES": fixture])
    }

    private func words(_ app: XCUIApplication, _ fixture: String) throws -> [XCUIElement] {
        let notices = app.descendants(matching: .any).matching(identifier: "topo-notices").firstMatch
        XCTAssertTrue(notices.waitForExistence(timeout: 60), "\(fixture): no notice in the bar")
        XCTAssertTrue(notices.staticTexts.firstMatch.waitForExistence(timeout: 10), "\(fixture): the notices hold no words")
        attach(app, fixture)
        return notices.staticTexts.allElementsBoundByIndex
    }

    /// Every line of words level with the badge, wholly to its leading side and to the trailing
    /// side of the model and the mute, which are in the bar with it, and above the transcript's
    /// frame as the chat reports it.
    private func holdInTheBar(_ app: XCUIApplication, _ texts: [XCUIElement], _ fixture: String) throws {
        let badge = app.buttons["topo-debug-chat"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "\(fixture): no badge in the navigation bar")
        let model = app.buttons["chat-model"], mute = app.buttons["chat-mute"]
        XCTAssertTrue(model.exists && mute.exists, "\(fixture): the bar is without its model or its mute")
        XCTAssertLessThanOrEqual(model.frame.maxX, mute.frame.minX + 0.5, "\(fixture): the model at \(model.frame) is over the mute at \(mute.frame)")
        let mic = ChatReading.microphone(app)
        XCTAssertTrue(mic.waitForExistence(timeout: 60), "\(fixture): the chat screen")
        let (_, topo) = try ChatReading.wait(app, "reporting the transcript's frame") { _, topo in
            topo.visibleRect != nil && topo.wellRect != nil
        }
        let offset = try XCTUnwrap(ChatReading.offset(topo, mic: mic), "\(fixture): no well in the report")
        let transcript = try XCTUnwrap(topo.visibleRect).offsetBy(dx: offset.dx, dy: offset.dy)
        for text in texts {
            let frame = text.frame
            XCTAssertLessThanOrEqual(abs(frame.midY - badge.frame.midY), badge.frame.height / 2,
                                     "\(fixture): \"\(text.label)\" at \(frame) is not level with the badge at \(badge.frame)")
            XCTAssertLessThanOrEqual(frame.maxX, badge.frame.minX,
                                     "\(fixture): \"\(text.label)\" at \(frame) runs into the badge at \(badge.frame)")
            XCTAssertGreaterThanOrEqual(frame.minX, mute.frame.maxX,
                                        "\(fixture): \"\(text.label)\" at \(frame) runs under the mute at \(mute.frame)")
            XCTAssertLessThanOrEqual(frame.maxY, transcript.minY + 0.5,
                                     "\(fixture): \"\(text.label)\" at \(frame) reaches down over the transcript at \(transcript)")
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String = "notices") {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
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
