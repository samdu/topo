import Foundation
import XCTest

@testable import Topo

/// Topo's words cut into blocks (`Markdown.blocks`): which blocks a source makes, what each
/// carries, and that no word of a reply is lost on the way — a reply with no markup is one
/// paragraph of itself, character for character.
final class MarkdownTests: XCTestCase {
    private func summary(_ source: String) -> [String] {
        Markdown.blocks(source).map { "\($0.kind) \($0.depth) \(String($0.text.characters))" }
    }

    func testEachBlockKindIsParsed() {
        let source = """
        # One
        ## Two
        ### Three
        #### Four

        A paragraph.

        - a bullet
        1. a number

        > a quote

        ```swift
        let x = 1
        ```

        ---
        """
        XCTAssertEqual(summary(source), [
            "heading(level: 1) 0 One",
            "heading(level: 2) 0 Two",
            "heading(level: 3) 0 Three",
            "heading(level: 4) 0 Four",
            "paragraph 0 A paragraph.",
            "item(Topo.Markdown.Marker.bullet) 1 a bullet",
            "item(Topo.Markdown.Marker.number(1)) 1 a number",
            "quote 0 a quote",
            "code(language: Optional(\"swift\")) 0 let x = 1",
            "rule 0 ",
        ])
    }

    func testListsNestAndNumber() {
        let source = """
        - first
        - second

          more of the second
          1. one
          2. two
        - third
        """
        XCTAssertEqual(summary(source), [
            "item(Topo.Markdown.Marker.bullet) 1 first",
            "item(Topo.Markdown.Marker.bullet) 1 second",
            "paragraph 1 more of the second",
            "item(Topo.Markdown.Marker.number(1)) 2 one",
            "item(Topo.Markdown.Marker.number(2)) 2 two",
            "item(Topo.Markdown.Marker.bullet) 1 third",
        ])
    }

    /// A fence or a quote inside a list item keeps the item's depth, so it is drawn under the
    /// item's words and not at the margin.
    func testEveryBlockCarriesItsListDepth() {
        let source = """
        - an item

          ```
          code in the item
          ```

          > a quote in the item
        """
        XCTAssertEqual(summary(source), [
            "item(Topo.Markdown.Marker.bullet) 1 an item",
            "code(language: nil) 1 code in the item",
            "quote 1 a quote in the item",
        ])
    }

