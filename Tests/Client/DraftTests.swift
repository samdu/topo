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
                       edit: (@MainActor () -> Void)? = nil, holdsKeyboard: Bool = false) -> Draft {
        Draft(text: .constant(text), typing: .constant(typing), sending: sending, edit: edit,
              holdsKeyboard: holdsKeyboard)
    }

    /// Nothing written and no keyboard: the transcript ends at the last turn, as it did before
    /// there was a row at all.
    func testAnEmptyRowWithNoKeyboardIsNotShown() {
        XCTAssertEqual(draft().state, .hidden)
    }

    func testTheKeyboardAloneShowsTheRow() {
        XCTAssertEqual(draft(typing: true).state, .writing)
    }

    /// The keyboard asked down while the field still holds it leaves the row where it is: taken
    /// out of the window then, the field would drop the keyboard with no animation. The row goes
    /// once the field has let the keyboard go.
    func testTheRowStaysUntilItsFieldHasLetTheKeyboardGo() {
        XCTAssertEqual(draft(typing: false, holdsKeyboard: true).state, .writing)
        XCTAssertEqual(draft(typing: false, holdsKeyboard: false).state, .hidden)
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

/// The row, read off the pixels. Two things are worth holding: that it is drawn at the size the
/// turn it is about to become will be — the transcript's type, an enclosure of the bubble's
/// shape, hugging its words rather than filling the line — and that its colour is the one thing
/// that is not the landed turn's, since the row is not a turn until it lands: secondary while it
/// is written, signal while it is on its way, and the person's primary only in the log.
@MainActor
final class DraftRowRenderTests: XCTestCase {
    private let width: CGFloat = 340

    /// The look every render here is made under. The send control is the mind's side and takes
    /// the same `primary` a landed turn does, which a render read by colour could confuse with
    /// the bubble it sits beside — and every measurement below is of the bubble. So the control
    /// is given an ink of its own here. That the look's ink reaches the control at all is held by
    /// `testTheSendControlIsDrawnFromTheLook`, which names an ink of its own too, and the row
    /// draws the shipped one.
    private static func look() -> Look {
        var look = Look()
        look.draft.sendInk = Color(red: 0, green: 1, blue: 0)
        return look
    }

    /// The row under the look given, as pixels. The `TextField` in it is laid out by
    /// `ImageRenderer` and not drawn, which is exactly why the bubble is sized by a `Text` behind
    /// it: what is measured here is the size that `Text` gives it.
    private func render(_ draft: Draft, look: Look = DraftRowRenderTests.look()) throws -> Raster {
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

        /// How many pixels in the rightmost `columns` are not the white behind the render: what
        /// the slot has in it, whatever colour it is drawn in.
        func inkInTrailing(_ columns: Int) -> Int {
            var found = 0
            for y in 0..<height {
                for x in max(0, width - columns)..<width {
                    let i = (y * width + x) * 4
                    if pixels[i] < 250 || pixels[i + 1] < 250 || pixels[i + 2] < 250 { found += 1 }
                }
            }
            return found
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
    /// The accent is the row's own by default, since that is what the row draws; a landed turn's
    /// is measured by naming the bubble's.
    private func box(_ raster: Raster, _ accent: Color = Look().draft.written.accent) throws
        -> (left: Int, right: Int, top: Int, bottom: Int) {
        let found = outline(raster, accent)
        let xs = found.map(\.x), ys = found.map(\.y)
        return (try XCTUnwrap(xs.min(), "no bubble to measure"), try XCTUnwrap(xs.max()),
                try XCTUnwrap(ys.min(), "no bubble to measure"), try XCTUnwrap(ys.max()))
    }

    // MARK: Drawn as the turn it becomes

    func testTheRowIsDrawnInAnOutlinedBubble() throws {
        XCTAssertFalse(outline(try render(draft("Morning.")), Look().draft.written.accent).isEmpty,
                       "the row draws no outline at all")
    }

    /// The row's two enclosures are its own, so a look that changes the person's landed bubble
    /// leaves the row alone — which is what makes the draft's colour a value of the draft's.
    func testTheLooksLandedBubbleDoesNotReachTheRow() throws {
        var look = Self.look()
        look.bubble.accent = Color(red: 1, green: 0, blue: 1)
        let raster = try render(draft("Morning."), look: look)
        XCTAssertTrue(raster.pixels(matching: .magenta).isEmpty,
                      "the landed bubble's accent reached the row, so the row is drawn from it")
        XCTAssertFalse(outline(raster, Look().draft.written.accent).isEmpty,
                       "the row stopped drawing its own accent")
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
        let turn = try box(try renderTurn(words), Look().bubble.accent)
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

        var wider = Self.look()
        wider.draft.minimumWidth = 260
        let widened = try box(try render(draft(""), look: wider))
        XCTAssertGreaterThan(widened.right - widened.left, empty.right - empty.left,
                             "the look's minimum width does not reach the empty row")
    }

    // MARK: The colour of a turn that is not one yet

    /// Being written, the row is the theme's secondary. Asserted against `Theme` and not against
    /// the look the render was made under, since a colour compared with the one it was drawn
    /// from passes whatever either of them is.
    func testTheRowBeingWrittenIsDrawnInTheSecondaryColour() throws {
        XCTAssertFalse(outline(try render(draft("bins?")), Theme.secondary).isEmpty,
                       "the row being written is not drawn in the theme's secondary")
    }

    /// On its way, it is the theme's signal: the palette's measured liveness, which a turn that
    /// has been said and is not yet in the log is.
    func testTheRowInFlightIsDrawnInTheSignalColour() throws {
        XCTAssertFalse(outline(try render(draft("bins?", sending: true)), Theme.signal).isEmpty,
                       "the row in flight is not drawn in the theme's signal")
    }

    /// The landed turn's own colour is in neither state of the row. The draft becomes a turn of
    /// the person's by landing, so a row drawn in `primary` before it lands says it already has.
    func testThePersonsLandedColourIsInNeitherStateOfTheRow() throws {
        XCTAssertTrue(outline(try render(draft("bins?")), Theme.primary).isEmpty,
                      "the row being written is drawn in the landed turn's colour")
        XCTAssertTrue(outline(try render(draft("bins?", sending: true)), Theme.primary).isEmpty,
                      "the row in flight is drawn in the landed turn's colour")
    }

    /// Each state is drawn from its own field of the look, so a look that names another accent
    /// for either of them draws that and leaves the other alone.
    func testEachStateIsDrawnFromItsOwnFieldOfTheLook() throws {
        var written = Self.look()
        written.draft.written.accent = Color(red: 1, green: 0, blue: 1)
        let writing = try render(draft("bins?"), look: written)
        XCTAssertFalse(writing.pixels(matching: .magenta).isEmpty,
                       "the look's written accent does not reach the row")
        XCTAssertTrue(try render(draft("bins?", sending: true), look: written)
                        .pixels(matching: .magenta).isEmpty,
                      "the written accent reached the row in flight")

        var sending = Self.look()
        sending.draft.sending.accent = Color(red: 0, green: 0, blue: 1)
        let inFlight = try render(draft("bins?", sending: true), look: sending)
        XCTAssertFalse(inFlight.pixels(matching: .blue).isEmpty,
                       "the look's sending accent does not reach the row in flight")
        XCTAssertTrue(try render(draft("bins?"), look: sending).pixels(matching: .blue).isEmpty,
                      "the sending accent reached the row being written")
    }

    /// The colour is the whole of what changes when the turn goes: the same size, in the same
    /// place, so nothing moves under the thumb that sent it.
    func testTheBubbleKeepsItsSizeAndPlaceWhenTheTurnGoes() throws {
        let words = "bins?"
        let writing = try box(try render(draft(words)))
        let inFlight = try box(try render(draft(words, sending: true)), Look().draft.sending.accent)
        XCTAssertEqual(writing.left, inFlight.left, "the bubble moved when the turn went")
        XCTAssertEqual(writing.right, inFlight.right)
        XCTAssertEqual(writing.top, inFlight.top)
        XCTAssertEqual(writing.bottom, inFlight.bottom)
    }

    /// The send control goes when the turn goes, the slot keeps its space so the bubble beside
    /// it does not move, and something is drawn in that space. What that something is, this
    /// render cannot say: `ImageRenderer` draws a `ProgressView` in the system's own grey and not
    /// in the tint it is given, so the ink in the slot is not the look's to check. That the thing
    /// there is a spinner and not the send control is the running app's to show —
    /// `TopoUITests/DraftRowTests`, where "Sending" exists and no "Send" button does.
    func testTheSendControlGoesAndTheSlotKeepsItsSpace() throws {
        let writing = try render(draft("bins?"))
        let sent = try render(draft("bins?", sending: true))
        let ink = UIColor(Self.look().draft.sendInk).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let light = UIColor(Self.look().draft.sendInk).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let before = writing.pixels(matching: ink).count + writing.pixels(matching: light).count
        let after = sent.pixels(matching: ink).count + sent.pixels(matching: light).count
        XCTAssertGreaterThan(before, 0, "the send control is not drawn in the look's ink")
        XCTAssertEqual(after, 0, "the send control is still drawn while the turn is on its way")

        // The slot is the row's trailing edge, a `look.draft.slot` wide at the render's scale. A
        // slot that stopped taking its space would let the bubble slide into it, which is the
        // whole reason the control and the spinner are drawn in one frame of a fixed size.
        let slot = Int(Look().draft.slot * 3)
        XCTAssertGreaterThan(sent.inkInTrailing(slot), 0, "nothing at all is drawn in the slot while the turn is on its way")
        XCTAssertEqual(try box(sent, Look().draft.sending.accent).right, try box(writing).right,
                       "the bubble moved when the turn went, so the slot did not keep its space")
    }

    /// The control is the look's: its ink, its type and the room it takes.
    func testTheSendControlIsDrawnFromTheLook() throws {
        var ink = Self.look()
        ink.draft.sendInk = Color(red: 1, green: 0, blue: 1)
        XCTAssertFalse(try render(draft("bins?"), look: ink).pixels(matching: .magenta).isEmpty,
                       "the look's send ink does not reach the control")

        let shipped = try box(try render(draft("bins?")))
        var wide = Self.look()
        wide.draft.slot = 80
        let widened = try box(try render(draft("bins?"), look: wide))
        XCTAssertLessThan(widened.right, shipped.right,
                          "the look's slot does not reach the room the control takes")

        var apart = Self.look()
        apart.draft.spacing = 40
        let spaced = try box(try render(draft("bins?"), look: apart))
        XCTAssertLessThan(spaced.right, shipped.right,
                          "the look's spacing does not reach the room beside the bubble")
    }

    /// A control that would send nothing says so: an empty row's send is faded by the look's
    /// own value rather than being live to press and doing nothing.
    func testAnEmptyRowsSendIsFadedByTheLook() throws {
        let ink = UIColor(Self.look().draft.sendInk).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        let dark = UIColor(Self.look().draft.sendInk).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        let empty = try render(draft(""))
        let written = try render(draft("bins?"))
        XCTAssertLessThan(empty.pixels(matching: ink).count + empty.pixels(matching: dark).count,
                          written.pixels(matching: ink).count + written.pixels(matching: dark).count,
                          "an empty row draws its send control as live as a written one's")

        var solid = Self.look()
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
