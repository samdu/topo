import XCTest

@testable import Topo

/// What of a message still being written is read (`Speaker.settled`), and that reading it a
/// piece at a time comes to the sentences the whole of it is read as.
@MainActor
final class SettledSpeechTests: XCTestCase {
    func testNothingIsSettledBeforeASentenceEnds() {
        XCTAssertEqual(Speaker.settled(""), "")
        XCTAssertEqual(Speaker.settled("Twelve"), "")
        XCTAssertEqual(Speaker.settled("Twelve."), "")
    }

    func testASentenceIsSettledOnceWhitespaceOrALineBreakFollowsIt() {
        XCTAssertEqual(Speaker.settled("Twelve. And"), "Twelve. ")
        XCTAssertEqual(Speaker.settled("Is it? Yes! May"), "Is it? Yes! ")
        XCTAssertEqual(Speaker.settled("A heading\nand more"), "A heading\n")
        // A decimal point is not a sentence's end.
        XCTAssertEqual(Speaker.settled("It is 3.5 metres"), "")
    }

    func testACodeBlockIsNotSettledUntilItsFenceCloses() {
        XCTAssertEqual(Speaker.settled("Run this.\n```sh\nls -l\n"), "Run this.\n")
        XCTAssertEqual(Speaker.settled("Run this.\n```sh\nls -l\n```\nThen"), "Run this.\n```sh\nls -l\n```\n")
    }

    func testReadingAPieceAtATimeComesToTheSentencesOfTheWhole() {
        let reply = """
        A starter is flour and water. Wild yeast lives in it!

        - Feed it daily.
        - Keep it warm, about 24.5 degrees.

        ```sh
        echo feed. now
        ```

        See `look.json` for more? Yes.
        """
        var queued: [String] = []
        var written = ""
        for character in reply {
            written.append(character)
            let sentences = Speaker.spoken(Speaker.settled(written)).map(\.text)
            XCTAssertEqual(Array(sentences.prefix(queued.count)), queued, "after \(written.debugDescription)")
            queued = sentences
        }
        let whole = Speaker.spoken(reply).map(\.text)
        XCTAssertEqual(Array(whole.prefix(queued.count)), queued)
        XCTAssertEqual(whole.count - queued.count, 1, "only the last sentence waits for the reply to land")
    }
}
