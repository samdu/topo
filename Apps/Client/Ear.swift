#if os(iOS)
import AVFoundation
import Observation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Speech to text on this phone: Parakeet-tdt-0.6b-v2 through FluidAudio, rescored against the
/// person's own `Vocabulary`, the words the recogniser breaks on. The microphone's audio never
/// leaves the device. The measured reason (Daphne's stt-tune sweep over Sam's own recordings):
/// WER 0.058 against 0.186 for the server recogniser, eighteen of twenty vocabulary words
/// recognised against two, no invented jargon in ordinary speech, and the transcript in about
/// 0.3s with no network in the loop.
///
/// The models are not in the bundle. `ModelDownloads` fetches them through the app's background
/// session (about 540 MB of CoreML: 442 MB for Parakeet, 98 MB for the CTC spotter, listed
/// file by file in the manifest) into the app's Application Support, and FluidAudio loads them
/// from there, told to touch no network of its own. Until they are resident, or if they fail to
/// load, `VoiceInput` uses `SFSpeechRecognizer` instead, so nothing here can leave a press deaf.
///
/// The vocabulary is a layer over that, not a condition of it. Parakeet recognising bare is
/// far better than the fallback, so a boosting session that cannot be built (and none is
/// built for an empty list) leaves the ear ready and says so in `summary`.
///
/// Published state lives on the main actor; recognition itself runs in `EarEngine`, an actor,
/// because a CoreML decode on the main thread is a visible freeze.
@MainActor
@Observable
final class Ear {
    /// `fetching` is the wait for `ModelDownloads` to have every file; `loading` is the CoreML
    /// compile from disk.
    enum State: Equatable { case cold, fetching, loading, ready, failed }

    private(set) var state: State = .cold
    /// Why the ear is not available when it is not, or why the vocabulary is not applied when
    /// the ear is ready without it. Cleared by the next `prepare`, or by the rebuild that works.
    private(set) var trouble: String?
    /// Where the load has got to: a state that just says "loading" for a minute reads as hung.
    private(set) var progress = ""

    /// The manifest entries the ear needs on disk.
    static let models = [ModelManifest.parakeet, ModelManifest.ctc]

    /// Parakeet eats 16 kHz mono, so the microphone is converted to that and nothing else.
    nonisolated static let rate = 16000

    /// The words the recogniser is rescored towards, canonical spellings only, the person's to
    /// edit. Every edit rebuilds the spotter's session, so a word works from the next press.
    let vocabulary: Vocabulary

    /// The rescorer's gate, constant whatever the list holds. No aliases and a similarity gate
    /// of 0.65: the stt-tune sweep (160 configurations over Sam's own recordings) found that
    /// multiword aliases and the default gate were the whole corruption engine ("get some" →
    /// "jetsam"), and that dropping them costs one recall hit while zeroing every invented
    /// word. The rescorer's other knobs stay stock because past this gate they measurably do
    /// nothing. A term shorter than `minTermLength` is ignored by the rescorer, so the store
    /// refuses one.
    nonisolated static let minSimilarity: Float = 0.65
    nonisolated static let minTermLength = 3

    private let engine: any SpeechEngine

    /// Counts the lists handed to the engine, so of two edits in flight the later one is the
    /// session that stands whichever finishes first.
    private var vocabularyVersion = 0

    init(vocabulary: Vocabulary = Vocabulary(), engine: any SpeechEngine = Ear.defaultEngine()) {
        self.vocabulary = vocabulary
        self.engine = engine
        vocabulary.changed = { [weak self] in self?.rebuild() }
    }

    static func defaultEngine() -> any SpeechEngine {
        #if canImport(FluidAudio)
        return EarEngine.shared
        #else
        return NoEngine()
        #endif
    }

    var ready: Bool { state == .ready }

    /// One line for the diagnostics screen.
    var summary: String {
        switch state {
        case .cold: return "not loaded"
        case .fetching: return ModelDownloads.shared.describe(Self.models)
        case .loading: return progress.isEmpty ? "loading" : "loading: \(progress)"
        case .ready: return trouble.map { "Parakeet resident; vocabulary boost unavailable: \($0)" } ?? "Parakeet resident"
        case .failed: return "failed: \(trouble ?? "unknown")"
        }
    }

