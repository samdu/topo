import Foundation
import XCTest

@testable import TopoCore

/// Carrying the vault's files from one folder to another: what arrives, what is left alone, and
/// what happens to a file already standing where one of them goes. Every test here runs over two
/// temporary directories; the coordination, the security scope and the commit are the caller's and
/// are not exercised here.
final class VaultTransferTests: XCTestCase {
    private let device = DeviceID("phone")
    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    private func makeFolder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-transfer-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to relative: String, in root: URL) {
        let file = relative.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file)
    }

    private func read(_ relative: String, in root: URL) -> String? {
        let file = relative.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func names(in root: URL) -> [String] {
        let entries = VaultTransfer.entries(in: root)
        return (entries.files + entries.skipped).sorted()
    }

    // MARK: What arrives

    func testEveryFileAndTheBaselineArrive() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("# Today", to: "notes/today.md", in: source)
        write("# Groceries", to: "Groceries.md", in: source)
        write("{\"version\":1}", to: ".topo/mirror.json", in: source)

        let outcome = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        XCTAssertEqual(outcome.copied, ["Groceries.md", "notes/today.md"])
        XCTAssertTrue(outcome.baseline)
        XCTAssertEqual(read("notes/today.md", in: destination), "# Today")
        XCTAssertEqual(read("Groceries.md", in: destination), "# Groceries")
        XCTAssertEqual(read(".topo/mirror.json", in: destination), "{\"version\":1}")
        // Nothing is taken off the source: the removal is the caller's, after the commit.
        XCTAssertEqual(names(in: source), [".topo/mirror.json", "Groceries.md", "notes/today.md"])
    }

    func testASourceWithNoBaselineCarriesNone() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("# Today", to: "notes/today.md", in: source)

        let outcome = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        XCTAssertFalse(outcome.baseline)
        XCTAssertNil(read(".topo/mirror.json", in: destination))
    }

    // MARK: What the destination already holds

    func testAFileAlreadyThereWithOtherTextKeepsItsNameAndTheCarriedOneLandsBeside() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("what the phone had", to: "Groceries.md", in: source)
        write("what Obsidian had", to: "Groceries.md", in: destination)

        let outcome = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        XCTAssertEqual(read("Groceries.md", in: destination), "what Obsidian had")
        let copy = try XCTUnwrap(outcome.conflicted["Groceries.md"])
        XCTAssertEqual(copy, "Groceries (Conflicted copy phone 202508240146).md")
        XCTAssertEqual(read(copy, in: destination), "what the phone had")
        XCTAssertFalse(outcome.copied.contains("Groceries.md"))
    }

    func testAFileAlreadyThereWithTheSameTextIsNothingToDo() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("the same", to: "Groceries.md", in: source)
        write("the same", to: "Groceries.md", in: destination)

        let outcome = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        XCTAssertEqual(outcome.identical, ["Groceries.md"])
        XCTAssertTrue(outcome.conflicted.isEmpty)
        XCTAssertEqual(names(in: destination), ["Groceries.md"])
    }

    func testASecondConflictDoesNotTakeTheFirstOnesName() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("what the phone had", to: "Groceries.md", in: source)
        write("what Obsidian had", to: "Groceries.md", in: destination)
        // A copy of that name is already in the destination, so the carried file needs another.
        write("an older copy", to: "Groceries (Conflicted copy phone 202508240146).md", in: destination)

        let outcome = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        let copy = try XCTUnwrap(outcome.conflicted["Groceries.md"])
        XCTAssertEqual(copy, "Groceries (Conflicted copy phone 202508240146 2).md")
        XCTAssertEqual(read("Groceries (Conflicted copy phone 202508240146).md", in: destination),
                       "an older copy")
        XCTAssertEqual(read(copy, in: destination), "what the phone had")
    }

    func testTheDestinationsOwnHiddenFoldersAreLeftAlone() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("# Today", to: "notes/today.md", in: source)
        write("{\"theme\":\"obsidian\"}", to: ".obsidian/appearance.json", in: destination)

        _ = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        XCTAssertEqual(read(".obsidian/appearance.json", in: destination), "{\"theme\":\"obsidian\"}")
    }

    func testObsidiansOwnFolderIsNotCarried() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("# Today", to: "notes/today.md", in: source)
        write("{\"theme\":\"moonstone\"}", to: ".obsidian/appearance.json", in: source)

        let outcome = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        XCTAssertNil(read(".obsidian/appearance.json", in: destination))
        XCTAssertEqual(outcome.copied, ["notes/today.md"])
    }

    // MARK: What is not a file

    func testASymbolicLinkIsSkippedRatherThanFollowed() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        let outside = makeFolder("outside")
        write("not the person's memory", to: "secret.md", in: outside)
        write("# Today", to: "notes/today.md", in: source)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("link.md"),
                                                   withDestinationURL: outside.appendingPathComponent("secret.md"))

        let outcome = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        XCTAssertEqual(outcome.copied, ["notes/today.md"])
        XCTAssertTrue(outcome.skipped.contains("link.md"))
        XCTAssertNil(read("link.md", in: destination))
    }

    /// A folder is a way down to files, never a file to carry: a walk that took every entry would
    /// try to read one as bytes and call the move failed.
    func testAFolderIsNotCarriedAsAFile() {
        let source = makeFolder("source")
        write("# Today", to: "notes/today.md", in: source)
        let found = VaultTransfer.entries(in: source)
        XCTAssertEqual(found.files, ["notes/today.md"])
        XCTAssertFalse(found.files.contains("notes"))
        XCTAssertFalse(found.skipped.contains("notes"))
    }

    func testAPathAVaultCannotHoldIsSkipped() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("# Today", to: "notes/today.md", in: source)
        write("mine", to: ".topo/something-else.md", in: source)

        let outcome = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        XCTAssertEqual(outcome.copied, ["notes/today.md"])
        XCTAssertTrue(outcome.skipped.contains(".topo/something-else.md"))
        XCTAssertNil(read(".topo/something-else.md", in: destination))
    }

    // MARK: When it stops

    func testADestinationThatCannotBeWrittenStopsTheTransferAndLeavesTheSource() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("# Today", to: "notes/today.md", in: source)
        // A folder standing where the file's folder goes, with nothing writable in it.
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("notes"),
                                                withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: destination.appendingPathComponent("notes").path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: destination.appendingPathComponent("notes").path)
        }

        XCTAssertThrowsError(try VaultTransfer.copy(from: source, to: destination,
                                                    device: device, at: now)) { error in
            XCTAssertEqual(error as? VaultTransfer.Failure, .unwritable("notes/today.md"))
        }
        XCTAssertEqual(read("notes/today.md", in: source), "# Today")
    }
}

