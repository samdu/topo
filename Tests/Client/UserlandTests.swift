import CryptoKit
import TopoUserland
import XCTest

@testable import Topo

/// The rootfs pipeline in the app: a fetch that fails reaches whoever is waiting for the fakefs,
/// and the next `prepare` fetches afresh rather than waiting on the one that failed.
@MainActor
final class UserlandTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("topo-userland-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    func testAFailedFetchThrowsFromReadyAndTheNextPrepareFetchesAgain() async throws {
        let source = ScriptedSource()
        let userland = Userland(installer: RootfsInstaller(directory: base.appendingPathComponent("Userland"), importer: MakesADirectory()),
                                source: source, shellSource: FetchedShell(base), claudeSource: ScriptedSource())
        let failure = ModelDownloadFailure(id: ModelManifest.rootfs, why: "404")

        let first = Answer()
        Task { @MainActor in await first.settle { try await userland.ready() } }
        try await until { source.fetches == 1 }
        source.settle(.failure(failure))
        try await until(seconds: 5) { first.result != nil }
        guard case .failure(let error)? = first.result else {
            return XCTFail("ready() did not throw once the fetch failed: \(String(describing: first.result))")
        }
        XCTAssertEqual(error as? ModelDownloadFailure, failure)
        XCTAssertEqual(userland.phase, .failed(String(describing: failure)))

        userland.prepare()
        XCTAssertEqual(source.fetches, 2, "the next prepare did not fetch again")
        let (tarball, pin) = try tarballAndPin()
        source.settle(.success([Fetched(file: tarball, size: pin.size, sha256: pin.sha256, version: nil)]))
        let second = Answer()
        Task { @MainActor in await second.settle { try await userland.ready() } }
        try await until(seconds: 5) { second.result != nil }
        XCTAssertEqual(try second.result?.get(), userland.installer.fakefs)
        XCTAssertEqual(userland.phase, .ready(.imported))
    }

    /// A foreground during a fetch asks for nothing more: one fetch, one outcome.
    func testPrepareDuringAFetchStartsNoSecondOne() {
        let source = ScriptedSource()
        let userland = Userland(installer: RootfsInstaller(directory: base.appendingPathComponent("Userland"), importer: MakesADirectory()),
                                source: source, shellSource: FetchedShell(base), claudeSource: ScriptedSource())
        userland.prepare()
        userland.prepare()
        userland.prepare()
        XCTAssertEqual(source.fetches, 1)
    }

    /// Claude Code is handed out as its installer once the downloader has it, pinned at the
    /// version the manifest names; a failed fetch reaches whoever waits for it, and the next
    /// `prepare` fetches again.
    func testClaudeCodeIsHandedOutAtItsPinAndAFailedFetchIsTriedAgain() async throws {
        let claude = ScriptedSource()
        let userland = Userland(installer: RootfsInstaller(directory: base.appendingPathComponent("Userland"), importer: MakesADirectory()),
                                source: ScriptedSource(), shellSource: ScriptedSource(), claudeSource: claude)
        let first = Answer()
        Task { @MainActor in await first.settle { try await userland.claudeCode().binary } }
        try await until { claude.fetches == 1 }
        let failure = ModelDownloadFailure(id: ModelManifest.claudeCode, why: "403")
        claude.settle(.failure(failure))
        try await until(seconds: 5) { first.result != nil }
        guard case .failure(let error)? = first.result else {
            return XCTFail("claudeCode() did not throw once the fetch failed")
        }
        XCTAssertEqual(error as? ModelDownloadFailure, failure)
        XCTAssertEqual(userland.claude, .failed(String(describing: failure)))

        userland.prepare()
        XCTAssertEqual(claude.fetches, 2, "the next prepare did not fetch Claude Code again")
        let binary = base.appendingPathComponent("claude")
        claude.settle(.success([Fetched(file: binary, size: 226_637_472, sha256: String(repeating: "c", count: 64), version: "2.1.278")]))
        let installer = try await userland.claudeCode()
        XCTAssertEqual(installer.binary, binary)
        XCTAssertEqual(installer.pin, ClaudeCodePin(version: "2.1.278", size: 226_637_472, sha256: String(repeating: "c", count: 64)))
        XCTAssertEqual(userland.claude, .fetched(installer.pin))
        userland.prepare()
        XCTAssertEqual(claude.fetches, 2, "Claude Code on the phone was fetched again")
    }

    /// A Claude Code entry whose pin names no version — absent, empty or only whitespace — is a
    /// failure, not a pin `claude --version` is held to an empty string by.
    func testAClaudeCodePinWithNoVersionFails() async throws {
        for version in [nil, "", "  ", "\n", " \t\n"] as [String?] {
            let claude = ScriptedSource()
            let userland = Userland(installer: RootfsInstaller(directory: base.appendingPathComponent("Userland"), importer: MakesADirectory()),
                                    source: ScriptedSource(), shellSource: ScriptedSource(), claudeSource: claude)
            let answer = Answer()
            Task { @MainActor in await answer.settle { try await userland.claudeCode().binary } }
            try await until { claude.fetches == 1 }
            claude.settle(.success([Fetched(file: base.appendingPathComponent("claude"), size: 1,
                                           sha256: String(repeating: "c", count: 64), version: version)]))
            try await until(seconds: 5) { answer.result != nil }
            guard case .failure(let error)? = answer.result else {
                XCTFail("claudeCode() handed out a pin with version \(String(describing: version)): \(String(describing: answer.result))")
                continue
            }
            XCTAssertEqual((error as? ModelDownloadFailure)?.id, ModelManifest.claudeCode, String(describing: version))
            guard case .failed = userland.claude else {
                XCTFail("with version \(String(describing: version)) the phase is \(userland.claude), not failed")
                continue
            }
        }
    }

    /// The diagnostics row says which of the three downloads the guest is waiting on.
    func testTheUserlandRowSaysWhichDownloadIsOutstanding() async throws {
        let rootfs = ScriptedSource(), shell = ScriptedSource(), claude = ScriptedSource()
        let userland = Userland(installer: RootfsInstaller(directory: base.appendingPathComponent("Userland"), importer: MakesADirectory()),
                                source: rootfs, shellSource: shell, claudeSource: claude)
        rootfs.status = "downloading 1 MB of 4 MB"
        shell.status = "waiting for a network the data settings allow"
        claude.status = "downloading 20 MB of 227 MB"
        userland.prepare()
        XCTAssertEqual(userland.summary, "rootfs downloading 1 MB of 4 MB; bash waiting for a network the data settings allow; "
                       + "claude code downloading 20 MB of 227 MB")

        let (tarball, pin) = try tarballAndPin()
        rootfs.settle(.success([Fetched(file: tarball, size: pin.size, sha256: pin.sha256, version: nil)]))
        rootfs.status = "downloaded"
        shell.status = "downloading 100 KB of 800 KB"
        XCTAssertEqual(userland.summary, "rootfs downloaded; bash downloading 100 KB of 800 KB; claude code downloading 20 MB of 227 MB")
        shell.settle(.success(try packages()))
        _ = try await userland.ready()
        XCTAssertEqual(userland.summary, "rootfs and bash ready; claude code downloading 20 MB of 227 MB")

        claude.settle(.success([Fetched(file: base.appendingPathComponent("claude"), size: 1,
                                       sha256: String(repeating: "c", count: 64), version: "2.1.278")]))
        XCTAssertEqual(userland.summary, "rootfs and bash ready; claude code 2.1.278 downloaded")
    }

    /// The import waits for the rootfs and the packages both, and hands the importer the tarball
    /// and every package in the manifest's order; the packages failing to download fails it, and
    /// the next `prepare` fetches both afresh.
    func testTheImportWaitsForTheRootfsAndThePackagesAndAFailedPackageFetchFailsIt() async throws {
        let rootfs = ScriptedSource(), shell = ScriptedSource()
        let importer = RecordingImporter()
        let userland = Userland(installer: RootfsInstaller(directory: base.appendingPathComponent("Userland"), importer: importer),
                                source: rootfs, shellSource: shell, claudeSource: ScriptedSource())
        let first = Answer()
        Task { @MainActor in await first.settle { try await userland.ready() } }
        try await until { rootfs.fetches == 1 && shell.fetches == 1 }
        let (tarball, pin) = try tarballAndPin()
        rootfs.settle(.success([Fetched(file: tarball, size: pin.size, sha256: pin.sha256, version: nil)]))
        XCTAssertEqual(userland.phase, .fetching, "the import began before the packages were here")
        let failure = ModelDownloadFailure(id: ModelManifest.shell, why: "404")
        shell.settle(.failure(failure))
        try await until(seconds: 5) { first.result != nil }
        guard case .failure(let error)? = first.result else {
            return XCTFail("ready() did not throw once the packages' fetch failed: \(String(describing: first.result))")
        }
        XCTAssertEqual(error as? ModelDownloadFailure, failure)
        XCTAssertEqual(importer.calls, [], "the importer ran without the packages")

        userland.prepare()
        XCTAssertEqual(rootfs.fetches, 2)
        XCTAssertEqual(shell.fetches, 2, "the next prepare did not fetch the packages again")
        let packages = try packages()
        shell.settle(.success(packages))
        rootfs.settle(.success([Fetched(file: tarball, size: pin.size, sha256: pin.sha256, version: nil)]))
        let second = Answer()
        Task { @MainActor in await second.settle { try await userland.ready() } }
        try await until(seconds: 5) { second.result != nil }
        XCTAssertEqual(try second.result?.get(), userland.installer.fakefs)
        XCTAssertEqual(importer.calls, [[tarball] + packages.map(\.file)])
    }

    /// Two stand-in packages, written and pinned.
    private func packages() throws -> [Fetched] {
        try ["bash-5.2.37-r0.apk", "readline-8.2.13-r1.apk"].map { name in
            let data = Data(name.utf8)
            let url = base.appendingPathComponent(name)
            try data.write(to: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return Fetched(file: url, size: Int64(data.count), sha256: digest, version: nil)
        }
    }

    private func tarballAndPin() throws -> (URL, RootfsPin) {
        let data = Data("a tarball".utf8)
        let url = base.appendingPathComponent("alpine.tar.gz")
        try data.write(to: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (url, RootfsPin(size: Int64(data.count), sha256: digest))
    }

    /// Waits until `condition` holds, failing after a bound rather than hanging: a `ready()` that
    /// is never answered is the defect this suite exists for, and it has to fail rather than stall.
    private func until(seconds: Double = 1, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "still waiting after \(seconds) s")
    }
}

