#if os(iOS)
import AVFoundation
import Observation

/// Push to talk: speech to text from the microphone between a press and a release, on the device
/// where it can be. The microphone opens as the thumb comes down; hold to talk and release to
/// send, or tap to leave it open until the next press. Which a release is, is the gesture's word
/// (`pressUp`'s `held`: SwiftUI's long press of `tapLimit` fired before the thumb came up), never
/// a clock read here; the open's engine work runs off the main thread so it does not delay that
/// word, though a main thread stalled past `tapLimit` at the press makes a tap a hold. One object for the whole app, and one gate on its
/// microphone, enforced: a surface that presses while another holds it is refused, because two
/// gates on one input answer the same utterance twice. The microphone is asked for at the first press and nowhere earlier, and it is the only permission a press asks
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

    /// The long press's minimum on the microphone: a release before it fired is a tap, and leaves
    /// the microphone open until the next press.
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
    /// True while a hands-free session is held across the call's session changing hands
    /// (`suspend`): its generation, owner and sink stand and `listening` stays true, so a reply
    /// waits for it as for any open microphone; its engine is gone, and `resume` opens it again.
    private(set) var suspended = false
    /// Whether a session's caption glances run: false while the conversation carries it behind
    /// the lock, where nothing draws them and each glance is a decode of the whole utterance.
    var glancing = true
    /// Asked at an interruption's start: true when the conversation carries the open session
    /// across it (`Conversation.carries`), which suspends it rather than dropping it.
    var carries: (@MainActor () -> Bool)?
    /// Presses that reached `begin`, whatever became of them, and sessions whose microphone
    /// ran, counted when the engine starts, so a press cancelled during the prompts or refused
    /// at the input is a press and not a session. The UI test reads both: the first proves a
    /// gesture was handled, the second that it opened the microphone.
    private(set) var presses = 0
    private(set) var sessions = 0
    /// Every release the gesture handed over, whatever it ended: with `presses`, what says a press
    /// was the microphone's from the thumb coming down to its going up.
    private(set) var releases = 0
    /// Releases the gesture called holds (`pressUp`'s `held`), for the debug report.
    private(set) var holds = 0
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
    /// The input engine, its node and its tap, off the main actor (`InputEngine`): the engine is
    /// built at the press, once the session is active, and dropped by a media services reset or by
    /// a press that found the input dead; an engine outlives neither, and reading its input node
    /// before the session is active is what raises inside `installTap`. The two formats the guard
    /// judges and the tap is installed with are read from the node in production and injected by
    /// the suite, which has no audio device to read one from.
    private let input: InputEngine
    /// True from a press handing its open to the input's queue until the open has answered: the
    /// microphone is opening, and a reply landing meanwhile waits for it as for an open one
    /// (`busy`).
    private(set) var opening = false
    /// Whether the microphone is open or opening, whoever opened it — a thumb's press or a
    /// conversation's reopen, which tells the speaker nothing else: what the app answers
    /// `Speaker.microphoneOpen` with, and what `MicrophoneWatch` hears close.
    var busy: Bool { listening || opening }
    /// The generation whose open `opening` stands for.
    private var openingFor: Int?
    /// The generation of an open an interruption's start found in flight on a session the
    /// conversation carries: it is suspended as it answers, its engine already dropped.
    private var suspendWhenOpened: Int?
    /// The microphone prompt's answer: the system's in production, injected by the suite so a
    /// press can be driven through `pressDown` and `pressUp` without TCC.
    private let permission: @MainActor () async -> Bool
    /// Whether the microphone is already allowed, read without asking: a microphone opened with
    /// no thumb (`reopen`) never puts the prompt up.
    private let permitted: @MainActor () -> Bool
    /// Where `NoiseSuppression` is kept, read at every press.
    private let defaults: UserDefaults
    /// The microphone's samples at the ear's rate, filled by the tap. Internal so the suite can
    /// hand a release an utterance on a host with no audio device.
    let sink = SampleSink()
    /// What the tap hands its buffers through: open while a session is listening, shut from its
    /// release, so the input kept running past a release (`inputKept`) feeds nothing.
    let gate = TapGate()
    /// True from a spoken release that asked for it until `stopKeptInput`: the release's engine
    /// and tap left running, the gate shut, so the app is recording when a lock straight after
    /// the press places the call. The call service lets a call be started from the background
    /// when the app placing it is recording, as Daphne's microphone is whenever she places hers.
    /// Kept only while a call can still be placed (`Speaker.callIdle`). Not the microphone
    /// left open: `listening` is false, nothing it hears reaches a turn, a caption or the row,
    /// and a reply is not held for it. The audio session is kept for it as for an open
    /// microphone (`AudioSession.keptInput`), since its tap is on the format the session gave.
    private(set) var inputKept = false
    /// The gate whose release kept the input: its cancel stops it, though the session it was
    /// kept from has ended and `owner` is clear.
    private var keptFor: Gate?
    /// Ends a kept input at `keptFor` from its release.
    private var keptBound: Task<Void, Never>?
    /// How long an input is kept at most: the release hold's own bound (`Speaker.releaseBound`).
    static let keptFor: Duration = Speaker.releaseBound
    /// How the kept input's bound is waited out; a test's sleep in the suite.
    var keptSleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Whether the input engine is running: a session's, or one kept past its release.
    var inputRunning: Bool { input.isRunning }
    /// Whether a tap is on the input node: a session's, or a kept input's.
    var inputTapped: Bool { input.isTapped }
    private var captioner: Task<Void, Never>?
    /// Counts sessions; everything asynchronous checks it belongs to the current one. Readable
    /// so the suite can drive a press under the generation the object is on.
    private(set) var generation = 0
    /// How long a press waits for the call's session to settle (`AudioSession.settled`): past
    /// the call's closing grace, so a call only the grace finishes is waited out. Settable for
    /// the suite.
    var callSettle: Duration = .seconds(3)
    /// The generation of the press waiting out the call's session (`begin`). A generation, so a
    /// press cancelled while it waited leaves nothing that reads as the next press's.
    private var settling: Int?
    /// The generation of a press whose tap's release came while its microphone was still opening
    /// (the call's session settling, the open in flight): it opens hands-free once it is open.
    private var tappedWhileOpening: Int?
    /// True while the press waits on the microphone prompt the system has put up: a release then
    /// is no verdict of the thumb's (the alert takes the touch), and it cancels the press.
    private var prompting = false
    /// Presses `pressDown` ignored while another press was starting (the call's session settling,
    /// the open in flight), whose releases are owed nothing. Cleared at the next press that begins.
    private var ignoredWhileSettling = 0
    /// True from the press until the microphone is running: the permission prompt, the call's
    /// session settling and the open on the input's queue.
    private var starting = false
    /// True from a release until the session is torn down: the wait for the last word.
    private(set) var ending = false
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
         makeEngine: @escaping InputEngine.Make = { AVAudioEngine() },
         formats: @escaping InputEngine.Formats = VoiceInput.readFormats,
         permission: @escaping @MainActor () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
         permitted: @escaping @MainActor () -> Bool = { AVAudioApplication.shared.recordPermission == .granted },
         voiceProcessing: @escaping InputEngine.Processing = VoiceInput.setVoiceProcessing,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.audio = audio
        // Before any claim, so the record configuration the foreground warms is the one the
        // first press wants.
        audio.wantVoiceProcessing(NoiseSuppression.enabled(defaults))
        self.ear = ear
        input = InputEngine(center: center, make: makeEngine, formats: formats, processing: voiceProcessing)
        self.permission = permission
        self.permitted = permitted
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            // A call or Siri took the session; whatever was still being said is over, and words
            // already released finish their decode and are sent (`drop`). Only the start
            // of an interruption: iOS posts its end seconds later, by which time a new session
            // may be up and is not to be cancelled for it.
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in
                guard let self else { return }
                // No input engine crosses a session event, a kept one included.
                self.stopKeptInput("the interruption's start")
                // An open in flight keeps no engine across the event: one it started is dropped
                // as it answers. A session the conversation carries is suspended there, as an
                // open one is below; any other press is over.
                if self.opening {
                    guard self.carries?() == true else { return self.cancel() }
                    self.suspendWhenOpened = self.openingFor
                    self.input.drop()
                    return
                }
                // A session the conversation carries is suspended, never carried across the
                // event on its engine: under the call's live session it is rebuilt at once
                // (`Conversation`), otherwise at the call's activation.
                if self.carries?() == true { self.suspend("the interruption's start") } else { self.drop() }
            }
        }
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
        // The input is kept only for the placing of a turn's call: with no turn held there is
        // none to place, and a reply being read is ducked by its voice unit. Told before the
        // session is let go, so it never goes under a live tap.
        audio.endKeptInput = { [weak self] in self?.stopKeptInput($0) }
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
        input.drop()
    }

    /// Loads the ear's models, downloading them on the first run. Called on the foreground so
    /// they are resident by the first press; idempotent.
    func prepare() { ear.prepare() }

    /// The thumb comes down for `gate`. Ends a hands-free session and returns what it heard, to
    /// be sent; otherwise starts a session and returns nil. Nothing happens for a press while
    /// another gate holds the microphone, while a release is still waiting for the last word, or
    /// when a permission is denied.
    func pressDown(as gate: Gate, keepingInput keeps: Bool = false) async -> String? {
        if listening, owner == gate, handsFree { return await end(as: gate, keepingInput: keeps) }
        guard !listening, !starting, !ending else {
            // A press made while another's microphone is still opening (the call's session
            // settling, the open in flight) reaches nothing, and so does its release, whenever
            // it comes.
            if starting { ignoredWhileSettling += 1 }
            return nil
        }
        await begin(as: gate)
        return nil
    }

    /// The thumb comes up for `gate`. `held` is the gesture's verdict: the long press fired before
    /// the release. A hold ends and returns what it heard, to be sent; a tap leaves the microphone
    /// open and returns nil. A release while the microphone prompt is up cancels the press,
    /// whichever it was, so no microphone is left open with nobody holding it; so does a hold
    /// released while the microphone is still opening, and a tap released there opens it
    /// hands-free once it is open. `keepingInput` keeps the input running past a release that
    /// sends (`inputKept`).
    func pressUp(as gate: Gate, held: Bool, keepingInput keeps: Bool = false) async -> String? {
        releases += 1
        if held { holds += 1 }
        if ignoredWhileSettling > 0 {
            ignoredWhileSettling -= 1
            return nil
        }
        // A tap while the microphone is still opening is a tap, not a cancel: it opens
        // hands-free once it is open.
        if starting, owner == gate, !prompting, !held {
            tappedWhileOpening = generation
            return nil
        }
        if starting, owner == gate {
            generation += 1
            // An open in flight is stopped here, before the release returns: its engine started on
            // the queue for a press that is over.
            if opening { tearDown() } else {
                starting = false
                owner = nil
            }
            return nil
        }
        guard listening, owner == gate, !ending else { return nil }
        if !held, !handsFree {
            handsFree = true
            return nil
        }
        return await end(as: gate, keepingInput: keeps)
    }

    /// Drops a session still listening, as `cancel` does, and leaves one already ending to
    /// finish: a released press has taken its audio and stopped its engine, and what is left is
    /// the decode of words the person meant to send — a lock or an interruption landing during it
    /// takes nothing from the microphone, which is no longer open.
    /// An input kept past a release (`inputKept`) is kept for the lock: the lock's drop leaves it
    /// to the call's placing, which stops it.
    func drop(_ gate: Gate? = nil) {
        guard !ending else { return }
        if let gate, owner != gate { return }
        cancel(gate)
    }

    /// Stops listening and drops what was heard. Any gate's session, or `gate`'s only.
    func cancel(_ gate: Gate? = nil) {
        if gate == nil || gate == keptFor { stopKeptInput("the session was cancelled") }
        if let gate, owner != gate { return }
        generation += 1
        text = ""
        tearDown()
    }

    /// Holds an open hands-free session across the call's session changing hands: the tap comes
    /// off and the engine is stopped and dropped — an engine keeps the input format of the route
    /// it was made on, and a call can move the route, where a tap on the old format raises past
    /// any `catch` — while the session's generation, owner and samples stand. The audio session
    /// hears the microphone close, so what waited on it applies. Nothing for a session that is
    /// not running.
    func suspend(_ why: String) {
        guard listening, !ending, !starting, !suspended else { return }
        suspendNow(why)
    }

    private func suspendNow(_ why: String) {
        suspended = true
        captioner?.cancel()
        captioner = nil
        input.drop()
        AudioLog.say("microphone suspended (\(why)): what was heard is kept")
        audio.microphone(open: false)
    }

    /// Opens a suspended session again, on the session the call's activation made live: the
    /// press's own path — `ensureActive`, a new engine, voice processing set before the one read
    /// of the formats, the guard, the tap — on the same generation, going on into the same
    /// samples. A refusal leaves the session suspended with what it heard, for its owner to end
    /// (`end` decodes what was kept) or drop; answers whether the microphone is running.
    @discardableResult
    func resume() -> Bool {
        guard listening, suspended, !ending, let gate = owner else { return false }
        do {
            try resumeMicrophone()
            suspended = false
            return true
        } catch {
            input.drop()
            if error is SessionInactive || (error as? InputEngine.Refusal).map(\.deadSession) == true { audio.invalidate() }
            refusal = "the microphone did not resume: \(error)"
            AudioLog.say(refusal ?? "")
            return false
        }
    }

    /// Opens a hands-free session with no thumb: the conversation's next utterance, in front or
    /// behind the lock. A press in everything but the gesture: the permission is not asked — one not
    /// already granted refuses — and the ear's readiness, the session, the engine and the tap go
    /// through `press` as a thumb's do. Answers whether the microphone is listening for `gate`.
    /// It does not wait out a call's session changing hands, as a thumb's press does, and refuses:
    /// behind the lock the wait could end at the call's end, on a session the background cannot
    /// activate. `live` is asked again once the permission has answered, the one wait before the
    /// session is touched: a session no longer live (the app gone inactive with no call) refuses,
    /// so nothing is opened or read from a session iOS would refuse.
    func reopen(as gate: Gate, live: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        guard !listening, !starting, !ending, !denied, permitted() else { return false }
        guard !audio.callChangingHands else {
            refusal = "the call's session is changing hands"
            return false
        }
        await begin(as: gate, settling: false, live: live)
        guard listening, owner == gate else { return false }
        handsFree = true
        return true
    }

    /// `settling` false refuses a call's session changing hands rather than waiting it out, as
    /// `reopen` does, however long the permission took to answer.
    private func begin(as gate: Gate, settling waits: Bool = true,
                       live: @MainActor () -> Bool = { true }) async {
        presses += 1
        refusal = nil
        #if DEBUG
        capture = Capture()
        meter.reset()
        #endif
        generation += 1
        let mine = generation
        ignoredWhileSettling = 0
        starting = true
        owner = gate
        text = ""
        handsFree = false
        defer {
            if generation == mine { starting = false }
            if tappedWhileOpening == mine { tappedWhileOpening = nil }
        }
        // The microphone, and nothing else: the words are turned into text on this phone. The
        // prompt is up only when it was not already allowed, and a release then cancels the press.
        prompting = !permitted()
        let allowed = await permission()
        prompting = false
        guard allowed else {
            microphoneDenied()
            return
        }
        // Released or cancelled while the prompt was up: start nothing.
        guard generation == mine else { return }
        denied = false
        // The call's session changing hands — closing as a reply ends, which is when a person
        // answers — is waited out rather than refused: a tap put on a closing session is cut by
        // its deactivation. Past the bound the press goes on and `ensureActive` refuses it.
        if audio.callChangingHands, !waits {
            refusal = "the call's session is changing hands"
            owner = nil
            return
        }
        guard live() else {
            refusal = "no live session"
            owner = nil
            return
        }
        if audio.callChangingHands {
            settling = mine
            _ = await audio.settled(within: callSettle)
            if settling == mine { settling = nil }
            // Released or cancelled while it waited: start nothing.
            guard generation == mine else { return }
        }
        await press(as: gate, mine: mine)
        if tappedWhileOpening == mine, listening, generation == mine { handsFree = true }
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
    func press(as gate: Gate, mine: Int) async {
        // An ear that is not resident is the whole refusal, and it comes first: the audio
        // session, the engine and the input node are not touched for a press nothing can hear.
        // The ear's own words are the reason, which is what the diagnostics `speech` row shows.
        guard ear.ready else {
            refusal = ear.summary
            #if DEBUG
            DebugRun.say("press: \(refusal ?? "refused")")
            #endif
            owner = nil
            return
        }
        // The gate holds the microphone from here; `begin` has already said so, and a press the
        // suite drives straight in says it here.
        owner = gate
        do {
            try await startMicrophone(as: gate, mine: mine)
        } catch is Superseded {
            // Cancelled while it opened: whatever moved the generation tore it down.
            return
        } catch {
            // A session that would not activate and an input node whose formats are dead are both
            // the same situation: the handles this press holds are no good and must not be reused.
            let dead: Bool
            // An engine whose voice processing would not change is in neither state for certain,
            // so it goes too; the session under it is as good as it was.
            var dropped = false
            switch error {
            case InputEngine.Refusal.noInput:
                refusal = Self.noInput
                dead = true
            case InputEngine.Refusal.processing(let on, let underlying):
                refusal = "noise suppression did not turn \(on ? "on" : "off"): \(underlying)"
                dead = false
                dropped = true
            case InputEngine.Refusal.reset:
                refusal = "the media services reset while the microphone opened"
                dead = true
            case let inactive as SessionInactive:
                refusal = "the audio session did not activate: \(inactive.underlying)"
                dead = true
            case InputEngine.Refusal.start(let underlying):
                refusal = "the engine did not start: \(underlying)"
                dead = false
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
            if dead || dropped { input.drop() }
            if dead { audio.invalidate() }
        }
    }

    /// The press proper, once the permission is in: everything that is a handle into
    /// mediaserverd, in the one order that is safe. The session is claimed and activated here, on
    /// the main actor whose state it is, before an engine exists; then the open goes to the input's
    /// queue (`InputEngine.enqueueOpen`): the engine before its input node is read, voice processing set
    /// before the formats are read, and the formats before a tap is installed on them. The main
    /// actor is free while it runs, which is what lets the gesture's events and the long press's
    /// verdict arrive while the microphone opens. A throw anywhere leaves the press refused with
    /// nothing running.
    private func startMicrophone(as gate: Gate, mine: Int) async throws {
        let (suppress, resetsAt, session) = try prepareSession(as: gate)
        let resets = audio.resets
        // The generation as the open begins (`mine` on every path but a suite's): whatever moves
        // it before the open answers has torn the press down.
        let at = generation
        // The session is kept from here, before the first handle exists: no claim, hold or setting
        // change reconfigures it, or hands it back, under an engine starting on the queue. A
        // refusal's teardown says it has closed.
        audio.microphone(open: true)
        sink.reset()
        self.gate.open()
        opening = true
        openingFor = at
        defer {
            if openingFor == at {
                opening = false
                openingFor = nil
            }
            if suspendWhenOpened == at { suspendWhenOpened = nil }
        }
        let handed = ContinuousClock.now
        let input = self.input, tap = self.tap
        let answer: Result<InputEngine.Opened, Error> = await withCheckedContinuation { done in
            // On the main actor, before the suspension: the open is on the queue ahead of any
            // teardown made while this press waits for it.
            input.enqueueOpen(suppress: suppress, resetsAt: resetsAt, tap: tap) { done.resume(returning: $0) }
        }
        let answered = ContinuousClock.now - handed
        // Cancelled while it opened (a release, a cancel, an interruption, a reset's handler):
        // whatever moved the generation tore it down, its engine stopped before it returned. A
        // refusal from a superseded open is the newer press's business no more than a success.
        guard generation == at, owner == gate else { throw Superseded() }
        let result = try answer.get()
        // A reset that landed while it opened, before this object's handler has run: the handles
        // just made are dead.
        guard audio.resets == resets else {
            input.drop()
            throw InputEngine.Refusal.reset
        }
        opened(result, suppress: suppress, resuming: false, mine: mine,
               main: "session \(SmartTurn.ms(session)), queue \(SmartTurn.ms(answered))")
        if suspendWhenOpened == at {
            suspendWhenOpened = nil
            suspendNow("the interruption's start, while it opened")
        }
    }

    /// A suspended session opened again on the session the call's activation made live: the same
    /// open, waited for, since its caller reads the answer at once.
    private func resumeMicrophone() throws {
        let (suppress, resetsAt, session) = try prepareSession(as: owner ?? .chat)
        gate.open()
        let opened = try input.openNow(suppress: suppress, resetsAt: resetsAt, tap: tap)
        audio.microphone(open: true)
        self.opened(opened, suppress: suppress, resuming: true, mine: generation,
                    main: "session \(SmartTurn.ms(session))")
    }

    /// What every open does on the main actor before the first handle: a kept input stopped (its
    /// engine is the one this press opens, and voice processing is set only on an engine that is
    /// not running), the setting read (now and not again, so a change made mid-utterance is the
    /// next press's; the session hears of it first, because the mode is the session's), the
    /// record claim, and the session made active. Answers the voice processing the unit takes —
    /// the session's and not the setting's: under a hold the session's mode waits, and the unit
    /// waits with it — and the input's reset count read before the activation.
    private func prepareSession(as gate: Gate) throws -> (suppress: Bool, resetsAt: Int, took: Duration) {
        let began = ContinuousClock.now
        stopKeptInput("a press opens the microphone")
        audio.wantVoiceProcessing(NoiseSuppression.enabled(defaults))
        audio.wantRecord(true, for: gate == .chat ? .chat : .firstRun)
        let resetsAt = input.resets
        do { try audio.ensureActive() } catch { throw SessionInactive(underlying: error) }
        return (audio.voiceProcessed, resetsAt, ContinuousClock.now - began)
    }

    /// What the tap hands its buffers to.
    private var tap: InputEngine.Tap {
        #if DEBUG
        InputEngine.Tap(gate: gate, sink: sink, meter: meter)
        #else
        InputEngine.Tap(gate: gate, sink: sink)
        #endif
    }

    /// The engine is running with the tap on it: the microphone is open. `main` is what the
    /// open took on the main actor (the session) and in all on the queue, the queue's own steps
    /// in `result`, so a slow press names which side it was slow on.
    private func opened(_ result: InputEngine.Opened, suppress: Bool, resuming: Bool, mine: Int, main: String) {
        #if DEBUG
        DebugRun.say("press: session ok, client \(result.client.rate)/\(result.client.channels), " +
                     "hardware \(result.hardware.rate)/\(result.hardware.channels)")
        #endif
        let steps = result.steps
        AudioLog.say("microphone \(resuming ? "resumed" : "open"): noise suppression \(suppress ? "on" : "off") (\(main); \(steps))")
        listening = true
        if !resuming { sessions += 1 }
        audio.wantScreenAwake(true, for: .listening)
        startCaptions(for: mine)
    }

    /// The caption on the ear's path: every `glanceEvery`, the audio so far decoded bare, once
    /// there is a second of it and something new has arrived since the last glance.
    private func startCaptions(for mine: Int) {
        guard glancing else { return }
        captioner = Task { [weak self] in
            var seen = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.glanceEvery)
                guard let self, self.generation == mine, self.listening, !self.ending else { return }
                // Behind the lock nobody reads a caption: the conversation stops the glances.
                guard self.glancing else { continue }
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
    /// `keepingInput` shuts the gate and leaves the engine running (`inputKept`) where it would
    /// stop it, until the input's own end; a release that heard nothing stops it at once.
    func end(as gate: Gate, keepingInput keeps: Bool = false) async -> String {
        guard listening, owner == gate, !ending else { return "" }
        ending = true
        let mine = generation
        captioner?.cancel()
        captioner = nil
        if keeps, input.isRunning {
            keepInput(for: gate)
        } else {
            input.stop()
        }
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
        if heard.isEmpty { stopKeptInput("the release heard nothing to send") }
        tearDown()
        ending = false
        return heard
    }

    /// The release keeps its input: the gate shut first, so nothing the input hears from here
    /// reaches the sink, and the session kept for the tap before anything else lets it go.
    private func keepInput(for owner: Gate) {
        gate.shut()
        inputKept = true
        keptFor = owner
        audio.keptInput(running: true)
        AudioLog.say("input kept past the release for the call's placing; what it hears is dropped")
        keptBound?.cancel()
        let sleep = keptSleep
        keptBound = Task { [weak self] in
            do { try await sleep(Self.keptFor) } catch { return }
            self?.stopKeptInput("its bound ran out")
        }
    }

    /// The call's moments (`Speaker.onCall`): the input kept past a release is what the call
    /// service judged the placing by, so it runs until the system performs the start, where the
    /// session becomes the system's (`AudioSession.callPlaced` follows at once), and through a
    /// refused placing's retries until the call is over, refused for good or failed.
    func call(_ moment: Speaker.CallMoment) {
        switch moment {
        case .placing:
            stopKeptInput("the call is placed: the session is the system's")
            // An open in flight would start an engine on the session the call is taking.
            if opening { cancel() }
        case .taken:
            // The session the open is starting an engine on is the other call's now.
            if opening { cancel() }
        case .ending:
            // The session the open is starting an engine on is about to be activated afresh.
            if opening { cancel() }
        case .over: stopKeptInput("the call is over")
        default: break
        }
    }

    /// Stops the input kept past a release: the tap off and the engine stopped, the engine itself
    /// kept for the next press as a release's is, then the session told. Free when none is kept.
    /// Called before the call's placing reconfigures the session (`AudioSession.callPlaced`), at
    /// the call's end however it ended, at an interruption's start, when no turn is held, as a
    /// reply begins to be read, at its bound, at a cancel and when the microphone next opens.
    func stopKeptInput(_ why: String) {
        keptBound?.cancel()
        keptBound = nil
        guard inputKept else { return }
        inputKept = false
        keptFor = nil
        input.stop()
        AudioLog.say("kept input stopped: \(why)")
        audio.keptInput(running: false)
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
        self.gate.shut()
        // An input kept past its release outlives its session: `stopKeptInput` ends it.
        if !inputKept { input.stop() }
        sink.reset()
        listening = false
        starting = false
        ending = false
        handsFree = false
        suspended = false
        opening = false
        openingFor = nil
        owner = nil
        prompting = false
        audio.wantScreenAwake(false, for: .listening)
        if let gate { audio.wantRecord(false, for: gate == .chat ? .chat : .firstRun) }
        // Last, so the claim just dropped and whatever waited on the open microphone are one
        // configuration.
        audio.microphone(open: false)
    }

    /// A press cancelled while its open was in flight: nothing is left of it to refuse.
    private struct Superseded: Error {}
    /// `AudioSession.ensureActive` refused, carrying what it threw for the refusal line.
    private struct SessionInactive: Error { let underlying: Error }

    /// The numbers one side of an input node reports, which is all the guard judges on.
    struct Format: Equatable, Sendable {
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
    nonisolated static let readFormats: InputEngine.Formats = { engine in
        let input = engine.inputNode
        return (input.outputFormat(forBus: 0), input.inputFormat(forBus: 0))
    }

    /// Apple's voice processing on the input node (noise suppression, echo cancellation and gain
    /// control, one unit), as `NoiseSuppression` asks. Changing it rebuilds the node's unit, so
    /// it is called only when the answer differs from the node's own. The voice unit ducks every
    /// other sound on the phone while it runs, Topo's own reply among them, so its ducking is
    /// set to the least it allows; some remains for as long as the microphone is open.
    /// Off is the unit gone and not bypassed, which is the microphone as it comes.
    nonisolated static let setVoiceProcessing: InputEngine.Processing = { engine, on in
        let input = engine.inputNode
        guard input.isVoiceProcessingEnabled != on else { return }
        try input.setVoiceProcessingEnabled(on)
        if on {
            input.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
        }
        AudioLog.say("noise suppression \(on ? "on" : "off"): the input's voice processing was changed")
    }

    /// Whether a tap may be installed, as a function of the four numbers alone. A zero sample
    /// rate or no channel on either side is a session with no input; a client rate that is not
    /// the hardware's is a conversion `installTap` refuses. Both refusals are raised as
    /// Objective-C exceptions no `catch` here would see, so they are answered before the call.
    nonisolated static func inputIsUsable(client: Format, hardware: Format) -> Bool {
        client.rate > 0 && client.channels > 0
            && hardware.rate > 0 && hardware.channels > 0
            && client.rate == hardware.rate
    }
}

/// What the input tap hands its buffers through, on the audio thread: open, each buffer is passed
/// on; shut, it goes nowhere. The check and what is passed run as one step under the lock, so
/// once `shut` has returned nothing more reaches the sink, whatever the audio thread was doing.
final class TapGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() { lock.withLock { isOpen = true } }
    func shut() { lock.withLock { isOpen = false } }

    /// Runs `body` if the gate is open.
    func pass(_ body: () -> Void) {
        lock.withLock { if isOpen { body() } }
    }
}

/// Whether the microphone is heard through Apple's voice processing: Settings' Noise suppression,
/// which the mind sets too (`topo voice`), kept in this device's defaults.
enum NoiseSuppression {
    static let key = "noiseSuppression"

    /// On unless turned off: a phone that has never been asked suppresses.
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
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
        var holds = 0
        var refusal: String?
        var ear: String
        var capture: Capture
    }

    var debugReport: String {
        let report = Report(presses: presses, sessions: sessions, releases: releases, holds: holds, refusal: refusal,
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
