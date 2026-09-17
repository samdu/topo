#if os(iOS)
import AVFoundation
import Observation

/// Reads a reply aloud. Speaking is foreground work: synthesis submits work to the audio engine
/// and iOS suspends a backgrounded process, so the scene stops it on leaving the foreground.
/// Pressing the microphone stops it too, so the mic does not hear the speaker.
///
/// One voice. When the `Voice` (Pocket TTS, on the device) is resident and the scene is active,
/// the reply is cut into sentences, each synthesised behind the one before and pushed to the play
/// queue frame by frame as it decodes, paced in two stages (`PocketPace` on the frames, then the
/// queue's time-pitch unit at `Voice.tempo`), so what a listener waits for is the first frame of
/// the first sentence rather than the reply. A reply given to a voice that is not resident, or to
/// a scene that is not active, is not spoken at all; the diagnostics `voice` row says which.
///
/// Every `speak` is a generation. A frame that lands after a `stop` belongs to no reply and
/// changes nothing.
@MainActor
@Observable
final class Speaker {
    private(set) var speaking = false

    let voice: Voice
    private let audio: AudioSession
    private let queue: PlayQueue
    private var resetObserver: NSObjectProtocol?
    /// Counts replies. A forward pass in flight does not notice a cancellation, so a frame
    /// carrying an older number is made and dropped.
    private(set) var generation = 0
    /// The tail of the synthesis chain: each sentence waits on the one in front of it, which is
    /// what keeps a reply in the order it was written though the sentences are made one at a time.
    private var chain: Task<Void, Never>?
    /// Sentences of the current reply not yet made.
    private var making = 0
    /// The loudest 20ms window the voice has made since launch, carried from one sentence to the
    /// next so a reply settles on one scale rather than judging each sentence on its own.
    private var loudest: Float = 0
    /// True while the scene is active; the scene sets it. A reply that starts while it is false
    /// is not spoken.
    var foreground = true
    #if DEBUG
    /// What the last reply was and whether it was heard to the end, for the UI test.
    private(set) var report = Report()
    #endif

