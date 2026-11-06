#if os(iOS)
import AVFoundation
import Foundation
import TopoUserland

/// What a spoken turn sounds like while Topo works on it: nothing, the receipts, or the receipts
/// over a working bed. Kept in this device's defaults as the case's name and read at each sound,
/// so a change is the next one's.
enum WorkingSounds {
    enum Mode: String, CaseIterable, Sendable {
        case off, receipts, sounds

        var label: String {
            switch self {
            case .off: "Off"
            case .receipts: "Receipts"
            case .sounds: "Sounds"
            }
        }
    }

    static let key = "workingSounds"
    /// Receipts for a phone never asked.
    static let standard = Mode.receipts

    /// The one reader: anything kept that is not one of the cases — a word nobody chose, a Boolean,
    /// which `string(forKey:)` hands back as a digit — is the standard.
    static func mode(_ defaults: UserDefaults = .standard) -> Mode {
        Mode(rawValue: defaults.string(forKey: key) ?? "") ?? standard
    }
}

/// A player as the receipts and the bed need one: `AVAudioPlayer`'s own surface, over it in the
/// app (`WorkingAudioPlayer`) and a recorder in the suite.
@MainActor
protocol WorkingPlayer: AnyObject {
    var volume: Float { get set }
    var numberOfLoops: Int { get set }
    var currentTime: TimeInterval { get set }
    var isPlaying: Bool { get }
    @discardableResult func play() -> Bool
    func pause()
    func setVolume(_ volume: Float, fadeDuration: TimeInterval)
}

/// `AVAudioPlayer` as a `WorkingPlayer`.
@MainActor
final class WorkingAudioPlayer: WorkingPlayer {
    private let player: AVAudioPlayer

    init(url: URL) throws {
        player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }
    var numberOfLoops: Int {
        get { player.numberOfLoops }
        set { player.numberOfLoops = newValue }
    }
    var currentTime: TimeInterval {
        get { player.currentTime }
        set { player.currentTime = newValue }
    }
    var isPlaying: Bool { player.isPlaying }
    func play() -> Bool { player.play() }
    func pause() { player.pause() }
    func setVolume(_ volume: Float, fadeDuration: TimeInterval) { player.setVolume(volume, fadeDuration: fadeDuration) }
}

/// The keeper's sounds: what a phone in a pocket hears of a spoken turn being worked on, as
/// Daphne's are, with her bloops (Sam's own, `THIRD-PARTY`) bundled as `bloop_<tone>.wav`. The
/// receipts are tool-class tones, each tool classed as her voice channel classes it
/// (`tone(forTool:)`): `read`, `write`, `delegate` and `act` for everything else; `return` as a
/// delegate's result comes back, `error` for a result marked an error and when the guest's turn
/// fails. The open microphone has `ack` at an utterance's onset and the go-ahead (`speak`), and a
/// press heard behind a turn on its way bleeps (`queue`). The bed is `thinking_bed.wav`, an 8 s
/// loop under −20 dBFS at `bedVolume`, faded in from the release and out when the wait it was for
/// ends (a reply landing ends its own wait before its first frame) or at the reply's first frame
/// under a second wait, never begun under a sentence, and paused rather than stopped so the next
/// wait picks it up where the last left it. The mode is `WorkingSounds`: `off` sounds nothing,
/// `receipts` the tones, `sounds` the tones over the bed.
///
/// The receipts and the bleep are the keeper's, so they sound only while a hold that is not a
/// sound's own stands (`AudioSession.heldForATurn`): a typed turn, which holds nothing, makes
/// none, and a typed turn worked on while a spoken turn's wait stands receipts with it. The
/// conversation's tones sound under the conversation, which the call or the front keeps running.
/// They sound over Topo's voice and into an open microphone, as Daphne's do, and tell the
/// conversation their length (`toneSounded`), which shuts its gate under them. Every sound is
/// played on the session as it stands, live (`AudioSession.ensureLive()`) and refused when it is
/// not, so it configures and activates nothing, and the bed dips while a microphone is open.
/// Where a turn's hold already stands a sound holds the process for its own length too
/// (`AudioSession.Hold.sound`, standing while a receipt's length or the bed's fade-out is not yet
/// up, each its own, `bound` at most), taken before it starts and before the hold it follows
/// drops, so an error receipt and the bed's fade behind the lock are heard out before the last
/// hold is let go of; with nothing held it holds nothing. The
/// players are handles into mediaserverd: a media services reset drops them and builds nothing,
/// and the next sound makes its own. Each is kept with the session's reset count it was made
/// under (`AudioSession.resets`, counted at the notification) and checked against it before
/// anything touches it, so a sound between the session's handler and the speaker's finds a
/// stale player and drops it. An interruption stops the bed under a wait that still wants it, so
/// the speaker asks for it again at the interruption's end (`Speaker.resumeAudio`, `resume`); a
/// resume the session refuses leaves it wanted, for the next.
///
/// Lifted from Daphne's `Keeper` and `WaitSounds`, per `THIRD-PARTY`. Main only.
@MainActor
final class KeeperSounds {
    enum Tone: String, CaseIterable, Sendable {
        case read, act, write, delegate, `return`, error, ack, speak, queue

