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
                                source: source)
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
        source.settle(.success((tarball, pin)))
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
                                source: source)
        userland.prepare()
        userland.prepare()
        userland.prepare()
        XCTAssertEqual(source.fetches, 1)
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
private final class ScriptedSource: RootfsSource {
    private(set) var fetches = 0
    private var pending: [@MainActor (Result<(tarball: URL, pin: RootfsPin), Error>) -> Void] = []
    var isFetched: Bool { false }
    var status: String { "scripted" }

    func fetch(_ done: @escaping @MainActor (Result<(tarball: URL, pin: RootfsPin), Error>) -> Void) {
        fetches += 1
        pending.append(done)
    }

    func settle(_ result: Result<(tarball: URL, pin: RootfsPin), Error>) {
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
