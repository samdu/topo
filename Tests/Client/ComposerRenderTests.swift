import CryptoKit
import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The composer, read off the pixels rather than off the source. What is worth holding is that
/// the glass, the well, the etch, the mark, the field and both states of the jewel are the look's
/// and not the view's: a value nothing outside the source can change is a value the mind cannot
/// reach, which is the whole point of `Look`.
///
/// Every field of `Look.Composer` is varied here except four, and each of the four was shown to
/// render byte for byte the same picture before it was left out rather than assumed to:
///
/// - `duration` and `presenceDuration` are times, so a still frame is the
///   same either way. Nothing tests them.
/// - `presenceRise` is not drawn by the composer at all: it is how the chat works out the
///   presence it hands over, and it is `PanePresenceTests` that holds it.
/// - `dimmedSaturation` is drawn by `.saturation`, which `ImageRenderer` does not apply. The
///   colour draining out of the jewel is by eye, in the dimmed screenshots on the PR.
/// - `widthFraction` is `containerRelativeFrame`, which has no container in a renderer. How
///   much of the screen the glass takes is by eye, in every screenshot.
/// - `horizontalInset` is the room inside the glass for the two ends, and the ends are elastic:
///   each takes the width left over, so the inset bounds them and moves nothing while neither
///   is wide enough to be bounded. It is drawn and not dead, but there is no picture it changes
///   today.
/// - `field.ink` and `field.lineLimit` are the text inside a `TextField`, which `ImageRenderer`
///   lays out without drawing. The font and the padding do reach the picture, through the space
///   they take. What the words look like is by eye, in the typing screenshots on the PR.
///
/// The surface is set to `flat` in every render here. The system's own glass is drawn by the
/// compositor and `ImageRenderer` does not draw it, so a tint laid under it would be a change
/// these digests could not see; `flat` is the same tint with nothing over it, which is exactly
/// what is being asked about. This is also the whole of what the presence can be said to do
/// here: that the flat substitute goes when the presence does. Whether the *system's* glass goes
/// with it is a compositor's business and is by eye, in the screenshots on the PR and in the
/// device box under them.
@MainActor
final class ComposerRenderTests: XCTestCase {
    private let size = CGSize(width: 340, height: 160)

    /// A look whose pane is drawn rather than composited, so the digest sees what it is handed.
    private func flatLook() -> Look {
        var look = Look()
        look.composer.surface = .flat
        return look
    }

    /// The composer at rest, or in whatever state it is handed, as a digest: what a failure here
    /// has to say is that two pictures are the same, and the bytes are not worth printing.
    private func raster(_ mic: Composer.MicState = .init(), typing: Bool = false,
                        presence: Double = 1, keyboard: Bool = false, look: Look) throws -> String {
        let view = Composer(typing: .constant(typing), mic: mic, presence: presence, keyboard: keyboard)
            .environment(\.look, look)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "the composer rendered to nothing")
        let cgImage = try XCTUnwrap(image.cgImage, "no bitmap behind the render")
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        XCTAssertGreaterThan(Set(bytes).count, 2, "the render is a blank field, so it says nothing")
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private var held: Composer.MicState {
        Composer.MicState(canListen: true, listening: true, owner: .chat, handsFree: false)
    }

    /// Open with the hand off the glass, which is the one state in which the pane is coloured
    /// and the flanks are still drawn on it.
    private var handsFree: Composer.MicState {
        Composer.MicState(canListen: true, listening: true, owner: .chat, handsFree: true)
    }

    // MARK: The pane

    /// The colour the glass takes while the microphone is open, and the alpha it takes it at:
    /// two fields, and a third state where the alpha is nothing and opening changes no pixel.
    func testTheOpenPaneTakesItsTintFromTheLook() throws {
        let look = flatLook()
        XCTAssertNotEqual(try raster(look: look), try raster(held, look: look),
                          "the open microphone does not change the pane")

        var other = flatLook()
        other.composer.tint = Color(red: 0.8, green: 0.2, blue: 0.1)
        XCTAssertNotEqual(try raster(held, look: look), try raster(held, look: other),
                          "the look's tint does not reach the open pane")

        var clear = flatLook()
        clear.composer.tintOpacity = 0
        XCTAssertNotEqual(try raster(held, look: look), try raster(held, look: clear),
                          "the tint's alpha does not reach the pane")
    }

