import XCTest

@testable import Topo

/// Asking iCloud Drive for what it has taken off the device. A simulator has no iCloud Drive, so
/// the downloading status and the ask are injected and the folder is a real temporary one: what is
/// under test is which entries are asked for, and that the wait ends.
@MainActor
final class VaultDownloadsTests: XCTestCase {
    private func makeFolder() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("topo-downloads-\(UUID().uuidString)", isDirectory: true)
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

    /// Nothing but a plain file is bytes to wait for. A folder has a downloading status of its
    /// own, and a pass that asked for one would wait out its bound on something that is never
    /// going to arrive and then report the person's memory as incomplete.
    func testOnlyRegularFilesAreAskedFor() {
        let folder = makeFolder()
        write("# Today", to: "notes/today.md", in: folder)
        write("# Groceries", to: "Groceries.md", in: folder)

        let pending = VaultDownloads.pending(in: folder, status: { _ in .notDownloaded })

        XCTAssertEqual(pending, ["Groceries.md", "notes/today.md"])
        XCTAssertFalse(pending.contains("notes"))
    }

    /// `.notDownloaded` is the one status that says the bytes are not here. A file with no
    /// status at all is not a ubiquitous item — a note just written on this phone, which iCloud
    /// has not taken up yet — and `startDownloadingUbiquitousItem` on one throws, so a pass that
    /// asked would report a refusal about a file that is perfectly readable.
    func testAFileWithNoDownloadingStatusIsNotAskedFor() {
        let folder = makeFolder()
        write("# Today", to: "notes/today.md", in: folder)

        XCTAssertEqual(VaultDownloads.pending(in: folder, status: { _ in nil }), [])
    }

    /// `.downloaded` is a local copy that is merely out of date. The bytes read as text either
    /// way, and the next pass sees the newer of them, so nothing waits for it.
    func testAStaleLocalCopyIsNotWaitedFor() {
        let folder = makeFolder()
        write("# Today", to: "notes/today.md", in: folder)

        XCTAssertEqual(VaultDownloads.pending(in: folder, status: { _ in .downloaded }), [])
    }

    func testFilesAlreadyDownloadedAreNotAskedFor() {
        let folder = makeFolder()
        write("# Today", to: "notes/today.md", in: folder)
        write("# Groceries", to: "Groceries.md", in: folder)

        let pending = VaultDownloads.pending(in: folder, status: { url in
            url.lastPathComponent == "today.md" ? .notDownloaded : .current
        })

        XCTAssertEqual(pending, ["notes/today.md"])
    }

    func testHiddenFoldersAreNotDescendedInto() {
        let folder = makeFolder()
        write("{}", to: ".obsidian/appearance.json", in: folder)
        write("# Today", to: "notes/today.md", in: folder)

        XCTAssertEqual(VaultDownloads.pending(in: folder, status: { _ in .notDownloaded }),
                       ["notes/today.md"])
    }

    // MARK: The wait

    func testAFileThatArrivesIsReportedAsArrived() async {
        let folder = makeFolder()
        write("# Today", to: "notes/today.md", in: folder)
        let asks = Counter()
        let report = await VaultDownloads.warm(folder, status: { _ in
            asks.next() > 1 ? .current : .notDownloaded
        }, startDownload: { _ in }, now: { .now }, sleep: { _ in })

        XCTAssertEqual(report.asked, ["notes/today.md"])
        XCTAssertEqual(report.arrived, ["notes/today.md"])
        XCTAssertEqual(report.waiting, [])
    }

    /// `.downloaded` is the bytes being here with a newer copy known elsewhere, which is a file
    /// the scan can read. So it ends the wait exactly as `.current` does: waiting on it would
    /// spend the whole bound on a file that has already landed.
    func testAFileThatLandsDownloadedRatherThanCurrentIsReportedAsArrived() async {
        let folder = makeFolder()
        write("# Today", to: "notes/today.md", in: folder)
        let asks = Counter()
        let report = await VaultDownloads.warm(folder, status: { _ in
            asks.next() > 1 ? .downloaded : .notDownloaded
        }, startDownload: { _ in }, now: { .now }, sleep: { _ in })

        XCTAssertEqual(report.asked, ["notes/today.md"])
        XCTAssertEqual(report.arrived, ["notes/today.md"])
        XCTAssertEqual(report.waiting, [])
    }

    /// The wait has an end. A file iCloud Drive never delivers is left for the next pass, not a
    /// pass that never returns.
    func testAFileThatNeverArrivesEndsTheWaitAtTheBound() async {
        let folder = makeFolder()
        write("# Today", to: "notes/today.md", in: folder)
        let clock = Ticks()
        let report = await VaultDownloads.warm(folder, timeout: .seconds(1),
                                               status: { _ in .notDownloaded },
                                               startDownload: { _ in },
                                               now: { clock.advance(by: .milliseconds(250)) },
                                               sleep: { _ in })

        XCTAssertEqual(report.asked, ["notes/today.md"])
        XCTAssertEqual(report.arrived, [])
        XCTAssertEqual(report.waiting, ["notes/today.md"])
        XCTAssertEqual(report.summary, "downloaded 0 of 1, still waiting for 1")
    }

    func testADownloadICloudDriveRefusesIsReportedRatherThanWaitedFor() async {
        let folder = makeFolder()
        write("# Today", to: "notes/today.md", in: folder)
        struct Refused: Error, CustomStringConvertible { var description = "no" }
        let report = await VaultDownloads.warm(folder, status: { _ in .notDownloaded },
                                               startDownload: { _ in throw Refused() },
                                               now: { .now }, sleep: { _ in })

        XCTAssertEqual(report.refused.keys.sorted(), ["notes/today.md"])
        XCTAssertEqual(report.waiting, [])
    }

    func testAFolderWithNothingMissingCostsNoWait() async {
        let folder = makeFolder()
        write("# Today", to: "notes/today.md", in: folder)
        let report = await VaultDownloads.warm(folder, status: { _ in .current },
                                               startDownload: { _ in XCTFail("asked for a file that is here") },
                                               now: { XCTFail("waited"); return ContinuousClock.now },
                                               sleep: { _ in })
        XCTAssertTrue(report.isEmpty)
        XCTAssertNil(report.summary)
    }
}

/// A count the injected closures share, since they are handed across an await.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// A clock the test moves on by hand, so the bound is reached without waiting for it.
private final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func advance(by step: Duration) -> ContinuousClock.Instant {
        lock.withLock { instant = instant.advanced(by: step); return instant }
    }
}
