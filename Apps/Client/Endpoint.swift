#if os(iOS)
import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// The end of an utterance, heard on the device: what lets an open microphone behind the lock
/// send a turn with no thumb to release it (`Conversation`). Silero's voice activity detector
/// through FluidAudio (`VadManager`), fed the microphone's samples at the ear's rate in 256 ms
/// chunks, says where speech starts and where it ends; FluidAudio's own streaming segmentation
/// holds an end back until `silence` has passed with no speech, so a pause shorter than that is
/// not an end at all. Topo's policy over its events is `Policy`: a start shorter than `minSpeech`
/// before its end is a cough, not an utterance.
///
/// The model is fetched with the ear's (`ModelDownloads`, `ModelManifest.vad`) and loaded on the
/// foreground with it (`VoiceInput.prepare`), never first behind the lock, where a model's first
/// load has taken minutes; `ready` is loaded, not downloaded.
@MainActor
final class Endpoint {
    /// Silence after speech that ends an utterance. Daphne ended turns at 1.2 s of quiet only
    /// with a Smart Turn model judging the sentence complete, and 2 s without that judgement cut
    /// a speaker off mid-clause; with no judge, the window sits just past it.
    nonisolated static let silence: TimeInterval = 2.1
    /// Speech shorter than this between a start and its end is not an utterance.
    nonisolated static let minSpeech: TimeInterval = 0.25
    /// What the detector is fed at a time: 256 ms at the ear's rate, the model's own chunk.
    nonisolated static let chunk = 4096

    enum State: Equatable { case absent, fetching, loading, ready, failed }
    private(set) var state = State.absent
    private(set) var trouble: String?
    var ready: Bool { state == .ready }

    private let load: @Sendable (URL) async throws -> any VoiceDetector
    private(set) var detector: (any VoiceDetector)?

    init(load: @escaping @Sendable (URL) async throws -> any VoiceDetector = Endpoint.silero) {
        self.load = load
    }

    #if DEBUG
    /// A detector handed straight in, for the suite: ready at once.
    init(detector: any VoiceDetector) {
        self.load = { _ in detector }
        self.detector = detector
        state = .ready
    }
    #endif

    /// Asks for the model and loads it once it is on disk. Idempotent, called on every
    /// foreground beside the ear's, so a download that failed is tried again.
    func prepare() {
        guard state != .loading, state != .ready else { return }
        let downloads = ModelDownloads.shared
        let id = ModelManifest.vad
        downloads.start([id])
        guard state != .fetching else { return }
        state = .fetching
        trouble = nil
        downloads.whenPresent([id]) { [weak self] in
            guard let self, self.state == .fetching else { return }
            do {
                let directory = try downloads.directory(for: id)
                self.state = .loading
                let load = self.load
                Task {
                    do {
                        let made = try await load(directory)
                        self.detector = made
                        self.state = .ready
                    } catch {
                        self.state = .failed
                        self.trouble = error.localizedDescription
                        AudioLog.say("the voice detector did not load: \(error.localizedDescription)")
                    }
                }
            } catch {
                state = .failed
                trouble = error.localizedDescription
            }
        }
    }

    /// FluidAudio's loader, from the store's directory: it reads `<base>/Models/<repo folder>`,
    /// so it is handed the directory two above the one the store keeps the files in.
    nonisolated static func silero(_ directory: URL) async throws -> any VoiceDetector {
        #if canImport(FluidAudio)
        let base = directory.deletingLastPathComponent().deletingLastPathComponent()
        return SileroDetector(try await VadManager(modelDirectory: base))
        #else
        throw Unavailable()
        #endif
    }

    struct Unavailable: Error {}

    /// What the detector says of a chunk: speech began, or speech ended, at a sample of the
    /// stream since its reset.
    enum Event: Equatable, Sendable {
        case start(Int)
        case end(Int)
    }

    /// What the conversation is told: an utterance has begun (the idle clock stops counting
    /// toward an end), or the utterance has ended and is to be sent.
    enum Heard: Equatable, Sendable { case speech, ended }

    /// Topo's policy over the detector's events. Pure, so the suite drives it with a script.
    struct Policy: Equatable, Sendable {
        private var startedAt: Int?
        /// Whether this utterance has held speech of `minSpeech` or more.
        private(set) var heardSpeech = false

        mutating func take(_ event: Event) -> Heard? {
            switch event {
            case .start(let at):
                startedAt = at
                return .speech
            case .end(let at):
                // An end with no start before it ends nothing.
                guard let start = startedAt else { return nil }
                startedAt = nil
                let long = Double(at - start) >= Endpoint.minSpeech * Double(Ear.rate)
                if long { heardSpeech = true }
                return heardSpeech ? .ended : nil
            }
        }

        /// Whether speech is going on, or this utterance has held any.
        var speaking: Bool { startedAt != nil || heardSpeech }
    }
}

/// The detector as the endpoint asks it: Silero through FluidAudio in the app, a script in the
/// suite. `reset` begins a new stream; `feed` takes one chunk of `Endpoint.chunk` samples.
protocol VoiceDetector: AnyObject, Sendable {
    func reset() async
    func feed(_ chunk: [Float]) async throws -> Endpoint.Event?
}

#if canImport(FluidAudio)
/// Silero's streaming segmentation, its state kept between chunks, ending speech only after
/// `Endpoint.silence` with none.
actor SileroDetector: VoiceDetector {
    private let manager: VadManager
    private var stream: VadStreamState
    private let config = VadSegmentationConfig(minSilenceDuration: Endpoint.silence)

    init(_ manager: VadManager) {
        self.manager = manager
        stream = VadStreamState.initial()
    }

    func reset() async { stream = VadStreamState.initial() }

    func feed(_ chunk: [Float]) async throws -> Endpoint.Event? {
        let result = try await manager.processStreamingChunk(chunk, state: stream, config: config)
        stream = result.state
        guard let event = result.event else { return nil }
        switch event.kind {
        case .speechStart: return .start(event.sampleIndex)
        case .speechEnd: return .end(event.sampleIndex)
        }
    }
}
#endif
#endif
