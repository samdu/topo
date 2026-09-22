import CryptoKit
import XCTest
@testable import TopoUserland

/// Claude Code between the downloader's file and the guest, with the guest a counting double:
/// only the pinned binary is made executable and mounted, and a relaunch copies nothing.
final class ClaudeCodeInstallerTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        home = fm.temporaryDirectory.appendingPathComponent("claude-code-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    /// Writes `bytes` as the binary in its home, the way the downloader leaves it (no execute
    /// bit), and returns it with the pin that matches it.
    private func binary(_ bytes: Data, version: String = "2.1.278") throws -> (URL, ClaudeCodePin) {
        let url = home.appendingPathComponent("claude")
        try bytes.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (url, ClaudeCodePin(version: version, size: Int64(bytes.count), sha256: digest))
    }

    private func mode(_ url: URL) throws -> Int {
        try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testABinaryOfThePinnedSizeWithTheWrongDigestIsNeitherMountedNorExecutable() throws {
        let (url, pin) = try binary(Data(repeating: 7, count: 4096))
        // Same size, one byte different, and executable: what a swapped or corrupted file at the
        // pinned length is, even one an earlier install had already allowed to run.
        var other = Data(repeating: 7, count: 4096)
        other[100] = 8
        try other.write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let guest = CountingMounts()

        XCTAssertThrowsError(try ClaudeCodeInstaller(binary: url, pin: pin).install(into: guest)) { error in
            XCTAssertEqual(error as? ClaudeCodeInstaller.Failure, .wrongDigest)
        }
        XCTAssertEqual(guest.mounts.count, 0, "an unverified binary was mounted")
        XCTAssertEqual(guest.links.count, 0, "an unverified binary was linked")
        XCTAssertEqual(try mode(url) & 0o111, 0, "an unverified binary was left executable")
    }

    func testATruncatedBinaryIsNeverMounted() throws {
        let bytes = Data(repeating: 1, count: 4096)
        let (url, pin) = try binary(bytes)
        try bytes.prefix(4000).write(to: url)
        let guest = CountingMounts()

        XCTAssertThrowsError(try ClaudeCodeInstaller(binary: url, pin: pin).install(into: guest)) { error in
            XCTAssertEqual(error as? ClaudeCodeInstaller.Failure, .wrongSize(expected: 4096, got: 4000))
        }
        XCTAssertEqual(guest.mounts.count, 0)
        XCTAssertEqual(guest.links.count, 0)
    }

    func testAMissingBinaryIsNeverMounted() throws {
        let (url, pin) = try binary(Data(repeating: 1, count: 16))
        try fm.removeItem(at: url)
        let guest = CountingMounts()
        XCTAssertThrowsError(try ClaudeCodeInstaller(binary: url, pin: pin).install(into: guest))
        XCTAssertEqual(guest.mounts.count, 0)
    }

    /// The pinned binary's own home is what the guest mounts, and the guest's name for it is a link
    /// into that mount: one copy, the downloader's.
    func testThePinnedBinaryIsMountedFromItsHomeAndLinked() throws {
        let (url, pin) = try binary(Data(repeating: 3, count: 1024))
        let guest = CountingMounts()

        let installed = try ClaudeCodeInstaller(binary: url, pin: pin).install(into: guest)
        XCTAssertEqual(installed.version, "2.1.278")
        XCTAssertEqual(installed.command, "/usr/local/bin/claude")
        XCTAssertEqual(guest.mounts.map(\.host), [home])
        XCTAssertEqual(guest.mounts.map(\.point), ["/opt/claude-code"])
        XCTAssertEqual(guest.links.map(\.target), ["/opt/claude-code/claude"])
        XCTAssertEqual(guest.links.map(\.path), ["/usr/local/bin/claude"])
        XCTAssertEqual(try mode(url) & 0o111, 0o111, "the guest cannot exec a file with no execute bit")
    }

    /// A relaunch finds the binary in place and copies nothing: the file is the same file, unwritten,
    /// its home holds what it held, and what is mounted is still the downloader's own home.
    func testARelaunchCopiesNothing() throws {
        let (url, pin) = try binary(Data(repeating: 5, count: 64 * 1024))
        let first = CountingMounts()
        _ = try ClaudeCodeInstaller(binary: url, pin: pin).install(into: first)
        let before = try Snapshot(of: url, in: home)

        let relaunch = CountingMounts()
        _ = try ClaudeCodeInstaller(binary: url, pin: pin).install(into: relaunch)
        let after = try Snapshot(of: url, in: home)

        XCTAssertEqual(after, before, "the relaunch wrote the binary or its home")
        XCTAssertEqual(relaunch.mounts.map(\.host), [home], "the relaunch mounted something other than the home")
    }
}

/// What a copy would change: the file's identity and modification time, and what its home holds.
struct Snapshot: Equatable {
    let inode: UInt64
    let modified: Date
    let size: Int64
    let listing: [String]

    init(of file: URL, in home: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        inode = try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
        modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        size = try XCTUnwrap(attributes[.size] as? Int64)
        listing = try FileManager.default.contentsOfDirectory(atPath: home.path).sorted()
    }
}

/// The guest as the installer sees it, counting what it was asked to mount and link.
final class CountingMounts: GuestMounts, @unchecked Sendable {
    private let lock = NSLock()
    private var mounted: [(host: URL, point: String)] = []
    private var linked: [(target: String, path: String)] = []

    var mounts: [(host: URL, point: String)] { lock.withLock { mounted } }
    var links: [(target: String, path: String)] { lock.withLock { linked } }

    func mount(_ host: URL, at point: String) throws {
        lock.withLock { mounted.append((host, point)) }
    }

    func link(_ target: String, at path: String) throws {
        lock.withLock { linked.append((target, path)) }
    }
}
