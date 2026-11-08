#if os(iOS)
import TopoCore
import Foundation
import Observation
#if canImport(PhononTTS)
import PhononTTS
#endif

/// Text to speech on this phone: Gradium's Phonon 40m English through Gradium's own Swift
/// runtime (`PhononTTS`), speaking Friendly Octopus, the one voice its bundle carries
/// (`PhononStore`). On the device because the first sound is what a listener waits for: a few
/// milliseconds to the first 80 ms frame on the Neural Engine, against a round trip and a download
/// for a server's audio. Phonon makes audio about thirty times faster than it plays.
///
/// The runtime places the flow model on the Neural Engine (`.neuralEngine`) and decodes on the
/// CPU; a simulator has no Neural Engine and Core ML runs the same models on its CPU, so the
/// voice is the phone's voice there too, only slower. Phonon makes no audio handle of its own:
/// its samples reach the speaker through `Speaker`'s play queue alone, which is why ptts's own
/// player is not in the vendored package.
///
/// The bundle is not compiled into the app. `PhononStore` copies it, checked, from this build's
/// source (the Apple-hosted asset pack, the app's own resources in a build from the install page,
/// or a debug launch's folder) into Application Support, and the engine loads it from there.
/// Until it is resident, or if it fails to load, a reply is not read aloud; the diagnostics
/// `voice` row says which.
///
/// Published state lives on the main actor; synthesis runs in `PhononVoiceEngine`, an actor, off
/// the main thread.
@MainActor
@Observable
final class Voice {
    /// `fetching` is the store making its copy — a pack's download first where the system has
    /// not finished it — and then, with the copy made, the wait for the ear's compile to end
    /// (`waitsForEar`); `loading` is Core ML's compile from disk, which the first load after an
    /// install or a new bundle pays.
    enum State: Equatable { case cold, fetching, loading, ready, failed }

    private(set) var state: State = .cold
    /// Why the voice is not available, when it is not. Cleared by the next `prepare`.
    private(set) var trouble: String?
    /// How far a pack's download has come, while the store waits on one.
    private(set) var fraction: Double?
    /// Whether this fetch replaces a copy already in the store: a new version of the pack after
    /// an update, which downloads at the first launch after it, with replies written until it is in.
    private(set) var renewing = false
    /// Whether the store has begun a copy, rather than still finding its copy whole.
    private(set) var copyingNow = false
    /// The ear beside the voice, which comes first: the first thing a person does is talk, and a
    /// reply can be text until the voice is in. The voice's compile waits while the ear is still
    /// to be fetched or is compiling (`mayLoad`), so the ear's compile is not shared with the
    /// voice's. An ear whose download failed lets the voice go, since a broken ear never costs
    /// the voice. Nothing holds the ear back for the voice. Unset (a debug stand-in ear) waits
    /// for nothing. Whoever sets it has the ear call `earSettled` when its compile ends.
    weak var ear: Ear?
    /// Whether a wait on the ear's download is registered, so a refusal registers one only.
    private var awaitingEarFiles = false
    /// The store's folder once the copy is made, while the state is still `fetching`: the
    /// compile is waiting on the ear.
    private var folder: URL?

    /// What `loading` reads as: the step a first load after an install spends its time in.
    static let preparing = "preparing the model for this phone"

    /// What the voice's line says while its copy is made and its compile waits on the ear's.
    nonisolated static let afterEar = "waiting for the ear"

    /// What the line says while the store finds its copy whole, which every launch does and draws
    /// no meter for (`Setup.launchWords`).
    nonisolated static let checking = "checking Topo's voice"
    /// What the line says while the store waits on the pack, and while it copies.
    static let downloading = "downloading Topo's voice"
    static let copying = "copying Topo's voice"
    /// What the line says while a new version of the pack downloads over the copy in the store.
    static let renewingWords = "downloading Topo's new voice, replies written until it's in"

    /// Whether the voice may compile, given the ear: none beside it, or one neither still to be
    /// fetched nor compiling. An ear being fetched lets the voice go once its download failed.
    static func mayLoad(ear: Ear.State?, earDownloadFailed: Bool) -> Bool {
        switch ear {
        case nil, .cold, .ready, .failed: true
        case .loading: false
        case .fetching: earDownloadFailed
        }
    }

    /// Whether the compile is waiting on the ear, with the copy made.
    var waitsForEar: Bool { state == .fetching && folder != nil }

    /// Phonon's rate, which is every frame's rate: 80 ms of audio in 1920 samples.
    nonisolated static let rate = 24_000

    var ready: Bool { state == .ready }

    private let engine: any VoiceEngine
    private let store: PhononStore
    private let source: any PhononSource
    /// Where `VoiceTemperature` is kept, read as each sentence is asked for.
    private let defaults: UserDefaults

