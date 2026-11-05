import XCTest

@testable import Topo

/// Topo's policy over the detector's events (`Endpoint.Policy`): an end with no start ends
/// nothing, a start shorter than `minSpeech` before its end is a cough, and an utterance that has
/// held speech ends at the next end.
final class EndpointTests: XCTestCase {
    private let quarter = Int(Endpoint.minSpeech * Double(Ear.rate))

    func testAnEndWithNoStartEndsNothing() {
        var policy = Endpoint.Policy()
        XCTAssertNil(policy.take(.end(8_000)))
        XCTAssertFalse(policy.speaking)
    }

    func testSpeechAsLongAsTheMinimumIsAnUtterance() {
        var policy = Endpoint.Policy()
        XCTAssertEqual(policy.take(.start(100)), .speech)
        XCTAssertTrue(policy.speaking)
        XCTAssertEqual(policy.take(.end(100 + quarter)), .ended)
    }

    func testACoughIsNotAnUtteranceButSpeechAfterItIs() {
        var policy = Endpoint.Policy()
        XCTAssertEqual(policy.take(.start(0)), .speech)
        XCTAssertNil(policy.take(.end(quarter - 1)), "a cough ended the utterance")
        XCTAssertFalse(policy.speaking, "a cough counted as speech")
        XCTAssertEqual(policy.take(.start(20_000)), .speech)
        XCTAssertEqual(policy.take(.end(20_000 + quarter * 4)), .ended)
    }

    /// The promised numbers as literals, so a change to any of them is a change to this test.
    /// FluidAudio's segmentation itself needs Silero's model, which the unit suite does not
    /// load: that a 1.5 s pause does not split a sentence is the device check's.
    func testTheSilenceWindowSitsPastTheTwoSecondsThatCutSpeakersOff() {
        XCTAssertEqual(Endpoint.silence, 2.1)
        XCTAssertEqual(Endpoint.minSpeech, 0.25)
        XCTAssertEqual(Endpoint.chunk, 4_096)
        #if canImport(FluidAudio)
        XCTAssertEqual(SileroDetector.silenceWindow, 2.1, "the detector segments on a window other than the promised one")
        #endif
    }

    func testAQuarterSecondAtTheEarsRateIsFourThousandSamples() {
        var policy = Endpoint.Policy()
        XCTAssertEqual(policy.take(.start(0)), .speech)
        XCTAssertNil(policy.take(.end(3_999)), "under a quarter second ended an utterance")
        XCTAssertEqual(policy.take(.start(10_000)), .speech)
        XCTAssertEqual(policy.take(.end(14_000)), .ended, "a quarter second was not an utterance")
    }
}

#if canImport(FluidAudio)
/// The detector as the app loads it: Silero's real model, fetched by the suite from the manifest's
/// pinned revision (`scripts/fetch-ear-models.sh`), laid where the app's own store keeps it
/// (`ModelStore.standard(support:)`, `directory(for:)`), and loaded by `Endpoint.silero`, the
/// loader `Endpoint.prepare` runs. `Endpoint(detector:)`, which the conversation's suite uses,
/// passes over all three.
final class SileroLoadTests: XCTestCase {
    private var support: URL!

    override func setUpWithError() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("topo-silero-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: support)
    }

    private func vad() throws -> ModelManifest.Model {
        try XCTUnwrap(ModelManifest.bundled().models.first { $0.id == ModelManifest.vad })
    }

    func testTheDetectorLoadsFromWhereTheStoreKeepsIt() async throws {
        let fetched = try XCTUnwrap(
            ProcessInfo.processInfo.environment["TOPO_UNIT_EAR_MODELS"].flatMap { $0.isEmpty ? nil : $0 },
            "Silero's model in TEST_RUNNER_TOPO_UNIT_EAR_MODELS")
        let model = try vad()
        let store = ModelStore.standard(support: support)
        let directory = store.directory(for: model)
        let source = URL(fileURLWithPath: fetched).appendingPathComponent(ModelManifest.vad)
        for file in model.files {
            let to = directory.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.appendingPathComponent(file.path), to: to)
        }

        let detector = try await Endpoint.silero(directory)
        let quiet = [Float](repeating: 0, count: Endpoint.chunk)
        for _ in 0..<4 {
            let event = try await detector.feed(quiet)
            XCTAssertNil(event, "silence began or ended an utterance")
        }
    }

    /// With nothing where the store keeps the model, the load fails rather than fetching the
    /// model over a session of FluidAudio's own.
    func testADetectorNotInTheStoreIsAFailureAndNotAFetch() async throws {
        let directory = ModelStore.standard(support: support).directory(for: try vad())
        do {
            _ = try await Endpoint.silero(directory)
            XCTFail("loaded a detector the store does not have")
        } catch {}
        let models = support.appendingPathComponent("Models")
        let left = (try? FileManager.default.subpathsOfDirectory(atPath: models.path)) ?? []
        XCTAssertFalse(left.contains { $0.hasSuffix(".mlmodelc") }, "fetched \(left)")
    }
}
#endif
