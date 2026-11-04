import AVFoundation
import XCTest

@testable import Topo

/// The judge runs on its own serial queue (`SmartTurn.queue`), never on the main actor or the
/// cooperative pool: the session's `run` and the mel's `sgemm`s are synchronous CPU work.
final class SmartTurnTests: XCTestCase {
    override func tearDown() {
        SmartTurn.onQueue = nil
        super.tearDown()
    }

    @MainActor
    func testTheJudgeAnswersFromItsOwnQueue() async throws {
        let seen = JudgeThreads()
        SmartTurn.onQueue = {
            dispatchPrecondition(condition: .onQueue(SmartTurn.queue))
            seen.add(Thread.isMainThread)
        }
        let judge = SmartTurn()
        do {
            _ = try await judge.complete([Float](repeating: 0, count: 1_600))
            XCTFail("an unloaded judge answered")
        } catch let trouble as SmartTurn.Trouble {
            XCTAssertTrue(trouble.localizedDescription.contains("not loaded"), trouble.localizedDescription)
        }
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-model.onnx")
        do {
            try await judge.load(model: nowhere, filterbank: nowhere)
            XCTFail("a model that is not there loaded")
        } catch {}
        XCTAssertEqual(seen.threads, [false, false], "a block ran somewhere but the judge's queue, or on the main thread")
    }

    func testTheWindowIsTheLastEightSecondsPaddedAtTheFront() {
        let short: [Float] = [1, 2, 3]
        let padded = SmartTurn.window(short)
        XCTAssertEqual(padded.count, SmartTurn.windowSamples)
        XCTAssertEqual(Array(padded.suffix(3)), short)
        XCTAssertTrue(padded.dropLast(3).allSatisfy { $0 == 0 })
        let long = (0..<(SmartTurn.windowSamples + 5)).map(Float.init)
        XCTAssertEqual(SmartTurn.window(long), Array(long.suffix(SmartTurn.windowSamples)))
    }
}

final class JudgeThreads: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    func add(_ main: Bool) { lock.withLock { seen.append(main) } }
    var threads: [Bool] { lock.withLock { seen } }
}

/// Whisper's log-mel front end against pipecat's numpy reference, on a signal both sides write by
/// formula: the fixture is every tenth frame of what `scripts/smartturn-mel.py --fixture` computes
/// from the vendored `whisper_features.py`, and the filterbank is the one the app bundles.
final class MelTests: XCTestCase {
    /// `chirp()` in `scripts/smartturn-mel.py`, sample for sample.
    static func chirp() -> [Float] {
        (0..<SmartTurn.windowSamples).map { n in
            let t = Double(n) / 16_000
            guard t >= 1 else { return 0 }
            let sweep = sin(2 * Double.pi * (100 * t + (4_000 - 100) / (2 * 8) * t * t))
            let level = 0.05 + 0.45 * abs(sin(Double.pi * t / 3))
            return Float(level * sweep)
        }
    }

    static func floats(_ url: URL) throws -> [Float] {
        try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    func testFeaturesMatchPipecatsReference() throws {
        let bank = try XCTUnwrap(Bundle.main.url(forResource: "smartturn-mel", withExtension: "bin"),
                                 "the filterbank is not in the app")
        let filterbank = try Self.floats(bank)
        XCTAssertEqual(filterbank.count, Mel.bins * Mel.freqBins)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/smartturn-mel-chirp.bin")
        let reference = try Self.floats(fixture)
        let kept = Mel.frames / 10
        XCTAssertEqual(reference.count, Mel.bins * kept)
        let features = Mel.features(Self.chirp(), filterbank: filterbank)
        XCTAssertEqual(features.count, Mel.bins * Mel.frames)
        var worst: Float = 0
        for bin in 0..<Mel.bins {
            for j in 0..<kept {
                worst = max(worst, abs(features[bin * Mel.frames + j * 10] - reference[bin * kept + j]))
            }
        }
        // Daphne's measured agreement with the reference on real audio.
        XCTAssertLessThan(worst, 3e-3, "the mel drifted from pipecat's by \(worst)")
        // The signal is not one every front end agrees on: it has silence and tone in it.
        XCTAssertGreaterThan((reference.max() ?? 0) - (reference.min() ?? 0), 1)
    }
}

/// The judge is asked about the last eight seconds, copied alone.
final class SampleSinkTests: XCTestCase {
    func testTailCopiesOnlyTheTail() throws {
        let sink = SampleSink()
        let format = sink.format
        let frames: AVAudioFrameCount = 4_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(i) / Float(frames) }
        sink.append(buffer)
        let all = sink.peek()
        XCTAssertEqual(all.count, Int(frames))
        XCTAssertEqual(sink.tail(1_600), Array(all.suffix(1_600)))
        XCTAssertEqual(sink.tail(1_600).count, 1_600)
        XCTAssertEqual(sink.tail(10_000), all, "a tail longer than the utterance is the utterance")
        XCTAssertEqual(sink.tail(0), [])
        XCTAssertEqual(sink.peek().count, Int(frames), "the tail took samples from the sink")
    }
}

/// The real model through ONNX Runtime on the simulator: the fixture's phrase with a second of
/// quiet after it is complete, and the same phrase cut after "seven" is not. The model comes from
/// a directory `scripts/fetch-ear-models.sh` filled (`TOPO_UITEST_EAR_MODELS`, the full lane's).
final class SmartTurnRealTests: XCTestCase {
    func testTheFixtureIsCompleteAndItsCutIsNot() async throws {
        guard let models = ProcessInfo.processInfo.environment["TOPO_UITEST_EAR_MODELS"], !models.isEmpty else {
            throw XCTSkip("missing coverage: no models directory (TOPO_UITEST_EAR_MODELS), so the real Smart Turn did not judge the fixture")
        }
        let judge = try await SmartTurn.loaded(from: URL(fileURLWithPath: models)
            .appendingPathComponent(ModelManifest.smartTurn))
        let wav = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/purple-elephants.wav")
        let file = try AVAudioFile(forReading: wav)
        XCTAssertEqual(file.processingFormat.sampleRate, Double(Ear.rate))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let phrase = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let quiet = [Float](repeating: 0, count: Ear.rate)
        // "purple elephants juggle seven", where the energy dips before "lanterns".
        let cut = Array(phrase.prefix(Int(2.12 * Double(Ear.rate))))
        let complete = try await judge.complete(phrase + quiet)
        let unfinished = try await judge.complete(cut + quiet)
        print("smart turn: the fixture \(complete), cut after seven \(unfinished)")
        XCTAssertTrue(complete.isFinite && unfinished.isFinite)
        XCTAssertGreaterThan(complete, 0.85, "the whole phrase did not sound finished")
        XCTAssertLessThan(unfinished, 0.85, "the phrase cut after \"seven\" sounded finished")
    }
}
