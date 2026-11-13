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

    /// The install's own refusal, naming `path` and saying why, and not some other error that
    /// happens to mention it.
    private func assertRefused(_ path: String, _ why: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GuestTools.install(home: home), file: file, line: line) { error in
            guard let failure = error as? GuestTools.InstallFailure else {
                return XCTFail("not the install's refusal: \(error)", file: file, line: line)
            }
            XCTAssertTrue(failure.description.hasPrefix("\(path) in the guest's home \(why)"),
                          "the refusal names \(path) and says it \(why): \(failure)", file: file, line: line)
        }
    }

    func testAFolderTheGuestLinkedOutTheHomeIsRefusedAndNothingIsWrittenThere() throws {
        try link(".topo/bin", to: "../../outside")
        assertRefused(".topo/bin", "is not a folder")
        XCTAssertTrue(try outsideIsEmpty())
    }

    func testAFolderNearerTheHomeLinkedOutIsRefusedToo() throws {
        try link(".claude", to: "../outside")
        assertRefused(".claude", "is not a folder")
        XCTAssertTrue(try outsideIsEmpty())
    }

    /// A folder where a file goes cannot be renamed over: the install says so, naming the file,
    /// leaves the folder and what is in it as they were, and leaves no hidden name behind.
    func testAFolderWhereAFileGoesIsRefusedLeftAloneAndNoPartIsLeft() throws {
        let folder = home.appendingPathComponent(GuestTools.scriptPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let inside = folder.appendingPathComponent("the guest's own")
        try Data("kept".utf8).write(to: inside)
        assertRefused(GuestTools.scriptPath, "cannot be replaced")
        var isFolder: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder) && isFolder.boolValue)
        XCTAssertEqual(try String(contentsOf: inside, encoding: .utf8), "kept")
        let left = try FileManager.default.subpathsOfDirectory(atPath: home.path).filter { ($0 as NSString).lastPathComponent.hasSuffix(".part") }
        XCTAssertEqual(left, [], "a hidden name is left behind")
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
        let converter = try String(contentsOf: home.appendingPathComponent(GuestTools.doccToMarkdownPath), encoding: .utf8)
        XCTAssertTrue(converter.hasPrefix("# docc2md.jq"), "the converter is TopoTools' resource: " + converter)
        XCTAssertEqual(converter, try GuestTools.doccToMarkdown)
        let left = try FileManager.default.subpathsOfDirectory(atPath: home.path).filter { ($0 as NSString).lastPathComponent.hasSuffix(".part") }
        XCTAssertEqual(left, [], "no hidden name is left behind")
    }
}
