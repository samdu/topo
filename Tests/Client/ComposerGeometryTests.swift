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

    // MARK: The room to grow in

    /// The lines a field takes are the look's and no more than the room holds: a row of one
    /// line is the band, each line more is a line, and there is always one.
    func testTheFieldsLinesAreTheLooksAndNoMoreThanTheRoomHolds() {
        XCTAssertEqual(ComposerPlan.lines(most: 20, room: 288, band: 64, line: 20), 12)
        XCTAssertEqual(ComposerPlan.lines(most: 5, room: 288, band: 64, line: 20), 5, "the room gave more lines than the look")
        XCTAssertEqual(ComposerPlan.lines(most: 20, room: 64, band: 64, line: 20), 1)
        XCTAssertEqual(ComposerPlan.lines(most: 20, room: 10, band: 64, line: 20), 1, "a room under one row left no line to type in")
        XCTAssertEqual(ComposerPlan.lines(most: 20, room: -.infinity, band: 64, line: 20), 20)
        XCTAssertEqual(ComposerPlan.lines(most: 20, room: .nan, band: 64, line: 20), 20)
        XCTAssertEqual(ComposerPlan.lines(most: 20, room: .infinity, band: 64, line: 20), 20)
        XCTAssertEqual(ComposerPlan.lines(most: 20, room: 288, band: 64, line: 0), 20)
        XCTAssertEqual(ComposerPlan.lines(most: 0, room: 288, band: 64, line: 20), 1)
        for lines in 1...20 {
            let fit = ComposerPlan.lines(most: lines, room: 288, band: 64, line: 20)
            XCTAssertLessThanOrEqual(64 + CGFloat(fit - 1) * 20, 288, "\(lines): the pane is taller than its room")
        }
    }

    /// The room is the column's height, and within one state of the keyboard and one width it
    /// only shrinks: a pane that outgrows the column pushes the column's edges out, and a room
    /// that followed it would let the pane grow again.
    func testTheRoomOnlyShrinksUntilTheKeyboardOrTheWidthChanges() {
        let up = ChatView.Room(tall: 423, wide: 402, keyboard: true)
        XCTAssertEqual(up.taken(after: ChatView.Room(tall: 724, wide: 402, keyboard: false), held: 724), 423)
        XCTAssertEqual(ChatView.Room(tall: 436, wide: 402, keyboard: true).taken(after: up, held: 423), 423,
                       "a column pushed out by the pane gave the pane more room")
        XCTAssertEqual(ChatView.Room(tall: 400, wide: 402, keyboard: true).taken(after: up, held: 423), 400)
        XCTAssertEqual(ChatView.Room(tall: 724, wide: 402, keyboard: false).taken(after: up, held: 423), 724,
                       "the keyboard gone left the room it had left")
        XCTAssertEqual(ChatView.Room(tall: 500, wide: 874, keyboard: true).taken(after: up, held: 423), 500)
        XCTAssertEqual(up.taken(after: up, held: nil), 423)
    }

    /// On the smallest screen, 320 by 568, with a keyboard up and the look's most lines at the
    /// most the reader takes, a draft longer than all of them leaves the pane inside the room
    /// between the navigation bar and the keyboard, with every word still the field's. Without
    /// the room the same draft is a pane taller than it, which is what the bound is for.
    func testADraftOfTheMostLinesLeavesThePaneInsideTheRoomAboveTheKeyboard() throws {
        // The screen, less the status bar, the navigation bar and a keyboard with its bar.
        let room: CGFloat = 568 - 20 - 44 - 260
        let words = String(repeating: "and then the bins, the plants on the stairs and the post, ", count: 40)
        var look = Look()
        look.composer.surface = .flat
        look.draft.maximumLines = Look.Draft.lines.upperBound
        func pane(room: CGFloat?) throws -> (height: CGFloat, field: String) {
            let probe = FrameProbe()
            let view = VStack(spacing: 0) {
                Spacer(minLength: 0)
                Composer(draft: Draft(text: .constant(words), typing: .constant(true), row: true), room: room)
                    .overlayPreferenceValue(ComposerFrames.Pane.self) { pane in
                        GeometryReader { proxy in
                            Color.clear.onAppear { probe.pane = Self.global(pane, proxy) }
                                .onChange(of: Self.global(pane, proxy)) { _, rect in probe.pane = rect }
                        }
                    }
            }
            .environment(\.look, look)
            .transaction { $0.animation = nil }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
            window.rootViewController = UIHostingController(rootView: view)
            window.isHidden = false
            defer { window.isHidden = true }
            for _ in 0..<4 { window.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            func find(_ view: UIView) -> UITextView? {
                (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first
            }
            return (try XCTUnwrap(probe.pane, "no pane was laid out").height, try XCTUnwrap(find(window)).text)
        }
        let bounded = try pane(room: room)
        XCTAssertLessThanOrEqual(bounded.height, room, "the pane grew past the room above the keyboard")
        XCTAssertGreaterThan(bounded.height, room / 2, "the pane did not grow into the room it has")
        XCTAssertEqual(bounded.field, words, "words past the field's lines are not the field's")
        let unbounded = try pane(room: nil)
        XCTAssertGreaterThan(unbounded.height, room, "twenty lines fit the room, so this holds nothing")
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

    /// A field holding focus keeps it when the pane goes to rest under it — a keyboard leaving a
    /// field still being typed in — so the pane can take the focus as its row again, and what is
    /// typed meanwhile lands. A field that does not hold focus takes no touch at rest.
    func testAFieldHoldingFocusKeepsItWhenThePaneGoesToRest() throws {
        final class Form: ObservableObject {
            @Published var row = true
            /// What the composer has said of its field's focus, in order.
            var heard: [Bool] = []
            /// How tall the pane is laid out, which is which form it is in.
            var tall: CGFloat?
        }
        struct Stage: View {
            @ObservedObject var form: Form
            @State var text = "Hello"
            var body: some View {
                Composer(draft: Draft(text: $text, typing: .constant(true), row: form.row),
                         focused: { form.heard.append($0) })
                    .overlayPreferenceValue(ComposerFrames.Pane.self) { pane in
                        GeometryReader { proxy in
                            let tall = pane.map { proxy[$0].height }
                            Color.clear.onChange(of: tall, initial: true) { _, tall in form.tall = tall }
                        }
                    }
            }
        }
        var look = Look()
        look.composer.surface = .flat
        let form = Form()
        let view = VStack(spacing: 0) {
            Spacer(minLength: 0)
            Stage(form: form)
        }
        .environment(\.look, look)
        .transaction { $0.animation = nil }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: narrowest)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let settle = { window.layoutIfNeeded(); RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        settle()
        func find(_ view: UIView) -> UITextView? {
            (view as? UITextView) ?? view.subviews.lazy.compactMap(find).first
        }
        let field = try XCTUnwrap(find(window), "no text view in the composer")
        XCTAssertTrue(field.isFirstResponder || field.becomeFirstResponder(), "the field would not take focus")
        defer { field.resignFirstResponder() }
        // The composer knows its field holds focus before the pane is put to rest, as it does
        // by the time a keyboard leaves a field somebody is typing in: the focus the text view
        // has reaches the view's own state a turn of the run loop later, and on a slow machine
        // later than that.
        let known = Date().addingTimeInterval(20)
        while form.heard.last != true, Date() < known { settle() }
        XCTAssertEqual(form.heard.last, true, "the composer never heard that its field holds focus: \(form.heard)")
        XCTAssertTrue(field.isFirstResponder, "the field lost focus before the pane was put to rest")

        var ended = 0
        let watching = NotificationCenter.default.addObserver(forName: UITextView.textDidEndEditingNotification,
                                                              object: field, queue: nil) { _ in ended += 1 }
        defer { NotificationCenter.default.removeObserver(watching) }
        // The pane at rest is laid out before anything is asked of the field: on a slow machine
        // five turns of the run loop can pass before the row is gone, and a field in a row
        // keeps its focus whatever this test is for.
        let row = try XCTUnwrap(form.tall, "no pane was laid out")
        form.row = false
        let rested = Date().addingTimeInterval(20)
        while form.tall == row, Date() < rested { settle() }
        XCTAssertNotEqual(form.tall, row, "the pane never went to rest")
        for _ in 0..<5 { settle() }
        let open = sequence(first: field as UIView, next: \.superview).allSatisfy(\.isUserInteractionEnabled)
        XCTAssertTrue(open, "the pane going to rest took the touches from a field that holds focus")
        XCTAssertTrue(field.isFirstResponder, """
            the pane going to rest took the keyboard from a field being typed in: editing ended \(ended) times, \
            the window is key \(window.isKeyWindow), the composer heard \(form.heard)
            """)
        field.insertText("!")
        settle()
        XCTAssertEqual(field.text, "Hello!", "what was typed at rest did not land")

        field.resignFirstResponder()
        for _ in 0..<3 { settle() }
        let closed = sequence(first: field as UIView, next: \.superview).contains { !$0.isUserInteractionEnabled }
        XCTAssertTrue(closed, "a field at rest and out of focus takes touches")
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
            let width = ComposerGeometry.width(composer, draft: Look().draft, column: Look().transcript.maximumLineWidth,
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
        let width = ComposerGeometry.width(look.composer, draft: look.draft, column: look.transcript.maximumLineWidth, in: screen, row: true)
        return ComposerPlan.row(look.composer, draft: look.draft, geometry: geometry, width: width,
                                marks: marks, line: line) { _ in self.line * lines }
    }

    /// The row's own share of the screen, and no wider than the transcript's column; the resting
    /// pane its own share whatever the column.
    func testTheRowIsItsShareOfTheScreenAndNoWiderThanTheColumn() {
        let composer = Look.Composer()
        XCTAssertEqual(ComposerGeometry.width(composer, draft: Look().draft, column: .infinity, in: 400, row: true), 400 * 0.93, accuracy: 1e-9)
        XCTAssertEqual(ComposerGeometry.width(composer, draft: Look().draft, column: 700, in: 1024, row: true), 700)
        XCTAssertEqual(ComposerGeometry.width(composer, draft: Look().draft, column: 700, in: 400, row: true), 400 * 0.93, accuracy: 1e-9)
        XCTAssertEqual(ComposerGeometry.width(composer, draft: Look().draft, column: 700, in: 1024, row: false), 1024 * 0.8, accuracy: 1e-9)
        var other = composer
        other.typingWidthFraction = 0.5
        XCTAssertEqual(ComposerGeometry.width(other, draft: Look().draft, column: .infinity, in: 800, row: true), 400)
        XCTAssertEqual(ComposerGeometry.width(other, draft: Look().draft, column: .infinity, in: 400, row: false), 320)
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

    /// A look's share of the screen is a wish: the row is never narrower than what holds the
    /// well, the control, the field at its least and the send side by side, and never wider than
    /// the screen. At the least share the reader takes, on the narrowest phone, the send is
    /// clear of the well and the field has its minimum; where the screen cannot hold the
    /// field's minimum the field has what there is.
    func testTheRowIsNeverNarrowerThanWhatItHoldsNorWiderThanTheScreen() {
        var look = Look()
        look.composer.typingWidthFraction = 0.1
        let geometry = ComposerGeometry.of(look.composer, row: true)
        let floor = ComposerPlan.floor(look.composer, draft: look.draft, geometry: geometry, row: true)
        XCTAssertLessThan(floor, 320, "the default row does not fit the narrowest phone")
        let narrow = row(look, screen: 320)
        XCTAssertEqual(narrow.size.width, floor, accuracy: 1e-9, "a tenth of the screen is narrower than the row")
        check(narrow, look, "a tenth of 320")
        XCTAssertGreaterThanOrEqual(narrow.field.width, look.draft.minimumWidth - 1e-6)
        XCTAssertGreaterThan(narrow.send.x - narrow.sendSlot / 2, narrow.well.maxX, "the send is over the well")

        look.draft.minimumWidth = 4000
        let wide = row(look, screen: 320)
        XCTAssertEqual(wide.size.width, 320, "the row is wider than the screen")
        check(wide, look, "a field of 4000 on 320")
        XCTAssertGreaterThan(wide.field.width, 0, "the field has none of the width the screen has")

        // The column caps a share, and not the floor.
        look = Look()
        XCTAssertEqual(ComposerGeometry.width(look.composer, draft: look.draft, column: 10, in: 1024, row: true),
                       ComposerPlan.floor(look.composer, draft: look.draft, geometry: geometry, row: true), accuracy: 1e-9)
    }

    /// Each field of the row's own, at each end of the range it is read in, with the rest of the
    /// look as it is, on the narrowest phone: the well, the control, the field and the send are
    /// in order, apart and inside the pane, and the field has width.
    func testAtEachEndOfEachOfTheRowsRangesTheNarrowestPhoneHoldsTheRow() {
        let ends: [(String, (inout Look, CGFloat) -> Void, [CGFloat])] = [
            ("composer.typingWidthFraction", { $0.composer.typingWidthFraction = $1 }, [0.1, 1]),
            ("composer.jewelInset", { $0.composer.jewelInset = $1 }, [0, 200]),
            ("composer.flank.slot", { $0.composer.flank.slot = $1 }, [8, 4000]),
            ("draft.slot", { $0.draft.slot = $1 }, [8, 4000]),
        ]
        for (name, set, values) in ends {
            for value in values {
                var look = Look()
                set(&look, value)
                let plan = row(look, screen: 320, lines: 20)
                check(plan, look, "\(name) \(value)")
                XCTAssertLessThanOrEqual(plan.size.width, 320, "\(name) \(value): the row is wider than the screen")
                XCTAssertLessThanOrEqual(plan.well.maxX, plan.more.x - plan.moreSlot / 2 + 1e-6, "\(name) \(value)")
                XCTAssertGreaterThanOrEqual(plan.send.x - plan.sendSlot / 2, plan.field.maxX - 1e-6, "\(name) \(value)")
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
        // The control and the send are held in the room the plan gives each, which is the look's
        // slot wherever the row can hold the well and both.
        XCTAssertLessThanOrEqual(plan.moreSlot, look.composer.flank.slot + 1e-6, what)
        XCTAssertLessThanOrEqual(plan.sendSlot, look.draft.slot + 1e-6, what)
        if plan.size.width >= geometry.well + look.composer.flank.slot + look.draft.slot {
            XCTAssertEqual(plan.moreSlot, look.composer.flank.slot, accuracy: 1e-6, "\(what): the control's room yielded with room for it")
            XCTAssertEqual(plan.sendSlot, look.draft.slot, accuracy: 1e-6, "\(what): the send's room yielded with room for it")
        }
        XCTAssertGreaterThanOrEqual(plan.more.x - plan.moreSlot / 2, plan.well.maxX - 1e-6, "\(what): the control is over the well")
        XCTAssertGreaterThanOrEqual(plan.field.minX, plan.more.x + plan.moreSlot / 2 - 1e-6, "\(what): the field is under the control")
        XCTAssertGreaterThanOrEqual(plan.field.width, 0, what)
        XCTAssertLessThanOrEqual(plan.send.x + plan.sendSlot / 2, plan.size.width + 1e-6, "\(what): the send is past the pane's end")
        // In order whatever the field's width, none included: the send is never over the field,
        // the control or the well, wherever the pane holds the well at all — a well wider than
        // the screen, which its own range allows, leaves no pane beside it.
        if geometry.well <= plan.size.width {
            XCTAssertLessThanOrEqual(plan.field.maxX, plan.send.x - plan.sendSlot / 2 + 1e-6, "\(what): the field is under the send")
            XCTAssertLessThanOrEqual(plan.more.x + plan.moreSlot / 2, plan.send.x - plan.sendSlot / 2 + 1e-6, "\(what): the send is over the control")
            XCTAssertLessThanOrEqual(plan.well.maxX, plan.size.width + 1e-6, "\(what): the well is past the pane's trailing end")
            XCTAssertLessThanOrEqual(plan.well.maxX, plan.send.x - plan.sendSlot / 2 + 1e-6, "\(what): the send is over the well")
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
