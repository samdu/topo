#if os(iOS)
import TopoCore
import AVFoundation
import Observation
#if canImport(FluidAudio)
import FluidAudio
#endif

private let log = TopoLog(.models)

/// Speech to text on this phone: Parakeet Ultra (moondream's post-training of parakeet-tdt-0.6b-v3)
/// through FluidAudio, rescored against the person's own `Vocabulary`, the words the recogniser
/// breaks on. The microphone's audio never leaves the device. Daphne chose it on Sam's own
/// recordings, through the same path, booster and gates (samdu/daphne-assistant#205): boosted WER
/// 0.027 against v2's 0.059, seventeen of twenty vocabulary words against eighteen, and no invented
/// jargon from either — measured on FluidAudio 0.17.7's decode path, which 0.18.2's long-form
/// path has changed since.
///
/// The model is a bundle (`BundleStore`, `parakeet-ultra`, 632 MB of CoreML), copied and
/// checked into `Application Support/Ear` from whichever source the build has: the Apple-hosted
/// pack, the app's own resources (an install-page build) or a folder a debug launch names. The
/// CTC spotter the vocabulary is rescored with (98 MB) is a download of `ModelDownloads`'s, into
/// FluidAudio's own cache, where its boosting session reads the tokenizer; it is not a condition of
/// the ear. Ultra recognising bare is still the ear, so the ear is ready once Ultra is resident,
/// and the boost joins it when the spotter has arrived and compiled, without a press waiting on it.
/// Until Ultra is resident, or if it fails to load, `VoiceInput` refuses a press with `summary`:
/// this is the phone's one ear.
///
/// A phone whose earlier build downloaded Parakeet v2 hears with v2 while Ultra's copy is not yet
/// in its store (an update's first launch fetches a TestFlight build's pack), and the copy is made
/// beside it; the launch after, the ear is Ultra and v2's folder is removed. Nothing downloads v2.
///
/// Published state lives on the main actor; recognition itself runs in `EarEngine`, an actor,
/// because a CoreML decode on the main thread is a visible freeze.
@MainActor
@Observable
final class Ear {
    /// `fetching` is the store making Ultra's copy — a pack's download first where the system has
    /// not finished it; `loading` is the CoreML compile from disk, which after an install is the
    /// Neural Engine compiling the model for this phone, and takes its time.
    enum State: Equatable { case cold, fetching, loading, ready, failed }

    private(set) var state: State = .cold
    /// Why the ear is not available when it is not, or why the vocabulary is not applied when
    /// the ear is ready without it. Cleared by the next `prepare`, or by the rebuild that works.
    private(set) var trouble: String?
    /// Where the load has got to: a state that says only that it is preparing for a minute reads as hung.
    private(set) var progress = ""
    /// The acoustic model resident or compiling, nil before a load.
    private(set) var model: EarModel?
    /// How far a pack's download has come, while the store waits on one.
    private(set) var fraction: Double?
    /// Whether the store has begun a copy, rather than still finding its copy whole.
    private(set) var copyingNow = false
    /// Whether the spotter is resident, and with it the boost the vocabulary rides.
    private(set) var spotterResident = false

    /// The manifest entries the ear downloads: the spotter alone. Parakeet v2's entry stays in the
    /// manifest so a phone's earlier download of it is kept until Ultra replaces it, and is never
    /// asked for.
    static let models = [ModelManifest.ctc]

    /// What `loading` reads as: the step a first load after an install spends its time in.
    static let preparing = "preparing the models for this phone"
    /// What the line says while the store finds its copy whole, which every launch does and draws
    /// no meter for (`Setup.launchWords`).
    nonisolated static let checking = "checking Topo's ear"
    nonisolated static let downloading = "downloading Topo's ear"
    nonisolated static let copying = "copying Topo's ear"

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
    /// nothing, except the one FluidAudio added since the sweep and turned on by default: the
    /// confident-word bias gate (`confidentWordBiasGate`), which takes the context bonus off a
    /// term where Parakeet heard every word at 0.99 or better and the term is under 0.80
    /// similar, so fewer replacements happen. It is off here (`VocabularyRescorer.Config` at
    /// the session), because the sweep measured the rescorer without it and nothing has
    /// measured it since. A term shorter than `minTermLength` is ignored by the rescorer, so
    /// the store refuses one. The booster rescores on the spotter's own tokenizer, so it is the
    /// same over Ultra as over v2.
    nonisolated static let minSimilarity: Float = 0.65
    nonisolated static let minTermLength = 3

