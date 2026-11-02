#if os(iOS)
import AVFoundation
import Foundation

/// A player for one cue: `AVAudioPlayer` in the app (`EarconPlayer`), a recorder in the suite.
@MainActor
protocol CuePlayer: AnyObject {
    /// Plays the cue from its start and says whether it started. `whenDone` is called on the
    /// main actor once the cue has been heard out, and not for a play that was started again
    /// before then.
    func play(whenDone: @escaping @MainActor () -> Void) -> Bool
}

/// `AVAudioPlayer` as a `CuePlayer`, its own delegate: the player's finish is posted on whatever
/// thread the system chooses, and reaches the main actor here.
@MainActor
final class EarconPlayer: NSObject, CuePlayer, AVAudioPlayerDelegate {
    private let player: AVAudioPlayer
    private var whenDone: (@MainActor () -> Void)?

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        super.init()
        player.delegate = self
        player.prepareToPlay()
    }

    func play(whenDone: @escaping @MainActor () -> Void) -> Bool {
        self.whenDone = whenDone
        player.currentTime = 0
        return player.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            let done = self.whenDone
            self.whenDone = nil
            done?()
        }
    }
}

/// The four cues a spoken exchange sounds — `listening` as the microphone opens at a press,
/// `sent` at a release that heard words, `done` as a reply read aloud comes to its end, and
/// `failed` when a release heard nothing or a spoken turn fails — each a UI SFX Zen sound (CC0,
/// `THIRD-PARTY`) bundled as `earcon_<cue>.mp3`. On unless turned off (`EarconsSetting`: a toggle
/// in the settings sheet and `topo voice earcons`).
///
/// A cue is a moment, not a reply. It is played on the session as it stands, after
/// `AudioSession.ensureActive()` has returned and refused when it throws, and reconfigures
/// nothing. Where a hold already stands it holds the process for its own length too
/// (`AudioSession.Hold.cue`, let go when the player has finished or at `bound`), taken before the
/// player starts, so that `done` behind the lock is heard out before the reply's own hold goes
/// and the last hold is let go of; its caller plays it before dropping the hold it follows, so
/// the process is never let go of between the two. With nothing held — a press in front — a cue
/// holds nothing, so a claim change waits on no cue. Nothing but `listening` is played into an
/// open microphone. The players are handles into
/// mediaserverd: a media services reset drops them and builds nothing, and the next cue makes
/// its own afresh. Lifted from Daphne's `Earcons`, per `THIRD-PARTY`. Main only.
@MainActor
final class Earcons {
    enum Cue: String, CaseIterable, Sendable {
        case listening, sent, done, failed

        /// The bundled file's name, without its extension.
        var file: String { "earcon_\(rawValue)" }

        /// What a press or a release that sends `heard` sounds: words went, or nothing did.
        static func sending(_ heard: String) -> Cue { heard.isEmpty ? .failed : .sent }
    }

    /// How long a cue's hold stands at most: a player whose finish never comes is let go of here,
    /// so no hold outlives the cue it was taken for by more than this.
    static let bound: Duration = .seconds(2)

    private let audio: AudioSession
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let makePlayer: @MainActor (URL) throws -> any CuePlayer
    private let sleep: @Sendable (Duration) async throws -> Void
    /// Whether a microphone is open or opening; `Speaker` answers it.
    var microphoneOpen: @MainActor () -> Bool = { false }
    private var players: [Cue: any CuePlayer] = [:]
    /// The cue being played, by serial, so a finish or a bound of an earlier one moves nothing.
    private var playing: Int?
    /// Whether the cue holds the process (`AudioSession.Hold.cue`), which it does only when a
    /// hold already stood as it began: a cue extends a held reply or wait and never holds alone.
    private var holding = false
    private var serial = 0
    private var bounding: Task<Void, Never>?
    private var resetObserver: NSObjectProtocol?
    #if DEBUG
    /// Every cue played, in order, for a test.
    private(set) var played: [Cue] = []
    #endif

    init(audio: AudioSession, center: NotificationCenter = .default, defaults: UserDefaults = .standard,
         bundle: Bundle = .main,
         makePlayer: @escaping @MainActor (URL) throws -> any CuePlayer = { try EarconPlayer(url: $0) },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.audio = audio
        self.defaults = defaults
        self.bundle = bundle
        self.makePlayer = makePlayer
        self.sleep = sleep
        resetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mediaServicesWereReset() }
        }
    }

    /// iOS reset the media server: the players were handles into it and are dropped, and the cue
    /// that was playing is over with it. Nothing is built here; the next cue makes its own.
    private func mediaServicesWereReset() {
        players = [:]
        if let playing { ended(playing, "the media server was reset") }
        AudioLog.say("media services reset: the earcons' players dropped")
    }

    /// Sounds `cue`, and says whether it was played. Nothing is played with the setting off,
    /// into an open microphone (`listening` excepted, which is the microphone's own), on a
    /// session that will not activate, or for a file the bundle lacks.
    @discardableResult
    func play(_ cue: Cue) -> Bool {
        guard EarconsSetting.enabled(defaults) else { return false }
        if cue != .listening, microphoneOpen() {
            AudioLog.say("earcon \(cue) not played: the microphone is open")
            return false
        }
        do {
            try audio.ensureActive()
        } catch {
            AudioLog.say("earcon \(cue) refused: the session did not activate: \(error)")
            return false
        }
        guard let player = player(for: cue) else { return false }
        serial += 1
        let mine = serial
        bounding?.cancel()
        playing = mine
        // The hold before the player, so the process is held from the cue's first frame; only
        // where a hold already stands, since in front nothing suspends and a cue that held alone
        // would keep a claim change waiting for nothing.
        if audio.holding {
            audio.wantAlive(true, for: .cue)
            holding = true
        }
        guard player.play(whenDone: { [weak self] in self?.ended(mine, "heard out") }) else {
            AudioLog.say("earcon \(cue) did not start")
            ended(mine, "it did not start")
            return false
        }
        AudioLog.say("earcon \(cue)")
        #if DEBUG
        played.append(cue)
        #endif
        bounding = Task { [sleep] in
            try? await sleep(Self.bound)
            guard !Task.isCancelled else { return }
            self.ended(mine, "its bound passed")
        }
        return true
    }

    /// The cue `mine` is over, one way or another: its hold goes. Free for any other cue's.
    private func ended(_ mine: Int, _ why: String) {
        guard playing == mine else { return }
        playing = nil
        bounding?.cancel()
        bounding = nil
        AudioLog.say("earcon over: \(why)")
        guard holding else { return }
        holding = false
        audio.wantAlive(false, for: .cue)
    }

    private func player(for cue: Cue) -> (any CuePlayer)? {
        if let player = players[cue] { return player }
        guard let url = bundle.url(forResource: cue.file, withExtension: "mp3") else {
            AudioLog.say("earcon \(cue) is not bundled")
            return nil
        }
        do {
            let player = try makePlayer(url)
            players[cue] = player
            return player
        } catch {
            AudioLog.say("earcon \(cue) has no player: \(error)")
            return nil
        }
    }
}

/// Whether the cues sound at all: the settings sheet's toggle, kept in the defaults.
enum EarconsSetting {
    static let key = "earcons"

    /// On unless turned off: a phone that has never been asked sounds them.
    static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) == nil || defaults.bool(forKey: key)
    }
}
#endif
