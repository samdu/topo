#if os(iOS)
import AVFoundation
import Observation
import Speech

/// Push to talk: speech to text from the microphone between a press and a release, on the device
/// where it can be. Hold to talk and release to send; a tap (a press shorter than `tapLimit`)
/// opens the microphone until the next press. One object for the whole app, and one gate on its
/// microphone, enforced: a surface that presses while another holds it is refused, because two
/// gates on one input answer the same utterance twice; the two surfaces (first run, chat) are
/// never mounted together, and each cancels its own session on disappearing. Both permissions
/// are asked at the first press and nowhere earlier.
///
/// Two recognisers. When the `Ear` (Parakeet, on the device) is resident, the session records
/// the utterance at the ear's rate, glances at it every second for the caption and decodes the
/// whole of it at the release. Otherwise the session is `SFSpeechRecognizer`'s, on the device
/// where it supports that. The choice is made at the press and kept for the session, so a
/// model that becomes resident mid-utterance changes nothing until the next press. A local
/// decode that fails hands its audio to `SFSpeechRecognizer` rather than dropping it.
///
/// Every press is one session with a generation number. A release, a cancel, a late recogniser
/// callback or a second `end()` that belongs to another generation does nothing, so nothing said
/// in one session can become a turn in the next, a session cannot be ended twice, and a press
/// released while the permission prompts are up starts no microphone.
@MainActor
@Observable
final class VoiceInput {
    enum Gate: Hashable { case firstRun, chat }
    enum Recogniser { case parakeet, appleOnDevice, appleServer }

    /// A press shorter than this is a tap: it opens the microphone until the next press.
    static let tapLimit: TimeInterval = 0.4
    /// How long a release waits for `SFSpeechRecognizer`'s last word before sending what it has.
    static let finalWait: TimeInterval = 1
    /// How long a release waits for `SFSpeechRecognizer` to transcribe an utterance the ear
    /// failed on, before sending the caption it has.
    static let fallbackWait: TimeInterval = 10
    /// How often the caption is refreshed from the audio so far, on the ear's path.
    static let glanceEvery: Duration = .milliseconds(900)

    private(set) var listening = false
    /// What has been recognised so far in this session, as it comes.
    private(set) var text = ""
    private(set) var denied = false
    private(set) var owner: Gate?
    /// True while the microphone stays open after a tap, until the next press.
    private(set) var handsFree = false
    /// Which recogniser the current or last session used.
    private(set) var recogniser: Recogniser?
    /// Presses that reached `begin`, whatever became of them, and sessions whose microphone
    /// ran, counted when the engine starts, so a press cancelled during the prompts or refused
    /// at the input is a press and not a session. The UI test reads both: the first proves a
    /// gesture was handled, the second that it opened the microphone.
    private(set) var presses = 0
    private(set) var sessions = 0
    /// Why the last press started no microphone, in words; nil while it is running, and from
    /// the next press until that one is refused. The UI test reads it too, to tell a host with
    /// no input from a refusal that is a fault.
    private(set) var refusal: String?
    /// The refusal on a host whose audio session has no input right now: a Mac with no
    /// microphone running the simulator, or a session that is playback-only.
    static let noInput = "no audio input"
    /// True when recognition ran on the device; false when it went to Apple's servers.
    var onDevice: Bool { recogniser != .appleServer }
    /// Words a session heard before the recogniser ended it on its own (server recognition's
    /// one-minute cap in hands-free, a network or no-speech error), waiting for the owner to
    /// send them; `takeUnsent` hands them over. Nothing said is dropped for an error.
    private(set) var unsent: Unsent?

    struct Unsent: Equatable {
        var gate: Gate
        var text: String
    }

