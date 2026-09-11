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
        for id in [ModelManifest.parakeet, ModelManifest.ctc, ModelManifest.kokoro, ModelManifest.g2p] {
            let model = try XCTUnwrap(manifest.model(id), id)
            XCTAssertFalse(model.files.isEmpty, id)
            XCTAssertEqual(model.revision.count, 40, "\(id) is pinned to a commit")
            for file in model.files {
                XCTAssertEqual(file.sha256.count, 64, "\(id)/\(file.path)")
                XCTAssertTrue(file.sha256.allSatisfy(\.isHexDigit), "\(id)/\(file.path)")
                XCTAssertGreaterThan(file.size, 0, "\(id)/\(file.path)")
                XCTAssertEqual(model.url(for: file).host, "huggingface.co")
            }
        }
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
