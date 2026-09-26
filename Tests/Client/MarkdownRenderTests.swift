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