    /// Asks for the models, downloading whatever this phone lacks, and loads them once every
    /// file is on disk. Idempotent, and called on every foreground so that they are resident by
    /// the first press and a download that failed is tried again; a press that beats the load
    /// uses the fallback.
    func prepare() {
        let downloads = ModelDownloads.shared
        downloads.start(Self.models)
        guard state == .cold || state == .failed else { return }
        state = .fetching
        trouble = nil
        downloads.whenPresent(Self.models) { [weak self] in
            guard let self, self.state == .fetching else { return }
            do {
                self.load(parakeet: try downloads.directory(for: ModelManifest.parakeet),
                          ctc: try downloads.directory(for: ModelManifest.ctc))
            } catch {
                self.state = .failed
                self.trouble = error.localizedDescription
            }
        }
    }

    /// The CoreML compile from the store's directories, then the vocabulary over it. The ear is
    /// ready once the models are; the session is built after, through `rebuild`, whose failure
    /// is `summary`'s to report and not the ear's to fall on.
    func load(parakeet: URL, ctc: URL) {
        state = .loading
        Task {
            do {
                try await engine.load(parakeet: parakeet, ctc: ctc) { [weak self] line in
                    Task { @MainActor in self?.progress = line }
                }
                state = .ready
                progress = ""
                rebuild()
            } catch {
                state = .failed
                trouble = error.localizedDescription
                progress = ""
            }
        }
    }

    /// The spotter's session around the list as it is now: an edit landing, or the load
    /// finishing. Nothing until the models are resident; an edit during the load is read by the
    /// rebuild that follows it. A rebuild that fails leaves the session that was standing and
    /// says so in `summary`; one that works clears that.
    private func rebuild() {
        vocabularyVersion += 1
        let version = vocabularyVersion
        guard state == .ready else { return }
        let terms = vocabulary.terms
        Task {
            do {
                try await engine.rebuild(terms: terms, version: version)
                if vocabularyVersion == version { trouble = nil }
            } catch {
                if vocabularyVersion == version { trouble = error.localizedDescription }
            }
        }
    }

    /// A glance mid-utterance, for the caption: the audio so far, decoded bare. No rescore,
    /// because the caption is provisional by definition and the CTC pass would double the cost
    /// of something thrown away a second later.
    func glance(_ samples: [Float]) async throws -> String {
        try await engine.transcribe(samples, boosted: false)
    }

    /// The whole utterance, decoded and rescored on the vocabulary: what becomes the turn.
    func hear(_ samples: [Float]) async throws -> String {
        try await engine.transcribe(samples, boosted: true)
    }
}

/// The engine as the ear drives it: `EarEngine` in the app, a double in the tests.
protocol SpeechEngine: Sendable {
    /// The models from disk. Throws when they cannot be loaded, which fails the ear.
    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws
    /// The boosting session around `terms`, or none for an empty list. Throws when the session
    /// cannot be built, which leaves the ear ready without it.
    func rebuild(terms: [String], version: Int) async throws
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String
}

/// Stands in where FluidAudio is not linked: every call fails, so `VoiceInput` uses the fallback.
struct NoEngine: SpeechEngine {
    private static let why = "FluidAudio is not linked in this build"
    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
        throw EarError.unavailable(Self.why)
    }
    func rebuild(terms: [String], version: Int) async throws { throw EarError.unavailable(Self.why) }
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String { throw EarError.unavailable(Self.why) }
}

enum EarError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self { case .unavailable(let why): return why }
    }
}

/// The microphone's samples, converted to the ear's format and accumulated under a lock rather
/// than hopped to the main actor: a buffer in flight when the thumb lifts must land here, not
/// after the samples were taken, or the last word of every utterance is clipped.
final class SampleSink: @unchecked Sendable {
    /// The ear's format: mono float at `Ear.rate`.
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Ear.rate),
                               channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?

    /// Takes a buffer in the input's own format and keeps it at the ear's rate. The converter
    /// is built for the first buffer's format and rebuilt if a later one differs.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if converter == nil || converter?.inputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: format)
            }
            guard let converter else { return }
            let ratio = format.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            let frames = Int(out.frameLength)
            guard frames > 0, let channel = out.floatChannelData else { return }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
        }
    }

    /// Everything so far, for a caption glance; the session keeps recording.
    func peek() -> [Float] { lock.withLock { samples } }

    /// Everything so far, emptied: the utterance.
    func take() -> [Float] {
        lock.withLock {
            let out = samples
            samples = []
            return out
        }
    }

    func reset() {
        lock.withLock {
            samples = []
            converter = nil
        }
    }
}

#if canImport(FluidAudio)
/// Parakeet's per-token timings, which the rescore step lines the spotter's evidence up
/// against. Named here so a `Boost` outside this file needs no FluidAudio of its own.
typealias EarTimings = [TokenTiming]

