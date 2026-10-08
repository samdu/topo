import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The glass under the keyboard: the pane goes short and becomes a row, the microphone with it
/// in its leading end, and the microphone never goes out of reach. Held twice. As the arithmetic `ComposerGeometry` is, at
/// every combination of the ends of the ranges `look.json` reads the fields that bound
/// containment in: the new share, the well and the jewel set into it, the pane's width and both
/// of its insets. And as a composer laid out in a window the size of the smallest phone the app
/// runs on, where the well is the area a press lands in (`ComposerFrames.Well`, the frame the
/// gesture is on) and the pane is the edge of the glass (`ComposerFrames.Pane`), at the looks
/// among those whose resting pane fits on that screen: a 4000-point well or inset already spills
/// off the screen at rest, so hosting one proves nothing about the keyboard, and a window big
/// enough to hold it is a texture bigger than the renderer will make.
///
/// That a press at the short well's edge reaches the microphone is `TopoOnTheGlassTests`', which
/// raises the keyboard and presses it.
@MainActor
final class ComposerGeometryTests: XCTestCase {
    /// The smallest phone layout the iOS target supports: 320 by 568 points, which is also the
    /// width of an iPad's Slide Over column.
    private let narrowest = CGSize(width: 320, height: 568)

    /// The ends of `LookDocument`'s ranges for every field that bounds where the microphone is:
    /// `compactShare` 0.5 and 1, the well's size and the jewel's 8 and 4000 (with the default and
    /// the pressable floor between them, where the share and the floor meet), `widthFraction` 0.1
    /// and 1, and both insets 0 and 4000.
    static var extremes: [Look.Composer] {
        var all: [Look.Composer] = [Look.Composer()]
        for share in [0.5, 1] as [CGFloat] {
            for well in [8, Look.Composer.Well.pressable, 72, 4000] as [CGFloat] {
                for jewel in [8, 4000] as [CGFloat] {
                    for width in [0.1, 1] as [CGFloat] {
                        for horizontal in [0, 4000] as [CGFloat] {
                            for vertical in [0, 4000] as [CGFloat] {
                                var composer = Look.Composer()
                                composer.compactShare = share
                                composer.well.size = well
                                composer.well.jewelSize = jewel
                                composer.widthFraction = width
                                composer.horizontalInset = horizontal
                                composer.verticalInset = vertical
                                all.append(composer)
                            }
                        }
                    }
                }
            }
        }
        return all
    }

    /// The looks hosted in a window: the ends of the share, the width and the jewel as above, with
    /// the well at its floor, the pressable floor and the default, and both insets at nothing and
    /// at 100 points — every combination whose resting pane fits on the smallest phone.
    static var hosted: [Look.Composer] {
        var all: [Look.Composer] = [Look.Composer()]
        for share in [0.5, 1] as [CGFloat] {
            for well in [8, Look.Composer.Well.pressable, 72] as [CGFloat] {
                for jewel in [8, 4000] as [CGFloat] {
                    for width in [0.1, 1] as [CGFloat] {
                        for horizontal in [0, 100] as [CGFloat] {
                            for vertical in [0, 100] as [CGFloat] {
                                var composer = Look.Composer()
                                composer.compactShare = share
                                composer.well.size = well
                                composer.well.jewelSize = jewel
                                composer.widthFraction = width
                                composer.horizontalInset = horizontal
                                composer.verticalInset = vertical
                                all.append(composer)
                            }
                        }
                    }
                }
            }
        }
        return all
    }

    // MARK: The arithmetic

    /// At rest the microphone is drawn at its own size, and under the keyboard at the look's share
    /// of it: the well, the jewel and the room above and below it together.
    func testUnderTheKeyboardTheMicrophoneIsTheSharesSize() {
        let composer = Look.Composer()
        let rest = ComposerGeometry.of(composer, row: false)
        XCTAssertEqual(rest.scale, 1)
        XCTAssertEqual(rest.well, composer.well.size)
        XCTAssertEqual(rest.jewel, composer.well.jewelSize)
        XCTAssertEqual(rest.verticalInset, composer.verticalInset)

        let short = ComposerGeometry.of(composer, row: true)
        XCTAssertEqual(short.scale, 2.0 / 3, accuracy: 1e-9, "the default share is two thirds")
        XCTAssertEqual(short.well, composer.well.size * 2 / 3, accuracy: 1e-9)
        XCTAssertEqual(short.jewel, composer.well.jewelSize * 2 / 3, accuracy: 1e-9,
                       "the jewel is two thirds of its diameter at two thirds of the height")
        XCTAssertEqual(short.verticalInset, composer.verticalInset * 2 / 3, accuracy: 1e-9)
        XCTAssertEqual(short.well + 2 * short.verticalInset,
                       (rest.well + 2 * rest.verticalInset) * 2 / 3, accuracy: 1e-9,
                       "the pane is two thirds of its resting height where the well sets it")

        var other = composer
        other.compactShare = 0.8
        XCTAssertEqual(ComposerGeometry.of(other, row: true).scale, 0.8, accuracy: 1e-9,
                       "the look's share does not reach the geometry")
    }

