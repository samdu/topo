import CryptoKit
import XCTest
@testable import TopoUserland

/// Claude Code in the booted guest. The kernel is process-global and a real relaunch is a fresh
/// one with nothing mounted, so each launch a test plays is a mount point and a command name of its
/// own; the binary is a stand-in script of a fixed size that says which version it is, except in
/// the one test that runs the pinned binary itself.
final class ClaudeCodeGuestTests: XCTestCase {
    private var home: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
        home = fm.temporaryDirectory.appendingPathComponent("claude-home-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: home)
    }

    private var binary: URL { home.appendingPathComponent("claude") }

    /// A stand-in for the binary: `--version` prints `version`, and it says on stderr whether its
    /// updater was turned off. Padded to one size whatever the version, so two versions share the
    /// pinned length and only the digest tells them apart.
    private func standIn(_ version: String) -> Data {
        var script = """
        #!/bin/sh
        [ "$1" = "--version" ] && echo "\(version) (Claude Code)"
        echo "DISABLE_AUTOUPDATER=${DISABLE_AUTOUPDATER-unset}" >&2

        """
        script += "#" + String(repeating: "x", count: 512 - script.utf8.count - 2) + "\n"
        return Data(script.utf8)
    }

    private func pin(_ data: Data, _ version: String) -> ClaudeCodePin {
        ClaudeCodePin(version: version, size: Int64(data.count),
                      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    /// Lands `data` as the downloader does: a new file moved over the old one, without the
    /// execute bit.
    private func deliver(_ data: Data) throws {
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: temp)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temp.path)
        if fm.fileExists(atPath: binary.path) { try fm.removeItem(at: binary) }
        try fm.moveItem(at: temp, to: binary)
    }

    /// One launch's installer: its own mount point and command, as a fresh kernel would have.
    private func launch(_ name: String, _ pin: ClaudeCodePin) -> ClaudeCodeInstaller {
        ClaudeCodeInstaller(binary: binary, pin: pin, mountPoint: "/opt/\(name)", command: "/usr/local/bin/\(name)")
    }

    private func run(_ command: String) async throws -> Guest.Exit {
        try await Guest.shared.run("/bin/sh", ["-c", command])
    }

    func testABinaryWithTheWrongDigestCannotRunInTheGuest() async throws {
        let good = standIn("2.1.278")
        try deliver(good)
        let name = "claude-rf1-\(UUID().uuidString.prefix(8))"
        _ = try launch(name, pin(good, "2.1.278")).install(into: Guest.shared)
        let ran = try await run("\(name) --version")
        XCTAssertEqual(ran.output, "2.1.278 (Claude Code)\n", ran.errors)

        // The same length, a different build, written over the file in place so it keeps the
        // execute bit the first install gave it and the mount the guest already has.
        let swapped = standIn("6.6.666")
        XCTAssertEqual(swapped.count, good.count)
        try swapped.write(to: binary)
        XCTAssertThrowsError(try launch(name, pin(good, "2.1.278")).install(into: Guest.shared)) { error in
            XCTAssertEqual(error as? ClaudeCodeInstaller.Failure, .wrongDigest)
        }
        let refused = try await run("\(name) --version")
        XCTAssertNotEqual(refused.status, 0, "the swapped binary ran: \(refused.output)")
        XCTAssertFalse(refused.output.contains("6.6.666"), "the swapped binary ran")

        // A fresh launch on the wrong file: nothing mounted, nothing linked, nothing to run.
        let fresh = "claude-rf1-\(UUID().uuidString.prefix(8))"
        XCTAssertThrowsError(try launch(fresh, pin(good, "2.1.278")).install(into: Guest.shared))
        let absent = try await run("\(fresh) --version")
        XCTAssertEqual(absent.status, 127, "a binary that failed its digest is reachable: \(absent.output)")
    }

    /// A bump: pin A installed, the manifest moved to B, and the launches after it. While the
    /// downloader has not yet replaced A the new pin refuses it; once B is there the guest runs B,
    /// and the launch after that copies nothing.
    func testABumpRunsTheNewVersionAndTheLaunchAfterCopiesNothing() async throws {
        let a = standIn("2.1.278"), b = standIn("2.1.300")
        try deliver(a)
        let first = "claude-bump-\(UUID().uuidString.prefix(8))"
        _ = try launch(first, pin(a, "2.1.278")).install(into: Guest.shared)
        let ranA = try await run("\(first) --version")
        XCTAssertEqual(ranA.output, "2.1.278 (Claude Code)\n", ranA.errors)

        // The app updated to pin B; B has not arrived yet, so A is still the file in the home.
        let waiting = "claude-bump-\(UUID().uuidString.prefix(8))"
        XCTAssertThrowsError(try launch(waiting, pin(b, "2.1.300")).install(into: Guest.shared)) { error in
            XCTAssertEqual(error as? ClaudeCodeInstaller.Failure, .wrongDigest)
        }
        let stale = try await run("\(waiting) --version")
        XCTAssertEqual(stale.status, 127, "the old version ran under the new pin: \(stale.output)")

        try deliver(b)
        let second = "claude-bump-\(UUID().uuidString.prefix(8))"
        _ = try launch(second, pin(b, "2.1.300")).install(into: Guest.shared)
        let ranB = try await run("\(second) --version")
        XCTAssertEqual(ranB.output, "2.1.300 (Claude Code)\n", ranB.errors)
        let before = try Snapshot(of: binary, in: home)

        let third = "claude-bump-\(UUID().uuidString.prefix(8))"
        _ = try launch(third, pin(b, "2.1.300")).install(into: Guest.shared)
        let again = try await run("\(third) --version")
        XCTAssertEqual(again.output, "2.1.300 (Claude Code)\n", again.errors)
        XCTAssertEqual(try Snapshot(of: binary, in: home), before, "the launch after the bump copied the binary")
    }

    /// What every launch path hands the guest turns Claude Code's updater off: read by the program
    /// itself, from the environment `Guest.run` gives when it is given none.
    func testTheGuestEnvironmentTurnsTheUpdaterOff() async throws {
        XCTAssertEqual(Guest.environment["DISABLE_AUTOUPDATER"], "1")
        let data = standIn("2.1.278")
        try deliver(data)
        let name = "claude-env-\(UUID().uuidString.prefix(8))"
        _ = try launch(name, pin(data, "2.1.278")).install(into: Guest.shared)
        let exit = try await run("\(name) --version")
        XCTAssertEqual(exit.status, 0, exit.errors)
        XCTAssertEqual(exit.errors, "DISABLE_AUTOUPDATER=1\n")
    }

    /// The pinned binary itself, mounted where the app mounts it: the guest runs it by its name,
    /// and it says it is the pinned version.
    func testTheGuestRunsThePinnedClaudeCode() async throws {
        let (url, pin) = try Fixture.claude()
        let installed = try ClaudeCodeInstaller(binary: url, pin: pin).install(into: Guest.shared)
        XCTAssertEqual(installed.command, "/usr/local/bin/claude")
        let exit = try await run("claude --version")
        XCTAssertEqual(exit.status, 0, exit.errors)
        XCTAssertTrue(exit.output.hasPrefix("\(pin.version) "), "claude --version printed \(exit.output)")
    }
}
