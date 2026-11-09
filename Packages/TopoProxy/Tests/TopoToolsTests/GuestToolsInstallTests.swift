import Foundation
import TopoTools
import XCTest

/// `GuestTools.install` writes into the guest's home, which the guest writes too: a link the guest
/// has put there, at any name the install walks through or writes, sends nothing outside the home.
final class GuestToolsInstallTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("guest-tools-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// What the guest makes with `ln -s ../../outside`: a relative link, which the host follows
    /// from where it stands.
    private func link(_ path: String, to target: String) throws {
        let at = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: at.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: at.path, withDestinationPath: target)
    }

    private func outsideIsEmpty() throws -> Bool {
        try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty
    }

    func testAFolderTheGuestLinkedOutTheHomeIsRefusedAndNothingIsWrittenThere() throws {
        try link(".topo/bin", to: "../../outside")
        XCTAssertThrowsError(try GuestTools.install(home: home)) { error in
            XCTAssertTrue("\(error)".contains(".topo/bin"), "the refusal names the link: \(error)")
        }
        XCTAssertTrue(try outsideIsEmpty())
    }

    func testAFolderNearerTheHomeLinkedOutIsRefusedToo() throws {
        try link(".claude", to: "../outside")
        XCTAssertThrowsError(try GuestTools.install(home: home))
        XCTAssertTrue(try outsideIsEmpty())
    }

    func testALinkWhereAFileGoesIsReplacedAndWhatItNamedIsLeftAlone() throws {
        let target = outside.appendingPathComponent("kept")
        try Data("the guest's own".utf8).write(to: target)
        try link(GuestTools.scriptPath, to: "../../../outside/kept")
        try GuestTools.install(home: home)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "the guest's own")
        let script = home.appendingPathComponent(GuestTools.scriptPath)
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: script.path))
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), GuestTools.script)
    }

    func testTheScriptsAreExecutableTheRestPlainAndASecondInstallReplacesThem() throws {
        try GuestTools.install(home: home)
        let script = home.appendingPathComponent(GuestTools.scriptPath)
        try Data("stale".utf8).write(to: script)
        try GuestTools.install(home: home)
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), GuestTools.script)
        for path in [GuestTools.scriptPath, GuestTools.credentialHelperPath, GuestTools.ghPath, GuestTools.browserPath, GuestTools.appleDocPath] {
            let mode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(path).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o755, path)
        }
        for path in [GuestTools.skillPath, GuestTools.appleDocsSkillPath, GuestTools.doccToMarkdownPath] {
            let mode = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent(path).path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o644, path)
        }
        let left = try FileManager.default.subpathsOfDirectory(atPath: home.path).filter { ($0 as NSString).lastPathComponent.hasSuffix(".part") }
        XCTAssertEqual(left, [], "no hidden name is left behind")
    }
}
