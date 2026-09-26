import SwiftUI
import TopoCore
import UIKit
import XCTest

@testable import Topo

/// What a reply's markdown draws, read off the pixels, under the phone's, the watch's and the
/// television's looks: a fence in its own enclosure and inside the column, inline styles drawn
/// and not only carried, headings bigger than words, and the person's turn drawn as typed.
///
/// Rows are drawn through `LookStage`, a real window, because a phone's fence scrolls sideways
/// and `ImageRenderer` lays out nothing inside a `ScrollView`; and through `TurnRow`, so the text
/// is drawn by the same renderer that reads its lines for Topo (`MascotLines`).
@MainActor
final class MarkdownRenderTests: XCTestCase {
    private let stage = CGSize(width: 393, height: 520)
    /// The code block's outline, in a colour nothing else on the stage is.
    private let outline = UIColor(red: 1, green: 0, blue: 0.5, alpha: 1)
    /// A quote's bars, and a quote's words, each in a colour of its own: a bar counted by its
    /// pixels alone would be indistinguishable from one bar of twice the width, and from the
    /// enclosure of a fence inside the quote.
    private let barInk = UIColor(red: 0, green: 0.6, blue: 1, alpha: 1)
    private let quoteInk = UIColor(red: 0, green: 0.5, blue: 0, alpha: 1)

    private func turn(_ role: TurnRole, _ text: String) -> Turn {
        Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 1), parents: [], role: role,
             text: text, at: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// A screen's look with the code block outlined in `outline`, so where it is drawn is a
    /// colour the test can find.
    private func look(_ screen: Look.Screen) -> Look {
        var look = Look(screen)
        look.markdown.codeBlock.accent = Color(outline)
        look.markdown.codeBlock.strokeWidth = 2
        look.markdown.quoteBar = Color(barInk)
        look.markdown.quoteText = Color(quoteInk)
        return look
    }

    private func draw(_ turn: Turn, _ look: Look) throws -> Pixels {
        let row = VStack(spacing: 0) {
            TurnRow(turn: turn)
                .padding(.horizontal, look.transcript.horizontalPadding)
            Spacer(minLength: 0)
        }
        .frame(width: stage.width, height: stage.height, alignment: .top)
        .background(Color.white)
        return try Pixels(LookStage.image(row, look: look, size: stage))
    }

    private let long = "```\n" + String(repeating: "let aVeryLongName = anotherVeryLongName; ", count: 6) + "\n```"

    /// A fence draws its enclosure and words with none do not, on every screen.
    func testAFenceIsDrawnInItsOwnEnclosure() throws {
        for screen in Look.Screen.allCases {
            let fenced = try draw(turn(.assistant, "Here:\n\n```\nlet x = 1\n```"), look(screen))
            XCTAssertGreaterThan(fenced.count(outline), 20, "\(screen): no enclosure round the fence")
            let bare = try draw(turn(.assistant, "Here:\n\nlet x = 1"), look(screen))
            XCTAssertEqual(bare.count(outline), 0, "\(screen): an enclosure with no fence")
        }
    }

    /// A code line longer than the column stays in the column: the phone scrolls it inside its
    /// enclosure and the watch and the television wrap it, and on every screen the enclosure
    /// ends where the reply's words end, before Topo's margin.
    func testALongCodeLineStaysInTheColumn() throws {
        for screen in Look.Screen.allCases {
            let look = look(screen)
            let pixels = try draw(turn(.assistant, long), look)
            let columns = try XCTUnwrap(pixels.columns(outline), "\(screen): no enclosure")
            let edge = (stage.width - look.transcript.horizontalPadding - look.transcript.replyTrailingInset) * pixels.scale
            XCTAssertLessThanOrEqual(CGFloat(columns.upperBound), edge + 1, "\(screen): the fence ran past the column")
            XCTAssertGreaterThanOrEqual(CGFloat(columns.lowerBound), look.transcript.horizontalPadding * pixels.scale - 1,
                                        "\(screen): the fence ran before the column")
        }
    }

