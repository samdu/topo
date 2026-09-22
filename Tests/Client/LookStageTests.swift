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
/// Three things make one view two pictures, and they want different answers, which is why the
/// answer is in three places. The composer's glass is drawn from what the render server captured
/// behind it when it last composited the screen, so a window not yet on the display draws its
/// pane without that backdrop — another rim, shadow and lensed edge — and a wait on the clock is
/// a race a loaded runner loses: the stage waits for frames of the display instead
/// (`LookStage.composited`). A transcript taller than its stage is scrolled to its end and comes
/// to rest a pixel or two apart between two drawings, which the composer's glass magnifies into a
/// difference of eight shades over three thousand pixels — no capture strategy answers that,
/// because both drawings are finished; the surfaces are the answer, and they fit. A curve
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
            ("canvas", shots(LookReachTests.Surface.staged(row: .writing))),
            ("canvasNotice", shots(LookReachTests.Surface.staged(notice: "Topo is on another device."))),
            ("canvasDimmed", shots(LookReachTests.Surface.staged(mic: .init(canListen: false)))),
            ("canvasInFlight", shots(LookReachTests.Surface.staged(row: .inFlight))),
            ("canvasWide", shots(LookReachTests.Surface.staged(row: .writing),
                                 size: CGSize(width: 900, height: 700))),
            ("settings", shots(SettingsView(signOut: SignOut()).environment(Fixtures.harness()))),
        ] {
            if let said = try unsteadiness(of: made, called: name) { unsteady.append(said) }
        }
        XCTAssertEqual(unsteady, [], "these staged surfaces drew more than one picture of one look")
    }

    /// The surfaces `ImageRenderer` draws, which reproduce exactly — so they are asked for
    /// exactly, without the shade of tolerance the render server's need.
    func testEveryDrawnSurfaceGivesOnePicture() throws {
        var unsteady: [String] = []
        for surface in LookReachTests.Surface.allCases where surface.isDrawn {
            _ = try surface.picture(Look(), "stage")
            let made = try (0..<Self.asks).map { _ in try surface.picture(Look(), "stage") }
            if Set(made).count != 1 { unsteady.append(surface.rawValue) }
        }
        XCTAssertEqual(unsteady, [], "these drawn surfaces gave more than one picture of one look")
    }

    /// The other two looks this surface is drawn at, and a dark render of it — the surface and
    /// the appearances the screenshots compare.
    ///
    /// Each look is drawn on a stage it fits, which is the whole of what makes a still steady
    /// and is a different size for each: a look that overflows its stage is a transcript with a
    /// scroll to make, and where that comes to rest is what the phone's surfaces were changed to
    /// stop deciding. The watch's look fits the phone's stage with room over. The television's
    /// does not — 48 points of side padding and `.title3` on a 393-point column runs the draft
    /// row off the bottom edge, where the composer's glass is, which is exactly the pairing that
    /// magnifies a pixel of drift into a picture. So it is drawn at 1280×720, a television's
    /// shape, where nothing is clipped at either end.
    func testTheOtherLooksAndTheDarkRenderAreAsSteady() throws {
        var unsteady: [String] = []
        let surface = LookReachTests.Surface.staged(row: .writing)
        for (name, look, size) in [("watch", Look(.watch), LookStage.size),
                                   ("tv", Look(.tv), CGSize(width: 1280, height: 720))] {
            if let said = try unsteadiness(of: shots(surface, look: look, size: size),
                                           called: name) {
                unsteady.append(said)
            }
        }
        if let said = try unsteadiness(of: shots(surface, style: .dark), called: "dark") {
            unsteady.append(said)
        }
        XCTAssertEqual(unsteady, [], "these drew more than one picture of one look")
    }

    /// The steadiness assertion's own teeth: two surfaces that really are two pictures, drawn in
    /// turn, one to each ask, through the same stage and the same comparison the steadiness tests
    /// make, are reported as unsteady. The two are the draft row being written and on its way,
    /// which differ in the row's colour and in the spinner beside it — the kind of difference a
    /// still that had not settled would be.
    func testTwoPicturesDrawnInTurnAreReportedUnsteady() throws {
        let made = try shots { ask in
            LookReachTests.Surface.staged(row: ask.isMultiple(of: 2) ? .writing : .inFlight)
        }
        XCTAssertNotNil(try unsteadiness(of: made, called: "negative-control"),
                        "two different pictures drawn in turn read as one steady picture")
    }

    /// What the stage's steadiness rests on: no picture is taken before the display has drawn
    /// its window twice, since the system's glass is drawn from the render server's capture of
    /// the screen and a window the display has not drawn has none. A wait on the clock passes on
    /// an idle machine and loses on a loaded runner, so it is the frames that are held here,
    /// not the picture.
    func testNoPictureIsTakenBeforeTheDisplayHasDrawnItsWindow() throws {
        _ = try LookStage.image(LookReachTests.Surface.staged(row: .writing), look: Look())
        XCTAssertGreaterThanOrEqual(LookStage.framesBeforeLastPicture, 2,
                                    "the picture was taken before the display drew its window twice")
    }

    /// Whatever is on the screen under the stage stays out of the picture. The glass samples a
    /// margin past its own edge, and from a pane near the stage's foot that reaches past the
    /// stage; a full-screen window of another colour put under the stage is what would show if
    /// it reached the host app's window there.
    func testWhatIsUnderTheStageStaysOutOfThePicture() throws {
        let surface = LookReachTests.Surface.staged(row: .writing)
        _ = try LookStage.image(surface, look: Look(), style: .dark)
        let picture = try LookStage.image(surface, look: Look(), style: .dark)
        let alone = try LookStage.bytes(picture)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first, "no scene to put a window under the stage in")
        let under = UIWindow(windowScene: scene)
        under.frame = scene.screen.bounds
        let red = UIViewController()
        red.view.backgroundColor = .systemRed
        under.rootViewController = red
        under.isHidden = false
        defer {
            under.isHidden = true
            under.rootViewController = nil
        }
        let over = try LookStage.plane(surface, look: Look(), style: .dark)

        let said = LookStage.difference(alone, over, width: Int(picture.size.width * picture.scale),
                                        scale: picture.scale)?.said ?? ""
        XCTAssertFalse(try LookStage.differ(alone, over),
                       "a window under the stage reached the picture: \(said)")
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
    private func shots(_ view: some View, look: Look = Look(),
                       style: UIUserInterfaceStyle = .light,
                       size: CGSize = LookStage.size) throws -> [UIImage] {
        try shots(look: look, style: style, size: size) { _ in view }
    }

    /// The same, with the view each ask draws handed over by the ask's number: 0 is the drawing
    /// thrown away, and 1 onwards are the ones compared.
    private func shots<V: View>(look: Look = Look(), style: UIUserInterfaceStyle = .light,
                                size: CGSize = LookStage.size,
                                _ view: (Int) -> V) throws -> [UIImage] {
        _ = try LookStage.image(view(0), look: look, style: style, size: size)
        return try (1...Self.asks).map {
            try LookStage.image(view($0), look: look, style: style, size: size)
        }
    }

    /// Whether these drawings are one picture, and if they are not, what the difference was:
    /// the same account the reach suite's own failure gives, since a failure that names only
    /// the subject is a run on the CI runner that has to be repeated to learn anything.
    ///
    /// The first drawing that differs is the one reported, and only a failure pays for the
    /// pictures.
    private func unsteadiness(of made: [UIImage], called name: String) throws -> String? {
        let first = try LookStage.bytes(made[0])
        let width = Int(made[0].size.width * made[0].scale)
        for (index, image) in made.enumerated().dropFirst() {
            let bytes = try LookStage.bytes(image)
            guard try LookStage.differ(first, bytes) else { continue }
            let difference = LookStage.difference(first, bytes, width: width, scale: made[0].scale)
            attach(made[0], "\(name)-first")
            attach(image, "\(name)-ask-\(index)")
            if let mask = difference?.picture { attach(mask, "\(name)-mask") }
            // `differ` said these are two pictures, so `difference` has something to report.
            let said = difference?.said ?? "a difference of no channel, which cannot happen"
            return "\(name) on ask \(index): \(said); pictures and mask attached"
        }
        return nil
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
