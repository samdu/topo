import SwiftUI
import TopoCore
import UIKit
import XCTest

@testable import Topo

/// What the row at the end of the transcript is, and what it draws. The three states are a value
/// rather than a screen, so what the row shows in each is asserted here; what the log does under
/// each is in `HarnessIntegrationTests`, since a row that says the right thing over the wrong log
/// is the failure worth catching.
@MainActor
final class DraftStateTests: XCTestCase {
    private func draft(_ text: String = "", typing: Bool = false, sending: Bool = false,
                       edit: (@MainActor () -> Void)? = nil) -> Draft {
        Draft(text: .constant(text), typing: .constant(typing), sending: sending, edit: edit)
    }

    /// Nothing written and no keyboard: the transcript ends at the last turn, as it did before
    /// there was a row at all.
    func testAnEmptyRowWithNoKeyboardIsNotShown() {
        XCTAssertEqual(draft().state, .hidden)
    }

    func testTheKeyboardAloneShowsTheRow() {
        XCTAssertEqual(draft(typing: true).state, .writing)
    }

    /// A caption from the microphone arrives with no keyboard, and the row is what shows it.
    func testWordsWithNoKeyboardShowTheRow() {
        XCTAssertEqual(draft("purple elephants").state, .writing)
    }

    /// The turn is on its way whatever else is true: the keyboard may be up or down, and the
    /// words are the ones being sent either way.
    func testATurnOnItsWayIsInFlightAboveEverythingElse() {
        XCTAssertEqual(draft("bins?", sending: true).state, .inFlight)
        XCTAssertEqual(draft("bins?", typing: true, sending: true).state, .inFlight)
        XCTAssertEqual(draft(sending: true).state, .inFlight, "an empty row in flight is still in flight")
    }

    /// The way back is offered or it is not; the row never draws a way back that does nothing.
    func testTheWayBackIsWhatTheRowIsGiven() {
        XCTAssertNil(draft("bins?", sending: true).edit)
        XCTAssertNotNil(draft("bins?", sending: true, edit: {}).edit)
    }
}

/// The row, read off the pixels. Two things are worth holding: that it is drawn as the turn it is
/// about to become — the person's bubble, the transcript's type, hugging its words rather than
/// filling the line — and that nothing in it changes colour when the turn goes, since colour says
/// who is on the other end and never says state.
@MainActor
final class DraftRowRenderTests: XCTestCase {
    private let width: CGFloat = 340

    /// The row under the look given, as pixels. The `TextField` in it is laid out by
    /// `ImageRenderer` and not drawn, which is exactly why the bubble is sized by a `Text` behind
    /// it: what is measured here is the size that `Text` gives it.
    private func render(_ draft: Draft, look: Look = Look()) throws -> Raster {
        let view = DraftRow(draft: draft)
            .environment(\.look, look)
            .frame(width: width)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return try Raster(try XCTUnwrap(renderer.uiImage, "the row rendered to nothing"))
    }

