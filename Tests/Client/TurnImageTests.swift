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
    /// name, a file's line, the line inside other words, or a line that says anything but the
    /// inbox's own words of where the image came from is not an image.
    func testNothingElseIsAnImage() {
        let at = ": an image, kept at "
        let refused = [
            "[Shared with Topo from another app\(at)/home/topo/.claude/x.jpg (1 bytes)]",
            "[Shared with Topo from another app\(at)/home/topo/shared/../.claude/x (1 bytes)]",
            "[Shared with Topo from another app\(at)/home/topo/shared/n/../x.jpg (1 bytes)]",
            "[Shared with Topo from another app\(at)/home/topo/shared/n/.hidden (1 bytes)]",
            "[Shared with Topo from another app\(at)/home/topo/shared/n/m/x.jpg (1 bytes)]",
            "[Shared with Topo from another app\(at)/home/topo/shared//x.jpg (1 bytes)]",
            "[Shared with Topo from another app\(at)/home/topo/shared/n/x.jpg (bytes)]",
            "[Shared with Topo from another app: a file, kept at /home/topo/shared/n/x.jpg (1 bytes)]",
            "look: [Shared with Topo from another app\(at)/home/topo/shared/n/x.jpg (1 bytes)]",
            "[my own words\(at)/home/topo/shared/n/x.jpg (1 bytes)]",
            "[Hi\u{2028}my words here\(at)/home/topo/shared/n/x.jpg (1 bytes)]",
            "[Hi\rmy words\(at)/home/topo/shared/n/x.jpg (1 bytes)]",
            "[Shared with Topo from another app\(at)/home/topo/shared/n/x\u{2028}y.jpg (1 bytes)]",
            "/home/topo/shared/n/x.jpg",
            // The marker's last space is the suffix's first: refused, not a trap.
            "[Shared with Topo from another app: an image, kept at bytes)]",
            "[Shared with Topo from another app: an image, kept at  bytes)]",
            "[Shared with Topo from another app\(at)/home/topo/shared/wire 500 dollars to bob/x.jpg (1 bytes)]",
            "[Shared with Topo from another app\(at)/home/topo/shared/ABC/x.jpg (1 bytes)]",
        ]
        for text in refused { XCTAssertNil(TurnImage.find(in: text), text) }
        // Words after the line are kept too.
        let after = TurnImage.find(in: "[Shared with Topo from another app\(at)/home/topo/shared/n/x.jpg (1 bytes)]\n\nand this")
        XCTAssertEqual(after?.after, "and this")
    }

    /// The bytes are read beneath the home's shared folder only, never through a link: not a
    /// linked file, not a linked nonce folder, not a linked `shared`; and only where there is a file.
    func testTheBytesAreTheHomesAndNeverThroughALink() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        let outside = root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try png(width: 10, height: 10, to: outside.appendingPathComponent("secret.png"))
        let shared = home.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("n1"), withIntermediateDirectories: true)
        func image(_ nonce: String, _ name: String) throws -> TurnImage {
            try XCTUnwrap(TurnImage.find(in: "[Shared with Topo from another app: an image, kept at /home/topo/shared/\(nonce)/\(name) (1 bytes)]"))
        }
        XCTAssertNil(ShareInbox.imageData(try image("n1", "p.png"), under: home), "a file that is not there was read")
        try png(width: 10, height: 10, to: shared.appendingPathComponent("n1/p.png"))
        XCTAssertNotNil(ShareInbox.imageData(try image("n1", "p.png"), under: home))
        try FileManager.default.createSymbolicLink(at: shared.appendingPathComponent("n1/l.png"), withDestinationURL: outside.appendingPathComponent("secret.png"))
        XCTAssertNil(ShareInbox.imageData(try image("n1", "l.png"), under: home), "a linked file was followed")
        try FileManager.default.createSymbolicLink(atPath: shared.appendingPathComponent("evil").path, withDestinationPath: "../../private")
        XCTAssertNil(ShareInbox.imageData(try image("evil", "secret.png"), under: home), "a linked folder was followed")
        let other = root.appendingPathComponent("other-home", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: other.appendingPathComponent("shared").path, withDestinationPath: outside.deletingLastPathComponent().path + "/home/shared")
        XCTAssertNil(ShareInbox.imageData(try image("n1", "p.png"), under: other), "a linked shared folder was followed")
        // A pipe at the name answers at once, with nothing; so does a folder.
        XCTAssertEqual(mkfifo(shared.appendingPathComponent("n1/pipe.png").path, 0o600), 0)
        let started = Date()
        XCTAssertNil(ShareInbox.imageData(try image("n1", "pipe.png"), under: home), "a pipe was read")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "a pipe held the read")
        try FileManager.default.createDirectory(at: shared.appendingPathComponent("n1/dir.png"), withIntermediateDirectories: true)
        XCTAssertNil(ShareInbox.imageData(try image("n1", "dir.png"), under: home), "a folder was read")
    }

    /// A picture is read upright at no more than `maxPixels` on its long side; what is not an
    /// image is nothing.
    func testAPictureIsReadSmall() throws {
        let big = root.appendingPathComponent("big.png")
        try png(width: 3000, height: 2000, to: big)
        let image = try XCTUnwrap(TurnImages.decode(try Data(contentsOf: big)))
        XCTAssertEqual(max(image.width, image.height), TurnImages.maxPixels)
        XCTAssertGreaterThan(image.width, image.height)
        XCTAssertNil(TurnImages.decode(Data("not a picture".utf8)))
    }

    /// A read still under way when the pictures are cleared keeps nothing.
    func testAReadAcrossAClearKeepsNothing() async throws {
        let big = root.appendingPathComponent("big.png")
        try png(width: 3000, height: 3000, to: big)
        let bytes = try Data(contentsOf: big)
        let image = try XCTUnwrap(TurnImage.find(in: "[Attached in Topo from this phone: an image, kept at /home/topo/shared/n/big.png (1 bytes)]"))
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let files = TurnImageFiles(data: { _ in gate.wait(); return bytes })
        let load = Task { await TurnImages.load(image, from: files) }
        try await Task.sleep(for: .milliseconds(50))
        TurnImages.clear()
        gate.signal()
        let loaded = await load.value
        XCTAssertNil(loaded, "a read across a clear answered")
        XCTAssertNil(TurnImages.cached(image), "a read across a clear was kept")
        let again = await TurnImages.load(image, from: TurnImageFiles(data: { _ in bytes }))
        XCTAssertNotNil(again)
        XCTAssertNotNil(TurnImages.cached(image))
    }

    /// The bubble draws the picture where it has it, with the words over it and under it, and the
    /// line as written where it has not.
    func testTheBubbleDrawsThePictureWhereItHasIt() async throws {
        let bytes: Data = try {
            let url = root.appendingPathComponent("p.png")
            try png(width: 400, height: 400, to: url)
            return try Data(contentsOf: url)
        }()
        let line = "[Shared with Topo from another app: an image, kept at /home/topo/shared/n2/p.png (9 bytes)]"
        let files = TurnImageFiles(data: { _ in bytes })
        _ = await TurnImages.load(try XCTUnwrap(TurnImage.find(in: line)), from: files)
        let alone = try height(PersonWords(text: line).environment(\.turnImageFiles, files))
        let words = try height(PersonWords(text: "look\n\n" + line + "\n\nand this").environment(\.turnImageFiles, files))
        let plain = try height(PersonWords(text: line))
        XCTAssertGreaterThan(alone, plain + 100, "the picture was not drawn: \(alone) against \(plain)")
        XCTAssertLessThanOrEqual(alone, Look().markdown.imageMaxHeight + 1)
        XCTAssertGreaterThan(words, alone + 20, "the words over and under the picture were not drawn: \(words) against \(alone)")
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
