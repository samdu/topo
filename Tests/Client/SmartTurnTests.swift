import AVFoundation
import XCTest

@testable import Topo

/// The judge runs on its own serial queue (`SmartTurn.queue`), never on the main actor or the
/// cooperative pool: the compile, the prediction and the mel's `sgemm`s are synchronous work.
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
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-model.mlpackage")
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

    /// The compiled copy is named for every byte and every path of the package, so a new package
    /// is never answered by an old compile.
    func testThePackagesDigestChangesWithAnyByteOrPath() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent("digest-\(UUID().uuidString).mlpackage", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let weights = package.appendingPathComponent("Data/com.apple.CoreML/weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("manifest".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        try Data([1, 2, 3]).write(to: weights.appendingPathComponent("weight.bin"))
        let first = try SmartTurn.digest(package)
        XCTAssertEqual(try SmartTurn.digest(package), first, "the digest is not a function of the package")
        XCTAssertEqual(first.count, 64)
        try Data([1, 2, 4]).write(to: weights.appendingPathComponent("weight.bin"))
        let byte = try SmartTurn.digest(package)
        XCTAssertNotEqual(byte, first, "a changed weight kept the old compile's name")
        try FileManager.default.moveItem(at: weights.appendingPathComponent("weight.bin"),
                                         to: weights.appendingPathComponent("weight2.bin"))
        XCTAssertNotEqual(try SmartTurn.digest(package), byte, "a renamed file kept the old compile's name")
        let empty = package.deletingLastPathComponent().appendingPathComponent("empty-\(UUID().uuidString).mlpackage")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertThrowsError(try SmartTurn.digest(empty), "an empty package was given a name")
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

/// The real model through Core ML on the simulator: it compiles from the store's layout into a
/// cache of its own, named for the package, loads again from that compile, and judges the
/// fixture's phrase with a second of quiet after it complete, and the phrase cut after "seven"
/// ("purple elephants juggle seven") with no quiet after it unfinished; with a second of quiet
/// the cut scores as complete too (0.99 when measured), the model saturating on digital silence. The model comes from a directory `scripts/fetch-ear-models.sh`
/// filled (`TOPO_UNIT_EAR_MODELS`, on the full lane).
final class SmartTurnRealTests: XCTestCase {
    func testTheRealModelLoadsAndJudgesTheFixtureComplete() async throws {
        guard let models = ProcessInfo.processInfo.environment["TOPO_UNIT_EAR_MODELS"], !models.isEmpty else {
            throw XCTSkip("missing coverage: no models directory (TOPO_UNIT_EAR_MODELS), so the real Smart Turn did not judge the fixture")
        }
        let package = URL(fileURLWithPath: models).appendingPathComponent(ModelManifest.smartTurn)
            .appendingPathComponent(SmartTurn.package, isDirectory: true)
        let filterbank = try XCTUnwrap(Bundle.main.url(forResource: "smartturn-mel", withExtension: "bin"))
        let cache = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-turn-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        try await SmartTurn().load(model: package, filterbank: filterbank, cache: cache)
        let fm = FileManager.default
        let name = try SmartTurn.digest(package) + ".mlmodelc"
        let compiled = try fm.contentsOfDirectory(atPath: cache.path).sorted()
        XCTAssertEqual(compiled, [name, name + ".sha256"], "the compile is not kept under the package's name with its digest")
        let kept = cache.appendingPathComponent(name)
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent(name + ".sha256"), encoding: .utf8),
                       try SmartTurn.digest(kept), "the digest beside the compile is not the compile's")
        let data = kept.appendingPathComponent("coremldata.bin").path
        func inode() throws -> Int { try XCTUnwrap(fm.attributesOfItem(atPath: data)[.systemFileNumber] as? Int) }
        let made = try inode()
        let judge = SmartTurn()
        try await judge.load(model: package, filterbank: filterbank, cache: cache)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: cache.path).sorted(), compiled)
        XCTAssertEqual(try inode(), made, "a second load compiled again")
        // A compile damaged in part — a weight file cut short, as a partial purge leaves one — is
        // compiled again, never handed to Core ML, which crashes on it.
        let weights = try XCTUnwrap(fm.enumerator(at: kept, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.first { $0.lastPathComponent == "weight.bin" })
        let damaged = try FileHandle(forWritingTo: weights)
        try damaged.truncate(atOffset: 1 << 20)
        try damaged.close()
        try await SmartTurn().load(model: package, filterbank: filterbank, cache: cache)
        XCTAssertNotEqual(try inode(), made, "a damaged compile was loaded rather than compiled again")
        XCTAssertEqual(try String(contentsOf: cache.appendingPathComponent(name + ".sha256"), encoding: .utf8),
                       try SmartTurn.digest(kept))
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
        // Cut with no quiet after it, the model hears a speaker mid-clause (0.02 when measured).
        let unfinished = try await judge.complete(cut)
        print("smart turn: the fixture \(complete), cut after seven \(unfinished)")
        XCTAssertTrue(complete.isFinite && unfinished.isFinite)
        XCTAssertGreaterThan(complete, 0.85, "the whole phrase did not sound finished")
        XCTAssertLessThan(unfinished, 0.5, "the phrase cut after \"seven\", with no quiet after it, sounded finished")
    }
}