    let ear: Ear
    private let audio: AudioSession
    /// Built at the press, once the session is active, and dropped by a media services reset or
    /// by a press that found the input dead: an engine outlives neither, and reading its input
    /// node before the session is active is what raises inside `installTap`.
    private var engine: AVAudioEngine?
    private let makeEngine: () -> AVAudioEngine
    /// The two formats the guard judges, read from the engine's input node in production and
    /// injected by the suite, which has no audio device to read one from.
    private let formats: (AVAudioEngine) -> (client: Format, hardware: Format)
    /// True while a tap is on the input node, so a teardown that installed none never reads
    /// `inputNode`, which creates the hardware input on its first read.
    private(set) var tapped = false
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let sink = SampleSink()
    private var captioner: Task<Void, Never>?
    /// Counts sessions; everything asynchronous checks it belongs to the current one.
    private var generation = 0
    /// True from the press until the microphone is running: the permission prompts, mainly.
    private var starting = false
    /// True from a release until the session is torn down: the wait for the last word.
    private var ending = false
    private var pressedAt: Date?
    private var finalArrived = false
    private var interruptionObserver: NSObjectProtocol?
    private var resetObserver: NSObjectProtocol?
    #if DEBUG
    /// What reached the input tap, counted on the audio thread; `capture` is its snapshot.
    private let meter = TapMeter()
    /// What the last session's microphone delivered and what it was heard as, for the UI
    /// test: reset at every press, so a refused press reads as nothing delivered.
    private(set) var capture = Capture()
    #endif