/// The rescore step as the engine calls it: FluidAudio's session in the app, a stub in tests.
protocol Boost: Sendable {
    /// The text with the vocabulary's replacements applied, or nil where none were.
    func rescored(_ text: String, timings: EarTimings, samples: [Float]) async -> String?
}

extension VocabularyBoostingSession: Boost {
    func rescored(_ text: String, timings: EarTimings, samples: [Float]) async -> String? {
        await rescore(text: text, tokenTimings: timings, audioSamples: samples)?.text
    }
}

/// Everything FluidAudio, one instance for the process. Parakeet and the CTC spotter are about
/// 120 MB resident together, and an actor because `transcribe` is a synchronous CoreML forward
/// pass.
actor EarEngine: SpeechEngine {
    static let shared = EarEngine()

    /// v2 explicitly: `AsrModels` defaults to v3, and the multilingual model is a different
    /// recogniser from the one every number was measured on.
    static let version: AsrModelVersion = .v2

    /// The session around a list: FluidAudio's, over the resident spotter, or nil for a list
    /// with nothing in it the spotter could look for.
    typealias Builder = @Sendable ([String]) async throws -> (any Boost)?

    private var asr: AsrManager?
    private var boost: (any Boost)?
    /// Set by `load` over the spotter's models and tokenizer, which stay resident in it so an
    /// edited list is a rebuilt context, not a second trip through the CoreML loads.
    private var builder: Builder?
    /// The version of the list the session holds; an older one arriving late is dropped.
    private var applied = 0

    /// The tests hand in a builder over no models; the app's instance gets its own from `load`.
    init(builder: Builder? = nil) {
        self.builder = builder
    }

    /// Whether a session stands: a rescored `transcribe` differs from a bare one only then.
    var boosted: Bool { boost != nil }

    /// Load from disk, the acoustic model then the spotter. `parakeet` is the directory the
    /// manifest's Parakeet entry fills (named as FluidAudio's loader expects, since it appends
    /// that name to the parent it is given) and `ctc` the spotter's, which is also where
    /// FluidAudio's boosting session will read the tokenizer from (`ModelStore.homes`). The
    /// list is `rebuild`'s.
    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
        if asr != nil && builder != nil { return }
        // Every file is the manifest's and verified; a load that fails is reported, and never
        // answered by FluidAudio deleting the directory and fetching afresh over a session of
        // its own.
        ModelHub.offlineMode = true
        let models = try await AsrModels.load(from: parakeet, version: Self.version) { p in
            if case .compiling(let name) = p.phase { onProgress("Parakeet: compiling \(name)") }
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager

        onProgress("compiling the CTC spotter")
        let ctcModels = try await CtcModels.loadDirect(from: ctc, variant: .ctc110m)
        let tokenizer = try await CtcTokenizer.load(from: ctc)
        builder = { terms in
            let vterms = terms.compactMap { term -> CustomVocabularyTerm? in
                let ids = tokenizer.encode(term)
                guard !ids.isEmpty else { return nil }
                return CustomVocabularyTerm(text: term, aliases: nil, ctcTokenIds: ids)
            }
            guard !vterms.isEmpty else { return nil }
            let context = CustomVocabularyContext(terms: vterms, minSimilarity: Ear.minSimilarity,
                                                  minTermLength: Ear.minTermLength)
            return try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels, config: .init())
        }
    }

    /// The session around a fresh list. Cheap against the loads above: tokenisation and a new
    /// context. Nothing until the spotter is resident, and a list older than the one applied
    /// is dropped, so two edits in flight end on the later one. An empty list is no session at
    /// all, so removing the last term removes the boost: a rescorer over nothing is pure cost.
    func rebuild(terms: [String], version: Int) async throws {
        guard let builder, version > applied else { return }
        let session: (any Boost)?
        if terms.isEmpty {
            session = nil
        } else {
            session = try await builder(terms)
        }
        guard version > applied else { return }
        applied = version
        boost = session
    }

    /// One utterance. A fresh decoder state per call: every session, and every caption glance,
    /// is its own utterance, and LSTM state carried across them would let one borrow context
    /// no real utterance gets.
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String {
        guard let asr else { throw EarError.unavailable("Parakeet is not loaded") }
        let layers = await asr.decoderLayerCount
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await asr.transcribe(samples, decoderState: &state)
        var text = result.text
        if boosted, let boost {
            if let rescored = await boost.rescored(text, timings: result.tokenTimings ?? [], samples: samples) {
                text = rescored
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
#endif
