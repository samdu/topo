import XCTest

/// Every kind of block a reply carries, on the screen of a running app: the chat launched over
/// the `blocks` fixture (`PreviewTurns.blocks`), whose reply is two paragraphs, a link, a table
/// with an empty cell, an image by its path in the guest (`DebugRun.fixtureImages` writes the
/// file into the guest's home) and an image on the web. Whether this launch has a guest is the
/// simulator's — one that has fetched the guest's files boots it — and the chat's report says
/// which (`guestHome`): with a guest the image must be read through it and drawn as a picture,
/// and only with none is it its alternative text and why, as on a device that cannot read it.
/// Which it was is attached. The read itself is `GuestFileReadTests`, the drawing
/// `MarkdownRenderTests`.
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
        // The image by its path. A guest that is coming comes within the wait; one that has
        // its home must draw the picture, and with none the image is its words and why.
        let picture = app.images["A chart of the three sizes"]
        let words = app.staticTexts["A chart of the three sizes"]
        let deadline = Date().addingTimeInterval(45)
        while ChatReading.chat(app)?.guestHome != true, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        let guest = try XCTUnwrap(ChatReading.chat(app)?.guestHome, "the chat does not say whether it has a guest")
        if guest {
            XCTAssertTrue(picture.waitForExistence(timeout: 30), "the guest has its home and the image is not drawn as a picture")
            XCTAssertFalse(app.staticTexts["Not on this device"].exists)
        } else {
            XCTAssertTrue(words.waitForExistence(timeout: 10), "no guest, and the image is not its words")
            XCTAssertTrue(app.staticTexts["Not on this device"].exists)
            XCTAssertFalse(picture.exists)
        }
        let which = XCTAttachment(string: guest ? "read through the guest and drawn" : "no guest: drawn as its words")
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
