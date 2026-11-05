#if os(iOS)
import Foundation
#if canImport(FluidAudio)
import FluidAudio
#endif

/// The end of an utterance, heard on the device: what lets an open microphone behind the lock
/// send a turn with no thumb to release it (`Conversation`). Two things listen. Silero's voice
/// activity detector through FluidAudio (`VadManager`), fed the microphone's samples at the ear's
/// rate in 256 ms chunks, says where speech starts and where it ends; FluidAudio's own streaming
/// segmentation holds an end back until `silence(judged:)` has passed with no speech. Topo's
/// policy over its events is `Policy`: a start shorter than `minSpeech` before its end is a
/// cough, not an utterance. And Smart Turn (`SmartTurn`), asked over the quiet after speech,
/// judges whether the utterance sounds finished; the rule over its verdicts is `Judging`.
///
/// Both models are fetched with the ear's (`ModelDownloads`, `ModelManifest.vad` and
/// `ModelManifest.smartTurn`) and asked for on every foreground (`prepare`, beside the ear's),
/// each loading once it is on disk, so each is normally loaded in front, where a model's first
/// load does not take the minutes it has behind the lock. Each has a state of its own, so a judge
/// that failed holds the detector back from nothing. `ready` is the detector loaded, not
/// downloaded, and nothing is carried until it is; the judge is not needed to carry a
/// conversation, whose utterances without one end on Silero's silence alone.
@MainActor
final class Endpoint {
    /// Silence after speech that ends an utterance in Silero's segmentation. With the judge
    /// loaded, Silero's end is the cap: 4 s of quiet ends the turn whatever the judge says, past
    /// which the model is outside its training data, and which ends a turn in a room too loud for
    /// `Judging`'s gate ever to call quiet. Without one, the window sits just past the 2 s that
    /// cut a speaker off mid-clause in Daphne. Chosen per conversation, as its detector is reset.
    nonisolated static func silence(judged: Bool) -> TimeInterval { judged ? 4.0 : 2.1 }
    /// Speech shorter than this between a start and its end is not an utterance.
    nonisolated static let minSpeech: TimeInterval = 0.25
    /// What the detector is fed at a time: 256 ms at the ear's rate, the model's own chunk.
    nonisolated static let chunk = 4096

    enum State: Equatable { case absent, fetching, loading, ready, failed }
    private(set) var state = State.absent
    private(set) var trouble: String?
    var ready: Bool { state == .ready }

    /// The judge's load, beside the detector's and independent of it.
    private(set) var judgeState = State.absent
    private(set) var judgeTrouble: String?

    private let load: @Sendable (URL) async throws -> any VoiceDetector
    private let loadJudge: @Sendable (URL) async throws -> any TurnJudge
    private(set) var detector: (any VoiceDetector)?
    private(set) var judge: (any TurnJudge)?

    init(load: @escaping @Sendable (URL) async throws -> any VoiceDetector = Endpoint.silero,
         loadJudge: @escaping @Sendable (URL) async throws -> any TurnJudge = { try await SmartTurn.loaded(from: $0) }) {
        self.load = load
        self.loadJudge = loadJudge
    }

    #if DEBUG
    /// A detector, and a judge or none, handed straight in, for the suite: ready at once.
    init(detector: any VoiceDetector, judge: (any TurnJudge)? = nil) {
        self.load = { _ in detector }
        self.loadJudge = { _ in throw Unavailable() }
        self.detector = detector
        self.judge = judge
        state = .ready
        judgeState = judge == nil ? .absent : .ready
    }
    #endif