    private let engine: any SpeechEngine
    private let downloads: ModelDownloads
    private let store: BundleStore
    private let source: any BundleSource
    /// Whether this launch's copy of Ultra beside a resident v2 is under way, so a foreground
    /// asks for one only.
    private var copyingBeside = false
    /// Whether the spotter's compile has been asked for, so it is asked for once.
    private var spotterAsked = false
    /// Whether `prepare` has made this ear, so a foreground carries on its spotter's download.
    private var prepared = false

    /// Counts the lists handed to the engine, so of two edits in flight the later one is the
    /// session that stands whichever finishes first.
    private var vocabularyVersion = 0

    init(vocabulary: Vocabulary = Vocabulary(), engine: any SpeechEngine = Ear.defaultEngine(),
         store: BundleStore = .ear(), source: (any BundleSource)? = nil, downloads: ModelDownloads = .shared) {
        self.vocabulary = vocabulary
        self.engine = engine
        self.downloads = downloads
        self.store = store
        self.source = source ?? FolderSource.embedded(BundleStore.earName)
            ?? AssetPackSource(id: BundleStore.earName, noun: "ear")
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

    /// What the line says while the state is `fetching`.
    var fetchWords: String {
        if let fraction { return "\(Self.downloading) (\(Int((fraction * 100).rounded()))%)" }
        return copyingNow ? Self.copying : Self.checking
    }

    /// One line for the diagnostics screen.
    var summary: String {
        switch state {
        case .cold: return "not loaded"
        case .fetching: return fetchWords
        case .loading: return progress.isEmpty ? Self.preparing : "\(Self.preparing): \(progress)"
        case .ready:
            let name = model?.name ?? "Parakeet"
            if let trouble { return "\(name) resident; vocabulary boost unavailable: \(trouble)" }
            if !spotterResident { return "\(name) resident; vocabulary boost waiting for its spotter (\(downloads.describe(Self.models)))" }
            return "\(name) resident"
        case .failed: return "failed: \(trouble ?? "unknown")"
        }
    }

    /// Makes the ear resident: Ultra from its store, made from this build's source where the store
    /// does not hold it whole, or, on a phone with Parakeet v2 on disk and no whole copy of Ultra
    /// yet, v2 at once while Ultra's copy is made beside it for the next launch. Asks for the
    /// spotter too, whose arrival joins the boost to a resident ear. Idempotent, and called on every
    /// foreground so that the ear is resident by the first press and a copy, a download or a load
    /// that failed is tried again; a press that beats the load is refused with `summary`.
    func prepare() {
        // An ear a debug launch loaded itself (`load`, never `prepare`) asks for no spotter.
        if prepared {
            askForSpotter()
            if state == .ready { loadSpotterIfDue() }
        }
        guard state == .cold || state == .failed else { return }
        prepared = true
        askForSpotter()
        trouble = nil
        if !(store.installed() != nil && store.isWhole()), downloads.present.contains(ModelManifest.parakeet),
           let v2 = try? downloads.directory(for: ModelManifest.parakeet) {
            load(acoustic: v2, model: .v2)
            copyBeside()
            return
        }
        state = .fetching
        fraction = nil
        copyingNow = false
        install { [weak self] result in
            guard let self, self.state == .fetching else { return }
            switch result {
            case .success(let home):
                self.load(acoustic: home, model: .ultra)
            case .failure(let error):
                log.error("ear: Ultra's copy was not made: \(String(describing: error))")
                self.state = .failed
                self.trouble = error.localizedDescription
                self.settled?()
            }
        }
    }

    /// The store's copy from this build's source, its progress drawn while the ear is fetching.
    private func install(_ done: @escaping @MainActor (Result<URL, Error>) -> Void) {
        let store = store, source = source
        Task {
            do {
                let home = try await store.install(from: source, progress: { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.state == .fetching, !self.copyingNow else { return }
                        self.fraction = fraction
                    }
                }, copying: {
                    Task { @MainActor [weak self] in
                        guard let self, self.state == .fetching else { return }
                        self.fraction = nil
                        self.copyingNow = true
                    }
                })
                done(.success(home))
            } catch {
                done(.failure(error))
            }
        }
    }