    init(engine: any VoiceEngine = Voice.defaultEngine(), store: PhononStore = .standard(),
         source: (any PhononSource)? = nil, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.store = store
        self.source = source ?? FolderSource.embedded() ?? AssetPackSource()
        self.defaults = defaults
    }

    static func defaultEngine() -> any VoiceEngine {
        #if canImport(PhononTTS)
        return PhononVoiceEngine.shared
        #else
        return NoVoice()
        #endif
    }

    #if DEBUG
    /// True on a voice a debug build asked to stay unloaded; `prepare` then does nothing.
    private var stalled = false

    /// A voice that never becomes resident (`TOPO_DEBUG_VOICE=loading`), so a phone with the
    /// voice's copy on disk can be made to leave a reply unspoken from a launch argument.
    static func stalledVoice() -> Voice {
        let voice = Voice()
        voice.stalled = true
        voice.state = .loading
        return voice
    }
    #endif

    /// What the line says while the state is `fetching`.
    var fetchWords: String {
        if waitsForEar { return Self.afterEar }
        let downloading = renewing ? Self.renewingWords : Self.downloading
        if let fraction { return "\(downloading) (\(Int((fraction * 100).rounded()))%)" }
        return copyingNow ? Self.copying : Self.checking
    }

    /// One line for the diagnostics screen.
    var summary: String {
        switch state {
        case .cold: return "not loaded"
        case .fetching: return fetchWords
        case .loading: return Self.preparing
        case .ready: return "Phonon resident"
        case .failed: return "failed: \(trouble ?? "unknown")"
        }
    }

    /// Asks the store for its copy and loads it once the copy is made and the ear is not
    /// compiling. Idempotent, and called on every foreground so it is resident by the first reply
    /// and a copy or a load that failed is tried again.
    func prepare() {
        #if DEBUG
        if stalled { return }
        #endif
        guard state != .loading, state != .ready else { return }
        guard state != .fetching else {
            loadIfDue()
            return
        }
        state = .fetching
        trouble = nil
        folder = nil
        fraction = nil
        renewing = store.installed() != nil
        copyingNow = false
        let store = store, source = source
        Task {
            do {
                let folder = try await store.install(from: source, progress: { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.state == .fetching, self.folder == nil, !self.copyingNow else { return }
                        self.fraction = fraction
                    }
                }, copying: {
                    Task { @MainActor [weak self] in
                        guard let self, self.state == .fetching, self.folder == nil else { return }
                        self.fraction = nil
                        self.copyingNow = true
                    }
                })
                guard state == .fetching else { return }
                self.folder = folder
                fraction = nil
                loadIfDue()
            } catch {
                guard state == .fetching else { return }
                state = .failed
                trouble = error.localizedDescription
            }
        }
    }

    /// The ear's compile has ended, resident or failed: the voice's compile goes if its copy is
    /// made.
    func earSettled() {
        loadIfDue()
    }

    /// The compile, once the copy is made and the ear allows it. Refused for an ear still being
    /// fetched, it waits for the ear's download to settle: a failure lets the voice go, and an
    /// arrival puts the ear into its compile, whose end calls `earSettled`.
    private func loadIfDue() {
        guard state == .fetching, let folder else { return }
        let downloads = ModelDownloads.shared
        guard Self.mayLoad(ear: ear?.state, earDownloadFailed: downloads.failed(Ear.models)) else {
            if ear?.state == .fetching, !awaitingEarFiles {
                awaitingEarFiles = true
                downloads.whenSettled(Ear.models) { [weak self] _ in
                    // A turn later, so the ear's own wait on the same arrival has put it into
                    // its compile first.
                    Task { @MainActor in
                        self?.awaitingEarFiles = false
                        self?.earSettled()
                    }
                }
            }
            return
        }
        load(folder: folder)
    }

    /// The Core ML compile and load from the store's folder, at the temperature kept now.
    func load(folder: URL) {
        state = .loading
        Perf.mark("voice.load.begin")
        let temperature = VoiceTemperature.value(defaults)
        Task {
            do {
                try await engine.load(folder: folder, temperature: temperature)
                Perf.mark("voice.load.end")
                state = .ready
            } catch {
                state = .failed
                trouble = error.localizedDescription
            }
        }
    }

    /// One sentence, as the frames of it arrive. The caller queues each for playback the instant
    /// it exists, so what a listener waits for is a frame rather than the sentence.
    /// An engine that refuses the sentence itself, before any frame, holds no bundle: a reload
    /// for a new temperature failed. That is a voice that is not ready, so the voice fails, the
    /// line says why, replies are text, and the next `prepare` loads it again.
    func synthesise(_ text: String) async throws -> AsyncThrowingStream<Frame, Error> {
        do {
            return try await engine.stream(text, temperature: VoiceTemperature.value(defaults))
        } catch {
            if state == .ready {
                state = .failed
                trouble = "could not be loaded again: \(error.localizedDescription)"
            }
            throw error
        }
    }

    /// One decoded frame, 80 ms of audio.
    struct Frame: Sendable {
        let samples: [Float]
        let rate: Int
    }
}

