#if os(iOS)
import AVFoundation
import Observation
import TopoCore

/// Reads a reply aloud, wherever the process is: a reply to a spoken turn is heard whether the
/// phone is locked, pocketed or showing another app. What keeps the process there is the hold —
/// `AudioSession.Hold`, counted, answered by the play queue's keeper — which stands from the
/// release of the press until the reply has been read, one wait per turn said and not answered. Pressing the microphone stops a reply, so
/// the mic does not hear the speaker; so does the Stop item, a sign-out and a media services
/// reset. An interruption does not: iOS posts one at the lock screen with nothing in it, so a
/// `.began` marks the engine dead and leaves the hold standing, and the rebuild at `.ended` or at
/// the configuration change carries the reply on. No hold outlives its ceiling either way.
///
/// One voice. When the `Voice` (Pocket TTS, on the device) is resident, the reply is cut into
/// sentences, each synthesised behind the one before and pushed to the play queue frame by frame
/// as it decodes, paced by the queue's time-pitch unit at `Voice.tempo`, so what a listener waits
/// for is the first frame of the first sentence rather than the reply. A reply given to a voice
/// that is not resident is not spoken at all; the diagnostics `voice` row says why.
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
    /// True while the process is being held open for a reply, by either owner.
    var holding: Bool { audio.holding }
    #if DEBUG
    /// Whether the keeper's silence is rendering, and every transition it has made, for a test
    /// that holds the silence never stopped between two owners of the hold.
    var keeping: Bool { queue.keeping }
    var keeperTransitions: [String] { queue.keeperTransitions }
    #endif
    private var resetObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    /// How long a wait for a reply may keep the phone awake. A reply that never comes cannot hold
    /// the process open in a pocket; one slower than this is heard on the next foreground instead.
    /// The model call's own timeout is longer, so nothing is lost, only made to wait.
    private let ceiling: Duration
    /// One wait per spoken turn outstanding, by that turn's nonce, each counting down `ceiling`
    /// from its own release: a second thing said while the first is in flight is held for too,
    /// and the first being answered does not let go of the second.
    private var waits: [String: Task<Void, Never>] = [:]
    /// The same bound on the other owner, measured from the last frame scheduled or played back:
    /// a reply that is being heard keeps resetting it, and one that has stopped making progress
    /// — a dead engine nothing came back to rebuild — outlives its audio by `ceiling` at most.
    private var reading: Task<Void, Never>?
    /// Counts replies. A forward pass in flight does not notice a cancellation, so a frame
    /// carrying an older number is made and dropped.
    private(set) var generation = 0
    /// The tail of the synthesis chain: each sentence waits on the one in front of it, which is
    /// what keeps a reply in the order it was written though the sentences are made one at a time.
    private var chain: Task<Void, Never>?
    /// Sentences of the current reply not yet made.
    private var making = 0
    #if DEBUG
    /// What the last reply was and whether it was heard to the end, for the UI test.
    private(set) var report = Report()
    /// When the reply being read was handed to `speak`, which is what `Report.first` is measured
    /// from: what a listener waited, not what one sentence of it took.
    private var spokeAt: TimeInterval = 0
    /// The reply's audio so far and the time spent making it, summed over the sentences that
    /// made any. A sentence that scheduled no frame is in neither, so it moves no number.
    private var replySamples = 0
    private var replySynth: Double = 0
    #endif

    /// Reads the clock, so a test can drive the report's measurements rather than race them. The
    /// production clock is the continuous one, which a system-time step does not move.
    private let now: () -> TimeInterval

    init(audio: AudioSession, voice: Voice = Voice(), center: NotificationCenter = .default,
         makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
         ceiling: Duration = .seconds(120),
         now: @escaping () -> TimeInterval = PrimaryLease.continuousUptime) {
        self.audio = audio
        self.voice = voice
        self.ceiling = ceiling
        self.now = now
        queue = PlayQueue(makeEngine: makeEngine, center: center)
        queue.onDrained = { [weak self] in Task { @MainActor in self?.drained() } }
        queue.onPlayed = { [weak self] in Task { @MainActor in self?.progressed() } }
        // The queue rebuilds its engine on a configuration change, and a rebuilt engine under a
        // session that is not active is the crash rather than the silence, so the session is the
        // queue's first call there as it is everywhere else.
        queue.ensureActive = { [weak self] in try self?.audio.ensureActive() }
        queue.sessionFailed = { [weak self] in self?.audio.invalidate() }
        audio.onHoldChanged = { [weak self] held in self?.hold(held) }
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            let described = Self.describe(note)
            Task { @MainActor in
                guard let self else { return }
                switch type {
                case .began: self.interrupted(described)
                case .ended: self.resumeAudio("the interruption ended: \(described)")
                @unknown default: break
                }
            }
        }
    }

    /// The hold changed hands. The keeper is the play queue's silence: starting it needs the
    /// engine, and an engine under a session that is not active is the crash, so the session
    /// comes first here as in every other audio path and a refusal is a refusal.
    private func hold(_ held: Bool) {
        guard held else { queue.hold(false); return }
        do {
            try audio.ensureActive()
        } catch {
            AudioLog.say("the hold's session did not activate: \(error)")
            return
        }
        queue.hold(true)
    }

    /// An interruption began. What it is not is the end of the wait or of the reply: iOS posts
    /// one at the lock screen with no call and no Siri in it, and a hold dropped there is the
    /// process suspended with the reply unheard. It is the engine being dead — the player stops
    /// and the buffers nobody has heard are kept — and the hold stands until something rebuilds
    /// (`.ended`, or the configuration change a real interruption's end posts) or the ceiling
    /// runs out. Daphne's semantics, plus that bound.
    private func interrupted(_ described: String) {
        AudioLog.say("interruption began: \(described); the engine is dead, the hold stands")
        // Whoever interrupted took the session with the engine, so the next path configures and
        // activates it again rather than trusting the one this object last saw work.
        audio.invalidate()
        queue.interrupted()
    }

    /// Something says the audio can run again. The queue puts back what it owed on a fresh engine
    /// over a session activated first; a hold with no engine at all — a rebuild that was refused
    /// while a call was still up — gets one for its keeper. A refusal here leaves the hold
    /// standing and the keeper down, and the next `.ended`, configuration change or the ceiling
    /// is what answers for it.
    private func resumeAudio(_ why: String) {
        AudioLog.say(why)
        // Whether an engine exists is not the question: a rebuild refused earlier left none, and
        // what it owed is owed still. Anything owed or dead is rebuilt from nothing if need be.
        if queue.needsRebuild { queue.rebuild() }
        if audio.holding, !queue.keeping { hold(true) }
    }

    /// Everything the notification carries, since what iOS calls an interruption at the lock
    /// screen is what the next device run has to name.
    private nonisolated static func describe(_ note: Notification) -> String {
        let info = note.userInfo ?? [:]
        let type = (info[AVAudioSessionInterruptionTypeKey] as? UInt)
            .map { $0 == AVAudioSession.InterruptionType.began.rawValue ? "began" : "ended" } ?? "unknown"
        let reason = (info[AVAudioSessionInterruptionReasonKey] as? UInt).map { "\($0)" } ?? "none"
        let suspended = (info[AVAudioSessionInterruptionWasSuspendedKey] as? Bool).map { "\($0)" } ?? "none"
        let options = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { "\($0)" } ?? "none"
        return "type \(type), reason \(reason), wasSuspended \(suspended), options \(options)"
    }

    /// The release of a spoken press: hold the process open for the reply that is coming, so the
    /// turn is written, asked and answered behind the lock. Capped, and dropped the moment the
    /// reply is being read, the turn fails, or anything ends the reply. Nothing is held for a
    /// reply that could not be heard anyway — Read replies aloud off, or a voice that is not
    /// resident at the release — since those turns make no audio to keep the phone awake for.
    ///
    /// The answer is returned because it is the same answer to whether the turn is a spoken one:
    /// a turn recorded as spoken and never held for would be read aloud by some later launch that
    /// turned the setting on, so the caller records the mark from this and states no condition of
    /// its own.
    @discardableResult
    func awaitReply(_ nonce: String, readAloud: Bool) -> Bool {
        guard readAloud, voice.ready else {
            AudioLog.say("no wait held for \(nonce): \(readAloud ? "the voice is not resident" : "replies are not read aloud")")
            return false
        }
        waits[nonce]?.cancel()
        audio.wantAlive(true, for: .awaitingReply(nonce))
        waits[nonce] = Task { [ceiling] in
            try? await Task.sleep(for: ceiling)
            guard !Task.isCancelled else { return }
            self.endAwaiting(nonce, "capped at \(ceiling); the reply never landed")
        }
        return true
    }

    /// Lets go of one turn's wait. Free when that turn holds none.
    func endAwaiting(_ nonce: String, _ why: String) {
        guard let counting = waits.removeValue(forKey: nonce) else { return }
        counting.cancel()
        AudioLog.say("the wait for \(nonce)'s reply ends — \(why)")
        audio.wantAlive(false, for: .awaitingReply(nonce))
    }

    /// Lets go of every wait: the chat has stopped answering, or something ended things.
    func endAllWaits(_ why: String) {
        waits.keys.forEach { endAwaiting($0, why) }
    }

    /// iOS reset the media server: the reply stops, both holds go with it, and the play queue's
    /// nodes go too, since an engine that was running when the server went down will not start
    /// again. Nothing is built here; the next `speak` activates the session and the first frame
    /// builds the queue, which is how Say it again works after a reset with no press before it.
    /// A turn that was still awaited is answered on the next pass the app runs, on the foreground.
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

    /// Reads `text` aloud, and says whether it took the reply. A voice that is not resident, and
    /// a session that will not activate, each speak nothing, build nothing and answer false: the
    /// reply is still owed, its turn's wait still stands, and whoever holds the reply offers it
    /// again. The session comes first, before the queue exists: a player node spoken to under a
    /// session that is not active is the crash, not a silence.
    @discardableResult
    func speak(_ text: String, answering nonce: String? = nil) -> Bool {
        cancel()
        guard voice.ready else {
            #if DEBUG
            DebugRun.say("speak: not spoken — \(voice.summary)")
            #endif
            AudioLog.say("the reply was not taken: \(voice.summary)")
            return false
        }
        do {
            try audio.ensureActive()
        } catch {
            #if DEBUG
            DebugRun.say("speak: the audio session did not activate: \(error)")
            #endif
            AudioLog.say("the reply was not taken: the session did not activate: \(error)")
            done()
            return false
        }
        // A reply beginning on a queue nothing has rebuilt since an interruption: the session is
        // active again as of the line above, so this is where it comes back. Without it the
        // frames would be owed to a rebuild that may never come and the reply heard as silence.
        if queue.dead { queue.rebuild() }
        speaking = true
        // Taken before the wait is let go, so the keeper never stops between the two.
        audio.wantAlive(true, for: .speaking)
        progressed()
        nonce.map { endAwaiting($0, "the reply is being read") }
        audio.wantScreenAwake(true, for: .speaking)
        #if DEBUG
        report = Report(speaks: report.speaks + 1, engine: .pocket, text: text)
        spokeAt = now()
        replySamples = 0
        replySynth = 0
        DebugRun.say("speak: session ok, pocket")
        #endif
        speakLocally(text)
        return true
    }

    /// Ends things: a press, the Stop item, a sign-out, a reset, a reply that stopped making
    /// progress. Both holds go, since whatever was being waited for is not going to be heard now
    /// either.
    func stop() {
        cancel()
        endAllWaits("stopped")
    }

    /// Ends the reply in flight and leaves any wait standing, which is what `speak` needs: the
    /// reply about to be read replaces the one before it without the keeper stopping between them.
    private func cancel() {
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
                await self.say(sentence, generation: mine)
            }
        }
    }

    /// One sentence, frame by frame. The console line is per sentence; the report is per reply,
    /// and neither number in it is written by a sentence that scheduled no frame.
    private func say(_ sentence: String, generation mine: Int) async {
        let started = now()
        let idle = queue.isIdle
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
                guard !frame.samples.isEmpty else { continue }
                try queue.play(frame.samples, rate: frame.rate)
                progressed()
                if first == nil {
                    first = now() - started
                    #if DEBUG
                    report.started = true
                    // The reply's first frame, timed from `speak` and written once.
                    if report.first == nil { report.first = now() - spokeAt }
                    #endif
                }
            }
            // The stream ending is not the sentence still being this reply's: a `stop` while the
            // last frame was in flight leaves the measurements below belonging to a reply nobody
            // is hearing, and they would then time the next one.
            guard generation == mine else { return }
            #if DEBUG
            let seconds = now() - started
            let audio = Double(samples) / Double(rate)
            let words = sentence.split(separator: " ").count
            guard let first else {
                DebugRun.say(String(format: "voice: %@ synth=%.2fs made no audio words=%d",
                                    idle ? "ttfa" : "next", seconds, words))
                return
            }
            replySamples += samples
            replySynth += seconds
            report.rtf = replySynth / (Double(replySamples) / Double(rate))
            DebugRun.say(String(format: "voice: %@ synth=%.2fs first=%.2fs audio=%.2fs rtf=%.2f words=%d",
                                idle ? "ttfa" : "next", seconds, first, audio, seconds / audio, words))
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

    /// A frame was scheduled or heard: the reply is getting somewhere, so its bound starts again.
    private func progressed() {
        guard speaking else { return }
        reading?.cancel()
        reading = Task { [ceiling] in
            try? await Task.sleep(for: ceiling)
            guard !Task.isCancelled else { return }
            AudioLog.say("the reply made no progress for \(ceiling); it and its hold end")
            self.stop()
        }
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

    /// The reply is over, however it ended: nothing is being made and nothing is left to hear, so
    /// the screen and the process are let go. The queue draining between two sentences is not
    /// this — `made` and `drained` both have to agree before either calls it.
    private func done() {
        speaking = false
        reading?.cancel()
        reading = nil
        audio.wantScreenAwake(false, for: .speaking)
        audio.wantAlive(false, for: .speaking)
    }
}

