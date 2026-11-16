import CryptoKit
import FluidAudio
import XCTest

@testable import Topo

/// Records what the ear asks it to load, and loads nothing.
private actor LoadingEngine: SpeechEngine {
    struct Load: Equatable { let acoustic: URL; let model: EarModel }
    var loads: [Load] = []
    var spotters: [URL] = []
    var rebuilds: [[String]] = []
    /// A model whose load throws, as a compile that fails does.
    var refusing: EarModel?

    func refuse(_ model: EarModel) { refusing = model }

    func load(acoustic: URL, model: EarModel, onProgress: @escaping @Sendable (String) -> Void) async throws {
        loads.append(Load(acoustic: acoustic, model: model))
        if model == refusing { throw CocoaError(.fileReadCorruptFile) }
    }
    func loadSpotter(_ ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
        spotters.append(ctc)
    }
    func rebuild(terms: [String], version: Int) async throws { rebuilds.append(terms) }
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String { "" }
}

/// A download that never answers, so a model not on disk stays not on disk.
private final class SilentProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// The ear over its store: Ultra from this build's source on a fresh phone, ready before the
/// spotter; v2 on a phone that has it while Ultra's copy is made beside it, Ultra the launch after
/// and v2 removed; the spotter joining a resident ear; and a copy that fails, failing the ear.
@MainActor
final class EarStoreTests: XCTestCase {
    private let fm = FileManager.default
    private var base: URL!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("ear-store-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Ultra's bundle as a source folder: one weight file and the `bundle.json` naming it, with
    /// `missing` leaving the file out.
    private func source(missing: Bool = false) throws -> FolderSource {
        let folder = base.appendingPathComponent("source/\(BundleStore.earName)", isDirectory: true)
        let path = "Encoder.mlmodelc/weights/weight.bin"
        let data = Data("ultra".utf8)
        try fm.createDirectory(at: folder.appendingPathComponent("Encoder.mlmodelc/weights"), withIntermediateDirectories: true)
        if !missing { try data.write(to: folder.appendingPathComponent(path)) }
        let manifest: [String: Any] = ["built": 1, "files": [["path": path, "size": data.count, "sha256": digest(data)]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("bundle.json"))
        return FolderSource(folder: folder)
    }

    private var store: BundleStore {
        BundleStore(home: base.appendingPathComponent("Ear/\(BundleStore.earName)", isDirectory: true), noun: "ear")
    }

    private let modelData = Data("abc".utf8)
    private var manifest: ModelManifest {
        let revision = String(repeating: "0", count: 40)
        let file = ModelManifest.File(path: "model.bin", size: Int64(modelData.count), sha256: digest(modelData))
        return ModelManifest(models: [
            .init(id: ModelManifest.parakeet, repo: "example/v2", revision: revision, files: [file]),
            .init(id: ModelManifest.ctc, repo: "example/ctc", revision: revision, files: [file]),
        ])
    }
    private var models: ModelStore { ModelStore(root: base.appendingPathComponent("Models", isDirectory: true)) }

    /// A model of the manifest on disk and in its ledger, as a finished download leaves it.
    private func present(_ id: String) throws {
        let model = try XCTUnwrap(manifest.model(id))
        let temp = base.appendingPathComponent(UUID().uuidString)
        try modelData.write(to: temp)
        try models.admit(temp, as: model.files[0], of: model)
    }

    /// A launch's downloads over the test's store, whose downloads never answer.
    private func downloads() -> ModelDownloads {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SilentProtocol.self]
        let suite = "topo-ear-store-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ModelDownloads(store: models, manifest: .success(manifest), configuration: configuration, defaults: defaults)
    }

    private func ear(_ engine: LoadingEngine, source: FolderSource, downloads: ModelDownloads? = nil) -> Ear {
        Ear(vocabulary: Vocabulary(defaults: UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!),
            engine: engine, store: store, source: source, downloads: downloads ?? self.downloads())
    }

    /// The models `downloads` has a task for, by id.
    private func asked(_ downloads: ModelDownloads) -> Set<String> {
        Set(downloads.live.compactMap { $0.split(separator: "|").first.map(String.init) })
    }

    private func settle(_ what: String, until condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<300 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let settled = await condition()
        XCTAssertTrue(settled, what)
    }

    /// FluidAudio loads Ultra from the folder its repository names locally, beneath the parent
    /// of the one it is handed, so the store's folder is that name or no file of it is found.
    func testTheStoresFolderIsTheOneFluidAudioLoadsUltraFrom() {
        XCTAssertEqual(BundleStore.earName, Repo.parakeetUltra.folderName)
        XCTAssertEqual(EarEngine.version(.ultra), .ultra)
    }

    func testAFreshPhoneHearsWithUltraFromItsSourceBeforeTheSpotterArrives() async throws {
        let engine = LoadingEngine()
        let ear = ear(engine, source: try source())
        ear.prepare()
        XCTAssertEqual(ear.state, .fetching, "a fresh phone waits on Ultra's copy, not on a download")
        await settle("Ultra is resident") { ear.state == .ready }
        let loads = await engine.loads
        XCTAssertEqual(loads, [.init(acoustic: store.home, model: .ultra)], "the ear is Ultra, from its store")
        XCTAssertTrue(store.isWhole())
        XCTAssertFalse(ear.spotterResident, "the spotter's download has not answered")
        XCTAssertTrue(ear.summary.hasPrefix("Parakeet Ultra resident; vocabulary boost waiting for its spotter"), ear.summary)
        let spotters = await engine.spotters
        XCTAssertEqual(spotters, [], "no spotter is loaded that is not on disk")
    }

    func testAPhoneWithV2HearsWithV2WhileUltraIsCopiedAndWithUltraTheLaunchAfter() async throws {
        try present(ModelManifest.parakeet)
        let v2 = models.directory(for: try XCTUnwrap(manifest.model(ModelManifest.parakeet)))
        let source = try source()

        let first = LoadingEngine()
        let before = ear(first, source: source)
        before.prepare()
        XCTAssertEqual(before.state, .loading, "the ear is v2 at once, with no wait on Ultra's copy")
        await settle("v2 is resident") { before.state == .ready }
        await settle("Ultra's copy is made beside v2") { self.store.installed() != nil && self.store.isWhole() }
        var loads = await first.loads
        XCTAssertEqual(loads, [.init(acoustic: v2, model: .v2)], "Ultra is not loaded beside v2")
        XCTAssertTrue(fm.fileExists(atPath: v2.path), "v2 stays while it is the ear")
        before.prepare()
        loads = await first.loads
        XCTAssertEqual(loads.count, 1, "a foreground over a resident ear loads nothing")

        let second = LoadingEngine()
        let after = ear(second, source: source)
        after.prepare()
        await settle("Ultra is resident the launch after") { after.state == .ready }
        loads = await second.loads
        XCTAssertEqual(loads, [.init(acoustic: store.home, model: .ultra)])
        XCTAssertFalse(fm.fileExists(atPath: v2.path), "v2 is removed once Ultra is the ear")
    }

    func testAPhoneWithoutV2DownloadsNoV2() async throws {
        let engine = LoadingEngine()
        let downloads = downloads()
        let ear = ear(engine, source: try source(), downloads: downloads)
        ear.prepare()
        await settle("Ultra is resident") { ear.state == .ready }
        await settle("the spotter's download is asked for") { self.asked(downloads).contains(ModelManifest.ctc) }
        ear.prepare()
        XCTAssertEqual(asked(downloads), [ModelManifest.ctc], "the ear asks for the spotter and nothing else")
        XCTAssertEqual(downloads.status(for: ModelManifest.parakeet), .absent)
    }

    func testAnEarADebugLaunchLoadedAsksForNoSpotter() async throws {
        let engine = LoadingEngine()
        let downloads = downloads()
        let ear = ear(engine, source: try source(), downloads: downloads)
        ear.load(acoustic: URL(fileURLWithPath: "/stub"))
        ear.prepare()
        await settle("the debug ear is resident") { ear.state == .ready }
        ear.prepare()
        XCTAssertEqual(asked(downloads), [], "a foreground over a debug ear started a download")
        XCTAssertEqual(downloads.status(for: ModelManifest.ctc), .absent)
    }

    func testUltraThatWillNotLoadOnAPhoneWithV2HearsWithV2AndKeepsIt() async throws {
        try present(ModelManifest.parakeet)
        let v2 = models.directory(for: try XCTUnwrap(manifest.model(ModelManifest.parakeet)))
        let source = try source()
        _ = try await store.install(from: source, progress: { _ in }, copying: {})
        let engine = LoadingEngine()
        await engine.refuse(.ultra)
        let ear = ear(engine, source: source)
        var settled = 0
        ear.settled = { settled += 1 }
        ear.prepare()
        await settle("v2 is resident") { ear.state == .ready }
        let loads = await engine.loads
        XCTAssertEqual(loads, [.init(acoustic: store.home, model: .ultra), .init(acoustic: v2, model: .v2)])
        XCTAssertEqual(ear.summary.hasPrefix("Parakeet v2 resident"), true, ear.summary)
        XCTAssertTrue(fm.fileExists(atPath: v2.path), "v2 is kept while Ultra will not load")
        XCTAssertEqual(settled, 1, "the voice is let go once, when v2 is resident")
    }

    func testTheSpotterOnDiskJoinsTheEarOnceItIsResident() async throws {
        try present(ModelManifest.ctc)
        let engine = LoadingEngine()
        let vocabulary = Vocabulary(defaults: UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!)
        vocabulary.add("Daphne")
        let ear = Ear(vocabulary: vocabulary, engine: engine, store: store, source: try source(), downloads: downloads())
        ear.prepare()
        await settle("the spotter is resident") { ear.state == .ready && ear.spotterResident }
        await settle("the boost is built over the list") { await !engine.rebuilds.isEmpty }
        let spotters = await engine.spotters
        XCTAssertEqual(spotters, [models.directory(for: try XCTUnwrap(manifest.model(ModelManifest.ctc)))])
        let rebuilds = await engine.rebuilds
        XCTAssertTrue(rebuilds.allSatisfy { $0 == ["Daphne"] }, "\(rebuilds)")
        XCTAssertEqual(ear.summary, "Parakeet Ultra resident")
    }

    func testACopyThatFailsFailsTheEarAndSettlesIt() async throws {
        let engine = LoadingEngine()
        let ear = ear(engine, source: try source(missing: true))
        var settled = 0
        ear.settled = { settled += 1 }
        ear.prepare()
        await settle("the ear fails") { ear.state == .failed }
        XCTAssertEqual(settled, 1, "the voice is let go once")
        XCTAssertTrue(ear.summary.hasPrefix("failed: "), ear.summary)
        let loads = await engine.loads
        XCTAssertEqual(loads, [], "nothing is loaded from a copy that was not made")
        XCTAssertFalse(fm.fileExists(atPath: store.home.path))
    }
}
