#if os(iOS)
import AVFoundation
import MediaPlayer
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
    enum RecordClaim: Hashable { case firstRun, chat, warm }
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
    /// Where the session is with the CallKit call a spoken exchange behind the lock is
    /// (`SpokenCall`). From the call's placing until the system says it is over the session is
    /// the system's: `placed` is set and not yet activated, `active` is held active by the system
    /// at the call's priority, `deactivated` is taken away with the call still standing (a phone
    /// call holds it), `closing` is ended and on its way back, still active until the system
    /// deactivates it about a second later. Nothing here activates or hands back while the phase
    /// is not `none`.
    enum CallPhase { case none, placed, active, deactivated, closing }
    /// A path wanted the session while the call's phase has it the system's and not active.
    struct CallNotActive: Error, CustomStringConvertible {
        let phase: CallPhase
        var description: String {
            switch phase {
            case .placed: "the call's session is placed and not yet activated"
            case .active: "the call's session is the system's; nothing here configures it"
            case .deactivated: "the call's session is deactivated with the call standing"
            case .closing: "the call's session is closing; the system deactivates it"
            case .none: "no call"
            }
        }
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
    /// Sets the category and the mode as `configure` does and activates nothing: the call's
    /// configuration, which the system activates itself.
    private let setCategory: (Bool, Bool) throws -> Void
    /// Deactivates the session, telling other audio it may resume when asked to (the hand-back).
    private let deactivate: (_ notifyingOthers: Bool) throws -> Void
    private(set) var call: CallPhase = .none
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
    /// True while an input is kept running past a spoken release for the call's placing
    /// (`VoiceInput.inputKept`): its tap is on the format the session gave, so it keeps the
    /// session as an open microphone does.
    private var inputKept = false
    /// Whether the session is to be left as it is: a hold stands, the microphone is open, or an
    /// input is kept.
    private var kept: Bool { holding || microphoneOpen || inputKept }
    /// Told, with why, when the input kept past a release has nothing left to be kept for: the
    /// last hold that is a turn's going (`heldForATurn` true to false), told after the speaker
    /// has heard of it (so its keeper has stopped) and before the session is let go, so the input never runs under a session
    /// being reconfigured or handed back; and a reply beginning to be read (`.speaking` taken),
    /// since the input's voice unit ducks every other sound on the phone, the reply among them.
    var endKeptInput: ((String) -> Void)?
    /// True only between a configuration that activated the session and the next reset or failure.
    private var valid = false
    private var resetObserver: NSObjectProtocol?
    /// The outputs the session is routed to now, by port type (`currentRoute`).
    private let outputs: @MainActor () -> [AVAudioSession.Port]
    /// Overrides the output to the speaker, or clears the override.
    private let speakerOverride: @MainActor (Bool) throws -> Void
    /// Whether the call's activation overrode the earpiece to the speaker.
    private var overridden = false

    /// iOS resetting the media server leaves the session at its default category and inactive, so
    /// the configuration the claims asked for is applied again; a session never configured is left
    /// alone, since activating it is not the reset's to decide.
    init(center: NotificationCenter = .default,
         configure: @escaping (Bool, Bool) throws -> Void = AudioSession.configureSession(record:processed:),
         setCategory: @escaping (Bool, Bool) throws -> Void = AudioSession.setCategory(record:processed:),
         deactivate: @escaping (Bool) throws -> Void = AudioSession.deactivate(notifyingOthers:),
         isActive: @escaping @MainActor () -> Bool = AudioSession.appIsActive,
         otherAudioPlaying: @escaping @MainActor () -> Bool = { AVAudioSession.sharedInstance().isOtherAudioPlaying },
         recordPermitted: @escaping @MainActor () -> Bool = { AVAudioApplication.shared.recordPermission == .granted },
         outputs: @escaping @MainActor () -> [AVAudioSession.Port] = { AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType) },
         speakerOverride: @escaping @MainActor (Bool) throws -> Void = { try AVAudioSession.sharedInstance().overrideOutputAudioPort($0 ? .speaker : .none) }) {
        self.outputs = outputs
        self.speakerOverride = speakerOverride
        self.configure = configure
        self.otherAudioPlaying = otherAudioPlaying
        self.recordPermitted = recordPermitted
        self.setCategory = setCategory
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
    /// The reset count the call's session was activated under: a reset since is the call's
    /// session gone with every handle on it, until the system activates it again.
    private var resetsAtActivation = 0

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
        switch call {
        case .active:
            // The system holds the session active for the call, and nothing here doubts it: a
            // `.began` iOS posts at the lock screen with a call up is not the session gone.
            return
        case .placed, .deactivated, .closing:
            // A closing session is still active, and the system takes it a second later with
            // whatever was put on it: a press or a reading started now would be cut there.
            throw CallNotActive(phase: call)
        case .none:
            guard !valid else { return }
            try apply()
        }
    }

    /// The first call of a sound that is a moment rather than a path (a cue, a receipt): free on a live
    /// session, as `ensureActive` is, and a refusal on one that is not, since a moment configures
    /// nothing. Behind the lock, after an interruption took the session, `ensureActive` would be
    /// the session reconfigured and activated from the background under a hold, for a cue.
    /// Judged by the call's phase, as `ensureActive` is, and by the reset count: under an active call the session is the
    /// system's and live whatever marked it otherwise (a claim deferred as the microphone closed
    /// away, ahead of the turn's hold) but a media services reset since its activation, and on
    /// its way to the system or back it is not.
    func ensureLive() throws {
        switch call {
        case .active: guard resets == resetsAtActivation else { throw NotLive() }
        case .placed, .deactivated, .closing: throw NotLive()
        case .none: guard valid else { throw NotLive() }
        }
    }

    struct NotLive: Error, CustomStringConvertible {
        var description: String { "the session is not live" }
    }

    /// Marks the session as needing configuring again, for a caller that found the audio dead
    /// under a session this object believed was live.
    /// Under an active call it changes nothing: the session is the system's and live until the
    /// system says otherwise (`callDeactivated`, `callOver`), and a `.began` iOS posts at the lock
    /// screen or as the call takes the session is not the session gone.
    func invalidate() {
        guard call != .active else { return }
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
    func microphone(open: Bool) {
        guard microphoneOpen != open else { return }
        microphoneOpen = open
        if !open {
            clearOverride(after: "the microphone has closed")
            applyDeferred(after: "the microphone has closed")
        }
    }

    /// Says that an input kept past a release is running, or has stopped (`VoiceInput.inputKept`).
    /// Between the two the session is not reconfigured, as for an open microphone; the stop
    /// applies what waited.
    func keptInput(running: Bool) {
        guard inputKept != running else { return }
        inputKept = running
        if !running {
            clearOverride(after: "the kept input has stopped")
            applyDeferred(after: "the kept input has stopped")
        }
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
        let wasForATurn = heldForATurn
        if on { holds.insert(who) } else { holds.remove(who) }
        guard holds != was else { return }
        let by = holds.isEmpty ? "nobody" : holds.map { "\($0)" }.sorted().joined(separator: ", ")
        AudioLog.say("hold \(on ? "taken" : "dropped") by \(who); held by \(by)")
        // With no turn held there is no call to place, so a kept input stops: after the speaker
        // has heard, so its keeper's engine is stopped before the stop applies what waited, and
        // before the session is let go, so nothing is reconfigured or handed back under the tap.
        let noTurn = wasForATurn && !heldForATurn
        if on, who == .speaking { endKeptInput?("the reply is being read") }
        // Told on every claim while anything is held, not only when the answer changes: a claim
        // taken while another already stands is the moment to retry a keeper an earlier refusal
        // left down, and a hold nothing renders for is a hold on paper.
        guard holding != wasHolding else {
            onHoldChanged?(holding)
            if noTurn { endKeptInput?("no turn is held") }
            return
        }
        // The speaker first, so the keeper's engine is stopped before the session is let go: a
        // deactivation with an engine still rendering is refused as busy.
        onHoldChanged?(holding)
        if noTurn { endKeptInput?("no turn is held") }
        if !holding {
            clearOverride(after: "the last hold is gone")
            letGo(after: "the last hold is gone")
        }
    }

    /// Clears the call's speaker override once the call is over and nothing keeps the session:
    /// a route change under an open microphone's tap or a reply's engine is the change the
    /// session is kept from, so with either standing it waits for the last of them.
    private func clearOverride(after what: String) {
        guard overridden, call == .none, !kept else { return }
        overridden = false
        do {
            try speakerOverride(false)
            AudioLog.say("\(what): the call's speaker override is cleared")
        } catch {
            AudioLog.say("\(what): the call's speaker override did not clear: \(error)")
        }
    }

    /// The last hold has gone. In front, what waited is applied, as it is when the microphone
    /// closes; away, the session is handed back (`handBack`), with what waited left for the next
    /// audio path; under a call nothing is let go until the system says the call is over
    /// (`callOver`), since the session is the system's until then.
    private func letGo(after what: String) {
        guard !kept else { return }
        guard call == .none else {
            AudioLog.say("\(what) under the call; the session is the system's until it is over")
            return
        }
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

    /// True while the call's session is on its way to the system or back from it: placed and
    /// not yet activated, taken with the call standing, or closing. A reply landing then waits
    /// for the activation or the call's end (`Speaker`), as one does for an open microphone, and
    /// a press waits for the same (`settled`).
    var callChangingHands: Bool { call == .placed || call == .deactivated || call == .closing }

    private var settling: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Waits until the call's session is no longer changing hands — activated, or the call over
    /// — or for `bound`, whichever is first, and answers whether it settled. Free when it is not
    /// changing hands. A press waits here rather than being refused, since the window is the
    /// second after a reply ends, which is when a person answers. Each wait's bound ends that
    /// wait alone.
    func settled(within bound: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> Bool {
        guard callChangingHands else { return true }
        let id = UUID()
        let timer = Task { @MainActor [weak self] in
            try? await sleep(bound)
            guard !Task.isCancelled else { return }
            self?.settling.removeValue(forKey: id)?.resume()
        }
        await withCheckedContinuation { settling[id] = $0 }
        timer.cancel()
        return !callChangingHands
    }

    private func releaseSettling() {
        let waiting = settling.values
        settling = [:]
        waiting.forEach { $0.resume() }
    }

    /// The call was ended, by Topo or from the card: the session stays the system's, active,
    /// until its deactivation (`callOver`), and nothing new is put on it meanwhile.
    func callClosing() {
        // A call refused before the system performed its start never took the session.
        guard call != .none, call != .closing else { return }
        call = .closing
        valid = false
        AudioLog.say("call closing: nothing new goes on the session until it is over")
    }

    /// `SpokenCall`'s `onStart`: the system is placing the call and will activate the session
    /// itself, so the record configuration is set with the mode as it stands and nothing is
    /// activated, and the session is not this object's again until `callActivated`. A category
    /// that will not set is logged: the call goes on without it, on whatever the session was.
    func callPlaced() {
        // The input kept for the placing stops before the call's category is set on its session.
        endKeptInput?("the call is placed: the session is the system's")
        call = .placed
        valid = false
        // The mode the session is in, not the one wanted: a change of voice processing asked for
        // while a hold or the microphone keeps the session waits for them (`deferredClaims`), and
        // the call is placed only while a hold stands. From a session not in the record
        // configuration no unit has a mode to keep, so the wanted one is set.
        let mode = configuredRecord == true ? voiceProcessed : processed
        do {
            try setCategory(true, mode)
            configuredRecord = true
            voiceProcessed = mode
            AudioLog.say("call placed: the record configuration is set (voice processing \(mode), \(mode == processed ? "as wanted" : "as applied; \(processed) waits")); the system activates")
        } catch {
            AudioLog.say("call placed: the category did not set: \(error)")
        }
    }

    /// The session as a call's placing finds it, for the line each placing logs: the call service
    /// judges whether the person meant the call from the app's state as it is asked, so a refusal
    /// is read against these.
    func describePlacing(inputRunning: Bool) -> String {
        let session = AVAudioSession.sharedInstance()
        return Self.placing(category: session.category.rawValue, options: session.categoryOptions,
                            mode: session.mode.rawValue, inputRunning: inputRunning,
                            nowPlaying: MPNowPlayingInfoCenter.default().nowPlayingInfo != nil)
    }

    /// The placing's line from its facts, every field named.
    nonisolated static func placing(category: String, options: AVAudioSession.CategoryOptions, mode: String,
                                    inputRunning: Bool, nowPlaying: Bool) -> String {
        let named: [(AVAudioSession.CategoryOptions, String)] = [
            (.mixWithOthers, "mixWithOthers"), (.duckOthers, "duckOthers"),
            (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudioAndMixWithOthers"),
            (.allowBluetoothHFP, "allowBluetoothHFP"), (.allowBluetoothA2DP, "allowBluetoothA2DP"),
            (.allowAirPlay, "allowAirPlay"), (.defaultToSpeaker, "defaultToSpeaker"),
            (.overrideMutedMicrophoneInterruption, "overrideMutedMicrophoneInterruption"),
        ]
        let said = named.filter { options.contains($0.0) }.map(\.1)
        return "category \(category), options [\(said.joined(separator: ", "))], mode \(mode), "
            + "input running \(inputRunning), now playing \(nowPlaying)"
    }

    /// The session as a reply about to be read finds it: the call's phase, the mode, the voice
    /// processing it is configured for, the route and the system's output volume. Read only.
    func describeOutput() -> String {
        let session = AVAudioSession.sharedInstance()
        let route = outputs().map(\.rawValue).joined(separator: ", ")
        return "call \(call), mode \(session.mode.rawValue), voice processing \(voiceProcessed), "
            + "route \(route.isEmpty ? "none" : route), overridden \(overridden), volume \(String(format: "%.2f", session.outputVolume))"
    }

    /// The system activated the session for the call: it is live, at the call's priority, and
    /// stays so until `callDeactivated` or `callOver`.
    func callActivated() {
        call = .active
        applied = true
        valid = true
        resetsAtActivation = resets
        defer { releaseSettling() }
        // CallKit routes an activated call to the earpiece, whatever the category's
        // `defaultToSpeaker` says: a reply read there is not heard from a phone held away or
        // lying down. Overridden to the speaker only from the earpiece, so AirPods, a car or
        // headphones keep the call. A route override, not a category or an activation, made
        // before the speaker's rebuild puts an engine on the new session.
        let route = outputs()
        if route.contains(.builtInReceiver) {
            do {
                try speakerOverride(true)
                overridden = true
                AudioLog.say("call activated: the session is the system's and live; the earpiece overridden to the speaker")
            } catch {
                AudioLog.say("call activated: the session is the system's and live; the earpiece could not be overridden: \(error)")
            }
        } else {
            AudioLog.say("call activated: the session is the system's and live (route \(route.map(\.rawValue).joined(separator: ", ")))")
        }
    }

    /// The system took the session with the call still standing (a phone call holds this one):
    /// nothing is valid until it activates again.
    func callDeactivated() {
        call = .deactivated
        valid = false
        AudioLog.say("call deactivated with the call standing: the session is not live")
    }

    /// The call is over, ended or failed, and the session is this object's again, inactive. With
    /// a hold standing or the microphone open nothing is done here: the speaker re-ensures for
    /// its keeper, in front where that is allowed. With nothing kept, in front the claims that
    /// waited are applied; away, the session is handed back so what the exchange paused resumes.
    func callOver() {
        // A call refused before the system performed its start never took the session.
        guard call != .none else { return }
        call = .none
        valid = false
        releaseSettling()
        clearOverride(after: "the call is over")
        AudioLog.say("call over: other audio playing \(otherAudioPlaying())")
        guard !kept else {
            AudioLog.say("call over with \(keptBy); the session waits for the next audio path")
            return
        }
        if isActive() {
            if deferredClaims {
                deferredClaims = false
                AudioLog.say("call over; the claims are applied (record \(recordMode))")
                applyOrRemember()
            } else {
                AudioLog.say("call over in front; the session waits for the next audio path")
            }
        } else {
            handBack(after: "the call is over")
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
        holding ? "a hold stands" : microphoneOpen ? "the microphone is open" : "the input is kept"
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
        // Nothing activates beside the call: the claims wait for `callOver`.
        guard call == .none else {
            deferredClaims = true
            throw CallNotActive(phase: call)
        }
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
