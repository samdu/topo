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
    enum RecordClaim: Hashable { case firstRun, chat, warm }
    enum ScreenClaim: Hashable { case listening, speaking }
    /// Who is keeping the process running behind the lock: the wait for a spoken turn's reply,
    /// one claim per turn outstanding, and the reading of a reply. Counted like the other two, so
    /// the one letting go cannot cut what the other is still paying for — a reply handed to the
    /// speaker drops its own turn's wait with `.speaking` already taken, the keeper never stops
    /// between them, and a second thing said while the first is in flight is still held for.
    enum Hold: Hashable {
        case awaitingReply(String)
        case speaking
    }

    private var recordClaims: Set<RecordClaim> = []
    private var screenClaims: Set<ScreenClaim> = []
    private var holds: Set<Hold> = []
    /// Told the answer whenever it changes. The count is the session's; the engine that renders
    /// the silence is the play queue's, so `Speaker` — the one object holding both — is what
    /// starts and stops the keeper.
    var onHoldChanged: ((Bool) -> Void)?
    /// True while anything wants the process kept alive.
    var holding: Bool { !holds.isEmpty }
    private var recordMode: Bool { !recordClaims.isEmpty }
    /// Sets the session's category for record mode (true) or the quiet one (false) and activates
    /// it, throwing when either refuses: activation is commonly refused while another app is in
    /// front, which is exactly where a media services reset is asked for.
    private let configure: (Bool) throws -> Void
    /// True once the session has been configured; a reset re-applies only a session that was.
    private var applied = false
    /// A claim change that came in while a hold stood, waiting for the last hold to drop. The
    /// session a reply is being waited for on is not reconfigured underneath it: activating or
    /// reconfiguring a non-mixable session from the background is refused
    /// (`cannotInterruptOthers`), which would leave the session invalid and every later
    /// `ensureActive` trying the same refused call from behind the lock. The session that was
    /// active at the release stays active and untouched, whatever category it was in, until the
    /// reply has been heard — the keeper is already rendering on it, and an already-active session
    /// goes on rendering in the background under the `audio` mode.
    private var deferredClaims = false
    /// True only between a configuration that activated the session and the next reset or failure.
    private var valid = false
    private var resetObserver: NSObjectProtocol?

    /// iOS resetting the media server leaves the session at its default category and inactive, so
    /// the configuration the claims asked for is applied again; a session never configured is left
    /// alone, since activating it is not the reset's to decide.
    init(center: NotificationCenter = .default,
         configure: @escaping (Bool) throws -> Void = AudioSession.configureSession(record:)) {
        self.configure = configure
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
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

    /// Marks the session as needing configuring again, for a caller that found the audio dead
    /// under a session this object believed was live.
    func invalidate() { valid = false }

    /// Claims or drops the record configuration for one surface. The session is touched only
    /// when the answer changes, so a press that finds it already claimed pays nothing. A failure
    /// is recorded rather than thrown: a claim is not an audio path, and the path that is will
    /// meet it at `ensureActive`.
    func wantRecord(_ on: Bool, for who: RecordClaim) {
        let was = recordMode
        if on { recordClaims.insert(who) } else { recordClaims.remove(who) }
        guard recordMode != was else { return }
        guard !holding else {
            deferredClaims = true
            AudioLog.say("record \(recordMode ? "claimed" : "dropped") while a hold stands; the session is left as it is")
            return
        }
        applyOrRemember()
    }

    /// Brings the record configuration up before the thumb needs it, from the foreground: the
    /// first `playAndRecord` activation of a launch costs a route change, seconds of it on
    /// AirPods, and paying that at the press is what a press feeling slow is. Permission-gated,
    /// so an unasked phone meets the microphone prompt at the button, never on a foreground.
    func warmRecord(_ on: Bool) {
        if on, AVAudioApplication.shared.recordPermission != .granted { return }
        wantRecord(on, for: .warm)
    }

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
        guard holding != wasHolding else { return }
        // The claim changes the hold stood in the way of, applied once now that nothing is being
        // kept alive — the foreground is where a reconfiguration is allowed, and the app is back
        // in it or done with the reply by the time the last hold goes.
        if !holding, deferredClaims {
            deferredClaims = false
            AudioLog.say("the last hold is gone; the claims are applied (record \(recordMode))")
            applyOrRemember()
        }
        onHoldChanged?(holding)
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
        try configure(recordMode)
        valid = true
    }

    /// Playback-only until the mic is actually wanted: a `playAndRecord` session prompts for the
    /// microphone the moment it activates. The quiet configuration mixes, so Topo idle does not
    /// stop what else the phone is playing; the record configuration takes the route outright.
    /// HFP is the AirPods mic; without it iOS never offers a headset's input. Deliberately
    /// without `.bluetoothHighQualityRecording`: the wideband link's input latency lands on
    /// AirPods as a press that lags and an utterance that starts clipped.
    nonisolated static func configureSession(record: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        if record {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetoothHFP])
        } else {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try session.setActive(true)
    }
}
#endif
