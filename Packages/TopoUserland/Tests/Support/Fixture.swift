import Foundation
import XCTest
import TopoUserland

/// Alpine's minirootfs, the pinned tarball, handed to the test runner as
/// `TEST_RUNNER_TOPO_USERLAND_ROOTFS` (a path; `scripts/fetch-rootfs.sh` fetches and verifies it)
/// and pinned by the app's manifest, which is read from the repository rather than copied here.
enum Fixture {
    static let variable = "TOPO_USERLAND_ROOTFS"

    static func rootfs() throws -> (url: URL, pin: RootfsPin) {
        guard let path = ProcessInfo.processInfo.environment[variable], !path.isEmpty else {
            throw XCTSkip("missing coverage: no rootfs; set TEST_RUNNER_\(variable) (scripts/fetch-rootfs.sh)")
        }
        return (URL(fileURLWithPath: path), try pin())
    }

    /// The manifest's entry for the rootfs, from Apps/Topo/Resources/models.json.
    static func pin() throws -> RootfsPin {
        let manifest = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Apps/Topo/Resources/models.json")
        struct File: Decodable { let size: Int64; let sha256: String }
        struct Model: Decodable { let id: String; let files: [File] }
        struct Manifest: Decodable { let models: [Model] }
        let models = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest)).models
        let file = try XCTUnwrap(models.first { $0.id == "alpine-minirootfs" }?.files.first,
                                 "no alpine-minirootfs entry in \(manifest.path)")
        return RootfsPin(size: file.size, sha256: file.sha256)
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
