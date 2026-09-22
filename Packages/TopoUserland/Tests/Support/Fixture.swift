import Foundation
import XCTest
import TopoUserland

/// Alpine's minirootfs, the pinned tarball, handed to the test runner as
/// `TEST_RUNNER_TOPO_USERLAND_ROOTFS` (a path; `scripts/fetch-pinned.sh alpine-minirootfs` fetches and verifies it)
/// and pinned by the app's manifest, which is read from the repository rather than copied here.
enum Fixture {
    static let variable = "TOPO_USERLAND_ROOTFS"

    static func rootfs() throws -> (url: URL, pin: RootfsPin) {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("missing coverage: no rootfs; set TEST_RUNNER_\(variable) (scripts/fetch-pinned.sh alpine-minirootfs)")
        }
        return (URL(fileURLWithPath: path), try pin())
    }

    /// The manifest's entry for the rootfs, from Apps/Topo/Resources/models.json.
    static func pin() throws -> RootfsPin {
        let file = try XCTUnwrap(try entry("alpine-minirootfs").files.first)
        return RootfsPin(size: file.size, sha256: file.sha256)
    }

    static let claudeVariable = "TOPO_USERLAND_CLAUDE"

    /// Claude Code, the pinned binary, handed to the test runner as
    /// `TEST_RUNNER_TOPO_USERLAND_CLAUDE` (a path; `scripts/fetch-pinned.sh claude-code` fetches
    /// and verifies it), with the manifest's pin for it.
    static func claude() throws -> (url: URL, pin: ClaudeCodePin) {
        guard let path = ProcessInfo.processInfo.environment[claudeVariable], !path.isEmpty else {
            throw XCTSkip("missing coverage: no Claude Code; set TEST_RUNNER_\(claudeVariable) (scripts/fetch-pinned.sh claude-code)")
        }
        return (URL(fileURLWithPath: path), try claudePin())
    }

    /// The manifest's entry for Claude Code.
    static func claudePin() throws -> ClaudeCodePin {
        let model = try entry("claude-code")
        let file = try XCTUnwrap(model.files.first)
        return ClaudeCodePin(version: try XCTUnwrap(model.version, "claude-code has no version"),
                             size: file.size, sha256: file.sha256)
    }

    private struct File: Decodable { let size: Int64; let sha256: String }
    private struct Model: Decodable { let id: String; let version: String?; let files: [File] }
    private struct Manifest: Decodable { let models: [Model] }

    private static func entry(_ id: String) throws -> Model {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/Topo/Resources/models.json")
        let models = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest)).models
        return try XCTUnwrap(models.first { $0.id == id }, "no \(id) entry in \(manifest.path)")
    }
}

/// The one kernel this test process boots, on a fakefs imported once from the fixture. The kernel
/// is process-global, so every test that needs it shares this boot.
enum SharedGuest {
    private static let result: Result<URL, Error> = Result {
        let rootfs = try Fixture.rootfs()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guest-\(UUID().uuidString)", isDirectory: true)
        let installer = RootfsInstaller(directory: directory)
        try installer.install(from: rootfs.url, pin: rootfs.pin)
        try Guest.shared.boot(fakefs: installer.fakefs)
        return installer.fakefs
    }

    /// The booted fakefs, booting it on first use.
    static func booted() throws -> URL { try result.get() }
}