    /// One landed turn, for the comparison the row exists to make.
    private func renderTurn(_ text: String, look: Look = Look()) throws -> Raster {
        let turn = Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 1), parents: [],
                        role: .person, text: text, at: Date(timeIntervalSince1970: 1_700_000_000))
        let view = TurnRow(turn: turn)
            .environment(\.look, look)
            .frame(width: width)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return try Raster(try XCTUnwrap(renderer.uiImage, "the turn rendered to nothing"))
    }

    private func draft(_ text: String, typing: Bool = true, sending: Bool = false) -> Draft {
        Draft(text: .constant(text), typing: .constant(typing), sending: sending)
    }

    /// A rendered row as bytes, and where in it a colour lands.
    private struct Raster {
        let width: Int
        let height: Int
        private let pixels: [UInt8]

        init(_ image: UIImage) throws {
            let cgImage = try XCTUnwrap(image.cgImage, "no bitmap behind the render")
            width = cgImage.width
            height = cgImage.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = bytes
        }

        /// Every pixel of a colour, within the tolerance the render's antialiasing needs.
        func pixels(matching colour: UIColor, tolerance: Int = 4) -> [(x: Int, y: Int)] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.getRed(&r, green: &g, blue: &b, alpha: &a)
            let want = (Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
            var found: [(x: Int, y: Int)] = []
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    if abs(Int(pixels[i]) - want.0) <= tolerance,
                       abs(Int(pixels[i + 1]) - want.1) <= tolerance,
                       abs(Int(pixels[i + 2]) - want.2) <= tolerance {
                        found.append((x, y))
                    }
                }
            }
            return found
        }
    }

    /// The accent as it resolves in whichever appearance the renderer drew in.
    private func outline(_ raster: Raster, _ colour: Color) -> [(x: Int, y: Int)] {
        [UITraitCollection(userInterfaceStyle: .light), UITraitCollection(userInterfaceStyle: .dark)]
            .flatMap { raster.pixels(matching: UIColor(colour).resolvedColor(with: $0)) }
    }

    /// The bubble's outline, as a box: where it starts, where it ends, how wide and how tall.
    private func box(_ raster: Raster, _ look: Look = Look()) throws -> (left: Int, right: Int, top: Int, bottom: Int) {
        let found = outline(raster, look.bubble.accent)
        let xs = found.map(\.x), ys = found.map(\.y)
        return (try XCTUnwrap(xs.min(), "no bubble to measure"), try XCTUnwrap(xs.max()),
                try XCTUnwrap(ys.min(), "no bubble to measure"), try XCTUnwrap(ys.max()))
    }

    // MARK: Drawn as the turn it becomes

    func testTheRowIsDrawnInThePersonsBubble() throws {
        XCTAssertFalse(outline(try render(draft("Morning.")), Look().bubble.accent).isEmpty,
                       "the row draws no outline in the person's accent")
    }

    /// Every value the bubble draws with is the look's, and the row draws the person's bubble
    /// rather than one of its own: a look that changes the bubble changes the row with it.
    func testTheRowsBubbleIsTheLooksBubble() throws {
        var look = Look()
        look.bubble.accent = Color(red: 1, green: 0, blue: 1)
        let raster = try render(draft("Morning."), look: look)
        XCTAssertFalse(raster.pixels(matching: .magenta).isEmpty, "the row ignored the look's bubble")
        XCTAssertTrue(outline(raster, Look().bubble.accent).isEmpty,
                      "the row drew the shipped accent under a look that names another")
    }

    /// The words hug: a bubble sized by the field would take every point on offer, and the turn
    /// that lands would be a different width from the row that was written.
    func testTheBubbleIsTheWidthOfItsWordsAndNotOfTheRow() throws {
        let short = try box(try render(draft("ta")))
        let longer = try box(try render(draft("Remind me to water the plants")))
        XCTAssertGreaterThan(longer.right - longer.left, short.right - short.left,
                             "the bubble is the same width for two lengths of words, so it is not sized by them")
        XCTAssertLessThan(short.right - short.left, Int(width * 3) / 2,
                          "a two-letter draft fills half the row")
    }

    /// The same words are the same bubble, written or landed, so nothing moves when the turn
    /// lands. The row's bubble sits a send control's width further in, which is the whole of the
    /// difference between them.
    func testTheBubbleIsTheSizeTheLandedTurnsWillBe() throws {
        let words = "Remind me to water"
        let row = try box(try render(draft(words)))
        let turn = try box(try renderTurn(words))
        XCTAssertEqual(row.right - row.left, turn.right - turn.left, accuracy: 6,
                       "the row's bubble is not the width the landed turn's will be")
        XCTAssertEqual(row.bottom - row.top, turn.bottom - turn.top, accuracy: 6,
                       "the row's bubble is not the height the landed turn's will be")
        let slot = Int((Look().draft.slot + Look().draft.spacing) * 3)
        XCTAssertEqual(turn.right - row.right, slot, accuracy: 12,
                       "the row's bubble is not inset from the turn's by the control beside it")
    }

    /// Long words wrap into a taller bubble rather than scrolling inside a one-line field: the
    /// row is as tall as what is written, which is what makes it the turn it is about to be.
    func testWordsPastOneLineMakeTheBubbleTaller() throws {
        let one = try box(try render(draft("ta")))
        let many = try box(try render(draft(String(repeating: "one more thing and another ", count: 6))))
        XCTAssertGreaterThan(many.bottom - many.top, (one.bottom - one.top) * 2,
                             "a draft of six lines is drawn no taller than one, so it is scrolling inside itself")
    }

    /// Empty, the row still holds a bubble wide enough for a caret to sit in.
    func testAnEmptyRowHoldsTheLooksMinimumWidth() throws {
        let empty = try box(try render(draft("")))
        XCTAssertEqual(empty.right - empty.left, Int(Look().draft.minimumWidth * 3), accuracy: 9,
                       "an empty row is not the look's minimum width")

        var wider = Look()
        wider.draft.minimumWidth = 260
        let widened = try box(try render(draft(""), look: wider), wider)
        XCTAssertGreaterThan(widened.right - widened.left, empty.right - empty.left,
                             "the look's minimum width does not reach the empty row")
    }

    // MARK: Colour says who, not state

    /// The bubble in flight is the bubble that was being written: the same accent, the same size,
    /// the same place. What changes is the control beside it.
    func testTheBubbleDoesNotChangeWhenTheTurnGoes() throws {
        let words = "bins?"
        let writing = try box(try render(draft(words)))
        let inFlight = try box(try render(draft(words, sending: true)))
        XCTAssertEqual(writing.left, inFlight.left, "the bubble moved when the turn went")
        XCTAssertEqual(writing.right, inFlight.right)
        XCTAssertEqual(writing.top, inFlight.top)
        XCTAssertEqual(writing.bottom, inFlight.bottom)
        XCTAssertFalse(outline(try render(draft(words, sending: true)), Look().bubble.accent).isEmpty,
                       "the bubble in flight is not the person's colour any more")
    }

    /// The send control is in the slot until the turn goes, and the spinner is in it after. The
    /// slot is the same size either way, so the bubble beside it does not move.
    func testTheSlotHoldsTheSendControlAndThenTheSpinner() throws {
        let writing = try render(draft("bins?"))
        let sent = try render(draft("bins?", sending: true))
        let ink = UIColor(Look().draft.sendInk).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let light = UIColor(Look().draft.sendInk).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let before = writing.pixels(matching: ink).count + writing.pixels(matching: light).count
        let after = sent.pixels(matching: ink).count + sent.pixels(matching: light).count
        XCTAssertGreaterThan(before, 0, "the send control is not drawn in the look's ink")
        XCTAssertLessThan(after, before, "the send control is still drawn while the turn is on its way")
    }

    /// The control is the look's: its ink, its type and the room it takes.
    func testTheSendControlIsDrawnFromTheLook() throws {
        var ink = Look()
        ink.draft.sendInk = Color(red: 1, green: 0, blue: 1)
        XCTAssertFalse(try render(draft("bins?"), look: ink).pixels(matching: .magenta).isEmpty,
                       "the look's send ink does not reach the control")

        let shipped = try box(try render(draft("bins?")))
        var wide = Look()
        wide.draft.slot = 80
        let widened = try box(try render(draft("bins?"), look: wide), wide)
        XCTAssertLessThan(widened.right, shipped.right,
                          "the look's slot does not reach the room the control takes")

        var apart = Look()
        apart.draft.spacing = 40
        let spaced = try box(try render(draft("bins?"), look: apart), apart)
        XCTAssertLessThan(spaced.right, shipped.right,
                          "the look's spacing does not reach the room beside the bubble")
    }

    /// A control that would send nothing says so: an empty row's send is faded by the look's
    /// own value rather than being live to press and doing nothing.
    func testAnEmptyRowsSendIsFadedByTheLook() throws {
        let ink = UIColor(Look().draft.sendInk).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = UIColor(Look().draft.sendInk).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let empty = try render(draft(""))
        let written = try render(draft("bins?"))
        XCTAssertLessThan(empty.pixels(matching: ink).count + empty.pixels(matching: dark).count,
                          written.pixels(matching: ink).count + written.pixels(matching: dark).count,
                          "an empty row draws its send control as live as a written one's")

        var solid = Look()
        solid.draft.sendRestingOpacity = 1
        let full = try render(draft(""), look: solid)
        XCTAssertGreaterThan(full.pixels(matching: ink).count + full.pixels(matching: dark).count,
                             empty.pixels(matching: ink).count + empty.pixels(matching: dark).count,
                             "the look's resting alpha does not reach the send control")
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(message) (\(a) vs \(b))", file: file, line: line)
}
