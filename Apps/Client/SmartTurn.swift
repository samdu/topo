#if os(iOS)
import Accelerate
import Foundation
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

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
/// and says whether it sounds finished. An 8 MB int8 Whisper-tiny encoder with a linear head, run
/// by ONNX Runtime on the CPU (the model ships only as ONNX), audio-native, so it never waits on a
/// transcript. Ported from Daphne's `SmartTurn.swift`, which is where what is known about it was
/// learned: the score is not calibrated (the training set had no "ambiguous" class, so it reads as
/// binary: debounced, never threshold-swept); it wants about 1.2 s of trailing quiet in the window
/// before "complete" firms up; gaps inside the window past about 4 s are outside its training
/// data; and "complete" is far more trustworthy than "incomplete" (95% against about 55%
/// precision on real conversations), which is why a hard cap on the quiet still backs it.
///
/// Three things differ from Daphne's, each because Topo's surroundings do:
///
/// - **Off the pool.** The session's `run` and the mel's three `sgemm`s are synchronous CPU work,
///   so neither runs on the cooperative pool or the main actor: `load` and `complete` each run as
///   one block on `queue`, a serial queue of this class's own, and every stored property is
///   touched only there. One serial queue is also what keeps the `ORTSession` used from one
///   thread at a time.
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
    /// The model's one file, as the manifest names it.
    static let file = "smart-turn-v3.2-cpu.onnx"

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
    #if canImport(OnnxRuntimeBindings)
    private var env: ORTEnv?
    private var session: ORTSession?
    #endif
    /// [80][201], pipecat's filterbank exactly.
    private var filterbank: [Float] = []

    /// The judge loaded from the store's directory for `ModelManifest.smartTurn`, with the bundle's
    /// filterbank: `Endpoint`'s loader.
    static func loaded(from directory: URL) async throws -> any TurnJudge {
        guard let filterbank = Bundle.main.url(forResource: "smartturn-mel", withExtension: "bin") else {
            throw Trouble.missing("the mel filterbank")
        }
        let judge = SmartTurn()
        try await judge.load(model: directory.appendingPathComponent(file), filterbank: filterbank)
        return judge
    }

    /// Reads the filterbank and opens the session. Idempotent; tens of milliseconds.
    func load(model: URL, filterbank url: URL) async throws {
        try await onQueue { [self] in
            #if canImport(OnnxRuntimeBindings)
            if session != nil { return }
            guard FileManager.default.fileExists(atPath: model.path) else { throw Trouble.missing("the model") }
            let bank = try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard bank.count == Mel.bins * Mel.freqBins else {
                throw Trouble.runtime("the filterbank is \(bank.count) floats")
            }
            let made = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            try options.setGraphOptimizationLevel(.all)
            session = try ORTSession(env: made, modelPath: model.path, sessionOptions: options)
            env = made
            filterbank = bank
            #else
            throw Trouble.runtime("ONNX Runtime is not linked in this build")
            #endif
        }
    }

    func complete(_ tail: [Float]) async throws -> Float {
        try await onQueue { [self] in
            #if canImport(OnnxRuntimeBindings)
            guard let session else { throw Trouble.runtime("not loaded") }
            var features = Mel.features(Self.window(tail), filterbank: filterbank)
            let data = NSMutableData(bytes: &features, length: features.count * MemoryLayout<Float>.size)
            let input = try ORTValue(tensorData: data, elementType: .float,
                                     shape: [1, NSNumber(value: Mel.bins), NSNumber(value: Mel.frames)])
            let out = try session.run(withInputs: ["input_features": input], outputNames: ["logits"], runOptions: nil)
            guard let logits = out["logits"] else { throw Trouble.runtime("no logits") }
            let bytes = try logits.tensorData() as Data
            guard bytes.count >= MemoryLayout<Float>.size else { throw Trouble.runtime("empty logits") }
            return bytes.withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            #else
            throw Trouble.runtime("ONNX Runtime is not linked in this build")
            #endif
        }
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
