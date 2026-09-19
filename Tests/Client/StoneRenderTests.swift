import CryptoKit
import Foundation
import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The stone and the cut, read off the pixels rather than off the source.
///
/// Two claims, and they are the two the cabochon is made of. The body is one photograph under a
/// cast, so a jewel of another colour has to reach the picture and a cast of nothing has to
/// reach none of it. The mark is pressed through one treatment, so the four fields of
/// `Look.Press` are the whole of what the cut is drawn with: take them all away and what is left
/// is the stone under the mark's own shape and nothing else.
///
/// What is held here is what `ImageRenderer` draws. It composites none of the system's own glass
/// and applies no `.saturation`, so neither is asked about; everything below is a shape, a fill,
/// a mask and a blend, all of which it draws.
@MainActor
final class StoneRenderTests: XCTestCase {
    /// The size the microphone's stone is read at, which is the larger of the two cabochons and
    /// so the one whose cut has the most pixels to show.
    private let diameter = Look().composer.well.jewelSize

    /// A view's pixels as a digest: what a failure here has to say is that two pictures are the
    /// same, or that they differ, and the bytes themselves are not worth printing.
    private func raster(_ view: some View, side: CGFloat) throws -> String {
        let renderer = ImageRenderer(content: view.frame(width: side, height: side)
            .background(Color.white))
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "the stone rendered to nothing")
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

    // MARK: The cast

    /// The badge's stone is the same photograph under the colour of the other side, and that is
    /// a value: a cast of another colour is another picture.
    func testACastStoneIsNotTheStoneItWasCutFrom() throws {
        let plain = try raster(StainedGlass(glass: Look().jewel, diameter: diameter), side: diameter)
        let badge = try raster(StainedGlass(glass: Look().badge.jewel, diameter: diameter), side: diameter)
        XCTAssertNotEqual(plain, badge, "the badge's cast does not reach the stone")
    }

    /// And a cast at nothing is nothing drawn: the alpha is what lays the colour on, so a stone
    /// that takes no cast is the same bytes whatever colour the cast names.
    func testACastAtNoAlphaDrawsNothingAtAll() throws {
        var uncast = Look.Jewel()
        uncast.cast = .clear
        uncast.castOpacity = 0

        var named = Look.Jewel()
        named.cast = Theme.secondary
        named.castOpacity = 0

        XCTAssertEqual(try raster(StainedGlass(glass: uncast, diameter: diameter), side: diameter),
                       try raster(StainedGlass(glass: named, diameter: diameter), side: diameter),
                       "a cast at no alpha changed the stone")
    }

    // MARK: The cut

    /// The mark as the badge draws it, at the size it is drawn, cut at whatever press it is
    /// handed. The frame is the jewel's, so the floor's stone sits where the body's does.
    private func mark(_ press: Look.Press, cast: Color = .clear) -> some View {
        OctopusMark()
            .frame(width: Look().badge.markSize, height: Look().badge.markSize)
            .pressed(press, into: Look().jewel, diameter: diameter, cast: cast)
            .frame(width: diameter, height: diameter)
    }

    /// A wall of no width is no wall: the cut is the two bands the mark makes against itself
    /// moved by the wall's width, so at nothing there is nothing to shade or to light.
    func testTheWallsWidthIsWhatCutsTheMark() throws {
        var flat = Look.Press()
        flat.wall = 0
        XCTAssertNotEqual(try raster(mark(Look.Press()), side: diameter),
                          try raster(mark(flat), side: diameter),
                          "the press's wall does not reach the cut")
    }

    /// The four fields are the whole of the treatment: with both walls clear and no shade over
    /// the floor, what is drawn is the stone under the mark's shape and nothing besides.
    func testAPressAtNothingIsTheStoneUnderTheMark() throws {
        var none = Look.Press()
        none.shade = .clear
        none.catchLight = .clear
        none.floor = 0

        let jewel = Look().jewel
        let stone = Circle()
            .fill(Stone.paint(jewel.stone, across: diameter))
            .overlay { jewel.cast.opacity(jewel.castOpacity).blendMode(jewel.castBlend) }
            .compositingGroup()
            .frame(width: diameter, height: diameter)
            .mask {
                OctopusMark().frame(width: Look().badge.markSize, height: Look().badge.markSize)
            }

        XCTAssertEqual(try raster(mark(none), side: diameter),
                       try raster(stone, side: diameter),
                       "a press at nothing drew something the four fields do not account for")
    }

    /// The floor of the cut is the stone and not a colour: at the same shade, a mark cut into a
    /// stone of another cast is a different floor.
    func testTheFloorOfTheCutIsTheStoneUnderIt() throws {
        let press = Look.Press()
        let plain = OctopusMark()
            .frame(width: Look().badge.markSize, height: Look().badge.markSize)
            .pressed(press, into: Look().jewel, diameter: diameter)
            .frame(width: diameter, height: diameter)
        let cast = OctopusMark()
            .frame(width: Look().badge.markSize, height: Look().badge.markSize)
            .pressed(press, into: Look().badge.jewel, diameter: diameter)
            .frame(width: diameter, height: diameter)

        XCTAssertNotEqual(try raster(plain, side: diameter), try raster(cast, side: diameter),
                          "the jewel the mark is cut into does not reach the floor of the cut")
    }
}
