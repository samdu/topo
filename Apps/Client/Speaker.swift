#if os(iOS)
import AVFoundation
import Observation
import TopoCore

/// Reads a reply aloud, wherever the process is: a reply to a spoken turn is heard whether the
/// phone is locked, pocketed or showing another app. What keeps the process there is the hold —
/// `AudioSession.Hold`, counted, answered by the play queue's keeper — which stands from the
/// release of the press until the reply has been read, one wait per turn said and not answered. Pressing the microphone stops a reply — the
/// button is Stop while one is read, and a press on it opens nothing — so the mic does not hear
/// the speaker; so does the Stop item, a sign-out and a media services
/// reset. An interruption does not: iOS posts one at the lock screen with nothing in it, so a
/// `.began` marks the engine dead and leaves the hold standing, and the rebuild at `.ended` or at
/// the configuration change carries the reply on. No hold outlives its ceiling either way, while
/// no call is up (`attach`): under one the system holds the session and the card's hang-up is the bound.
///
/// One voice. When the `Voice` (Phonon, on the device) is resident, the reply is cut into
/// sentences, each synthesised behind the one before and pushed to the play queue frame by frame
/// as it decodes, paced by the queue's time-pitch unit at the speed setting (`VoiceSpeed`), so what a listener waits
/// for is the first frame of the first sentence rather than the reply. A reply given to a voice
/// that is not resident is not spoken at all; the diagnostics `voice` row says why. Nor is one
/// read into an open microphone: it waits until the microphone closes (`microphoneOpen`,
/// `microphoneClosed`).
///
/// Every `speak` is a generation. A frame that lands after a `stop` belongs to no reply and
/// changes nothing.
///
/// A sentence that stands for a code block ("See code block N.", `Speakable.Line.codeBlock`)
/// is a cue (`cue`) the moment it begins to be heard: its first frame is marked on the play queue,
/// and the mark fires when everything scheduled before that frame has been heard, which is when
/// the sentence starts. The transcript scrolls to the block, pulses its outline and sends Topo to
/// stand beside it from that value. A reply that is not read aloud makes none.
@MainActor
@Observable
final class Speaker {
    private(set) var speaking = false
    /// The code block the reply being read has just reached, with the reply it is in; nil until
    /// one has been. It is not cleared when the reply ends — a pulse that has played and a Topo
    /// who has gone are left as they are — and a reply read again reaches its blocks afresh.
    private(set) var cue: CodeBlockCue?
    /// Counts cues, so a block reached a second time is a new one.
    private var cues = 0
    /// The turn the reply being read is, which a cue names; nil for text that is no turn.
    private var reply: TurnRef?

    let voice: Voice
    private let audio: AudioSession
    private let queue: PlayQueue
    /// True while the process is being held open for a reply, by any owner.
    var holding: Bool { audio.holding }
    #if DEBUG
    /// Whether the keeper's silence is rendering, and every transition it has made, for a test
    /// that holds the silence never stopped between two owners of the hold.
    var keeping: Bool { queue.keeping }
    var keeperTransitions: [String] { queue.keeperTransitions }
    /// Whether the play queue's engine is running: what holds the process, the keeper being only
    /// what it renders.
    var running: Bool { queue.running }
    /// Whether the play queue is dead: its engine stopped under it, or a rebuild refused.
    var dead: Bool { queue.dead }
    #endif
    private var resetObserver: NSObjectProtocol?
    private var interruptionObserver: NSObjectProtocol?
    /// How long a wait for a reply may keep the phone awake. A reply that never comes cannot hold
    /// the process open in a pocket; one slower than this is heard on the next foreground instead.
    /// The model call's own timeout is longer, so nothing is lost, only made to wait.
    private let ceiling: Duration
    /// How many times a reply for this turn landed and was not taken, by nonce. Kept only so the
    /// ceiling's line can say what happened; forgotten with the wait.
    private var refusals: [String: Int] = [:]
    /// One wait per spoken turn outstanding, by that turn's nonce, each counting down `ceiling`
    /// from its own release: a second thing said while the first is in flight is held for too,
    /// and the first being answered does not let go of the second.
    private var waits: [String: Task<Void, Never>] = [:]
    /// The call a spoken exchange behind the lock is (`attach`): while it is up the wait for a
    /// reply is not capped, since the system holds the session for the call's length, and its
    /// hang-up is a mute. Nil where the app has not attached one.
    private(set) var call: SpokenCall?
    /// Whether a call can still be placed for this exchange: one is attached and none is on its
    /// way, up or closing. A release keeps its input for the placing only then (`MicPress`).
    var callIdle: Bool { call?.state == .idle }
    /// Told every hold change after this object has dealt with it, so the keeper comes first
    /// and whoever listens — the call's driver — second.
    var onHold: ((Bool) -> Void)?
    /// Told that the chat's microphone is opening (at the press, before any wait it ends) and
    /// that it has closed: a call kept up in front is kept while it is open (`SpokenCallDriver`),
    /// so the session the press opened on is not ended under it.
    var onMicrophone: ((Bool) -> Void)?
    /// The call's moments, told after the speaker has dealt with each — but for the placing,
    /// told first, so an open microphone is off the session before the session changes hands
    /// (`Conversation`).
    var onCall: ((CallMoment) -> Void)?
    enum CallMoment: Equatable { case placing, active, taken, hungUp, over, muted(Bool) }
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
    /// The reply being read while the guest is still writing it (`speak(writing:answering:)`):
    /// the spoken turn it answers, what of the reply had settled into sentences at the last
    /// call and how many of those are queued, and whether it is still being read. One that was
    /// stopped keeps its turn, so what is written after the stop is not read from the top.
    private var written: (nonce: String, settled: String, queued: Int, live: Bool)?
    /// A reply that landed while a microphone was open, to be read once it closes. Its wait stands
    /// until then, and the turn it is, whose code blocks it cues when it is read. One at most:
    /// each reply cuts off the one before it anyway.
    private var deferred: (text: String, nonce: String?, reply: TurnRef?)?
    /// The spoken turns whose failure has been cued, so one the harness tells of twice — at the
    /// guest's end and at the turn's — sounds once. Cleared as the wait ends.
    private var failedCued: Set<String> = []
    /// Whether the reply being read is a failed turn's: it ends with `failed` in place of `done`.
    private var readingFailed = false
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