        /// The bundled file's name, without its extension.
        var file: String { "bloop_\(rawValue)" }
    }

    static let bedFile = "thinking_bed"
    /// The bed is a room tone, not a track: well below speech (the loop itself peaks at −20 dBFS).
    static let bedVolume: Float = 0.5
    /// While the microphone is open over it, so the ear gets the words and not the bed.
    static let duckedVolume: Float = 0.1
    /// Slow enough in that a reply arriving in the first second never makes the bed an event;
    /// fast enough out that it never talks over the reply.
    static let fadeIn: TimeInterval = 1.5
    static let fadeOut: TimeInterval = 0.25
    /// The longest receipt, with room: how long a receipt's hold stands.
    static let toneLength: Duration = .milliseconds(400)
    /// The bed's fade-out, with room: how long its hold stands, and when it is paused.
    static let parkAfter: Duration = .milliseconds(300)
    /// How long a sound's hold stands at most, so no hold outlives the sound it was taken for.
    static let bound: Duration = .seconds(2)

    private let audio: AudioSession
    private let defaults: UserDefaults
    private let bundle: Bundle
    private let makePlayer: @MainActor (URL) throws -> any WorkingPlayer
    private let sleep: @Sendable (Duration) async throws -> Void
    private var players: [Tone: any WorkingPlayer] = [:]
    private var bed: (any WorkingPlayer)?
    /// The reset count the players were made under (`AudioSession.resets`): one made before a
    /// reset is a dead handle however live the session is now.
    private var madeUnder = 0
    /// Whether the waits want the bed, which is not whether it is playing: a start or a resume
    /// the session refused leaves it wanted, so the next resume that succeeds brings it back.
    private var bedWanted = false
    /// Whether Topo's own voice is being read out; `Speaker` answers it. A receipt over the voice
    /// is a stray tone in the middle of a sentence.
    var voiceSpeaking: @MainActor () -> Bool = { false }
    /// Whether a microphone is open or opening, asked at each sound; `Speaker` answers it. Asked
    /// rather than told at the press, so no path that opens one is missed, and a receipt played
    /// into one is heard by it.
    var microphoneOpen: @MainActor () -> Bool = { false }
    /// What the bed's level was last set for: `duck()` moves it only when the answer has changed.
    private var ducked = false
    /// The pause the fade-out ends in, cancelled when the bed is wanted again before it lands.
    private var parking: Task<Void, Never>?
    /// What a sound's hold is taken for: each owner has its own deadline, and the hold stands
    /// while any owner's does, so the bed's pause lets go of the fade's and never a receipt's.
    private enum Owner { case receipt, fade }
    /// The owners holding, each with the serial of its latest hold, and the tasks that let go.
    private var owned: [Owner: Int] = [:]
    private var letting: [Owner: Task<Void, Never>] = [:]
    private var holdSerial = 0
    #if DEBUG
    /// Every receipt played, in order, for a test.
    private(set) var played: [Tone] = []
    /// Whether a sound's own hold stands, for a test.
    var holdingASound: Bool { !owned.isEmpty }
    #endif