/// Running a transfer again after one that stopped before the commit. The move's promise is that
/// the next attempt writes over what the last one wrote, file by file, and a conflict copy is a
/// file like any other: one already standing there with these very bytes is this transfer's own
/// work, not a second file to make room for.
final class VaultTransferRetryTests: XCTestCase {
    private let device = DeviceID("phone")
    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    private func makeFolder(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-retry-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ text: String, to relative: String, in root: URL) {
        let file = relative.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file)
    }

    private func read(_ relative: String, in root: URL) -> String? {
        let file = relative.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func testARetryAfterAPartialConflictedTransferLeavesOneCopy() throws {
        let source = makeFolder("source")
        let destination = makeFolder("destination")
        write("what the phone had", to: "A.md", in: source)
        write("# Today", to: "notes/B.md", in: source)
        write("what Obsidian had", to: "A.md", in: destination)
        // The first attempt writes A's conflict copy and then cannot write B.
        let shut = destination.appendingPathComponent("notes", isDirectory: true)
        try FileManager.default.createDirectory(at: shut, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: shut.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shut.path)
        }
        XCTAssertThrowsError(try VaultTransfer.copy(from: source, to: destination,
                                                    device: device, at: now))
        let copy = "A (Conflicted copy phone 202508240146).md"
        XCTAssertEqual(read(copy, in: destination), "what the phone had")

        // The way is clear; the whole thing runs again.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shut.path)
        let outcome = try VaultTransfer.copy(from: source, to: destination, device: device, at: now)

        XCTAssertEqual(outcome.conflicted["A.md"], copy)
        XCTAssertEqual(read(copy, in: destination), "what the phone had")
        XCTAssertEqual(read("A.md", in: destination), "what Obsidian had")
        XCTAssertEqual(read("notes/B.md", in: destination), "# Today")
        // One copy of A, not one per attempt.
        let names = VaultTransfer.entries(in: destination).files.sorted()
        XCTAssertEqual(names, ["A (Conflicted copy phone 202508240146).md", "A.md", "notes/B.md"])
    }
}
