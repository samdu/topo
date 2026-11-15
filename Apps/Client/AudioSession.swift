#if os(iOS)
import AVFoundation
import UIKit

/// The process-wide audio resources, counted rather than assigned: the record configuration of
/// the audio session and the warm microphone it buys, the idle timer, and the hold that keeps the
/// process running in the background. More than one caller reaches for each, and the one leaving
/// must not hand the route, auto-lock or the background back under the one arriving. The pattern
/// is Daphne's `TurnController` (Sam's own iOS app, `clients/ios` in samdu/daphne-assistant).
///
/// It is also the gate on every handle into mediaserverd. Nothing reads an input node, installs a
/// tap, starts an engine or speaks until `ensureActive()` has returned: a configuration that
/// failed to activate leaves the session invalid, and a caller that goes on regardless meets an
/// uncatchable exception rather than an error.
@MainActor
final class AudioSession {
    /// `.conversation` is a conversation's whole life (`conversation(_:)`), its utterances' ends
    /// and the waits and readings between them included.
    enum RecordClaim: Hashable { case firstRun, chat, warm, conversation }
    /// `.profiling` is a run from a Mac (`--stay-awake`): a locked phone takes no launch and no copy.
    enum ScreenClaim: Hashable { case listening, speaking, profiling }
    /// Who is keeping the process running behind the lock: a spoken press released and not yet
    /// sent, the wait for a spoken turn's reply, one claim per turn outstanding, the reading of a
    /// reply, and a sound heard out beside them. Counted like the other two, so
    /// the one letting go cannot cut what the other is still paying for — a reply handed to the
    /// speaker drops its own turn's wait with `.speaking` already taken, the keeper never stops
    /// between them, and a second thing said while the first is in flight is still held for.
    enum Hold: Hashable {
        /// A spoken press released, its words still being finished and sent: from the thumb
        /// coming up (or the press that closes a hands-free microphone) to the turn's own wait,
        /// one per release, so a lock before the send still finds the process held.
        case releasing(Int)
        case awaitingReply(String)
        case speaking
        /// A cue of the spoken exchange's being heard out (`Earcons`), taken only while another
        /// hold stands and bounded by the cue's own bound.
        case cue
        /// The keeper's sound being heard out — a receipt, the bed's fade — taken only while
        /// another hold stands and bounded by the sound's own bound. A case of its own beside
        /// `cue`, since a hold is one per case: neither letting go can cut the other.
        case sound
    }

