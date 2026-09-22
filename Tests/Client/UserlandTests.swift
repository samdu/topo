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
                                source: source, claudeSource: ScriptedSource())
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
        source.settle(.success(Fetched(file: tarball, size: pin.size, sha256: pin.sha256, version: nil)))
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
                                source: source, claudeSource: ScriptedSource())
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
                                source: ScriptedSource(), claudeSource: claude)
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
        claude.settle(.success(Fetched(file: binary, size: 226_637_472, sha256: String(repeating: "c", count: 64), version: "2.1.278")))
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
                                    source: ScriptedSource(), claudeSource: claude)
            let answer = Answer()
            Task { @MainActor in await answer.settle { try await userland.claudeCode().binary } }
            try await until { claude.fetches == 1 }
            claude.settle(.success(Fetched(file: base.appendingPathComponent("claude"), size: 1,
                                           sha256: String(repeating: "c", count: 64), version: version)))
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

    /// The diagnostics row says which of the two downloads the guest is waiting on.
    func testTheUserlandRowSaysWhichDownloadIsOutstanding() async throws {
        let rootfs = ScriptedSource(), claude = ScriptedSource()
        let userland = Userland(installer: RootfsInstaller(directory: base.appendingPathComponent("Userland"), importer: MakesADirectory()),
                                source: rootfs, claudeSource: claude)
        rootfs.status = "downloading 1 MB of 4 MB"
        claude.status = "downloading 20 MB of 227 MB"
        userland.prepare()
        XCTAssertEqual(userland.summary, "rootfs downloading 1 MB of 4 MB; claude code downloading 20 MB of 227 MB")

        let (tarball, pin) = try tarballAndPin()
        rootfs.settle(.success(Fetched(file: tarball, size: pin.size, sha256: pin.sha256, version: nil)))
        _ = try await userland.ready()
        XCTAssertEqual(userland.summary, "rootfs ready; claude code downloading 20 MB of 227 MB")

        claude.settle(.success(Fetched(file: base.appendingPathComponent("claude"), size: 1,
                                       sha256: String(repeating: "c", count: 64), version: "2.1.278")))
        XCTAssertEqual(userland.summary, "rootfs ready; claude code 2.1.278 downloaded")
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
    private var pending: [@MainActor (Result<Fetched, Error>) -> Void] = []
    var isFetched: Bool { false }
    var status: String = "scripted"

    func fetch(_ done: @escaping @MainActor (Result<Fetched, Error>) -> Void) {
        fetches += 1
        pending.append(done)
    }

    func settle(_ result: Result<Fetched, Error>) {
        let waiting = pending
        pending = []
        waiting.forEach { $0(result) }
    }
}

private struct MakesADirectory: FakefsImporter {
    func makeFakefs(from tarball: URL, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
