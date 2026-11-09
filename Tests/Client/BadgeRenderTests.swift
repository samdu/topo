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
    /// A view rendered at the size the badge is drawn, as its image and its RGBA bytes.
    private struct Picture {
        let image: UIImage
        let bytes: [UInt8]
    }

    private func picture<V: View>(_ view: V, look: Look = Look(), size: CGFloat? = nil) throws -> Picture {
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
        return Picture(image: image, bytes: bytes)
    }

    /// A view's pixels, as a digest: what a failure here has to say is that two pictures are the
    /// same, and the bytes themselves are not worth printing.
    private func raster<V: View>(_ view: V, look: Look = Look(), size: CGFloat? = nil) throws -> String {
        let bytes = try picture(view, look: look, size: size).bytes
        return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// How far apart two pictures are: the mean of every channel's absolute difference, in
    /// levels of 255.
    private func distance(_ a: Picture, _ b: Picture) -> Double {
        guard a.bytes.count == b.bytes.count, !a.bytes.isEmpty else { return .infinity }
        let total = zip(a.bytes, b.bytes).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        return Double(total) / Double(a.bytes.count)
    }

    /// Kept with the result of a test that fails, whichever check fails it, and dropped from one
    /// that passes.
    private func attach(_ picture: Picture, _ name: String) {
        keep(XCTAttachment(image: picture.image), name)
    }

    private func attach(_ text: String, _ name: String) {
        keep(XCTAttachment(string: text), name)
    }

    private func keep(_ attachment: XCTAttachment, _ name: String) {
        attachment.name = name
        attachment.lifetime = .deleteOnSuccess
        add(attachment)
    }

    /// The first render of a process pays for the asset catalogue's first read and the blur's
    /// first pass; it is made here, so no test compares against a picture drawn cold.
    override func setUp() async throws {
        try await super.setUp()
        _ = try picture(TopoBadge())
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
    /// what makes the bar's mark a different colour from the one in the well. Judged against the
    /// difference the same glass makes when it is the badge's own, since two renders of one view
    /// need not agree to the last bit (the press's blur), and the cast would move it by far more.
    func testTheBadgeDoesNotTakeTheRestingJewel() throws {
        var resting = Look()
        resting.jewel = otherGlass
        var own = Look()
        own.badge.jewel = otherGlass
        let plain = try picture(TopoBadge())
        let underResting = try picture(TopoBadge(), look: resting)
        let underOwn = try picture(TopoBadge(), look: own)
        let leak = distance(plain, underResting)
        let cast = distance(plain, underOwn)
        attach(plain, "badge")
        attach(underResting, "badge with the resting jewel cast")
        attach(underOwn, "badge with its own jewel cast")
        attach("the resting jewel moved the badge by \(leak) levels a channel; its own jewel by \(cast)", "distances")
        guard cast > 1 else {
            return XCTFail("the badge's own jewel moved it by \(cast) levels a channel, so this test measures nothing")
        }
        if leak * 50 >= cast {
            XCTFail("the resting jewel reached the badge, which has a stone of its own: it moved the badge by \(leak) levels a channel, against \(cast) for the badge's own jewel")
        }
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
