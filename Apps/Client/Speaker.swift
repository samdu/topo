#if os(iOS)
import AVFoundation
import Observation

/// Reads a reply aloud. Speaking is foreground work: synthesis submits GPU commands and iOS kills
/// a backgrounded process that does, so the scene stops it on leaving the foreground. Pressing
/// the microphone stops it too, so the mic does not hear the speaker.
///
/// Two voices. When the `Voice` (Pocket TTS, on the device) is resident and the scene is active,
/// the reply is cut into sentences, each synthesised behind the one before, paced in two stages
/// (`PocketPace.trimGaps` on the buffer, then the queue's time-pitch unit at `Voice.tempo`) and
/// played the moment it exists, so what a listener waits for is the first sentence rather than
/// the reply. Otherwise the reply goes to `AVSpeechSynthesizer`, which takes neither stage. The
/// choice is made at `speak` and kept for the reply.
///
/// Every `speak` is a generation. A clip that lands after a `stop`, or a delegate callback for
/// an earlier utterance, belongs to no reply and changes nothing.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var speaking = false

    let voice: Voice
    private let audio: AudioSession
    /// Built at the first reply that needs it and dropped by a media services reset, which can
    /// swallow the old one's callbacks; nothing is built until the session is active again.
    private var synthesizer: AVSpeechSynthesizer?
    private let makeSynthesizer: () -> AVSpeechSynthesizer
    private let queue = PlayQueue()
    private var resetObserver: NSObjectProtocol?
    /// The utterance being read; a delegate callback for any other is an old one's and is ignored,
    /// so stopping A to say B does not drop B's claim when A's cancellation lands.
    private var current: AVSpeechUtterance?
    /// Counts replies on the voice's path. A forward pass in flight does not notice a
    /// cancellation, so a clip carrying an older number is made and dropped.
    private(set) var generation = 0
    /// The tail of the synthesis chain: each sentence waits on the one in front of it, which is
    /// what keeps a reply in the order it was written though the clips are made one at a time.
    private var chain: Task<Void, Never>?
    /// Sentences of the current reply not yet made.
    private var making = 0
    /// True while the scene is active; the scene sets it. A reply that starts while it is false
    /// goes to `AVSpeechSynthesizer`, since the voice is Metal work.
    var foreground = true
    #if DEBUG
    /// What the last reply was and whether it was heard to the end, for the UI test.
    private(set) var report = Report()
    #endif

    init(audio: AudioSession, voice: Voice = Voice(), center: NotificationCenter = .default,
         makeSynthesizer: @escaping () -> AVSpeechSynthesizer = { AVSpeechSynthesizer() }) {
        self.audio = audio
        self.voice = voice
        self.makeSynthesizer = makeSynthesizer
        super.init()
        queue.onDrained = { [weak self] in Task { @MainActor in self?.drained() } }
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
    }

    /// iOS reset the media server: the reply stops, since the callbacks that would end it may
    /// never come, and the synthesiser and the play queue's nodes go with it. Nothing is built
    /// here; the next `speak` activates the session and builds what its path needs, which is how
    /// Say it again works after a reset with no press before it.
    private func mediaServicesWereReset() {
        #if DEBUG
        DebugRun.say("media services reset: speaker stopped, synthesiser and play queue dropped")
        #endif
        stop()
        synthesizer = nil
        queue.reset()
    }

    /// Loads the voice's model, downloading it on the first run. Called on the foreground so it
    /// is resident by the first reply; idempotent.
    func prepare() { voice.prepare() }

    /// Reads `text` aloud. The session comes first, before either path exists: a synthesiser or
    /// a play queue spoken to under a session that is not active is the crash, not a silence.
    func speak(_ text: String) {
        stop()
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
        let local = voice.ready && foreground
        #if DEBUG
        report = Report(speaks: report.speaks + 1, engine: local ? .pocket : .system, text: text)
        DebugRun.say("speak: session ok, \(local ? "pocket" : "fallback")")
        #endif
        if local {
            speakLocally(text)
        } else {
            let synthesizer = self.synthesizer ?? {
                let made = makeSynthesizer()
                made.delegate = self
                self.synthesizer = made
                return made
            }()
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
                ?? AVSpeechSynthesisVoice(language: "en-GB")
            current = utterance
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        current = nil
        if synthesizer?.isSpeaking == true { synthesizer?.stopSpeaking(at: .immediate) }
        generation += 1
        chain = nil
        making = 0
        queue.stop()
        done()
    }

    /// The reply on the voice's path: one sentence at a time, each synthesised behind the one
    /// before and queued for playback as soon as it exists. A sentence the voice fails on is
    /// skipped rather than ending the reply.
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
                do {
                    let clip = try await self.voice.synthesise(sentence)
                    guard self.generation == mine else { return }
                    // Stage one of the pacing, on the buffer; stage two is the queue's unit.
                    try self.queue.play(PocketPace.trimGaps(clip.samples, rate: clip.rate), rate: clip.rate)
                    #if DEBUG
                    self.report.started = true
                    #endif
                } catch {}
            }
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

    /// The reply on the voice's path came to its end, rather than being stopped.
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

    private func done(_ utteranceID: ObjectIdentifier? = nil) {
        if let utteranceID, let current, utteranceID != ObjectIdentifier(current) { return }
        current = nil
        speaking = false
        audio.wantScreenAwake(false, for: .speaking)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in
            #if DEBUG
            if self.isCurrent(id) { self.report.finished = self.report.started }
            #endif
            self.done(id)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.done(id) }
    }

    #if DEBUG
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in if self.isCurrent(id) { self.report.started = true } }
    }

    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        current.map { ObjectIdentifier($0) == id } ?? false
    }
    #endif
}

#if DEBUG
extension Speaker {
    enum Engine: String, Codable { case pocket, system }

    /// The chat title's debug-only report of the last reply: how many replies `speak` has been
    /// given, which engine the last one took (`pocket`, the on-device voice, or `system`,
    /// `AVSpeechSynthesizer`), its text, whether audio for it started (the synthesiser's
    /// `didStart`, or the first clip queued on the voice's path) and whether it came to its end
    /// rather than being stopped.
    struct Report: Codable, Equatable {
        var speaks = 0
        var engine: Engine?
        var text = ""
        var started = false
        var finished = false
    }
}
#endif

/// Whatever the voice has made, in the order it was made, on one player node. A player node
/// with nothing scheduled renders silence rather than stopping and picks up the moment a buffer
/// arrives, so a sentence appended behind a playing one is seamless and one appended into an
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

    /// The engine, the player and the time-pitch unit are built on the first clip, because the
    /// sample rate is the synthesiser's to report, and left running between clips so no sentence
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
