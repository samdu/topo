#if os(iOS)
import Accelerate
import CoreML
import CryptoKit
import Foundation

/// The judge of whether the speaker of an open microphone has finished, as the conversation asks
/// it (`Endpoint.Judging`): the probability that the utterance whose last samples are `tail`
/// (mono at `Ear.rate`, trailing quiet included) is complete. Smart Turn in the app, a script in
/// the suite.
protocol TurnJudge: AnyObject, Sendable {
    func complete(_ tail: [Float]) async throws -> Float
}

/// Smart Turn v3.2 (Pipecat, BSD-2-Clause, © Daily): did the speaker finish, or pause?
///
/// A silence timeout hears every pause mid-thought as the end of the turn; this model listens to
/// the last eight seconds of the turn itself — intonation, rate, the shape of the trailing off —
/// and says whether it sounds finished. A Whisper-tiny encoder with a linear head, audio-native,
/// so it never waits on a transcript; here as Topo's own Core ML package of pipecat's fp32
/// weights, an FP16 ML Program (`samthehugenerd/Smart-Turn-Topo`, made by `smart-turn-coreml` in
/// samdu/experiments), which scores within 0.05 of pipecat's fp32 model. Ported from Daphne's
/// `SmartTurn.swift`, which is where what is known about it was learned: the score is not
/// calibrated (the training set had no "ambiguous" class, so it reads as binary: debounced, never
/// threshold-swept); it wants about 1.2 s of trailing quiet in the window before "complete" firms
/// up; gaps inside the window past about 4 s are outside its training data; and "complete" is far
/// more trustworthy than "incomplete" (95% against about 55% precision on real conversations),
/// which is why a hard cap on the quiet still backs it.
///
/// Four things differ from Daphne's, each because Topo's surroundings do:
///
/// - **Core ML.** Daphne runs pipecat's int8 ONNX export through ONNX Runtime; the phone runs the
///   FP16 package as Core ML on the CPU and the Neural Engine (`.cpuAndNeuralEngine`: the model
///   runs behind the lock, and iOS ends a background process that submits GPU work). The package
///   is compiled on the phone the first time it is loaded and the compiled model kept in Caches
///   (`compiled(_:in:)`), keyed by the package's bytes, so a new package compiles afresh and a
///   purged cache only costs a compile. A kept compile is loaded only once its own bytes match
///   the digest written beside it after the compile: Core ML crashes, past any `catch`, on a
///   compile missing or damaged in part, so one the system half-purged is compiled again instead.
/// - **Off the pool.** Compiling, loading, the prediction and the mel's three `sgemm`s are
///   synchronous work, so none of it runs on the cooperative pool or the main actor: `load` and
///   `complete` each run as one block on `queue`, a serial queue of this class's own, and every
///   stored property is touched only there.
/// - **Floats in.** The sink already holds mono floats at 16 kHz, so `complete` takes them as they
///   are and `window` zero-pads them; Daphne's round trip through Int16 is not here.
/// - **Model from the store.** The model is a download (`ModelManifest.smartTurn`, fetched with
///   the ear's), not a bundled file; the filterbank (`smartturn-mel.bin`, 64 KB, made again by
///   `scripts/smartturn-mel.py`) is bundled.
final class SmartTurn: TurnJudge, @unchecked Sendable {
    /// Where every load and every verdict runs, one at a time.
    static let queue = DispatchQueue(label: "zone.hexagon.topo.smart-turn", qos: .userInitiated)

    static let windowSeconds = 8
    static let windowSamples = Ear.rate * windowSeconds
    /// The model's package, as the manifest names it.
    static let package = "smart-turn-v3.2-fp16.mlpackage"
    static let input = "input_features"
    static let output = "logits"

    #if DEBUG
    /// Called at the top of every block on `queue`, for the suite to see where it runs.
    nonisolated(unsafe) static var onQueue: (@Sendable () -> Void)?
    #endif

    enum Trouble: LocalizedError {
        case missing(String)
        case runtime(String)
        var errorDescription: String? {
            switch self {
            case .missing(let what): return "smart turn: \(what) is missing"
            case .runtime(let why): return "smart turn: \(why)"
            }
        }
    }

    // Touched only on `queue`.
    private var model: MLModel?
    /// [80][201], pipecat's filterbank exactly.
    private var filterbank: [Float] = []

    /// The judge loaded from the store's directory for `ModelManifest.smartTurn`, with the bundle's
    /// filterbank: `Endpoint`'s loader.
    static func loaded(from directory: URL) async throws -> any TurnJudge {
        guard let filterbank = Bundle.main.url(forResource: "smartturn-mel", withExtension: "bin") else {
            throw Trouble.missing("the mel filterbank")
        }
        let judge = SmartTurn()
        try await judge.load(model: directory.appendingPathComponent(package, isDirectory: true),
                             filterbank: filterbank)
        return judge
    }