    /// Ultra's copy made while v2 is the ear, for the next launch to take; never loaded beside v2.
    private func copyBeside() {
        guard !copyingBeside else { return }
        copyingBeside = true
        install { [weak self] result in
            if case .failure(let error) = result {
                log.error("ear: Ultra's copy beside v2 was not made, tried again at the next launch: \(String(describing: error))")
                self?.copyingBeside = false
            } else {
                log.notice("ear: Ultra's copy is in, and the ear is Ultra from the next launch")
            }
        }
    }

    /// The spotter: asked for once, and compiled once its files are on disk and the acoustic model
    /// is resident, so the two compiles are never shared.
    private func askForSpotter() {
        downloads.start(Self.models)
        guard !spotterAsked else { return }
        spotterAsked = true
        downloads.whenPresent(Self.models) { [weak self] in
            guard let self, let ctc = try? self.downloads.directory(for: ModelManifest.ctc) else { return }
            self.spotterDirectory = ctc
            self.loadSpotterIfDue()
        }
    }

    /// The spotter's directory once its files are on disk.
    private var spotterDirectory: URL?
    /// Whether the spotter's compile has begun.
    private var spotterLoading = false

    private func loadSpotterIfDue() {
        guard state == .ready, let ctc = spotterDirectory, !spotterLoading, !spotterResident else { return }
        spotterLoading = true
        Task {
            do {
                try await engine.loadSpotter(ctc) { [weak self] line in
                    Task { @MainActor in self?.note(line) }
                }
                spotterResident = true
                rebuild()
            } catch {
                trouble = error.localizedDescription
                log.error("ear: the spotter did not load, so the vocabulary is not applied: \(String(describing: error))")
            }
            spotterLoading = false
        }
    }

    private func note(_ line: String) { log.info("ear: \(line)") }

    /// Removes v2's download once Ultra is the resident ear, so the phone keeps one acoustic model.
    private func retireV2() {
        guard model == .ultra, let v2 = try? downloads.directory(for: ModelManifest.parakeet),
              FileManager.default.fileExists(atPath: v2.path) else { return }
        do {
            try FileManager.default.removeItem(at: v2)
            log.notice("ear: Parakeet v2 removed, Ultra is resident")
        } catch {
            log.error("ear: Parakeet v2 was not removed, tried again at the next launch: \(String(describing: error))")
        }
    }

    /// Called when a compile of the acoustic model ends, resident or failed, and when Ultra's
    /// copy fails: the voice's compile waits on it.
    var settled: (@MainActor () -> Void)?

    /// The CoreML compile of the acoustic model from `acoustic`, then the spotter's where `spotter`
    /// names one (a debug launch's folder) or the download has brought it. The ear is ready once the
    /// acoustic model is; the session is built after, through `rebuild`, whose failure is
    /// `summary`'s to report and not the ear's to fall on.
    func load(acoustic: URL, model: EarModel = .ultra, spotter: URL? = nil) {
        state = .loading
        self.model = model
        if let spotter { spotterDirectory = spotter }
        Perf.mark("ear.load.begin")
        Task {
            do {
                try await engine.load(acoustic: acoustic, model: model) { [weak self] line in
                    Task { @MainActor in self?.progress = line }
                }
                Perf.mark("ear.load.end")
                log.notice("ear: \(model.name) resident")
                state = .ready
                progress = ""
                retireV2()
                settled?()
                loadSpotterIfDue()
            } catch {
                progress = ""
                log.error("ear: \(model.name) did not load from \(acoustic.lastPathComponent): \(String(describing: error))")
                // Ultra that will not load on a phone that still has v2 hears with v2, which stays
                // until Ultra is resident; the next launch tries Ultra again.
                if model == .ultra, downloads.present.contains(ModelManifest.parakeet),
                   let v2 = try? downloads.directory(for: ModelManifest.parakeet) {
                    log.error("ear: Ultra did not load, so the ear is v2 for this launch: \(String(describing: error))")
                    load(acoustic: v2, model: .v2)
                    return
                }
                state = .failed
                trouble = error.localizedDescription
                settled?()
            }
        }
    }

