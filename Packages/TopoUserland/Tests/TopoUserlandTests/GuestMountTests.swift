import XCTest
import TopoUserland

/// The two calls Claude Code is reached through, in the booted guest: a bind mount that is left
/// alone when asked for again and refuses a second source at its point, and a link that is left
/// alone, replaced when it points elsewhere, and never put over something that is not a link.
final class GuestMountTests: XCTestCase {
    private let fm = FileManager.default
    private var hosts: [URL] = []

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        hosts.forEach { try? fm.removeItem(at: $0) }
    }

    /// A host directory holding one file whose text names it.
    private func host(_ name: String) throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("mount-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("\(name)\n".utf8).write(to: url.appendingPathComponent("which"))
        hosts.append(url)
        return url
    }

    private func sh(_ command: String) async throws -> Guest.Exit {
        try await Guest.shared.run("/bin/sh", ["-c", command])
    }

    func testTheSameMountIsLeftAloneAndASecondSourceIsRefused() async throws {
        let a = try host("a"), b = try host("b")
        let point = "/opt/mount-\(UUID().uuidString.prefix(8))"

        try Guest.shared.mount(a, at: point)
        try Guest.shared.mount(a, at: point)
        let mounts = try await sh("grep -c ' \(point) ' /proc/mounts")
        XCTAssertEqual(mounts.output, "1\n", "asking for the same mount again stacked a second one")

        XCTAssertThrowsError(try Guest.shared.mount(b, at: point)) { error in
            XCTAssertEqual(error as? Guest.Failure, .mount(-16), "a second source was not refused with EBUSY")
        }
        let which = try await sh("cat \(point)/which; grep -c ' \(point) ' /proc/mounts")
        XCTAssertEqual(which.output, "a\n1\n", "the refused source reached the point")
    }

    func testALinkIsLeftAloneReplacedWhenItPointsElsewhereAndNeverPutOverAFile() async throws {
        let path = "/usr/local/bin/link-\(UUID().uuidString.prefix(8))"

        try Guest.shared.link("/opt/a/claude", at: path)
        try Guest.shared.link("/opt/a/claude", at: path)
        let first = try await sh("readlink \(path)")
        XCTAssertEqual(first.output, "/opt/a/claude\n")

        try Guest.shared.link("/opt/b/claude", at: path)
        let replaced = try await sh("readlink \(path)")
        XCTAssertEqual(replaced.output, "/opt/b/claude\n", "a link pointing elsewhere was not replaced")

        let file = "/usr/local/bin/file-\(UUID().uuidString.prefix(8))"
        _ = try await sh("echo keep > \(file)")
        XCTAssertThrowsError(try Guest.shared.link("/opt/a/claude", at: file)) { error in
            XCTAssertEqual(error as? Guest.Failure, .link(-17), "a file at the path was not refused with EEXIST")
        }
        let kept = try await sh("[ -L \(file) ] && echo link; cat \(file)")
        XCTAssertEqual(kept.output, "keep\n", "the file at the path was replaced")
    }
}