    private var recordClaims: Set<RecordClaim> = []
    private var screenClaims: Set<ScreenClaim> = []
    private var holds: Set<Hold> = []
    /// Told the answer on every claim taken or dropped, not only when it changes: the count is the
    /// session's, the engine that renders the silence is the play queue's, and `Speaker` — the one
    /// object holding both — is what starts and stops the keeper, so a claim arriving while
    /// another already stands is its chance to start a keeper an earlier refusal left down.
    var onHoldChanged: ((Bool) -> Void)?
    /// True while anything wants the process kept alive.
    var holding: Bool { !holds.isEmpty }
    /// Whether a hold stands that is not a sound's own (a cue's or the keeper's): what a sound may
    /// extend. A sound begun under nothing but another sound's hold holds nothing, so a run of
    /// them cannot keep the process alive past the wait or the reply they were played for.
    var heldForATurn: Bool { holds.contains { $0 != .cue && $0 != .sound } }
    private var recordMode: Bool { !recordClaims.isEmpty }
    /// Whether the record configuration is the one for a microphone heard through Apple's voice
    /// processing (`NoiseSuppression`), which is its mode: `voiceChat` with, `default` without.
    /// The mode is this object's to set and never the voice unit's: a unit made on a session in
    /// no chat mode has the system put the session in `voiceChat` by itself, under a session
    /// this object believes it configured, and nothing puts it back when the unit goes.
    private var processed = false
    /// What the last configuration that activated set: the state the session is in, which is
    /// what a press hands the input node's voice unit, so the two change together or not at all.
    private(set) var voiceProcessed = false
    /// Sets the session's category for record mode (true) or the quiet one (false), the record
    /// configuration's mode for voice processing or without it, and activates it, throwing when
    /// either refuses: activation is commonly refused while another app is in front, which is
    /// exactly where a media services reset is asked for.
    private let configure: (Bool, Bool) throws -> Void
    /// Deactivates the session, telling other audio it may resume when asked to (the hand-back).
    private let deactivate: (_ notifyingOthers: Bool) throws -> Void
    /// The record flag of the last configuration that set the category, nil before one has:
    /// entering the quiet configuration from the record one is where the hand-back goes.
    private var configuredRecord: Bool?
    /// Whether the app is in front, which is the only place a configuration is worth attempting:
    /// iOS refuses one from the background for a non-mixable session.
    private let isActive: @MainActor () -> Bool
    /// Whether another app is playing — a podcast, music — which the foreground's warm claim
    /// leaves alone (`warmRecord`).
    private let otherAudioPlaying: @MainActor () -> Bool
    /// Whether the microphone may be used, which the warm claim asks before it takes the session.
    private let recordPermitted: @MainActor () -> Bool
    /// True once the session has been configured; a reset re-applies only a session that was.
    private var applied = false
    /// A claim change that came in while a hold stood or the microphone was open, waiting for
    /// the last hold to drop and the microphone to close. Of the hold: the
    /// session a reply is being waited for on is not reconfigured underneath it: activating or
    /// reconfiguring a non-mixable session from the background is refused
    /// (`cannotInterruptOthers`), which would leave the session invalid and every later
    /// `ensureActive` trying the same refused call from behind the lock. The session that was
    /// active at the release stays active and untouched, whatever category it was in, until the
    /// reply has been heard — the keeper is already rendering on it, and an already-active session
    /// goes on rendering in the background under the `audio` mode.
    private var deferredClaims = false
    /// True while the chat's microphone is open: its engine is running on the session as it was
    /// configured, with a tap installed on the format that configuration gave and a voice unit
    /// made for its mode. A configuration applied underneath is a format changed under that tap
    /// and a mode changed under that unit, so an open microphone keeps the session as a hold
    /// does, and a claim change made over one waits for it to close.
    private var microphoneOpen = false
    /// True while a conversation's input runs on through a reading with its gate shut
    /// (`VoiceInput.inputKept`): its tap is on the format the session gave, so it keeps the
    /// session as an open microphone does.
    private var inputKept = false
    /// True from a conversation's beginning to its end (`conversation(_:)`): its microphone closes
    /// and opens again between utterances, behind the lock among them, and a session handed back
    /// or configured for playback between two of them is one it cannot open on again from there.
    private var conversing = false
    /// True only between a configuration that activated the session and the next reset or failure.
    private var valid = false
    private var resetObserver: NSObjectProtocol?
    /// Whether the session is to be left as it is: a hold stands, the microphone is open, an
    /// input is kept, or a conversation lives.
    private var kept: Bool { holding || microphoneOpen || inputKept || conversing }
    /// The outputs the session is routed to now, by port type (`currentRoute`).
    private let outputs: @MainActor () -> [AVAudioSession.Port]