    /// The short pane is the resting one scaled, so its corners are too: at rest the radius is the
    /// look's, and under the keyboard it is the look's at the same share as the well — two thirds
    /// by default, and wherever the pressable floor holds the well up, that share and not the
    /// look's — at every end of the ranges and at a radius of nothing and of a great deal.
    func testTheShortPanesCornerRadiusIsTheRestingOneAtTheShare() {
        let composer = Look.Composer()
        XCTAssertEqual(ComposerGeometry.of(composer, row: false).cornerRadius, composer.cornerRadius)
        XCTAssertEqual(ComposerGeometry.of(composer, row: true).cornerRadius, composer.cornerRadius * 2 / 3,
                       accuracy: 1e-9, "the default pane's corners are not two thirds of their radius")
        for var composer in Self.extremes {
            for radius in [0, 32, 4000] as [CGFloat] {
                composer.cornerRadius = radius
                let rest = ComposerGeometry.of(composer, row: false)
                let short = ComposerGeometry.of(composer, row: true)
                XCTAssertEqual(rest.cornerRadius, radius, "\(composer)")
                XCTAssertEqual(short.cornerRadius, radius * short.scale, accuracy: 1e-9, "\(composer)")
                XCTAssertEqual(short.cornerRadius * rest.well, rest.cornerRadius * short.well, accuracy: 1e-6,
                               "\(composer): the corners are not scaled as the well is")
            }
        }
    }

    /// Whatever the look says, the short well is no bigger than the resting one and no smaller
    /// than the pressable floor, or than the resting one where that is already under it; the
    /// jewel is inside the well at both heights; and the short pane is no taller than the resting
    /// one.
    func testTheShortMicrophoneIsNeverOutOfReach() {
        for composer in Self.extremes {
            let rest = ComposerGeometry.of(composer, row: false)
            let short = ComposerGeometry.of(composer, row: true)
            let floor = min(composer.well.size, Look.Composer.Well.pressable)
            XCTAssertLessThanOrEqual(short.well, rest.well + 1e-9, "\(composer)")
            XCTAssertGreaterThanOrEqual(short.well, floor - 1e-9, "\(composer): the short well is under the floor")
            XCTAssertGreaterThanOrEqual(short.well, composer.well.size * composer.compactShare - 1e-9, "\(composer)")
            for geometry in [rest, short] {
                XCTAssertLessThanOrEqual(geometry.jewel, geometry.well + 1e-9, "\(composer): the jewel is wider than its well")
                XCTAssertGreaterThan(geometry.scale, 0, "\(composer)")
                XCTAssertLessThanOrEqual(geometry.scale, 1, "\(composer)")
                XCTAssertTrue(geometry.well.isFinite && geometry.verticalInset.isFinite, "\(composer)")
            }
            XCTAssertLessThanOrEqual(short.verticalInset, rest.verticalInset + 1e-9, "\(composer)")
            XCTAssertEqual(short.slot, rest.slot, "\(composer): the well's width in the row changed")
            XCTAssertGreaterThanOrEqual(short.slot, short.well - 1e-9, "\(composer)")
            // The pane the well sets: never taller under the keyboard, and the well inside it.
            let restPane = rest.well + 2 * rest.verticalInset
            let shortPane = short.well + 2 * short.verticalInset
            XCTAssertLessThanOrEqual(shortPane, restPane + 1e-9, "\(composer): the pane grew under the keyboard")
            XCTAssertLessThanOrEqual(short.well, shortPane + 1e-9, "\(composer)")
            XCTAssertEqual(shortPane, restPane * short.scale, accuracy: 1e-6,
                           "\(composer): the pane is not the share the well is drawn at")
        }
    }