#if DEBUG
extension Speaker {
    enum Engine: String, Codable { case pocket }

    /// The chat title's debug-only report of the last reply: how many replies `speak` has been
    /// given, which engine the last one took (`pocket`, the only one there is), its text, whether
    /// audio for it started (the first frame queued) and whether it came to its end rather than
    /// being stopped. `first` and `rtf` are the reply's, not a sentence's: seconds from `speak`
    /// to the reply's first frame being scheduled, and the time spent synthesising over the
    /// audio that made. Neither is ever a stand-in — `first` is written once, when that frame is
    /// scheduled, and is nil when no frame ever was; `rtf` is nil until then and counts only the
    /// sentences that scheduled one. The `voice:` console line carries the same two numbers per
    /// sentence, for a run that can read the console.
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
///
/// It also renders the silence that keeps the process running in the background: a second player
/// on the same engine, at no volume, looping a fifth of a second of zeroes for as long as a hold
/// stands. Under the `audio` background mode iOS runs a backgrounded process only while audio is
/// actually rendering, and between the release of a press and the first frame of the reply
/// nothing is. Lifted, with the rebuild below, from Daphne's `AudioIO` and `VoiceQueue`.
final class PlayQueue: @unchecked Sendable {
    /// Fires, on the audio thread, when every scheduled buffer has been heard.
    var onDrained: (@Sendable () -> Void)?
    /// Fires, on the audio thread, as each buffer is heard: the reply making progress.
    var onPlayed: (@Sendable () -> Void)?
    /// The session, before anything here touches a handle into mediaserverd. `Speaker` sets it;
    /// a rebuild that cannot activate the session builds nothing.
    var ensureActive: (@MainActor () throws -> Void)?
    /// Says the session is not what this object believed it was, after a refusal here. `Speaker`
    /// sets it; the next path activates rather than trusting what last worked.
    var sessionFailed: (@MainActor () -> Void)?
    #if DEBUG
    /// What the last rebuild put back, for a test that wants the number rather than the log.
    private(set) var rescheduled: Int?
    /// Every keeper transition, in the order it happened.
    private(set) var keeperTransitions: [String] = []
    #endif

