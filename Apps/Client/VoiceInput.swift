#if os(iOS)
import AVFoundation
import Observation

/// Push to talk: speech to text from the microphone between a press and a release, on the device
/// where it can be. Hold to talk and release to send; a tap (a press shorter than `tapLimit`)
/// opens the microphone until the next press. One object for the whole app, and one gate on its
/// microphone, enforced: a surface that presses while another holds it is refused, because two
/// gates on one input answer the same utterance twice; the two surfaces (first run, chat) are
/// never mounted together, and each cancels its own session on disappearing. The microphone is
/// asked for at the first press and nowhere earlier, and it is the only permission a press asks
/// for: recognition is the phone's own.
///
/// One ear, the `Ear` (Parakeet, on the device). A press while it is not resident is refused
/// with the ear's own words, before the audio session or the engine is touched, so a phone whose
/// models are still downloading says so rather than opening a microphone nothing will hear. A
/// session records the utterance at the ear's rate, glances at it every second for the caption,
/// and decodes the whole of it at the release; a decode that throws sends the caption, so
/// nothing said is dropped for it.
///
/// Every press is one session with a generation number. A release, a cancel or a second `end()`
/// that belongs to another generation does nothing, so nothing said in one session can become a
/// turn in the next, a session cannot be ended twice, and a press released while the permission
/// prompt is up starts no microphone.
@MainActor
@Observable
final class VoiceInput {
    enum Gate: Hashable { case firstRun, chat }

    /// A press shorter than this is a tap: it opens the microphone until the next press.
    static let tapLimit: TimeInterval = 0.4
    /// How often the caption is refreshed from the audio so far, on the ear's path.
    static let glanceEvery: Duration = .milliseconds(900)

    private(set) var listening = false
    /// What has been recognised so far in this session, as it comes.
    private(set) var text = ""
    private(set) var denied = false
    private(set) var owner: Gate?
    /// True while the microphone stays open after a tap, until the next press.
    private(set) var handsFree = false
    /// Presses that reached `begin`, whatever became of them, and sessions whose microphone
    /// ran, counted when the engine starts, so a press cancelled during the prompts or refused
    /// at the input is a press and not a session. The UI test reads both: the first proves a
    /// gesture was handled, the second that it opened the microphone.
    private(set) var presses = 0
    private(set) var sessions = 0
    /// Every release the gesture handed over, whatever it ended: with `presses`, what says a press
    /// was the microphone's from the thumb coming down to its going up.
    private(set) var releases = 0
    /// Why the last press started no microphone, in words; nil while it is running, and from
    /// the next press until that one is refused. The UI test reads it too, to tell a host with
    /// no input from a refusal that is a fault.
    private(set) var refusal: String?
    /// The refusal on a host whose audio session has no input right now: a Mac with no
    /// microphone running the simulator, or a session that is playback-only.
    static let noInput = "no audio input"
    /// Whether a press would open the microphone, read from the state as it is now rather than
    /// from what the last press did: the ear becoming resident undims the button with no press
    /// in between. `refusal` is the record of the last press and says why one was refused.
    var canListen: Bool { !denied && ear.ready }