    func testThePaneTakesItsCornersAndItsRoomFromTheLook() throws {
        let look = flatLook()

        var square = flatLook()
        square.composer.cornerRadius = 0
        XCTAssertNotEqual(try raster(held, look: look), try raster(held, look: square),
                          "the look's corner radius does not reach the pane")

        var tall = flatLook()
        tall.composer.verticalInset = look.composer.verticalInset + 12
        XCTAssertNotEqual(try raster(held, look: look), try raster(held, look: tall),
                          "the look's vertical inset does not reach the pane")
    }

    /// A look whose pane draws nothing: the flat substitute at no alpha, and a glow of nothing.
    /// It is the picture the pane at no presence has to be, since a pane over nothing is meant
    /// to be no pane and not a fainter one.
    private func panelessLook() -> Look {
        var look = flatLook()
        look.composer.tintOpacity = 0
        look.composer.glow = Look.Shadow(color: .clear, radius: 0, y: 0)
        return look
    }

    /// The surface and the glow are drawn at the presence, so over the empty end of the
    /// transcript there is the well, the jewel and the flanks and nothing else behind them.
    func testThePaneAndItsGlowAreDrawnAtThePresence() throws {
        let look = flatLook()
        XCTAssertNotEqual(try raster(held, presence: 0, look: look),
                          try raster(held, presence: 1, look: look),
                          "the presence does not reach the pane")
        XCTAssertEqual(try raster(held, presence: 0, look: look),
                       try raster(held, presence: 1, look: panelessLook()),
                       "the pane at no presence is not the picture of no pane")
    }

    /// `flat`, `material` and `glass` are three surfaces and not three views, so a look that
    /// names another one draws another picture.
    func testThePaneTakesItsSurfaceFromTheLook() throws {
        var material = flatLook()
        material.composer.surface = .material
        XCTAssertNotEqual(try raster(held, look: flatLook()), try raster(held, look: material),
                          "the look's surface does not reach the pane")
    }

    /// How far the glass floats off the bottom, and how far its ends sit from the well.
    func testTheGlassFloatsAndSpacesItsRowFromTheLook() throws {
        let look = flatLook()

        var high = flatLook()
        high.composer.bottomPadding = look.composer.bottomPadding + 24
        XCTAssertNotEqual(try raster(look: look), try raster(look: high),
                          "the look's bottom padding does not reach the pane")

        var tight = flatLook()
        tight.composer.spacing = 0
        XCTAssertNotEqual(try raster(look: look), try raster(look: tight),
                          "the look's spacing does not reach the row")

    }

    /// Under the keyboard the pane is short and the microphone with it, at the look's share: the
    /// share reaches the short pane's pixels and not the resting pane's.
    func testTheShortPaneIsDrawnAtTheLooksShare() throws {
        let look = flatLook()
        XCTAssertNotEqual(try raster(look: look), try raster(keyboard: true, look: look),
                          "the keyboard does not change the pane")
        var other = flatLook()
        other.composer.compactShare = 0.9
        XCTAssertNotEqual(try raster(keyboard: true, look: look), try raster(keyboard: true, look: other),
                          "the look's share does not reach the short pane")
        XCTAssertEqual(try raster(look: look), try raster(look: other),
                       "the share reaches the pane at rest")
        var whole = flatLook()
        whole.composer.compactShare = 1
        XCTAssertEqual(try raster(look: whole), try raster(keyboard: true, look: whole),
                       "a share of one is not the resting pane")
    }

    /// What the open glass spills onto the transcript behind it. It is the same shadow at
    /// nothing while the microphone is shut, so it is the open state that has one to change.
    func testTheOpenPaneSpillsTheLooksGlow() throws {
        var other = flatLook()
        other.composer.glow = Look.Shadow(color: Color(red: 0.9, green: 0.1, blue: 0.1),
                                          radius: 30, y: 6)
        XCTAssertNotEqual(try raster(held, look: flatLook()), try raster(held, look: other),
                          "the look's glow does not reach the pixels")
    }

    // MARK: The well and the jewel