    /// Wrapping a long line makes the block taller than scrolling it: the look's overflow is
    /// what decides, and both are drawn.
    func testTheOverflowIsTheLooks() throws {
        var scroll = look(.phone)
        scroll.markdown.codeOverflow = .scroll
        var wrap = scroll
        wrap.markdown.codeOverflow = .wrap
        let scrolled = try XCTUnwrap(try draw(turn(.assistant, long), scroll).rows(outline))
        let wrapped = try XCTUnwrap(try draw(turn(.assistant, long), wrap).rows(outline))
        XCTAssertGreaterThan(wrapped.count, scrolled.count * 2, "wrapping did not wrap: \(scrolled) \(wrapped)")
    }

    /// Emphasis, strong and inline code are drawn, not only carried: each is a different picture
    /// from the same word plain, through the renderer that reads Topo's lines.
    func testEmphasisAndInlineCodeDraw() throws {
        for screen in Look.Screen.allCases {
            let plain = try draw(turn(.assistant, "a word here"), look(screen))
            let again = try draw(turn(.assistant, "a word here"), look(screen))
            XCTAssertFalse(try LookStage.differ(plain.bytes, again.bytes), "\(screen): one row drew two pictures")
            for styled in ["a *word* here", "a **word** here", "a `word` here", "a ~~word~~ here"] {
                let drawn = try draw(turn(.assistant, styled), look(screen))
                XCTAssertTrue(try LookStage.differ(plain.bytes, drawn.bytes), "\(screen): \(styled) drew as plain")
            }
        }
    }

    /// A heading is drawn taller than the same words as a paragraph in Topo's turn, and in the
    /// person's the markup is drawn as typed: the same height as the words without it, and a
    /// different picture, since the `#` is there.
    func testAHeadingIsTallerAndThePersonsTurnIsLiteral() throws {
        for screen in Look.Screen.allCases {
            let look = look(screen)
            let words = try XCTUnwrap(try draw(turn(.assistant, "Reading the log"), look).inked, "\(screen)")
            let heading = try XCTUnwrap(try draw(turn(.assistant, "# Reading the log"), look).inked, "\(screen)")
            XCTAssertGreaterThan(heading.count, words.count, "\(screen): the heading is no taller than words")

            let typed = try draw(turn(.person, "# Reading *the* log"), look)
            let plain = try draw(turn(.person, "Reading the log"), look)
            XCTAssertEqual(try XCTUnwrap(typed.inked).count, try XCTUnwrap(plain.inked).count, accuracy: 2,
                           "\(screen): the person's markup changed their turn's height")
            XCTAssertTrue(try LookStage.differ(typed.bytes, plain.bytes), "\(screen): the person's markup was not drawn")
        }
    }

    // MARK: Quotes

    /// A quote is drawn behind one bar for each level it sits inside, each `quoteIndent` from the
    /// next, and its words start after the last of them: `> > b` draws two bars where `> a` draws
    /// one, on every screen.
    func testEachQuoteLevelDrawsItsOwnBar() throws {
        for screen in Look.Screen.allCases {
            let look = look(screen)
            let width = look.markdown.quoteBarWidth
            let step = width + look.markdown.quoteIndent

            let one = try draw(turn(.assistant, "> a quote"), look)
            let bars = try XCTUnwrap(one.runs(barInk), "\(screen): no bar at all")
            XCTAssertEqual(bars.count, 1, "\(screen): one level drew \(bars.count) bars")

            let two = try draw(turn(.assistant, "> > a quote"), look)
            let nested = try XCTUnwrap(two.runs(barInk), "\(screen): no bar in a nested quote")
            XCTAssertEqual(nested.count, 2, "\(screen): two levels drew \(nested.count) bars: \(nested)")
            for (level, run) in nested.enumerated() {
                XCTAssertEqual(CGFloat(run.count) / one.scale, width, accuracy: 1,
                               "\(screen): bar \(level) is not \(width) points wide")
            }
            XCTAssertEqual(CGFloat(nested[1].lowerBound - nested[0].lowerBound) / one.scale, step, accuracy: 1,
                           "\(screen): the second bar is not \(step) points after the first")
            XCTAssertEqual(CGFloat(nested[0].lowerBound - bars[0].lowerBound) / one.scale, 0, accuracy: 1,
                           "\(screen): the outer bar moved")

            // The words come after the last bar, one step further in than at one level.
            let near = try XCTUnwrap(one.columns(quoteInk), "\(screen): the quote's words were not drawn")
            let far = try XCTUnwrap(two.columns(quoteInk), "\(screen): the nested quote's words were not drawn")
            XCTAssertEqual(CGFloat(far.lowerBound - near.lowerBound) / one.scale, step, accuracy: 2,
                           "\(screen): the nested quote's words did not move in by \(step)")
        }
    }

