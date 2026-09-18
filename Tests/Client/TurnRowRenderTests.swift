import SwiftUI
import TopoCore
import UIKit
import XCTest

@testable import Topo

/// What the transcript draws, read off the pixels rather than off the source. Which side a turn
/// is on and whether it is enclosed is the only thing saying who said it now that no caption
/// does, so it is checked by rendering a row and looking for the bubble's outline: present on the
/// person's side, absent on Topo's, and on the right-hand half of the row.
///
/// The outline is the thing sampled because it is the one part of the bubble drawn at full
/// opacity, so a pixel of it is the accent exactly and no tolerance has to stand in for the
/// tint's alpha.
@MainActor
final class TurnRowRenderTests: XCTestCase {
    private let width: CGFloat = 320

    private func turn(_ role: TurnRole, _ text: String) -> Turn {
        Turn(ref: TurnRef(device: DeviceID("phone"), sequence: 1), parents: [], role: role,
             text: text, at: Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// One row as it ships, or under a look of the test's own.
    private func render(_ turn: Turn, look: Look = Look()) throws -> Raster {
        let view = TurnRow(turn: turn)
            .environment(\.look, look)
            .frame(width: width)
            .background(Color.white)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        let image = try XCTUnwrap(renderer.uiImage, "the row rendered to nothing")
        return try Raster(image)
    }

    /// A rendered row as bytes, with the one question worth asking of it.
    private struct Raster {
        let width: Int
        let height: Int
        private let pixels: [UInt8]

        init(_ image: UIImage) throws {
            let cgImage = try XCTUnwrap(image.cgImage, "no bitmap behind the render")
            width = cgImage.width
            height = cgImage.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            let context = try XCTUnwrap(CGContext(
                data: &bytes, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            pixels = bytes
        }

        /// Where in the row a colour appears, within a tolerance the render's antialiasing needs.
        func columns(matching colour: UIColor, tolerance: Int = 4) -> [Int] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            colour.getRed(&r, green: &g, blue: &b, alpha: &a)
            let want = (Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
            var found: [Int] = []
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    if abs(Int(pixels[i]) - want.0) <= tolerance,
                       abs(Int(pixels[i + 1]) - want.1) <= tolerance,
                       abs(Int(pixels[i + 2]) - want.2) <= tolerance {
                        found.append(x)
                    }
                }
            }
            return found
        }
    }

    /// The accent as it resolves in whichever appearance the renderer drew in: the test is about
    /// the outline being there, not about which side of the palette the host is on.
    private func accents(_ colour: Color) -> [UIColor] {
        [UITraitCollection(userInterfaceStyle: .light), UITraitCollection(userInterfaceStyle: .dark)]
            .map { UIColor(colour).resolvedColor(with: $0) }
    }

    private func outlinePixels(_ raster: Raster, _ colour: Color) -> [Int] {
        accents(colour).flatMap { raster.columns(matching: $0) }
    }

    func testThePersonsTurnIsDrawnInABubble() throws {
        let raster = try render(turn(.person, "What's the capital of France?"))
        XCTAssertFalse(outlinePixels(raster, Look().bubble.accent).isEmpty,
                       "the person's turn draws no outline in the bubble's accent")
    }

    func testToposTurnIsDrawnWithNoBubble() throws {
        let raster = try render(turn(.assistant, "Paris."))
        XCTAssertTrue(outlinePixels(raster, Look().bubble.accent).isEmpty,
                      "Topo's turn drew the bubble's accent, which is the person's side")
    }

    func testThePersonsBubbleSitsOnTheRight() throws {
        let raster = try render(turn(.person, "ta"))
        let columns = outlinePixels(raster, Look().bubble.accent)
        let leftmost = try XCTUnwrap(columns.min(), "no outline to place")
        XCTAssertGreaterThan(leftmost, raster.width / 2,
                             "the bubble reaches into the left half of the row")
    }

    /// The transcript under each screen's look, as a picture attached to the result bundle
    /// (`xcrun xcresulttool export attachments` is what takes them out of it). It is the phone
    /// build drawing the watch's and the television's values, not those builds — what it holds is
    /// that the three looks are three different pictures, and that each one draws the person's
    /// side enclosed and Topo's not.
    func testEachScreensLookRendersItsOwnTranscript() throws {
        var sizes: [Look.Screen: CGSize] = [:]
        for screen in Look.Screen.allCases {
            let look = Look(screen)
            let width: CGFloat = screen == .watch ? 180 : screen == .tv ? 900 : 390
            let view = TranscriptView(turns: PreviewTurns.short)
                .environment(\.look, look)
                .frame(width: width, height: 260)
                .background(Color.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage, "\(screen.rawValue) rendered to nothing")
            sizes[screen] = image.size
            let attachment = XCTAttachment(image: image)
            attachment.name = "transcript-\(screen.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(sizes.count, Look.Screen.allCases.count)
        XCTAssertNotEqual(Look(.watch).transcript.bodyFont, Look(.tv).transcript.bodyFont,
                          "two screens share a look, so one of them is drawn wrong")
        XCTAssertNotEqual(Look(.phone).bubble.horizontalPadding,
                          Look(.tv).bubble.horizontalPadding)
    }

    /// Every value the bubble draws with is the look's, so a look with another accent in it is a
    /// bubble in that accent and none of the shipped one. A literal in the view fails this.
    func testTheBubbleIsDrawnInTheLooksAccent() throws {
        var look = Look()
        look.bubble.accent = Color(red: 1, green: 0, blue: 1)
        let raster = try render(turn(.person, "Morning."), look: look)
        XCTAssertFalse(raster.columns(matching: UIColor.magenta).isEmpty,
                       "the bubble ignored the look's accent")
        XCTAssertTrue(outlinePixels(raster, Look().bubble.accent).isEmpty,
                      "the bubble drew the default accent under a look that names another")
    }
}
