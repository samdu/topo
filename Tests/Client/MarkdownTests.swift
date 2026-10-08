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
            "paragraph 0 a quote",
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
            "paragraph 1 a quote in the item",
        ])
    }

    /// How many quotes a block sits inside, and how many of its lists sit outside the outermost
    /// of them — the two counts the bars are drawn from. A quote's content is whatever markdown
    /// puts in it, so a heading, a rule, a fence, a list item and a table's rows each carry the
    /// quote they are in, and only a paragraph carried it before.
    func testEveryBlockCarriesItsQuoteDepth() {
        func quoted(_ source: String) -> [String] {
            Markdown.blocks(source).map {
                "\($0.kind) depth \($0.depth) quote \($0.quote) outside \($0.listsOutside) \(String($0.text.characters))"
            }
        }
        XCTAssertEqual(quoted("> a\n>\n> > b\n> >\n> > > c"), [
            "paragraph depth 0 quote 1 outside 0 a",
            "paragraph depth 0 quote 2 outside 0 b",
            "paragraph depth 0 quote 3 outside 0 c",
        ])
        XCTAssertEqual(quoted("> # head\n>\n> ---\n>\n> ```\n> code\n> ```"), [
            "heading(level: 1) depth 0 quote 1 outside 0 head",
            "rule depth 0 quote 1 outside 0 ",
            "code(language: nil) depth 0 quote 1 outside 0 code",
        ])
        let quotedTable = Markdown.blocks("> | a | b |\n> |---|---|\n> | 1 | 2 |")
        XCTAssertEqual(quotedTable.map { "\($0.depth) \($0.quote) \($0.listsOutside)" }, ["0 1 0"])
        XCTAssertEqual(quotedTable.first.flatMap(Self.cells), [["a", "b"], ["1", "2"]])
        // A list inside a quote is inside it: none of its lists lead the bars in, so the bars of
        // the one quote stand in one column however deep the list goes.
        XCTAssertEqual(quoted("> - a\n>   - b\n>\n>   more of a"), [
            "item(Topo.Markdown.Marker.bullet) depth 1 quote 1 outside 0 a",
            "item(Topo.Markdown.Marker.bullet) depth 2 quote 1 outside 0 b",
            "paragraph depth 1 quote 1 outside 0 more of a",
        ])
        // A quote inside a list item is outside nothing: its own list leads its bar in, so the bar
        // sits under the item's words.
        XCTAssertEqual(quoted("- an item\n\n  > a quote\n\n  > - x"), [
            "item(Topo.Markdown.Marker.bullet) depth 1 quote 0 outside 1 an item",
            "paragraph depth 1 quote 1 outside 1 a quote",
            "item(Topo.Markdown.Marker.bullet) depth 2 quote 1 outside 1 x",
        ])
        XCTAssertEqual(quoted("> - i"), ["item(Topo.Markdown.Marker.bullet) depth 1 quote 1 outside 0 i"])
        XCTAssertEqual(quoted("a paragraph\n\n- an item"), [
            "paragraph depth 0 quote 0 outside 0 a paragraph",
            "item(Topo.Markdown.Marker.bullet) depth 1 quote 0 outside 1 an item",
        ])
    }

    /// A quote's own lazy continuation is one paragraph of the quote it opened, at its level.
    func testALazyNestedQuoteKeepsItsLevel() {
        XCTAssertEqual(Markdown.blocks("> > lazy\ncontinued").map { ($0.quote, String($0.text.characters)) }
            .map { "\($0.0) \($0.1)" }, ["2 lazy\ncontinued"])
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
            ("5*3*2", ["paragraph 0 532"]),
            ("__init__.py", ["paragraph 0 init.py"]),
            // A block of HTML has no block intent at all, and is a paragraph of its words.
            ("<div>\nhello\n</div>", ["paragraph 0 <div>\nhello\n</div>"]),
        ]
        for (source, blocks) in cases {
            XCTAssertEqual(summary(source), blocks, source)
        }
    }

    /// A table's rows as their cells' words, the header first; nil for a block that is no table.
    private static func cells(_ block: Markdown.Block) -> [[String]]? {
        guard case .table(let header, let rows) = block.kind else { return nil }
        return ([header] + rows).map { $0.cells.map { String($0.text.characters) } }
    }

    /// A table is one block holding every cell of the source, header included, each in its
    /// column, with its column's alignment.
    func testATableIsOneBlockOfEveryCell() throws {
        let source = """
        | name | size | kept |
        |:-----|:----:|-----:|
        | look.json | 2 KB | yes |
        | notes.md | 14 KB | no |
        | `a.py` | **1** KB | *maybe* |
        """
        let blocks = Markdown.blocks(source)
        XCTAssertEqual(blocks.count, 1)
        let block = try XCTUnwrap(blocks.first)
        XCTAssertEqual(Self.cells(block), [
            ["name", "size", "kept"],
            ["look.json", "2 KB", "yes"],
            ["notes.md", "14 KB", "no"],
            ["a.py", "1 KB", "maybe"],
        ])
        guard case .table(let header, let rows) = block.kind else { return XCTFail("\(block.kind)") }
        for row in [header] + rows {
            XCTAssertEqual(row.cells.map(\.alignment), [.leading, .center, .trailing])
        }
        // A cell's inline styles are carried, as a paragraph's are.
        XCTAssertEqual(rows[2].cells[0].text.runs.first?.inlinePresentationIntent, .code)
        XCTAssertEqual(rows[2].cells[2].text.runs.first?.inlinePresentationIntent, .emphasized)
        XCTAssertEqual(Speakable.text(from: source), "A table with 3 rows.")
    }

    /// The parse makes no run for an empty cell. The row still holds a cell for every column,
    /// and the cells after the empty one stay in their own columns.
    func testAnEmptyCellKeepsItsColumn() {
        let source = "| a | b | c |\n|---|---|---|\n| 1 |  | 3 |\n|  | 5 |  |\n| 7 | 8 | 9 |"
        XCTAssertEqual(Markdown.blocks(source).compactMap(Self.cells), [[
            ["a", "b", "c"], ["1", "", "3"], ["", "5", ""], ["7", "8", "9"],
        ]])
        XCTAssertEqual(Speakable.text(from: source), "A table with 3 rows.")
        // An empty header cell is the same case.
        XCTAssertEqual(Markdown.blocks("|  | b |\n|---|---|\n| 1 | 2 |").compactMap(Self.cells),
                       [[["", "b"], ["1", "2"]]])
    }

    /// A table inside a list item is one block at the item's depth, and the words round it stay.
    func testATableInsideAListKeepsItsDepthAndItsCells() {
        let source = "- sizes:\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |\n\n  after the table\n- next"
        let blocks = Markdown.blocks(source)
        XCTAssertEqual(blocks.map { "\($0.depth) \(String($0.text.characters))" },
                       ["1 sizes:", "1 ", "1 after the table", "1 next"])
        XCTAssertEqual(blocks.compactMap(Self.cells), [[["a", "b"], ["1", "2"]]])
        XCTAssertEqual(Speakable.text(from: source), "sizes:\nA table with 1 row.\nafter the table\nnext")
    }

    /// Two tables one after the other are two blocks, and words between and after them stay.
    func testTwoTablesAreTwoBlocks() {
        let source = "| a |\n|---|\n| 1 |\n\n| b |\n|---|\n| 2 |\n| 3 |\n\nDone."
        let blocks = Markdown.blocks(source)
        XCTAssertEqual(blocks.compactMap(Self.cells), [[["a"], ["1"]], [["b"], ["2"], ["3"]]])
        XCTAssertEqual(blocks.last.map { String($0.text.characters) }, "Done.")
    }

    /// Every word of every cell the parse kept of a table is in the block, whatever the table's
    /// shape. A cell a row writes past its header's columns is one the parse itself drops, as
    /// the table's syntax has it, so it is in no run to draw: "extra" below, and what follows a
    /// bar written inside a cell's code.
    func testNoCellOfATableIsDropped() {
        let sources = [
            "| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n| 7 | 8 | 9 |",
            "| a | b | c |\n|---|---|---|\n| 1 |  | 3 |",
            "| a | b |\n|---|---|\n| 1 | 2 | extra |\n| short |",
            "- item\n\n  | a | b |\n  |---|---|\n  | 1 | 2 |",
            "> | a | b |\n> |---|---|\n> | one two | three |",
        ]
        for source in sources {
            let cells = Markdown.blocks(source).compactMap(Self.cells).flatMap { $0 }.flatMap { $0 }
            let drawn = cells.flatMap { $0.split(separator: " ").map(String.init) }
            // What the parser itself kept of the table: every run inside a cell.
            let parsed = (try? Markdown.parse(source)).map { parsed in
                parsed.runs.filter { run in
                    run.presentationIntent?.components.contains { if case .tableCell = $0.kind { true } else { false } } == true
                }.flatMap { String(parsed[$0.range].characters).split(separator: " ").map(String.init) }
            } ?? []
            XCTAssertFalse(parsed.isEmpty, source)
            XCTAssertEqual(drawn.sorted(), parsed.sorted(), source)
        }
        let over = Markdown.blocks("| a | b |\n|---|---|\n| 1 | 2 | extra |").compactMap(Self.cells)
        XCTAssertEqual(over, [[["a", "b"], ["1", "2"]]], "the parse keeps a row to its header's columns")
    }

    /// A row whose every cell is empty is a row: the parse makes no run for it, and it is kept
    /// by the place it leaves between the rows round it, so the rows the voice counts are the
    /// rows written.
    func testARowOfEmptyCellsIsARow() {
        let source = "| a | b |\n|---|---|\n|   |   |\n| 1 | 2 |"
        XCTAssertEqual(Markdown.blocks(source).compactMap(Self.cells), [[["a", "b"], ["", ""], ["1", "2"]]])
        XCTAssertEqual(Speakable.text(from: source), "A table with 2 rows.")
        let two = "| a |\n|---|\n| 1 |\n|  |\n|  |\n| 4 |"
        XCTAssertEqual(Markdown.blocks(two).compactMap(Self.cells), [[["a"], ["1"], [""], [""], ["4"]]])
        XCTAssertEqual(Speakable.text(from: two), "A table with 4 rows.")
        XCTAssertEqual(Markdown.blocks("| a |\n|---|").compactMap(Self.cells), [[["a"]]])
    }

    /// An image written as a link's words is both: the link stays on its alternative text, in
    /// the block it was written in, and the image is a block after it.
    func testAnImageThatIsALinksWordsKeepsItsLinkAndIsAnImage() {
        let source = "[![chart](chart.png)](https://example.com)"
        XCTAssertEqual(links(source), ["chart -> https://example.com"])
        XCTAssertEqual(pictured(source), ["chart", "image chart <- chart.png"])
        let among = "See [![a chart](/tmp/c.png)](https://example.com/c) and [the docs](https://example.com/c) and ![b](b.png)."
        XCTAssertEqual(links(among), ["a chart -> https://example.com/c", "the docs -> https://example.com/c"])
        XCTAssertEqual(pictured(among), ["See a chart and the docs and .", "image b <- b.png", "image a chart <- /tmp/c.png"])
        // Written in code it is words, with no link of its own to hang an image on.
        XCTAssertEqual(pictured("`[![x](x.png)](https://example.com)` and [x](https://example.org)"),
                       ["[![x](x.png)](https://example.com) and x"])
        // A source in angle brackets, and one escaped so that it is no image at all.
        XCTAssertEqual(pictured("[![a](<my chart.png>)](https://example.com)"), ["a", "image a <- my%20chart.png"])
        XCTAssertEqual(pictured("[![a](c.png \"A title\")](https://example.com)"), ["a", "image a <- c.png"])
    }

    /// Reading a reply for its linked images is one pass, whatever the reply holds: the shapes
    /// that begin like one and never end are read no further than a part's limit each.
    func testAReplyOfUnfinishedLinkedImagesIsReadInOnePass() {
        let sources = [
            String(repeating: "[![a](", count: 20_000),
            "[![a](data:image/png;base64," + String(repeating: "QUJD", count: 50_000) + ") and words",
            String(repeating: "[![", count: 40_000),
            String(repeating: "[![a](x.png)", count: 20_000),
            String(repeating: "[![a](x.png)](", count: 20_000),
            "[![" + String(repeating: "a", count: 200_000),
        ]
        for source in sources {
            let began = Date()
            _ = Markdown.blocks(source)
            let parse = Date()
            _ = try? Markdown.parse(source)
            let alone = Date().timeIntervalSince(parse)
            // The parse itself is the measure: the reading for linked images adds little to it.
            XCTAssertLessThan(parse.timeIntervalSince(began), max(alone * 4, 0.5), "\(source.prefix(16))… ×\(source.count)")
        }
    }

    /// The linked runs of the blocks of `source`: each run's words and where it goes.
    private func links(_ source: String) -> [String] {
        Markdown.blocks(source).flatMap { block in
            block.text.runs.compactMap { run in
                run.link.map { "\(String(block.text[run.range].characters)) -> \($0.absoluteString)" }
            }
        }
    }

    /// A web link keeps its address on its own run and on nothing round it, whether it was
    /// written as a link or is a bare URL the parse linked, and the words are all still there.
    func testAWebLinkIsCarriedOnItsRunAlone() {
        let source = "see [the docs](https://example.com/a) or <https://example.org> or https://example.net/x."
        XCTAssertEqual(Markdown.blocks(source).map { String($0.text.characters) },
                       ["see the docs or https://example.org or https://example.net/x."])
        XCTAssertEqual(links(source), [
            "the docs -> https://example.com/a",
            "https://example.org -> https://example.org",
            "https://example.net/x -> https://example.net/x",
        ])
        // In a heading, an item, a quote and a table's cell alike.
        XCTAssertEqual(links("# [h](https://e.com/h)\n\n- [i](https://e.com/i)\n\n> [q](https://e.com/q)"),
                       ["h -> https://e.com/h", "i -> https://e.com/i", "q -> https://e.com/q"])
        let table = Markdown.blocks("| a |\n|---|\n| [c](https://e.com/c) |")
        guard case .table(_, let rows) = table.first?.kind else { return XCTFail("\(table)") }
        XCTAssertEqual(rows.first?.cells.first?.text.runs.first?.link, URL(string: "https://e.com/c"))
        // The parse keeps a link's words and none of the styles written inside them.
        XCTAssertEqual(links("[**bold** and `code`](https://e.com/s)"),
                       ["bold and code -> https://e.com/s"])
    }

    /// Only a web address is somewhere a tap goes. A link to anything else — the app's own
    /// scheme, another app's, a file, a script, an address with no host — is its words.
    func testALinkThatIsNotAWebAddressIsItsWords() {
        let schemes = ["topo://widget/run", "file:///etc/hosts", "javascript:alert(1)", "tel:5551234",
                       "mailto:sam@example.com", "x-apple-reminderkit://x", "shortcuts://run-shortcut?name=x",
                       "data:text/html,hi", "relative/path.md", "/absolute/path", "#anchor", "https:///nohost",
                       "sms:5551234", "ftp://example.com/a"]
        for address in schemes {
            let source = "tap [here](\(address)) now"
            XCTAssertEqual(links(source), [], address)
            XCTAssertEqual(Markdown.blocks(source).map { String($0.text.characters) }, ["tap here now"], address)
        }
        XCTAssertEqual(links("mail sam@example.com or <mailto:sam@example.com>"), [])
        XCTAssertEqual(links("[a](HTTPS://Example.com/A) [b](http://example.com)"),
                       ["a -> HTTPS://Example.com/A", "b -> http://example.com"])
        for address in ["https://example.com", "http://example.com/a?b=c#d", "https://user@example.com:8443/"] {
            XCTAssertTrue(Markdown.opens(URL(string: address)!), address)
        }
    }

    /// The image blocks of `source`, as "alt <- source", and every other block as its words.
    private func pictured(_ source: String) -> [String] {
        Markdown.blocks(source).map { block in
            if case .image(let source, let alt) = block.kind { return "image \(alt) <- \(source)" }
            return String(block.text.characters)
        }
    }

    /// An image is a block of its own after the block it was written in, which keeps its words
    /// and none of the image's markup; one written alone leaves no empty block behind it.
    func testAnImageIsABlockOfItsOwnAfterTheWordsItWasWrittenIn() {
        XCTAssertEqual(pictured("![A chart](charts/sizes.png)"), ["image A chart <- charts/sizes.png"])
        XCTAssertEqual(pictured("Here it is: ![A chart](a.png) and that is all."),
                       ["Here it is:  and that is all.", "image A chart <- a.png"])
        XCTAssertEqual(pictured("Here it is:\n![A chart](a.png)\n\nNext."), ["Here it is:", "image A chart <- a.png", "Next."])
        XCTAssertEqual(pictured("![](a.png) ![two](b.png)"), ["image  <- a.png", "image two <- b.png"])
        XCTAssertEqual(pictured("![a b](<my chart.png>)"), ["image a b <- my%20chart.png"])
        // In a heading, a list item, a quote and a table's cell: under the block, at its depth.
        XCTAssertEqual(pictured("# Sizes ![c](c.png)"), ["Sizes", "image c <- c.png"])
        let listed = Markdown.blocks("- one ![c](c.png)\n- ![d](d.png)\n- three")
        XCTAssertEqual(listed.map { "\($0.depth)" }, ["1", "1", "1", "1"])
        XCTAssertEqual(pictured("- one ![c](c.png)\n- ![d](d.png)\n- three"), ["one", "image c <- c.png", "image d <- d.png", "three"])
        XCTAssertEqual(Markdown.blocks("> ![q](q.png)").map(\.quote), [1])
        XCTAssertEqual(pictured("| a |\n|---|\n| x ![t](t.png) |\n\nafter"), ["", "image t <- t.png", "after"])
        // What is not an image stays words: code, and brackets that close nothing.
        XCTAssertEqual(pictured("`![a](b.png)` and ![open](b.png"), ["![a](b.png) and ![open](b.png"])
        XCTAssertEqual(Speakable.text(from: "Look:\n\n![A chart of look.json](a.png)\n\n![](b.png)\n\n![Done.](c.png)"),
                       "Look:\nAn image: A chart of look dot json.\nAn image.\nAn image: Done.")
    }

    /// What an image's source names: a path, as written with its escapes read, for the guest to
    /// resolve; a web address; or neither.
    func testWhatAnImagesSourceNames() {
        let files: [(String, String)] = [
            ("a.png", "a.png"), ("charts/sizes.png", "charts/sizes.png"), ("./a.png", "./a.png"),
            ("my%20chart.png", "my chart.png"), ("/tmp/x.png", "/tmp/x.png"), ("/home/topo/x.png", "/home/topo/x.png"),
            ("/memory/notes/x.png", "/memory/notes/x.png"), ("memory/x.png", "memory/x.png"), ("../x.png", "../x.png"),
            ("~/x.png", "~/x.png"), ("  a.png ", "a.png"),
        ]
        for (source, path) in files {
            XCTAssertEqual(Markdown.place(ofImage: source), .file(path), source)
        }
        for source in ["", "   ", "file:///etc/hosts", "file:a.png", "data:image/png;base64,AAAA", "topo://a.png",
                       "ftp://example.com/a.png", "https:///a.png", "a%00.png"] {
            XCTAssertEqual(Markdown.place(ofImage: source), .neither, source.debugDescription)
        }
        XCTAssertEqual(Markdown.place(ofImage: "https://example.com/i.png"), .web(URL(string: "https://example.com/i.png")!))
        XCTAssertEqual(Markdown.place(ofImage: "http://example.com/i.png?x=../y"), .web(URL(string: "http://example.com/i.png?x=../y")!))
    }

    /// Nothing is fetched from the network: for a web address, or any address that is not a
    /// path, the reader is not asked at all, and what is drawn is why there is no picture. A
    /// path is the guest's to answer, and one it cannot read is drawn as "not on this device".
    @MainActor func testAnUnreadablePathIsNoPictureAndNothingIsFetched() async {
        let asked = Asked()
        let read: @Sendable (String) async -> Data? = { path in
            asked.add(path)
            return path == "notes.txt" ? Data("not a png".utf8) : nil
        }
        for source in ["https://example.com/i.png", "http://example.com/i.png"] {
            let drawn = await ReplyImage.resolve(source, read: read)
            XCTAssertEqual(drawn, .missing(.onTheWeb(URL(string: source)!)))
            XCTAssertEqual(ReplyImage.settled(source, kept: { asked.add($0); return nil }), .missing(.onTheWeb(URL(string: source)!)))
        }
        for source in ["file:///etc/hosts", "data:image/png;base64,AAAA", "ftp://example.com/a.png", ""] {
            let drawn = await ReplyImage.resolve(source, read: read)
            XCTAssertEqual(drawn, .missing(.neither), source)
        }
        XCTAssertEqual(asked.paths, [], "an address that is not a path was read")

        for source in ["../x.png", "/etc/hosts", "/tmp/gone.png", "charts/gone.png", "notes.txt"] {
            let drawn = await ReplyImage.resolve(source, read: read)
            XCTAssertEqual(drawn, .missing(.notHere), source)
        }
        XCTAssertEqual(asked.paths, ["../x.png", "/etc/hosts", "/tmp/gone.png", "charts/gone.png", "notes.txt"])
        // A path not yet read is not yet anything; the blocks carry the words drawn in its place.
        XCTAssertNil(ReplyImage.settled("/tmp/x.png", kept: { _ in nil }))
        for source in ["../x.png", "/etc/hosts", "https://example.com/i.png"] {
            XCTAssertEqual(Markdown.blocks("![a](\(source))").map(\.kind), [.image(source: source, alt: "a")])
        }
    }

    /// The paths a reader was asked for.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [String] = []
        func add(_ path: String) { lock.withLock { asked.append(path) } }
        var paths: [String] { lock.withLock { asked } }
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