    private var engine: AVAudioEngine?
    private let makeEngine: () -> AVAudioEngine
    private let center: NotificationCenter
    private var configurationObserver: NSObjectProtocol?
    private(set) var node: AVAudioPlayerNode?
    /// The silence. A second node rather than a quiet buffer on the first: what it renders must
    /// not come between two frames of the reply.
    private var keeper: AVAudioPlayerNode?
    /// True while something wants the process kept alive; the count itself is `AudioSession`'s.
    private var holding = false
    /// True from an interruption's `.began` until the queue is built again: iOS has stopped the
    /// engine, so a frame that arrives meanwhile is owed rather than played.
    private(set) var dead = false
    /// Between the player and the mixer: stage two of the pacing, for a voice with no pace of
    /// its own. `rate` stretches time and leaves the pitch where it was, so at `Voice.tempo` the
    /// words come faster without rising.
    private(set) var timePitch: AVAudioUnitTimePitch?
    private var format: AVAudioFormat?
    /// What the engine is built at. Remembered past a drop, so a rebuild with no engine left to
    /// read a format from still knows what to build.
    private var rate = Voice.rate
    private let lock = NSLock()
    /// What is scheduled and not yet heard, in the order it was scheduled, so a rebuild puts back
    /// what the dead engine forgot rather than only knowing how much there was.
    private var queued: [(era: Int, buffer: AVAudioPCMBuffer)] = []
    /// Bumped by `stop` and by a rebuild. Stopping the node fires the completion of every buffer
    /// it discards, and without this the count would run negative and the queue never read as
    /// drained — or a rebuild's rescheduled buffers would be cancelled by their own predecessors.
    private var epoch = 0

