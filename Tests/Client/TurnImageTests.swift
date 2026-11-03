import ImageIO
import SwiftUI
import TopoUserland
import UniformTypeIdentifiers
import XCTest

@testable import Topo

/// The line a shared or attached image leaves in a turn is read back as the picture, and nothing
/// else in a turn's words is ever read as a path.
@MainActor
final class TurnImageTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("turn-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        TurnImages.clear()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        TurnImages.clear()
    }

    private func share(note: String, file: String) -> Share {
        Share(nonce: "ABC-123", login: "login", time: Date(), kind: .image, note: note, text: nil, file: file, bytes: 2048)
    }

    /// The folder the parser trusts is the one the inbox writes under.
    func testTheSharedFolderIsTheInboxs() {
        XCTAssertEqual(TurnImage.sharedFolder, ClaudeLauncher.home + "/" + ShareInbox.folder + "/")
    }

    /// What `ShareInbox.text` writes for an image reads back as that image, the note ahead of it.
    func testTheInboxsLineReadsBack() throws {
        let path = TurnImage.sharedFolder + "abc-123/Photo (1) 2026-11-02 09-15-03.jpg"
        let text = try XCTUnwrap(ShareInbox.text(share(note: "what is this?", file: "Photo (1) 2026-11-02 09-15-03.jpg"), path: path))
        let image = try XCTUnwrap(TurnImage.find(in: text), text)
        XCTAssertEqual(image.path, path)
        XCTAssertEqual(image.nonce, "abc-123")
        XCTAssertEqual(image.name, "Photo (1) 2026-11-02 09-15-03.jpg")
        XCTAssertEqual(image.before, "what is this?")
        XCTAssertEqual(image.after, "")
        let bare = try XCTUnwrap(ShareInbox.text(share(note: "", file: "a.jpeg"), path: TurnImage.sharedFolder + "n/a.jpeg"))
        XCTAssertEqual(TurnImage.find(in: bare)?.before, "")
        // The composer's line names it otherwise and reads the same.
        let attached = "[Attached in Topo from this phone: an image, kept at \(TurnImage.sharedFolder)n/b.jpeg (12 bytes)]"
        XCTAssertEqual(TurnImage.find(in: attached)?.name, "b.jpeg")
    }

    /// A line anywhere but the guest's shared folder, a path that leaves it, a hidden or nested
    /// name, a file's line, or the line inside other words is not an image.
    func testNothingElseIsAnImage() {
        let refused = [
            "[Shared with Topo from another app: an image, kept at /home/topo/.claude/x.jpg (1 bytes)]",
            "[Shared with Topo from another app: an image, kept at /home/topo/shared/../.claude/x (1 bytes)]",
            "[Shared with Topo from another app: an image, kept at /home/topo/shared/n/../x.jpg (1 bytes)]",
            "[Shared with Topo from another app: an image, kept at /home/topo/shared/n/.hidden (1 bytes)]",
            "[Shared with Topo from another app: an image, kept at /home/topo/shared/n/m/x.jpg (1 bytes)]",
            "[Shared with Topo from another app: an image, kept at /home/topo/shared//x.jpg (1 bytes)]",
            "[Shared with Topo from another app: an image, kept at /home/topo/shared/n/x.jpg (bytes)]",
            "[Shared with Topo from another app: a file, kept at /home/topo/shared/n/x.jpg (1 bytes)]",
            "look: [Shared with Topo from another app: an image, kept at /home/topo/shared/n/x.jpg (1 bytes)]",
            "[a] [b: an image, kept at /home/topo/shared/n/x.jpg (1 bytes)]",
            "/home/topo/shared/n/x.jpg",
        ]
        for text in refused { XCTAssertNil(TurnImage.find(in: text), text) }
    }

    /// The file is found under the home's shared folder only, and only where it is.
    func testTheFileIsTheHomesAndOnlyWhereItIs() throws {
        let image = try XCTUnwrap(TurnImage.find(in: "[x: an image, kept at /home/topo/shared/n1/p.png (1 bytes)]"))
        XCTAssertNil(ShareInbox.file(image, under: root), "a file that is not there was found")
        let folder = root.appendingPathComponent("shared/n1", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1]).write(to: folder.appendingPathComponent("p.png"))
        XCTAssertEqual(ShareInbox.file(image, under: root)?.lastPathComponent, "p.png")
    }

    /// A picture is read upright at no more than `maxPixels` on its long side; what is not a
    /// regular file of an image is nothing.
    func testAPictureIsReadSmall() throws {
        let big = root.appendingPathComponent("big.png")
        try png(width: 3000, height: 2000, to: big)
        let image = try XCTUnwrap(TurnImages.decode(big))
        XCTAssertEqual(max(image.width, image.height), TurnImages.maxPixels)
        XCTAssertGreaterThan(image.width, image.height)
        let words = root.appendingPathComponent("words.png")
        try Data("not a picture".utf8).write(to: words)
        XCTAssertNil(TurnImages.decode(words))
        let link = root.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: big)
        XCTAssertNil(TurnImages.decode(link), "a link was followed")
    }

    /// The bubble draws the picture where it has it, and the line as written where it has not.
    func testTheBubbleDrawsThePictureWhereItHasIt() async throws {
        let folder = root.appendingPathComponent("shared/n2", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png(width: 400, height: 400, to: folder.appendingPathComponent("p.png"))
        let text = "look\n\n[Shared with Topo from another app: an image, kept at /home/topo/shared/n2/p.png (9 bytes)]"
        let root = root!
        let files = TurnImageFiles(url: { ShareInbox.file($0, under: root) })
        let url = try XCTUnwrap(files.url(try XCTUnwrap(TurnImage.find(in: text))))
        _ = await TurnImages.load(url)
        let drawn = try height(PersonWords(text: text).environment(\.turnImageFiles, files))
        let plain = try height(PersonWords(text: text))
        XCTAssertGreaterThan(drawn, plain + 100, "the picture was not drawn: \(drawn) against \(plain)")
        XCTAssertLessThanOrEqual(drawn, Look().transcript.imageMaxHeight + plain + 20)
    }

    private func height(_ view: some View) throws -> CGFloat {
        let renderer = ImageRenderer(content: view.frame(width: 280))
        renderer.scale = 1
        return CGFloat(try XCTUnwrap(renderer.cgImage).height)
    }

    private func png(width: Int, height: Int, to url: URL) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