    func testCodeKeepsItsIndentationAndLosesOnlyItsLastNewline() {
        let blocks = Markdown.blocks("```\nfunc f() {\n    return 1\n}\n```")
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.kind, .code(language: nil))
        XCTAssertEqual(blocks.first.map { String($0.text.characters) }, "func f() {\n    return 1\n}")
    }

    /// The inline styles survive the cut as intents, which is what `Text` draws them from.
    func testInlineStylesAreCarried() throws {
        let block = try XCTUnwrap(Markdown.blocks("plain `code` *em* **strong** ~~gone~~").first)
        var found: [String: InlinePresentationIntent] = [:]
        for (intent, range) in block.text.runs[\.inlinePresentationIntent] {
            if let intent { found[String(block.text[range].characters)] = intent }
        }
        XCTAssertEqual(found["code"], .code)
        XCTAssertEqual(found["em"], .emphasized)
        XCTAssertEqual(found["strong"], .stronglyEmphasized)
        XCTAssertEqual(found["gone"], .strikethrough)
        XCTAssertEqual(String(block.text.characters), "plain code em strong gone")
    }

    /// Replies have always broken their lines where they were written; CommonMark would fold a
    /// single newline into a space, and a hard break into one too.
    func testASingleNewlineStaysALineBreak() {
        XCTAssertEqual(summary("one\ntwo"), ["paragraph 0 one\ntwo"])
        XCTAssertEqual(summary("one  \ntwo"), ["paragraph 0 one\ntwo"])
        XCTAssertEqual(summary("one\\\ntwo"), ["paragraph 0 one\ntwo"])
    }

    /// A reply with no markup is one paragraph whose words are the reply's, as the transcript
    /// drew it before there was any markdown; blank lines between paragraphs make paragraphs.
    func testPlainTextIsOneParagraphOfItself() {
        for text in ["Paris.",
                     "Two things: the dentist at 11, and Krista wanted to talk about the garden.",
                     "For the weekend, in order:\nthe dentist, Friday at 11\nDaphne's food on the way"] {
            XCTAssertEqual(summary(text), ["paragraph 0 \(text)"], text)
        }
        XCTAssertEqual(summary("Say the word.\n\nOr don't :)"), ["paragraph 0 Say the word.", "paragraph 0 Or don't :)"])
    }

    /// What sources that look like markup and are not, markup left open, and markup a reply
    /// might not mean, draw as: each pinned as the words that come out, since which characters
    /// count as markup is the parser's to say and a check that asked it would ask nothing.
    /// CommonMark's own readings stand — an asterisk between two digits is emphasis, and a
    /// double underscore round a word is strong — because a reply fences what it means as code.
    func testWhatAwkwardSourcesDrawAs() {
        let cases: [(String, [String])] = [
            ("2 * 3 * 4 and snake_case_name", ["paragraph 0 2 * 3 * 4 and snake_case_name"]),
            ("a < b and <div>html</div>", ["paragraph 0 a < b and <div>html</div>"]),
            ("```\nunclosed fence\nstill code", ["code(language: nil) 0 unclosed fence\nstill code"]),
            ("|||\nline", ["paragraph 0 |||\nline"]),
            ("C# and F# and #hashtag", ["paragraph 0 C# and F# and #hashtag"]),
            ("price: $5 * 2 = $10", ["paragraph 0 price: $5 * 2 = $10"]),
            ("an [unclosed link and a ] bracket", ["paragraph 0 an [unclosed link and a ] bracket"]),
            ("1) the first", ["item(Topo.Markdown.Marker.number(1)) 1 the first"]),
            ("| a | b |\n|---|---|\n| 1 | 2 |", ["paragraph 0 a  ·  b", "paragraph 0 1  ·  2"]),
            ("5*3*2", ["paragraph 0 532"]),
            ("__init__.py", ["paragraph 0 init.py"]),
            // A block of HTML has no block intent at all, and is a paragraph of its words.
            ("<div>\nhello\n</div>", ["paragraph 0 <div>\nhello\n</div>"]),
        ]
        for (source, blocks) in cases {
            XCTAssertEqual(summary(source), blocks, source)
        }
    }

    /// A link is drawn as its words and goes nowhere: nothing a reply says is a tap target.
    func testALinkIsItsWordsAndNothingElse() throws {
        let blocks = Markdown.blocks("see [the docs](https://example.com) or <https://example.org>")
        XCTAssertEqual(blocks.map { String($0.text.characters) }, ["see the docs or https://example.org"])
        for block in blocks {
            XCTAssertTrue(block.text.runs.allSatisfy { $0.link == nil }, "a link survived: \(block.text)")
        }
    }

    /// The cache hands back what the parse makes.
    func testTheCacheIsTheParse() {
        let source = "# Head\n\n- one\n- two"
        XCTAssertEqual(Markdown.cached(source), Markdown.blocks(source))
        XCTAssertEqual(Markdown.cached(source), Markdown.blocks(source))
    }

    /// A parse that throws is the reply as one plain paragraph, never an empty turn.
    func testAParseThatFailsIsThePlainText() {
        struct Refused: Error {}
        let blocks = Markdown.blocks("# not *drawn* as markup") { _ in throw Refused() }
        XCTAssertEqual(blocks, [Markdown.Block(kind: .paragraph, depth: 0,
                                               text: AttributedString("# not *drawn* as markup"))])
    }

    func testAnEmptyReplyIsNoBlocks() {
        XCTAssertEqual(Markdown.blocks(""), [])
        XCTAssertEqual(Markdown.blocks("  \n"), [])
    }

    /// A reply with words in it that the parse finds nothing to draw in is drawn as it was
    /// written rather than as an empty turn.
    func testASourceThatParsesToNothingIsItsPlainText() {
        for source in ["#", "-", "```", "[x]: http://y"] {
            XCTAssertEqual(summary(source), ["paragraph 0 \(source)"], source)
        }
    }
}