    /// Reads the filterbank, compiles the package or takes the compiled copy, loads it and runs
    /// it once on silence, so the first verdict of a conversation does not pay the model's first
    /// run. Idempotent.
    func load(model package: URL, filterbank url: URL, cache: URL = SmartTurn.cache) async throws {
        try await onQueue { [self] in
            if model != nil { return }
            guard FileManager.default.fileExists(atPath: package.path) else { throw Trouble.missing("the model") }
            let bank = try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard bank.count == Mel.bins * Mel.freqBins else {
                throw Trouble.runtime("the filterbank is \(bank.count) floats")
            }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let loaded = try MLModel(contentsOf: Self.compiled(package, in: cache), configuration: configuration)
            filterbank = bank
            _ = try Self.predict(loaded, Mel.features(Self.window([]), filterbank: bank))
            model = loaded
        }
    }

    func complete(_ tail: [Float]) async throws -> Float {
        try await onQueue { [self] in
            guard let model else { throw Trouble.runtime("not loaded") }
            return try Self.predict(model, Mel.features(Self.window(tail), filterbank: filterbank))
        }
    }

    /// Where compiled packages are kept: Caches, which the system may empty, and outside the
    /// model store's root, whose sweep removes whatever the manifest does not list.
    static var cache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("smart-turn", isDirectory: true)
    }

    /// The compiled model for `package`: the one in `cache` named for the package's bytes, if its
    /// own bytes still match the digest kept beside it (`<name>.sha256`), or a fresh compile moved
    /// there with its digest written after it, with everything else in `cache` removed. A compile
    /// with no digest beside it, or one that differs, is never handed to Core ML. On `queue` only.
    static func compiled(_ package: URL, in cache: URL) throws -> URL {
        let fm = FileManager.default
        let name = try digest(package) + ".mlmodelc"
        let kept = cache.appendingPathComponent(name, isDirectory: true)
        let mark = cache.appendingPathComponent(name + ".sha256")
        if let wanted = try? String(contentsOf: mark, encoding: .utf8), (try? digest(kept)) == wanted {
            return kept
        }
        let made = try MLModel.compileModel(at: package)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        for old in (try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: old)
        }
        try fm.moveItem(at: made, to: kept)
        try digest(kept).write(to: mark, atomically: true, encoding: .utf8)
        return kept
    }

    /// The SHA-256 of every file under `folder`, in path order, each path and each file's bytes
    /// preceded by its length, so no two packages share one: the compiled copy's name, and the
    /// check of the compiled copy itself.
    static func digest(_ folder: URL) throws -> String {
        let package = folder
        let root = package.standardizedFileURL.path
        guard let walk = FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw Trouble.missing("the model")
        }
        var files: [(String, URL)] = []
        for case let url as URL in walk where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            files.append((String(url.standardizedFileURL.path.dropFirst(root.count)), url))
        }
        guard !files.isEmpty else { throw Trouble.missing("the model") }
        var hash = SHA256()
        for (path, url) in files.sorted(by: { $0.0 < $1.0 }) {
            let name = Data(path.utf8), bytes = try Data(contentsOf: url, options: .alwaysMapped)
            withUnsafeBytes(of: UInt64(name.count).littleEndian) { hash.update(bufferPointer: $0) }
            hash.update(data: name)
            withUnsafeBytes(of: UInt64(bytes.count).littleEndian) { hash.update(bufferPointer: $0) }
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// One prediction over one window's features, `[1, 80, 800]` float32 in, the probability out.
    private static func predict(_ model: MLModel, _ features: [Float]) throws -> Float {
        let shape: [NSNumber] = [1, NSNumber(value: Mel.bins), NSNumber(value: Mel.frames)]
        let array = try MLMultiArray(shape: shape, dataType: .float32)
        guard features.count == array.count else { throw Trouble.runtime("\(features.count) features") }
        array.withUnsafeMutableBytes { bytes, _ in
            features.withUnsafeBytes { bytes.copyMemory(from: $0) }
        }
        let out = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [input: array]))
        guard let logits = out.featureValue(for: output)?.multiArrayValue, logits.count > 0 else {
            throw Trouble.runtime("no logits")
        }
        return logits[0].floatValue
    }

    /// The last eight seconds, zero-padded at the front so the speech sits at the end of the
    /// window, which is the reference's own framing.
    static func window(_ tail: [Float]) -> [Float] {
        if tail.count >= windowSamples { return Array(tail.suffix(windowSamples)) }
        return [Float](repeating: 0, count: windowSamples - tail.count) + tail
    }

    /// Runs `body` as one block on `queue` and answers what it answers.
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                #if DEBUG
                Self.onQueue?()
                #endif
                continuation.resume(with: Result { try body() })
            }
        }
    }
}

/// Whisper's log-mel front end, as transformers' `WhisperFeatureExtractor` computes it and as
/// pipecat re-implements it in numpy (`scripts/vendor/whisper_features.py`, the reference this is
/// checked against in `MelTests`): n_fft 400, hop 160, periodic Hann, reflect padding, 80 Slaney
/// mels, log10 clamped to 8 under the peak, then (x + 4) / 4. Daphne's, unchanged.
///
/// The 400-point DFT is a matrix product rather than vDSP's FFT: vDSP wants lengths of the form
/// 2ⁿ·{1,3,5,15}, and 400 = 2⁴·25 is not one. Three `sgemm`s over all 800 frames at once (cos,
/// sin, then the filterbank) is a few million flops, nothing beside the encoder. Synchronous, so
/// it is called on `SmartTurn.queue` alone.
enum Mel {
    static let nFFT = 400
    static let hop = 160
    static let bins = 80
    static let freqBins = nFFT / 2 + 1   // 201
    static let frames = SmartTurn.windowSamples / hop   // 800 (the 801st is dropped)

