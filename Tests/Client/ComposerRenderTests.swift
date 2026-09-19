import CryptoKit
import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The composer, read off the pixels rather than off the source. What is worth holding is that
/// the glass, the well, the etch and both states of the jewel are the look's and not the view's:
/// a value nothing outside the source can change is a value the mind cannot reach, which is the
/// whole point of `Look`.
///
/// The surface is set to `flat` in every render here. The system's own glass is drawn by the
/// compositor and `ImageRenderer` does not draw it, so a tint laid under it would be a change
/// these digests could not see; `flat` is the same tint with nothing over it, which is exactly
/// what is being asked about.
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
                        look: Look) throws -> String {
        let view = Composer(typing: .constant(typing), draft: .constant(""), mic: mic)
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

        var roomy = flatLook()
        roomy.composer.verticalInset = look.composer.verticalInset + 12
        XCTAssertNotEqual(try raster(held, look: look), try raster(held, look: roomy),
                          "the look's inset does not reach the pane")
    }

    /// `flat`, `material` and `glass` are three surfaces and not three views, so a look that
    /// names another one draws another picture.
    func testThePaneTakesItsSurfaceFromTheLook() throws {
        var material = flatLook()
        material.composer.surface = .material
        XCTAssertNotEqual(try raster(held, look: flatLook()), try raster(held, look: material),
                          "the look's surface does not reach the pane")
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

        var small = flatLook()
        small.composer.well.jewelSize = look.composer.well.jewelSize / 2
        XCTAssertNotEqual(try raster(look: look), try raster(look: small),
                          "the look's jewel size does not reach the pixels")
    }

    /// The jewel at rest is `look.jewel` — the same slab the badge is cut from — and the jewel
    /// while the microphone is open is `look.composer.openJewel`. Two values, so a change to
    /// either reaches its own state and not the other's.
    func testTheTwoJewelsAreTheLooksAndAreNotEachOther() throws {
        let look = flatLook()
        XCTAssertNotEqual(try raster(look: look), try raster(held, look: look),
                          "the jewel does not change when the microphone opens")

        var otherRest = flatLook()
        otherRest.jewel.deep = Color(red: 0.32, green: 0.05, blue: 0.05)
        otherRest.jewel.mid = Color(red: 0.56, green: 0.12, blue: 0.10)
        XCTAssertNotEqual(try raster(look: look), try raster(look: otherRest),
                          "the look's resting jewel does not reach the microphone")
        XCTAssertEqual(try raster(held, look: look), try raster(held, look: otherRest),
                       "the resting jewel reached the open state, which has a jewel of its own")

        var otherOpen = flatLook()
        otherOpen.composer.openJewel.milk = Color(red: 1, green: 0.9, blue: 0.7)
        otherOpen.composer.openJewel.pale = Color(red: 0.95, green: 0.7, blue: 0.4)
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

    func testTheFlanksTakeTheirInkAndTheirEtchFromTheLook() throws {
        let look = flatLook()

        var ink = flatLook()
        ink.composer.flank.ink = Color(red: 0.9, green: 0.2, blue: 0.6)
        XCTAssertNotEqual(try raster(look: look), try raster(look: ink),
                          "the look's flank ink does not reach the pixels")

        var open = flatLook()
        open.composer.flank.openInk = Color(red: 0.1, green: 0.9, blue: 0.2)
        XCTAssertNotEqual(try raster(handsFree, look: look), try raster(handsFree, look: open),
                          "the look's open flank ink does not reach the pixels")

        var etch = flatLook()
        etch.composer.flank.etchLight = Look.Shadow(color: .red, radius: 3, y: 3)
        XCTAssertNotEqual(try raster(look: look), try raster(look: etch),
                          "the look's etch does not reach the pixels")

        var font = flatLook()
        font.composer.flank.font = .largeTitle
        XCTAssertNotEqual(try raster(look: look), try raster(look: font),
                          "the look's flank font does not reach the pixels")
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

        var ink = flatLook()
        ink.composer.glyph.ink = Color(red: 0.9, green: 0.3, blue: 0.1)
        XCTAssertNotEqual(try raster(look: look), try raster(look: ink),
                          "the look's glyph ink does not reach the mark")

        var open = flatLook()
        open.composer.glyph.openInk = Color(red: 0.9, green: 0.3, blue: 0.1)
        XCTAssertNotEqual(try raster(held, look: look), try raster(held, look: open),
                          "the look's open glyph ink does not reach the mark")
    }

    // MARK: The field

    /// The field is in the glass only while the keyboard is up, and what it is set in is the
    /// look's.
    func testTheFieldIsDrawnFromTheLookWhileTypingAndNotBefore() throws {
        let look = flatLook()
        XCTAssertNotEqual(try raster(look: look), try raster(typing: true, look: look),
                          "raising the keyboard puts no field in the glass")

        var font = flatLook()
        font.composer.field.sendFont = .largeTitle
        XCTAssertNotEqual(try raster(typing: true, look: look), try raster(typing: true, look: font),
                          "the look's send control does not reach the pixels")
    }
}
