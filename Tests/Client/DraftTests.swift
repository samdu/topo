import SwiftUI
import TopoCore
import UIKit
import XCTest

@testable import Topo

/// What the person's next turn is, and which of the two places that can draw it does. The states
/// are a value rather than a screen, so each is asserted here; what the log does under each is in
/// `HarnessIntegrationTests`, since a draft that says the right thing over the wrong log is the
/// failure worth catching.
@MainActor
final class DraftStateTests: XCTestCase {
    private func draft(_ text: String = "", typing: Bool = false, sending: Bool = false, row: Bool = false) -> Draft {
        Draft(text: .constant(text), typing: .constant(typing), sending: sending, row: row)
    }

    /// Nothing written and no keyboard: nothing is drawn, at rest or in a pane still a row as
    /// the keyboard falls.
    func testAnEmptyDraftWithNoKeyboardIsDrawnNowhere() {
        XCTAssertEqual(draft().state, .hidden)
        XCTAssertEqual(draft().drawer, .none)
        XCTAssertEqual(draft(row: true).drawer, .none)
    }

    /// The keyboard asked for is a draft being written, and it is the field's once the pane is a
    /// row. Until then there is nothing to draw: no empty bubble stands in the transcript while
    /// the keyboard rises.
    func testTheKeyboardAloneIsTheFieldsOnceThePaneIsARow() {
        XCTAssertEqual(draft(typing: true).state, .writing)
        XCTAssertEqual(draft(typing: true).drawer, .none)
        XCTAssertEqual(draft(typing: true, row: true).drawer, .pane)
    }

    /// A caption from the microphone arrives with no keyboard, and the row at the end of the
    /// transcript is what shows it. The same words under the keyboard are the field's.
    func testWordsAreTheRowsAtRestAndTheFieldsInTheRowForm() {
        XCTAssertEqual(draft("purple elephants").state, .writing)
        XCTAssertEqual(draft("purple elephants").drawer, .row)
        XCTAssertEqual(draft("purple elephants", typing: true).drawer, .row,
                       "the keyboard is asked for and not up yet, so the pane has no field for the words")
        XCTAssertEqual(draft("purple elephants", typing: true, row: true).drawer, .pane)
        XCTAssertEqual(draft("purple elephants", row: true).drawer, .pane,
                       "the keyboard is going and the pane is still a row, so the field still has the words")
    }

    /// The turn is on its way whatever else is true: the keyboard may be up or down, and the
    /// words are the ones being sent either way. They are the row's in both of the pane's forms,
    /// since the field is closed to a turn on its way.
    func testATurnOnItsWayIsInFlightAboveEverythingElseAndIsTheRows() {
        XCTAssertEqual(draft("bins?", sending: true).state, .inFlight)
        XCTAssertEqual(draft("bins?", typing: true, sending: true).state, .inFlight)
        XCTAssertEqual(draft(sending: true).state, .inFlight, "an empty draft in flight is still in flight")
        for row in [false, true] {
            XCTAssertEqual(draft("bins?", typing: row, sending: true, row: row).drawer, .row)
        }
    }

    /// What is written is read once, where it is drawn: the field says its words only while the
    /// pane is a row with no turn on its way. A turn sent with the keyboard still up is the
    /// row's from that moment, and the field under it says nothing.
    func testTheFieldSaysNothingOfATurnOnItsWayInEitherForm() {
        XCTAssertEqual(draft("bins?", typing: true, row: true).fieldValue, "bins?")
        for row in [false, true] {
            for typing in [false, true] {
                XCTAssertEqual(draft("bins?", typing: typing, sending: true, row: row).fieldValue, "",
                               "row \(row), typing \(typing): a turn on its way is read in the field and in the row")
            }
        }
        XCTAssertEqual(draft("bins?").fieldValue, "", "words the row draws at rest are read in the field too")
    }

