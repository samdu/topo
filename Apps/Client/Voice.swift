#if os(iOS)
import Foundation
import Observation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// Text to speech on this phone: Kyutai's Pocket TTS through FluidAudio's CoreML port, speaking
/// its stock `eponine`. The measured reason for a voice on the device (Daphne's voice bench):
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
/// session (about 351 MB of CoreML: the four bundles the `.ane` placement loads and the
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

    /// The manifest entries the voice needs on disk.
    static let models = [ModelManifest.pocket]

    /// What `loading` reads as: the step a first load after an install spends its time in.
    static let preparing = "preparing the model for this phone"

    /// The speaker: one of the pack's stock voices, resolved by the port against the language
    /// pack's `constants_bin/`. The manifest fetches this one only.
    nonisolated static let speaker = "eponine"

    /// Mimi's rate, which is every frame's rate: 80 ms of audio in 1920 samples.
    nonisolated static let rate = 24_000

    /// The pacing: the rate of the play queue's `AVAudioUnitTimePitch`, with the pitch untouched.
    /// A per-speaker constant rather than a per-clip calculation: measured on one script, eponine
    /// articulates 4.28 words per voiced second against Kokoro at Sam's pace on 5.32, and 1.20
    /// brings her to about 5.02, just under his baseline rather than past it.
    nonisolated static let tempo: Float = 1.20

    var ready: Bool { state == .ready }

    private let engine: any VoiceEngine

    init(engine: any VoiceEngine = Voice.defaultEngine()) {
        self.engine = engine
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
        downloads.start(Self.models)
        guard state != .fetching else { return }
        state = .fetching
        trouble = nil
        downloads.whenPresent(Self.models) { [weak self] in
            guard let self, self.state == .fetching else { return }
            self.load(base: downloads.pocketBase)
        }
    }

    /// The CoreML compile from the store, once the files are all there. `base` is the directory
    /// FluidAudio's Pocket loader derives the pack's path from, which is what the manifest's
    /// entry fills; a file it cannot find is a load failure here and never a download of its own.
    func load(base: URL) {
        state = .loading
        Task {
            do {
                try await engine.load(base: base)
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
        try await engine.stream(text)
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
    func stream(_ text: String) async throws -> AsyncThrowingStream<Voice.Frame, Error>
}

/// Stands in where FluidAudio is not linked: every call fails, so the voice never becomes ready
/// and no reply is read aloud.
struct NoVoice: VoiceEngine {
    private static let why = "FluidAudio is not linked in this build"
    func load(base: URL) async throws { throw VoiceError.unavailable(Self.why) }
    func stream(_ text: String) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
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

    func stream(_ text: String) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        guard let manager else { throw VoiceError.notLoaded }
        let frames = try await manager.synthesizeStreaming(text: text, voice: Voice.speaker)
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
#endif
