import XCTest

/// Every kind of block a reply carries, on the screen of a running app: the chat launched over
/// the `blocks` fixture (`PreviewTurns.blocks`), whose reply is two paragraphs, a link, a table
/// with an empty cell, an image under the guest's home (written there by `DebugRun.fixtureImages`
/// and read through the app's own reader, `ReplyImages`) and an image on the web.
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
        // The image under the home is a picture, and the one on the web is its words and why.
        XCTAssertTrue(app.images["A chart of the three sizes"].exists, "the home's image is not drawn as a picture")
        XCTAssertFalse(app.images["A chart from the web"].exists, "the web's image is drawn as a picture")
        XCTAssertTrue(app.staticTexts["A chart from the web"].exists)
        XCTAssertTrue(app.staticTexts["On the web, so not fetched"].exists)
        XCTAssertTrue(app.staticTexts["https://example.com/chart.png"].exists)
        XCTAssertFalse(app.staticTexts["Not on this device"].exists)
    }
}