    /// The transcript keeps its end at what the row draws and at nothing the field holds: words
    /// typed in the pane's field are no change to what it follows, so a transcript scrolled back
    /// while someone writes stays where it was read.
    func testTheTranscriptFollowsTheRowsWordsAndNotTheFields() {
        let typed = [draft("bins", typing: true, row: true), draft("bins on", typing: true, row: true)]
        XCTAssertEqual(typed.map(\.drawer), [.pane, .pane])
        XCTAssertEqual(typed.map(\.followed), [nil, nil], "words in the field move the transcript")
        XCTAssertEqual(draft("bins", typing: true, row: false).followed, "bins")
        XCTAssertEqual(draft("bins on", typing: false, row: false).followed, "bins on")
        XCTAssertEqual(draft("bins", typing: true, sending: true, row: true).followed, "bins", "a turn on its way is the row's")
        XCTAssertNil(draft("", typing: false, row: false).followed)
    }

    /// What is written is drawn in one place or none, whatever the draft holds: the field has it
    /// only in a pane that is a row, and the row has it only with something to draw.
    func testWhatIsWrittenIsNeverDrawnTwice() {
        for text in ["", "bins?"] {
            for typing in [false, true] {
                for sending in [false, true] {
                    for row in [false, true] {
                        let draft = draft(text, typing: typing, sending: sending, row: row)
                        switch draft.drawer {
                        case .pane: XCTAssertTrue(row && !sending, "the field has the words in a pane with no field shown")
                        case .row: XCTAssertTrue(sending || !text.isEmpty, "the row is drawn with nothing in it")
                        case .none: XCTAssertTrue(text.isEmpty || !sending)
                        }
                    }
                }
            }
        }
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

    /// The look every render here is made under. The spinner beside a turn on its way is tinted
    /// with the send's ink, which is the written row's own colour, and every measurement below
    /// is of the bubble: so the ink is given a colour of its own here.
    private static func look() -> Look {
        var look = Look()
        look.draft.sendInk = Color(red: 0, green: 1, blue: 0)
        return look
    }

    /// The row under the look given, as pixels.
    private func render(_ draft: Draft, look: Look = DraftRowRenderTests.look(), width: CGFloat? = nil) throws -> Raster {
        let view = DraftRow(draft: draft)
            .environment(\.look, look)
            .frame(width: width ?? self.width)
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

    /// A turn on its way that the row is not holding.
    private func renderQueued(_ text: String, look: Look = Look()) throws -> Raster {
        let view = QueuedTurnRow(turn: QueuedTurn(text: text, nonce: "n"))
            .environment(\.look, look)
            .frame(width: width)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return try Raster(try XCTUnwrap(renderer.uiImage, "the queued turn rendered to nothing"))
    }

    private func draft(_ text: String, typing: Bool = false, sending: Bool = false) -> Draft {
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

    /// The words hug: a bubble that took every point on offer would land as a turn of a
    /// different width from the row that was written.
    func testTheBubbleIsTheWidthOfItsWordsAndNotOfTheRow() throws {
        let short = try box(try render(draft("ta")))
        let longer = try box(try render(draft("Remind me to water the plants")))
        XCTAssertGreaterThan(longer.right - longer.left, short.right - short.left,
                             "the bubble is the same width for two lengths of words, so it is not sized by them")
        XCTAssertLessThan(short.right - short.left, Int(width * 3) / 2,
                          "a two-letter draft fills half the row")
    }

    /// The same words are the same bubble, written or landed, so nothing moves when the turn
    /// lands. The row's bubble sits the spinner's slot further in, which is the whole of the
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
                       "the row's bubble is not inset from the turn's by the slot beside it")
    }

    /// Long words wrap into a taller bubble: the row is as tall as what is written, which is
    /// what makes it the turn it is about to be.
    func testWordsPastOneLineMakeTheBubbleTaller() throws {
        let one = try box(try render(draft("ta")))
        let many = try box(try render(draft(String(repeating: "one more thing and another ", count: 6))))
        XCTAssertGreaterThan(many.bottom - many.top, (one.bottom - one.top) * 2,
                             "a draft of six lines is drawn no taller than one")
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

    /// A turn on its way that the row is not holding is drawn in the sending colour and not the
    /// landed one, and the same words once in the log in the landed one and not the sending one:
    /// the bubble flips when the log has the turn, and only then. Asserted against `Theme`.
    func testATurnOnItsWayOutsideTheRowIsSignalUntilItLands() throws {
        let queued = try renderQueued("bins?")
        XCTAssertFalse(outline(queued, Theme.signal).isEmpty,
                       "a turn on its way outside the row is not drawn in the theme's signal")
        XCTAssertTrue(outline(queued, Theme.primary).isEmpty,
                      "a turn on its way outside the row is drawn in the landed turn's colour")

        let landed = try renderTurn("bins?")
        XCTAssertFalse(outline(landed, Theme.primary).isEmpty, "the landed turn is not in the theme's primary")
        XCTAssertTrue(outline(landed, Theme.signal).isEmpty, "the landed turn is still drawn as on its way")
    }

    /// It is the landed bubble in another colour, where the landed bubble will be: nothing moves
    /// when it lands. And its colour is the look's, so a look that changes the sending colour
    /// changes it.
    func testATurnOnItsWayOutsideTheRowIsWhereAndWhatSizeItWillLand() throws {
        let words = "Remind me to water"
        let queued = try box(try renderQueued(words), Look().draft.sending.accent)
        let landed = try box(try renderTurn(words), Look().bubble.accent)
        XCTAssertEqual(queued.left, landed.left, accuracy: 6, "the bubble moves as it lands")
        XCTAssertEqual(queued.right, landed.right, accuracy: 6, "the bubble moves as it lands")
        XCTAssertEqual(queued.bottom - queued.top, landed.bottom - landed.top, accuracy: 6,
                       "the bubble changes height as it lands")

        var look = Look()
        look.draft.sending.accent = Color(red: 0, green: 0, blue: 1)
        XCTAssertFalse(try renderQueued(words, look: look).pixels(matching: .blue).isEmpty,
                       "the look's sending accent does not reach a turn on its way outside the row")
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

    /// The slot beside the bubble keeps its space in both states, so the bubble does not move when
    /// the turn goes: empty while the words are being written — the send is the glass's — and
    /// holding something while they are on their way. What that something is, this render cannot
    /// say: `ImageRenderer` draws a `ProgressView` in the system's own grey and not in the tint
    /// it is given. That it is a spinner is the running app's to show — `TopoUITests/DraftRowTests`,
    /// where "Sending" exists.
    func testTheSlotKeepsItsSpaceAndHoldsNothingUntilTheTurnGoes() throws {
        let writing = try render(draft("bins?"))
        let sent = try render(draft("bins?", sending: true))
        let slot = Int(Look().draft.slot * 3)
        XCTAssertEqual(writing.inkInTrailing(slot), 0, "something is drawn beside a draft being written: the row has no send")
        XCTAssertGreaterThan(sent.inkInTrailing(slot), 0, "nothing at all is drawn in the slot while the turn is on its way")
        XCTAssertEqual(try box(sent, Look().draft.sending.accent).right, try box(writing).right,
                       "the bubble moved when the turn went, so the slot did not keep its space")
    }

    /// The room beside the bubble is the look's: the slot and what is between it and the bubble.
    func testTheRoomBesideTheBubbleIsTheLooks() throws {
        let shipped = try box(try render(draft("bins?")))
        var wide = Self.look()
        wide.draft.slot = 80
        let widened = try box(try render(draft("bins?"), look: wide))
        XCTAssertLessThan(widened.right, shipped.right,
                          "the look's slot does not reach the room beside the bubble")

        var apart = Self.look()
        apart.draft.spacing = 40
        let spaced = try box(try render(draft("bins?"), look: apart))
        XCTAssertLessThan(spaced.right, shipped.right,
                          "the look's spacing does not reach the room beside the bubble")
    }

    /// The person's inset at the top of its range on a 320-point phone leaves the column 288
    /// points, less than the inset and what the row keeps: the inset yields, and the bubble is
    /// inside the column, with the slot beside it.
    func testTheInsetYieldsSoTheBubbleStaysInTheColumnAtTheTopOfItsRange() throws {
        let column = 320 - 2 * Look().transcript.horizontalPadding
        var top = Self.look()
        top.transcript.personLeadingInset = 200
        let words = "Remind me to water the plants before the weekend, and the ones on the stairs"
        let inset = try render(draft(words), look: top, width: column)
        let bubble = try box(inset)
        XCTAssertGreaterThanOrEqual(bubble.left, 0)
        XCTAssertGreaterThan(bubble.right - bubble.left, Int((Look().draft.minimumWidth - 40) * 3),
                             "the inset took the room the row keeps for its bubble")
        let slot = Int((Look().draft.slot + Look().draft.spacing) * 3)
        XCTAssertEqual(inset.width - bubble.right, slot, accuracy: 6, "the slot is not kept beside the bubble")
    }

    /// The inset the row takes: all of it where there is room, as much as leaves the row what it
    /// keeps where there is not, and never less than none.
    func testTheRowTakesTheInsetOnlyAsFarAsLeavesItsBubbleAndSlot() {
        let kept = DraftRow.kept(Look().draft)
        XCTAssertEqual(kept, 160 + 8 + 36)
        XCTAssertEqual(DraftRow.inset(100, keeping: kept, in: 370), 100)
        XCTAssertEqual(DraftRow.inset(200, keeping: kept, in: 288), 84)
        XCTAssertEqual(DraftRow.inset(200, keeping: kept, in: 150), 0)
        XCTAssertEqual(DraftRow.inset(-5, keeping: kept, in: 370), 0)
        XCTAssertEqual(DraftRow.inset(.infinity, keeping: kept, in: 370), 0)
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int, _ message: String,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertLessThanOrEqual(abs(a - b), accuracy, "\(message) (\(a) vs \(b))", file: file, line: line)
}

/// Where the transcript comes to rest when the row is not the last thing it draws. A relaunch
/// over two owed turns draws the row holding the older and the newer below it; on a transcript
/// taller than the screen, the newer has to be on the screen, not under the fold. Drawn through a
/// real window (`LookStage`), since `ImageRenderer` lays out nothing inside a `ScrollView`.
@MainActor
final class TranscriptEndTests: XCTestCase {
    /// The draft's sending colour in a blue nothing else on the stage is drawn in, so every blue
    /// band down the picture is one bubble of a turn on its way.
    private static func look() -> Look {
        var look = Look()
        look.draft.sending.accent = Color(red: 0, green: 0, blue: 1)
        return look
    }

    private func turns(_ count: Int) -> [Turn] {
        (1...count).map { n in
            Turn(ref: TurnRef(device: DeviceID("phone"), sequence: Int64(n)), parents: [],
                 role: n.isMultiple(of: 2) ? .assistant : .person,
                 text: "Turn \(n), long enough to take a line or two of the transcript's width on a phone.",
                 at: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
        }
    }

    /// The runs of picture rows with blue in them, top to bottom, as (first row, last row).
    private func blueBands(_ image: UIImage) throws -> [(Int, Int)] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bands: [(Int, Int)] = []
        for y in 0..<height {
            var blue = false
            for x in 0..<width {
                let i = (y * width + x) * 4
                if bytes[i] < 30, bytes[i + 1] < 30, bytes[i + 2] > 220 { blue = true; break }
            }
            guard blue else { continue }
            if let last = bands.last, last.1 >= y - 2 { bands[bands.count - 1].1 = y } else { bands.append((y, y)) }
        }
        return bands
    }

    func testANewerTurnOnItsWayBelowTheRowIsOnTheScreen() throws {
        let draft = Draft(text: .constant("call Helen"), typing: .constant(false), sending: true)
        let view = TranscriptView(turns: turns(30), draft: draft,
                                  queued: ([], [QueuedTurn(text: "and book the flights", nonce: "newer")]))
            .background(Color.white)
        let bands = try blueBands(try LookStage.image(view, look: Self.look()))
        XCTAssertEqual(bands.count, 2,
                       "expected the row and the turn below it on the screen, found \(bands.count) bubble(s) of a turn on its way")
    }

    func testTheTranscriptEndsAtAReplyTheLogDoesNotHoldYet() {
        let draft = Draft(text: .constant("call Helen"), typing: .constant(false), sending: true)
        let reply = UnsavedReply.turn("Calling her now.", place: 0)
        let held = TranscriptView(turns: turns(4), draft: draft, answer: reply)
        XCTAssertEqual(held.end, AnyHashable(reply.ref), "the reply under the row is drawn last and is not the end")
        let before = TranscriptView(turns: turns(4), queued: ([QueuedTurn(text: "and Krista", nonce: "older", reply: reply)], []))
        XCTAssertEqual(before.end, AnyHashable(reply.ref), "the reply under a turn on its way is drawn last and is not the end")
        let after = TranscriptView(turns: turns(4), draft: draft,
                                   queued: ([], [QueuedTurn(text: "and book the flights", nonce: "newer")]), answer: reply)
        XCTAssertEqual(after.end, AnyHashable("newer"), "a turn on its way below the row's reply is drawn last")
    }

    /// Topo's side in a red nothing else on the stage is drawn in, over a log of the person's
    /// turns alone: every red band down the picture is a reply the log does not hold.
    private static func replyLook() -> Look {
        var look = Self.look()
        look.plain.accent = Color(red: 1, green: 0, blue: 0)
        look.plain.fillOpacity = 1
        return look
    }

    private func said(_ count: Int) -> [Turn] {
        (1...count).map { n in
            Turn(ref: TurnRef(device: DeviceID("phone"), sequence: Int64(n)), parents: [], role: .person,
                 text: "Turn \(n), long enough to take a line or two of the transcript's width on a phone.",
                 at: Date(timeIntervalSince1970: 1_700_000_000 + Double(n)))
        }
    }

    private func redBands(_ image: UIImage) throws -> [(Int, Int)] {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width, height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bands: [(Int, Int)] = []
        for y in 0..<height {
            var red = false
            for x in 0..<width {
                let i = (y * width + x) * 4
                if bytes[i] > 220, bytes[i + 1] < 30, bytes[i + 2] < 30 { red = true; break }
            }
            guard red else { continue }
            if let last = bands.last, last.1 >= y - 2 { bands[bands.count - 1].1 = y } else { bands.append((y, y)) }
        }
        return bands
    }

    func testAnUnsavedReplyIsDrawnUnderTheRowAndUnderATurnOnItsWay() throws {
        let draft = Draft(text: .constant("call Helen"), typing: .constant(false), sending: true)
        let reply = UnsavedReply.turn("Calling her now.", place: 0)
        let none = TranscriptView(turns: said(3), draft: draft).background(Color.white)
        XCTAssertEqual(try redBands(try LookStage.image(none, look: Self.replyLook())).count, 0, "control: nothing of Topo's is drawn")
        let held = TranscriptView(turns: said(3), draft: draft, answer: reply).background(Color.white)
        XCTAssertEqual(try redBands(try LookStage.image(held, look: Self.replyLook())).count, 1, "the reply to the row's words is not drawn")
        let queued = TranscriptView(turns: said(3), draft: draft,
                                    queued: ([QueuedTurn(text: "and Krista", nonce: "older", reply: reply)],
                                             [QueuedTurn(text: "and book the flights", nonce: "newer", reply: UnsavedReply.turn("Booked.", place: 1))]))
            .background(Color.white)
        XCTAssertEqual(try redBands(try LookStage.image(queued, look: Self.replyLook())).count, 2, "the replies to turns on their way are not drawn")
    }

    /// The transcript under a model a test changes, as the chat's is under the harness.
    @Observable final class Shown {
        var answer: Turn?
        var queued: [QueuedTurn] = []
        var after: [QueuedTurn] = []
    }

    private struct Stage: View {
        let turns: [Turn]
        let shown: Shown
        var held = true
        var body: some View {
            let draft = Draft(text: .constant("call Helen"), typing: .constant(false), sending: true)
            TranscriptView(turns: turns, draft: held ? draft : nil, queued: (shown.queued, shown.after), answer: shown.answer)
                .background(Color.white)
        }
    }

    /// Whole on the stage: one band, clear of the stage's foot.
    private func assertOnScreen(_ bands: [(Int, Int)], _ image: UIImage, _ what: String, line: UInt = #line) {
        XCTAssertEqual(bands.count, 1, "\(what) is not on the screen", line: line)
        guard let band = bands.first, let height = image.cgImage?.height else { return }
        XCTAssertLessThan(band.1, height - 2, "\(what) runs under the fold", line: line)
    }

    func testAnUnsavedReplyArrivingUnderTheRowIsScrolledTo() throws {
        let shown = Shown()
        let image = try LookStage.image(Stage(turns: said(30), shown: shown), look: Self.replyLook(),
                                        then: [{ shown.answer = UnsavedReply.turn("Calling her now.", place: 0) }])
        assertOnScreen(try redBands(image), image, "a reply that arrived under the row")
    }

    func testAnUnsavedReplyGrowingUnderTheRowIsFollowed() throws {
        let shown = Shown()
        let long = (1...12).map { "Line \($0) of what the guest is writing, long enough to wrap." }.joined(separator: "\n")
        let image = try LookStage.image(Stage(turns: said(30), shown: shown), look: Self.replyLook(),
                                        then: [{ shown.answer = UnsavedReply.turn("Calling", place: 0) },
                                               { shown.answer = UnsavedReply.turn(long, place: 0) }])
        assertOnScreen(try redBands(image), image, "a reply that grew under the row")
    }

    func testAnUnsavedReplyArrivingUnderATurnOnItsWayIsScrolledTo() throws {
        let shown = Shown()
        shown.queued = [QueuedTurn(text: "and Krista", nonce: "older")]
        let image = try LookStage.image(Stage(turns: said(30), shown: shown, held: false), look: Self.replyLook(),
                                        then: [{ shown.queued = [QueuedTurn(text: "and Krista", nonce: "older",
                                                                            reply: UnsavedReply.turn("Calling her too.", place: 0))] }])
        assertOnScreen(try redBands(image), image, "a reply that arrived under a turn on its way")
    }

    /// The row holds a first message with a second on its way below it: as the reply to the
    /// first grows, the second stays on the screen, whole.
    func testAReplyGrowingUnderTheRowKeepsTheTurnBelowItOnTheScreen() throws {
        let long = (1...12).map { "Line \($0) of what the guest is writing, long enough to wrap." }.joined(separator: "\n")
        // The bubble of the turn below, as tall as it is drawn before the reply grows.
        func drawn(_ replies: [String]) throws -> (red: [(Int, Int)], blue: [(Int, Int)]) {
            let shown = Shown()
            shown.after = [QueuedTurn(text: "and book the flights", nonce: "newer")]
            let image = try LookStage.image(Stage(turns: said(30), shown: shown), look: Self.replyLook(),
                                            then: replies.map { text in { shown.answer = UnsavedReply.turn(text, place: 0) } })
            return (try redBands(image), try blueBands(image))
        }
        let before = try drawn(["Calling"]), after = try drawn(["Calling", long])
        let whole = try XCTUnwrap(before.blue.last, "control: the turn below is on the screen before the reply grows")
        let reply = try XCTUnwrap(after.red.last, "the growing reply is not on the screen")
        let below = try XCTUnwrap(after.blue.last, "no turn on its way is on the screen")
        XCTAssertGreaterThan(below.0, reply.1, "the turn below the reply is not on the screen")
        XCTAssertEqual(below.1 - below.0, whole.1 - whole.0, accuracy: 2, "the turn below the reply runs under the fold")
    }
}