/// The engine as the voice drives it: `PhononVoiceEngine` in the app, a double in the tests.
protocol VoiceEngine: Sendable {
    /// The bundle from the store's folder, sampled at `temperature`. Throws when it cannot be
    /// loaded, which fails the voice.
    func load(folder: URL, temperature: Float) async throws
    /// One sentence as a stream of frames. Ending the stream (breaking out of it) stops the
    /// synthesis behind it.
    /// `temperature` is `VoiceTemperature`'s value as it stood when the sentence was asked for.
    func stream(_ text: String, temperature: Float) async throws -> AsyncThrowingStream<Voice.Frame, Error>
}

/// Stands in where PhononTTS is not linked: every call fails, so the voice never becomes ready
/// and no reply is read aloud.
struct NoVoice: VoiceEngine {
    private static let why = "PhononTTS is not linked in this build"
    func load(folder: URL, temperature: Float) async throws { throw VoiceError.unavailable(Self.why) }
    func stream(_ text: String, temperature: Float) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        throw VoiceError.unavailable(Self.why)
    }
}

enum VoiceError: LocalizedError {
    case notLoaded
    case noPlayer
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "the voice is not loaded"
        case .noPlayer: return "no playback format"
        case .unavailable(let why): return why
        }
    }
}

/// What the engine needs of Phonon: one loaded bundle that speaks a sentence as chunks of
/// samples, and stops when the stream it returned is ended. `Phonon` in the app, a double in
/// the tests, so the engine's order — one sentence at a time, a reload never under one — is held
/// without a model.
protocol PhononSpeaking: AnyObject, Sendable {
    /// Makes `text`, handing each chunk to `onAudio` as it is made, and returns once the native
    /// call has: at the end of the sentence, or at the next chunk after the calling task is
    /// cancelled.
    func say(_ text: String, onAudio: @escaping @Sendable ([Float]) -> Void) async throws
}

