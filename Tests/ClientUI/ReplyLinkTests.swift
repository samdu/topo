import XCTest

/// A reply's link is the one part of its words that is a tap target, and the target is the linked
/// words alone: a tap on them asks for the link's address to be opened, once, and a tap on the
/// words round them asks for nothing. Only a running app routes a touch to a run of a text, so
/// this is a UI test.
///
/// The chat is launched over the `links` fixture (`PreviewTurns.links`), where the taps a link
/// takes are recorded on the chat's report and nothing is opened (`DebugRun.ChatReport.opened`).
@MainActor
final class ReplyLinkTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private static let docs = "https://example.com/docs"
    private static let wrapped = "https://example.com/wrapped"
    private static let wrappedWords = "the linked words of this reply run on for long enough that they wrap onto another line"

    /// "see the docs", where only "docs" is linked: a tap on "docs" opens the link once, and a
    /// tap on "see the" opens nothing.
    func testATapOnTheLinkedWordOpensItAndATapBesideItDoesNot() throws {
        let app = ChatReading.launch(transcript: "links", tuning: "")
        let words = try reply(app, "see the docs")
        XCTAssertEqual(try opened(app, count: 0), [])

        // The reply is one line as wide as its words, and "docs" is the last of them.
        words.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5)).tap()
        XCTAssertEqual(try opened(app, count: 1), [Self.docs], "a tap on the linked word")

        words.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        words.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)).tap()
        XCTAssertEqual(try settled(app), [Self.docs], "a tap on the words before the link opened something")
    }

    /// A link whose words wrap onto a second line is a tap target on both lines, and the words
    /// before it on its first line are not.
    func testALinkThatWrapsIsATapTargetOnEachOfItsLines() throws {
        let app = ChatReading.launch(transcript: "links", tuning: "")
        let line = try reply(app, "see the docs").frame.height
        let words = try reply(app, "Before it " + Self.wrappedWords)
        XCTAssertGreaterThan(words.frame.height, line * 1.5, "the link's reply is on one line, so nothing wrapped")
        let origin = words.coordinate(withNormalizedOffset: .zero)

        // The last line holds only linked words, from the column's leading edge.
        origin.withOffset(CGVector(dx: 12, dy: words.frame.height - line / 2)).tap()
        XCTAssertEqual(try opened(app, count: 1), [Self.wrapped], "a tap on the link's second line")

        // The first line is "Before it" and then linked words to its end.
        origin.withOffset(CGVector(dx: words.frame.width * 0.6, dy: line / 2)).tap()
        XCTAssertEqual(try opened(app, count: 2), [Self.wrapped, Self.wrapped], "a tap on the link's first line")

        origin.withOffset(CGVector(dx: 12, dy: line / 2)).tap()
        XCTAssertEqual(try settled(app), [Self.wrapped, Self.wrapped], "a tap on the words before the link opened something")
    }

    /// The reply whose words are `label`, once it is on the screen.
    private func reply(_ app: XCUIApplication, _ label: String) throws -> XCUIElement {
        let words = app.staticTexts.matching(NSPredicate(format: "label == %@", label)).firstMatch
        if !words.waitForExistence(timeout: 60) {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "tree"
            tree.lifetime = .keepAlways
            add(tree)
            XCTFail("no reply reading \"\(label)\"")
            throw ChatReading.NotThere(description: label)
        }
        return words
    }

    /// What the chat was asked to open, once it has been asked `count` times.
    private func opened(_ app: XCUIApplication, count: Int) throws -> [String] {
        let deadline = Date().addingTimeInterval(10)
        var seen: [String]?
        repeat {
            seen = ChatReading.chat(app)?.opened
            if seen?.count == count { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return try XCTUnwrap(seen, "the chat reports no opened links")
    }

    /// What the chat was asked to open after long enough for a tap that opened something to
    /// have said so.
    private func settled(_ app: XCUIApplication) throws -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        return try XCTUnwrap(ChatReading.chat(app)?.opened, "the chat reports no opened links")
    }
}