    init(audio: AudioSession, voice: Voice = Voice(), center: NotificationCenter = .default,
         makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() }) {
        self.audio = audio
        self.voice = voice
        queue = PlayQueue(makeEngine: makeEngine)
        queue.onDrained = { [weak self] in Task { @MainActor in self?.drained() } }
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
    }

    /// iOS reset the media server: the reply stops, and the play queue's nodes go with it, since
    /// an engine that was running when the server went down will not start again. Nothing is
    /// built here; the next `speak` activates the session and the first frame builds the queue,
    /// which is how Say it again works after a reset with no press before it.
    private func mediaServicesWereReset() {
        #if DEBUG
        DebugRun.say("media services reset: speaker stopped, play queue dropped")
        #endif
        stop()
        queue.reset()
    }

    /// Loads the voice's model, downloading it on the first run. Called on the foreground so it
    /// is resident by the first reply; idempotent.
    func prepare() { voice.prepare() }

    /// Reads `text` aloud. A voice that is not resident and a scene that is not active each
    /// speak nothing and build nothing. The session comes first, before the queue exists: a
    /// player node spoken to under a session that is not active is the crash, not a silence.
    func speak(_ text: String) {
        stop()
        guard voice.ready, foreground else {
            #if DEBUG
            DebugRun.say("speak: not spoken — \(voice.ready ? "the scene is not active" : voice.summary)")
            #endif
            return
        }
        do {
            try audio.ensureActive()
        } catch {
            #if DEBUG
            DebugRun.say("speak: the audio session did not activate: \(error)")
            #endif
            done()
            return
        }
        speaking = true
        audio.wantScreenAwake(true, for: .speaking)
        #if DEBUG
        report = Report(speaks: report.speaks + 1, engine: .pocket, text: text)
        DebugRun.say("speak: session ok, pocket")
        #endif
        speakLocally(text)
    }

    func stop() {
        generation += 1
        chain = nil
        making = 0
        queue.stop()
        done()
    }

    /// The reply: one sentence at a time, each synthesised behind the one before and its frames
    /// queued for playback as soon as they exist. A sentence the voice fails on is skipped rather
    /// than ending the reply.
    private func speakLocally(_ text: String) {
        let sentences = Self.sentences(of: text)
        guard !sentences.isEmpty else { done(); return }
        let mine = generation
        making = sentences.count
        for sentence in sentences {
            let previous = chain
            chain = Task { [weak self] in
                await previous?.value
                guard let self, self.generation == mine else { return }
                defer { if self.generation == mine { self.made() } }
                guard self.foreground else { return }
                await self.say(sentence, generation: mine)
            }
        }
    }

    /// One sentence, frame by frame. The log line keeps `first`, the first frame's arrival, and
    /// `rtf`, the synthesis time over the audio made — the two numbers a device run is read on.
    private func say(_ sentence: String, generation mine: Int) async {
        let started = Date()
        let idle = queue.isIdle
        var trim = PocketPace(loudest: loudest)
        var first: Double?
        var samples = 0
        var rate = Voice.rate
        do {
            let frames = try await voice.synthesise(sentence)
            for try await frame in frames {
                // Leaving the loop cancels the synthesis behind it (the stream's termination
                // handler), so a stopped reply stops decoding rather than running to its end.
                guard generation == mine else { return }
                rate = frame.rate
                samples += frame.samples.count
                let out = trim.take(frame.samples, rate: frame.rate)
                guard !out.isEmpty else { continue }
                try queue.play(out, rate: frame.rate)
                if first == nil {
                    first = Date().timeIntervalSince(started)
                    #if DEBUG
                    report.started = true
                    #endif
                }
            }
            trim.finish()
            loudest = trim.loudest
            #if DEBUG
            let seconds = Date().timeIntervalSince(started)
            let audio = Double(samples) / Double(rate)
            report.first = first ?? seconds
            report.rtf = seconds / max(audio, 0.01)
            DebugRun.say(String(format: "voice: %@ synth=%.2fs first=%.2fs audio=%.2fs cut=%.2fs rtf=%.2f words=%d",
                                idle ? "ttfa" : "next", seconds, report.first ?? seconds, audio,
                                Double(trim.dropped) / Double(rate), report.rtf ?? 0,
                                sentence.split(separator: " ").count))
            #endif
        } catch {
            #if DEBUG
            DebugRun.say("voice: say failed — \(error.localizedDescription)")
            #endif
        }
    }

    /// One sentence is made, played or failed. The reply is over when nothing is left to make
    /// and nothing is left to hear; both halves have to agree, since the queue drains between
    /// two sentences and the last sentence is made while the queue is still full.
    private func made() {
        making -= 1
        if making == 0, queue.isIdle { finished() }
    }

    private func drained() {
        if making == 0 { finished() }
    }

    /// The reply came to its end, rather than being stopped.
    private func finished() {
        #if DEBUG
        report.finished = report.started
        #endif
        done()
    }

    /// The cut: sentence-final punctuation followed by whitespace, or a line break. Deliberately
    /// simple, because a cutter nobody can predict makes the same reply sound different twice.
    static func sentences(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            if character.isNewline || (character.isWhitespace && current.last.map { ".!?".contains($0) } == true) {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func done() {
        speaking = false
        audio.wantScreenAwake(false, for: .speaking)
    }
}

#if DEBUG
extension Speaker {
    enum Engine: String, Codable { case pocket }

    /// The chat title's debug-only report of the last reply: how many replies `speak` has been
    /// given, which engine the last one took (`pocket`, the only one there is), its text, whether
    /// audio for it started (the first frame queued) and whether it came to its end rather than
    /// being stopped. `first` and `rtf` are the last sentence's: seconds to its first frame, and
    /// its synthesis time over the audio it made — the same two numbers the `voice:` console
    /// line carries, so a lane that cannot read the console reads them here.
    struct Report: Codable, Equatable {
        var speaks = 0
        var engine: Engine?
        var text = ""
        var started = false
        var finished = false
        var first: Double?
        var rtf: Double?
    }
}
#endif

/// Whatever the voice has made, in the order it was made, on one player node. A player node
/// with nothing scheduled renders silence rather than stopping and picks up the moment a buffer
/// arrives, so a frame appended behind a playing one is seamless and one appended into an
/// empty queue simply starts talking.
final class PlayQueue: @unchecked Sendable {
    /// Fires, on the audio thread, when every scheduled buffer has been heard.
    var onDrained: (@Sendable () -> Void)?

    private var engine: AVAudioEngine?
    private let makeEngine: () -> AVAudioEngine
    private(set) var node: AVAudioPlayerNode?
    /// Between the player and the mixer: stage two of the pacing, for a voice with no pace of
    /// its own. `rate` stretches time and leaves the pitch where it was, so at `Voice.tempo` the
    /// words come faster without rising.
    private(set) var timePitch: AVAudioUnitTimePitch?
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var pending = 0
    /// Bumped by `stop`. Stopping the node fires the completion of every buffer it discards,
    /// and without this the count would run negative and the queue never read as drained.
    private var epoch = 0

    var isIdle: Bool { lock.withLock { pending == 0 } }

    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() }) {
        self.makeEngine = makeEngine
    }

    /// The engine, the player and the time-pitch unit are built on the first frame, because the
    /// sample rate is the synthesiser's to report, and left running between frames so nothing
    /// after the first pays for a route. Called on the main actor, as `reset()` is: the chain's
    /// tasks inherit `Speaker`'s, and these three and the format are guarded by that and not by
    /// the lock, which counts what is scheduled for the audio thread.
    func play(_ samples: [Float], rate: Int) throws {
        guard !samples.isEmpty else { return }
        if engine == nil {
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                        channels: 1, interleaved: false) else { throw VoiceError.noPlayer }
            let e = makeEngine()
            let player = AVAudioPlayerNode()
            let unit = AVAudioUnitTimePitch()
            e.attach(player)
            e.attach(unit)
            e.connect(player, to: unit, format: f)
            e.connect(unit, to: e.mainMixerNode, format: f)
            unit.rate = Voice.tempo
            engine = e
            node = player
            timePitch = unit
            format = f
        }
        guard let engine, let node, let format, format.sampleRate == Double(rate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw VoiceError.noPlayer }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !node.isPlaying { node.play() }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let era: Int = lock.withLock {
            pending += 1
            return epoch
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            let done: Bool = self.lock.withLock {
                guard era == self.epoch else { return false }
                self.pending -= 1
                return self.pending == 0
            }
            if done { self.onDrained?() }
        }
    }

    /// Cuts what is playing and drops everything behind it.
    func stop() {
        lock.withLock {
            pending = 0
            epoch += 1
        }
        node?.stop()
    }

    /// Stops, and drops the engine with its nodes, which cannot be attached to another: after a
    /// media services reset the old engine will not start, so the next `play` builds afresh.
    /// Called on the main actor, as `play` is.
    func reset() {
        stop()
        engine = nil
        format = nil
        node = nil
        timePitch = nil
    }
}
#endif