/// Phonon, one instance for the process. An actor so its order is one place: a sentence is
/// made only once the one before has stopped making samples, its own or a stopped one's, so two
/// never run at once and a sentence's wait is never another's tail; and the bundle is loaded
/// again, for a new temperature, only between sentences. Phonon reads its temperature from the
/// bundle's `bundle.json` when it loads (its runtime has no setter), so a change is written into
/// the store's copy and the bundle loaded again before the next sentence: about a quarter of a
/// second warm, once, after the setting moved.
actor PhononVoiceEngine: VoiceEngine {
    #if canImport(PhononTTS)
    static let shared = PhononVoiceEngine(open: { folder in
        let phonon = try await Phonon.load(models: folder, language: .english, computeUnit: .neuralEngine)
        try await phonon.setVoice(PhononStore.voice)
        return phonon
    })
    #endif

    private let open: @Sendable (URL) async throws -> any PhononSpeaking
    private var phonon: (any PhononSpeaking)?
    private var folder: URL?
    private var temperature: Float?

    init(open: @escaping @Sendable (URL) async throws -> any PhononSpeaking) {
        self.open = open
    }

    func load(folder: URL, temperature: Float) async throws {
        await take()
        defer { release() }
        if phonon != nil, self.folder == folder, self.temperature == temperature { return }
        self.folder = folder
        try await reload(at: temperature)
    }

    /// The bundle at `temperature`: written into the copy's `bundle.json`, the old instance let
    /// go before the new one is made, so two are never held at once.
    private func reload(at temperature: Float) async throws {
        guard let folder else { throw VoiceError.notLoaded }
        try Self.write(temperature: temperature, into: folder.appendingPathComponent("bundle.json"))
        phonon = nil
        self.temperature = nil
        phonon = try await open(folder)
        self.temperature = temperature
    }

    /// Sets the one key, leaving every other in the file as it was.
    static func write(temperature: Float, into url: URL) throws {
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw VoiceError.unavailable("the voice's bundle.json is not an object")
        }
        if let kept = object["temperature"] as? NSNumber, kept.floatValue == temperature { return }
        // The float's shortest decimal, as a decimal number, which JSONSerialization writes as its
        // own digits: 0.3 is written 0.3, not a double's seventeen.
        object["temperature"] = NSDecimalNumber(string: "\(temperature)")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    func stream(_ text: String, temperature: Float) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        await take()
        do {
            if self.temperature != temperature { try await reload(at: temperature) }
            guard let phonon else { throw VoiceError.notLoaded }
            let (frames, continuation) = AsyncThrowingStream<Voice.Frame, Error>.makeStream()
            // The producer calls Phonon itself and frees the engine only once that call has
            // returned, so a dropped sentence's native work is over before the next begins; and it
            // has let go of the instance by then, so a reload after it never opens beside it.
            let held = Held(phonon)
            let producer = Task.detached {
                do {
                    try await held.take()?.say(text) { chunk in
                        continuation.yield(Voice.Frame(samples: chunk, rate: Voice.rate))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
                await self.release()
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
            return frames
        } catch {
            release()
            throw error
        }
    }

    /// Whether a sentence holds the engine: from its ask, through a reload, to its producer's end.
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Waits until no sentence holds the engine, then holds it. A waiter woken finds it free,
    /// since `release` hands it over without freeing it in between.
    private func take() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty {
            busy = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

/// The instance a sentence's producer holds until it hands it to its one call.
private final class Held: @unchecked Sendable {
    private let lock = NSLock()
    private var phonon: (any PhononSpeaking)?
    init(_ phonon: any PhononSpeaking) { self.phonon = phonon }
    func take() -> (any PhononSpeaking)? {
        lock.withLock {
            defer { phonon = nil }
            return phonon
        }
    }
}

#if canImport(PhononTTS)
extension Phonon: PhononSpeaking {
    func say(_ text: String, onAudio: @escaping @Sendable ([Float]) -> Void) async throws {
        try await speak(text, onAudio: onAudio)
    }
}
#endif
/// How much chance each frame of the voice is drawn with: Phonon's flow sampler draws every
/// frame's noise with a spread of this value's square root. A setting, this device's alone: a
/// slider in the settings sheet and the mind's `topo voice temperature`, kept as the
/// `voiceTemperature` default and read as each sentence is asked for (`Voice.synthesise`), and
/// taken by the engine by loading the bundle again before that sentence (`PhononVoiceEngine`).
/// `Speaker` asks for a reply's sentences ahead of their playing, so a change is heard from the
/// next reply, and in a reply being read only from the sentences not yet made.
enum VoiceTemperature {
    static let key = "voiceTemperature"

    /// What a phone never asked speaks at: the bundle's own, which Gradium's exporter writes as
    /// the temperature its other frontends speak at, and what Sam heard Friendly Octopus at.
    static let standard = 0.3

    /// What the decoder is ever handed. Below 0 the square root is not a number; 1 is the
    /// noise unscaled, which is as far as the model was trained.
    static let range = 0.0...1.0

    /// The slider's step, and what a value is said to: two places.
    static let step = 0.05

    /// The value as kept, or the standard one for a phone never asked and for anything kept
    /// that is not a number in the range.
    static func value(_ defaults: UserDefaults = .standard) -> Float {
        // A Boolean kept there is an `NSNumber` too, and is no temperature.
        guard let kept = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(kept) != CFBooleanGetTypeID() else { return Float(standard) }
        return Float(judged(kept.doubleValue) ?? standard)
    }

    /// A value the decoder can take, or nil.
    static func judged(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, range.contains(raw) else { return nil }
        return raw
    }

    static func said(_ value: Double) -> String { String(format: "%.2f", value) }
}
/// How fast the voice is heard: the rate of the play queue's `AVAudioUnitTimePitch`, with the
/// pitch untouched, so faster speech keeps its voice. A setting, this device's alone: a slider in
/// the settings sheet and the mind's `topo voice speed`, kept as the `voiceSpeed` default and read
/// by the play queue where it already speaks to its nodes (`PlayQueue.build` and `play`, after
/// `AudioSession.ensureActive`), so a change is heard from the next frame queued. Phonon's own
/// pace is fixed in its bundle at export, with no setter in its runtime, which is why speed is
/// the queue's.
enum VoiceSpeed {
    static let key = "voiceSpeed"

    /// The pace Friendly Octopus speaks at, unstretched.
    static let standard = 1.0

    /// What the unit is ever handed: slower than 0.8 and the stretch is heard as a smear, past
    /// 1.5 words run together.
    static let range = 0.8...1.5

    /// The slider's step, and what a value is said to: two places.
    static let step = 0.05

    /// The value as kept, or the standard one for a phone never asked and for anything kept
    /// that is not a number in the range.
    static func value(_ defaults: UserDefaults = .standard) -> Float {
        guard let kept = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(kept) != CFBooleanGetTypeID() else { return Float(standard) }
        return Float(judged(kept.doubleValue) ?? standard)
    }

    /// A value the unit can take, or nil.
    static func judged(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, range.contains(raw) else { return nil }
        return raw
    }

    static func said(_ value: Double) -> String { String(format: "%.2f", value) }
}
#endif
