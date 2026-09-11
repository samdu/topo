#if os(iOS)
import Foundation
import Observation
#if canImport(MLXAudioTTS)
import MLX
import MLXAudioTTS
#endif

/// Text to speech on this phone: Kokoro-82M through mlx-audio-swift, speaking Buddy's blended
/// voice. The measured reason (Daphne's voice bench): 0.45s to the first word here against 3s
/// for a server's audio over the network the phone is on, the difference being a round trip and
/// a download that do not exist on this path.
///
/// The model is not in the bundle. mlx-audio-swift downloads it from Hugging Face into the
/// app's cache the first time `prepare` runs (about 425 MB: 312 MB of weights, 27 MB of the
/// repo's own voices, 83 MB for the byT5 grapheme-to-phoneme model and 3.5 MB for the English
/// lexicon) and loads it from there on every launch after. The voice itself is bundled
/// (`bm_buddy.safetensors`, 510 KB): it is a blend, not one of the repo's voices. Until the
/// model is resident, or if it fails to load, `Speaker` uses `AVSpeechSynthesizer` instead.
///
/// Published state lives on the main actor; synthesis itself runs in `KokoroEngine`, off it,
/// because Kokoro's forward pass runs synchronously and would freeze the screen for seconds.
@MainActor
@Observable
final class Voice {
    enum State: Equatable { case cold, loading, ready, failed }

    private(set) var state: State = .cold
    /// Why the voice is not available, when it is not. Cleared by the next `prepare`.
    private(set) var trouble: String?

    /// Buddy's pacing. Kokoro scales predicted phoneme durations rather than resampling, so
    /// this is faster speech at the same pitch; 1.18 is the pace Sam chose by ear.
    nonisolated static let pace: Float = 1.18

    var ready: Bool { state == .ready }

    /// One line for the diagnostics screen.
    var summary: String {
        switch state {
        case .cold: return "not loaded"
        case .loading: return "loading"
        case .ready: return "Kokoro resident"
        case .failed: return "failed: \(trouble ?? "unknown")"
        }
    }

    /// Starts the model loading, downloading it first if this phone has never had it.
    /// Idempotent, and called on every foreground so it is resident by the first reply.
    func prepare() {
        #if targetEnvironment(simulator)
        // MLX wants a real Metal device.
        if state == .cold {
            state = .failed
            trouble = "no Metal in the simulator"
        }
        #elseif canImport(MLXAudioTTS)
        guard state == .cold || state == .failed else { return }
        state = .loading
        trouble = nil
        Task {
            do {
                try await KokoroEngine.shared.load()
                state = .ready
            } catch {
                state = .failed
                trouble = error.localizedDescription
            }
        }
        #else
        state = .failed
        trouble = "mlx-audio-swift is not linked in this build"
        #endif
    }

    /// One sentence, synthesised. The samples come back rather than staying in the engine
    /// because the caller queues them for playback the instant they exist.
    func synthesise(_ text: String) async throws -> Clip {
        #if canImport(MLXAudioTTS) && !targetEnvironment(simulator)
        return try await KokoroEngine.shared.synthesise(text)
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
    case noVoice
    case noPlayer

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "Kokoro is not loaded"
        case .noVoice: return "bm_buddy.safetensors is not in the bundle"
        case .noPlayer: return "no playback format"
        }
    }
}

#if canImport(MLXAudioTTS) && !targetEnvironment(simulator)
/// Everything MLX, one instance for the process; the weights are about 160 MB resident. Not an
/// actor: `MLXArray` is not Sendable and the model's `generate` is nonisolated, so an actor could
/// never hand it the voice under strict concurrency. Calls are serialised by their callers
/// instead, which is the shape they have anyway: `Voice.prepare` loads once, gated by its
/// state, and `Speaker`'s chain synthesises one sentence at a time.
final class KokoroEngine: @unchecked Sendable {
    static let shared = KokoroEngine()

    static let repo = "mlx-community/Kokoro-82M-bf16"
    /// Buddy's blended style vector: `[510, 1, 256]` float32 under the key `voice`.
    static let voiceResource = "bm_buddy"
    /// A Kokoro voice picks its grapheme-to-phoneme language from the first letter of its
    /// name (`b` is en-gb), and a reference vector arrives with no name to read, so British
    /// has to be asked for by hand or the voice phonemises American.
    static let language = "en-gb"

    private var model: KokoroModel?
    private var voice: MLXArray?

    func load() async throws {
        if model != nil { return }
        // Unbounded, MLX caches a Metal buffer for every tensor shape it has seen, and each
        // sentence length is a new set of shapes; the growth is what jetsams the app, with no
        // crash log. 64 MB keeps same-shape reuse and stops the climb.
        Memory.cacheLimit = 64 * 1024 * 1024
        // `fromPretrained` leaves the processor nil when none is passed, and a nil processor
        // tokenises the raw English as if it were IPA: it synthesises, badly, with no error.
        let processor = KokoroMultilingualProcessor()
        try await processor.prepare(for: Self.language)
        let m = try await KokoroModel.fromPretrained(Self.repo, textProcessor: processor)
        m.speed = Voice.pace
        model = m
        voice = try Self.bundledVoice()
    }

    func synthesise(_ text: String) async throws -> Voice.Clip {
        guard let model, let voice else { throw VoiceError.notLoaded }
        let audio = try await model.generate(
            text: text,
            // The voice name is what the model would look up on disk and route the G2P by; the
            // vector goes in as the reference instead.
            voice: nil, refAudio: voice, refText: nil,
            language: Self.language,
            generationParameters: model.defaultGenerationParameters)
        // MLX is lazy: `generate` hands back a graph, and the decoder runs when something asks
        // for the numbers.
        return Voice.Clip(samples: audio.asArray(Float.self), rate: model.sampleRate)
    }

    private static func bundledVoice() throws -> MLXArray {
        guard let url = Bundle.main.url(forResource: voiceResource, withExtension: "safetensors")
        else { throw VoiceError.noVoice }
        let arrays = try MLX.loadArrays(url: url)
        guard var v = arrays["voice"] ?? arrays.values.first else { throw VoiceError.noVoice }
        v = v.asType(.float32)
        // The file is [510, 1, 256] and the model indexes [token count, style], which is what
        // its own voice loader does to the repo's voices.
        if v.ndim == 3 { v = v.squeezed(axis: 1) }
        return v
    }
}
#endif
#endif