    /// Three levels under a look whose bars and insets are far wider than the default: the bars are
    /// drawn at their width and the words are still inside the reply's column, as a long code line
    /// is. The top of both ranges (64 points each) spends more than a phone's column on three
    /// levels of bar, so what is held here is a look well above the default rather than its ceiling.
    func testADeepQuoteUnderAWideLookStaysInTheColumn() throws {
        var look = look(.phone)
        look.markdown.quoteBarWidth = 8
        look.markdown.quoteIndent = 16
        let pixels = try draw(turn(.assistant, "> > > deep"), look)
        let bars = try XCTUnwrap(pixels.runs(barInk), "no bars")
        XCTAssertEqual(bars.count, 3, "three levels drew \(bars.count) bars: \(bars)")
        let words = try XCTUnwrap(pixels.columns(quoteInk), "the deep quote's words were not drawn")
        let edge = (stage.width - look.transcript.horizontalPadding - look.transcript.replyTrailingInset) * pixels.scale
        XCTAssertLessThanOrEqual(CGFloat(words.upperBound), edge + 1, "the words ran past the column")
        XCTAssertGreaterThanOrEqual(CGFloat(words.lowerBound),
                                    (look.transcript.horizontalPadding + 3 * (8 + 16)) * pixels.scale - 2,
                                    "the words did not clear the bars")
    }

    /// A quote holds whatever markdown puts in it, and each of those keeps its bar: a heading and a
    /// fence inside a quote are drawn behind one, and the fence keeps its own enclosure inside the
    /// column — on the phone, where it is a horizontal scroller, as on the screens that wrap it.
    func testAQuotedHeadingAndFenceKeepTheirBar() throws {
        for screen in Look.Screen.allCases {
            let look = look(screen)
            let heading = try draw(turn(.assistant, "> # a head"), look)
            XCTAssertNotNil(heading.runs(barInk), "\(screen): a quoted heading drew no bar")

            let quoted = try draw(turn(.assistant, "> ```\n> let x = 1\n> ```"), look)
            let bars = try XCTUnwrap(quoted.runs(barInk), "\(screen): a quoted fence drew no bar")
            XCTAssertEqual(bars.count, 1, "\(screen): a quoted fence drew \(bars.count) bars")
            let enclosure = try XCTUnwrap(quoted.columns(outline), "\(screen): a quoted fence drew no enclosure")
            let edge = (stage.width - look.transcript.horizontalPadding - look.transcript.replyTrailingInset) * quoted.scale
            XCTAssertLessThanOrEqual(CGFloat(enclosure.upperBound), edge + 1, "\(screen): the quoted fence ran past the column")

            // And it is no narrower than the bare fence less the bar and its inset, so a scroller
            // squeezed to nothing inside the bars fails rather than passes.
            let bare = try XCTUnwrap(try draw(turn(.assistant, "```\nlet x = 1\n```"), look).columns(outline),
                                     "\(screen): no bare enclosure")
            let step = (look.markdown.quoteBarWidth + look.markdown.quoteIndent) * quoted.scale
            XCTAssertGreaterThanOrEqual(CGFloat(enclosure.count), CGFloat(bare.count) - step - 2,
                                        "\(screen): the quoted fence lost more width than the bar it stands behind")
        }
    }

