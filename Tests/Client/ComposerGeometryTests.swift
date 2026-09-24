import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The glass under the keyboard: the pane goes short and the microphone with it, and the
/// microphone never goes out of reach. Held twice. As the arithmetic `ComposerGeometry` is, at
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
        let rest = ComposerGeometry.of(composer, keyboard: false)
        XCTAssertEqual(rest.scale, 1)
        XCTAssertEqual(rest.well, composer.well.size)
        XCTAssertEqual(rest.jewel, composer.well.jewelSize)
        XCTAssertEqual(rest.verticalInset, composer.verticalInset)

        let short = ComposerGeometry.of(composer, keyboard: true)
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
        XCTAssertEqual(ComposerGeometry.of(other, keyboard: true).scale, 0.8, accuracy: 1e-9,
                       "the look's share does not reach the geometry")
    }

    /// The short pane is the resting one scaled, so its corners are too: at rest the radius is the
    /// look's, and under the keyboard it is the look's at the same share as the well — two thirds
    /// by default, and wherever the pressable floor holds the well up, that share and not the
    /// look's — at every end of the ranges and at a radius of nothing and of a great deal.
    func testTheShortPanesCornerRadiusIsTheRestingOneAtTheShare() {
        let composer = Look.Composer()
        XCTAssertEqual(ComposerGeometry.of(composer, keyboard: false).cornerRadius, composer.cornerRadius)
        XCTAssertEqual(ComposerGeometry.of(composer, keyboard: true).cornerRadius, composer.cornerRadius * 2 / 3,
                       accuracy: 1e-9, "the default pane's corners are not two thirds of their radius")
        for var composer in Self.extremes {
            for radius in [0, 32, 4000] as [CGFloat] {
                composer.cornerRadius = radius
                let rest = ComposerGeometry.of(composer, keyboard: false)
                let short = ComposerGeometry.of(composer, keyboard: true)
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
            let rest = ComposerGeometry.of(composer, keyboard: false)
            let short = ComposerGeometry.of(composer, keyboard: true)
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
    private func frames(_ composer: Look.Composer, keyboard: Bool) throws -> (pane: CGRect, well: CGRect) {
        var look = Look()
        look.composer = composer
        look.composer.surface = .flat
        let probe = FrameProbe()
        let view = VStack(spacing: 0) {
            Spacer(minLength: 0)
            Composer(typing: .constant(keyboard), keyboard: keyboard)
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

    /// Laid out, at every hosted look: the short well is the geometry's size, is
    /// never under the pressable floor, sits inside the short pane from top to foot, and is inside
    /// it side to side wherever the resting well is — a look whose well is wider than its pane
    /// is that at rest, and the keyboard makes it no worse. The short pane is no taller than the
    /// resting one, sits on the same foot and is exactly as wide, in the same place.
    func testTheShortWellIsInsideTheShortPaneOnTheSmallestPhone() throws {
        for composer in Self.hosted {
            let rest = try frames(composer, keyboard: false)
            let short = try frames(composer, keyboard: true)
            let geometry = ComposerGeometry.of(composer, keyboard: true)
            let floor = min(composer.well.size, Look.Composer.Well.pressable)

            XCTAssertEqual(short.well.width, geometry.well, accuracy: 0.5, "\(composer): the well is not the geometry's")
            XCTAssertEqual(short.well.height, geometry.well, accuracy: 0.5, "\(composer)")
            XCTAssertGreaterThanOrEqual(short.well.width, floor - 0.5, "\(composer): the short well is under the floor")

            XCTAssertGreaterThanOrEqual(short.well.minY, short.pane.minY - 0.5, "\(composer): the well is over the pane's top")
            XCTAssertLessThanOrEqual(short.well.maxY, short.pane.maxY + 0.5, "\(composer): the well is under the pane's foot")
            if rest.well.minX >= rest.pane.minX - 0.5, rest.well.maxX <= rest.pane.maxX + 0.5 {
                XCTAssertGreaterThanOrEqual(short.well.minX, short.pane.minX - 0.5, "\(composer): the well left the pane")
                XCTAssertLessThanOrEqual(short.well.maxX, short.pane.maxX + 0.5, "\(composer): the well left the pane")
            }
            XCTAssertLessThanOrEqual(short.pane.height, rest.pane.height + 0.5, "\(composer): the pane grew under the keyboard")
            XCTAssertEqual(short.pane.maxY, rest.pane.maxY, accuracy: 0.5, "\(composer): the pane left its foot")
            // The width is the resting content's at every share, including a look whose content
            // is wider than its share of the screen.
            XCTAssertEqual(short.pane.width, rest.pane.width, accuracy: 0.5, "\(composer): the pane's width changed")
            XCTAssertEqual(short.pane.minX, rest.pane.minX, accuracy: 0.5, "\(composer): the pane moved sideways")
        }
    }

    /// The default look, laid out: the pane goes to two thirds of its height, and the well to two
    /// thirds of its size, centred on the same line across the glass.
    func testTheDefaultPaneGoesToTwoThirds() throws {
        let rest = try frames(Look.Composer(), keyboard: false)
        let short = try frames(Look.Composer(), keyboard: true)
        XCTAssertEqual(short.pane.height, rest.pane.height * 2 / 3, accuracy: 0.5)
        XCTAssertEqual(short.well.width, rest.well.width * 2 / 3, accuracy: 0.5)
        XCTAssertEqual(short.well.midX, rest.well.midX, accuracy: 0.5, "the well left the middle of the glass")
    }
}