    init(audio: AudioSession, ear: Ear = Ear(), center: NotificationCenter = .default,
         makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
         formats: @escaping (AVAudioEngine) -> (client: Format, hardware: Format) = VoiceInput.readFormats) {
        self.audio = audio
        self.ear = ear
        self.makeEngine = makeEngine
        self.formats = formats
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            // A call or Siri took the session; whatever was being said is over. Only the start
            // of an interruption: iOS posts its end seconds later, by which time a new session
            // may be up and is not to be cancelled for it.
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in self?.cancel() }
        }
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
    }

    /// iOS reset the media server: the engine's hardware input is gone. Whatever was being said
    /// is dropped, as for an interruption, and the engine goes with it. Nothing is built here —
    /// the next press reactivates the session and builds one, so recovery does not depend on a
    /// press coming before a reply.
    private func mediaServicesWereReset() {
        #if DEBUG
        DebugRun.say("media services reset: voice input cancelled and its engine dropped")
        #endif
        cancel()
        engine = nil
    }

    /// Loads the ear's models, downloading them on the first run. Called on the foreground so
    /// they are resident by the first press; idempotent.
    func prepare() { ear.prepare() }

    /// The thumb comes down for `gate`. Ends a hands-free session and returns what it heard, to
    /// be sent; otherwise starts a session and returns nil. Nothing happens for a press while
    /// another gate holds the microphone, while a release is still waiting for the last word, or
    /// when a permission is denied.
    func pressDown(as gate: Gate) async -> String? {
        if listening, owner == gate, handsFree { return await end(as: gate) }
        guard !listening, !starting, !ending else { return nil }
        pressedAt = Date()
        await begin(as: gate)
        return nil
    }

    /// The thumb comes up for `gate`. A hold ends and returns what it heard, to be sent; a tap
    /// leaves the microphone open and returns nil. A release while the permission prompts are
    /// still up cancels the press, so no microphone is left open with nobody holding it.
    func pressUp(as gate: Gate) async -> String? {
        if starting, owner == gate {
            generation += 1
            starting = false
            owner = nil
            return nil
        }
        guard listening, owner == gate, !ending else { return nil }
        if let pressedAt, Date().timeIntervalSince(pressedAt) < Self.tapLimit, !handsFree {
            handsFree = true
            return nil
        }
        return await end(as: gate)
    }

    /// The words kept from a session the recogniser ended, once; nil when there are none.
    func takeUnsent(for gate: Gate) -> String? {
        guard let unsent, unsent.gate == gate else { return nil }
        self.unsent = nil
        return unsent.text
    }

    /// The recogniser ended the session on its own: the words it heard are kept for the owner
    /// to send, and the microphone is released as on a release.
    private func endedByRecogniser(_ gate: Gate, error: String?) {
        #if DEBUG
        capture.ended = "recogniser"
        capture.recogniserError = error
        capture.heard = text
        #endif
        let heard = text
        generation += 1
        text = ""
        tearDown()
        if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            unsent = Unsent(gate: gate, text: heard)
        }
    }

    /// Stops listening and drops what was heard. Any gate's session, or `gate`'s only.
    func cancel(_ gate: Gate? = nil) {
        if let gate, owner != gate { return }
        generation += 1
        text = ""
        tearDown()
    }

    private func begin(as gate: Gate) async {
        presses += 1
        refusal = nil
        #if DEBUG
        capture = Capture()
        meter.reset()
        #endif
        generation += 1
        let mine = generation
        starting = true
        owner = gate
        text = ""
        handsFree = false
        finalArrived = false
        defer { if generation == mine { starting = false } }
        guard await AVAudioApplication.requestRecordPermission() else {
            refusal = "no microphone permission"
            denied = true; owner = nil; return
        }
        // Every block handed to the system from here is `@Sendable`, and it is load-bearing: TCC
        // answers this one on a global queue and the tap block below runs on the audio thread.
        // A closure formed on the main actor without `@Sendable` is main-actor-isolated by
        // inference, and Swift 6 opens it with an executor check that traps off the main thread
        // (`dispatch_assert_queue` under `swift_task_isCurrentExecutor`), which no `catch` sees.
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in c.resume(returning: status) }
        }
        // Released or cancelled while the prompts were up: start nothing.
        guard generation == mine else { return }
        guard speech == .authorized else {
            refusal = "no speech recognition permission"
            denied = true; owner = nil; return
        }
        // The session's recogniser, decided here and kept.
        let local = ear.ready
        if !local {
            guard let recognizer, recognizer.isAvailable else {
                refusal = "the speech recogniser is unavailable"
                denied = true; owner = nil; return
            }
            recogniser = recognizer.supportsOnDeviceRecognition ? .appleOnDevice : .appleServer
        } else {
            recogniser = .parakeet
        }
        denied = false
        press(as: gate, local: local, mine: mine)
    }

    /// Everything after the permission prompts: the microphone if it can be opened, the refusal
    /// if it cannot. Internal rather than private so the suite can drive a press without TCC.
    func press(as gate: Gate, local: Bool, mine: Int) {
        do {
            try startMicrophone(as: gate, local: local, mine: mine)
        } catch {
            // A session that would not activate and an input node whose formats are dead are both
            // the same situation: the handles this press holds are no good and must not be reused.
            let dead: Bool
            switch error {
            case is InputUnavailable:
                refusal = Self.noInput
                dead = true
            case let inactive as SessionInactive:
                refusal = "the audio session did not activate: \(inactive.underlying)"
                dead = true
            default:
                refusal = "the engine did not start: \(error)"
                dead = false
            }
            #if DEBUG
            DebugRun.say("press: \(refusal ?? "refused")")
            #endif
            owner = nil
            tearDown()
            audio.wantRecord(false, for: gate == .chat ? .chat : .firstRun)
            if dead {
                engine = nil
                audio.invalidate()
            }
        }
    }

    /// The press proper, once both permissions are in: everything that is a handle into
    /// mediaserverd, in the one order that is safe. The session is claimed and activated before
    /// an engine exists, the engine before its input node is read, and the formats before a tap
    /// is installed on them; a throw anywhere leaves the press refused with nothing running.
    private func startMicrophone(as gate: Gate, local: Bool, mine: Int) throws {
        audio.wantRecord(true, for: gate == .chat ? .chat : .firstRun)
        do { try audio.ensureActive() } catch { throw SessionInactive(underlying: error) }
        let engine = engine ?? {
            let made = makeEngine()
            self.engine = made
            return made
        }()
        let input = engine.inputNode
        let read = formats(engine)
        #if DEBUG
        DebugRun.say("press: session ok, client \(read.client.rate)/\(read.client.channels), " +
                     "hardware \(read.hardware.rate)/\(read.hardware.channels)")
        #endif
        // A dead format means the session has no input right now, and a tap rate that is not the
        // hardware's is the other way `installTap` raises; both are uncatchable, so refuse here.
        guard Self.inputIsUsable(client: read.client, hardware: read.hardware) else { throw InputUnavailable() }
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        tapped = true
        #if DEBUG
        let meter = meter
        #endif
        if local {
            let sink = sink
            sink.reset()
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                #if DEBUG
                meter.record(buffer)
                #endif
                sink.append(buffer)
            }
        } else {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.requiresOnDeviceRecognition = recogniser == .appleOnDevice
            self.request = request
            // The request is not Sendable, but `append` is made for the tap's thread: it is
            // the one call Apple's own push-to-talk sample makes from a tap block.
            nonisolated(unsafe) let fed = request
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
                #if DEBUG
                meter.record(buffer)
                #endif
                fed.append(buffer)
            }
        }
        engine.prepare()
        try engine.start()
        listening = true
        sessions += 1
        audio.wantScreenAwake(true, for: .listening)
        if local {
            startCaptions(for: mine)
        } else if let request, let recognizer {
            task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
                // The result is not Sendable; what the session reads of it crosses instead.
                let heard = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let failed = error != nil
                let failure = error.map { "\($0)" }
                Task { @MainActor in
                    guard let self, self.generation == mine else { return }
                    if let heard { self.text = heard }
                    if final { self.finalArrived = true }
                    if failed {
                        self.finalArrived = true
                        if !self.ending { self.endedByRecogniser(gate, error: failure) }
                    }
                }
            }
        }
    }

    /// The caption on the ear's path: every `glanceEvery`, the audio so far decoded bare, once
    /// there is a second of it and something new has arrived since the last glance.
    private func startCaptions(for mine: Int) {
        captioner = Task { [weak self] in
            var seen = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.glanceEvery)
                guard let self, self.generation == mine, self.listening, !self.ending else { return }
                let samples = self.sink.peek()
                guard samples.count > seen, samples.count > Ear.rate else { continue }
                seen = samples.count
                guard let heard = try? await self.ear.glance(samples),
                      self.generation == mine, !heard.isEmpty else { continue }
                self.text = heard
            }
        }
    }

    /// Ends the session and returns what was said; what arrives later belongs to no session.
    /// On the ear's path that is the whole utterance decoded, or the caption if even the
    /// fallback fails on it; on `SFSpeechRecognizer`'s, what it has once it has said its last
    /// word or `finalWait` has passed. Empty when nothing was heard.
    private func end(as gate: Gate) async -> String {
        guard listening, owner == gate, !ending else { return "" }
        ending = true
        let mine = generation
        captioner?.cancel()
        captioner = nil
        removeTap()
        if engine?.isRunning == true { engine?.stop() }
        var heard: String
        #if DEBUG
        capture.ended = "release"
        #endif
        if recogniser == .parakeet {
            let samples = sink.take()
            #if DEBUG
            capture.sunk = samples.count
            capture.sinkRMS = TapMeter.rms(samples)
            #endif
            if samples.isEmpty {
                heard = ""
            } else {
                do {
                    heard = try await ear.hear(samples)
                } catch {
                    heard = await appleTranscribe(samples) ?? text
                }
            }
        } else {
            request?.endAudio()
            let deadline = Date().addingTimeInterval(Self.finalWait)
            while !finalArrived, Date() < deadline, generation == mine {
                try? await Task.sleep(for: .milliseconds(50))
            }
            heard = text
        }
        #if DEBUG
        capture.heard = heard
        #endif
        guard generation == mine else { ending = false; return "" }
        generation += 1
        text = ""
        tearDown()
        ending = false
        return heard
    }

    /// The fallback for an utterance the ear failed on: the recorded samples through
    /// `SFSpeechRecognizer`, waited on for `fallbackWait`. Nil when it cannot run or says nothing.
    private func appleTranscribe(_ samples: [Float]) async -> String? {
        guard let recognizer, recognizer.isAvailable,
              let buffer = AVAudioPCMBuffer(pcmFormat: sink.format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData else { return nil }
        samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.append(buffer)
        request.endAudio()
        let heard: String? = await withCheckedContinuation { continuation in
            let done = Once(continuation)
            let task = recognizer.recognitionTask(with: request) { @Sendable result, error in
                if let result, result.isFinal { done.resume(result.bestTranscription.formattedString) }
                else if error != nil { done.resume(nil) }
            }
            Task {
                try? await Task.sleep(for: .seconds(Self.fallbackWait))
                task.cancel()
                done.resume(nil)
            }
        }
        guard let heard, !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return heard
    }

    /// A continuation resumed at most once, from whichever of the recogniser's callback and the
    /// timeout comes first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String?, Never>?
        init(_ continuation: CheckedContinuation<String?, Never>) { self.continuation = continuation }
        func resume(_ value: String?) {
            lock.withLock {
                continuation?.resume(returning: value)
                continuation = nil
            }
        }
    }

    private func removeTap() {
        guard tapped else { return }
        tapped = false
        engine?.inputNode.removeTap(onBus: 0)
    }

    /// Safe at any point, including after a start that never got going: the tap comes off
    /// whether or not the engine ran, so the next start does not install a second one.
    private func tearDown() {
        let gate = owner
        #if DEBUG
        capture.delivered(meter.snapshot())
        #endif
        captioner?.cancel()
        captioner = nil
        removeTap()
        if engine?.isRunning == true { engine?.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        sink.reset()
        listening = false
        starting = false
        ending = false
        handsFree = false
        owner = nil
        pressedAt = nil
        audio.wantScreenAwake(false, for: .listening)
        if let gate { audio.wantRecord(false, for: gate == .chat ? .chat : .firstRun) }
    }

    private struct InputUnavailable: Error {}
    /// `AudioSession.ensureActive` refused, carrying what it threw for the refusal line.
    private struct SessionInactive: Error { let underlying: Error }

    /// One side of an input node: what `outputFormat(forBus:)` or `inputFormat(forBus:)` says.
    struct Format: Equatable {
        var rate: Double
        var channels: UInt32
    }

    /// The input node's two formats, the client one a tap is installed against and the hardware
    /// one behind it. Production reads them off the node; the suite injects them, since a test
    /// host has no audio device and a dead node is what the guard exists for.
    static let readFormats: (AVAudioEngine) -> (client: Format, hardware: Format) = { engine in
        let input = engine.inputNode
        let client = input.outputFormat(forBus: 0)
        let hardware = input.inputFormat(forBus: 0)
        return (Format(rate: client.sampleRate, channels: client.channelCount),
                Format(rate: hardware.sampleRate, channels: hardware.channelCount))
    }

    /// Whether a tap may be installed, as a function of the four numbers alone. A zero sample
    /// rate or no channel on either side is a session with no input; a client rate that is not
    /// the hardware's is a conversion `installTap` refuses. Both refusals are raised as
    /// Objective-C exceptions no `catch` here would see, so they are answered before the call.
    static func inputIsUsable(client: Format, hardware: Format) -> Bool {
        client.rate > 0 && client.channels > 0
            && hardware.rate > 0 && hardware.channels > 0
            && client.rate == hardware.rate
    }
}

