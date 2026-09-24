import CryptoKit
import XCTest

@testable import Topo

final class ModelDownloadsTests: XCTestCase {
    /// The session obeys the person's data settings and outlives the process: nothing expensive
    /// or constrained, waits for a network rather than failing without one, wakes the app when
    /// it is done.
    @MainActor
    func testTheSessionConfigurationLeavesTheDataSettingsToIOS() {
        let configuration = ModelDownloads.configuration()
        XCTAssertEqual(configuration.identifier, "zone.hexagon.topo.models")
        XCTAssertFalse(configuration.allowsExpensiveNetworkAccess)
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)
        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertFalse(configuration.isDiscretionary)
        XCTAssertTrue(configuration.sessionSendsLaunchEvents)
    }

    func testTheBundledManifestNamesEveryModelWithADigestForEveryFile() throws {
        let manifest = try ModelManifest.bundled()
        for id in [ModelManifest.parakeet, ModelManifest.ctc, ModelManifest.pocket] {
            let model = try XCTUnwrap(manifest.model(id), id)
            XCTAssertFalse(model.files.isEmpty, id)
            XCTAssertEqual(model.revision?.count, 40, "\(id) is pinned to a commit")
            for file in model.files {
                XCTAssertEqual(file.sha256.count, 64, "\(id)/\(file.path)")
                XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit), "\(id)/\(file.path)")
                XCTAssertGreaterThan(file.size, 0, "\(id)/\(file.path)")
                XCTAssertEqual(model.url(for: file).host, "huggingface.co")
            }
        }
        // The guest's rootfs is not on the Hub: one tarball, fetched from Alpine's CDN at the
        // pinned release, and checked against its digest like every model file.
        let rootfs = try XCTUnwrap(manifest.model(ModelManifest.rootfs))
        XCTAssertNil(rootfs.repo)
        XCTAssertEqual(rootfs.files.map(\.path), ["alpine-minirootfs-3.22.6-aarch64.tar.gz"])
        XCTAssertEqual(rootfs.url(for: rootfs.files[0]).absoluteString,
                       "https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/alpine-minirootfs-3.22.6-aarch64.tar.gz")
        XCTAssertEqual(rootfs.files[0].sha256.count, 64)
        XCTAssertGreaterThan(rootfs.files[0].size, 0)
        // bash for the guest: Alpine's own packages for the same branch and architecture, bash
        // first, each an `.apk` from the branch's repository, checked by digest like the rootfs.
        let shell = try XCTUnwrap(manifest.model(ModelManifest.shell))
        XCTAssertNil(shell.repo)
        XCTAssertEqual(shell.url, "https://dl-cdn.alpinelinux.org/alpine/v3.22/main/aarch64/")
        XCTAssertTrue(shell.files.first?.path.hasPrefix("bash-") ?? false, "\(shell.files.map(\.path))")
        for file in shell.files {
            XCTAssertTrue(file.path.hasSuffix(".apk"), file.path)
            XCTAssertEqual(file.sha256.count, 64, file.path)
            XCTAssertGreaterThan(file.size, 0, file.path)
        }
        // Claude Code is Anthropic's own release distribution, the one the official installer
        // reads: the musl arm64 build at the pinned version, one binary, checked by digest.
        let claude = try XCTUnwrap(manifest.model(ModelManifest.claudeCode))
        XCTAssertNil(claude.repo)
        let version = try XCTUnwrap(claude.version)
        XCTAssertNotNil(version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression), version)
        XCTAssertEqual(claude.files.map(\.path), ["claude"])
        XCTAssertEqual(claude.url(for: claude.files[0]).absoluteString,
                       "https://downloads.claude.ai/claude-code-releases/\(version)/linux-arm64-musl/claude")
        XCTAssertEqual(claude.files[0].sha256.count, 64)
        XCTAssertGreaterThan(claude.files[0].size, 100_000_000)
        // The CoreML bundles arrive flattened: a bundle is several files on the Hub.
        let parakeet = try XCTUnwrap(manifest.model(ModelManifest.parakeet))
        XCTAssertTrue(parakeet.files.contains { $0.path == "Encoder.mlmodelc/weights/weight.bin" })
        XCTAssertTrue(parakeet.files.contains { $0.path == "parakeet_vocab.json" })
    }

    func testAModelIsPresentOnlyWhenEveryFileIsVerified() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topo-models-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ModelStore(root: root)
        let a = Data("the encoder".utf8), b = Data("the vocabulary".utf8)
        let model = ModelManifest.Model(id: "example", repo: "example/example", revision: String(repeating: "0", count: 40), files: [
            .init(path: "Encoder.mlmodelc/weights/weight.bin", size: Int64(a.count), sha256: digest(a)),
            .init(path: "vocab.json", size: Int64(b.count), sha256: digest(b)),
        ])

        XCTAssertFalse(store.isPresent(model))
        XCTAssertEqual(store.unverified(model).map(\.path), model.files.map(\.path))

        try store.admit(temp(a), as: model.files[0], of: model)
        XCTAssertFalse(store.isPresent(model), "one file of two is not present")
        XCTAssertEqual(store.unverified(model).map(\.path), ["vocab.json"])
        XCTAssertEqual(store.verifiedBytes(model), Int64(a.count))

        // Wrong bytes at the right size are refused and leave nothing behind.
        XCTAssertThrowsError(try store.admit(temp(Data("the vocabulary".utf8.reversed())), as: model.files[1], of: model))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.location(of: model.files[1], in: model).path))
        XCTAssertFalse(store.isPresent(model))
        // So is the wrong size.
        XCTAssertThrowsError(try store.admit(temp(Data("short".utf8)), as: model.files[1], of: model))
        XCTAssertFalse(store.isPresent(model))

        try store.admit(temp(b), as: model.files[1], of: model)
        XCTAssertTrue(store.isPresent(model))
        XCTAssertEqual(store.verifiedBytes(model), Int64(a.count + b.count))

        // A verified file that goes missing, or changes size, takes the model back to partial.
        try FileManager.default.removeItem(at: store.location(of: model.files[0], in: model))
        XCTAssertFalse(store.isPresent(model))
        XCTAssertEqual(store.unverified(model).map(\.path), ["Encoder.mlmodelc/weights/weight.bin"])
        try store.admit(temp(a), as: model.files[0], of: model)
        XCTAssertTrue(store.isPresent(model))
        try Data("the encoder, longer".utf8).write(to: store.location(of: model.files[0], in: model))
        XCTAssertFalse(store.isPresent(model))
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
}

