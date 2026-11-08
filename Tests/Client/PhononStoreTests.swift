import CryptoKit
import XCTest

@testable import Topo

/// The voice's store: one path for every source, a checked copy or none, and a good copy kept
/// when its source fails.
final class PhononStoreTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("phonon-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private var store: PhononStore {
        PhononStore(home: base.appendingPathComponent("Voice/\(PhononStore.name)", isDirectory: true))
    }

    /// A bundle folder: `files` by path, and a `bundle.json` naming each at its size and digest,
    /// with `lie` naming one file's digest wrong.
    private func bundle(built: Int64, files: [String: String], lie: String? = nil, name: String = UUID().uuidString) throws -> URL {
        let folder = base.appendingPathComponent("source-\(name)", isDirectory: true)
        var entries: [[String: Any]] = []
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(text.utf8)
            try data.write(to: url)
            let digest = path == lie ? String(repeating: "0", count: 64)
                : SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            entries.append(["path": path, "size": data.count, "sha256": digest])
        }
        let manifest: [String: Any] = ["built": built, "files": entries, "temperature": 0.3, "voices": ["Friendly Octopus"]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("bundle.json"))
        return folder
    }

    private let weights = [
        "flow.mlpackage/Data/com.apple.CoreML/weights/weight.bin": "flow weights",
        "flow.mlpackage/Manifest.json": "flow manifest",
        "voices/Friendly Octopus.safetensors": "the octopus",
    ]

    func testAFolderSourceIsCopiedWholeWithItsRecord() async throws {
        let source = FolderSource(folder: try bundle(built: 100, files: weights))
        let home = try await store.install(from: source)
        XCTAssertEqual(home, store.home)
        for (path, text) in weights {
            XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(path), encoding: .utf8), text, path)
        }
        XCTAssertTrue(fm.fileExists(atPath: home.appendingPathComponent("bundle.json").path))
        XCTAssertEqual(store.installed(), PhononStore.Installed(built: 100, version: nil))
        XCTAssertTrue(store.isWhole())
        XCTAssertFalse(fm.fileExists(atPath: store.staging.path), "no partial folder is left")
        let parent = try home.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(parent.isExcludedFromBackup, true, "half a gigabyte of weights is not backed up")
    }

    /// A pack takes the same path as a folder, and once its copy is checked it is let go.
    func testAPackSourceTakesTheSamePathAndIsLetGoAfterItsCopy() async throws {
        let pack = FakePack(folder: try bundle(built: 100, files: weights), version: 3)
        _ = try await store.install(from: pack)
        XCTAssertEqual(store.installed(), PhononStore.Installed(built: 100, version: 3, released: true))
        XCTAssertTrue(store.isWhole())
        XCTAssertEqual(pack.counts, .init(madeLocal: 1, copied: 1))
        XCTAssertFalse(pack.isLocal, "the pack is kept beside its copy")
    }

    /// A store of the pack's own version is taken as it stands, without making the pack local:
    /// a pack let go after its copy is not downloaded again for nothing.
    func testAStoreOfThePacksVersionIsTakenWithoutTheDownload() async throws {
        let pack = FakePack(folder: try bundle(built: 100, files: weights), version: 3)
        _ = try await store.install(from: pack)
        _ = try await store.install(from: pack)
        XCTAssertEqual(pack.counts, .init(madeLocal: 1, copied: 1))
        // A file gone from the store is not a store of that version.
        try fm.removeItem(at: store.home.appendingPathComponent("voices/Friendly Octopus.safetensors"))
        _ = try await store.install(from: pack)
        XCTAssertEqual(pack.counts, .init(madeLocal: 2, copied: 2))
        XCTAssertTrue(store.isWhole())
    }

    /// A new version of the pack (an update's, fetched at the first launch after it, since the
    /// pack is essential at first installation alone) is downloaded, copied over the store and
    /// let go: the phone keeps one copy of the weights.
    func testANewPackVersionIsFetchedCopiedAndLetGo() async throws {
        let folder = try bundle(built: 100, files: weights)
        _ = try await store.install(from: FakePack(folder: folder, version: 3))
        let next = FakePack(folder: folder, version: 4)
        _ = try await store.install(from: next)
        XCTAssertEqual(next.counts, .init(madeLocal: 1, copied: 1))
        XCTAssertEqual(store.installed(), PhononStore.Installed(built: 100, version: 4, released: true))
        _ = try await store.install(from: next)
        XCTAssertEqual(next.counts, .init(madeLocal: 1, copied: 1), "a store at the pack's version fetched it again")
    }

    /// The voice's line says a new version is downloading over the copy here, and that replies
    /// are written until it is in; a first download says only that it is downloading.
    @MainActor func testTheLineSaysANewVersionIsDownloadingAndRepliesAreWritten() async throws {
        let folder = try bundle(built: 100, files: weights)
        let first = GatedPack(folder: folder, version: 3)
        let fresh = Voice(engine: TemperatureRecorder(), store: store, source: first)
        fresh.prepare()
        while fresh.fraction == nil { await Task.yield() }
        XCTAssertEqual(fresh.fetchWords, "\(Voice.downloading) (50%)")
        first.open()
        while store.installed() == nil { await Task.yield() }

        // While the store waits on a pack that has said nothing of its download, the line says
        // it is checking, which is a launch's words and draws no meter.
        let quiet = GatedPack(folder: folder, version: 5, reports: false)
        let launch = Voice(engine: TemperatureRecorder(), store: store, source: quiet)
        launch.prepare()
        while !quiet.entered { await Task.yield() }
        XCTAssertEqual(launch.fetchWords, Voice.checking)
        quiet.open()
        while store.installed()?.version != 5 { await Task.yield() }

        let next = GatedPack(folder: folder, version: 6)
        let renewing = Voice(engine: TemperatureRecorder(), store: store, source: next)
        renewing.prepare()
        while renewing.fraction == nil { await Task.yield() }
        XCTAssertEqual(renewing.fetchWords, "\(Voice.renewingWords) (50%)")
        next.open()
        while store.installed()?.version != 6 { await Task.yield() }
    }

    /// A removal that fails, or a process that ends between the copy and the removal, is tried
    /// again at the next launch that finds the store whole, until the pack is gone.
    func testAPackNotLetGoIsLetGoAtTheNextLaunch() async throws {
        let pack = FakePack(folder: try bundle(built: 100, files: weights), version: 3, refusals: 1)
        _ = try await store.install(from: pack)
        XCTAssertTrue(pack.isLocal, "the refused removal took the pack")
        XCTAssertEqual(store.installed()?.released, false)
        _ = try await store.install(from: pack)
        XCTAssertFalse(pack.isLocal, "the next launch left the pack beside the store")
        XCTAssertEqual(store.installed(), PhononStore.Installed(built: 100, version: 3, released: true))
        XCTAssertEqual(pack.counts, .init(madeLocal: 1, copied: 2))
        _ = try await store.install(from: pack)
        XCTAssertEqual(pack.counts, .init(madeLocal: 1, copied: 2), "a pack let go is not let go again")
    }

    /// A pack whose version cannot be read this launch leaves a whole store standing: it is not
    /// downloaded again to find out.
    func testAnUnreadableVersionKeepsTheStoreWithoutAFetch() async throws {
        let pack = FakePack(folder: try bundle(built: 100, files: weights), version: 3, unreadable: 1)
        _ = try await store.install(from: FakePack(folder: pack.folder, version: 3))
        _ = try await store.install(from: pack)
        XCTAssertEqual(pack.counts.madeLocal, 0, "the pack was fetched again for a version nobody could read")
        XCTAssertTrue(store.isWhole())
    }

    func testAFileThatDoesNotMatchItsDigestLeavesNoStoreFolder() async throws {
        let source = FolderSource(folder: try bundle(built: 100, files: weights, lie: "flow.mlpackage/Manifest.json"))
        do {
            _ = try await store.install(from: source)
            XCTFail("a copy with a bad digest was taken")
        } catch let error as PhononStoreError {
            XCTAssertEqual(error, .wrongDigest("flow.mlpackage/Manifest.json"))
        }
        XCTAssertFalse(fm.fileExists(atPath: store.home.path))
        XCTAssertFalse(fm.fileExists(atPath: store.staging.path), "the partial copy goes with the failure")
        XCTAssertNil(store.installed())
    }

    /// A process that died mid-copy left a partial folder: the next copy starts over it.
    func testAPartialFolderLeftBehindIsReplaced() async throws {
        let stray = store.staging.appendingPathComponent("flow.mlpackage/Manifest.json")
        try fm.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("half".utf8).write(to: stray)
        _ = try await store.install(from: FolderSource(folder: try bundle(built: 100, files: weights)))
        XCTAssertFalse(fm.fileExists(atPath: store.staging.path))
        XCTAssertEqual(try String(contentsOf: store.home.appendingPathComponent("flow.mlpackage/Manifest.json"), encoding: .utf8), "flow manifest")
    }

    func testANewerBundleReplacesTheStore() async throws {
        _ = try await store.install(from: FolderSource(folder: try bundle(built: 100, files: weights)))
        var newer = weights
        newer["voices/Friendly Octopus.safetensors"] = "the octopus, again"
        newer.removeValue(forKey: "flow.mlpackage/Manifest.json")
        _ = try await store.install(from: FolderSource(folder: try bundle(built: 200, files: newer)))
        XCTAssertEqual(store.installed()?.built, 200)
        XCTAssertEqual(try String(contentsOf: store.home.appendingPathComponent("voices/Friendly Octopus.safetensors"), encoding: .utf8), "the octopus, again")
        XCTAssertFalse(fm.fileExists(atPath: store.home.appendingPathComponent("flow.mlpackage/Manifest.json").path),
                       "nothing of the older bundle is left in the store")
    }

    func testASourceThatFailsKeepsTheGoodCopy() async throws {
        _ = try await store.install(from: FolderSource(folder: try bundle(built: 100, files: weights)))
        let failing = FakePack(folder: base.appendingPathComponent("nowhere"), version: 4, fails: true)
        let home = try await store.install(from: failing)
        XCTAssertEqual(home, store.home)
        XCTAssertEqual(store.installed(), PhononStore.Installed(built: 100, version: nil))
        XCTAssertTrue(store.isWhole())
        // With no copy here, the failure is the answer.
        try fm.removeItem(at: store.home)
        do {
            _ = try await store.install(from: failing)
            XCTFail("a failing source with nothing here was taken")
        } catch {}
    }

    /// An older pack an earlier removal left on the phone, made local while the manager
    /// advertises a newer one, is recorded as the version its files are: the next launch still
    /// fetches the newer, rather than taking the older weights for it.
    func testAnOlderPackLeftLocalIsNotRecordedAsTheNewerVersion() async throws {
        let older = try bundle(built: 100, files: weights)
        _ = try await store.install(from: FakePack(folder: older, version: 3, refusals: 1))
        XCTAssertEqual(store.installed()?.released, false)
        var newer = weights
        newer["voices/Friendly Octopus.safetensors"] = "the octopus, version 4"
        let stale = FakePack(folder: older, version: 4, local: 3)
        _ = try await store.install(from: stale)
        XCTAssertEqual(store.installed()?.version, 3, "the older pack's files were recorded as the newer version")
        XCTAssertEqual(store.installed()?.built, 100)
        let latest = FakePack(folder: try bundle(built: 200, files: newer), version: 4)
        _ = try await store.install(from: latest)
        XCTAssertEqual(latest.counts.madeLocal, 1, "the newer version was never fetched")
        XCTAssertEqual(store.installed(), PhononStore.Installed(built: 200, version: 4, released: true))
        XCTAssertEqual(try String(contentsOf: store.home.appendingPathComponent("voices/Friendly Octopus.safetensors"), encoding: .utf8),
                       "the octopus, version 4")
    }

    /// A copy whose files are all in and checked, and whose last step fails, takes its partial
    /// folder with it and leaves the good copy in use.
    func testAFailureAfterTheFilesAreInTakesThePartialFolder() async throws {
        _ = try await store.install(from: FolderSource(folder: try bundle(built: 100, files: weights)))
        struct Refused: Error {}
        let failing = PhononStore(home: store.home, swap: { _, staging in
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent(".installed").path),
                          "the swap was reached before the copy was whole")
            throw Refused()
        })
        let home = try await failing.install(from: FolderSource(folder: try bundle(built: 200, files: weights)))
        XCTAssertEqual(home, store.home)
        XCTAssertEqual(store.installed()?.built, 100)
        XCTAssertFalse(fm.fileExists(atPath: store.staging.path), "the whole partial copy was left behind")
        // With no copy here, the failure is the answer, and it leaves nothing behind either.
        try fm.removeItem(at: store.home)
        do {
            _ = try await failing.install(from: FolderSource(folder: try bundle(built: 300, files: weights)))
            XCTFail("a copy that never reached its place was taken")
        } catch {}
        XCTAssertFalse(fm.fileExists(atPath: store.staging.path))
    }

    /// A partial folder an earlier process left is taken away by a launch whose source fails.
    func testASourceThatFailsTakesAPartialFolderLeftBehind() async throws {
        _ = try await store.install(from: FolderSource(folder: try bundle(built: 100, files: weights)))
        let stray = store.staging.appendingPathComponent("flow.mlpackage/Data/com.apple.CoreML/weights/weight.bin")
        try fm.createDirectory(at: stray.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("half the weights".utf8).write(to: stray)
        _ = try await store.install(from: FakePack(folder: base.appendingPathComponent("nowhere"), version: 4, fails: true))
        XCTAssertFalse(fm.fileExists(atPath: store.staging.path), "a failing source kept the partial folder")
        XCTAssertTrue(store.isWhole())
    }

    func testAPathOutsideTheBundleIsRefused() async throws {
        let folder = try bundle(built: 100, files: weights)
        let manifest: [String: Any] = ["built": 100, "files": [["path": "../escape", "size": 1, "sha256": String(repeating: "0", count: 64)]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("bundle.json"))
        do {
            _ = try await store.install(from: FolderSource(folder: folder))
            XCTFail("a path outside the bundle was taken")
        } catch let error as PhononStoreError {
            XCTAssertEqual(error, .badPath("../escape"))
        }
        for path in ["", "/abs", "a/../b", "./a", "a/./b"] { XCTAssertFalse(PhononStore.safe(path), path) }
        XCTAssertTrue(PhononStore.safe("voices/Friendly Octopus.safetensors"))
    }
}

/// A pack: a folder that counts its downloads and its letting go. Letting it go takes its files
/// away, as removing a pack does, and a download brings them back; a removal can be made to fail,
/// and the version to be unreadable, a number of times.
final class FakePack: PhononSource, @unchecked Sendable {
    struct Counts: Equatable { var madeLocal = 0; var copied = 0 }
    let folder: URL
    let packVersion: Int
    /// The version a download leaves local, which is the advertised one unless an older pack
    /// left on the phone stands in for it.
    let localVersion: Int
    let fails: Bool
    private let lock = NSLock()
    private var kept = Counts()
    private var refusals: Int
    private var unreadable: Int
    var counts: Counts { lock.withLock { kept } }
    private var gone: URL { folder.appendingPathExtension("removed") }

    init(folder: URL, version: Int, local: Int? = nil, fails: Bool = false, refusals: Int = 0, unreadable: Int = 0) {
        self.folder = folder
        self.packVersion = version
        self.localVersion = local ?? version
        self.fails = fails
        self.refusals = refusals
        self.unreadable = unreadable
    }

    /// Whether the pack's files are on the phone.
    var isLocal: Bool { FileManager.default.fileExists(atPath: folder.path) }

    func makeLocal(progress: @escaping @Sendable (Double?) -> Void) async throws -> Int? {
        lock.withLock { kept.madeLocal += 1 }
        if fails { throw URLError(.notConnectedToInternet) }
        if !isLocal, FileManager.default.fileExists(atPath: gone.path) {
            try FileManager.default.moveItem(at: gone, to: folder)
        }
        progress(1)
        return localVersion
    }
    func url(of path: String) throws -> URL { try FolderSource(folder: folder).url(of: path) }
    var versioned: Bool { true }
    func version() async -> Int? {
        lock.withLock {
            if unreadable > 0 { unreadable -= 1; return nil }
            return packVersion
        }
    }
    func copied() async -> Bool {
        let refused = lock.withLock { () -> Bool in
            kept.copied += 1
            if refusals > 0 { refusals -= 1; return true }
            return false
        }
        if refused { return false }
        try? FileManager.default.moveItem(at: folder, to: gone)
        return true
    }
}

/// A pack whose download stands at half until the test lets it finish.
final class GatedPack: PhononSource, @unchecked Sendable {
    let folder: URL
    let packVersion: Int
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false
    private var began = false
    /// Whether the store has asked for the download.
    var entered: Bool { lock.withLock { began } }

    let reports: Bool

    init(folder: URL, version: Int, reports: Bool = true) {
        self.folder = folder
        self.packVersion = version
        self.reports = reports
    }

    func open() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume()
    }

    func makeLocal(progress: @escaping @Sendable (Double?) -> Void) async throws -> Int? {
        lock.withLock { began = true }
        if reports { progress(0.5) }
        await withCheckedContinuation { continuation in
            let go = lock.withLock { () -> Bool in
                if opened { return true }
                waiter = continuation
                return false
            }
            if go { continuation.resume() }
        }
        return packVersion
    }
    func url(of path: String) throws -> URL { try FolderSource(folder: folder).url(of: path) }
    var versioned: Bool { true }
    func version() async -> Int? { packVersion }
    func copied() async -> Bool { true }
}