    private static let hann: [Float] = (0..<nFFT).map {
        0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(nFFT))
    }
    /// [nFFT][freqBins] cos and −sin tables, so frames × table = re, im.
    private static let cosTable: [Float] = (0..<nFFT).flatMap { n in
        (0..<freqBins).map { k in cos(2 * .pi * Float(n * k) / Float(nFFT)) }
    }
    private static let sinTable: [Float] = (0..<nFFT).flatMap { n in
        (0..<freqBins).map { k in -sin(2 * .pi * Float(n * k) / Float(nFFT)) }
    }

    /// `samples` is exactly one window. Answers [bins][frames], mel-major, the layout the
    /// model's `input_features` tensor wants.
    static func features(_ samples: [Float], filterbank: [Float]) -> [Float] {
        precondition(samples.count == SmartTurn.windowSamples)
        // Zero mean, unit variance over the whole window, in float32 like the reference
        // (population variance, eps 1e-7).
        var mean: Float = 0
        vDSP_meanv(samples, 1, &mean, vDSP_Length(samples.count))
        var msq: Float = 0
        vDSP_measqv(samples, 1, &msq, vDSP_Length(samples.count))
        let variance = max(msq - mean * mean, 0)
        var scale = 1 / sqrt(variance + 1e-7)
        var shift = -mean * scale
        var x = [Float](repeating: 0, count: samples.count)
        vDSP_vsmsa(samples, 1, &scale, &shift, &x, 1, vDSP_Length(samples.count))

        // Reflect-pad n_fft/2 each side, then hop through the windows.
        let pad = nFFT / 2
        var padded = [Float](repeating: 0, count: x.count + 2 * pad)
        for i in 0..<pad { padded[i] = x[pad - i] }
        padded.replaceSubrange(pad..<(pad + x.count), with: x)
        for i in 0..<pad { padded[pad + x.count + i] = x[x.count - 2 - i] }
        var windowed = [Float](repeating: 0, count: frames * nFFT)
        hann.withUnsafeBufferPointer { w in
            padded.withUnsafeBufferPointer { p in
                windowed.withUnsafeMutableBufferPointer { out in
                    for f in 0..<frames {
                        vDSP_vmul(p.baseAddress! + f * hop, 1, w.baseAddress!, 1,
                                  out.baseAddress! + f * nFFT, 1, vDSP_Length(nFFT))
                    }
                }
            }
        }

        // |rfft|² through the two tables: [frames×nFFT] · [nFFT×freqBins].
        var re = [Float](repeating: 0, count: frames * freqBins)
        var im = [Float](repeating: 0, count: frames * freqBins)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(frames), Int32(freqBins), Int32(nFFT), 1,
                    windowed, Int32(nFFT), cosTable, Int32(freqBins), 0,
                    &re, Int32(freqBins))
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans,
                    Int32(frames), Int32(freqBins), Int32(nFFT), 1,
                    windowed, Int32(nFFT), sinTable, Int32(freqBins), 0,
                    &im, Int32(freqBins))
        var power = [Float](repeating: 0, count: frames * freqBins)
        vDSP_vsq(re, 1, &power, 1, vDSP_Length(power.count))
        vDSP_vma(im, 1, im, 1, power, 1, &power, 1, vDSP_Length(power.count))

        // Mel energies: [frames×freqBins] · [freqBins×bins]. The filterbank is stored
        // [bins][freqBins], so it goes in transposed.
        var melE = [Float](repeating: 0, count: frames * bins)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                    Int32(frames), Int32(bins), Int32(freqBins), 1,
                    power, Int32(freqBins), filterbank, Int32(freqBins), 0,
                    &melE, Int32(bins))
        var floor: Float = 1e-10
        vDSP_vthr(melE, 1, &floor, &melE, 1, vDSP_Length(melE.count))
        var n = Int32(melE.count)
        vvlog10f(&melE, melE, &n)
        var peak: Float = 0
        vDSP_maxv(melE, 1, &peak, vDSP_Length(melE.count))
        var lo = peak - 8
        vDSP_vthr(melE, 1, &lo, &melE, 1, vDSP_Length(melE.count))
        var quarter: Float = 0.25
        var one: Float = 1
        vDSP_vsmsa(melE, 1, &quarter, &one, &melE, 1, vDSP_Length(melE.count))

        // [frames][bins] → [bins][frames].
        var out = [Float](repeating: 0, count: bins * frames)
        vDSP_mtrans(melE, 1, &out, 1, vDSP_Length(bins), vDSP_Length(frames))
        return out
    }
}
#endif