/// The downloader's waiters: a failure settles the waiters that asked to hear of one, and leaves
/// the ones waiting only for success to wait on.
@MainActor
final class ModelWaitersTests: XCTestCase {
    func testAFailureSettlesTheWaitersThatAskedForIt() {
        var waiters = ModelWaiters()
        var told: [Result<Void, ModelDownloadFailure>] = []
        waiters.add(["rootfs"], settlesOnFailure: true) { told.append($0) }
        waiters.add(["rootfs"], settlesOnFailure: false) { _ in XCTFail("a success-only waiter heard a failure") }
        waiters.add(["voice"], settlesOnFailure: true) { _ in XCTFail("a waiter on another model heard the failure") }

        let failure = ModelDownloadFailure(id: "rootfs", why: "404")
        waiters.failed("rootfs").forEach { $0(.failure(failure)) }
        XCTAssertEqual(told.count, 1)
        if case .failure(let got) = told.first { XCTAssertEqual(got, failure) } else { XCTFail("not told the failure") }
        XCTAssertEqual(waiters.count, 2, "the settled waiter is gone, the other two wait on")
        XCTAssertTrue(waiters.failed("rootfs").isEmpty, "a settled waiter was told twice")
    }

    func testSuccessSettlesEveryWaiterWhoseModelsArePresent() {
        var waiters = ModelWaiters()
        var told = 0
        waiters.add(["rootfs"], settlesOnFailure: true) { if case .success = $0 { told += 1 } }
        waiters.add(["rootfs"], settlesOnFailure: false) { if case .success = $0 { told += 1 } }
        waiters.add(["rootfs", "voice"], settlesOnFailure: true) { _ in XCTFail("settled with a model still missing") }
        waiters.present(["rootfs"]).forEach { $0(.success(())) }
        XCTAssertEqual(told, 2)
        XCTAssertEqual(waiters.count, 1)
    }
}