    var isIdle: Bool { lock.withLock { queued.isEmpty } }
    /// True while there is something a rebuild would put right: frames owed, or an engine marked
    /// dead. Whether an engine exists does not come into it — a refused rebuild drops the engine
    /// and keeps the owed frames, and the next attempt has to build one from nothing.
    var needsRebuild: Bool { dead || !isIdle }
    /// True while the silence is rendering, which is what a backgrounded process runs on.
    var keeping: Bool { keeper?.isPlaying ?? false }

    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
         center: NotificationCenter = .default) {
        self.makeEngine = makeEngine
        self.center = center
    }

    /// The engine, the player and the time-pitch unit are built on the first frame, because the
    /// sample rate is the synthesiser's to report, and left running between frames so nothing
    /// after the first pays for a route. Called on the main actor, as `reset()` is: the chain's
    /// tasks inherit `Speaker`'s, and these three and the format are guarded by that and not by
    /// the lock, which counts what is scheduled for the audio thread.
    @MainActor
    func play(_ samples: [Float], rate: Int) throws {
        guard !samples.isEmpty else { return }
        // While the engine is dead — from an interruption's `.began` until something rebuilds —
        // the frame is owed rather than played. Restarting a dead engine here throws, and the
        // throw reads to the voice as the sentence's end, so the rest of a sentence Pocket was
        // still yielding would be lost to an interruption nobody asked for.
        if !dead { try build(rate: rate) }
        guard let format, format.sampleRate == Double(rate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw VoiceError.noPlayer }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let era: Int = lock.withLock {
            queued.append((epoch, buffer))
            return epoch
        }
        guard !dead else { return }
        do {
            try start()
            guard let node else { throw VoiceError.noPlayer }
            if !node.isPlaying { node.play() }
            schedule(buffer, era: era)
        } catch {
            // The frame is already owed, so the reply is not lost with the engine: a refusal here
            // leaves it for the rebuild rather than reading to the voice as the sentence's end.
            refuse("a frame could not be played: \(error)")
        }
    }

