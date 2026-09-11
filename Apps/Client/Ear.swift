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
/// The models are not in the bundle. FluidAudio downloads them from Hugging Face into the
/// app's Application Support the first time `prepare` runs (about 540 MB of CoreML: 443 MB
/// for Parakeet, 98 MB for the CTC spotter) and loads them from there on every launch after.
/// Until they are resident, or if they fail to load, `VoiceInput` uses `SFSpeechRecognizer`
/// instead, so nothing here can leave a press deaf.
///
/// Published state lives on the main actor; recognition itself runs in `EarEngine`, an actor,
/// because a CoreML decode on the main thread is a visible freeze.
@MainActor
@Observable
final class Ear {
    enum State: Equatable { case cold, loading, ready, failed }

    private(set) var state: State = .cold
    /// Why the ear is not available, when it is not. Cleared by the next `prepare`.
    private(set) var trouble: String?
    /// Where the load has got to. The first run pulls half a gigabyte, and a state that just
    /// says "loading" for minutes reads as hung.
    private(set) var progress = ""

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

    /// Counts the lists handed to the engine, so of two edits in flight the later one is the
    /// session that stands whichever finishes first.
    private var vocabularyVersion = 0

    init(vocabulary: Vocabulary = Vocabulary()) {
        self.vocabulary = vocabulary
        vocabulary.changed = { [weak self] in self?.rebuild() }
    }

    var ready: Bool { state == .ready }

    /// One line for the diagnostics screen.
    var summary: String {
        switch state {
        case .cold: return "not loaded"
        case .loading: return progress.isEmpty ? "loading" : "loading: \(progress)"
        case .ready: return trouble.map { "Parakeet resident; vocabulary not applied: \($0)" } ?? "Parakeet resident"
        case .failed: return "failed: \(trouble ?? "unknown")"
        }
    }

    /// Starts the models loading, downloading them first if this phone has never had them.
    /// Idempotent, and called on every foreground so that they are resident by the first
    /// press; a press that beats the load uses the fallback.
    func prepare() {
        #if canImport(FluidAudio)
        guard state == .cold || state == .failed else { return }
        state = .loading
        trouble = nil
        vocabularyVersion += 1
        let version = vocabularyVersion
        Task {
            do {
                try await EarEngine.shared.load(terms: vocabulary.terms, version: version) { [weak self] line in
                    Task { @MainActor in self?.progress = line }
                }
                state = .ready
                progress = ""
                // An edit that landed during the load was refused by the engine, whose session
                // did not exist yet; it is applied now.
                if vocabularyVersion != version { rebuild() }
            } catch {
                state = .failed
                trouble = error.localizedDescription
                progress = ""
            }
        }
        #else
        state = .failed
        trouble = "FluidAudio is not linked in this build"
        #endif
    }

    /// The spotter's session around the list as it is now: an edit landing. Nothing until the
    /// models are resident; a load in flight reads the list when it finishes. A rebuild that
    /// fails leaves the session that was standing and says so in `summary`.
    private func rebuild() {
        #if canImport(FluidAudio)
        vocabularyVersion += 1
        let version = vocabularyVersion
        guard state == .ready else { return }
        let terms = vocabulary.terms
        Task {
            do {
                try await EarEngine.shared.rebuild(terms: terms, version: version)
                if vocabularyVersion == version { trouble = nil }
            } catch {
                if vocabularyVersion == version { trouble = error.localizedDescription }
            }
        }
        #endif
    }

    /// A glance mid-utterance, for the caption: the audio so far, decoded bare. No rescore,
    /// because the caption is provisional by definition and the CTC pass would double the cost
    /// of something thrown away a second later.
    func glance(_ samples: [Float]) async throws -> String {
        #if canImport(FluidAudio)
        return try await EarEngine.shared.transcribe(samples, boosted: false)
        #else
        throw EarError.unavailable("FluidAudio is not linked in this build")
        #endif
    }

    /// The whole utterance, decoded and rescored on the vocabulary: what becomes the turn.
    func hear(_ samples: [Float]) async throws -> String {
        #if canImport(FluidAudio)
        return try await EarEngine.shared.transcribe(samples, boosted: true)
        #else
        throw EarError.unavailable("FluidAudio is not linked in this build")
        #endif
    }
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
/// Everything FluidAudio, one instance for the process. Parakeet and the CTC spotter are about
/// 120 MB resident together, and an actor because `transcribe` is a synchronous CoreML forward
/// pass.
actor EarEngine {
    static let shared = EarEngine()

    /// v2 explicitly: `AsrModels` defaults to v3, and the multilingual model is a different
    /// recogniser from the one every number was measured on.
    static let version: AsrModelVersion = .v2

    private var asr: AsrManager?
    private var boost: VocabularyBoostingSession?
    /// Kept resident so an edited list is a rebuilt context, not a second trip through the
    /// CoreML loads.
    private var ctcModels: CtcModels?
    private var tokenizer: CtcTokenizer?
    /// The version of the list the session holds; an older one arriving late is dropped.
    private var applied = 0

    /// Download (first run only) and load, the acoustic model then the spotter, then the
    /// vocabulary tokenised against it. The gate is constant; the list is the caller's, and
    /// `rebuild` swaps it live.
    func load(terms: [String], version: Int, onProgress: @escaping @Sendable (String) -> Void) async throws {
        if asr != nil && boost != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: Self.version) { p in
            switch p.phase {
            case .listing:
                onProgress("Parakeet: listing files")
            case .downloading(let done, let total):
                onProgress(String(format: "Parakeet: downloading %d/%d, %.0f%%", done, total, p.fractionCompleted * 100))
            case .compiling(let name):
                onProgress("Parakeet: compiling \(name)")
            }
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager

        onProgress("fetching the CTC spotter")
        ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        try await rebuild(terms: terms, version: version)
    }

    /// The session around a fresh list. Cheap against the loads above: tokenisation and a new
    /// context. Nothing until the spotter is resident, and a list older than the one applied
    /// is dropped, so two edits in flight end on the later one.
    func rebuild(terms: [String], version: Int) async throws {
        guard let ctcModels, let tokenizer, version > applied else { return }
        let vterms = terms.compactMap { term -> CustomVocabularyTerm? in
            let ids = tokenizer.encode(term)
            guard !ids.isEmpty else { return nil }
            return CustomVocabularyTerm(text: term, aliases: nil, ctcTokenIds: ids)
        }
        let context = CustomVocabularyContext(terms: vterms, minSimilarity: Ear.minSimilarity,
                                              minTermLength: Ear.minTermLength)
        let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels, config: .init())
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
            let rescored = await boost.rescore(text: text, tokenTimings: result.tokenTimings ?? [],
                                               audioSamples: samples)
            if let rescored { text = rescored.text }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
#endif
#endif