#if DEBUG
extension VoiceInput {
    /// What one session's microphone delivered. `buffers`, `frames` and `tapRMS` are counted
    /// in the tap block itself, so they are what the input actually handed over after the
    /// engine started, not that a tap was installed, and are taken at the teardown however the
    /// session ended; `sunk` and `sinkRMS` are what reached the sample sink at the ear's rate
    /// (the on-device branch only); `heard` is what the session heard; `ended` is "release" or
    /// "recogniser" (the recogniser ended it on its own, with `recogniserError` when it failed).
    struct Capture: Codable, Equatable {
        var buffers = 0
        var frames = 0
        var rate = 0.0
        var tapRMS = 0.0
        var sunk = 0
        var sinkRMS = 0.0
        var heard = ""
        var ended = ""
        var recogniserError: String?

        mutating func delivered(_ tap: Capture) {
            buffers = tap.buffers
            frames = tap.frames
            rate = tap.rate
            tapRMS = tap.tapRMS
        }
    }

    /// The button's debug-only accessibility value, which the UI test decodes: the counters,
    /// the ear's state, the branch the last press took, and what its microphone delivered.
    struct Report: Codable, Equatable {
        var presses: Int
        var sessions: Int
        var refusal: String?
        var ear: String
        var recogniser: String?
        var capture: Capture
    }

    var debugReport: String {
        let report = Report(presses: presses, sessions: sessions, refusal: refusal,
                            ear: "\(ear.state)", recogniser: recogniser.map { "\($0)" }, capture: capture)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(report)).flatMap { String(data: $0, encoding: .utf8) } ?? "unencodable"
    }
}

/// Counts what the input tap is handed, under a lock, from the audio thread.
final class TapMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var capture = VoiceInput.Capture()
    private var squares = 0.0

    func record(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        var sum = 0.0
        if let channel = buffer.floatChannelData {
            for i in 0..<frames { sum += Double(channel[0][i] * channel[0][i]) }
        }
        lock.withLock {
            capture.buffers += 1
            capture.frames += frames
            capture.rate = buffer.format.sampleRate
            squares += sum
            capture.tapRMS = capture.frames > 0 ? (squares / Double(capture.frames)).squareRoot() : 0
        }
    }

    func snapshot() -> VoiceInput.Capture { lock.withLock { capture } }

    func reset() {
        lock.withLock {
            capture = VoiceInput.Capture()
            squares = 0
        }
    }

    static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1 * $1) } / Double(samples.count)).squareRoot()
    }
}
#endif
#endif