    /// Asks for both models and loads each once it is on disk. Idempotent, called on every
    /// foreground beside the ear's, so a download or a load that failed is tried again.
    func prepare() {
        let downloads = ModelDownloads.shared
        downloads.start([ModelManifest.vad, ModelManifest.smartTurn])
        if state != .loading, state != .ready, state != .fetching {
            state = .fetching
            trouble = nil
            arrive(ModelManifest.vad, downloads) { [weak self] directory in
                guard let self, self.state == .fetching else { return }
                self.state = .loading
                let load = self.load
                Task {
                    do {
                        self.detector = try await load(directory)
                        self.state = .ready
                    } catch {
                        self.state = .failed
                        self.trouble = error.localizedDescription
                        AudioLog.say("the voice detector did not load: \(error.localizedDescription)")
                    }
                }
            } failed: { [weak self] why in
                self?.state = .failed
                self?.trouble = why
            }
        }
        if judgeState != .loading, judgeState != .ready, judgeState != .fetching {
            judgeState = .fetching
            judgeTrouble = nil
            arrive(ModelManifest.smartTurn, downloads) { [weak self] directory in
                guard let self, self.judgeState == .fetching else { return }
                self.judgeState = .loading
                let load = self.loadJudge
                Task {
                    do {
                        self.judge = try await load(directory)
                        self.judgeState = .ready
                        AudioLog.say("the turn's judge (Smart Turn) is loaded")
                    } catch {
                        self.judgeState = .failed
                        self.judgeTrouble = error.localizedDescription
                        AudioLog.say("the turn's judge did not load: \(error.localizedDescription)")
                    }
                }
            } failed: { [weak self] why in
                self?.judgeState = .failed
                self?.judgeTrouble = why
            }
        }
    }

    /// Runs `body` with a model's directory once it is on disk, or `failed` if the manifest
    /// cannot place it.
    private func arrive(_ id: String, _ downloads: ModelDownloads,
                        _ body: @escaping @MainActor (URL) -> Void, failed: @escaping @MainActor (String) -> Void) {
        downloads.whenPresent([id]) {
            do { body(try downloads.directory(for: id)) } catch { failed(error.localizedDescription) }
        }
    }

    /// The judge as the next conversation is to be judged by, and what its first line says.
    var judgeLine: String {
        if judge != nil { return "judging ends with Smart Turn" }
        let why = judgeTrouble.map { "\(judgeState), \($0)" } ?? "\(judgeState)"
        return "ending on \(Self.silence(judged: false)) s of silence alone (the judge: \(why))"
    }

    /// FluidAudio's loader, from the store's directory: it reads `<base>/Models/<repo folder>`,
    /// so it is handed the directory two above the one the store keeps the files in. Offline
    /// first, as `Ear` and `Voice` load, so a file not where the loader reads is a load failure
    /// rather than a download over a session of the library's own.
    nonisolated static func silero(_ directory: URL) async throws -> any VoiceDetector {
        #if canImport(FluidAudio)
        ModelHub.offlineMode = true
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

    /// Whether a frame is loud: over -38 dBFS of RMS, the onset Daphne's open microphone uses. A
    /// frame at or under it is quiet.
    nonisolated static func loud(_ frame: ArraySlice<Float>) -> Bool {
        guard !frame.isEmpty else { return false }
        let power = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)
        return 10 * log10(max(power, 1e-12)) > Judging.gateDB
    }

    /// Daphne's rule for when an open microphone's turn has ended (`ClaudeTurnController.sense`),
    /// over 100 ms frames of the utterance after speech: the judge is asked from 0.4 s of quiet
    /// and every 0.2 s after, one ask in flight at a time; a verdict over 0.85 is a vote, one at
    /// or under it sets the votes to none; two votes in a row end the turn, but never before the
    /// quiet has run the wait (`QuietWait`, read at each verdict); and 4 s of quiet ends it
    /// whatever the judge says. A loud frame sets the quiet to none and makes a verdict still in
    /// flight count for nothing; the votes are kept across it, as Daphne keeps them. Pure, so the
    /// suite drives it frame by frame.
    struct Judging: Equatable, Sendable {
        /// A frame, at the ear's rate: 100 ms.
        static let frame = Ear.rate / 10
        static let gateDB: Float = -38
        static let askFrom = 4
        static let askEvery = 2
        static let threshold: Float = 0.85
        static let votesToEnd = 2
        /// 4 s of quiet, in frames: the end whatever the judge says.
        static let cap = 40

        enum Ending: Equatable, Sendable {
            /// Two complete verdicts in a row, the last `p`, after `quiet` seconds of it.
            case judged(p: Float, quiet: TimeInterval)
            /// The cap, whatever the judge said.
            case quiet(TimeInterval)
        }

        enum Step: Equatable, Sendable {
            case none
            /// Ask the judge about the utterance so far; its verdict comes back as `verdict(_:ask:wait:)`.
            case ask(Int)
            case end(Ending)
        }

