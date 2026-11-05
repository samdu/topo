import Foundation
import TopoTools
import XCTest

/// The guest's git identity, run with the Mac's own git: `Process` exists only here, not in the
/// simulator the guest's script tests run in. The environment is `GuestTools.environment` as the
/// app hands it to the guest, and the commit's committer is what the githubpr channel reads.
final class GitIdentityTests: XCTestCase {
    /// A repository whose own config names someone else, by `user.*` and by `committer.*`, still
    /// commits as Topo: configuration from the environment outranks the repository's.
    func testTheGuestCommitsAsTopoWhateverTheRepositorySays() throws {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { throw XCTSkip("no git on this Mac") }
        for keys in [["user.name", "user.email"], ["committer.name", "committer.email"]] {
            let repo = FileManager.default.temporaryDirectory.appendingPathComponent("git-identity-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: repo) }
            var environment = ProcessInfo.processInfo.environment
            // Hermetic: nothing of the runner's own that would outrank the guest's environment.
            for name in ["GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
                         "GIT_CONFIG_PARAMETERS", "GIT_DIR", "GIT_WORK_TREE"] {
                environment[name] = nil
            }
            // None of the Mac's person's configuration: a signing key there would be asked for.
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            try run(git, ["-C", repo.path, "init", "-q"], environment)
            try run(git, ["-C", repo.path, "config", keys[0], "Someone Else"], environment)
            try run(git, ["-C", repo.path, "config", keys[1], "someone@example.invalid"], environment)
            environment.merge(GuestTools.environment) { _, guest in guest }
            try run(git, ["-C", repo.path, "commit", "-q", "--allow-empty", "-m", "x"], environment)
            let identity = try run(git, ["-C", repo.path, "log", "-1", "--format=%cn %ce|%an %ae"], environment)
            let topo = "\(GuestTools.commitName) \(GuestTools.commitEmail)"
            XCTAssertEqual(identity, "\(topo)|\(topo)\n", keys.joined(separator: ", "))
        }
        XCTAssertEqual(GuestTools.commitName, "Topo")
        XCTAssertTrue(GuestTools.commitEmail.hasPrefix("topo@"))
    }

    @discardableResult
    private func run(_ executable: String, _ arguments: [String], _ environment: [String: String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors, as: UTF8.self))
        return String(decoding: output, as: UTF8.self)
    }
}