    // MARK: Laid out

    /// The pane and the well, as a composer lays them out in a window of the narrowest width, in
    /// the window's space.
    private func frames(_ composer: Look.Composer, row: Bool) throws -> (pane: CGRect, well: CGRect) {
        var look = Look()
        look.composer = composer
        look.composer.surface = .flat
        let probe = FrameProbe()
        let view = VStack(spacing: 0) {
            Spacer(minLength: 0)
            Composer(draft: Draft(text: .constant(""), typing: .constant(false), row: row))
                .overlayPreferenceValue(ComposerFrames.Pane.self) { pane in
                    GeometryReader { proxy in
                        Color.clear.onAppear { probe.pane = Self.global(pane, proxy) }
                            .onChange(of: Self.global(pane, proxy)) { _, rect in probe.pane = rect }
                    }
                }
                .overlayPreferenceValue(ComposerFrames.Well.self) { well in
                    GeometryReader { proxy in
                        Color.clear.onAppear { probe.well = Self.global(well, proxy) }
                            .onChange(of: Self.global(well, proxy)) { _, rect in probe.well = rect }
                    }
                }
        }
        .environment(\.look, look)
        .transaction { $0.animation = nil }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: narrowest)
        window.rootViewController = UIHostingController(rootView: view)
        window.isHidden = false
        defer { window.isHidden = true }
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        window.layoutIfNeeded()
        return (try XCTUnwrap(probe.pane, "\(composer): no pane was laid out"),
                try XCTUnwrap(probe.well, "\(composer): no well was laid out"))
    }

    // MARK: Typed

    /// What is typed into the field is the draft's in either of the pane's forms. With a hardware
    /// keyboard the pane is at rest for a moment after the field takes focus, and the first
    /// letter typed then makes the draft the transcript row's to draw: the letters after it are
    /// still the field's to write, each of them, and the field is not emptied under them.
    func testEveryLetterTypedIsTheDraftsWhateverFormThePaneIsIn() throws {
        for row in [false, true] {
            for held in ["", "bins on Tuesday"] {
                let typed = try typing("hi there", over: held, row: row)
                XCTAssertEqual(typed.draft, held + "hi there", "row \(row), over \"\(held)\": letters typed did not reach the draft")
                XCTAssertEqual(typed.field, held + "hi there", "row \(row), over \"\(held)\": the field does not hold what was typed into it")
            }
        }
    }

    /// The draft and the field's own text once `letters` have been typed, one at a time, into a
    /// composer whose field holds focus over `held`.
    private func typing(_ letters: String, over held: String, row: Bool) throws -> (draft: String, field: String) {
        final class Written { var text = "" }
        struct Stage: View {
            let written: Written
            let row: Bool
            @State var text: String
            var body: some View {
                Composer(draft: Draft(text: $text, typing: .constant(true), row: row))
                    .onChange(of: text, initial: true) { _, text in written.text = text }
            }
        }
        var look = Look()
        look.composer.surface = .flat
        let written = Written()
        let view = VStack(spacing: 0) {
            Spacer(minLength: 0)
            Stage(written: written, row: row, text: held)
        }
        .environment(\.look, look)
        .transaction { $0.animation = nil }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: narrowest)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let settle = { window.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        settle()
        func find(_ view: UIView) -> UITextView? {
            (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let field = try XCTUnwrap(find(window), "no text view in the composer")
        XCTAssertTrue(field.isFirstResponder || field.becomeFirstResponder(), "the field would not take focus")
        settle()
        field.selectedRange = NSRange(location: (field.text as NSString).length, length: 0)
        for letter in letters {
            field.insertText(String(letter))
            settle()
        }
        defer { field.resignFirstResponder() }
        return (written.text, field.text)
    }

    /// An anchor's rectangle in the window's space, so the resting and the short layouts, whose
    /// composers are of different heights, are compared on one set of axes.
    private static func global(_ anchor: Anchor<CGRect>?, _ proxy: GeometryProxy) -> CGRect? {
        guard let anchor else { return nil }
        let origin = proxy.frame(in: .global).origin
        return proxy[anchor].offsetBy(dx: origin.x, dy: origin.y)
    }

    private final class FrameProbe {
        var pane: CGRect?
        var well: CGRect?
    }

    /// Laid out, at every hosted look: the short well is the geometry's size, is never under the
    /// pressable floor, sits inside the short pane from top to foot, and is inside its leading
    /// end wherever the pane is as wide as the well. The short pane is no taller than the resting
    /// one where the well is what sets its height, sits on the same foot, is the width the
    /// geometry gives the row, and is centred where the resting one is.
    func testTheShortWellIsInsideTheShortPaneOnTheSmallestPhone() throws {
        for composer in Self.hosted {
            let rest = try frames(composer, row: false)
            let short = try frames(composer, row: true)
            let geometry = ComposerGeometry.of(composer, row: true)
            let floor = min(composer.well.size, Look.Composer.Well.pressable)

            XCTAssertEqual(short.well.width, geometry.well, accuracy: 0.5, "\(composer): the well is not the geometry's")
            XCTAssertEqual(short.well.height, geometry.well, accuracy: 0.5, "\(composer)")
            XCTAssertGreaterThanOrEqual(short.well.width, floor - 0.5, "\(composer): the short well is under the floor")

            XCTAssertGreaterThanOrEqual(short.well.minY, short.pane.minY - 0.5, "\(composer): the well is over the pane's top")
            XCTAssertLessThanOrEqual(short.well.maxY, short.pane.maxY + 0.5, "\(composer): the well is under the pane's foot")
            XCTAssertGreaterThanOrEqual(short.well.minX, short.pane.minX - 0.5, "\(composer): the well is past the pane's leading end")
            if short.pane.width >= short.well.width {
                XCTAssertLessThanOrEqual(short.well.maxX, short.pane.maxX + 0.5, "\(composer): the well left the pane")
            }
            XCTAssertEqual(short.pane.maxY, rest.pane.maxY, accuracy: 0.5, "\(composer): the pane left its foot")
            let width = ComposerGeometry.width(composer, column: Look().transcript.maximumLineWidth,
                                               in: narrowest.width, row: true)
            XCTAssertEqual(short.pane.width, width, accuracy: 0.5, "\(composer): the row is not the width the geometry gives it")
            XCTAssertEqual(short.pane.midX, rest.pane.midX, accuracy: 0.5, "\(composer): the pane moved sideways")
        }
    }

    /// The default look, laid out: the well goes to two thirds of its size, set into the pane's
    /// leading end at the look's inset, and the pane is as tall as the taller of the short well in
    /// its insets and one line of the field in its enclosure — which at the default type is the
    /// line, a point or two over two thirds of the resting height.
    func testTheDefaultPaneGoesToTwoThirdsWithTheWellInItsLeadingEnd() throws {
        let rest = try frames(Look.Composer(), row: false)
        let short = try frames(Look.Composer(), row: true)
        XCTAssertGreaterThanOrEqual(short.pane.height, rest.pane.height * 2 / 3 - 0.5)
        XCTAssertLessThan(short.pane.height, rest.pane.height * 3 / 4, "a row of one line is nearly as tall as the pane at rest")
        XCTAssertEqual(short.well.width, rest.well.width * 2 / 3, accuracy: 0.5)
        XCTAssertEqual(rest.well.midX, rest.pane.midX, accuracy: 0.5, "the resting well is not in the middle of the glass")
        XCTAssertEqual(short.well.midX, short.pane.minX + Look.Composer().jewelInset, accuracy: 0.5,
                       "the row's well is not the look's inset from the pane's leading end")
        XCTAssertEqual(short.well.midY, short.pane.midY, accuracy: 1, "the well is not level with a row of one line")
    }
}

/// Where everything in the pane stands in each form (`ComposerPlan`), as arithmetic, at the
/// look's defaults and at the ends of the ranges `look.json` reads the row's fields in.
@MainActor
final class ComposerPlanTests: XCTestCase {
    private let line: CGFloat = 40
    private let marks: CGFloat = 36

    private func row(_ look: Look = Look(), screen: CGFloat, lines: CGFloat = 1) -> ComposerPlan {
        let geometry = ComposerGeometry.of(look.composer, row: true)
        let width = ComposerGeometry.width(look.composer, column: look.transcript.maximumLineWidth, in: screen, row: true)
        return ComposerPlan.row(look.composer, draft: look.draft, geometry: geometry, width: width,
                                marks: marks, line: line) { _ in self.line * lines }
    }

    /// The row's own share of the screen, and no wider than the transcript's column; the resting
    /// pane its own share whatever the column.
    func testTheRowIsItsShareOfTheScreenAndNoWiderThanTheColumn() {
        let composer = Look.Composer()
        XCTAssertEqual(ComposerGeometry.width(composer, column: .infinity, in: 400, row: true), 400 * 0.93, accuracy: 1e-9)
        XCTAssertEqual(ComposerGeometry.width(composer, column: 700, in: 1024, row: true), 700)
        XCTAssertEqual(ComposerGeometry.width(composer, column: 700, in: 400, row: true), 400 * 0.93, accuracy: 1e-9)
        XCTAssertEqual(ComposerGeometry.width(composer, column: 700, in: 1024, row: false), 1024 * 0.8, accuracy: 1e-9)
        var other = composer
        other.typingWidthFraction = 0.5
        XCTAssertEqual(ComposerGeometry.width(other, column: .infinity, in: 400, row: true), 200)
        XCTAssertEqual(ComposerGeometry.width(other, column: .infinity, in: 400, row: false), 320)
    }

    /// On an ordinary phone the look's values stand as given: the jewel's middle its inset from
    /// the leading end, the control the spacing past the well's edge, the send the spacing in
    /// from the trailing end, and the field between them, clear of each by the draft's spacing.
    func testTheRowStandsWhereTheLookSaysOnAPhone() {
        let look = Look()
        let plan = row(screen: 393)
        let half = ComposerGeometry.of(look.composer, row: true).well / 2
        XCTAssertEqual(plan.size.width, 393 * 0.93, accuracy: 1e-9)
        XCTAssertEqual(plan.well.midX, look.composer.jewelInset, accuracy: 1e-9)
        XCTAssertEqual(plan.more.x, look.composer.jewelInset + half + look.composer.spacing, accuracy: 1e-9)
        XCTAssertEqual(plan.send.x, plan.size.width - look.composer.spacing, accuracy: 1e-9)
        XCTAssertEqual(plan.field.minX, plan.more.x + look.composer.flank.slot / 2 + look.draft.spacing, accuracy: 1e-9)
        XCTAssertEqual(plan.field.maxX, plan.send.x - look.draft.slot / 2 - look.draft.spacing, accuracy: 1e-9)
        XCTAssertGreaterThan(plan.field.width, look.draft.minimumWidth)
        for x in [plan.well.midY, plan.more.y, plan.send.y, plan.field.midY] {
            XCTAssertEqual(x, plan.size.height / 2, accuracy: 1e-9, "a row of one line is not level")
        }
    }

    /// On the narrowest phone the field would be under its minimum, so the spacing yields, as far
    /// as it takes and no further, and the jewel's inset and the room either side of the field
    /// stand: the field is its minimum exactly.
    func testOnTheNarrowestPhoneTheSpacingYieldsAndTheFieldKeepsItsMinimum() {
        let look = Look()
        let plan = row(screen: 320)
        let half = ComposerGeometry.of(look.composer, row: true).well / 2
        XCTAssertEqual(plan.field.width, look.draft.minimumWidth, accuracy: 1e-9)
        XCTAssertEqual(plan.well.midX, look.composer.jewelInset, accuracy: 1e-9, "the inset yielded before the spacing ran out")
        XCTAssertEqual(plan.field.minX - plan.more.x, look.composer.flank.slot / 2 + look.draft.spacing, accuracy: 1e-9,
                       "the room beside the field yielded before the spacing ran out")
        XCTAssertLessThan(plan.more.x - plan.well.maxX, look.composer.spacing)
        XCTAssertGreaterThanOrEqual(plan.more.x - plan.well.maxX, look.composer.flank.slot / 2 - 1e-9)
        XCTAssertGreaterThanOrEqual(plan.well.minX, -1e-9)
        XCTAssertEqual(plan.well.midX, max(look.composer.jewelInset, half), accuracy: 1e-9)
    }

    /// The order things yield in: the spacing first, then the jewel's inset, then the room either
    /// side of the field, and only a pane narrower than all of that takes the field under its
    /// minimum.
    func testTheLooksValuesYieldInOrder() {
        var look = Look()
        look.composer.typingWidthFraction = 1
        let geometry = ComposerGeometry.of(look.composer, row: true)
        let half = geometry.well / 2
        let least = ComposerPlan.least(look.composer, draft: look.draft, geometry: geometry)
        let spacing = (look.composer.spacing - look.composer.flank.slot / 2) + (look.composer.spacing - look.draft.slot / 2)
        let inset = look.composer.jewelInset - half
        let gaps = 2 * look.draft.spacing

        let whole = row(look, screen: least)
        XCTAssertEqual(whole.field.width, look.draft.minimumWidth, accuracy: 1e-9)
        XCTAssertEqual(whole.send.x, least - look.composer.spacing, accuracy: 1e-9, "something yielded with room for everything")

        let noSpacing = row(look, screen: least - spacing)
        XCTAssertEqual(noSpacing.field.width, look.draft.minimumWidth, accuracy: 1e-9)
        XCTAssertEqual(noSpacing.well.midX, look.composer.jewelInset, accuracy: 1e-9)
        XCTAssertEqual(noSpacing.more.x - noSpacing.well.maxX, look.composer.flank.slot / 2, accuracy: 1e-9)
        XCTAssertEqual(noSpacing.size.width - noSpacing.send.x, look.draft.slot / 2, accuracy: 1e-9)

        let noInset = row(look, screen: least - spacing - inset)
        XCTAssertEqual(noInset.field.width, look.draft.minimumWidth, accuracy: 1e-9)
        XCTAssertEqual(noInset.well.minX, 0, accuracy: 1e-9, "the well is not at the pane's very end")
        XCTAssertEqual(noInset.field.minX - noInset.more.x, look.composer.flank.slot / 2 + look.draft.spacing, accuracy: 1e-9)

        let noGaps = row(look, screen: least - spacing - inset - gaps)
        XCTAssertEqual(noGaps.field.width, look.draft.minimumWidth, accuracy: 1e-9)
        XCTAssertEqual(noGaps.field.minX - noGaps.more.x, look.composer.flank.slot / 2, accuracy: 1e-9)

        let under = row(look, screen: least - spacing - inset - gaps - 30)
        XCTAssertEqual(under.field.width, look.draft.minimumWidth - 30, accuracy: 1e-9,
                       "only a pane with nothing left to yield takes the field under its minimum")
    }

    /// What is written past one line grows the field and the pane upward: the well, the control
    /// and the send stay where they were above the pane's foot, and the field keeps the same room
    /// above it as below.
    func testWhatIsWrittenGrowsThePaneUpward() {
        let one = row(screen: 393)
        let five = row(screen: 393, lines: 5)
        XCTAssertEqual(five.size.height, one.size.height + 4 * line, accuracy: 1e-9)
        XCTAssertEqual(five.field.height, 5 * line, accuracy: 1e-9)
        XCTAssertEqual(five.field.minY, five.size.height - five.field.maxY, accuracy: 1e-9)
        for (grown, short) in [(five.well.midY, one.well.midY), (five.more.y, one.more.y), (five.send.y, one.send.y)] {
            XCTAssertEqual(five.size.height - grown, one.size.height - short, accuracy: 1e-9,
                           "something left the pane's bottom line as the field grew")
        }
        XCTAssertEqual(five.well.minX, one.well.minX)
        XCTAssertEqual(five.field.width, one.field.width)
    }

    /// At every end of the ranges the row's fields are read in, on the narrowest phone and on a
    /// pad: every number is finite, the well is inside the pane's leading end and inside the pane
    /// top to foot, no control stands over its neighbour or past the pane's trailing end, and
    /// wherever the pane is wide enough to hold the row the field has its minimum.
    func testAtEveryEndOfTheRangesNothingOverlapsOrLeavesThePane() {
        for screen in [320, 1366] as [CGFloat] {
            for fraction in [0.1, 1] as [CGFloat] {
                for well in [8, 72, 4000] as [CGFloat] {
                    for spacing in [0, 4000] as [CGFloat] {
                        for inset in [0, 200] as [CGFloat] {
                            for slot in [8, 4000] as [CGFloat] {
                                for gap in [0, 4000] as [CGFloat] {
                                    for minimum in [0, 160, 4000] as [CGFloat] {
                                        var look = Look()
                                        look.composer.typingWidthFraction = fraction
                                        look.composer.well.size = well
                                        look.composer.spacing = spacing
                                        look.composer.jewelInset = inset
                                        look.composer.flank.slot = slot
                                        look.draft.slot = slot
                                        look.draft.spacing = gap
                                        look.draft.minimumWidth = minimum
                                        check(row(look, screen: screen, lines: 3), look, "\(screen) \(fraction) \(well) \(spacing) \(inset) \(slot) \(gap) \(minimum)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func check(_ plan: ComposerPlan, _ look: Look, _ what: String) {
        let geometry = ComposerGeometry.of(look.composer, row: true)
        let numbers = [plan.size.width, plan.size.height, plan.well.minX, plan.well.minY, plan.well.width, plan.more.x, plan.more.y,
                       plan.field.minX, plan.field.minY, plan.field.width, plan.field.height, plan.send.x, plan.send.y]
        XCTAssertTrue(numbers.allSatisfy(\.isFinite), "\(what): \(plan)")
        XCTAssertGreaterThanOrEqual(plan.well.minX, -1e-6, "\(what): the well is past the pane's leading end")
        XCTAssertGreaterThanOrEqual(plan.well.minY, -1e-6, "\(what): the well is over the pane's top")
        XCTAssertLessThanOrEqual(plan.well.maxY, plan.size.height + 1e-6, "\(what): the well is under the pane's foot")
        XCTAssertGreaterThanOrEqual(plan.more.x - look.composer.flank.slot / 2, plan.well.maxX - 1e-6, "\(what): the control is over the well")
        XCTAssertGreaterThanOrEqual(plan.field.minX, plan.more.x + look.composer.flank.slot / 2 - 1e-6, "\(what): the field is under the control")
        XCTAssertGreaterThanOrEqual(plan.field.width, 0, what)
        XCTAssertLessThanOrEqual(plan.send.x + look.draft.slot / 2, plan.size.width + 1e-6, "\(what): the send is past the pane's end")
        if plan.field.width > 0 {
            XCTAssertLessThanOrEqual(plan.field.maxX, plan.send.x - look.draft.slot / 2 + 1e-6, "\(what): the field is under the send")
        }
        XCTAssertGreaterThanOrEqual(plan.field.minY, -1e-6, what)
        XCTAssertLessThanOrEqual(plan.field.maxY, plan.size.height + 1e-6, what)
        if plan.size.width >= ComposerPlan.least(look.composer, draft: look.draft, geometry: geometry) {
            XCTAssertGreaterThanOrEqual(plan.field.width, look.draft.minimumWidth - 1e-6, "\(what): the field is under its minimum with room for it")
        }
    }

    /// At rest the well is in the middle, the control for everything else in the middle of the
    /// leading flank's inner half, and the way to the keyboard its mirror across the well.
    func testAtRestTheTwoControlsMirrorEachOtherAcrossTheWell() {
        let composer = Look.Composer()
        let geometry = ComposerGeometry.of(composer, row: false)
        let plan = ComposerPlan.resting(composer, geometry: geometry, width: 320, marks: marks, line: line)
        XCTAssertEqual(plan.size.height, composer.well.size + 2 * composer.verticalInset)
        XCTAssertEqual(plan.well.midX, 160)
        XCTAssertEqual(plan.well.midY, plan.size.height / 2)
        XCTAssertEqual(plan.more.x + plan.keyboard.x, 320, accuracy: 1e-9)
        let inner = 160 - composer.well.size / 2 - composer.spacing
        XCTAssertEqual(plan.more.x, inner - (inner - composer.horizontalInset) / 4, accuracy: 1e-9)
        XCTAssertLessThan(plan.more.x, plan.well.minX)
        XCTAssertGreaterThan(plan.more.x, (inner + composer.horizontalInset) / 2, "the control is not in the flank's inner half")
    }

    /// The keyboard on screen is the row; so is the field holding focus once no keyboard has
    /// come for it, and not before.
    func testTheFormIsTheKeyboardOrFocusLeftAlone() {
        XCTAssertTrue(ComposerForm.isRow(keyboard: true, focused: true, alone: false))
        XCTAssertTrue(ComposerForm.isRow(keyboard: true, focused: false, alone: false),
                      "the keyboard still on screen as it falls is still the row")
        XCTAssertFalse(ComposerForm.isRow(keyboard: false, focused: true, alone: false),
                       "focus alone is the row before a keyboard has had the time to come")
        XCTAssertTrue(ComposerForm.isRow(keyboard: false, focused: true, alone: true))
        XCTAssertFalse(ComposerForm.isRow(keyboard: false, focused: false, alone: true))
        XCTAssertFalse(ComposerForm.isRow(keyboard: false, focused: false, alone: false))
    }
}