    func testTheWellIsDrawnFromTheLook() throws {
        let look = flatLook()

        var floor = flatLook()
        floor.composer.well.floor = Color(red: 0.6, green: 0.1, blue: 0.5)
        XCTAssertNotEqual(try raster(look: look), try raster(look: floor),
                          "the look's well floor does not reach the pixels")

        var edge = flatLook()
        edge.composer.well.edgeWidth = 6
        XCTAssertNotEqual(try raster(look: look), try raster(look: edge),
                          "the look's cut edge does not reach the pixels")

        var edgeColours = flatLook()
        edgeColours.composer.well.edgeColors = [.red, .green, .blue]
        XCTAssertNotEqual(try raster(look: look), try raster(look: edgeColours),
                          "the look's cut edge colours do not reach the pixels")

        var bore = flatLook()
        bore.composer.well.size = look.composer.well.size + 20
        XCTAssertNotEqual(try raster(look: look), try raster(look: bore),
                          "the look's well size does not reach the pixels")

        var small = flatLook()
        small.composer.well.jewelSize = look.composer.well.jewelSize / 2
        XCTAssertNotEqual(try raster(look: look), try raster(look: small),
                          "the look's jewel size does not reach the pixels")
    }

    /// The three inner shadows that make the bore a cut and not a disc: the wall's deep shadow,
    /// the hard line of the lip, and the light caught under its far edge. Three values, and each
    /// one is drawn.
    func testTheWellsThreeInnerShadowsReachThePixels() throws {
        let look = flatLook()

        var bore = flatLook()
        bore.composer.well.bore = Look.Shadow(color: .red.opacity(0.8), radius: 9, y: 7)
        XCTAssertNotEqual(try raster(look: look), try raster(look: bore),
                          "the look's bore shadow does not reach the pixels")

        var lip = flatLook()
        lip.composer.well.lip = Look.Shadow(color: .green.opacity(0.8), radius: 3, y: 3)
        XCTAssertNotEqual(try raster(look: look), try raster(look: lip),
                          "the look's lip does not reach the pixels")

        var catchLight = flatLook()
        catchLight.composer.well.catchLight = Look.Shadow(color: .blue.opacity(0.8), radius: 4, y: -4)
        XCTAssertNotEqual(try raster(look: look), try raster(look: catchLight),
                          "the look's catch light does not reach the pixels")
    }

    /// The jewel at rest is `look.jewel` — the same slab the badge is cut from — and the jewel
    /// while the microphone is open is `look.composer.openJewel`. Two values, so a change to
    /// either reaches its own state and not the other's.
    func testTheTwoJewelsAreTheLooksAndAreNotEachOther() throws {
        let look = flatLook()
        XCTAssertNotEqual(try raster(look: look), try raster(held, look: look),
                          "the jewel does not change when the microphone opens")

        var otherRest = flatLook()
        otherRest.jewel.cast = Color(red: 0.32, green: 0.05, blue: 0.05)
        otherRest.jewel.castOpacity = 0.8
        XCTAssertNotEqual(try raster(look: look), try raster(look: otherRest),
                          "the look's resting jewel does not reach the microphone")
        XCTAssertEqual(try raster(held, look: look), try raster(held, look: otherRest),
                       "the resting jewel reached the open state, which has a jewel of its own")

        var otherOpen = flatLook()
        otherOpen.composer.openJewel.cast = Color(red: 1, green: 0.9, blue: 0.7)
        otherOpen.composer.openJewel.castOpacity = 0.9
        XCTAssertNotEqual(try raster(held, look: look), try raster(held, look: otherOpen),
                          "the look's open jewel does not reach the open microphone")
    }

    /// A press that would be refused drains and fades the jewel, by two values rather than by a
    /// colour of its own.
    func testTheDimmedJewelIsDrawnFromTheLook() throws {
        let look = flatLook()
        let dimmed = Composer.MicState(canListen: false)
        XCTAssertNotEqual(try raster(look: look), try raster(dimmed, look: look),
                          "a microphone that cannot be pressed looks the same as one that can")

        var faint = flatLook()
        faint.composer.dimmedOpacity = 0.1
        XCTAssertNotEqual(try raster(dimmed, look: look), try raster(dimmed, look: faint),
                          "the look's dimmed alpha does not reach the jewel")

        // `dimmedSaturation` is not asserted here: `ImageRenderer` draws `.opacity` and does not
        // draw `.saturation`, so a look that changes it renders byte for byte the same picture
        // and a digest cannot tell the two apart. The colour draining out of the jewel is in the
        // dimmed screenshots on the PR, which is by eye and not by this suite.
    }

    // MARK: The flanks

