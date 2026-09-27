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
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the flank put no row at the end of the transcript")
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
        let inFlight = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'What to say'")).firstMatch
        XCTAssertTrue(inFlight.waitForExistence(timeout: 10), "the row left the transcript when the turn went")
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

    /// Each text drawn whole: as many lines tall as its words take at its width in `font`. The
    /// accessibility label is the whole string whatever the bar drew, so what is measured is the
    /// drawing — a notice cut short by the line limit is drawn fewer lines tall than its words need.
    private func whole(_ texts: [XCUIElement], in font: UIFont, _ fixture: String) {
        for text in texts {
            let needed = (text.label as NSString).boundingRect(
                with: CGSize(width: text.frame.width + 1, height: .greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil)
            let lines = (needed.height / font.lineHeight).rounded(), drawn = (text.frame.height / font.lineHeight).rounded()
            XCTAssertLessThanOrEqual(lines, drawn,
                                     "\(fixture): \"\(text.label)\" takes \(lines) lines at \(text.frame.width) pt wide and was drawn \(drawn) lines tall (\(text.frame)), cut short")
        }
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
        ("busy", ["Reaching iCloud…", "· 2 waiting"]),
        ("error", ["iCloud refused the read. Check you're signed in on this device."]),
        ("info", ["Saved. Another device will answer here."]),
        // A turn left for another primary while the next is on its way: the bar holds one notice,
        // and the turn in flight is it.
        ("busy-info", ["Reaching iCloud…", "· 1 waiting"]),
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

    /// Every line of words level with the badge, wholly to its leading side, and above the
    /// transcript's frame as the chat reports it.
    private func holdInTheBar(_ app: XCUIApplication, _ texts: [XCUIElement], _ fixture: String) throws {
        let badge = app.buttons["topo-debug-chat"]
        XCTAssertTrue(badge.waitForExistence(timeout: 10), "\(fixture): no badge in the navigation bar")
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