    init(audio: AudioSession, defaults: UserDefaults = .standard, bundle: Bundle = .main,
         makePlayer: @escaping @MainActor (URL) throws -> any WorkingPlayer = { try WorkingAudioPlayer(url: $0) },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.audio = audio
        self.defaults = defaults
        self.bundle = bundle
        self.makePlayer = makePlayer
        self.sleep = sleep
        madeUnder = audio.resets
    }

    /// iOS reset the media server: the players were handles into it and are dropped, and the bed
    /// is off. Told by `Speaker`'s reset handler first of all, so that nothing it does after —
    /// ending the waits, which fades a bed — finds a player to speak to; the sound's hold goes
    /// at the handler's end (`letGo`), after the speaker's own holds have. Nothing is built here;
    /// the next sound makes its own.
    func dropPlayers() {
        forget()
        bedWanted = false
        AudioLog.say("media services reset: the keeper's sounds dropped")
    }

    /// The players go, untouched: nothing is said to a handle the server may have killed.
    private func forget() {
        players = [:]
        bed = nil
        parking?.cancel()
        parking = nil
        madeUnder = audio.resets
    }

    /// Asked before any cached player is touched. The session marks a reset at its notification,
    /// before the speaker's handler has dropped the players, so a sound in between — the session
    /// re-applied by its own handler, the speaker's still to run — finds them made under an
    /// earlier count and drops them rather than speaking to them.
    private func dropStale() {
        guard madeUnder != audio.resets else { return }
        forget()
        AudioLog.say("the keeper's sounds were made before a media services reset: dropped")
    }

    // MARK: - The receipts

    /// Follows the chat's guest beside Topo: what the harness was already telling is told on, and
    /// the sounds hear of it after. Called after `Mascot.follow(harness)`, which it wraps.
    func follow(_ harness: Harness) {
        let before = harness.onGuest
        harness.onGuest = { [weak self] activity in
            before?(activity)
            self?.follow(activity)
        }
    }

    /// What the guest is doing: a tool reached for is its class's receipt, a turn that failed is
    /// the error's. Everything else is Topo's to draw.
    func follow(_ activity: GuestActivity) {
        switch activity {
        case .began, .gone: calls = []
        case .update(.event(.toolUse(let name, _))): tool(name)
        case .update(.event(.toolResult(let isError, _))): result(isError: isError)
        case .update(.ended(.failed)): failed()
        default: break
        }
    }

    /// The tools of each class, as Daphne's voice channel classes them (buddy-channels
    /// `voice/classify.ts`): a sound per kind of work, `act` for everything else — a command,
    /// every MCP tool, anything new.
    static let readTools: Set<String> = ["Read", "Grep", "Glob", "LS", "ToolSearch", "WebFetch", "WebSearch",
                                         "NotebookRead", "ListAgents", "TaskOutput"]
    static let writeTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    static let delegateTools: Set<String> = ["Agent", "Task", "Workflow"]

    static func tone(forTool name: String) -> Tone {
        if readTools.contains(name) { return .read }
        if writeTools.contains(name) { return .write }
        if delegateTools.contains(name) { return .delegate }
        return .act
    }

    /// The classes of the calls made and not yet answered, in the order they were made, which
    /// is the order their results come back in; emptied as a turn begins and goes, so a result
    /// with no call before it misaligns nothing past its turn.
    private var calls: [Tone] = []

    /// The guest reached for `name`: its class's tone.
    @discardableResult
    func tool(_ name: String) -> Bool {
        let tone = Self.tone(forTool: name)
        calls.append(tone)
        return play(tone)
    }

    /// A tool's result came back: a delegate handing back sounds `return`, and a result Claude
    /// Code marked an error sounds `error` (Daphne's channel: `SubagentStop`, and a
    /// `PostToolUse` that did not succeed).
    func result(isError: Bool) {
        let call = calls.isEmpty ? nil : calls.removeFirst()
        if call == .delegate { play(.return) }
        if isError { play(.error) }
    }

    /// The guest's turn failed and nothing is coming. With the earcons on, the speaker's `failed`
    /// cue says it, and a second tone would say it twice (Daphne's rule), so this gives way.
    @discardableResult
    func failed() -> Bool {
        if EarconsSetting.enabled(defaults) {
            AudioLog.say("receipt error not played: the earcons say a failed turn")
            return false
        }
        return play(.error)
    }