    let ear: Ear
    private let audio: AudioSession
    /// Built at the press, once the session is active, and dropped by a media services reset or
    /// by a press that found the input dead: an engine outlives neither, and reading its input
    /// node before the session is active is what raises inside `installTap`.
    private var engine: AVAudioEngine?
    private let makeEngine: () -> AVAudioEngine
    /// The two formats the guard judges and the tap is installed with, read from the engine's
    /// input node in production and injected by the suite, which has no audio device to read one
    /// from.
    private let formats: (AVAudioEngine) -> (client: AVAudioFormat, hardware: AVAudioFormat)
    /// True while a tap is on the input node, so a teardown that installed none never reads
    /// `inputNode`, which creates the hardware input on its first read.
    private(set) var tapped = false
    /// The microphone's samples at the ear's rate, filled by the tap. Internal so the suite can
    /// hand a release an utterance on a host with no audio device.
    let sink = SampleSink()
    private var captioner: Task<Void, Never>?
    /// Counts sessions; everything asynchronous checks it belongs to the current one. Readable
    /// so the suite can drive a press under the generation the object is on.
    private(set) var generation = 0
    /// True from the press until the microphone is running: the permission prompts, mainly.
    private var starting = false
    /// True from a release until the session is torn down: the wait for the last word.
    private var ending = false
    private var pressedAt: Date?
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
         formats: @escaping (AVAudioEngine) -> (client: AVAudioFormat, hardware: AVAudioFormat)
             = VoiceInput.readFormats) {
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
        releases += 1
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
        defer { if generation == mine { starting = false } }
        // The microphone, and nothing else: the words are turned into text on this phone.
        guard await AVAudioApplication.requestRecordPermission() else {
            microphoneDenied()
            return
        }
        // Released or cancelled while the prompt was up: start nothing.
        guard generation == mine else { return }
        denied = false
        press(as: gate, mine: mine)
    }

    /// The microphone was refused at the prompt: the press is over, and the button stays dimmed
    /// until the person grants it in Settings and presses again. Internal rather than private so
    /// the suite can drive a denial without TCC.
    func microphoneDenied() {
        refusal = "no microphone permission"
        denied = true
        owner = nil
    }

    /// Everything after the permission prompt: the microphone if it can be opened, the refusal
    /// if it cannot. Internal rather than private so the suite can drive a press without TCC.
    func press(as gate: Gate, mine: Int) {
        // An ear that is not resident is the whole refusal, and it comes first: the audio
        // session, the engine and the input node are not touched for a press nothing can hear.
        // The ear's own words are the reason, which is what the diagnostics `speech` row shows.
        guard ear.ready else {
            refusal = ear.summary
            #if DEBUG
            DebugRun.say("press: \(refusal ?? "refused")")
            #endif
            owner = nil
            pressedAt = nil
            return
        }
        // The gate holds the microphone from here; `begin` has already said so, and a press the
        // suite drives straight in says it here.
        owner = gate
        do {
            try startMicrophone(as: gate, mine: mine)
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
    private func startMicrophone(as gate: Gate, mine: Int) throws {
        audio.wantRecord(true, for: gate == .chat ? .chat : .firstRun)
        do { try audio.ensureActive() } catch { throw SessionInactive(underlying: error) }
        let engine = engine ?? {
            let made = makeEngine()
            self.engine = made
            return made
        }()
        let input = engine.inputNode
        // Read once. The format the tap is installed with is the very object the guard judged:
        // a route change between two reads would pass the guard on the first numbers and raise
        // on the second, which is the crash this guard exists to answer.
        let (format, hardware) = formats(engine)
        let client = Format(format)
        #if DEBUG
        DebugRun.say("press: session ok, client \(client.rate)/\(client.channels), " +
                     "hardware \(hardware.sampleRate)/\(hardware.channelCount)")
        #endif
        // A dead format means the session has no input right now, and a tap rate that is not the
        // hardware's is the other way `installTap` raises; both are uncatchable, so refuse here.
        guard Self.inputIsUsable(client: client, hardware: Format(hardware)) else { throw InputUnavailable() }
        input.removeTap(onBus: 0)
        tapped = true
        #if DEBUG
        let meter = meter
        #endif
        let sink = sink
        sink.reset()
        // The tap block is `@Sendable`, and it is load-bearing: it runs on the audio thread, and
        // a closure formed on the main actor without it is main-actor-isolated by inference,
        // which Swift 6 opens with an executor check that traps off the main thread
        // (`dispatch_assert_queue` under `swift_task_isCurrentExecutor`), past any `catch`.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            #if DEBUG
            meter.record(buffer)
            #endif
            sink.append(buffer)
        }
        engine.prepare()
        try engine.start()
        listening = true
        sessions += 1
        audio.wantScreenAwake(true, for: .listening)
        startCaptions(for: mine)
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
    /// That is the whole utterance decoded, and where the decode throws it is the caption the
    /// glances left — which is empty when none of them got a word out. Empty when nothing was
    /// heard. Internal rather than private so the suite can drive a release without TCC.
    func end(as gate: Gate) async -> String {
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
                // Nothing said is dropped for a decode that failed: the caption stands in for
                // the utterance, and the diagnostics say why there was no better answer.
                #if DEBUG
                capture.recogniserError = "\(error)"
                #endif
                heard = text
            }
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

    /// The numbers one side of an input node reports, which is all the guard judges on.
    struct Format: Equatable {
        var rate: Double
        var channels: UInt32

        init(rate: Double, channels: UInt32) {
            self.rate = rate
            self.channels = channels
        }

        init(_ format: AVAudioFormat) {
            self.init(rate: format.sampleRate, channels: format.channelCount)
        }
    }

    /// The input node's two formats, the client one a tap is installed with and the hardware one
    /// behind it, as the objects themselves so the press hands the tap what the guard judged.
    /// Production reads them off the node; the suite injects them, since a test host has no audio
    /// device and a dead node is what the guard exists for.
    static let readFormats: (AVAudioEngine) -> (client: AVAudioFormat, hardware: AVAudioFormat) = { engine in
        let input = engine.inputNode
        return (input.outputFormat(forBus: 0), input.inputFormat(forBus: 0))
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
    /// at the ear's rate; `heard` is what the session heard; `ended` is how the session ended,
    /// and `recogniserError` is what the release's decode threw, when it threw.
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
    /// the ear's state, and what the last press's microphone delivered.
    struct Report: Codable, Equatable {
        var presses: Int
        var sessions: Int
        var releases = 0
        var refusal: String?
        var ear: String
        var capture: Capture
    }

    var debugReport: String {
        let report = Report(presses: presses, sessions: sessions, releases: releases, refusal: refusal,
                            ear: "\(ear.state)", capture: capture)
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