        private(set) var quietFrames = 0
        private(set) var votes = 0
        /// The ask whose verdict has not come back, whether it still counts or not.
        private(set) var inFlight: Int?
        /// The ask whose verdict counts: none once a loud frame has come since it was asked.
        private var current: Int?
        private var asked = 0
        /// The last verdict that counted, for the log.
        private(set) var lastVerdict: Float?

        var quiet: TimeInterval { Double(quietFrames) / 10 }

        mutating func frame(loud: Bool) -> Step {
            if loud {
                quietFrames = 0
                current = nil
                return .none
            }
            quietFrames += 1
            if quietFrames >= Self.cap { return .end(.quiet(quiet)) }
            guard quietFrames >= Self.askFrom, (quietFrames - Self.askFrom) % Self.askEvery == 0,
                  inFlight == nil else { return .none }
            asked += 1
            inFlight = asked
            current = asked
            return .ask(asked)
        }

        /// The judge's verdict on ask `ask`, judged against the wait as it is set now.
        mutating func verdict(_ p: Float, ask: Int, wait: TimeInterval) -> Step {
            if inFlight == ask { inFlight = nil }
            guard current == ask else { return .none }
            current = nil
            lastVerdict = p
            votes = p > Self.threshold ? votes + 1 : 0
            let waited = quietFrames >= Int((wait * 10).rounded())
            guard votes >= Self.votesToEnd, waited else { return .none }
            return .end(.judged(p: p, quiet: quiet))
        }

        /// Ask `ask` came back with no verdict (the judge threw): it counts for nothing, and the
        /// next ask may go.
        mutating func unanswered(ask: Int) {
            if inFlight == ask { inFlight = nil }
            if current == ask { current = nil }
        }
    }
}

/// How long a pause in a conversation behind the lock has to run before the judge's verdict may
/// end the turn: a short sentence sounds finished to it while the speaker is still thinking of
/// the next one. Set in the settings sheet and by the mind's `topo voice wait`, kept as the
/// `quietWait` default on this device, and read at each verdict, as Daphne reads it. Inside
/// `Judging`'s 4 s cap.
enum QuietWait {
    static let key = "quietWait"
    static let standard = 1.2
    static let range = 0.6...3.0
    /// The stepper's step, Daphne's.
    static let step = 0.2

    /// The wait as kept, or the standard one for a phone never asked and for anything kept that
    /// is not a number in the range.
    static func value(_ defaults: UserDefaults = .standard) -> TimeInterval {
        // A Boolean kept there is an `NSNumber` too, and is no wait.
        guard let kept = defaults.object(forKey: key) as? NSNumber,
              CFGetTypeID(kept) != CFBooleanGetTypeID() else { return standard }
        return judged(kept.doubleValue) ?? standard
    }

    /// A wait the rule can take, to a tenth of a second (a stepper's sums drift past the last
    /// place), or nil.
    static func judged(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        let tenths = (raw * 10).rounded() / 10
        guard range.contains(tenths) else { return nil }
        return tenths
    }

    static func said(_ value: Double) -> String { String(format: "%.1f", value) }
}

/// The detector as the endpoint asks it: Silero through FluidAudio in the app, a script in the
/// suite. `reset` begins a new stream, whose ends wait for `silence` with no speech; `feed` takes
/// one chunk of `Endpoint.chunk` samples.
protocol VoiceDetector: AnyObject, Sendable {
    func reset(silence: TimeInterval) async
    func feed(_ chunk: [Float]) async throws -> Endpoint.Event?
}

#if canImport(FluidAudio)
/// Silero's streaming segmentation, its state kept between chunks, ending speech only after the
/// silence its stream was reset with. FluidAudio's streaming path reads no `maxSpeechDuration`,
/// so a long utterance has no forced end.
actor SileroDetector: VoiceDetector {
    private let manager: VadManager
    private var stream: VadStreamState
    private var config = VadSegmentationConfig(minSilenceDuration: Endpoint.silence(judged: false))

    init(_ manager: VadManager) {
        self.manager = manager
        stream = VadStreamState.initial()
    }

    func reset(silence: TimeInterval) async {
        stream = VadStreamState.initial()
        config = VadSegmentationConfig(minSilenceDuration: silence)
    }

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