    /// The open microphone heard an onset, and the utterance it began has opened a turn
    /// (Daphne's `Keeper.heard`). Under the conversation, which is the session armed.
    @discardableResult
    func heard() -> Bool { play(.ack, armed: true) }

    /// The go-ahead: the conversation's microphone can take the next turn (Daphne's
    /// `WaitSounds.ready`). Under the conversation, which is the session armed.
    @discardableResult
    func goAhead() -> Bool { play(.speak, armed: true) }

    /// A press was heard and its turn waits behind one on its way (Daphne's `WaitSounds.bleep`).
    @discardableResult
    func queued() -> Bool { play(.queue) }

    /// Told of each tone as it starts, with its length, so an open microphone's gate is shut
    /// while it sounds (`Conversation`, Daphne's `holdGate`).
    var toneSounded: @MainActor (Tone, Duration) -> Void = { _, _ in }

    /// Plays `tone` on the session as it stands. A receipt is the keeper's, so it sounds only
    /// where a turn's hold stands: a turn nothing waits for aloud sounds nothing, and a receipt
    /// under nothing but a sound's own hold would be the receipts keeping the process alive by
    /// themselves. `armed` is a tone of the conversation's own, which the call or the front keeps
    /// running, so it sounds without one and holds only beside one. Over Topo's voice and into
    /// an open microphone it sounds, as Daphne's do: the conversation's gate is shut under it.
    @discardableResult
    private func play(_ tone: Tone, armed: Bool = false) -> Bool {
        guard WorkingSounds.mode(defaults) != .off else { return false }
        let held = audio.heldForATurn
        guard held || armed else { return false }
        guard activate(for: "receipt \(tone)") else { return false }
        dropStale()
        guard let player = player(for: tone) else { return false }
        // The hold before the player, so the process is held from the tone's first frame.
        if held { holdUntil(Self.toneLength, for: .receipt) }
        toneSounded(tone, Self.toneLength)
        player.currentTime = 0
        guard player.play() else {
            AudioLog.say("receipt \(tone) did not start")
            return false
        }
        AudioLog.say("receipt \(tone)")
        #if DEBUG
        played.append(tone)
        #endif
        return true
    }

    private func player(for tone: Tone) -> (any WorkingPlayer)? {
        if let player = players[tone] { return player }
        guard let player = make(tone.file) else { return nil }
        players[tone] = player
        return player
    }

    private func make(_ file: String) -> (any WorkingPlayer)? {
        guard let url = bundle.url(forResource: file, withExtension: "wav") else {
            AudioLog.say("\(file) is not bundled")
            return nil
        }
        do {
            return try makePlayer(url)
        } catch {
            AudioLog.say("\(file) has no player: \(error)")
            return nil
        }
    }

    /// A sound is a moment: it plays on a live session and configures nothing to get one, so
    /// after an interruption behind the lock it is refused rather than the session reactivated
    /// from the background. The speaker's own resume brings the bed back once the session is.
    private func activate(for what: String) -> Bool {
        do {
            try audio.ensureLive()
            return true
        } catch {
            AudioLog.say("\(what) refused: \(error)")
            return false
        }
    }

    // MARK: - The bed