/// What a `ready()` answered, once it has.
@MainActor
private final class Answer {
    var result: Result<URL, Error>?

    func settle(_ body: () async throws -> URL) async {
        do { result = .success(try await body()) } catch { result = .failure(error) }
    }
}

/// A fetch the test settles by hand, counting how many were started.
@MainActor
private final class ScriptedSource: DownloadSource {
    private(set) var fetches = 0
    private var pending: [@MainActor (Result<[Fetched], Error>) -> Void] = []
    var isFetched: Bool { false }
    var status: String = "scripted"

    func fetch(_ done: @escaping @MainActor (Result<[Fetched], Error>) -> Void) {
        fetches += 1
        pending.append(done)
    }

    func settle(_ result: Result<[Fetched], Error>) {
        let waiting = pending
        pending = []
        waiting.forEach { $0(result) }
    }
}

/// The packages already on the phone: one stand-in, answered at once, for the tests about the
/// rootfs and Claude Code.
@MainActor
private final class FetchedShell: DownloadSource {
    private let base: URL
    init(_ base: URL) { self.base = base }
    var isFetched: Bool { true }
    var status: String { "downloaded" }

    func fetch(_ done: @escaping @MainActor (Result<[Fetched], Error>) -> Void) {
        done(Result {
            let data = Data("bash".utf8)
            let url = base.appendingPathComponent("bash.apk")
            try data.write(to: url)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return [Fetched(file: url, size: Int64(data.count), sha256: digest, version: nil)]
        })
    }
}

private struct MakesADirectory: FakefsImporter {
    func makeFakefs(from rootfs: URL, packages: [URL], at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}

/// An importer that records the files it was handed, each call's rootfs then its packages.
private final class RecordingImporter: FakefsImporter, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [[URL]] = []
    var calls: [[URL]] { lock.withLock { _calls } }

    func makeFakefs(from rootfs: URL, packages: [URL], at directory: URL) throws {
        lock.withLock { _calls.append([rootfs] + packages) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