    /// A quote and a list interleaved. Every bar of one quote stands in one column however deeply
    /// the list inside it nests, and a quote inside a list item keeps the item's indent.
    func testAQuoteAndAListInterleave() throws {
        let look = look(.phone)
        let indent = look.markdown.listIndent

        // A nested list inside one quote: one bar, one column, both rows.
        let inQuote = try draw(turn(.assistant, "> - a\n>   - b"), look)
        let bars = try XCTUnwrap(inQuote.runs(barInk), "a quoted list drew no bar")
        XCTAssertEqual(bars.count, 1, "the bars of one quote stood in \(bars.count) columns: \(bars)")
        XCTAssertEqual(CGFloat(bars[0].lowerBound) / inQuote.scale, look.transcript.horizontalPadding, accuracy: 1,
                       "the bar of a quoted list is not at the margin")

        // A quote inside a list item keeps the item's indent, so its bar sits one indent in.
        let inItem = try draw(turn(.assistant, "- an item\n\n  > a quote"), look)
        let itemBars = try XCTUnwrap(inItem.runs(barInk), "a quote in an item drew no bar")
        XCTAssertEqual(itemBars.count, 1, "a quote in an item drew \(itemBars.count) columns of bar")
        XCTAssertEqual(CGFloat(itemBars[0].lowerBound) / inItem.scale,
                       look.transcript.horizontalPadding + indent, accuracy: 1,
                       "the quote in an item did not keep the item's indent")

        // A list item inside a quote puts its marker after the bar, and the bar at the margin.
        let itemInQuote = try draw(turn(.assistant, "> - i"), look)
        let quoteBars = try XCTUnwrap(itemInQuote.runs(barInk), "a quoted item drew no bar")
        XCTAssertEqual(quoteBars.count, 1, "a quoted item drew \(quoteBars.count) columns of bar")
        XCTAssertEqual(CGFloat(quoteBars[0].lowerBound) / itemInQuote.scale, look.transcript.horizontalPadding,
                       accuracy: 1, "a quoted item's bar is not at the margin")
    }

    /// A rendered stage as bytes, with the questions worth asking of it.
    private struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let scale: CGFloat

        @MainActor init(_ image: UIImage) throws {
            bytes = try LookStage.bytes(image)
            let cgImage = try XCTUnwrap(image.cgImage)
            width = cgImage.width
            height = cgImage.height
            scale = CGFloat(width) / image.size.width
        }

        private func matches(_ colour: UIColor, _ index: Int) -> Bool {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.getRed(&r, green: &g, blue: &b, alpha: &a)
            let want = [r, g, b].map { Int($0 * 255 + 0.5) }
            return (0..<3).allSatisfy { abs(Int(bytes[index + $0]) - want[$0]) <= 6 }
        }

        func count(_ colour: UIColor) -> Int {
            stride(from: 0, to: bytes.count, by: 4).filter { matches(colour, $0) }.count
        }

        /// The columns a colour is found in, first to last.
        func columns(_ colour: UIColor) -> ClosedRange<Int>? {
            var found: [Int] = []
            for y in 0..<height { for x in 0..<width where matches(colour, (y * width + x) * 4) { found.append(x) } }
            guard let low = found.min(), let high = found.max() else { return nil }
            return low...high
        }

        /// The disjoint column runs a colour is found in, leading first: one per bar, so two bars
        /// are two runs and one bar of twice the width is one.
        func runs(_ colour: UIColor) -> [ClosedRange<Int>]? {
            var found: Set<Int> = []
            for y in 0..<height { for x in 0..<width where matches(colour, (y * width + x) * 4) { found.insert(x) } }
            guard !found.isEmpty else { return nil }
            var runs: [ClosedRange<Int>] = []
            for x in found.sorted() {
                if let last = runs.last, x == last.upperBound + 1 { runs[runs.count - 1] = last.lowerBound...x }
                else { runs.append(x...x) }
            }
            return runs
        }

        /// The rows a colour is found in, first to last.
        func rows(_ colour: UIColor) -> ClosedRange<Int>? {
            let found = (0..<height).filter { y in (0..<width).contains { matches(colour, (y * width + $0) * 4) } }
            guard let low = found.first, let high = found.last else { return nil }
            return low...high
        }

        /// The rows anything but white is drawn in, first to last.
        var inked: ClosedRange<Int>? {
            let found = (0..<height).filter { y in
                (0..<width).contains { x in (0..<3).contains { bytes[(y * width + x) * 4 + $0] < 200 } }
            }
            guard let low = found.first, let high = found.last else { return nil }
            return low...high
        }
    }
}
