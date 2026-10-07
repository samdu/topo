import XCTest

@testable import Topo

/// The one read a reply's image makes (`ReplyImages.bytes`): a regular file beneath the home,
/// reached through no link, and nothing else.
final class ReplyImagesTests: XCTestCase {
    private var root: URL!
    private var home: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "reply-images-\(UUID().uuidString)")
        home = root.appending(path: "home")
        try FileManager.default.createDirectory(at: home.appending(path: "charts"), withIntermediateDirectories: true)
        try Data("picture".utf8).write(to: home.appending(path: "charts/sizes.png"))
        try Data("secret".utf8).write(to: root.appending(path: "secret.png"))
        try FileManager.default.createDirectory(at: root.appending(path: "vault"), withIntermediateDirectories: true)
        try Data("note".utf8).write(to: root.appending(path: "vault/a.png"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func link(_ name: String, to target: String) throws {
        try FileManager.default.createSymbolicLink(atPath: home.appending(path: name).path(percentEncoded: false),
                                                   withDestinationPath: target)
    }

    func testAFileUnderTheHomeIsRead() {
        XCTAssertEqual(ReplyImages.bytes(at: "charts/sizes.png", under: home), Data("picture".utf8))
        XCTAssertNil(ReplyImages.bytes(at: "charts/none.png", under: home))
        XCTAssertNil(ReplyImages.bytes(at: "charts", under: home), "a directory was read")
        XCTAssertNil(ReplyImages.bytes(at: "", under: home))
    }

    /// The reader refuses a climbing or absolute path itself, whatever its caller checked.
    func testAPathThatLeavesTheHomeIsNotOpened() {
        for path in ["../secret.png", "charts/../../secret.png", "charts/../charts/sizes.png", "./charts/sizes.png",
                     root.appending(path: "secret.png").path(percentEncoded: false), "/etc/hosts"] {
            XCTAssertNil(ReplyImages.bytes(at: path, under: home), path)
        }
    }

    /// A link is followed nowhere along the path: not as the file, not as a directory on the
    /// way to it (the home's `memory` is one, to the vault), and not as the home itself.
    func testNoLinkIsFollowed() throws {
        try link("out.png", to: root.appending(path: "secret.png").path(percentEncoded: false))
        try link("near.png", to: "charts/sizes.png")
        try link("memory", to: root.appending(path: "vault").path(percentEncoded: false))
        try link("inner", to: "charts")
        XCTAssertNil(ReplyImages.bytes(at: "out.png", under: home), "a link out of the home was followed")
        XCTAssertNil(ReplyImages.bytes(at: "near.png", under: home), "a link inside the home was followed")
        XCTAssertNil(ReplyImages.bytes(at: "memory/a.png", under: home), "the memory was read through its link")
        XCTAssertNil(ReplyImages.bytes(at: "inner/sizes.png", under: home), "a linked directory was walked")

        let linked = root.appending(path: "linked-home")
        try FileManager.default.createSymbolicLink(atPath: linked.path(percentEncoded: false),
                                                   withDestinationPath: home.path(percentEncoded: false))
        XCTAssertNil(ReplyImages.bytes(at: "charts/sizes.png", under: linked), "a link standing as the home was followed")
        XCTAssertNil(ReplyImages.bytes(at: "a.png", under: root.appending(path: "none")), "a home that is not there was read")
    }

    /// Only a regular file within the limit is read: a pipe would hold the read open, and a
    /// file past the limit is not read in part.
    func testOnlyARegularFileWithinTheLimitIsRead() throws {
        XCTAssertEqual(mkfifo(home.appending(path: "pipe.png").path(percentEncoded: false), 0o600), 0)
        XCTAssertNil(ReplyImages.bytes(at: "pipe.png", under: home), "a pipe was read")
        XCTAssertEqual(ReplyImages.bytes(at: "charts/sizes.png", under: home, limit: 7), Data("picture".utf8))
        XCTAssertNil(ReplyImages.bytes(at: "charts/sizes.png", under: home, limit: 6), "a file over the limit was read")
    }
}