    /// The spotter's session around the list as it is now: an edit landing, or the spotter's
    /// load finishing. Nothing until the acoustic model and the spotter are both resident; an edit
    /// before then is read by the rebuild the spotter's load ends in. A rebuild that fails leaves the session that was standing and
    /// says so in `summary`; one that works clears that.
    private func rebuild() {
        vocabularyVersion += 1
        let version = vocabularyVersion
        guard state == .ready, spotterResident else { return }
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

/// The acoustic models the ear runs: Ultra, and v2 on a phone that downloaded it before Ultra's
/// copy was in.
enum EarModel: Sendable, Equatable {
    case ultra, v2

    var name: String {
        switch self {
        case .ultra: "Parakeet Ultra"
        case .v2: "Parakeet v2"
        }
    }
}

/// The engine as the ear drives it: `EarEngine` in the app, a double in the tests.
protocol SpeechEngine: Sendable {
    /// The acoustic model from disk. Throws when it cannot be loaded, which fails the ear.
    func load(acoustic: URL, model: EarModel, onProgress: @escaping @Sendable (String) -> Void) async throws
    /// The spotter from disk. Throws when it cannot be loaded, which leaves the ear ready
    /// without the vocabulary.
    func loadSpotter(_ ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws
    /// The boosting session around `terms`, or none for an empty list. Throws when the session
    /// cannot be built, which leaves the ear ready without it.
    func rebuild(terms: [String], version: Int) async throws
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String
}

extension SpeechEngine {
    /// A double with no spotter loads one by doing nothing.
    func loadSpotter(_ ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {}
}

/// Stands in where FluidAudio is not linked: every call fails, so the ear never becomes ready
/// and `VoiceInput` refuses every press.
struct NoEngine: SpeechEngine {
    private static let why = "FluidAudio is not linked in this build"
    func load(acoustic: URL, model: EarModel, onProgress: @escaping @Sendable (String) -> Void) async throws {
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
    func peek() -> [Float] { lock.withLock { copy(samples[...]) } }

    #if DEBUG
    /// How many samples the sink has copied out, for the suite: the tail's bound is a count.
    private(set) var copied = 0
    #endif

    private func copy(_ slice: ArraySlice<Float>) -> [Float] {
        #if DEBUG
        copied += slice.count
        #endif
        return Array(slice)
    }

    /// What has arrived from sample `start` on, and where the stream now ends: what the
    /// voice detector is fed, without copying the utterance from its start each time.
    func peek(from start: Int) -> (samples: [Float], end: Int) {
        lock.withLock {
            let from = min(max(start, 0), samples.count)
            return (copy(samples[from...]), samples.count)
        }
    }

    /// The last `count` samples, or everything when fewer have arrived: what the turn's judge is
    /// asked about. Only the tail is copied, so asking five times a second costs eight seconds of
    /// samples each time however long the utterance has run.
    func tail(_ count: Int) -> [Float] {
        lock.withLock { copy(samples.suffix(max(count, 0))) }
    }

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

/// Everything FluidAudio, one instance for the process — Parakeet v2 and the CTC spotter measured
/// about 120 MB resident together; Ultra's footprint on the phone is the dev build's to measure —
/// and an actor because `transcribe` is a synchronous CoreML forward pass.
actor EarEngine: SpeechEngine {
    static let shared = EarEngine()

    /// The FluidAudio version each acoustic model loads as, named because `AsrModels` defaults
    /// to v3.
    static func version(_ model: EarModel) -> AsrModelVersion {
        switch model {
        case .ultra: .ultra
        case .v2: .v2
        }
    }

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

    /// The acoustic model from disk. `acoustic` is the model's folder, named as FluidAudio's
    /// loader expects (`parakeet-ultra`, the store's; `parakeet-tdt-0.6b-v2`, the
    /// manifest's), since it appends that name to the parent it is given.
    func load(acoustic: URL, model: EarModel, onProgress: @escaping @Sendable (String) -> Void) async throws {
        if asr != nil { return }
        // Every file is the store's or the manifest's and verified; a load that fails is
        // reported, and never answered by FluidAudio deleting the directory and fetching afresh
        // over a session of its own.
        ModelHub.offlineMode = true
        let models = try await AsrModels.load(from: acoustic, version: Self.version(model)) { p in
            if case .compiling(let name) = p.phase { onProgress("\(model.name): compiling \(name)") }
        }
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asr = manager
    }

    /// The spotter from disk: `ctc` is its directory, which is also where FluidAudio's boosting
    /// session reads the tokenizer from (`ModelStore.homes`). The list is `rebuild`'s.
    func loadSpotter(_ ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
        if builder != nil { return }
        ModelHub.offlineMode = true
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
            return try await VocabularyBoostingSession(vocabulary: context, ctcModels: ctcModels,
                                                       config: .init(confidentWordBiasGate: false))
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
