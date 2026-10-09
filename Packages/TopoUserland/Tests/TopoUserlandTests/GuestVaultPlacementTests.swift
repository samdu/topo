import XCTest
import TopoUserland

/// A file put in the memory's folder by the guest (`VaultPlacement.place`), through the vault's
/// own filesystem and the guest's own BusyBox: it lands whole under its name, nothing at the name
/// is written over, even a file that arrives there while the placement waits, nothing is done
/// where no vault is mounted or after the deadline, its own hidden copy is not left behind, and
/// nothing else hidden is touched.
final class GuestVaultPlacementTests: XCTestCase {
    private let fm = FileManager.default
    private var hosts: [URL] = []
    private var points: [String] = []

    override func setUpWithError() throws {
        _ = try SharedGuest.booted()
    }

    override func tearDownWithError() throws {
        for point in points { try? Guest.shared.unmount(point) }
        hosts.forEach { try? fm.removeItem(at: $0) }
    }

    private func vault(at point: String = "/vault-\(UUID().uuidString.prefix(8))") throws -> (host: URL, point: String) {
        let host = fm.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: host, withIntermediateDirectories: true)
        hosts.append(host)
        try Guest.shared.mountVault(host, at: point)
        points.append(point)
        return (host, point)
    }

    /// A file in the guest's own filesystem holding `text`, and its path.
    private func source(_ text: String) async throws -> String {
        let path = "/tmp/pick-\(UUID().uuidString.prefix(8))"
        let made = try await Guest.shared.run("/bin/sh", ["-c", #"printf '%s' "$1" > "$2""#, "sh", text, path])
        XCTAssertEqual(made.status, 0, made.errors)
        return path
    }

    /// A coordinated write held on `url` from `init` until `arrive`, which writes the file there
    /// and lets go.
    private final class Arrival: @unchecked Sendable {
        private let release = DispatchSemaphore(value: 0)
        private let done = DispatchSemaphore(value: 0)

        init(at url: URL, leaving text: String) {
            let entered = DispatchSemaphore(value: 0)
            DispatchQueue.global().async { [release, done] in
                var error: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &error) { granted in
                    entered.signal()
                    release.wait()
                    try? Data(text.utf8).write(to: granted)
                }
                done.signal()
            }
            entered.wait()
        }

        func arrive() {
            release.signal()
            done.wait()
        }
    }

    private func hidden(in folder: URL) throws -> [String] {
        try fm.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
    }

    func testAFileLandsWholeUnderItsNameInAFolderMadeForIt() async throws {
        let (host, point) = try vault()
        let picked = try await source("the picked file\n")
        let outcome = try await VaultPlacement.place(picked, at: point, folder: "inbox/from files", name: "a report.txt", by: soon)
        XCTAssertEqual(outcome, .placed(bytes: 16))
        let folder = host.appendingPathComponent("inbox/from files")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a report.txt"), encoding: .utf8), "the picked file\n")
        XCTAssertEqual(try hidden(in: folder), [], "the copy's hidden name was left")
    }

    /// The memory as the app lays it out: mounted at `ClaudeLauncher.vault` and linked from the
    /// home. A placement that names no root goes to the mount, and the file is there by the home's
    /// link; the link itself is no mount, so a placement told to go there does nothing.
    func testAPlacementGoesToTheMemorysOwnMountAndNotByTheHomesLinkToIt() async throws {
        let (host, _) = try vault(at: ClaudeLauncher.vault)
        _ = try await Guest.shared.run("/bin/mkdir", ["-p", ClaudeLauncher.home])
        try Guest.shared.link(ClaudeLauncher.vault, at: ClaudeLauncher.memory)
        let picked = try await source("mine\n")
        let outcome = try await VaultPlacement.place(picked, folder: "inbox", name: "file.md", by: soon)
        XCTAssertEqual(outcome, .placed(bytes: 5))
        XCTAssertEqual(try String(contentsOf: host.appendingPathComponent("inbox/file.md"), encoding: .utf8), "mine\n")
        let read = try await Guest.shared.run("/bin/cat", ["\(ClaudeLauncher.memory)/inbox/file.md"])
        XCTAssertEqual(read.output, "mine\n", read.errors)
        let byLink = try await VaultPlacement.place(picked, at: ClaudeLauncher.memory, folder: "inbox", name: "other.md", by: soon)
        XCTAssertEqual(byLink, .unmounted)
        XCTAssertFalse(fm.fileExists(atPath: host.appendingPathComponent("inbox/other.md").path))
    }

    func testNothingAtTheNameIsWrittenOver() async throws {
        let (host, point) = try vault()
        let folder = host.appendingPathComponent("inbox", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("theirs\n".utf8).write(to: folder.appendingPathComponent("file.md"))
        try fm.createSymbolicLink(atPath: folder.appendingPathComponent("dangling.md").path, withDestinationPath: "nowhere")
        try fm.createDirectory(at: folder.appendingPathComponent("folder.md"), withIntermediateDirectories: true)
        let picked = try await source("mine\n")
        for name in ["file.md", "dangling.md", "folder.md"] {
            let outcome = try await VaultPlacement.place(picked, at: point, folder: "inbox", name: name, by: soon)
            XCTAssertEqual(outcome, .exists, name)
        }
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("file.md"), encoding: .utf8), "theirs\n")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("dangling.md").path), "nowhere")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: folder.appendingPathComponent("folder.md").path), [])
        XCTAssertEqual(try hidden(in: folder), [])
    }

    /// The mirror, or another device through iCloud, puts a file at the name after the placement
    /// looked and found nothing there: the placement waits for that writer and then leaves its
    /// file alone.
    func testAFileThatArrivesAtTheNameWhileThePlacementWaitsIsNotWrittenOver() async throws {
        let (host, point) = try vault()
        let folder = host.appendingPathComponent("inbox", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = folder.appendingPathComponent("notes.md")
        let writer = Arrival(at: name, leaving: "theirs\n")
        let picked = try await source("mine\n")
        let placing = Task { try await VaultPlacement.place(picked, at: point, folder: "inbox", name: "notes.md", by: soon) }
        // Long enough for the placement to have looked, copied and be waiting on the name.
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(fm.fileExists(atPath: name.path))
        writer.arrive()
        let outcome = try await placing.value
        XCTAssertEqual(outcome, .exists)
        XCTAssertEqual(try String(contentsOf: name, encoding: .utf8), "theirs\n", "the placement wrote over the file that arrived")
        XCTAssertEqual(try hidden(in: folder), [])
    }

    func testTwoPlacementsAtOneNameLeaveOneWholeFile() async throws {
        let (host, point) = try vault()
        let first = try await source(String(repeating: "a", count: 4096))
        let second = try await source(String(repeating: "b", count: 4096))
        for round in 0..<5 {
            let name = "same-\(round).txt"
            async let one = VaultPlacement.place(first, at: point, folder: "inbox", name: name, by: soon)
            async let two = VaultPlacement.place(second, at: point, folder: "inbox", name: name, by: soon)
            let outcomes = try await [one, two]
            XCTAssertEqual(outcomes.filter { $0 == .placed(bytes: 4096) }.count, 1, "\(outcomes)")
            XCTAssertEqual(outcomes.filter { $0 == .exists }.count, 1, "\(outcomes)")
            let landed = try String(contentsOf: host.appendingPathComponent("inbox/\(name)"), encoding: .utf8)
            let winner = outcomes[0] == .exists ? "b" : "a"
            XCTAssertEqual(landed, String(repeating: winner, count: 4096), "the file is not the one whose placement was answered as placed")
        }
        XCTAssertEqual(try hidden(in: host.appendingPathComponent("inbox")), [])
    }

    func testNothingIsPlacedWhereNoVaultIsMounted() async throws {
        let bare = "/tmp/bare-\(UUID().uuidString.prefix(8))"
        _ = try await Guest.shared.run("/bin/mkdir", ["-p", bare])
        let picked = try await source("mine\n")
        let outcome = try await VaultPlacement.place(picked, at: bare, folder: "inbox", name: "file.md", by: soon)
        XCTAssertEqual(outcome, .unmounted)
        let listed = try await Guest.shared.run("/bin/ls", ["-A", bare])
        XCTAssertEqual(listed.output, "", "something was written into a folder that is no vault")
    }

    func testNothingIsGivenItsNameAfterTheDeadline() async throws {
        let (host, point) = try vault()
        let picked = try await source("mine\n")
        let outcome = try await VaultPlacement.place(picked, at: point, folder: "inbox", name: "file.md", by: Date().addingTimeInterval(-1))
        XCTAssertEqual(outcome, .late)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: host.appendingPathComponent("inbox").path), [])
    }

    func testAMissingSourceIsAFailureThatLeavesNothing() async throws {
        let (host, point) = try vault()
        let outcome = try await VaultPlacement.place("/tmp/no-such-file", at: point, folder: "inbox", name: "file.md", by: soon)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: host.appendingPathComponent("inbox").path), [])
    }

    /// Nothing hidden in the folder is a placement's to take away but the copy it made itself: a
    /// name like its own, of any age, may be the person's file.
    func testNoHiddenFileButItsOwnCopyIsTakenAway() async throws {
        let (host, point) = try vault()
        let folder = host.appendingPathComponent("inbox", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-3600)
        let theirs = [".topo-pick-41.part", ".topo-pick-notes.part", ".topo-pick-list.md"]
        for name in theirs {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let picked = try await source("mine\n")
        let outcome = try await VaultPlacement.place(picked, at: point, folder: "inbox", name: "file.md", by: soon)
        XCTAssertEqual(outcome, .placed(bytes: 5))
        XCTAssertEqual(try hidden(in: folder).sorted(), theirs.sorted())
    }
}

/// A deadline no placement here reaches.
private var soon: Date { Date().addingTimeInterval(60) }
