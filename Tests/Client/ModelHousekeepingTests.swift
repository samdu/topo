import CryptoKit
import XCTest

@testable import Topo

final class ModelHousekeepingTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("topo-housekeeping-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: The sweep

    /// The store laid out as the phone has it: Parakeet under its id, the spotter in FluidAudio's
    /// own cache, and the voice at `Models/pocket-tts` while its id is `pocket-tts-coreml`. What
    /// the voice's earlier pack left at the root of its home goes, and so does every directory
    /// under `Models/` that is no model's home; the voice itself survives.
    func testTheSweepKeepsTheVoiceWhoseHomeIsNotItsId() throws {
        let (store, manifest) = try realStore()
        let pocket = try XCTUnwrap(manifest.model(ModelManifest.pocket))
        let home = store.directory(for: pocket)
        XCTAssertNotEqual(home.lastPathComponent, pocket.id, "the case this test exists for")
        XCTAssertEqual(home.deletingLastPathComponent(), store.root, "the voice's home is under Models/")

        let strays = [
            home.appendingPathComponent("model.safetensors"),
            home.appendingPathComponent("config.json"),
            home.appendingPathComponent("v2/english/old.mlmodelc/weights/weight.bin"),
            store.root.appendingPathComponent("pocket-tts-coreml/v2.1/english/constants_bin/eponine.bin"),
            store.root.appendingPathComponent("kokoro/model.bin"),
            store.root.appendingPathComponent(".DS_Store"),
        ]
        try strays.forEach(write)

        store.sweep(manifest)

        for model in manifest.models {
            for file in model.files {
                XCTAssertTrue(exists(store.location(of: file, in: model)), "\(model.id)/\(file.path) survives")
            }
            XCTAssertTrue(store.isPresent(model), "\(model.id) is still present")
        }
        for stray in strays { XCTAssertFalse(exists(stray), "\(stray.path) is gone") }
        XCTAssertFalse(exists(home.appendingPathComponent("v2")), "an emptied orphan folder goes with its files")
        XCTAssertFalse(exists(store.root.appendingPathComponent("pocket-tts-coreml")))
        XCTAssertFalse(exists(store.root.appendingPathComponent("kokoro")))
        XCTAssertEqual(try Set(fm.contentsOfDirectory(atPath: store.root.path)),
                       [ModelManifest.parakeet, home.lastPathComponent], "only the two homes under Models/ remain")
    }

    /// A model's directory built from a manifest entry the way the downloader fills one:
    /// repository-relative paths, `.mlmodelc` directories, the ledger beside them, resume data
    /// for a file. Orphans at every depth go; everything the entry or the downloader put there
    /// stays; a link is removed as a link and what it points at is left alone.
    func testTheSweepRemovesOrphansAtEveryDepthAndKeepsTheLedgerAndResumeData() throws {
        let root = base.appendingPathComponent("Models", isDirectory: true)
        let store = ModelStore(root: root)
        let model = try filled(store, id: "example", files: [
            "Encoder.mlmodelc/model.mil": "the graph",
            "Encoder.mlmodelc/weights/weight.bin": "the weights",
            "Encoder.mlmodelc/analytics/coremldata.bin": "analytics",
            "v2.1/english/constants_bin/eponine.bin": "a voice",
            "vocab.json": "the vocabulary",
        ])
        let dir = store.directory(for: model)
        let resume = store.resumeData(for: model.files[1], in: model)
        try write(resume)

        let outside = base.appendingPathComponent("elsewhere/precious.txt")
        try write(outside)
        let orphans = [
            dir.appendingPathComponent("orphan.txt"),
            dir.appendingPathComponent(".hidden"),
            dir.appendingPathComponent("Encoder.mlmodelc/metadata.json"),
            dir.appendingPathComponent("Encoder.mlmodelc/weights/weight.bin.old"),
            dir.appendingPathComponent("Decoder.mlmodelc/weights/weight.bin"),
            dir.appendingPathComponent("v2.1/english/constants_bin/alba.bin"),
            dir.appendingPathComponent("v2.1/french/constants_bin/eponine.bin"),
            dir.appendingPathComponent("v2/english/cond.mlmodelc/model.mil"),
        ]
        try orphans.forEach(write)
        let link = dir.appendingPathComponent("v2.1/elsewhere")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside.deletingLastPathComponent())
        // And one inside an orphan folder, which goes whole: its removal unlinks the link.
        try fm.createSymbolicLink(at: dir.appendingPathComponent("v2/english/elsewhere"),
                                  withDestinationURL: outside.deletingLastPathComponent())

        let removed = store.sweep(ModelManifest(models: [model]))

        for file in model.files { XCTAssertTrue(exists(store.location(of: file, in: model)), file.path) }
        XCTAssertTrue(exists(dir.appendingPathComponent(ModelStore.ledgerName)), "the ledger stays")
        XCTAssertTrue(exists(resume), "the resume data stays")
        XCTAssertTrue(store.isPresent(model))
        for orphan in orphans { XCTAssertFalse(exists(orphan), "\(orphan.path) is gone") }
        XCTAssertFalse(exists(dir.appendingPathComponent("Decoder.mlmodelc")))
        XCTAssertFalse(exists(dir.appendingPathComponent("v2.1/french")))
        XCTAssertFalse(exists(dir.appendingPathComponent("v2")))
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "the link is gone")
        XCTAssertTrue(exists(outside), "what the link pointed at is not the sweep's")
        XCTAssertFalse(removed.isEmpty)
    }

    /// A home that is itself a link is not Topo's to empty: `Models/example` points at a folder
    /// elsewhere holding the manifest's files, a matching ledger and something that is nobody's
    /// business. The model reads as present through the link, and the sweep still enters none of
    /// it, and leaves the link where it is.
    func testAHomeThatIsALinkIsNeverEntered() throws {
        let root = base.appendingPathComponent("Models", isDirectory: true)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        let model = try filled(ModelStore(root: elsewhere), id: "example", files: [
            "Encoder.mlmodelc/weights/weight.bin": "the weights",
            "vocab.json": "the vocabulary",
        ])
        let target = elsewhere.appendingPathComponent("example", isDirectory: true)
        let precious = target.appendingPathComponent("precious.txt")
        let nested = target.appendingPathComponent("Encoder.mlmodelc/notes.txt")
        try [precious, nested].forEach(write)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("example")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let store = ModelStore(root: root)
        XCTAssertTrue(store.isPresent(model), "presence reads through the link")

        XCTAssertEqual(store.sweep(ModelManifest(models: [model])), [], "nothing is removed")

        XCTAssertTrue(exists(precious), "what the link points at is not the sweep's")
        XCTAssertTrue(exists(nested))
        for file in model.files { XCTAssertTrue(exists(target.appendingPathComponent(file.path)), file.path) }
        XCTAssertTrue(exists(target.appendingPathComponent(ModelStore.ledgerName)))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), target.path, "the link is left alone")
    }

    /// `Models` itself a link, to a folder holding a present model's home (with a file in it no
    /// manifest names) and something that is nobody's business: the sweep touches nothing
    /// behind it, at the top level or inside the home, and leaves the link where it is.
    func testARootThatIsALinkIsNeverSwept() throws {
        let support = base.appendingPathComponent("Application Support", isDirectory: true)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        let model = try filled(ModelStore(root: elsewhere), id: "example", files: [
            "Encoder.mlmodelc/weights/weight.bin": "the weights",
            "vocab.json": "the vocabulary",
        ])
        let precious = elsewhere.appendingPathComponent("precious.txt")
        let inside = elsewhere.appendingPathComponent("example/notes.txt")
        try [precious, inside].forEach(write)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let root = support.appendingPathComponent("Models", isDirectory: true)
        try fm.createSymbolicLink(at: root, withDestinationURL: elsewhere)
        let store = ModelStore(root: root)
        XCTAssertTrue(store.isPresent(model), "presence reads through the link")

        XCTAssertEqual(store.sweep(ModelManifest(models: [model])), [], "nothing is removed")

        XCTAssertTrue(exists(precious), "the top level behind the link is not the sweep's")
        XCTAssertTrue(exists(inside), "nor is the home behind it")
        for file in model.files { XCTAssertTrue(exists(elsewhere.appendingPathComponent("example/\(file.path)")), file.path) }
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: root.path), elsewhere.path, "the link is left alone")
    }

    /// A set the downloader has not finished is left whole: a file missing, one at the wrong
    /// size, one on disk that is not in the ledger. The voice's pack in its real home, and an
    /// entry under its id.
    func testAModelThatIsNotPresentIsNotSwept() throws {
        let breaks: [(String, (ModelStore, ModelManifest.Model) throws -> Void)] = [
            ("a file missing", { store, model in
                try self.fm.removeItem(at: store.location(of: model.files[0], in: model))
            }),
            ("a file at the wrong size", { store, model in
                try Data("longer than it should be".utf8).write(to: store.location(of: model.files[0], in: model))
            }),
            ("a file not in the ledger", { store, model in
                let ledger = store.directory(for: model).appendingPathComponent(ModelStore.ledgerName)
                var entries = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: ledger))
                entries[model.files[0].path] = nil
                try JSONEncoder().encode(entries).write(to: ledger)
            }),
        ]
        for (name, breaking) in breaks {
            // The voice, partially downloaded in its real home.
            let (store, manifest) = try realStore()
            let pocket = try XCTUnwrap(manifest.model(ModelManifest.pocket))
            try breaking(store, pocket)
            XCTAssertFalse(store.isPresent(pocket), name)
            let home = store.directory(for: pocket)
            let orphans = [home.appendingPathComponent("model.safetensors"),
                           home.appendingPathComponent("v2.1/english/constants_bin/alba.bin")]
            try orphans.forEach(write)
            // An entry under its id, the same way.
            let root = base.appendingPathComponent("\(UUID().uuidString)/Models", isDirectory: true)
            let plain = ModelStore(root: root)
            let model = try filled(plain, id: "example", files: [
                "Encoder.mlmodelc/weights/weight.bin": "the weights",
                "vocab.json": "the vocabulary",
            ])
            try breaking(plain, model)
            let resume = plain.resumeData(for: model.files[0], in: model)
            try write(resume)
            let loose = [plain.directory(for: model).appendingPathComponent("stray.bin"),
                         plain.directory(for: model).appendingPathComponent("Encoder.mlmodelc/stray.bin")]
            try loose.forEach(write)

            XCTAssertEqual(store.sweep(manifest), [], "\(name): nothing of the voice's is removed")
            XCTAssertEqual(plain.sweep(ModelManifest(models: [model])), [], "\(name): nothing is removed")

            for orphan in orphans + loose + [resume] { XCTAssertTrue(exists(orphan), "\(name): \(orphan.path) stays") }
            for file in pocket.files.dropFirst() { XCTAssertTrue(exists(store.location(of: file, in: pocket)), "\(name): \(file.path)") }
        }
    }

    /// The spotter's home is FluidAudio's cache directory, which the library writes into for
    /// itself: the manifest's files are there, and so are files the manifest never placed, and
    /// the sweep enters none of it.
    func testALibrarysHomeIsNotSwept() throws {
        let (store, manifest) = try realStore()
        let ctc = try XCTUnwrap(manifest.model(ModelManifest.ctc))
        XCTAssertFalse(store.owns(ctc), "the spotter's home is FluidAudio's")
        XCTAssertTrue(store.isPresent(ctc))
        let home = store.directory(for: ctc)
        let theirs = [home.appendingPathComponent("AudioEncoder.mlpackage/Manifest.json"),
                      home.appendingPathComponent(".cache/metadata"),
                      home.appendingPathComponent("config.json"),
                      home.deletingLastPathComponent().appendingPathComponent("parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc/model.mil")]
        try theirs.forEach(write)

        store.sweep(manifest)

        for file in theirs { XCTAssertTrue(exists(file), "\(file.path) is the library's") }
        for file in ctc.files { XCTAssertTrue(exists(store.location(of: file, in: ctc)), file.path) }
    }

    /// The bundled manifest, over the homes the phone's store has, resolves the voice to
    /// `Models/pocket-tts`, a home Topo owns and one that is not named after its id.
    func testTheBundledManifestResolvesTheVoiceToItsHome() throws {
        let manifest = try ModelManifest.bundled()
        let store = ModelStore(root: base.appendingPathComponent("Models"),
                               homes: [ModelManifest.pocket: ModelStore.pocketHome(under: base)])
        let pocket = try XCTUnwrap(manifest.model(ModelManifest.pocket))
        XCTAssertEqual(store.directory(for: pocket).path, base.appendingPathComponent("Models/pocket-tts").path)
        XCTAssertTrue(store.owns(pocket))
    }

    // MARK: The compile cache

    /// A first launch with nothing recorded clears; a relaunch on the same install does not; a
    /// new install does; a removal that fails records nothing, so the next launch tries again.
    /// Every sibling of the cache survives every case.
    func testTheCompileCacheIsClearedOncePerInstall() throws {
        let caches = base.appendingPathComponent("Library/Caches", isDirectory: true)
        let cache = CompileCache.directory(caches: caches, bundleIdentifier: "zone.hexagon.topo")
        XCTAssertEqual(cache.path, caches.appendingPathComponent("zone.hexagon.topo/com.apple.e5rt.e5bundlecache").path)
        let siblings = [caches.appendingPathComponent("zone.hexagon.topo/Cache.db"),
                        caches.appendingPathComponent("zone.hexagon.topo/fsCachedData/ABCD"),
                        caches.appendingPathComponent("zone.hexagon.topo/com.apple.e5rt.e5bundlecache.old/x"),
                        caches.appendingPathComponent("com.apple.metal/shaders"),
                        caches.appendingPathComponent("CloudKit/records")]
        try siblings.forEach(write)
        let suite = "topo-compile-cache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func generation(_ name: String) throws { try write(cache.appendingPathComponent("\(name)/bundle.e5")) }
        let clear = CompileCache(directory: cache, defaults: defaults)

        try generation("16th")
        try generation("17th")
        XCTAssertEqual(clear.clear(install: "A"), .cleared, "a first launch with no key recorded clears")
        XCTAssertFalse(exists(cache))
        XCTAssertEqual(defaults.string(forKey: CompileCache.recorded), "A")

        try generation("A")
        XCTAssertEqual(clear.clear(install: "A"), .sameInstall, "a relaunch of the same install clears nothing")
        XCTAssertTrue(exists(cache.appendingPathComponent("A/bundle.e5")))

        struct Refused: Error {}
        let failing = CompileCache(directory: cache, defaults: defaults) { _ in throw Refused() }
        guard case .failed = failing.clear(install: "B") else { return XCTFail("a refused removal is a failure") }
        XCTAssertEqual(defaults.string(forKey: CompileCache.recorded), "A", "a failed removal is not remembered as done")
        XCTAssertTrue(exists(cache))

        XCTAssertEqual(clear.clear(install: "B"), .cleared, "the next launch tries again, and a new install clears")
        XCTAssertFalse(exists(cache))
        XCTAssertEqual(defaults.string(forKey: CompileCache.recorded), "B")

        XCTAssertEqual(clear.clear(install: "C"), .absent, "a new install with no cache records its key")
        XCTAssertEqual(defaults.string(forKey: CompileCache.recorded), "C")

        for sibling in siblings { XCTAssertTrue(exists(sibling), "\(sibling.path) is not the compile cache") }
    }

    /// The cache's own folder under Caches a link to somewhere else: nothing behind it is
    /// removed, and the key is not recorded, so a later launch looks again.
    func testACacheReachedThroughALinkIsNotCleared() throws {
        let caches = base.appendingPathComponent("Library/Caches", isDirectory: true)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        let behind = elsewhere.appendingPathComponent("com.apple.e5rt.e5bundlecache/first/bundle.e5")
        let precious = elsewhere.appendingPathComponent("precious.txt")
        try [behind, precious].forEach(write)
        try fm.createDirectory(at: caches, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: caches.appendingPathComponent("zone.hexagon.topo"), withDestinationURL: elsewhere)
        let suite = "topo-cache-link-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clear = CompileCache(directory: CompileCache.directory(caches: caches, bundleIdentifier: "zone.hexagon.topo"),
                                 defaults: defaults)

        guard case .failed = clear.clear(install: "A") else { return XCTFail("a cache behind a link is refused") }
        XCTAssertTrue(exists(behind), "nothing behind the link is removed")
        XCTAssertTrue(exists(precious))
        XCTAssertNil(defaults.string(forKey: CompileCache.recorded), "nothing is recorded")
    }

    /// The key the app runs with is read off this image and this bundle, and is the same on
    /// every read.
    func testTheInstallKeyIsThisImageAndThisBundle() throws {
        let image = try XCTUnwrap(CompileCache.imageUUID())
        XCTAssertNotNil(UUID(uuidString: image))
        let key = try XCTUnwrap(CompileCache.installKey())
        XCTAssertEqual(key, CompileCache.installKey(image: image, bundle: Bundle.main.bundleURL))
        XCTAssertEqual(CompileCache.installKey(), key)
    }

    /// A byte-identical build installed over itself has the same UUID and a new bundle
    /// container, and is a new install: it clears. The same UUID at the same path is a relaunch,
    /// and does not.
    func testTheSameBuildInstalledAgainIsANewInstall() throws {
        let cache = base.appendingPathComponent("Library/Caches/zone.hexagon.topo/com.apple.e5rt.e5bundlecache")
        let suite = "topo-install-key-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clear = CompileCache(directory: cache, defaults: defaults)
        let image = "8DCA16A0-1AE6-3AF6-B0E6-2196DC5EE906"
        let first = URL(fileURLWithPath: "/containers/Bundle/Application/73E6F797-EE47-46A6-AAD7-8F6BA62AC899/Topo.app")
        let second = URL(fileURLWithPath: "/containers/Bundle/Application/0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0/Topo.app")

        try write(cache.appendingPathComponent("first/bundle.e5"))
        XCTAssertEqual(clear.clear(install: CompileCache.installKey(image: image, bundle: first)), .cleared)
        try write(cache.appendingPathComponent("first/bundle.e5"))
        XCTAssertEqual(clear.clear(install: CompileCache.installKey(image: image, bundle: first)), .sameInstall,
                       "the same build at the same path is a relaunch")
        XCTAssertTrue(exists(cache))
        XCTAssertEqual(clear.clear(install: CompileCache.installKey(image: image, bundle: second)), .cleared,
                       "the same build in a new bundle container is a new install")
        XCTAssertFalse(exists(cache))
    }

    /// The launch clears before either the ear or the voice exists, since a debug build's start
    /// loading as they are made, and `prepare` is only reachable through them.
    @MainActor
    func testTheLaunchClearsBeforeTheEarOrTheVoiceExists() {
        var order: [String] = []
        let (ear, voice) = ModelHousekeeping.launch(clear: { order.append("clear") },
                                                    ear: { order.append("ear"); return "ear" },
                                                    voice: { order.append("voice"); return "voice" })
        XCTAssertEqual(order, ["clear", "ear", "voice"])
        XCTAssertEqual(ear, "ear")
        XCTAssertEqual(voice, "voice")
    }

    // MARK: Helpers

    /// A store with the phone's homes under `base` and a manifest of three entries, every one
    /// present: Parakeet under its id, the spotter in a library's cache, the voice in the home
    /// FluidAudio names for it.
    private func realStore() throws -> (ModelStore, ModelManifest) {
        let root = base.appendingPathComponent("\(UUID().uuidString)/Models", isDirectory: true)
        let support = root.deletingLastPathComponent()
        let store = ModelStore(root: root, homes: [
            ModelManifest.ctc: support.appendingPathComponent("FluidAudio/Models/\(ModelManifest.ctc)", isDirectory: true),
            ModelManifest.pocket: ModelStore.pocketHome(under: support),
        ])
        let parakeet = try filled(store, id: ModelManifest.parakeet, files: [
            "Encoder.mlmodelc/model.mil": "encoder graph",
            "Encoder.mlmodelc/weights/weight.bin": "encoder weights",
            "parakeet_vocab.json": "vocabulary",
        ])
        let ctc = try filled(store, id: ModelManifest.ctc, files: [
            "AudioEncoder.mlmodelc/weights/weight.bin": "ctc weights",
            "tokenizer.json": "tokenizer",
        ])
        let pocket = try filled(store, id: ModelManifest.pocket, files: [
            "v2.1/english/cond_step.mlmodelc/weights/weight.bin": "conditioner",
            "v2.1/english/cond_step.mlmodelc/model.mil": "conditioner graph",
            "v2.1/english/constants_bin/eponine.bin": "eponine",
            "v2.1/english/tokenizer.model": "tokenizer",
        ])
        return (store, ModelManifest(models: [parakeet, ctc, pocket]))
    }

    /// A manifest entry for `files`, admitted into `store` the way the downloader admits each.
    private func filled(_ store: ModelStore, id: String, files: [String: String]) throws -> ModelManifest.Model {
        let entries = files.sorted { $0.key < $1.key }.map { path, text -> ModelManifest.File in
            let data = Data(text.utf8)
            return .init(path: path, size: Int64(data.count),
                         sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        let model = ModelManifest.Model(id: id, repo: "example/\(id)", revision: String(repeating: "0", count: 40), files: entries)
        for file in entries {
            let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data(files[file.path]!.utf8).write(to: temp)
            try store.admit(temp, as: file, of: model)
        }
        XCTAssertTrue(store.isPresent(model), id)
        return model
    }

    private func write(_ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("orphan \(url.lastPathComponent)".utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
}

final class ModelPreparingWordsTests: XCTestCase {
    /// The step a first load after an install spends its time in reads as what it is, on the
    /// status lines and the diagnostics `speech` and `voice` rows alike (both read `summary`).
    @MainActor
    func testLoadingReadsAsPreparingTheModelForThisPhone() {
        let ear = DebugRun.ear(["TOPO_DEBUG_EAR": "loading"])
        XCTAssertEqual(ear.state, .loading)
        XCTAssertEqual(ear.summary, "preparing the models for this phone")
        let voice = DebugRun.voice(["TOPO_DEBUG_VOICE": "loading"])
        XCTAssertEqual(voice.state, .loading)
        XCTAssertEqual(voice.summary, "preparing the model for this phone")
    }
}