    func testTheFlanksTakeTheirInkFromTheLook() throws {
        let look = flatLook()

        var ink = flatLook()
        ink.composer.flank.ink = Color(red: 0.9, green: 0.2, blue: 0.6)
        XCTAssertNotEqual(try raster(look: look), try raster(look: ink),
                          "the look's flank ink does not reach the pixels")

        var open = flatLook()
        open.composer.flank.openInk = Color(red: 0.1, green: 0.9, blue: 0.2)
        XCTAssertNotEqual(try raster(handsFree, look: look), try raster(handsFree, look: open),
                          "the look's open flank ink does not reach the pixels")

        var font = flatLook()
        font.composer.flank.font = .largeTitle
        XCTAssertNotEqual(try raster(look: look), try raster(look: font),
                          "the look's flank font does not reach the pixels")
    }

    /// The one control the glass has says which way it goes: the keyboard up, or down again.
    /// The words themselves are not here — they are written in the row at the end of the
    /// transcript — so this is the whole of what `typing` changes on the glass.
    func testTheFlankSaysWhichWayTheKeyboardGoes() throws {
        let look = flatLook()
        XCTAssertNotEqual(try raster(look: look), try raster(typing: true, look: look),
                          "the flank draws the same mark whether the keyboard is up or down")
    }

    /// The etch is three values — how far under its ink the glyph sits, and the two catches that
    /// make it a cut rather than a drawing — and all three are drawn.
    func testTheEtchIsTheLooksThreeValues() throws {
        let look = flatLook()

        var opacity = flatLook()
        opacity.composer.flank.etchOpacity = 0.2
        XCTAssertNotEqual(try raster(look: look), try raster(look: opacity),
                          "the look's etch opacity does not reach the pixels")

        var light = flatLook()
        light.composer.flank.etchLight = Look.Shadow(color: .red, radius: 3, y: 3)
        XCTAssertNotEqual(try raster(look: look), try raster(look: light),
                          "the look's etch light does not reach the pixels")

        var shade = flatLook()
        shade.composer.flank.etchShade = Look.Shadow(color: .green, radius: 3, y: -3)
        XCTAssertNotEqual(try raster(look: look), try raster(look: shade),
                          "the look's etch shade does not reach the pixels")
    }

    /// A thumb on the microphone takes the flanks to the look's held alpha and leaves their
    /// space, so the glass never changes size under the hand.
    func testTheHeldFlanksGoByTheLooksAlpha() throws {
        let look = flatLook()
        var visible = flatLook()
        visible.composer.flank.heldOpacity = 1
        XCTAssertNotEqual(try raster(held, look: look), try raster(held, look: visible),
                          "the look's held alpha does not reach the flanks")
    }

    // MARK: The mark

    func testTheMarkIsDrawnFromTheLook() throws {
        let look = flatLook()

        var big = flatLook()
        big.composer.glyph.size = look.composer.glyph.size * 1.6
        XCTAssertNotEqual(try raster(look: look), try raster(look: big),
                          "the look's glyph size does not reach the mark")

        var heavy = flatLook()
        heavy.composer.glyph.weight = .black
        XCTAssertNotEqual(try raster(look: look), try raster(look: heavy),
                          "the look's glyph weight does not reach the mark")

        var open = flatLook()
        open.composer.glyph.openCast = Color(red: 0.9, green: 0.3, blue: 0.1)
        XCTAssertNotEqual(try raster(held, look: look), try raster(held, look: open),
                          "the look's open cast does not reach the floor of the open mark")
        XCTAssertEqual(try raster(look: look), try raster(look: open),
                       "the open cast reached the mark at rest, where there is nothing to cast")
    }

    /// The cut the mark is pressed at is `Look.press`, which is one treatment for both marks,
    /// so a change to it reaches the microphone.
    func testTheCutIsDrawnFromTheLooksOnePress() throws {
        let look = flatLook()

        var flat = flatLook()
        flat.press.wall = 0
        XCTAssertNotEqual(try raster(look: look), try raster(look: flat),
                          "the look's wall does not reach the microphone's cut")

        var lit = flatLook()
        lit.press.catchLight = Color(red: 1, green: 0.85, blue: 0.4)
        XCTAssertNotEqual(try raster(look: look), try raster(look: lit),
                          "the look's catch light does not reach the microphone's cut")
    }
}
