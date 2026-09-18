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

    /// A jewel poured from another glass entirely, so a picture drawn with it cannot match the
    /// default's by accident.
    private var otherGlass: Look.Jewel {
        var jewel = Look.Jewel()
        jewel.deep = Color(red: 0.32, green: 0.05, blue: 0.05)
        jewel.mid = Color(red: 0.56, green: 0.12, blue: 0.10)
        jewel.pale = Color(red: 0.90, green: 0.60, blue: 0.55)
        jewel.milk = Color(red: 0.96, green: 0.86, blue: 0.84)
        return jewel
    }

    func testTheJewelIsDrawnFromTheGlassItIsHanded() throws {
        let teal = try raster(StainedGlass(glass: Look().jewel), size: Look().badge.size)
        let other = try raster(StainedGlass(glass: otherGlass), size: Look().badge.size)
        XCTAssertNotEqual(teal, other, "the jewel drew the same picture from two different glasses")
    }

    func testTheBadgeTakesItsGlassFromTheLook() throws {
        var look = Look()
        look.jewel = otherGlass
        XCTAssertNotEqual(try raster(TopoBadge()), try raster(TopoBadge(), look: look),
                          "the look's jewel does not reach the badge")
    }

    func testTheBadgeTakesItsSizeFromTheLook() throws {
        var look = Look()
        look.badge.markSize = look.badge.size / 4
        XCTAssertNotEqual(try raster(TopoBadge()), try raster(TopoBadge(), look: look),
                          "the look's mark size does not reach the badge")
    }
}
