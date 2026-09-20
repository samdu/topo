import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The stage's own claim: one view under one look is one picture, however many times it is asked.
///
/// Everything the reach suite says rests on this. It decides whether a field reaches the pixels
/// by comparing two stills, so a surface that gives two different pictures of the same look makes
/// its fields report differently from one run to the next — a field that draws nothing read as
/// drawing, and the excuse list read as stale.
///
/// Two things made one view two pictures, and they wanted different answers, which is why the
/// fix is in two places. A transcript taller than its stage is scrolled to its end and comes to
/// rest a pixel or two apart between two drawings, which the composer's glass magnifies into a
/// difference of eight shades over three thousand pixels — no capture strategy answers that,
/// because both drawings are finished; the surfaces are the answer, and they now fit. A curve
/// composited through two windows rounds its antialiasing a shade either way, which nothing can
/// remove either: `differ` is the answer to that, and the settings sheet's glass is what needs
/// it.
@MainActor
final class LookStageTests: XCTestCase {
    /// How many times each surface is asked. Enough for an alternating pair to show itself, and
    /// cheap enough to run on every PR.
    private static let asks = 3

    /// The staged surfaces, which go through the render server and are compared by their bytes.
    func testEveryStagedSurfaceGivesOnePicture() throws {
        var unsteady: [String] = []
        for (name, made) in try [
            ("canvas", planes(LookReachTests.Surface.staged(row: .writing))),
            ("canvasNotice", planes(LookReachTests.Surface.staged(notice: "Topo is on another device."))),
            ("canvasDimmed", planes(LookReachTests.Surface.staged(mic: .init(canListen: false)))),
            ("canvasInFlight", planes(LookReachTests.Surface.staged(row: .inFlight))),
            ("canvasWide", planes(LookReachTests.Surface.staged(row: .writing),
                                  size: CGSize(width: 900, height: 700))),
            ("settings", planes(SettingsView(signOut: SignOut()).environment(Fixtures.harness()))),
        ] where try alike(made) == false {
            unsteady.append(name)
        }
        XCTAssertEqual(unsteady, [], "these staged surfaces drew more than one picture of one look")
    }

    /// The surfaces `ImageRenderer` draws, which reproduce exactly and are compared by digest.
    func testEveryDrawnSurfaceGivesOnePicture() throws {
        var unsteady: [String] = []
        for surface in LookReachTests.Surface.allCases where surface.isDrawn {
            _ = try surface.raster(Look(), "stage")
            let made = try (0..<Self.asks).map { _ in try surface.raster(Look(), "stage") }
            if Set(made).count != 1 { unsteady.append(surface.rawValue) }
        }
        XCTAssertEqual(unsteady, [], "these drawn surfaces gave more than one digest of one look")
    }

    /// The other two looks the same transcript is drawn at, and a dark render, which is what the
    /// screenshots compare.
    func testTheOtherLooksAndTheDarkRenderAreAsSteady() throws {
        for look in [Look(.watch), Look(.tv)] {
            XCTAssertTrue(try alike(planes(LookReachTests.Surface.staged(row: .writing), look: look)),
                          "one of the other screens' looks drew more than one picture")
        }
        XCTAssertTrue(try alike(planes(LookReachTests.Surface.staged(row: .writing), style: .dark)),
                      "the dark render drew more than one picture")
    }

    /// And that a shade is all the tolerance is: two pictures that differ by more than one are
    /// two pictures, or the reach suite would see no field at all.
    func testMoreThanAShadeIsADifference() throws {
        let one = try LookStage.plane(ChatCanvas(row: .writing), look: Look())
        var nudged = one
        for i in stride(from: 0, to: nudged.count, by: 4) {
            nudged[i] = nudged[i] > 127 ? nudged[i] - 3 : nudged[i] + 3
        }
        XCTAssertTrue(try LookStage.differ(one, nudged), "three shades read as the same picture")
        var within = one
        for i in stride(from: 0, to: within.count, by: 4) {
            within[i] = within[i] > 127 ? within[i] - 2 : within[i] + 2
        }
        XCTAssertFalse(try LookStage.differ(one, within), "two shades read as a difference")
    }

    /// The drawings to compare, with the first one thrown away: a surface's first drawing in a
    /// process is not like the ones after it — glyphs are not yet in the atlas, a backdrop's
    /// caches are not yet built — and this asks whether the drawings after that are one picture.
    /// Comparing across that boundary is the defect `LookReachTests.baseline` guards against.
    private func planes(_ view: some View, look: Look = Look(),
                        style: UIUserInterfaceStyle = .light,
                        size: CGSize = LookStage.size) throws -> [[UInt8]] {
        _ = try LookStage.plane(view, look: look, style: style, size: size)
        return try (0..<Self.asks).map {
            _ in try LookStage.plane(view, look: look, style: style, size: size)
        }
    }

    private func alike(_ made: [[UInt8]]) throws -> Bool {
        for plane in made.dropFirst() where try LookStage.differ(made[0], plane) { return false }
        return true
    }
}
