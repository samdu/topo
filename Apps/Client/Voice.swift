#if os(iOS)
import TopoCore
import Foundation
import Observation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Text to speech on this phone: Kyutai's Pocket TTS through FluidAudio's CoreML port, speaking
/// its stock `marius`. The measured reason for a voice on the device (Daphne's voice bench):
/// 0.04–0.18s to the first sound here against about 3s for a server's audio over the network the
/// phone is on, the difference being a round trip and a download that do not exist on this path.
///
/// A stock voice rather than a blend: each person names their own mind, so the default voice
/// is nobody's in particular. Pocket is a small language model over Mimi audio frames, which is
/// where its prosody comes from, and it has no pace knob of its own, so `Speaker` paces every
/// sentence on the way to the speaker, with the play queue's time-pitch unit at `Voice.tempo`.
///
/// Every stage is placed off the GPU: the conditioner, the flow-LM and the fused flow decoder on
/// the Neural Engine (the rank-4 graphs its compiler accepts), Mimi on the CPU, where the port
/// found it fastest and where its fp16 state feedback does not beep as it does on the ANE.
/// `.cpuAndNeuralEngine` rather than `.all` throughout, because `.all` lets a stage fall to the
/// GPU, which is the one thing this placement exists to rule out. A simulator has no Neural
/// Engine and CoreML runs the same models on its CPU, so the voice is the phone's voice there
/// too, only slower.
///
/// The model is not in the bundle. `ModelDownloads` fetches it through the app's background
/// session (about 350 MB of CoreML: the four bundles the `.ane` placement loads and the
/// constants beside them, listed file by file in the manifest) into the app's Application
/// Support, and FluidAudio loads it from there, told to touch no network of its own. Until it is
/// resident, or if it fails to load, a reply is not read aloud; the diagnostics `voice` row says
/// which.
///
/// Published state lives on the main actor; synthesis itself runs in `PocketVoiceEngine`, an
/// actor, because a CoreML prediction is synchronous and would freeze the screen.
@MainActor
@Observable
final class Voice {
    /// `fetching` is the wait for `ModelDownloads` to have every file; `loading` is the CoreML
    /// compile from disk, which the first load after an install pays: the Neural Engine
    /// compiling the model for this phone.
    enum State: Equatable { case cold, fetching, loading, ready, failed }

    private(set) var state: State = .cold
    /// Why the voice is not available, when it is not. Cleared by the next `prepare`.
    private(set) var trouble: String?
    /// Whether the ear is being fetched or compiled. The ear comes first, since the first thing a
    /// person does is talk and a reply can be text until the voice is in: the voice's files are
    /// asked for after the ear's (`ModelDownloads.start(_:after:)`), and its compile waits for the
    /// ear's, because the Neural Engine's compiler working on both makes the ear later. Unset
    /// (a voice with no ear beside it) waits for nothing; whoever sets it calls `prepare` again
    /// when the ear stops being busy.
    var earBusy: (@MainActor () -> Bool)?
    /// Whether every file is on the phone while the state is still `fetching`: the compile is
    /// waiting on the ear.
    private var filesHere = false

    /// The manifest entries the voice needs on disk.
    static let models = [ModelManifest.pocket]

    /// What `loading` reads as: the step a first load after an install spends its time in.
    static let preparing = "preparing the model for this phone"

    /// What the voice's line says while its files are here and its compile waits on the ear's.
    static let afterEar = "waiting for the ear"

    /// Whether the compile is waiting on the ear, with every file on the phone.
    var waitsForEar: Bool { state == .fetching && filesHere }

    /// The speaker: one of the pack's stock voices, resolved by the port against the language
    /// pack's `constants_bin/`. The manifest fetches this one only.
    nonisolated static let speaker = "marius"

    /// Mimi's rate, which is every frame's rate: 80 ms of audio in 1920 samples.
    nonisolated static let rate = 24_000

    /// The pacing: the rate of the play queue's `AVAudioUnitTimePitch`, with the pitch untouched.
    /// A per-speaker constant rather than a per-clip calculation, and for marius it is 1: he is
    /// heard at the pace he speaks at, which Sam chose by ear, so the unit stretches nothing.
    /// Measured on CPU Pocket rather than a phone, he articulates about 5.3 words per voiced
    /// second, where a slower stock voice (eponine, about 4.0 by the same measure) wants 1.20.
    nonisolated static let tempo: Float = 1.0

    var ready: Bool { state == .ready }

    private let engine: any VoiceEngine
    /// Where `VoiceTemperature` is kept, read as each sentence is asked for.
    private let defaults: UserDefaults

    init(engine: any VoiceEngine = Voice.defaultEngine(), defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
    }

    static func defaultEngine() -> any VoiceEngine {
        #if canImport(FluidAudio)
        return PocketVoiceEngine.shared
        #else
        return NoVoice()
        #endif
    }

    #if DEBUG
    /// True on a voice a debug build asked to stay unloaded; `prepare` then does nothing.
    private var stalled = false

    /// A voice that never becomes resident (`TOPO_DEBUG_VOICE=loading`), so a phone with Pocket
    /// on disk can be made to leave a reply unspoken from a launch argument.
    static func stalledVoice() -> Voice {
        let voice = Voice()
        voice.stalled = true
        voice.state = .loading
        return voice
    }
    #endif

