import CryptoKit
import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The badge, read off the pixels rather than off the source. What is worth holding is that the
/// glass is the look's and not the view's: a jewel of another colour has to reach the picture, or
/// the numbers in `Look.Jewel` are numbers nothing outside the source can change, which is the
/// whole point of the type.
@MainActor
final class BadgeRenderTests: XCTestCase {
    /// A view's pixels, as a digest at the size the badge is drawn: what a failure here has to
    /// say is that two pictures are the same, and the bytes themselves are not worth printing.
    private func raster<V: View>(_ view: V, look: Look = Look(), size: CGFloat? = nil) throws -> String {
        let side = size ?? look.badge.size
        let renderer = ImageRenderer(content: view
            .environment(\.look, look)
            .frame(width: side, height: side)
            .background(Color.white))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "the badge rendered to nothing")
        let cgImage = try XCTUnwrap(image.cgImage, "no bitmap behind the render")
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: cgImage.width, height: cgImage.height, bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// A stone under a cast of another colour entirely, so a picture drawn with it cannot match
    /// the uncast one's by accident.
    private var otherGlass: Look.Jewel {
        var jewel = Look.Jewel()
        jewel.cast = Color(red: 0.90, green: 0.20, blue: 0.10)
        jewel.castOpacity = 0.85
        return jewel
    }

    func testTheJewelIsDrawnFromTheGlassItIsHanded() throws {
        let teal = try raster(StainedGlass(glass: Look().jewel, diameter: Look().badge.size))
        let other = try raster(StainedGlass(glass: otherGlass, diameter: Look().badge.size))
        XCTAssertNotEqual(teal, other, "the jewel drew the same picture from two different glasses")
    }

    func testTheBadgeTakesItsGlassFromTheLook() throws {
        var look = Look()
        look.badge.jewel = otherGlass
        XCTAssertNotEqual(try raster(TopoBadge()), try raster(TopoBadge(), look: look),
                          "the look's badge jewel does not reach the badge")
    }

    /// The badge's stone is its own, so the microphone's does not reach it: two slabs, which is
    /// what makes the bar's mark a different colour from the one in the well.
    func testTheBadgeDoesNotTakeTheRestingJewel() throws {
        var look = Look()
        look.jewel = otherGlass
        XCTAssertEqual(try raster(TopoBadge()), try raster(TopoBadge(), look: look),
                       "the resting jewel reached the badge, which has a stone of its own")
    }

    /// The octopus is cut into the stone through the one press, so a look that takes the cut
    /// away takes it away in the bar as well as in the well.
    func testTheBadgesMarkIsCutAtTheLooksPress() throws {
        var flat = Look()
        flat.press.shade = .clear
        flat.press.catchLight = .clear
        flat.press.floor = 0
        XCTAssertNotEqual(try raster(TopoBadge()), try raster(TopoBadge(), look: flat),
                          "the look's press does not reach the badge's mark")
    }

    func testTheBadgeTakesItsSizeFromTheLook() throws {
        var look = Look()
        look.badge.markSize = look.badge.size / 4
        XCTAssertNotEqual(try raster(TopoBadge()), try raster(TopoBadge(), look: look),
                          "the look's mark size does not reach the badge")
    }

    /// The lights on the glass are the jewel's too: a slab of another colour wants a highlight of
    /// its own, and a sheen or a bevel written into the view is one it cannot have.
    func testTheSheenAndTheBevelAreTheJewelsOwnColours() throws {
        let plain = try raster(StainedGlass(glass: Look().jewel, diameter: Look().badge.size))

        var lit = Look.Jewel()
        lit.sheenColor = Color(red: 1, green: 0.85, blue: 0.4)
        XCTAssertNotEqual(plain, try raster(StainedGlass(glass: lit, diameter: Look().badge.size)),
                          "the jewel's sheen colour does not reach the glass")

        var cut = Look.Jewel()
        cut.bevelColor = Color(red: 1, green: 0.85, blue: 0.4)
        XCTAssertNotEqual(plain, try raster(StainedGlass(glass: cut, diameter: Look().badge.size)),
                          "the jewel's bevel colour does not reach the glass")
    }
}