    /// The engine, running. The one place it is started, so a start that throws is a refusal
    /// everywhere rather than a `try?` on one path and a throw on another.
    private func start() throws {
        guard let engine else { throw VoiceError.noPlayer }
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    /// Whatever went wrong, the answer is the same: no engine under a session that may be gone,
    /// the frames still owed, the queue still dead, and the session marked as needing activating
    /// again. The next `.ended`, configuration change or reply tries the whole thing afresh.
    @MainActor
    private func refuse(_ why: String) {
        AudioLog.say("the play queue refused: \(why)")
        drop()
        dead = true
        sessionFailed?()
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, era: Int) {
        node?.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            var played = false
            let done: Bool = self.lock.withLock {
                guard era == self.epoch else { return false }
                played = true
                if let index = self.queued.firstIndex(where: { $0.buffer === buffer }) {
                    self.queued.remove(at: index)
                }
                return self.queued.isEmpty
            }
            if done { self.onDrained?() } else if played { self.onPlayed?() }
        }
    }

    /// Builds the engine and its nodes if there are none, at `rate`. The one place they are made,
    /// so a frame and a hold build the same thing.
    private func build(rate: Int) throws {
        guard engine == nil else { return }
        guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                    channels: 1, interleaved: false) else { throw VoiceError.noPlayer }
        let e = makeEngine()
        let player = AVAudioPlayerNode()
        let silence = AVAudioPlayerNode()
        let unit = AVAudioUnitTimePitch()
        e.attach(player)
        e.attach(unit)
        e.attach(silence)
        e.connect(player, to: unit, format: f)
        e.connect(unit, to: e.mainMixerNode, format: f)
        e.connect(silence, to: e.mainMixerNode, format: f)
        unit.rate = Voice.tempo
        silence.volume = 0
        self.rate = rate
        engine = e
        node = player
        keeper = silence
        timePitch = unit
        format = f
        dead = false
        // The audio category flipping (the warm record claim going as the phone locks), a route
        // change, a call: each reconfigures the hardware, stops every engine in the process and
        // takes the buffers on its node with it. What was not heard is put back below.
        configurationObserver = center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: .main
        ) { [weak self, mine = ObjectIdentifier(e)] _ in
            Task { @MainActor in
                // The engine this observer was registered for, and not one dropped since: a
                // notification already on the queue when it went reaches nothing.
                guard let self, let engine = self.engine, ObjectIdentifier(engine) == mine else { return }
                self.rebuild()
            }
        }
    }

    /// Keeps the process alive, or lets it go. The engine is built here if the hold begins before
    /// the reply's first frame exists, which is the ordinary case: the wait for the reply is
    /// exactly the gap the keeper is for.
    @MainActor
    func hold(_ on: Bool) {
        holding = on
        guard on else { stopKeeper(); return }
        do {
            try build(rate: rate)
            try startKeeper()
        } catch {
            refuse("the keeper's engine: \(error)")
        }
    }

    /// Stops the silence, and says so only when there was some. Both the hold being let go and
    /// the engine being dropped come through here, so the transitions read in order.
    private func stopKeeper() {
        guard keeper?.isPlaying == true else { return }
        keeper?.stop()
        #if DEBUG
        keeperTransitions.append("stopped")
        #endif
        AudioLog.say("keeper stopped")
    }

    private func startKeeper() throws {
        try start()
        guard let keeper, let format else { throw VoiceError.noPlayer }
        guard !keeper.isPlaying,
              let quiet = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * 0.2))
        else { return }
        quiet.frameLength = quiet.frameCapacity
        keeper.scheduleBuffer(quiet, at: nil, options: .loops, completionHandler: nil)
        keeper.play()
        #if DEBUG
        keeperTransitions.append("playing")
        #endif
        AudioLog.say("keeper playing")
    }

    /// The engine stopped underneath and its node forgot what it held, or a refusal left no
    /// engine at all. Everything is built afresh at the rate it was built at, and what was not
    /// heard is scheduled again, in the order it was scheduled, under a new epoch so the
    /// discarded buffers' completions — which fire as if they had played — move nothing. The
    /// session comes first, as on every other audio path: a new engine under a session that is
    /// not active is a crash, not a silence. Every way this can fail ends at `refuse`, which
    /// keeps the owed frames and the dead mark, so nothing is stranded by a rebuild that could
    /// not happen yet — the next `.ended`, configuration change or reply tries again.
    @MainActor
    func rebuild() {
        let again: [AVAudioPCMBuffer] = lock.withLock {
            epoch += 1
            queued = queued.map { (epoch, $0.buffer) }
            return queued.map(\.buffer)
        }
        drop()
        dead = true
        do {
            try ensureActive?()
            try build(rate: rate)
            if !again.isEmpty {
                try start()
                guard let node else { throw VoiceError.noPlayer }
                node.play()
                let era = lock.withLock { epoch }
                for buffer in again { schedule(buffer, era: era) }
            }
            if holding { try startKeeper() }
        } catch {
            refuse("\(again.count) owed: \(error)")
            return
        }
        #if DEBUG
        rescheduled = again.count
        #endif
        AudioLog.say("play queue rebuilt: \(again.count) rescheduled, keeper \(holding ? "playing" : "idle")")
    }

    /// An interruption began: iOS has stopped the engine, and what it was playing is lost. The
    /// player and the keeper stop, the engine is left where it is so its configuration change
    /// still reaches this queue, and every buffer nobody has heard is carried into a new epoch,
    /// so the completions the stop fires move nothing and the rebuild has them to put back.
    @MainActor
    func interrupted() {
        let owed: Int = lock.withLock {
            epoch += 1
            queued = queued.map { (epoch, $0.buffer) }
            return queued.count
        }
        dead = true
        stopKeeper()
        node?.stop()
        engine?.stop()
        AudioLog.say("the play queue's engine is dead: \(owed) owed, waiting to be rebuilt")
    }

    /// Cuts what is playing and drops everything behind it. The keeper plays on: what it holds
    /// open is the wait, not the reply.
    @MainActor
    func stop() {
        lock.withLock {
            queued.removeAll()
            epoch += 1
        }
        node?.stop()
    }

    /// Stops, and drops the engine with its nodes, which cannot be attached to another: after a
    /// media services reset the old engine will not start, so the next `play` or hold builds
    /// afresh. Called on the main actor, as `play` is; the holds have been dropped before it.
    @MainActor
    func reset() {
        stop()
        holding = false
        dead = false
        drop()
    }

    /// Lets go of the engine and everything attached to it, leaving what is queued alone.
    private func drop() {
        stopKeeper()
        node?.stop()
        engine?.stop()
        if let configurationObserver { center.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine = nil
        format = nil
        node = nil
        keeper = nil
        timePitch = nil
    }
}
#endif