    /// One line for the diagnostics screen.
    var summary: String {
        switch state {
        case .cold: return "not loaded"
        case .fetching: return ModelDownloads.shared.describe(Self.models)
        case .loading: return Self.preparing
        case .ready: return "Pocket resident"
        case .failed: return "failed: \(trouble ?? "unknown")"
        }
    }

    /// Asks for the model, downloading whatever this phone lacks, and loads it once every file
    /// is on disk. Idempotent, and called on every foreground so it is resident by the first
    /// reply and a download that failed is tried again.
    func prepare() {
        #if DEBUG
        if stalled { return }
        #endif
        guard state != .loading, state != .ready else { return }
        let downloads = ModelDownloads.shared
        downloads.start(Self.models, after: Ear.models)
        guard state != .fetching else {
            loadIfDue(base: downloads.pocketBase)
            return
        }
        state = .fetching
        trouble = nil
        filesHere = false
        downloads.whenPresent(Self.models) { [weak self] in
            guard let self, self.state == .fetching else { return }
            self.filesHere = true
            self.loadIfDue(base: downloads.pocketBase)
        }
    }

    /// The compile, once the files are here and the ear is not busy.
    private func loadIfDue(base: URL) {
        guard state == .fetching, filesHere, earBusy?() != true else { return }
        load(base: base)
    }

    /// The CoreML compile from the store, once the files are all there. `base` is the directory
    /// FluidAudio's Pocket loader derives the pack's path from, which is what the manifest's
    /// entry fills; a file it cannot find is a load failure here and never a download of its own.
    func load(base: URL) {
        state = .loading
        Perf.mark("voice.load.begin")
        Task {
            do {
                try await engine.load(base: base)
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
    func synthesise(_ text: String) async throws -> AsyncThrowingStream<Frame, Error> {
        try await engine.stream(text, temperature: VoiceTemperature.value(defaults))
    }

    /// One decoded frame, 80 ms of audio.
    struct Frame: Sendable {
        let samples: [Float]
        let rate: Int
    }
}

/// The engine as the voice drives it: `PocketVoiceEngine` in the app, a double in the tests.
protocol VoiceEngine: Sendable {
    /// The models from disk, under the base directory the loader derives the pack's path from.
    /// Throws when they cannot be loaded, which fails the voice.
    func load(base: URL) async throws
    /// One sentence as a stream of frames. Breaking out of the stream cancels the synthesis
    /// behind it.
    /// `temperature` is `VoiceTemperature`'s value as it stood when the sentence was asked for.
    func stream(_ text: String, temperature: Float) async throws -> AsyncThrowingStream<Voice.Frame, Error>
}

/// Stands in where FluidAudio is not linked: every call fails, so the voice never becomes ready
/// and no reply is read aloud.
struct NoVoice: VoiceEngine {
    private static let why = "FluidAudio is not linked in this build"
    func load(base: URL) async throws { throw VoiceError.unavailable(Self.why) }
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
        case .notLoaded: return "Pocket TTS is not loaded"
        case .noPlayer: return "no playback format"
        case .unavailable(let why): return why
        }
    }
}

#if canImport(FluidAudio)
/// FluidAudio's Pocket port, one instance for the process. An actor because a CoreML prediction
/// is synchronous: the decode loop runs a model per 80 ms frame and would freeze the screen.
actor PocketVoiceEngine: VoiceEngine {
    static let shared = PocketVoiceEngine()

    private var manager: PocketTtsManager?

    /// `base` is the directory the manifest's Pocket entry was filled under: the port appends
    /// `Models/pocket-tts/v2.1/english` to it and reads the pack from there. Offline first, as
    /// `Ear` does, so a file the store lacks is a load failure rather than a download over a
    /// session of the library's own.
    func load(base: URL) async throws {
        if manager != nil { return }
        ModelHub.offlineMode = true
        let manager = PocketTtsManager(
            defaultVoice: Voice.speaker, language: .english, directory: base, placement: .ane,
            computeUnits: PocketTtsComputeUnits(
                conditioner: .cpuAndNeuralEngine,
                flowLM: .cpuAndNeuralEngine,
                flowDecoder: .cpuAndNeuralEngine,
                mimiDecoder: .cpuOnly))
        try await manager.initialize()
        self.manager = manager
    }

    func stream(_ text: String, temperature: Float) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        guard let manager else { throw VoiceError.notLoaded }
        let frames = try await manager.synthesizeStreaming(
            text: text, voice: Voice.speaker, temperature: temperature)
        let rate = PocketTtsConstants.audioSampleRate
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await frame in frames {
                        continuation.yield(Voice.Frame(samples: frame.samples, rate: rate))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
#endif
/// How much chance each frame of the voice is drawn with: the flow decoder starts every frame
/// from noise scaled by this value's square root. A setting, this device's alone: a slider in
/// the settings sheet and the mind's `topo voice temperature`, kept as the `voiceTemperature`
/// default and read as each sentence is asked for (`Voice.synthesise`). `Speaker` asks for a
/// reply's sentences ahead of their playing, so a change is heard from the next reply, and in
/// a reply being read only from the sentences not yet made.
enum VoiceTemperature {
    static let key = "voiceTemperature"

    /// What a phone never asked speaks at, chosen by Sam's ear between the two published
    /// defaults: Kyutai's own package speaks English at 0.3 (kyutai-labs/pocket-tts#223) and
    /// FluidAudio at 0.7.
    static let standard = 0.5

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
#endif
