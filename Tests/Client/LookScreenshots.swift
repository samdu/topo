import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// The same screen under two looks, in both appearances, as four pictures attached to the result
/// bundle. Nothing here asserts what they look like — that is what the render suites are for, and
/// what a person's eye is for. What it asserts is that the two looks really are two pictures in
/// both appearances, so an attachment that shows no difference is a failure and not a screenshot
/// somebody has to squint at.
///
/// `xcrun xcresulttool export attachments` is what takes them out of the bundle.
@MainActor
final class LookScreenshots: XCTestCase {
    /// A document that changes the palette, the material and the padding, and nothing else: the
    /// three things a look is judged on by eye.
    static let document = """
    {
      "transcript": {
        "spacing": 22,
        "horizontalPadding": 26,
        "text": ["#2A1A05", "#F6ECE0"],
        "caption": ["#7A5C33", "#C6AE8E"]
      },
      "bubble": {
        "accent": ["#7A4E00", "#FFC46B"],
        "fillOpacity": 0.18,
        "surface": "material",
        "cornerRadius": 8,
        "horizontalPadding": 22,
        "verticalPadding": 16
      },
      "jewel": {
        "cast": "#7A4E00",
        "castOpacity": 0.8
      },
      "badge": { "size": 36, "markSize": 23 },
      "composer": {
        "surface": "material",
        "tint": ["#7A4E00", "#FFC46B"],
        "verticalInset": 12,
        "cornerRadius": 20
      }
    }
    """

    func testTheSameScreenUnderTwoLooksInBothAppearances() throws {
        let reading = LookDocument.read(Self.document)
        XCTAssertEqual(reading.notes, [], "the screenshot document does not read")

        for (name, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
            // A transcript that fits its stage: one taller than it scrolls to its end and comes
            // to rest a pixel or two apart between two drawings, and this asks whether two
            // drawings differ. Drawn long, the difference could be that drift rather than the
            // document.
            let canvas = ChatCanvas(turns: PreviewTurns.fitting, row: .writing)
            _ = try LookStage.image(canvas, look: Look(), style: style)
            let compiled = try LookStage.image(canvas, look: Look(), style: style)
            let written = try LookStage.image(canvas, look: reading.look, style: style)
            // And compared the way the render server's drawings are compared, so a difference of
            // a shade along an antialiased edge is not read as the document either.
            XCTAssertTrue(try LookStage.differ(try LookStage.bytes(compiled),
                                               try LookStage.bytes(written)),
                          "\(name): the document changed no more of the chat than a shade")
            attach(compiled, "chat-default-\(name)")
            attach(written, "chat-document-\(name)")
        }
    }

    private func attach(_ image: UIImage, _ name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
