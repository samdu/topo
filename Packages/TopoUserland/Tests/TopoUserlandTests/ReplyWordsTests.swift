import XCTest
@testable import TopoUserland

/// A reply's words gathered over the messages of a turn (`ReplyWords`): the one function the row,
/// the log and the crash recovery build a reply from.
final class ReplyWordsTests: XCTestCase {
    func testMessagesAreJoinedByOneBlankLineAndAMessageWithNoWordsAddsNothing() {
        var words = ReplyWords()
        XCTAssertEqual(words.text, "")
        words.begin()
        XCTAssertEqual(words.text, "")
        words.append("Let me ")
        words.append("look.")
        XCTAssertEqual(words.text, "Let me look.")
        words.begin()
        XCTAssertEqual(words.text, "Let me look.", "a message begun is no break until it says something")
        words.begin()
        words.append("\n")
        XCTAssertEqual(words.text, "Let me look.", "a message of whitespace is no words")
        words.begin()
        words.append("It is ")
        XCTAssertEqual(words.text, "Let me look.\n\nIt is ")
        words.append("here.")
        XCTAssertEqual(words.text, "Let me look.\n\nIt is here.")
    }

    func testWordsAppendedWithNoMessageBegunAreOneMessage() {
        var words = ReplyWords()
        words.append("Paris")
        words.append(".")
        XCTAssertEqual(words.text, "Paris.")
    }

    /// By id: a block of the message last written to runs on from it, and a block of another
    /// message is a new paragraph. Blocks with no id are one message.
    func testBlocksAreGroupedByTheirMessage() {
        var words = ReplyWords()
        words.append("One, ", of: "m1")
        words.append("two.", of: "m1")
        words.append("Three.", of: "m2")
        XCTAssertEqual(words.text, "One, two.\n\nThree.")
        var unnamed = ReplyWords()
        unnamed.append("One, ", of: nil)
        unnamed.append("two.", of: nil)
        unnamed.append("Three.", of: "m2")
        unnamed.append("Four.", of: nil)
        XCTAssertEqual(unnamed.text, "One, two.\n\nThree.\n\nFour.")
    }

    /// The same messages a delta at a time, with a message begun at each start, and a block at a
    /// time by id, come to the same bytes: the row's way and the log's.
    func testDeltasAndWholeBlocksComeToTheSameReply() {
        let messages: [(id: String, blocks: [String])] = [
            ("m1", ["Let me look. "]), ("m2", []), ("m3", ["  "]), ("m4", ["It is ", "on the shelf.\n"]), ("m5", ["Done."]),
        ]
        var deltas = ReplyWords(), blocks = ReplyWords()
        var seen: [String] = []
        for message in messages {
            deltas.begin()
            for block in message.blocks {
                for character in block {
                    deltas.append(String(character))
                    XCTAssertTrue(deltas.text.hasPrefix(seen.last ?? ""),
                                  "\(deltas.text.debugDescription) after \((seen.last ?? "").debugDescription)")
                    seen.append(deltas.text)
                }
                blocks.append(block, of: message.id)
            }
        }
        XCTAssertEqual(deltas.text, blocks.text)
        XCTAssertEqual(blocks.text, "Let me look. \n\nIt is on the shelf.\n\n\nDone.")
    }
}