    /// iOS resetting the media server leaves the session at its default category and inactive, so
    /// the configuration the claims asked for is applied again; a session never configured is left
    /// alone, since activating it is not the reset's to decide.
    init(center: NotificationCenter = .default,
         configure: @escaping (Bool, Bool) throws -> Void = AudioSession.configureSession(record:processed:),
         deactivate: @escaping (Bool) throws -> Void = AudioSession.deactivate(notifyingOthers:),
         isActive: @escaping @MainActor () -> Bool = AudioSession.appIsActive,
         otherAudioPlaying: @escaping @MainActor () -> Bool = { AVAudioSession.sharedInstance().isOtherAudioPlaying },
         recordPermitted: @escaping @MainActor () -> Bool = { AVAudioApplication.shared.recordPermission == .granted },
         outputs: @escaping @MainActor () -> [AVAudioSession.Port] = { AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType) }) {
        self.outputs = outputs
        self.configure = configure
        self.otherAudioPlaying = otherAudioPlaying
        self.recordPermitted = recordPermitted
        self.deactivate = deactivate
        self.isActive = isActive
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Marked at the notification itself, before any handler's task runs: every handle
            // made before it is dead from this moment, whichever object's handler comes first.
            MainActor.assumeIsolated { self?.serverWasReset() }
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
    }

    /// How many media services resets this session has seen, counted at the notification: a
    /// handle into mediaserverd kept across calls (a sound's player) is good only while this is
    /// the count it was made under.
    private(set) var resets = 0

    private func serverWasReset() {
        resets += 1
        valid = false
    }

    private func mediaServicesWereReset() {
        valid = false
        AudioLog.say("media services reset: audio session invalidated (record \(recordMode))")
        guard applied else { return }
        // Remembered rather than swallowed: a failure here leaves the session invalid and the
        // next `ensureActive` tries again, from the path that actually wants the audio. Logged,
        // so a run says when a configure failed and with what.
        applyOrRemember()
    }

    /// The first call of every audio path. Free on a session that is already active; otherwise it
    /// configures for the claims as they stand and throws whatever that throws, so the caller
    /// refuses rather than touching a dead session. Behind the lock it is free, because a hold
    /// defers the claim changes that would have invalidated the session; what can still ask for a
    /// configuration there is an interruption that took the session, and the end of one is
    /// exactly when iOS allows the session back.
    func ensureActive() throws {
        guard !valid else { return }
        try apply()
    }

    /// The first call of a sound that is a moment rather than a path (a cue, a receipt): free on a live
    /// session, as `ensureActive` is, and a refusal on one that is not, since a moment configures
    /// nothing. Behind the lock, after an interruption took the session, `ensureActive` would be
    /// the session reconfigured and activated from the background under a hold, for a cue.
    func ensureLive() throws {
        guard valid else { throw NotLive() }
    }

    struct NotLive: Error, CustomStringConvertible {
        var description: String { "the session is not live" }
    }

    /// Marks the session as needing configuring again, for a caller that found the audio dead
    /// under a session this object believed was live.
    func invalidate() {
        valid = false
    }

    /// Claims or drops the record configuration for one surface. The session is touched only
    /// when the answer changes, so a press that finds it already claimed pays nothing. A failure
    /// is recorded rather than thrown: a claim is not an audio path, and the path that is will
    /// meet it at `ensureActive`.
    func wantRecord(_ on: Bool, for who: RecordClaim) {
        let was = recordMode
        if on { recordClaims.insert(who) } else { recordClaims.remove(who) }
        // The warm claim another app's playing put off is taken with the exchange's own: a press
        // drops its claim as the microphone closes, before the wait's hold is taken, and the
        // record configuration has to stand from the press to the reply's end, not hand the
        // session back between the two and read the reply over the podcast.
        if on, who != .warm, warmWanted { recordClaims.insert(.warm) }
        guard recordMode != was else { return }
        guard !kept else {
            deferredClaims = true
            AudioLog.say("record \(recordMode ? "claimed" : "dropped") while \(keptBy); the session is left as it is")
            return
        }
        applyOrRemember()
    }

    /// Says whether the microphone is to be heard through voice processing, which is the record
    /// configuration's mode. Like a claim: the session is touched only when its configuration
    /// would change — never for the quiet one, which has no such mode — a failure is recorded
    /// rather than thrown, and while a hold stands or the microphone is open the change waits
    /// for both to go, so a press under a hold finds `voiceProcessed` as the session was left.
    func wantVoiceProcessing(_ on: Bool) {
        guard processed != on else { return }
        processed = on
        guard recordMode else { return }
        guard !kept else {
            deferredClaims = true
            AudioLog.say("voice processing \(on ? "wanted" : "dropped") while \(keptBy); the session is left as it is")
            return
        }
        applyOrRemember()
    }

    /// Says that the chat's microphone is opening (said before its first handle exists, so nothing
    /// is reconfigured under an open in flight) or open, or has closed, its engine stopped. Between the two the session is not reconfigured; the close applies what waited,
    /// as the last hold going does.
    /// Away from the front a close with nothing else keeping the session hands it back, as the
    /// last hold going does, unless it is a microphone suspended across an interruption
    /// (`lettingGo` false): that session is the interruption's for now and comes back at its end,
    /// so nothing is handed back under it.
    func microphone(open: Bool, lettingGo: Bool = true) {
        guard microphoneOpen != open else { return }
        microphoneOpen = open
        guard !open else { return }
        if lettingGo { letGo(after: "the microphone has closed") } else { applyDeferred(after: "the microphone has closed") }
    }

    /// Says that a conversation's input is running on with its gate shut, or has stopped
    /// (`VoiceInput.inputKept`). Between the two the session is not reconfigured, as for an open
    /// microphone; the stop lets the session go as the last hold going does.
    func keptInput(running: Bool, lettingGo: Bool = true) {
        guard inputKept != running else { return }
        inputKept = running
        guard !running else { return }
        if lettingGo { letGo(after: "the kept input has stopped") } else { applyDeferred(after: "the kept input has stopped") }
    }

    /// A conversation began or ended (`Conversation`). From its beginning to its end the record
    /// configuration is claimed and the session is kept as a hold keeps it: no utterance's end, no
    /// reading's or wait's end and no interruption's end between two utterances hands it back or
    /// configures it for playback, so an interruption's end resumes it as the microphone's and the
    /// next utterance opens on it with nothing activated from the background. The end lets the
    /// session go as the last hold going does: what waited is applied in front, and away it is
    /// handed back once nothing else keeps it.
    func conversation(_ on: Bool) {
        guard conversing != on else { return }
        if on {
            wantRecord(true, for: .conversation)
            conversing = true
            AudioLog.say("the conversation keeps the session (record \(recordMode))")
            return
        }
        conversing = false
        let was = recordMode
        recordClaims.remove(.conversation)
        if recordMode != was { deferredClaims = true }
        AudioLog.say("the conversation lets the session go (record \(recordMode))")
        letGo(after: "the conversation has ended")
    }

    /// Brings the record configuration up before the thumb needs it, from the foreground: the
    /// first `playAndRecord` activation of a launch costs a route change, seconds of it on
    /// AirPods, and paying that at the press is what a press feeling slow is. Permission-gated,
    /// so an unasked phone meets the microphone prompt at the button, never on a foreground. Not
    /// taken while another app is playing: the record configuration cannot mix, so taking it
    /// would pause the podcast with nothing said, and Topo takes the session from other audio
    /// only when a spoken exchange starts — that press pays the route change instead, and takes
    /// the warm claim with its own (`wantRecord`), so the exchange keeps the session to its end
    /// and Topo holds it, as it would have, until it leaves the front.
    func warmRecord(_ on: Bool) {
        warmWanted = on
        if on, !recordPermitted() { return }
        if on, otherAudioPlaying() {
            return AudioLog.say("not warming the record configuration: another app is playing")
        }
        wantRecord(on, for: .warm)
    }

    /// The app is in front and would warm the record configuration: the warm claim stands, or
    /// waits for the next press because another app was playing.
    private var warmWanted = false

    /// Claims or drops the hold that keeps the process running when the phone is locked or Topo
    /// is behind another app. Under the `audio` background mode iOS runs a backgrounded process
    /// only while audio is actually rendering, and between the release of a press and the first
    /// frame of the reply nothing is, so the hold is what the play queue's keeper answers.
    func wantAlive(_ on: Bool, for who: Hold) {
        let was = holds
        let wasHolding = holding
        if on { holds.insert(who) } else { holds.remove(who) }
        guard holds != was else { return }
        let by = holds.isEmpty ? "nobody" : holds.map { "\($0)" }.sorted().joined(separator: ", ")
        AudioLog.say("hold \(on ? "taken" : "dropped") by \(who); held by \(by)")
        // Told on every claim while anything is held, not only when the answer changes: a claim
        // taken while another already stands is the moment to retry a keeper an earlier refusal
        // left down, and a hold nothing renders for is a hold on paper.
        guard holding != wasHolding else {
            onHoldChanged?(holding)
            return
        }
        // The speaker first, so the keeper's engine is stopped before the session is let go: a
        // deactivation with an engine still rendering is refused as busy.
        onHoldChanged?(holding)
        if !holding { letGo(after: "the last hold is gone") }
    }

    /// The last hold has gone. In front, what waited is applied, as it is when the microphone
    /// closes; away, the session is handed back (`handBack`), with what waited left for the next
    /// audio path.
    private func letGo(after what: String) {
        guard !kept else { return }
        if isActive() { applyDeferred(after: what) } else { handBack(after: what) }
    }

    /// Whether other audio took up again a second after it was told to, for the log alone: the
    /// hand-back's effect is the other app's to decide, and this is the only sight of it.
    private func noteOtherAudio(after what: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self else { return }
            AudioLog.say("a second after \(what): other audio playing \(self.otherAudioPlaying())")
        }
    }

    /// Topo has finished with the session away from the front: it is deactivated, telling the
    /// audio the press paused — a podcast, music — that it may resume, which the record
    /// configuration going on its own never does. A deactivation is allowed from the background
    /// where an activation is not. The claims that waited stay waiting for the next audio path,
    /// which configures and activates afresh, and a refusal (an engine still rendering) is
    /// logged and leaves the session where it was, marked as needing configuring.
    private func handBack(after what: String) {
        valid = false
        // Marked invalid, the next audio path configures from the claims as they stand, so
        // nothing is owed to a later apply of what waited; and other audio has been told, so the
        // quiet configuration that next path may enter owes it nothing more.
        deferredClaims = false
        do {
            try deactivate(true)
            configuredRecord = nil
            AudioLog.say("\(what) with the app away; the session is handed back and other audio told to resume (record \(recordMode), other audio playing \(otherAudioPlaying()))")
            noteOtherAudio(after: what)
        } catch {
            AudioLog.say("\(what) with the app away; the session could not be handed back: \(error)")
        }
    }

    /// The claim changes a hold or an open microphone stood in the way of, applied once neither
    /// does. The last hold going is as likely to be a reply ending behind the lock as the app
    /// coming back, and a configure from there is refused every time, so it is attempted only in
    /// the foreground; otherwise the session is marked as needing configuring and the claims are
    /// left for the next path that wants audio — the next `ensureActive`, or the foreground's own
    /// warm claim, which applies them as it changes.
    private func applyDeferred(after what: String) {
        guard !kept, deferredClaims else { return }
        deferredClaims = false
        if isActive() {
            AudioLog.say("\(what); the claims are applied (record \(recordMode))")
            applyOrRemember()
        } else {
            valid = false
            AudioLog.say("\(what) with the app away; the claims wait for the next audio path (record \(recordMode))")
        }
    }

    private var keptBy: String {
        holding ? "a hold stands" : microphoneOpen ? "the microphone is open"
            : inputKept ? "the input is kept" : "a conversation lives"
    }

    /// The session as a reply about to be read finds it: the mode, the voice processing it is
    /// configured for, the route and the system's output volume. Read only.
    func describeOutput() -> String {
        let session = AVAudioSession.sharedInstance()
        let route = outputs().map(\.rawValue).joined(separator: ", ")
        return "mode \(session.mode.rawValue), voice processing \(voiceProcessed), "
            + "route \(route.isEmpty ? "none" : route), volume \(String(format: "%.2f", session.outputVolume))"
    }

    /// Holds auto-lock off while someone is listening or speaking; process-wide, so counted.
    func wantScreenAwake(_ on: Bool, for who: ScreenClaim) {
        if on { screenClaims.insert(who) } else { screenClaims.remove(who) }
        let want = !screenClaims.isEmpty
        guard UIApplication.shared.isIdleTimerDisabled != want else { return }
        UIApplication.shared.isIdleTimerDisabled = want
    }

    /// Applies the claims as they stand, keeping a failure rather than throwing it: the caller is
    /// a claim or a reset, neither of which is an audio path. The next `ensureActive` meets it.
    private func applyOrRemember() {
        do {
            try apply()
        } catch {
            AudioLog.say("the session did not configure for record \(recordMode): \(error)")
        }
    }

    private func apply() throws {
        applied = true
        valid = false
        // Leaving the record configuration for the quiet one with nothing held is the exchange's
        // end: the hand-back goes first, so what the press paused is told to resume before the
        // mixable session is activated beside it. Logged, not thrown: the quiet configuration is
        // still wanted whether or not other audio was told. Under a hold or an open microphone
        // the exchange is not over, and other audio is told at the last hold's drop instead.
        if configuredRecord == true, !recordMode, !kept {
            do {
                try deactivate(true)
                AudioLog.say("the record configuration is let go; other audio told to resume")
                noteOtherAudio(after: "the record configuration let go")
            } catch {
                AudioLog.say("the record configuration is let go; other audio could not be told: \(error)")
            }
        }
        try configure(recordMode, processed)
        configuredRecord = recordMode
        voiceProcessed = recordMode && processed
        valid = true
    }

    /// Playback-only until the mic is actually wanted: a `playAndRecord` session prompts for the
    /// microphone the moment it activates. The quiet configuration mixes, so Topo idle does not
    /// stop what else the phone is playing; the record configuration takes the route outright.
    /// HFP is the AirPods mic; without it iOS never offers a headset's input. Deliberately
    /// without `.bluetoothHighQualityRecording`: the wideband link's input latency lands on
    /// AirPods as a press that lags and an utterance that starts clipped. The record
    /// configuration's mode is `voiceChat` when the microphone is heard through voice processing:
    /// the mode the system would set by itself for the voice unit, set here so that it is this
    /// object's, and so that `default` comes back when the unit is turned off.
    static func appIsActive() -> Bool { UIApplication.shared.applicationState == .active }

    nonisolated static func configureSession(record: Bool, processed: Bool) throws {
        try setCategory(record: record, processed: processed)
        try AVAudioSession.sharedInstance().setActive(true)
    }

    nonisolated static func setCategory(record: Bool, processed: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if record {
            try session.setCategory(.playAndRecord, mode: processed ? .voiceChat : .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetoothHFP])
        } else {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
    }

    /// `notifyOthersOnDeactivation` is what tells the app whose audio this session interrupted
    /// that it may resume; without it the podcast paused at the press stays paused.
    nonisolated static func deactivate(notifyingOthers: Bool) throws {
        try AVAudioSession.sharedInstance().setActive(false, options: notifyingOthers ? [.notifyOthersOnDeactivation] : [])
    }
}
#endif
