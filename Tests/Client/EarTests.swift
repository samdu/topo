import XCTest

@testable import Topo

/// The ear's engine as a double: records the lists it is handed, and fails to build a session
/// when told to, the way FluidAudio's does when its tokenizer is not where it expects.
private actor FakeEngine: SpeechEngine {
    var rebuilds: [[String]] = []
    var refuseSessions = false

    func refuse() { refuseSessions = true }

    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
        onProgress("loaded")
    }

    func rebuild(terms: [String], version: Int) async throws {
        rebuilds.append(terms)
        if refuseSessions { throw EarError.unavailable("tokenizer.json not found") }
    }

    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String { "heard" }
}

private struct StubBoost: Boost {
    func rescored(_ text: String, timings: EarTimings, samples: [Float]) async -> String? { nil }
}

@MainActor
final class EarTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!
    }

    /// The ear's work is on tasks of its own; a test waits for the state it expects.
    private func settle(until condition: @escaping @MainActor () async -> Bool) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let settled = await condition()
        XCTAssertTrue(settled)
    }

    // MARK: EarEngine

    func testAnEmptyVocabularyBuildsNoSession() async throws {
        let asked = Counter()
        let engine = EarEngine(builder: { _ in asked.bump(); return StubBoost() })
        try await engine.rebuild(terms: [], version: 1)
        let boosted = await engine.boosted
        XCTAssertFalse(boosted)
        XCTAssertEqual(asked.count, 0, "no session is built over nothing")
    }

    func testATermAddedLaterBuildsOneAndRemovingItClearsIt() async throws {
        let engine = EarEngine(builder: { _ in StubBoost() })
        try await engine.rebuild(terms: [], version: 1)
        try await engine.rebuild(terms: ["Daphne"], version: 2)
        var boosted = await engine.boosted
        XCTAssertTrue(boosted)
        try await engine.rebuild(terms: [], version: 3)
        boosted = await engine.boosted
        XCTAssertFalse(boosted, "removing the last term removes the boost")
    }

    func testASessionThatCannotBeBuiltLeavesTheOneStanding() async throws {
        let fail = Counter()
        let engine = EarEngine(builder: { terms in
            if terms.contains("broken") { fail.bump(); throw EarError.unavailable("tokenizer.json not found") }
            return StubBoost()
        })
        try await engine.rebuild(terms: ["Daphne"], version: 1)
        do {
            try await engine.rebuild(terms: ["Daphne", "broken"], version: 2)
            XCTFail("the failure is reported")
        } catch {}
        let boosted = await engine.boosted
        XCTAssertTrue(boosted)
        XCTAssertEqual(fail.count, 1)
    }

    // MARK: Ear

    func testTheEarIsReadyWithoutAVocabularyAndTheSpotterIsToldSo() async {
        let engine = FakeEngine()
        let ear = Ear(vocabulary: Vocabulary(defaults: makeDefaults()), engine: engine)
        ear.load(parakeet: URL(fileURLWithPath: "/parakeet"), ctc: URL(fileURLWithPath: "/ctc"))
        await settle { ear.state == .ready }
        await settle { ear.trouble == nil && ear.summary == "Parakeet resident" }
        let rebuilds = await engine.rebuilds
        XCTAssertEqual(rebuilds, [[]], "the load ends in one rebuild over the list as it is")
    }

    func testAnEditRebuildsOverTheNewListOnceTheEarIsReady() async {
        let engine = FakeEngine()
        let vocabulary = Vocabulary(defaults: makeDefaults())
        let ear = Ear(vocabulary: vocabulary, engine: engine)
        vocabulary.add("early")
        ear.load(parakeet: URL(fileURLWithPath: "/parakeet"), ctc: URL(fileURLWithPath: "/ctc"))
        await settle { ear.state == .ready }
        vocabulary.add("Daphne")
        await settle { await engine.rebuilds.count == 2 }
        let rebuilds = await engine.rebuilds
        XCTAssertEqual(rebuilds, [["early"], ["early", "Daphne"]])
    }

    func testASessionThatThrowsLeavesTheEarUsable() async throws {
        let engine = FakeEngine()
        await engine.refuse()
        let vocabulary = Vocabulary(defaults: makeDefaults())
        vocabulary.add("Daphne")
        let ear = Ear(vocabulary: vocabulary, engine: engine)
        ear.load(parakeet: URL(fileURLWithPath: "/parakeet"), ctc: URL(fileURLWithPath: "/ctc"))
        await settle { ear.state == .ready && ear.trouble != nil }
        XCTAssertTrue(ear.ready)
        XCTAssertEqual(ear.summary, "Parakeet resident; vocabulary boost unavailable: tokenizer.json not found")
        let heard = try await ear.hear([0, 0, 0])
        XCTAssertEqual(heard, "heard")
    }

    // MARK: ModelStore

    func testTheSpotterIsRehomedRatherThanFetchedAgain() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("topo-rehome-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("Models")
        let home = base.appendingPathComponent("FluidAudio/Models/parakeet-ctc-110m-coreml")
        let old = root.appendingPathComponent(ModelManifest.ctc)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: old.appendingPathComponent(".verified.json"))

        let store = ModelStore(root: root, homes: [ModelManifest.ctc: home])
        store.rehome()

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".verified.json").path))
        let model = ModelManifest.Model(id: ModelManifest.ctc, repo: "x/y", revision: "", files: [])
        XCTAssertEqual(store.directory(for: model), home)
    }
}

/// A count a `@Sendable` closure can bump.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}
