import XCTest

/// Every kind of block a reply carries, on the screen of a running app: the chat launched over
/// the `blocks` fixture (`PreviewTurns.blocks`), whose reply is two paragraphs, a link, a table
/// with an empty cell, an image by its path in the guest (`DebugRun.fixtureImages` writes the
/// file into the guest's home) and an image on the web. Whether this launch has a guest is the
/// simulator's: one that has fetched the guest's files boots it, and the image is read through
/// the guest and drawn; one that has not draws it as a device that cannot read it does, its
/// alternative text and why. Either is right and anything else is not, and which it was is
/// attached. The read itself is `GuestFileReadTests`, and the drawing `MarkdownRenderTests`.
@MainActor
final class ReplyBlocksTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAReplysBlocksAreAllOnTheScreen() throws {
        let app = ChatReading.launch(transcript: "blocks", tuning: "")
        let first = app.staticTexts["Let me look at the folder."]
        XCTAssertTrue(first.waitForExistence(timeout: 60), "the reply's first paragraph")
        ChatReading.attach(app, "blocks", to: self)

        for words in ["Three files, and the look document explains the fields:", "file", "size", "kept",
                      "look.json", "2 KB", "notes.md", "14 KB", "old-look.json", "no"] {
            XCTAssertTrue(app.staticTexts[words].exists, "\"\(words)\" is not on the screen")
        }
        // The image by its path: a picture where the guest read it, its words and why where
        // there is no guest to. Nothing is drawn until one or the other is known.
        let picture = app.images["A chart of the three sizes"]
        let words = app.staticTexts["A chart of the three sizes"]
        let deadline = Date().addingTimeInterval(30)
        while !picture.exists, !words.exists, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        XCTAssertNotEqual(picture.exists, words.exists, "the image by its path is neither a picture nor its words")
        XCTAssertEqual(app.staticTexts["Not on this device"].exists, words.exists)
        let which = XCTAttachment(string: picture.exists ? "read through the guest and drawn" : "no guest: drawn as its words")
        which.name = "the image by its path"
        which.lifetime = .keepAlways
        add(which)
        // The image on the web is its words and why, with its address.
        XCTAssertFalse(app.images["A chart from the web"].exists, "the web's image is drawn as a picture")
        XCTAssertTrue(app.staticTexts["A chart from the web"].exists)
        XCTAssertTrue(app.staticTexts["On the web, so not fetched"].exists)
        XCTAssertTrue(app.staticTexts["https://example.com/chart.png"].exists)
    }
}
