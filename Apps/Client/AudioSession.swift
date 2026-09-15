#if os(iOS)
import AVFoundation
import UIKit

/// The process-wide audio resources, counted rather than assigned: the record configuration of
/// the audio session and the warm microphone it buys, and the idle timer. Two surfaces reach for
/// each (the first-run screen and the chat), and the one leaving must not hand the route or
/// auto-lock back under the one arriving. The pattern is Daphne's `TurnController` (Sam's own
/// iOS app, `clients/ios` in samdu/daphne-assistant).
@MainActor
final class AudioSession {
    enum RecordClaim: Hashable { case firstRun, chat, warm }
    enum ScreenClaim: Hashable { case listening, speaking }

    private var recordClaims: Set<RecordClaim> = []
    private var screenClaims: Set<ScreenClaim> = []
    private var recordMode: Bool { !recordClaims.isEmpty }
    /// Sets the session's category for record mode (true) or the quiet one (false) and activates it.
    private let configure: (Bool) -> Void
    /// True once the session has been configured; a reset re-applies only a session that was.
    private var applied = false
    private var resetObserver: NSObjectProtocol?

    /// iOS resetting the media server leaves the session at its default category and inactive, so
    /// the configuration the claims asked for is applied again; a session never configured is left
    /// alone, since activating it is not the reset's to decide.
    init(center: NotificationCenter = .default, configure: @escaping (Bool) -> Void = AudioSession.configureSession(record:)) {
        self.configure = configure
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
    }

    private func mediaServicesWereReset() {
        guard applied else { return }
        #if DEBUG
        DebugRun.say("media services reset: audio session re-applied (record \(recordMode))")
        #endif
        apply()
    }

    /// Claims or drops the record configuration for one surface. The session is touched only
    /// when the answer changes, so a press that finds it already claimed pays nothing.
    func wantRecord(_ on: Bool, for who: RecordClaim) {
        let was = recordMode
        if on { recordClaims.insert(who) } else { recordClaims.remove(who) }
        guard recordMode != was else { return }
        apply()
    }

    /// Brings the record configuration up before the thumb needs it, from the foreground: the
    /// first `playAndRecord` activation of a launch costs a route change, seconds of it on
    /// AirPods, and paying that at the press is what a press feeling slow is. Permission-gated,
    /// so an unasked phone meets the microphone prompt at the button, never on a foreground.
    func warmRecord(_ on: Bool) {
        if on, AVAudioApplication.shared.recordPermission != .granted { return }
        wantRecord(on, for: .warm)
    }

    /// Holds auto-lock off while someone is listening or speaking; process-wide, so counted.
    func wantScreenAwake(_ on: Bool, for who: ScreenClaim) {
        if on { screenClaims.insert(who) } else { screenClaims.remove(who) }
        let want = !screenClaims.isEmpty
        guard UIApplication.shared.isIdleTimerDisabled != want else { return }
        UIApplication.shared.isIdleTimerDisabled = want
    }

    private func apply() {
        applied = true
        configure(recordMode)
    }

    /// Playback-only until the mic is actually wanted: a `playAndRecord` session prompts for the
    /// microphone the moment it activates. The quiet configuration mixes, so Topo idle does not
    /// stop what else the phone is playing; the record configuration takes the route outright.
    /// HFP is the AirPods mic; without it iOS never offers a headset's input. Deliberately
    /// without `.bluetoothHighQualityRecording`: the wideband link's input latency lands on
    /// AirPods as a press that lags and an utterance that starts clipped.
    nonisolated static func configureSession(record: Bool) {
        let session = AVAudioSession.sharedInstance()
        if record {
            try? session.setCategory(.playAndRecord, mode: .default,
                                     options: [.defaultToSpeaker, .allowBluetoothA2DP, .allowBluetoothHFP])
        } else {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try? session.setActive(true)
    }
}
#endif