    /// The speaker is waiting for a reply, or has stopped: the bed fades in under `sounds` while
    /// a hold stands, and out otherwise. Off goes through whatever the mode, so a bed begun
    /// under `sounds` is still faded out at its wait's end after the mode changed under it (a
    /// change applies at the next sound; the bed plays on to the end of the wait it was for).
    func working(_ on: Bool) {
        dropStale()
        // Never under a sentence: a wait taken while Topo is reading wants no bed.
        let want = on && WorkingSounds.mode(defaults) == .sounds && audio.heldForATurn && !voiceSpeaking()
        // An interruption stops the player under a bed that is still wanted, so "already on" has
        // to mean "still playing" too.
        if want == bedWanted, !want || bed?.isPlaying == true { return }
        bedWanted = want
        parking?.cancel()
        parking = nil
        if want {
            // A refusal from here on leaves the bed wanted: it is the playing that failed.
            guard activate(for: "the working bed") else { return }
            if bed == nil {
                bed = make(Self.bedFile)
                bed?.numberOfLoops = -1
            }
            guard let bed else { return }
            if !bed.isPlaying {
                bed.volume = 0
                guard bed.play() else {
                    AudioLog.say("the working bed did not start")
                    return
                }
            }
            ducked = microphoneOpen()
            bed.setVolume(target, fadeDuration: Self.fadeIn)
            AudioLog.say("the working bed fades in")
        } else {
            guard let bed, bed.isPlaying else { return }
            // Held through the fade, since the wait that wanted it is ending; then paused rather
            // than stopped, so the next wait picks the loop up where this one left it. The hold
            // is a sound's and asks the same of the session: on one that is not live (the
            // lock screen's interruption, with the player somehow still going) it would be a
            // hold whose keeper reconfigures the session from the background, so none is taken.
            // Let go once the bed is paused (`park`), and at the sounds' bound at the latest: a
            // hold let go with the player still running is a session handed back under live I/O.
            if activate(for: "the working bed's fade") { holdUntil(Self.bound, for: .fade) }
            bed.setVolume(0, fadeDuration: Self.fadeOut)
            AudioLog.say("the working bed fades out")
            parking = Task { [sleep] in
                try? await sleep(Self.parkAfter)
                guard !Task.isCancelled else { return }
                self.park()
            }
        }
    }

    private func park() {
        parking = nil
        dropStale()
        guard !bedWanted else { return }
        bed?.pause()
        AudioLog.say("the working bed is paused")
        release(.fade, "the working bed is paused")
    }

    /// The speaker's engine is back after an interruption: a bed still wanted and not playing
    /// is played again, through the same refusal path as its start, and a refusal leaves it
    /// wanted for the next.
    func resume() {
        dropStale()
        guard bedWanted, bed?.isPlaying != true else { return }
        bedWanted = false
        working(true)
    }

    /// A microphone opened over the bed, or closed again: the bed is set to the level the answer
    /// now asks for. Told at each microphone moment; a receipt asks for itself (`play`).
    func duck() {
        dropStale()
        let open = microphoneOpen()
        guard open != ducked else { return }
        ducked = open
        guard bedWanted, let bed, bed.isPlaying else { return }
        bed.setVolume(open ? Self.duckedVolume : Self.bedVolume, fadeDuration: 0.15)
    }

    private var target: Float { microphoneOpen() ? Self.duckedVolume : Self.bedVolume }

    // MARK: - The hold

    /// `owner` holds the process for `length` more (`bound` at most), beside any other owner — an extension of the turn's hold
    /// that every caller has checked stands (`play`'s guard; the bed is on only under one, and
    /// its fade-out is asked for before the wait's hold drops), never a hold taken alone: in
    /// front nothing suspends, and a sound holding alone would keep a claim change waiting for
    /// nothing.
    private func holdUntil(_ length: Duration, for owner: Owner) {
        if owned.isEmpty { audio.wantAlive(true, for: .sound) }
        letting[owner]?.cancel()
        holdSerial += 1
        let mine = holdSerial
        owned[owner] = mine
        letting[owner] = Task { [sleep] in
            try? await sleep(min(length, Self.bound))
            guard !Task.isCancelled, self.owned[owner] == mine else { return }
            self.release(owner, "the sound is over")
        }
    }

    /// `owner`'s part of the hold goes; the hold itself goes with the last owner's.
    private func release(_ owner: Owner, _ why: String) {
        letting.removeValue(forKey: owner)?.cancel()
        guard owned.removeValue(forKey: owner) != nil, owned.isEmpty else { return }
        AudioLog.say("the keeper's sound let go: \(why)")
        audio.wantAlive(false, for: .sound)
    }

    /// The sound's hold, if one stands, goes now, whoever holds it: at the end of the reset
    /// handler, after the speaker's own holds have.
    func letGo(_ why: String) {
        letting.values.forEach { $0.cancel() }
        letting = [:]
        guard !owned.isEmpty else { return }
        owned = [:]
        AudioLog.say("the keeper's sound let go: \(why)")
        audio.wantAlive(false, for: .sound)
    }
}
#endif
