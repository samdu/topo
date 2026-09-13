#if os(iOS)
import Foundation
import Observation
#if canImport(MLXAudioTTS)
import MLX
import MLXAudioTTS
#endif

/// Text to speech on this phone: Kyutai's Pocket TTS through mlx-audio-swift, speaking its stock
/// `eponine`. The measured reason for a voice on the device (Daphne's voice bench): 0.45s to the
/// first word here against 3s for a server's audio over the network the phone is on, the
/// difference being a round trip and a download that do not exist on this path.
///
/// A stock voice rather than a blend: each person names their own mind, so the default voice
/// is nobody's in particular. Pocket is a small language model over Mimi audio frames, which is
/// where its prosody comes from, and it has no pace knob of its own, so `Speaker` paces every
/// sentence on the way to the speaker (`PocketPace`, then the play queue's time-pitch unit at
/// `Voice.tempo`).
///
/// The model is not in the bundle. `ModelDownloads` fetches it through the app's background
/// session (about 237 MB: the bf16 weights, the config, the tokenizer and the one speaker
/// embedding, listed file by file in the manifest) into the app's Application Support, and
/// mlx-audio-swift loads it from there. Until the model is resident, or if it fails to load,
/// `Speaker` uses `AVSpeechSynthesizer` instead.
///
/// Published state lives on the main actor; synthesis itself runs in `PocketEngine`, off it,
/// because the decode loop runs synchronously and would freeze the screen for seconds.
@MainActor
@Observable
final class Voice {
    /// `fetching` is the wait for `ModelDownloads` to have every file; `loading` is the read
    /// of the weights into MLX.
    enum State: Equatable { case cold, fetching, loading, ready, failed }

    private(set) var state: State = .cold
    /// Why the voice is not available, when it is not. Cleared by the next `prepare`.
    private(set) var trouble: String?

    /// The manifest entries the voice needs on disk.
    static let models = [ModelManifest.pocket]

    /// The speaker: one of the eight stock embeddings in the model repository, resolved by the
    /// port against the model directory's `embeddings/`. The manifest fetches this one only.
    nonisolated static let speaker = "eponine"

    /// Stage two of the pacing, the rate of the play queue's `AVAudioUnitTimePitch` with the
    /// pitch untouched; stage one is `PocketPace.trimGaps`, which is why this is a small number.
    /// A per-speaker constant rather than a per-clip calculation: measured on one script, after
    /// trimming, eponine articulates 4.28 words per voiced second against Kokoro at Sam's pace
    /// on 5.32, and 1.20 brings her to about 5.02, just under his baseline rather than past it.
    nonisolated static let tempo: Float = 1.20

    var ready: Bool { state == .ready }

    /// One line for the diagnostics screen.
    var summary: String {
        switch state {
        case .cold: return "not loaded"
        case .fetching: return ModelDownloads.shared.describe(Self.models)
        case .loading: return "loading"
        case .ready: return "Pocket resident"
        case .failed: return "failed: \(trouble ?? "unknown")"
        }
    }

    /// Asks for the model, downloading whatever this phone lacks, and loads it once every file
    /// is on disk. Idempotent, and called on every foreground so it is resident by the first
    /// reply and a download that failed is tried again.
    func prepare() {
        #if targetEnvironment(simulator)
        // MLX wants a real Metal device, so the simulator asks for nothing.
        if state == .cold {
            state = .failed
            trouble = "no Metal in the simulator"
        }
        #elseif canImport(MLXAudioTTS)
        let downloads = ModelDownloads.shared
        downloads.start(Self.models)
        guard state == .cold || state == .failed else { return }
        state = .fetching
        trouble = nil
        downloads.whenPresent(Self.models) { [weak self] in self?.load() }
        #else
        state = .failed
        trouble = "mlx-audio-swift is not linked in this build"
        #endif
    }

    /// The read into MLX, from the store's directory, once the files are all there.
    private func load() {
        #if canImport(MLXAudioTTS) && !targetEnvironment(simulator)
        guard state == .fetching else { return }
        state = .loading
        Task {
            do {
                try await PocketEngine.shared.load(from: ModelDownloads.shared.directory(for: ModelManifest.pocket))
                state = .ready
            } catch {
                state = .failed
                trouble = error.localizedDescription
            }
        }
        #endif
    }

    /// One sentence, synthesised. The samples come back rather than staying in the engine
    /// because the caller queues them for playback the instant they exist.
    func synthesise(_ text: String) async throws -> Clip {
        #if canImport(MLXAudioTTS) && !targetEnvironment(simulator)
        return try await PocketEngine.shared.synthesise(text)
        #else
        throw VoiceError.notLoaded
        #endif
    }

    struct Clip {
        let samples: [Float]
        let rate: Int
    }
}

enum VoiceError: LocalizedError {
    case notLoaded
    case noPlayer

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Pocket TTS is not loaded"
        case .noPlayer: return "no playback format"
        }
    }
}

#if canImport(MLXAudioTTS) && !targetEnvironment(simulator)
/// Everything MLX, one instance for the process. Not an actor: `MLXArray` is not Sendable and
/// the model's `generate` is nonisolated, so an actor could never hand its result across under
/// strict concurrency. Calls are serialised by their callers instead, which is the shape they
/// have anyway: `Voice.prepare` loads once, gated by its state, and `Speaker`'s chain
/// synthesises one sentence at a time.
final class PocketEngine: @unchecked Sendable {
    static let shared = PocketEngine()

    private var model: PocketTTSModel?

    /// `directory` is the one the manifest's Pocket entry fills: the config, the weights, the
    /// tokenizer and `embeddings/<speaker>.safetensors`, which is everything the port reads.
    /// Loaded from the directory rather than by repository name, so the port never opens a
    /// session of its own to the Hub.
    func load(from directory: URL) async throws {
        if model != nil { return }
        // Unbounded, MLX caches a Metal buffer for every tensor shape it has seen, and each
        // sentence length is a new set of shapes; the growth is what jetsams the app, with no
        // crash log. 64 MB keeps same-shape reuse and stops the climb.
        Memory.cacheLimit = 64 * 1024 * 1024
        model = try await PocketTTSModel.fromModelDirectory(directory)
    }

    func synthesise(_ text: String) async throws -> Voice.Clip {
        guard let model else { throw VoiceError.notLoaded }
        let audio = try await model.generate(
            text: text,
            voice: Voice.speaker,
            refAudio: nil, refText: nil, language: nil,
            generationParameters: model.defaultGenerationParameters)
        // MLX is lazy: `generate` hands back a graph, and the decoder runs when something asks
        // for the numbers.
        return Voice.Clip(samples: audio.asArray(Float.self), rate: model.sampleRate)
    }
}
#endif
#endif
