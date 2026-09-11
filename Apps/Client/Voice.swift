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
/// The model is not in the bundle. `ModelDownloads` fetches it through the app's background
/// session (about 320 MB: 311 MB of weights and 9 MB for the English grapheme-to-phoneme
/// resources, listed file by file in the manifest) into the app's Application Support, and
/// mlx-audio-swift loads it from there. The voice itself is bundled (`bm_buddy.safetensors`,
/// 510 KB): it is a blend, not one of the repo's voices, which is why none of those are fetched.
/// Until the model is resident, or if it fails to load, `Speaker` uses `AVSpeechSynthesizer`
/// instead.
///
/// Published state lives on the main actor; synthesis itself runs in `KokoroEngine`, off it,
/// because Kokoro's forward pass runs synchronously and would freeze the screen for seconds.
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
    static let models = [ModelManifest.kokoro, ModelManifest.g2p]

    /// Buddy's pacing. Kokoro scales predicted phoneme durations rather than resampling, so
    /// this is faster speech at the same pitch; 1.18 is the pace Sam chose by ear.
    nonisolated static let pace: Float = 1.18

    var ready: Bool { state == .ready }

    /// One line for the diagnostics screen.
    var summary: String {
        switch state {
        case .cold: return "not loaded"
        case .fetching: return ModelDownloads.shared.describe(Self.models)
        case .loading: return "loading"
        case .ready: return "Kokoro resident"
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

    /// The read into MLX, from the store's directories, once the files are all there.
    private func load() {
        #if canImport(MLXAudioTTS) && !targetEnvironment(simulator)
        guard state == .fetching else { return }
        state = .loading
        Task {
            do {
                let downloads = ModelDownloads.shared
                try await KokoroEngine.shared.load(kokoro: downloads.directory(for: ModelManifest.kokoro),
                                                   g2p: downloads.directory(for: ModelManifest.g2p))
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

    /// Buddy's blended style vector: `[510, 1, 256]` float32 under the key `voice`.
    static let voiceResource = "bm_buddy"
    /// A Kokoro voice picks its grapheme-to-phoneme language from the first letter of its
    /// name (`b` is en-gb), and a reference vector arrives with no name to read, so British
    /// has to be asked for by hand or the voice phonemises American.
    static let language = "en-gb"

    private var model: KokoroModel?
    private var voice: MLXArray?

    /// `kokoro` is the directory the manifest's Kokoro entry fills (the config and the weights)
    /// and `g2p` the English phonemiser's, which sits where mlx-audio-swift's processor looks
    /// for it: under the Hugging Face cache root `ModelDownloads` points at the store.
    func load(kokoro: URL, g2p: URL) async throws {
        if model != nil { return }
        // Unbounded, MLX caches a Metal buffer for every tensor shape it has seen, and each
        // sentence length is a new set of shapes; the growth is what jetsams the app, with no
        // crash log. 64 MB keeps same-shape reuse and stops the climb.
        Memory.cacheLimit = 64 * 1024 * 1024
        // The processor's own check for a fetched repository wants a valid `config.json`
        // beside the weights, and this repository has none; without one it fetches the
        // repository again over a session of its own. An empty object satisfies it.
        let placeholder = g2p.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: placeholder.path) {
            try "{}".write(to: placeholder, atomically: true, encoding: .utf8)
        }
        // `fromModelDirectory` leaves the processor nil when none is passed, and a nil
        // processor tokenises the raw English as if it were IPA: it synthesises, badly, with
        // no error.
        let processor = KokoroMultilingualProcessor()
        try await processor.prepare(for: Self.language)
        let m = try await KokoroModel.fromModelDirectory(kokoro, textProcessor: processor)
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