    /// `heard` is what counts as a frame heard: played back through the hardware on a phone. An
    /// engine rendering offline in a test plays nothing back, and counts a frame rendered instead.
    init(audio: AudioSession, voice: Voice = Voice(), center: NotificationCenter = .default,
         makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
         ceiling: Duration = .seconds(120),
         now: @escaping () -> TimeInterval = PrimaryLease.continuousUptime,
         heard: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack,
         sounds: KeeperSounds? = nil, earcons: Earcons? = nil) {
        self.audio = audio
        self.voice = voice
        self.sounds = sounds
        self.earcons = earcons
        self.ceiling = ceiling
        self.now = now
        queue = PlayQueue(makeEngine: makeEngine, center: center, heard: heard)
        queue.onDrained = { [weak self] in Task { @MainActor in self?.drained() } }
        queue.onPlayed = { [weak self] in Task { @MainActor in self?.progressed() } }
        // The queue rebuilds its engine on a configuration change, and a rebuilt engine under a
        // session that is not active is the crash rather than the silence, so the session is the
        // queue's first call there as it is everywhere else.
        queue.ensureActive = { [weak self] in try self?.audio.ensureActive() }
        queue.sessionFailed = { [weak self] in self?.audio.invalidate() }
        audio.onHoldChanged = { [weak self] held in
            guard let self else { return }
            self.hold(held)
            self.onHold?(held)
        }
        // A cue is never played into an open microphone, and whether one is open or opening is
        // this object's answer.
        self.earcons?.microphoneOpen = { [weak self] in self?.microphoneBusy ?? false }
        // The voice is audible while it is reading and not in one of its gaps: the bed fills a
        // gap and never a sentence.
        sounds?.voiceSpeaking = { [weak self] in self.map { $0.speaking && !$0.voiceGap } ?? false }
        // Receipts sound into an open microphone, as Daphne's do: the conversation shuts its gate
        // under each, and with noise suppression on the input's voice processing ducks them. Whether
        // one is open or opening sets the working bed's level, asked rather than told at the press
        // alone.
        sounds?.microphoneOpen = { [weak self] in self?.microphoneBusy ?? false }
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

    /// Wires the call: the session's phase follows the call's callbacks (`AudioSession.callPlaced`
    /// and after), the queue comes back when the system activates the session and when the call
    /// is over with a hold still standing, and the card's hang-up is a mute. A call that fails
    /// leaves the hold standing and the keeper where the call left it: in front the resume
    /// brings it back, behind the lock the activation is refused and the reply is read on unlock.
    func attach(_ call: SpokenCall) {
        self.call = call
        call.onStart = { [weak self] in
            guard let self else { return }
            onCall?(.placing)
            // The bed's player is a handle on the session too: paused before the category
            // changes, kept wanted, and played again by the activation's resume.
            sounds?.pause("the call is being placed")
            // The session is the system's from here until it activates it: a frame scheduled
            // meanwhile would be heard twice once the activation's rebuild puts it back, so the
            // engine is dead and what is owed waits, as at an interruption.
            audio.callPlaced()
            queue.interrupted()
        }
        call.onActive = { [weak self] in
            guard let self else { return }
            audio.callActivated()
            resumeAudio("the call's session is active")
            // A reply that landed while the session was changing hands is read now.
            readWhatWaited()
            onCall?(.active)
        }
        call.onInactive = { [weak self] in
            guard let self else { return }
            // A phone call took the session with ours still standing: the engine is dead and
            // the hold stands, as at an interruption, until the system activates again.
            AudioLog.say("the call's session was taken; the engine is dead, the hold stands")
            sounds?.pause("the call's session was taken")
            audio.callDeactivated()
            queue.interrupted()
            onCall?(.taken)
        }
        call.onMute = { [weak self] in self?.onCall?(.muted($0)) }
        call.onHangUp = { [weak self] in
            self?.hangUp()
            self?.onCall?(.hungUp)
        }
        call.onClosing = { [weak self] in self?.audio.callClosing() }
        let over: (String) -> Void = { [weak self] why in
            guard let self else { return }
            defer { onCall?(.over) }
            // A call refused before the system performed its start never took the session: the
            // keeper is where it was, on a session that was never the system's.
            guard audio.call != .none else { return }
            // Before the call's end can hand the session back, which a player still running
            // on it would make a hand-back under live I/O.
            sounds?.pause("the call is over")
            audio.callOver()
            // The system's deactivation took the session with the engine on it: what is owed is
            // kept and the engine is rebuilt over a session activated afresh, in front where that
            // is allowed; behind the lock the activation is refused and the reply is read on unlock.
            queue.interrupted()
            if audio.holding { resumeAudio(why) }
            // A reply that waited for an activation that never came is read now, where the
            // session allows it, rather than left to its ceiling.
            readWhatWaited()
        }
        call.onOver = { over("the call is over with a hold standing") }
        call.onFailed = { why in over("the call failed (\(why)) with a hold standing") }
    }

    /// The card's hang-up: the person hung up on the reply, so it is not read, then or on
    /// unlock. Every awaited turn's spoken mark goes with its wait (`settled`, which the chat
    /// answers with `Harness.answeredAloud`, as a muted reply's is), and what is being read
    /// stops, as at the mute.
    func hangUp() {
        AudioLog.say("hung up from the call; the reply will not be read")
        // The reply being read as the guest writes it has no wait left (`begin` ended it) and
        // its mark still stands on disk: it goes the same way, or a relaunch reads it at unlock.
        var hung = Set(waits.keys)
        if let written, written.live { hung.insert(written.nonce) }
        for nonce in hung.sorted() {
            // What the guest writes of this turn from here is not read either: the chat's
            // writing path was told the turn was spoken when it began, and nothing tells it
            // otherwise until the turn ends.
            hungUp.insert(nonce)
            // A reply waiting for the activation is settled by `stop`, which drops it: once.
            if nonce != deferred?.nonce { settled?(nonce) }
        }
        stop()
    }

    /// The spoken turns hung up on whose turns have not ended: what the guest writes of them
    /// is not begun. Forgotten as each turn ends (`writingEnded`).
    private var hungUp: Set<String> = []

    /// The hold changed hands. The keeper is the play queue's silence: starting it needs the
    /// engine, and an engine under a session that is not active is the crash, so the session
    /// comes first here as in every other audio path and a refusal is a refusal.
    @discardableResult
    private func hold(_ held: Bool) -> Bool {
        guard held else { return queue.hold(false) }
        // Under the reset handler the engine is dead and the queue about to be dropped: a hold
        // change there (a wait ending while another hold stands) starts nothing.
        guard !resetting else { return false }
        do {
            try audio.ensureActive()
        } catch {
            // `ensureActive` leaves the session invalid, so the next path activates afresh.
            AudioLog.say("the play queue refused: the hold's session did not activate: \(error)")
            return false
        }
        return queue.hold(true)
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
        // The interruption stopped the bed too, and nothing else puts it back.
        sounds?.resume()
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

    /// A spoken turn sent: hold the process open for the reply that is coming, so the turn is
    /// written, asked and answered behind the lock, taking over from the release's hold. Capped, and dropped the moment the
    /// reply is being read, the turn fails, or anything ends the reply. Nothing is held for a
    /// reply that could not be heard anyway — replies muted, or a voice that is not
    /// resident at the release — since those turns make no audio to keep the phone awake for.
    ///
    /// The answer says both what was decided and what was achieved: `spoken` is whether the reply
    /// will be read aloud when it lands, which is what makes the turn a spoken one — the caller
    /// records the mark from it and states no condition of its own — and `held` is whether the
    /// keeper is actually rendering for it, or will be at the activation of a call being placed.
    /// A keeper that would not start is a refusal, not a hold, and is reported as one rather
    /// than left for the chat to believe in.
    @discardableResult
    func awaitReply(_ nonce: String, readAloud: Bool) -> Wait {
        // The release this turn was sent under is let go once its wait stands, or at once where
        // none is taken: from here the wait is what holds the process for the turn.
        defer { sending.map { released($0, "its turn's wait is taken") } }
        guard readAloud, voice.ready else {
            AudioLog.say("no wait held for \(nonce): \(readAloud ? "the voice is not resident" : "replies are not read aloud")")
            return Wait(spoken: false, held: false)
        }
        waits[nonce]?.cancel()
        audio.wantAlive(true, for: .awaitingReply(nonce))
        // Under a call on its way — asked of the system or placed by it — the keeper may be down
        // until the activation, whose resume starts it again for the holds standing: a wait taken
        // then is held, or the call it is placed for would end with nothing holding it.
        let placing = audio.call == .placed || call?.state == .starting
        if placing { AudioLog.say("the wait for \(nonce) is held for the call's activation") }
        guard queue.keeping || placing else {
            // The claim is one the process cannot honour: nothing is rendering, so nothing is
            // keeping it running, and saying otherwise would be a hold that exists only on paper.
            // The refusal itself is the queue's and is already logged there; what brought it down
            // is retried by the next rebuild, and the turn stays a spoken one either way.
            audio.wantAlive(false, for: .awaitingReply(nonce))
            waits[nonce] = nil
            AudioLog.say("the wait for \(nonce) is not held: nothing is rendering")
            return Wait(spoken: true, held: false)
        }
        waits[nonce] = ceilingWait(nonce)
        askForBed()
        return Wait(spoken: true, held: true)
    }

    /// One pass of the ceiling for the wait on `nonce`.
    private func ceilingWait(_ nonce: String) -> Task<Void, Never> {
        Task { [ceiling] in
            try? await Task.sleep(for: ceiling)
            guard !Task.isCancelled else { return }
            self.capped(nonce)
        }
    }

    /// What a release was answered with. The two are not the same answer: whether the reply will
    /// be read aloud when it lands, which is what makes the turn a spoken one and is true in the
    /// foreground whatever the audio is doing, and whether the process is actually being kept
    /// running for it, which is only true while the keeper is rendering.
    struct Wait {
        let spoken: Bool
        let held: Bool
    }

    /// The ceiling reached with the wait still standing. The line says which of the two ways that
    /// happens this was: a reply that never came, and one that landed every pass and was refused
    /// every pass, end the same wait, and only the count tells a run's log them apart. It is the
    /// ceiling's own path, and returns its line so a test reads what a run would.
    @discardableResult
    func capped(_ nonce: String) -> String {
        // Under a call the system holds the session for the call's length and the card's
        // hang-up is the bound, so the wait stands for another pass; the next ceiling asks again.
        if call?.up == true, waits[nonce] != nil {
            let line = "the ceiling passed under the call; the wait stands"
            AudioLog.say(line)
            waits[nonce] = ceilingWait(nonce)
            return line
        }
        let refused = refusals[nonce] ?? 0
        let what = refused == 0
            ? "the reply never landed"
            : "the reply landed and was not taken, \(refused) time\(refused == 1 ? "" : "s")"
        let line = "capped at \(ceiling); \(what)"
        endAwaiting(nonce, line)
        return line
    }

    /// The releases of spoken presses still being finished and sent, each with the task that
    /// lets it go at `releaseBound`.
    private var releases: [Int: Task<Void, Never>] = [:]
    private var releaseSerial = 0
    /// The release whose words are being sent right now (`sending(under:)`): set by the press's
    /// task just before its send, which reaches `awaitReply` before its first suspension, so the
    /// wait taken there is that release's turn's.
    private var sending: Int?
    /// How long a release holds the process without its turn's wait: the final transcription
    /// and the send's way to `awaitReply`, which take seconds, never this.
    static let releaseBound: Duration = .seconds(30)
    /// How a release waits out its bound; a test's clock in the suite.
    var releaseSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// The thumb has come up on a spoken press: the process is held from here, before the final
    /// transcription and the send, so a lock in between does not suspend it with the turn half
    /// made. Answers the release's token, or nil where the voice is not resident or no keeper is
    /// rendering. The token is let go by `awaitReply` once its turn's wait stands (the press's
    /// task names it with `sending(under:)` before the send), and otherwise by the press's task
    /// once its send returns, or at `releaseBound`. One per release, so two in flight are held
    /// for each.
    func releasing() -> Int? {
        guard voice.ready else { return nil }
        releaseSerial += 1
        let token = releaseSerial
        audio.wantAlive(true, for: .releasing(token))
        guard queue.keeping else {
            audio.wantAlive(false, for: .releasing(token))
            AudioLog.say("release \(token) is not held: nothing is rendering")
            return nil
        }
        let sleep = releaseSleep
        releases[token] = Task { [weak self] in
            try? await sleep(Self.releaseBound)
            guard !Task.isCancelled else { return }
            self?.released(token, "its bound ran out")
        }
        AudioLog.say("release \(token): held while its words are finished and sent")
        return token
    }

    /// Names the release whose words the next send carries, so `awaitReply` lets it go as the
    /// turn's wait is taken.
    func sending(under token: Int?) { sending = token }

    /// The releases still held, for a test.
    var releasesHeld: Int { releases.count }

    /// Lets go of a release's hold: its turn's wait is taken, its send returned without one, or
    /// its bound ran out. Free for one already let go.
    func released(_ token: Int, _ why: String) {
        if sending == token { sending = nil }
        guard let bound = releases.removeValue(forKey: token) else { return }
        bound.cancel()
        taken.remove(token)
        AudioLog.say("release \(token) let go: \(why)")
        // Before the hold drops, so the bed's fade-out is held through where this was the last.
        askForBed()
        audio.wantAlive(false, for: .releasing(token))
    }

    /// Lets go of one turn's wait. Free when that turn holds none.
    func endAwaiting(_ nonce: String, _ why: String) {
        refusals[nonce] = nil
        failedCued.remove(nonce)
        guard let counting = waits.removeValue(forKey: nonce) else { return }
        counting.cancel()
        AudioLog.say("the wait for \(nonce)'s reply ends — \(why)")
        // Before the hold drops, so the bed's fade-out is held through where this was the last.
        askForBed()
        audio.wantAlive(false, for: .awaitingReply(nonce))
    }

    /// A spoken turn failed for the person (`Harness.onTurnFailure`, through `SpokenReply.follow`):
    /// a wait standing for it sounds `failed`, once, before the wait ends, so the cue's hold is
    /// taken under the wait's; and a reply of it being read as it was written ends with `failed`
    /// in place of `done`, since what was heard was cut short. A turn no wait stands for and
    /// nobody is reading — a typed one — sounds nothing.
    func turnFailed(_ nonce: String) {
        if written?.nonce == nonce {
            readingFailed = true
            return
        }
        guard waits[nonce] != nil, !failedCued.contains(nonce) else { return }
        failedCued.insert(nonce)
        earcons?.play(.failed)
    }

    /// Lets go of every wait: the chat has stopped answering, or something ended things.
    func endAllWaits(_ why: String) {
        waits.keys.forEach { endAwaiting($0, why) }
    }

    /// iOS reset the media server: the keeper's sounds' players go first, so that nothing below
    /// finds a bed to fade; every release goes; the reply stops and every hold goes with it; the
    /// play queue's nodes go too, since an engine that was running when the server went down will
    /// not start again; and then the keeper's sounds' own hold, and the cues' players and the
    /// cue's hold. Nothing is built or started here: a hold change under the handler re-notifies
    /// `hold(true)` while another hold still stands, and `resetting` keeps that from starting the
    /// keeper on the dead engine. The next `speak` activates the session and the first frame
    /// builds the queue, which is how Say it again works after a reset with no press before it.
    /// A turn that was still awaited is answered on the next pass the app runs, on the foreground.
    private func mediaServicesWereReset() {
        #if DEBUG
        DebugRun.say("media services reset: speaker stopped, play queue dropped")
        #endif
        resetting = true
        defer { resetting = false }
        sounds?.dropPlayers()
        // Every release goes, so none outlives the queue the reset drops.
        releases.keys.forEach { released($0, "the media server was reset") }
        stop()
        queue.reset()
        sounds?.letGo("the media server was reset")
        earcons?.mediaServicesWereReset()
    }

    /// True while the media-services-reset handler runs: no hold change under it may touch the
    /// engine the reset killed.
    private var resetting = false

    /// Loads the voice's model, downloading it on the first run. Called on the foreground so it
    /// is resident by the first reply; idempotent.
    func prepare() { voice.prepare() }

    /// Reads `text` aloud, and says whether it took the reply. `reply` is the turn the text is,
    /// which the cues of its code blocks name (`cue`). A voice that is not resident, and
    /// a session that will not activate, each speak nothing, build nothing and answer false: the
    /// reply is still owed, its turn's wait still stands, and whoever holds the reply offers it
    /// again. The session comes first, before the queue exists: a player node spoken to under a
    /// session that is not active is the crash, not a silence.
    @discardableResult
    func speak(_ text: String, answering nonce: String? = nil, reply: TurnRef? = nil) -> Bool {
        // The reply to a turn whose reading began while it was written: what is not yet queued
        // of it is queued behind what is, and nothing is read twice. One stopped meanwhile was
        // stopped, and is not read again.
        if let written, let nonce, written.nonce == nonce {
            self.written = nil
            guard written.live else { return true }
            self.reply = reply
            enqueue(Array(Self.spoken(text).dropFirst(written.queued)))
            if making == 0, queue.isIdle { finished() }
            return true
        }
        written = nil
        return begin(text, answering: nonce, reply: reply, reading: true)
    }

    /// What the guest has written so far of the reply to the spoken turn `nonce`: every message
    /// of the turn's words, each call's text extending the last's (`Harness.follow`).
    /// The sentences that have settled (`settled`) are read as they come, behind one another,
    /// so the voice starts at the first sentence rather than once the reply is whole and in the
    /// log; `speak` is still called with the reply when it lands, and reads what is left. The
    /// guest's next message of the turn is more of the same text after a paragraph break, so
    /// its sentences are read behind the last message's, each once. Nothing begins while a microphone
    /// is open or the voice is not resident: the reply is offered whole when it lands, as ever.
    func speak(writing text: String, answering nonce: String) {
        guard !hungUp.contains(nonce) else { return }
        let settled = Self.settled(text)
        if written?.nonce != nonce {
            guard !settled.isEmpty, !replyMustWait, voice.ready,
                  begin(settled, answering: nonce, reply: nil, reading: false) else { return }
            written = (nonce, "", 0, true)
        }
        guard var reading = written, reading.live else { return }
        if !settled.hasPrefix(reading.settled) { reading.queued = 0 }
        let sentences = Self.spoken(settled)
        reading.settled = settled
        if sentences.count > reading.queued {
            enqueue(Array(sentences.dropFirst(reading.queued)))
            reading.queued = sentences.count
        }
        written = reading
    }

    /// The turn `nonce` is being answered no longer and no reply landed: what is queued is read
    /// out, and nothing more is waited for.
    func writingEnded(_ nonce: String) {
        hungUp.remove(nonce)
        guard let reading = written, reading.nonce == nonce else { return }
        written = nil
        if reading.live, making == 0, queue.isIdle { finished() }
    }

    /// A reply taken to be read: the session, the queue and the holds, as `speak` documents.
    /// `reading` reads `text` from here; without it the caller queues the sentences itself.
    private func begin(_ text: String, answering nonce: String?, reply: TurnRef?, reading: Bool) -> Bool {
        cancel()
        readingFailed = false
        guard voice.ready else {
            #if DEBUG
            DebugRun.say("speak: not spoken — \(voice.summary)")
            #endif
            AudioLog.say("the reply was not taken: \(voice.summary)")
            nonce.map { refusals[$0, default: 0] += 1 }
            return false
        }
        // Taken, and read once the microphone closes or the call's session is activated
        // (`readWhatWaited`), with nothing touched before then: no session, no queue, and the
        // turn's wait left standing.
        if replyMustWait {
            deferred = (text, nonce, reply)
            let why = microphoneBusy ? "the microphone to close" : "the call's session to be activated"
            #if DEBUG
            DebugRun.say("speak: waiting for \(why)")
            #endif
            AudioLog.say("the reply waits for \(why)")
            return true
        }
        do {
            try audio.ensureActive()
        } catch {
            #if DEBUG
            DebugRun.say("speak: the audio session did not activate: \(error)")
            #endif
            AudioLog.say("the reply was not taken: the session did not activate: \(error)")
            nonce.map { refusals[$0, default: 0] += 1 }
            done()
            return false
        }
        // A reply beginning on a queue nothing has rebuilt since an interruption: the session is
        // active again as of the line above, so this is where it comes back. Without it the
        // frames would be owed to a rebuild that may never come and the reply heard as silence.
        // A rebuild that refuses is a refused reply, like an activation that throws: an engine
        // that would not start renders nothing, and taking the reply here would clear its mark
        // and end its wait for a reading that never happens.
        if queue.dead, !queue.rebuild() {
            AudioLog.say("the reply was not taken: the play queue could not be rebuilt")
            nonce.map { refusals[$0, default: 0] += 1 }
            done()
            return false
        }
        speaking = true
        // A reply to a spoken turn is quiet until its first frame, and the bed fills that; a
        // replay, which answers no turn, has no bed under it at all.
        answering = nonce != nil
        voiceGap = answering
        Perf.mark("speak.begin")
        // Taken before the wait is let go, so the keeper never stops between the two.
        audio.wantAlive(true, for: .speaking)
        // And a hold that could not be honoured is a refused reply, like a rebuild that refuses:
        // an engine that would not start renders nothing, so taking the reply here would clear
        // its turn's mark and end its wait for a reading that never happens.
        guard queue.keeping else {
            AudioLog.say("the reply was not taken: nothing is rendering for it")
            nonce.map { refusals[$0, default: 0] += 1 }
            done()
            return false
        }
        progressed()
        // Where and how loud the reply is about to be heard, so a run that sounded quiet says
        // which of the session's states it was read under: the call's or not, its mode, the
        // voice processing the session is configured for, the route and the system's volume.
        AudioLog.say("the reply begins (\(audio.describeOutput()))")
        nonce.map { endAwaiting($0, "the reply is being read") }
        audio.wantScreenAwake(true, for: .speaking)
        #if DEBUG
        report = Report(speaks: report.speaks + 1, engine: .phonon, text: text)
        spokeAt = now()
        replySamples = 0
        replySynth = 0
        DebugRun.say("speak: session ok, phonon")
        #endif
        self.reply = reply
        if reading { speakLocally(text) }
        return true
    }

    /// Ends things: a press, the Stop item, a sign-out, a reset, a reply that stopped making
    /// progress. The waits and the reading's hold go, since whatever was being waited for is not
    /// going to be heard now either; a release stands, since the words it is finishing are still
    /// sent, and goes at its turn's wait.
    func stop() {
        cancel()
        endAllWaits("stopped")
    }

    /// The keeper's sounds (`KeeperSounds`): the bed wherever a turn's hold stands and the voice
    /// is not heard (`askForBed`), dipped while a microphone is open, paused while the call's
    /// session changes hands, and back at an interruption's end and the call's activation
    /// (`resumeAudio`). The
    /// app's to give; a speaker given none sounds nothing, which is every suite's but theirs.
    let sounds: KeeperSounds?

    /// A press was released with `heard` to send: heard behind a turn still on its way it bleeps
    /// (`queue`, Daphne's for a press held behind a turn in flight), and that is the release's
    /// one sound; otherwise the cues say it was sent, or that nothing was heard.
    func sounded(release heard: String) {
        if !heard.isEmpty, turnOnItsWay(), sounds?.queued() == true { return }
        earcons?.play(.sending(heard))
    }

    /// Whether a turn is on its way, asked at a release: the harness's (`Harness.turnOnItsWay`),
    /// which the press leaves standing, and not this object's waits, which the press ends. The
    /// app answers; a speaker told nothing has none.
    var turnOnItsWay: @MainActor () -> Bool = { false }

    /// Whether a hands-free conversation is on (`Conversation`, which sets it): a reply heard out
    /// under one ends on the conversation's go-ahead rather than `done`, where the go-ahead can
    /// sound (`KeeperSounds.saysGoAhead`).
    var conversing = false
    /// Whether the reply being read is a spoken turn's, which is what the bed fills the voice's
    /// gaps for: a replay answers no turn and gets none.
    private var answering = false
    /// The voice's gap inside a reading of a spoken turn's reply: from `begin` to the first
    /// frame, and again from the moment the voice has said everything it has with the guest
    /// still writing — the guest at its tools — to the next frame scheduled. A drain with a
    /// sentence still being made is the pause between two sentences, not a gap.
    private(set) var voiceGap = false
    /// The releases whose utterance `VoiceInput` has taken (`utteranceTaken`): only those want
    /// the bed, so its onset is never in input still being collected.
    private var taken: Set<Int> = []

    /// The cues a spoken exchange sounds (`Earcons`), on this speaker's session: the chat's press
    /// plays the microphone's and the release's, this object plays `done` as a reply ends, or `failed` for one its turn's failure cut short. The
    /// app's to give; a speaker given none sounds nothing, which is every suite's but the cues' own.
    let earcons: Earcons?

    /// Whether a microphone is open, asked at every `speak`. A reply is never read into one: the
    /// microphone would hear it, and the turn being said would carry Topo's words. The app answers
    /// with `VoiceInput.listening`.
    var microphoneOpen: @MainActor () -> Bool = { false }

    /// The presses opening a microphone: counted at the press, before `VoiceInput` has awaited
    /// the permission prompt or the call's session or started anything, so a reply landing in
    /// between waits as it would for one already open, and counted off by `microphoneOpened`. A
    /// count, not a flag: a press released while it waited is answered after the press that
    /// followed it has begun opening, and its answer is not that one's.
    private var openings = 0

    /// Told the nonce of a spoken turn whose reply waited for the microphone, once that reply has
    /// been taken or dropped. Until then its turn stays marked spoken (`Harness.answeredAloud` is
    /// held back), so a reply the session refused at the release is still owed.
    var settled: (@MainActor (String) -> Void)?

    /// A reply is waiting for the microphone to close.
    var waitingForMicrophone: Bool { deferred != nil }

    /// Whether a wait stands for the spoken turn `nonce`.
    func isAwaiting(_ nonce: String) -> Bool { waits[nonce] != nil }

    /// Whether any spoken turn's wait stands.
    var awaitingAny: Bool { !waits.isEmpty }

    #if DEBUG
    /// The spoken turns a wait is standing for, for a test.
    var awaiting: [String] { waits.keys.sorted() }
    #endif

    /// The press's call into `VoiceInput` has returned: the microphone is listening, or the
    /// press opened nothing, or it closed a hands-free session. A press that was opening
    /// (`counted`, told `microphoneOpening`) is no longer, and a reply that waited is read if no
    /// microphone is open or opening.
    func microphoneOpened(counted: Bool) {
        if counted { openings = max(openings - 1, 0) }
        microphoneClosed()
    }

    private var microphoneBusy: Bool { openings > 0 || microphoneOpen() }

    /// Whether a reply landing now waits rather than being read: a microphone is open or
    /// opening, or the call's session is changing hands — placed and not yet activated by the
    /// system, taken with the call standing, or closing — where `ensureActive` would refuse it
    /// and the activation or the call's end is what reads it.
    private var replyMustWait: Bool { microphoneBusy || audio.callChangingHands }

    /// A microphone began listening, as `MicrophoneWatch` sees it, whatever opened it: the bed dips
    /// under it as under a press's. Nothing else: what waits is read at its close, as ever.
    func microphoneListening() {
        sounds?.duck()
    }

    /// A press is about to open the microphone. What is being read stops, so the microphone does
    /// not hear it, and every other wait goes, as at any press; a reply waiting for the microphone
    /// waits on with its wait, since opening it again is no reason to lose it — it is read when
    /// this one closes.
    func microphoneOpening() {
        onMicrophone?(true)
        // A cue sounding as the microphone opens is not heard by it. After the microphone is
        // told, so a call kept up in front by a cue's hold alone is kept by the microphone as
        // that hold goes, rather than ended under it.
        earcons?.microphoneOpening()
        let waiting = deferred
        deferred = nil
        cancel()
        deferred = waiting
        waits.keys.filter { $0 != waiting?.nonce }.forEach { endAwaiting($0, "stopped") }
        openings += 1
        sounds?.duck()
    }

    /// The press that opened a microphone has done what it was going to, or a microphone closed:
    /// the reply that landed while it was open is read now, and the button it was pressed on
    /// becomes Stop. Free while a microphone is still open or nothing is waiting. A reply the
    /// session refuses here keeps waiting, its turn still marked, for the next close or the next
    /// pass that offers it after a relaunch.
    func microphoneClosed() {
        sounds?.duck()
        readWhatWaited()
        // After the reading, so a reply read now holds the call before the microphone lets it go.
        if !microphoneBusy { onMicrophone?(false) }
    }

    /// Reads the reply that waited for the microphone or for the call's session, if nothing
    /// holds it back now. One the session refuses here keeps waiting, its turn still marked.
    private func readWhatWaited() {
        guard let waiting = deferred, !replyMustWait else { return }
        deferred = nil
        AudioLog.say("reading the reply that waited")
        guard speak(waiting.text, answering: waiting.nonce, reply: waiting.reply) else {
            deferred = waiting
            AudioLog.say("the reply that waited was not taken; it waits on")
            return
        }
        waiting.nonce.map { settled?($0) }
    }

    /// Ends the reply in flight and leaves any wait standing, which is what `speak` needs: the
    /// reply about to be read replaces the one before it without the keeper stopping between them.
    /// A reply waiting for the microphone goes too: its turn is settled unread and its wait let go.
    private func cancel() {
        if let dropped = deferred?.nonce {
            settled?(dropped)
            endAwaiting(dropped, "its reply will not be read")
        }
        deferred = nil
        written?.live = false
        generation += 1
        reply = nil
        chain = nil
        making = 0
        queue.stop()
        done()
    }

    /// The reply: its words as the voice reads them (`Speakable`), one sentence at a time, each
    /// synthesised behind the one before and its frames queued for playback as soon as they
    /// exist. A sentence the voice fails on is skipped rather than ending the reply.
    /// A code block's line is one sentence, and it carries the block it stands for from
    /// `Speakable`, so a sentence of prose with the same words is never a cue.
    private func speakLocally(_ text: String) {
        let sentences = Self.spoken(text)
        guard !sentences.isEmpty else { done(); return }
        enqueue(sentences)
    }

    /// The sentences a text is read as, each with the code block it stands for, if it does.
    static func spoken(_ text: String) -> [(text: String, block: Int?)] {
        Speakable.lines(from: text).flatMap { line in
            sentences(of: line.text).map { (text: $0, block: line.codeBlock) }
        }
    }

    /// As much of a message still being written as will not change in the reading: up to its
    /// last line break, or its last sentence-final punctuation followed by whitespace, and no
    /// further than the opening of a code fence that has not closed, since what a block is read
    /// as is decided by the whole of it, nor than an image in a block still being written.
    static func settled(_ text: String) -> String {
        // An image is read after the block it was written in, as it is drawn, so the words
        // written after it in that block are read before it: from an image on, a block is not
        // settled until a blank line ends it. That also keeps an image half written — its
        // brackets open, its alternative text read as words — from being read at all.
        let block = text.range(of: "\n\n", options: .backwards)?.upperBound ?? text.startIndex
        let text = text[..<(text.range(of: "![", range: block..<text.endIndex)?.lowerBound ?? text.endIndex)]
        var end = text.startIndex
        var previous: Character?
        for index in text.indices {
            let character = text[index]
            if character.isNewline || (character.isWhitespace && previous.map { ".!?".contains($0) } == true) {
                end = text.index(after: index)
            }
            previous = character
        }
        var settled = String(text[..<end])
        let fences = settled.components(separatedBy: "```")
        if fences.count % 2 == 0 { settled = fences.dropLast().joined(separator: "```") }
        // A table is read as the count of its rows, which every further row changes: none of
        // it is settled until a line that is no row follows it. A row is a line that opens
        // with a bar, which is known at its first character, so no line is half read and then
        // taken back; a bar further along a line of prose is prose.
        var lines = settled.split(separator: "\n", omittingEmptySubsequences: false)
        var whole = false
        if lines.last == "" { lines.removeLast(); whole = true }
        while let last = lines.last, last.drop(while: { " \t>".contains($0) }).hasPrefix("|") { lines.removeLast(); whole = true }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + (whole ? "\n" : "")
    }

    private func enqueue(_ sentences: [(text: String, block: Int?)]) {
        let mine = generation
        making += sentences.count
        for sentence in sentences {
            let previous = chain
            chain = Task { [weak self] in
                await previous?.value
                guard let self, self.generation == mine else { return }
                defer { if self.generation == mine { self.made() } }
                await self.say(sentence.text, block: sentence.block, generation: mine)
            }
        }
    }

    /// One sentence, frame by frame; `block` is the code block it stands for, if it does. The
    /// console line is per sentence; the report is per reply, and neither number in it is written
    /// by a sentence that scheduled no frame.
    private func say(_ sentence: String, block: Int?, generation mine: Int) async {
        let started = now()
        let idle = queue.isIdle
        var first: Double?
        // A sentence that stands for a code block marks its first frame: the cue fires when
        // everything before it has been heard, which is when the sentence begins.
        let begins: (@Sendable () -> Void)? = block.map { number in
            { @Sendable [weak self] in
                Task { @MainActor in self?.reached(number, generation: mine) }
            }
        }
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
                try queue.play(frame.samples, rate: frame.rate, begins: first == nil ? begins : nil)
                progressed()
                if voiceGap {
                    // The voice is heard again: the bed gives way to it.
                    voiceGap = false
                    askForBed()
                }
                if first == nil {
                    first = now() - started
                    Perf.mark("speak.firstFrame")
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
            let seconds = now() - started
            let audio = Double(samples) / Double(rate)
            let words = sentence.split(separator: " ").count
            // What the sentence cost to make, in a release build's log too: numbers, never its words.
            Perf.mark(String(format: "speak.sentence synth=%.2f first=%.2f audio=%.2f words=%d",
                             seconds, first ?? -1, audio, words))
            #if DEBUG
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
            // Logged in every build, so a sentence that failed is not read as the reply's end:
            // the error alone, never the words.
            AudioLog.say("voice: a sentence failed to synthesise (\(String(describing: type(of: error)))): the reply goes on without it")
            #if DEBUG
            DebugRun.say("voice: say failed — \(error.localizedDescription)")
            #endif
        }
    }

    /// The sentence standing for code block `number` has begun to be heard. A cue of a reply
    /// since stopped or replaced reaches nothing.
    private func reached(_ number: Int, generation mine: Int) {
        guard generation == mine else { return }
        #if DEBUG
        report.blocks.append(number)
        #endif
        guard let reply else { return }
        cues += 1
        cue = CodeBlockCue(reply: reply, number: number, serial: cues)
    }

    /// One sentence is made, played or failed. The reply is over when nothing is left to make
    /// and nothing is left to hear; both halves have to agree, since the queue drains between
    /// two sentences and the last sentence is made while the queue is still full.
    private func made() {
        making -= 1
        guard making == 0, queue.isIdle else { return }
        // The other order from `drained`'s: the queue drained while this sentence was still
        // being made, and it ended with no frame after it, so no drain is coming to say so.
        if written?.live == true { heardOut() } else { finished() }
    }

    private func drained() {
        guard making == 0 else { return }
        if written?.live == true { heardOut() } else { finished() }
    }

    /// The voice has said everything it has and the guest is still writing: the bed fills the
    /// gap until the next frame.
    private func heardOut() {
        guard speaking, answering, !voiceGap else { return }
        voiceGap = true
        AudioLog.say("the voice is heard out with the guest still writing")
        askForBed()
    }

    /// Whether the bed is wanted, asked of the keeper's sounds wherever the answer can change and
    /// before any hold that changed it drops: while a release whose utterance is taken, a turn's
    /// wait, or a gap of the voice in a spoken turn's reading stands. The keeper's sounds judge
    /// the rest — the mode, the mute, a turn's hold, the voice — and fade it out otherwise.
    private func askForBed() {
        // Nothing is built inside the reset handler: the players are dead, and the next ask after
        // it makes its own.
        guard !resetting else { return }
        sounds?.working(!taken.isEmpty || !waits.isEmpty || (speaking && voiceGap))
    }

    /// `VoiceInput` has taken a release's utterance: its tap is off or its gate shut, so the bed
    /// can begin under the decode and the send without the ear hearing it. Every release standing
    /// has had its utterance taken by now.
    func utteranceTaken() {
        guard !releases.isEmpty else { return }
        taken.formUnion(releases.keys)
        askForBed()
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

    /// The reply came to its end, rather than being stopped. The cue first: its hold is taken
    /// while the reply's still stands, so behind the lock the process is not let go of between
    /// the two and nothing retakes a hold on a session the last one's going left to wait. A reply
    /// cut short by its turn's failure (`turnFailed`) ends with `failed`, not `done`, and one heard
    /// out in a conversation with the go-ahead to come sounds neither.
    private func finished() {
        // The queue's drained lands on main a hop after the audio thread saw it: one landing
        // after a stop, or after the end `made` or `writingEnded` already saw, ends nothing twice.
        guard speaking else { return }
        #if DEBUG
        report.finished = report.started
        #endif
        // In a conversation the reply's end is the go-ahead's moment, sounded as the microphone
        // opens again (`Conversation`), and one tone says it, as on Daphne's open mic; where no
        // go-ahead can sound (the keeper's sounds off), `done` says it.
        if readingFailed { earcons?.play(.failed) } else if !conversing || sounds?.saysGoAhead != true { earcons?.play(.done) }
        readingFailed = false
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
        voiceGap = false
        answering = false
        // Before `.speaking` drops: a wait or a release still standing has the bed back now the
        // voice is done, and one that wants none is faded out under the reading's hold.
        askForBed()
        reading?.cancel()
        reading = nil
        audio.wantScreenAwake(false, for: .speaking)
        audio.wantAlive(false, for: .speaking)
    }
}

#if DEBUG
extension Speaker {
    enum Engine: String, Codable { case phonon }

    /// The badge's debug-only report of the last reply: how many replies `speak` has been
    /// given, which engine the last one took (`phonon`, the only one there is), its text, whether
    /// audio for it started (the first frame queued) and whether it came to its end rather than
    /// being stopped. `first` and `rtf` are the reply's, not a sentence's: seconds from `speak`
    /// to the reply's first frame being scheduled, and the time spent synthesising over the
    /// audio that made. Neither is ever a stand-in — `first` is written once, when that frame is
    /// scheduled, and is nil when no frame ever was; `rtf` is nil until then and counts only the
    /// sentences that scheduled one. The `voice:` console line carries the same two numbers per
    /// sentence, for a run that can read the console. `blocks` is the code blocks the reply has
    /// reached, in the order their sentences began to be heard.
    struct Report: Codable, Equatable {
        var speaks = 0
        var engine: Engine?
        var text = ""
        var started = false
        var finished = false
        var first: Double?
        var rtf: Double?
        var blocks: [Int] = []
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
    /// What counts as a buffer heard (`Speaker.init`'s `heard`).
    private let heard: AVAudioPlayerNodeCompletionCallbackType
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
    /// Between the player and the mixer: the speed setting (`VoiceSpeed`). `rate` stretches time
    /// and leaves the pitch where it was, so faster speech comes without rising.
    private(set) var timePitch: AVAudioUnitTimePitch?
    private var format: AVAudioFormat?
    /// What the engine is built at. Remembered past a drop, so a rebuild with no engine left to
    /// read a format from still knows what to build.
    private var rate = Voice.rate
    private let lock = NSLock()
    /// What is scheduled and not yet heard, in the order it was scheduled, so a rebuild puts back
    /// what the dead engine forgot rather than only knowing how much there was.
    private var queued: [(era: Int, buffer: AVAudioPCMBuffer)] = []
    /// The silence queued ahead of a marked frame with nothing before it, in samples: two
    /// milliseconds at the voice's rate, too short to hear.
    static let leadIn: AVAudioFrameCount = 48
    /// What fires once a buffer has been heard, by the buffer: the beginning of what was
    /// scheduled right behind it (`play`'s `begins`). Guarded by the lock, kept across a rebuild
    /// with the buffers it waits on, and dropped with them by `stop`.
    private var marks: [ObjectIdentifier: [@Sendable () -> Void]] = [:]
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
    /// Whether an engine of this queue's is running, which is what iOS counts as audio.
    var running: Bool { engine?.isRunning ?? false }

    /// The rate the time-pitch unit is set to (`VoiceSpeed`), read where the queue speaks to its
    /// nodes and nowhere else.
    private let speed: () -> Float
    /// Makes the time-pitch unit at each build; a seam for the tests, which watch it.
    private let makeTimePitch: () -> AVAudioUnitTimePitch

    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() },
         center: NotificationCenter = .default,
         heard: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack,
         speed: @escaping () -> Float = { VoiceSpeed.value() },
         makeTimePitch: @escaping () -> AVAudioUnitTimePitch = { AVAudioUnitTimePitch() }) {
        self.makeEngine = makeEngine
        self.center = center
        self.heard = heard
        self.speed = speed
        self.makeTimePitch = makeTimePitch
    }

    /// The engine, the player and the time-pitch unit are built on the first frame, because the
    /// sample rate is the synthesiser's to report, and left running between frames so nothing
    /// after the first pays for a route. Called on the main actor, as `reset()` is: the chain's
    /// tasks inherit `Speaker`'s, and these three and the format are guarded by that and not by
    /// the lock, which counts what is scheduled for the audio thread.
    ///
    /// `begins` fires once everything scheduled before this frame has been heard, on the audio
    /// thread: the moment the frame starts to be heard. With nothing scheduled before it, a lead-in
    /// of silence a few milliseconds long (`leadIn`) is queued ahead of it to carry the mark, so
    /// the mark still waits on playback rather than firing as the frame is queued, and a queue
    /// that never plays fires nothing. A frame that is not queued (a format the queue cannot
    /// build) fires nothing, and a `stop` drops it with the frames it waited on.
    @MainActor
    func play(_ samples: [Float], rate: Int, begins: (@Sendable () -> Void)? = nil) throws {
        guard !samples.isEmpty else { return }
        // While the engine is dead — from an interruption's `.began` until something rebuilds —
        // the frame is owed rather than played. Restarting a dead engine here throws, and the
        // throw reads to the voice as the sentence's end, so the rest of a sentence the voice was
        // still yielding would be lost to an interruption nobody asked for.
        if !dead { try build(rate: rate) }
        guard let format, format.sampleRate == Double(rate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw VoiceError.noPlayer }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let silence = begins == nil ? nil : AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.leadIn)
        if let silence {
            // A buffer's memory is not cleared when it is made: silence is written, not assumed.
            silence.frameLength = Self.leadIn
            silence.floatChannelData![0].update(repeating: 0, count: Int(Self.leadIn))
        }
        let (era, lead): (Int, AVAudioPCMBuffer?) = lock.withLock {
            var lead: AVAudioPCMBuffer?
            if let begins {
                // What the mark waits on: the frame queued last, or the lead-in with none. Where
                // no lead-in could be made, the frame itself, which is heard 80 ms into it.
                let carrier = queued.last?.buffer ?? silence ?? buffer
                if carrier === silence {
                    queued.append((epoch, carrier))
                    lead = silence
                }
                marks[ObjectIdentifier(carrier), default: []].append(begins)
            }
            queued.append((epoch, buffer))
            return (epoch, lead)
        }
        guard !dead else { return }
        do {
            try start()
            guard let node else { throw VoiceError.noPlayer }
            // The speed as it stands now, so a change is heard from this frame on.
            let pace = speed()
            if let timePitch, timePitch.rate != pace { timePitch.rate = pace }
            if !node.isPlaying { node.play() }
            if let lead { schedule(lead, era: era) }
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
        node?.scheduleBuffer(buffer, completionCallbackType: heard) { [weak self] _ in
            guard let self else { return }
            var played = false
            var begun: [@Sendable () -> Void] = []
            let done: Bool = self.lock.withLock {
                guard era == self.epoch else { return false }
                played = true
                if let index = self.queued.firstIndex(where: { $0.buffer === buffer }) {
                    self.queued.remove(at: index)
                    begun = self.marks.removeValue(forKey: ObjectIdentifier(buffer)) ?? []
                }
                return self.queued.isEmpty
            }
            begun.forEach { $0() }
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
        let unit = makeTimePitch()
        e.attach(player)
        e.attach(unit)
        e.attach(silence)
        e.connect(player, to: unit, format: f)
        e.connect(unit, to: e.mainMixerNode, format: f)
        e.connect(silence, to: e.mainMixerNode, format: f)
        unit.rate = speed()
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
    @discardableResult
    func hold(_ on: Bool) -> Bool {
        guard on else { holding = false; stopKeeper(); stopEngine(); return false }
        do {
            try build(rate: rate)
            try startKeeper()
        } catch {
            // Nothing is rendering, so nothing is held: the flag says so, and the refusal leaves
            // the queue dead for the next rebuild to try again.
            holding = false
            refuse("the keeper's engine: \(error)")
            return false
        }
        holding = true
        return keeping
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

    /// The process is held by a running engine; the keeper only gives it something to render, and
    /// an engine left running with its keeper stopped is a phone that never suspends. With no hold
    /// nothing runs: the engine is stopped and its nodes left attached, so the next hold or frame
    /// starts it again through `start()`, where a refusal is a refusal like anywhere else.
    private func stopEngine() {
        guard let engine, engine.isRunning else { return }
        engine.stop()
        AudioLog.say("engine stopped: nothing is held")
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
    /// not happen yet — the next `.ended`, configuration change or reply tries again. Says whether
    /// it happened, so a caller with a reply in its hands refuses rather than speaking to nothing.
    @MainActor
    @discardableResult
    func rebuild() -> Bool {
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
            return false
        }
        #if DEBUG
        rescheduled = again.count
        #endif
        AudioLog.say("play queue rebuilt: \(again.count) rescheduled, keeper \(holding ? "playing" : "idle")")
        return true
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
            marks.removeAll()
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
        // The one thing that drops the format: after a media services reset there is no telling
        // what the next voice will report, and nothing is owed to carry over. A refusal keeps it,
        // because a frame arriving while the engine is dead is made against the voice's rate and
        // has to be owed rather than lost.
        format = nil
        drop()
    }

    /// Lets go of the engine and everything attached to it, leaving what is queued and the
    /// format alone: the format is the voice's rate, not the engine's, and a frame that arrives
    /// while there is no engine is still made against it and owed.
    private func drop() {
        stopKeeper()
        node?.stop()
        engine?.stop()
        if let configurationObserver { center.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine = nil
        node = nil
        keeper = nil
        timePitch = nil
    }
}
#endif
