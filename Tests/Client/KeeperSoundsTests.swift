import AVFoundation
import TopoCore
import TopoCoreTesting
import TopoTurn
import TopoUserland
import UIKit
import XCTest

@testable import Topo

/// A receipt's or the bed's player as the suite has it: every play, pause and fade recorded.
@MainActor
final class FakeWorkingPlayer: WorkingPlayer {
    let url: URL
    var volume: Float = 1
    var numberOfLoops = 0
    var currentTime: TimeInterval = 0
    private(set) var isPlaying = false
    var refusesToStart = false
    private(set) var plays = 0
    private(set) var pauses = 0
    /// Each fade asked for: the volume and how long.
    private(set) var fades: [(to: Float, over: TimeInterval)] = []

    init(url: URL) { self.url = url }

    var name: String { url.deletingPathExtension().lastPathComponent }

    func play() -> Bool {
        guard !refusesToStart else { return false }
        plays += 1
        isPlaying = true
        return true
    }

    func pause() {
        pauses += 1
        isPlaying = false
    }

    func setVolume(_ volume: Float, fadeDuration: TimeInterval) {
        fades.append((volume, fadeDuration))
        self.volume = volume
    }

    /// An interruption: the system stopped the player under whoever wanted it.
    func interrupted() { isPlaying = false }
}

/// Every player `KeeperSounds` asked for, in order.
@MainActor
final class WorkingRecorder {
    private(set) var players: [FakeWorkingPlayer] = []
    var nextRefusesToStart = false
    var names: [String] { players.map(\.name) }
    var bed: FakeWorkingPlayer? { players.first { $0.name == KeeperSounds.bedFile } }

    func make(_ url: URL) -> FakeWorkingPlayer {
        let player = FakeWorkingPlayer(url: url)
        player.refusesToStart = nextRefusesToStart
        nextRefusesToStart = false
        players.append(player)
        return player
    }
}

/// The keeper's sounds over a real `Speaker` on the audio seams and the guest activity as the
/// harness tells it, with the players the suite's. What is held: each tool class sounds its tone
/// and only while a hold stands, so a typed turn is silent; the bed only under `sounds`, in from
/// the release and out at the reply's first frame, paused not stopped; off goes through in every
/// mode; a value kept that is no mode reads as `receipts`; nothing on a session that will not
/// activate; a hold that extends a standing one and never holds
/// alone; and the players dropped, not rebuilt, at a reset.
@MainActor
final class KeeperSoundsTests: XCTestCase {
    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    @MainActor struct Rig {
        let speaker: Speaker
        let sounds: KeeperSounds
        let players: WorkingRecorder
        let seams: Seams
        let audio: AudioSession
        let center: NotificationCenter
        let defaults: UserDefaults
        let clock: PausedSleep
        let earcons: Earcons
        let cues: CueRecorder
    }

    private func drain() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "topo.tests.keeper-sounds.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// `speakerCenter` puts the speaker's notifications on a center of their own, so a test posts
    /// a reset to the session's handler and the speaker's one at a time, in the order it chooses.
    private func rig(mode: WorkingSounds.Mode? = nil, earcons: Bool = false, isActive: Bool = true,
                     heard: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack,
                     speakerCenter: NotificationCenter? = nil) async -> Rig {
        let seams = Seams()
        let center = NotificationCenter()
        let defaults = makeDefaults()
        if let mode { defaults.set(mode.rawValue, forKey: WorkingSounds.key) }
        // The keeper's sounds alone unless a test asks: the earcons' own failure cue is theirs.
        defaults.set(earcons, forKey: EarconsSetting.key)
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { isActive })
        let players = WorkingRecorder()
        let clock = PausedSleep()
        let sounds = KeeperSounds(audio: audio, defaults: defaults, bundle: Bundle(for: KeeperSounds.self),
                                  makePlayer: { players.make($0) }, sleep: { try await clock.sleep($0) })
        let voice = Voice(engine: ScriptedVoice())
        voice.load(folder: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let cues = CueRecorder()
        let earcons = Earcons(audio: audio, defaults: defaults, bundle: Bundle(for: Earcons.self),
                              makePlayer: { cues.make($0) }, tail: { .zero })
        let speaker = Speaker(audio: audio, voice: voice, center: speakerCenter ?? center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) },
                              heard: heard, sounds: sounds, earcons: earcons)
        return Rig(speaker: speaker, sounds: sounds, players: players, seams: seams, audio: audio,
                   center: center, defaults: defaults, clock: clock, earcons: earcons, cues: cues)
    }

    private func toolUse(_ name: String, path: String? = nil, id: String? = nil) -> GuestActivity {
        .update(.event(.toolUse(name: name, path: path, id: id)))
    }

    private func toolResult(isError: Bool = false, id: String? = nil) -> GuestActivity {
        .update(.event(.toolResult(isError: isError, text: "", id: id)))
    }

    private func renderUntil(_ rig: Rig, _ what: String, file: StaticString = #filePath, line: UInt = #line,
                             _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            let engine = try XCTUnwrap(rig.seams.engines.last, file: file, line: line)
            let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                     frameCapacity: engine.manualRenderingMaximumFrameCount))
            _ = try? engine.renderOffline(256, to: out)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(condition(), "rendered 400 slices waiting for \(what)", file: file, line: line)
    }

    // MARK: - The receipts

    /// Each tool sounds its class's tone, as Daphne's voice channel classes it (`classify.ts`),
    /// over the bundled file, while a wait stands: the reads, the file writes, the delegates, and
    /// `act` for everything else. Under `receipts` no bed is made.
    func testEachToolClassSoundsItsToneWhileAWaitStands() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.speaker.keeping, "the wait's keeper is not running, so the session is not live")
        XCTAssertTrue(rig.audio.holding)

        rig.sounds.follow(toolUse("WebSearch"))
        rig.sounds.follow(toolUse("Bash"))
        rig.sounds.follow(toolUse("Edit", path: "notes/today.md"))
        rig.sounds.follow(toolUse("Read"))
        rig.sounds.follow(toolUse("mcp__home__lights"))
        XCTAssertEqual(rig.sounds.played, [.read, .act, .write, .read, .act])
        XCTAssertEqual(rig.players.names, ["bloop_read", "bloop_act", "bloop_write"], "a tone's player was made twice, or the bed under receipts")
        XCTAssertEqual(rig.players.players.map(\.plays), [2, 2, 1])
        XCTAssertNil(rig.players.bed)
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// The table is `classify.ts`'s, tool for tool, with `act` for anything it does not name.
    func testTheToolsMapToTheirClasses() {
        for name in ["Read", "Grep", "Glob", "LS", "ToolSearch", "WebFetch", "WebSearch", "NotebookRead", "ListAgents", "TaskOutput"] {
            XCTAssertEqual(KeeperSounds.tone(forTool: name), .read, name)
        }
        for name in ["Edit", "Write", "MultiEdit", "NotebookEdit"] {
            XCTAssertEqual(KeeperSounds.tone(forTool: name), .write, name)
        }
        for name in ["Agent", "Task", "Workflow"] {
            XCTAssertEqual(KeeperSounds.tone(forTool: name), .delegate, name)
        }
        for name in ["Bash", "TodoWrite", "mcp__x__y", "Skill", ""] {
            XCTAssertEqual(KeeperSounds.tone(forTool: name), .act, name)
        }
    }

    /// A delegate sounds as it is called and `return` as its own result comes back, paired by
    /// id; a result Claude Code marked an error sounds `error`, whatever its call; a result
    /// naming no call sounds nothing of a call's.
    func testADelegateReturnsAndAFailedToolSoundsTheError() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(toolResult(id: "nobody"))
        XCTAssertEqual(rig.sounds.played, [], "a result with no call sounded")
        rig.sounds.follow(toolUse("Read", id: "r"))
        rig.sounds.follow(toolUse("Agent", id: "a"))
        rig.sounds.follow(toolResult(id: "r"))
        XCTAssertEqual(rig.sounds.played, [.read, .delegate], "the read's result sounded as the delegate's return")
        rig.sounds.follow(toolResult(id: "a"))
        XCTAssertEqual(rig.sounds.played, [.read, .delegate, .return])
        rig.sounds.follow(toolResult(id: "a"))
        XCTAssertEqual(rig.sounds.played, [.read, .delegate, .return], "a delegate returned twice")
        rig.sounds.follow(toolUse("Bash", id: "b"))
        rig.sounds.follow(toolResult(isError: true, id: "b"))
        XCTAssertEqual(rig.sounds.played, [.read, .delegate, .return, .act, .error])
        XCTAssertEqual(rig.players.names, ["bloop_read", "bloop_delegate", "bloop_return", "bloop_act", "bloop_error"])
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// The calls still owed a result go with their turn: a delegate whose result never came back
    /// does not take the next turn's first result for its own.
    func testTheCallsOwedGoWithTheirTurn() async {
        for end in [GuestActivity.gone(answering: []), .began(pid: nil, answering: [])] {
            let rig = await rig()
            _ = rig.speaker.awaitReply("turn", readAloud: true)
            rig.sounds.follow(toolUse("Agent", id: "a"))
            rig.sounds.follow(end)
            rig.sounds.follow(toolUse("Read", id: "r"))
            rig.sounds.follow(toolResult(id: "a"))
            XCTAssertEqual(rig.sounds.played, [.delegate, .read], "\(end): a call of the turn before was answered by this one's result")
            rig.speaker.endAwaiting("turn", "the test is done")
        }
    }

    /// A sub-agent's own tools sound, and their results come between its delegate's call and
    /// its result: `return` sounds at the delegate's own result and no other, whatever the
    /// sub-agent did, and delegates called at once return in the order they finish. The lines
    /// are Claude Code's own, through `StreamJSON`.
    func testADelegateReturnsAtItsOwnResultWhateverItsSubagentDid() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        func feed(_ line: String) {
            for event in StreamJSON.events(in: line) { rig.sounds.follow(.update(.event(event))) }
        }
        func call(_ name: String, _ id: String, parent: String? = nil) -> String {
            let p = parent.map { #""\#($0)""# } ?? "null"
            return #"{"type":"assistant","parent_tool_use_id":\#(p),"message":{"id":"m","model":"claude-haiku-4-5","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]}}"#
        }
        func result(_ id: String, parent: String? = nil) -> String {
            let p = parent.map { #""\#($0)""# } ?? "null"
            return #"{"type":"user","parent_tool_use_id":\#(p),"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"#
        }
        feed(call("Agent", "a1"))
        feed(call("Agent", "a2"))
        feed(call("Read", "s1", parent: "a1"))
        feed(result("s1", parent: "a1"))
        XCTAssertEqual(rig.sounds.played, [.delegate, .delegate, .read], "a sub-agent's result sounded its delegate's return")
        feed(result("a2"))
        XCTAssertEqual(rig.sounds.played, [.delegate, .delegate, .read, .return])
        feed(call("Grep", "s2", parent: "a1"))
        feed(result("s2", parent: "a1"))
        feed(result("a1"))
        XCTAssertEqual(rig.sounds.played, [.delegate, .delegate, .read, .return, .read, .return],
                       "the first delegate did not return at its own result")
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// In a conversation the go-ahead takes `done`'s place at a reply's end; with the sounds off
    /// no go-ahead can sound, and `done` is said as it is outside one.
    func testAConversationsReplySoundsDoneOnlyWhereNoGoAheadCanSound() async throws {
        for mode in [WorkingSounds.Mode.receipts, .off] {
            let rig = await rig(mode: mode, earcons: true, heard: .dataRendered)
            rig.speaker.conversing = true
            XCTAssertTrue(rig.speaker.speak("Hi."))
            await settle("the reply to start") { rig.speaker.report.started }
            try await renderUntil(rig, "the reply to finish") { rig.speaker.report.finished }
            XCTAssertEqual(rig.earcons.played, mode == .off ? [.done] : [], "\(mode): the reply's end")
        }
    }

    /// Over Topo's voice and into an open microphone a receipt sounds, as Daphne's do; the gate
    /// of the microphone it sounds into is told its length.
    func testAReceiptSoundsOverTheVoiceAndIntoAnOpenMicrophone() async {
        let rig = await rig()
        var told: [KeeperSounds.Tone] = []
        rig.sounds.toneSounded = { tone, length in
            told.append(tone)
            XCTAssertEqual(length, KeeperSounds.toneLength)
        }
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.voiceSpeaking = { true }
        rig.sounds.follow(toolUse("WebSearch"))
        rig.sounds.voiceSpeaking = { false }
        rig.sounds.microphoneOpen = { true }
        rig.sounds.follow(toolUse("Bash"))
        XCTAssertEqual(rig.sounds.played, [.read, .act])
        XCTAssertEqual(told, [.read, .act])
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// The conversation's own tone, the go-ahead, sounds with no turn's hold, since the call or
    /// the front keeps the process running under it, and takes none of its own; the queued bleep
    /// is a receipt's and sounds only under one. Off sounds none.
    func testTheConversationsToneSoundsWithoutATurnsHoldAndHoldsNothing() async {
        let rig = await rig()
        try? rig.audio.ensureActive()
        XCTAssertFalse(rig.audio.holding)
        XCTAssertTrue(rig.sounds.goAhead())
        XCTAssertFalse(rig.sounds.queued(), "the queued bleep sounded with no turn on its way")
        XCTAssertEqual(rig.sounds.played, [.speak])
        XCTAssertEqual(rig.players.names, ["bloop_speak"])
        XCTAssertFalse(rig.audio.holding, "a conversation's tone held the process by itself")
        XCTAssertFalse(rig.sounds.holdingASound)

        rig.defaults.set(WorkingSounds.Mode.off.rawValue, forKey: WorkingSounds.key)
        XCTAssertFalse(rig.sounds.goAhead())
        XCTAssertEqual(rig.sounds.played, [.speak])
    }

    /// A press released with words while a turn is still on its way bleeps, and that is its one
    /// sound: `sent` gives way. The press runs as the chat's does (`MicPress.gesture`) — the
    /// spoken turn's wait taken, then the press's `microphoneOpening`, which ends that wait, the
    /// microphone open, and the release, held as its words are finished — so what says a turn is
    /// on its way is the harness's line, which the press leaves standing, and the hold the bleep
    /// sounds under is the release's. With nothing on its way, or nothing heard, or the sounds
    /// off, the earcons say it as they did.
    func testAPressHeardBehindATurnOnItsWayBleepsInPlaceOfSent() async {
        let rig = await rig(earcons: true)
        let harness = Harness(database: InMemoryRecordDatabase(), device: DeviceID("phone"), ensureZone: {},
                              defaults: makeDefaults(), brain: NoBrain(),
                              leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                              pause: { _ in throw CancellationError() })
        rig.speaker.turnOnItsWay = { harness.turnOnItsWay }
        try? rig.audio.ensureActive()
        press(rig)
        XCTAssertEqual(rig.sounds.played, [], "a bleep with no turn on its way")
        XCTAssertEqual(rig.earcons.played, [.sent])

        _ = harness.willSend("what's on tonight")
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        press(rig) { XCTAssertEqual(rig.speaker.awaiting, [], "the press left the turn's wait standing") }
        XCTAssertEqual(rig.sounds.played, [.queue], "the release behind a turn on its way did not bleep")
        XCTAssertEqual(rig.earcons.played, [.sent], "sent sounded beside the bleep")
        press(rig, heard: "")
        XCTAssertEqual(rig.sounds.played, [.queue], "a release that heard nothing bleeped")
        XCTAssertEqual(rig.earcons.played, [.sent, .failed])

        rig.defaults.set(WorkingSounds.Mode.off.rawValue, forKey: WorkingSounds.key)
        press(rig, heard: "and the hall")
        XCTAssertEqual(rig.sounds.played, [.queue])
        XCTAssertEqual(rig.earcons.played, [.sent, .failed, .sent], "with the sounds off the release went unsaid")
    }

    /// A hold-to-talk press as `MicPress.gesture` runs it, `pressed` seeing the open microphone,
    /// released with `heard`; the release's hold goes once its words have sounded.
    private func press(_ rig: Rig, heard: String = "and the kitchen", pressed: () -> Void = {},
                       file: StaticString = #filePath, line: UInt = #line) {
        rig.speaker.microphoneOpening()
        rig.speaker.microphoneOpened(counted: true)
        pressed()
        let release = rig.speaker.releasing()
        XCTAssertNotNil(release, "the release was not held", file: file, line: line)
        rig.speaker.microphoneClosed()
        rig.speaker.sounded(release: heard)
        release.map { rig.speaker.released($0, "the test's send returned") }
    }

    /// Review Focus 9: a typed turn holds nothing, so its tools sound nothing and its failure
    /// sounds nothing, in every mode.
    func testNothingSoundsForATypedTurn() async {
        for mode in WorkingSounds.Mode.allCases {
            let rig = await rig(mode: mode)
            XCTAssertFalse(rig.audio.holding)
            rig.sounds.follow(toolUse("WebSearch"))
            rig.sounds.follow(.update(.ended(.failed(.exited("exit 1")))))
            rig.sounds.working(true)
            XCTAssertEqual(rig.sounds.played, [], "\(mode)")
            XCTAssertTrue(rig.players.players.isEmpty, "\(mode): a player was made for a turn nothing waits for")
        }
    }

    /// With the earcons on, a failed turn is theirs to sound (`failed`): the error receipt gives
    /// way, so one failure is one tone.
    func testWithTheEarconsOnAFailedTurnSoundsNoErrorReceipt() async {
        let rig = await rig(earcons: true)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(toolUse("WebSearch"))
        rig.sounds.follow(.update(.ended(.failed(.exited("exit 1")))))
        XCTAssertEqual(rig.sounds.played, [.read], "the error receipt sounded beside the earcons' failed")
    }

    /// The guest's turn failing sounds the error, once, before the wait ends; the wait ending
    /// sounds nothing of its own.
    func testAFailedTurnSoundsTheError() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(.update(.ended(.failed(.exited("exit 1")))))
        XCTAssertEqual(rig.sounds.played, [.error])
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertEqual(rig.sounds.played, [.error])
        XCTAssertTrue(rig.audio.holding, "the receipt's hold went with the wait's")
        await settle("the hold's length to be asked for") { rig.clock.asked.contains(KeeperSounds.toneLength) }
        rig.clock.fire()
        await settle("the receipt's hold to go") { !rig.audio.holding }
    }

    /// Off sounds nothing and makes no player; back on, the next sound plays.
    func testOffSoundsNothing() async {
        let rig = await rig(mode: .off)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(toolUse("WebSearch"))
        rig.sounds.working(true)
        XCTAssertEqual(rig.sounds.played, [])
        XCTAssertTrue(rig.players.players.isEmpty)

        rig.defaults.set(WorkingSounds.Mode.receipts.rawValue, forKey: WorkingSounds.key)
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.sounds.played, [.read])
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// Review Focus 12: a value kept that is no mode — a word nobody chose, a Boolean — reads as
    /// `receipts`; a phone never asked reads as `receipts`.
    func testAnUnknownKeptValueIsTheStandard() {
        let defaults = makeDefaults()
        XCTAssertEqual(WorkingSounds.mode(defaults), .receipts)
        defaults.set("loud", forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .receipts)
        defaults.set(true, forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .receipts)
        defaults.set(false, forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .receipts)
        defaults.set("sounds", forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .sounds)
        defaults.set("off", forKey: WorkingSounds.key)
        XCTAssertEqual(WorkingSounds.mode(defaults), .off)
    }

    /// A receipt sounds over Topo's own voice, as Daphne's Keeper's do: a tool reached for while
    /// the reading goes on, with a second wait keeping the hold, sounds, and one sounding as the
    /// reply's first frame is scheduled plays on.
    func testAReceiptSoundsOverTheVoice() async throws {
        let rig = await rig(heard: .dataRendered)
        _ = rig.speaker.awaitReply("first", readAloud: true)
        _ = rig.speaker.awaitReply("second", readAloud: true)
        rig.sounds.follow(toolUse("Bash"))
        let act = try XCTUnwrap(rig.players.players.first { $0.name == "bloop_act" })
        XCTAssertTrue(rig.speaker.speak("Paris.", answering: "first"))
        await settle("the reply to start") { rig.speaker.report.started }
        XCTAssertTrue(act.isPlaying, "a receipt was stopped at the reply's first frame")
        XCTAssertEqual(act.pauses, 0)
        XCTAssertTrue(rig.speaker.speaking)
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.sounds.played, [.act, .read], "a receipt was refused over the voice")
        try await renderUntil(rig, "the reply to be made") { rig.speaker.report.finished }
        rig.speaker.endAwaiting("second", "the test is done")
    }

    /// A receipt sounds into an open microphone, as Daphne's do, and one sounding as a microphone
    /// opens plays on: the conversation's gate is what keeps the ear from taking it for speech.
    /// Only the keeper's rule holds it back: a press over the wait ends it, the last receipt's own
    /// hold alone stands, and a receipt under nothing but that would be the receipts keeping the
    /// process alive by themselves.
    func testAReceiptSoundsIntoAnOpenMicrophoneButNotUnderItsOwnHoldAlone() async throws {
        let rig = await rig()
        var open = false
        rig.speaker.microphoneOpen = { open }
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(toolUse("Bash"))
        let act = try XCTUnwrap(rig.players.players.first { $0.name == "bloop_act" })
        open = true
        rig.speaker.microphoneListening()
        XCTAssertTrue(act.isPlaying, "a receipt was stopped as a microphone opened")
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.sounds.played, [.act, .read], "a receipt was refused into an open microphone")
        open = false
        rig.speaker.microphoneClosed()

        rig.speaker.microphoneOpening()
        XCTAssertTrue(rig.speaker.awaiting.isEmpty)
        XCTAssertTrue(rig.audio.holding, "the receipt's hold went with the wait's")
        XCTAssertFalse(rig.audio.heldForATurn)
        rig.speaker.microphoneOpened(counted: true)
        rig.sounds.follow(toolUse("Bash"))
        XCTAssertEqual(rig.sounds.played, [.act, .read], "a receipt sounded under nothing but a receipt's hold")
        await settle("the hold's length to be asked for") { rig.clock.asked.contains(KeeperSounds.toneLength) }
        rig.clock.fire()
        await settle("the receipt's hold to go") { !rig.audio.holding }
    }

    /// The bed dips once the watch on the microphone tells the speaker it is listening, and comes
    /// back up as it closes.
    func testTheBedDipsUnderAMicrophoneNoPressOpened() async throws {
        let rig = await rig(mode: .sounds)
        var open = false
        rig.speaker.microphoneOpen = { open }
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        open = true
        rig.speaker.microphoneListening()
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.duckedVolume, "the bed did not dip under the microphone")
        open = false
        rig.speaker.microphoneClosed()
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// A sound on a session that is not live is refused and configures nothing to get one: no
    /// player, no hold, nothing played. Behind the lock that is the lock screen's interruption
    /// with a claim change deferred under the wait's hold, which a sound must not apply from the
    /// background; a sound on a session nothing has activated yet is refused the same way.
    func testASoundOnASessionThatIsNotLiveIsRefusedAndConfiguresNothing() async {
        let rig = await rig(mode: .sounds, isActive: false)
        XCTAssertFalse(rig.sounds.tool("WebSearch"), "a receipt played on a session nothing had activated")
        rig.audio.wantRecord(true, for: .warm)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.audio.wantRecord(false, for: .warm)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await drain()
        rig.seams.forget()

        XCTAssertFalse(rig.sounds.tool("WebSearch"))
        XCTAssertEqual(rig.sounds.played, [])
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile], "a player was made on a session that is not live")
        // The bed somehow still going: the wait's end fades it, and takes no hold for the fade,
        // since the hold's keeper would reconfigure the session from the background.
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertEqual(rig.players.bed?.fades.last?.to, 0)
        XCTAssertFalse(rig.audio.holding, "the fade held on a session that is not live")
        XCTAssertEqual(rig.seams.lines, [], "a sound configured the session")
        XCTAssertEqual(rig.seams.records, [], "a sound applied a claim change from the background")
    }

    /// The interruption stopped the bed under a wait that still wants it, and the speaker asks
    /// for it back before the session is live again (a rebuild the session refused): the bed is
    /// not played again, since `AVAudioPlayer.play()` would activate the session itself, from
    /// the background, and nothing is configured.
    func testTheBedIsNotPlayedAgainOnASessionThatIsNotLive() async throws {
        let rig = await rig(mode: .sounds, isActive: false)
        rig.audio.wantRecord(true, for: .warm)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertEqual(bed.plays, 1)
        rig.audio.wantRecord(false, for: .warm)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await drain()
        bed.interrupted()
        rig.seams.forget()

        rig.sounds.resume()
        XCTAssertEqual(bed.plays, 1, "the bed was played again on a session that is not live")
        XCTAssertFalse(bed.isPlaying)
        XCTAssertEqual(rig.seams.lines, [], "a sound configured the session")
        XCTAssertEqual(rig.seams.records, [], "a sound applied a claim change from the background")
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// An interruption's first end is refused by the session and its second is not, with the
    /// wait standing throughout: the refused resume leaves the bed wanted, so the second brings
    /// it back with the engine.
    func testARefusedResumeLeavesTheBedWantedForTheNext() async throws {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        bed.interrupted()
        await drain()

        rig.seams.activationError = CancellationError()
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        await drain()
        XCTAssertEqual(bed.plays, 1, "the bed was played on a session that refused")
        XCTAssertEqual(rig.speaker.awaiting, ["turn"])

        rig.seams.activationError = nil
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        await drain()
        XCTAssertEqual(bed.plays, 2, "the bed a refused resume left wanted did not come back with the engine")
        XCTAssertTrue(bed.isPlaying)
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    // MARK: - The bed

    /// Under `sounds`, a conversation behind the lock on an active call: the utterance's end
    /// drops the chat's claim and closes the microphone ahead of the turn's hold, and the bed is
    /// played for the wait on the call's live session, configuring nothing. Placed and not yet
    /// activated, the session is not live and the bed is refused.
    func testTheBedPlaysOnTheCallsLiveSessionUnderAConversation() async throws {
        let rig = await rig(mode: .sounds, isActive: false)
        rig.audio.wantRecord(true, for: .chat)
        rig.audio.wantAlive(true, for: .awaitingReply("before"))
        rig.audio.callPlaced()
        rig.sounds.working(true)
        XCTAssertNil(rig.players.bed, "a bed was made on a call not yet activated")
        rig.audio.callActivated()
        rig.audio.microphone(open: true)
        rig.audio.wantAlive(false, for: .awaitingReply("before"))
        rig.seams.forget()

        rig.audio.wantRecord(false, for: .chat)
        rig.audio.microphone(open: false)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.audio.microphone(open: true)
        let bed = try XCTUnwrap(rig.players.bed, "no bed was made on the call's live session")
        XCTAssertTrue(bed.isPlaying, "the bed was refused on the call's live session")
        XCTAssertEqual(bed.plays, 1)
        XCTAssertEqual(rig.seams.lines, [], "a sound configured the session beside the call")
        XCTAssertEqual(rig.seams.records, [])
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// Under `sounds` the bed fades in from the release and out at the reply's first frame, once,
    /// and is paused after its fade rather than stopped; the next wait plays it on from where it was.
    func testTheBedPlaysFromTheReleaseToTheReplysFirstFrameAndIsPausedNotStopped() async throws {
        let rig = await rig(mode: .sounds, heard: .dataRendered)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed, "no bed was made at the release")
        XCTAssertEqual(bed.numberOfLoops, -1)
        XCTAssertEqual(bed.plays, 1)
        XCTAssertTrue(bed.isPlaying)
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.bedVolume])
        XCTAssertEqual(bed.fades.map(\.over), [KeeperSounds.fadeIn])

        // The reply lands and is read: its first frame fades the bed out, and the second
        // sentence's first frame does not fade it again.
        XCTAssertTrue(rig.speaker.speak("Paris is the capital. It is on the Seine.", answering: "turn"))
        await settle("the reply to start") { rig.speaker.report.started }
        try await renderUntil(rig, "both sentences to be made") { rig.speaker.report.finished }
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.bedVolume, 0], "the bed faded at more than one frame")
        XCTAssertEqual(bed.fades.last?.over, KeeperSounds.fadeOut)
        XCTAssertTrue(bed.isPlaying, "the bed was stopped before its fade")
        XCTAssertEqual(rig.clock.asked.filter { $0 == KeeperSounds.parkAfter }.count, 1, "the pause asked for other than once")
        XCTAssertTrue(rig.clock.asked.contains(KeeperSounds.bound), "the fade's hold has no bound")
        bed.currentTime = 3.2
        // The pause alone, the bound still waiting: the fade's hold goes at the pause. Kills the
        // mutant where the pause lets go of nothing and the bound alone ends the hold.
        rig.clock.fire(KeeperSounds.parkAfter)
        await settle("the bed to be paused") { bed.pauses == 1 }
        XCTAssertFalse(bed.isPlaying)
        XCTAssertFalse(rig.sounds.holdingASound, "the fade's hold outlived the pause")

        // The next wait: the same player plays on from where it was paused.
        _ = rig.speaker.awaitReply("second", readAloud: true)
        XCTAssertEqual(rig.players.players.filter { $0.name == KeeperSounds.bedFile }.count, 1, "a second bed was made")
        XCTAssertEqual(bed.plays, 2)
        XCTAssertEqual(bed.currentTime, 3.2, "the bed was started from the top")
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        rig.speaker.stop()
    }

    /// Never under a sentence: a wait taken while Topo is reading starts no bed.
    func testAWaitTakenWhileTopoIsReadingStartsNoBed() async {
        let rig = await rig(mode: .sounds)
        rig.sounds.voiceSpeaking = { true }
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertNil(rig.players.bed, "the bed was started under a sentence")
        rig.sounds.voiceSpeaking = { false }
        _ = rig.speaker.awaitReply("second", readAloud: true)
        XCTAssertEqual(rig.players.bed?.isPlaying, true)
        rig.speaker.endAwaiting("turn", "the test is done")
        rig.speaker.endAwaiting("second", "the test is done")
    }

    /// With a second turn's wait standing, the first's reply does not end the bed at its landing
    /// — the wait it ends is not the last — but at its first frame, so the bed is not under the
    /// voice. It is not brought back for the second wait once the reply is read.
    func testTheBedGivesWayAtTheFirstFrameUnderASecondWait() async throws {
        let rig = await rig(mode: .sounds, heard: .dataRendered)
        _ = rig.speaker.awaitReply("first", readAloud: true)
        _ = rig.speaker.awaitReply("second", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertTrue(rig.speaker.speak("Paris.", answering: "first"))
        XCTAssertEqual(rig.speaker.awaiting, ["second"])
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.bedVolume], "the bed faded at the reply's landing, under a wait still standing")
        await settle("the reply to start") { rig.speaker.report.started }
        try await renderUntil(rig, "the reply to be made") { rig.speaker.report.finished }
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.bedVolume, 0], "the bed played on under the voice")
        rig.speaker.endAwaiting("second", "the test is done")
    }

    /// Under `receipts` there is no bed; a mode changed to `off` mid-wait stops the bed under
    /// it; and a wait that follows within the fade cancels the pause, so the bed plays on.
    func testTheBedOnlyUnderSoundsAndOffGoesThrough() async throws {
        let receipts = await rig(mode: .receipts)
        _ = receipts.speaker.awaitReply("turn", readAloud: true)
        XCTAssertNil(receipts.players.bed, "a bed under receipts")
        receipts.speaker.endAwaiting("turn", "the test is done")

        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        rig.defaults.set(WorkingSounds.Mode.off.rawValue, forKey: WorkingSounds.key)
        rig.sounds.working(false)
        XCTAssertEqual(bed.fades.last?.to, 0, "off did not stop the bed")
        // Wanted again before the pause lands: the pause is cancelled and the bed plays on.
        await settle("the fade's sleeps to be asked for") { rig.clock.asked.contains(KeeperSounds.parkAfter) && rig.clock.asked.contains(KeeperSounds.bound) }
        rig.defaults.set(WorkingSounds.Mode.sounds.rawValue, forKey: WorkingSounds.key)
        rig.sounds.working(true)
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        rig.clock.fire()
        await drain()
        XCTAssertEqual(bed.pauses, 0, "the bed was paused under a wait that wanted it")
        XCTAssertTrue(bed.isPlaying)
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// The bed dips while a microphone is open over it (a hands-free session's, listening as its
    /// turn is sent) and comes back when it closes; a press over the wait ends it, bed and all.
    func testTheBedDipsUnderAnOpenMicrophone() async throws {
        let rig = await rig(mode: .sounds)
        var open = true
        rig.speaker.microphoneOpen = { open }
        rig.speaker.microphoneOpened(counted: false)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.duckedVolume], "the bed came in at full volume under an open microphone")
        rig.speaker.microphoneClosed()
        XCTAssertEqual(bed.fades.count, 1, "a microphone still open changed the bed")
        open = false
        rig.speaker.microphoneClosed()
        XCTAssertEqual(bed.fades.map(\.to), [KeeperSounds.duckedVolume, KeeperSounds.bedVolume])
        open = true
        rig.speaker.microphoneOpened(counted: false)
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.duckedVolume)
        rig.speaker.microphoneOpened(counted: false)
        XCTAssertEqual(bed.fades.count, 3, "the open microphone dipped the bed twice")
        open = false
        rig.speaker.microphoneClosed()
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)

        rig.speaker.microphoneOpening()
        XCTAssertTrue(rig.speaker.awaiting.isEmpty, "a press left the wait standing")
        XCTAssertEqual(bed.fades.last?.to, 0, "the bed played on under a press that ended its wait")
        // Under nothing but the fade's own hold, the bed is not wanted back.
        XCTAssertFalse(rig.audio.heldForATurn)
        rig.sounds.working(true)
        XCTAssertEqual(bed.fades.last?.to, 0, "the bed came back under a sound's own hold")
        rig.speaker.microphoneOpened(counted: true)
    }

    /// The lock screen's interruption stops the bed under a wait that still wants it; where the
    /// speaker puts its engine back, the bed is played again, through the same refusal path.
    func testTheBedComesBackWhereTheEngineDoes() async throws {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        bed.interrupted()
        await drain()
        XCTAssertEqual(bed.plays, 1)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        await drain()
        XCTAssertEqual(bed.plays, 2, "the bed was not played again with the engine")
        XCTAssertTrue(bed.isPlaying)
        XCTAssertEqual(bed.fades.last?.to, KeeperSounds.bedVolume)
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    // MARK: - The hold

    /// A sound begun while a hold stands holds the process until it is over and no longer:
    /// the error receipt's hold outlasts the wait's by the tone's length, then goes.
    func testASoundsHoldExtendsTheWaitsAndThenGoes() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.sounds.failed())
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertTrue(rig.audio.holding, "the receipt's hold went with the wait's")
        XCTAssertTrue(rig.speaker.keeping, "the keeper stopped under the receipt")
        await settle("the hold's length to be asked for") { rig.clock.asked.contains(KeeperSounds.toneLength) }
        rig.clock.fire()
        await settle("the hold to go") { !rig.audio.holding }
        XCTAssertFalse(rig.speaker.running, "the engine ran on with nothing held")
    }

    /// The fade's hold is taken before the wait's drops: behind the lock with a claim change
    /// deferred under the wait, the keeper does not stop and the claim does not apply between
    /// the two holds, only once the fade's hold has gone.
    func testTheFadesHoldIsTakenBeforeTheWaitsDrops() async throws {
        let rig = await rig(mode: .sounds, isActive: false)
        rig.audio.wantRecord(true, for: .warm)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.speaker.keeping)
        rig.audio.wantRecord(false, for: .warm)
        rig.seams.forget()
        let bed = try XCTUnwrap(rig.players.bed)

        rig.speaker.endAwaiting("turn", "the turn is done")
        XCTAssertEqual(bed.fades.last?.to, 0)
        XCTAssertTrue(rig.audio.holding, "the process was let go of with the fade unheard")
        XCTAssertFalse(rig.speaker.keeperTransitions.contains("stopped"), "the keeper stopped between the wait's hold and the fade's")
        XCTAssertEqual(rig.seams.records, [], "the deferred claim applied between the wait's hold and the fade's")
        await settle("the fade's sleeps to be asked for") { rig.clock.asked.contains(KeeperSounds.parkAfter) && rig.clock.asked.contains(KeeperSounds.bound) }
        rig.clock.fire()
        await settle("the fade's hold to go") { !rig.audio.holding }
        // Away, the last hold's going applies nothing either: the session is marked for the
        // foreground's next path, and a sound on it is refused.
        XCTAssertEqual(rig.seams.records, [], "a claim was applied from the background")
        XCTAssertFalse(rig.speaker.running)
        XCTAssertFalse(rig.sounds.tool("WebSearch"))
    }

    /// The bed wanted again inside its fade cancels the pause and nothing else: the fade's hold
    /// stands until its own length is up.
    func testTheBedWantedInsideItsFadeLeavesTheFadesHold() async throws {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.working(false)
        XCTAssertTrue(rig.sounds.holdingASound)
        await settle("the fade's sleeps to be asked for") { rig.clock.asked.contains(KeeperSounds.parkAfter) && rig.clock.asked.contains(KeeperSounds.bound) }
        rig.sounds.working(true)
        await drain()
        XCTAssertTrue(rig.sounds.holdingASound, "cancelling the pause let go of the fade's hold")
        // The bound alone: with no pause to end it, the fade's hold goes at its bound. Kills the
        // mutant where the fade's deadline never lets go.
        rig.clock.fire(KeeperSounds.bound)
        await settle("the fade's hold to go") { !rig.sounds.holdingASound }
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// A receipt played inside the bed's fade holds on its own deadline. Under `sounds` a wait
    /// plays the bed; the setting goes to `receipts`, and a second wait fades it; a WebSearch
    /// receipt sounds inside the fade, and both waits end before the pause. The pause lets go of
    /// the fade's hold and not the receipt's, which stands until the receipt's own length is up.
    /// Kills the mutant where the pause lets go of the whole hold (`letGo` in `park`).
    func testTheBedsPauseLeavesAReceiptsHold() async throws {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("first", readAloud: true)
        let bed = try XCTUnwrap(rig.players.bed)
        rig.defaults.set(WorkingSounds.Mode.receipts.rawValue, forKey: WorkingSounds.key)
        _ = rig.speaker.awaitReply("second", readAloud: true)
        XCTAssertEqual(bed.fades.last?.to, 0, "the second wait under receipts did not fade the bed")
        await settle("the fade's sleeps to be asked for") { rig.clock.asked.contains(KeeperSounds.parkAfter) && rig.clock.asked.contains(KeeperSounds.bound) }
        XCTAssertTrue(rig.sounds.tool("WebSearch"), "the receipt inside the fade was not played")
        await settle("the receipt's hold to ask for its length") { rig.clock.asked.contains(KeeperSounds.toneLength) }
        rig.speaker.endAwaiting("first", "the turn is done")
        rig.speaker.endAwaiting("second", "the turn is done")
        XCTAssertTrue(rig.audio.holding, "the sounds' hold went with the waits'")

        rig.clock.fire(KeeperSounds.parkAfter)
        await settle("the bed to be paused") { bed.pauses == 1 }
        XCTAssertTrue(rig.sounds.holdingASound, "the bed's pause let go of the receipt's hold")
        XCTAssertTrue(rig.audio.holding, "the process was let go of mid-tone")

        rig.clock.fire(KeeperSounds.toneLength)
        await settle("the receipt's hold to go") { !rig.audio.holding }
        XCTAssertFalse(rig.sounds.holdingASound)
    }

    /// A sound begun with nothing held holds nothing, and a claim change under it applies at once.
    func testASoundBegunWithNothingHeldHoldsNothing() async {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.speaker.endAwaiting("turn", "the test is done")
        await settle("the fade's sleeps to be asked for") { rig.clock.asked.contains(KeeperSounds.parkAfter) && rig.clock.asked.contains(KeeperSounds.bound) }
        rig.clock.fire()
        await settle("the fade's hold to go") { !rig.audio.holding }
        // Nothing held: a receipt is the keeper's and is not played; the bed is not either.
        XCTAssertFalse(rig.sounds.tool("Bash"))
        rig.sounds.working(true)
        XCTAssertFalse(rig.audio.holding, "a sound held alone")
        rig.seams.forget()
        rig.audio.wantRecord(true, for: .warm)
        XCTAssertEqual(rig.seams.lines, ["activate ok"], "the claim waited on a sound")
    }

    /// iOS reset the media server with a receipt's hold standing and the bed playing: the players
    /// are dropped and nothing is built, started or spoken to in the handler — not the keeper on
    /// the dead engine as the waits end under it, not the dropped bed — and the next sound makes
    /// its own.
    func testAMediaServicesResetDropsThePlayersAndBuildsNothing() async throws {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile, "bloop_read"])
        let bed = try XCTUnwrap(rig.players.bed)
        await settle("the receipt's hold to ask for its length") { rig.clock.asked.contains(KeeperSounds.toneLength) }
        let fades = bed.fades.count
        let engines = rig.seams.engines.count
        let transitions = rig.speaker.keeperTransitions.count
        let asked = rig.clock.asked.count
        // The reset leaves the engine stopped, as the offline one is not by the notification
        // alone: the wait ending under the handler with the receipt's hold still standing
        // re-notifies the hold, and on a stopped engine that is the keeper started again.
        let engine = try XCTUnwrap(rig.seams.engines.last)
        engine.stop()
        let starts = rig.seams.playEngineStarts

        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await drain()
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile, "bloop_read"], "a player was built in the reset handler")
        XCTAssertFalse(rig.audio.holding, "the reset left a hold standing")
        XCTAssertFalse(rig.sounds.holdingASound, "the reset left a sound's owner standing")
        XCTAssertEqual(rig.seams.engines.count, engines, "an engine was built in the reset handler")
        XCTAssertFalse(rig.speaker.keeperTransitions.dropFirst(transitions).contains("playing"), "the keeper was started in the reset handler: \(rig.speaker.keeperTransitions)")
        XCTAssertEqual(rig.seams.playEngineStarts, starts, "the engine the reset killed was started again")
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(rig.speaker.running)
        XCTAssertEqual(bed.fades.count, fades, "the dropped bed was faded")
        XCTAssertEqual(bed.pauses, 0, "the dropped bed was spoken to")
        XCTAssertEqual(rig.clock.asked.count, asked, "a sleep was asked for in the reset handler")

        _ = rig.speaker.awaitReply("again", readAloud: true)
        rig.sounds.follow(toolUse("WebSearch"))
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile, "bloop_read", KeeperSounds.bedFile, "bloop_read"],
                       "a player the reset invalidated was reused")
        rig.speaker.endAwaiting("again", "the test is done")
    }

    /// The session's reset handler has run and the speaker's has not (each on a center of its
    /// own, posted one at a time): the session is live again under a wait still standing, and a
    /// sound in between finds players made before the reset. Neither is spoken to; the receipt
    /// makes its own.
    func testASoundBetweenTheSessionsResetHandlerAndTheSpeakersMakesItsOwnPlayer() async throws {
        let speakerCenter = NotificationCenter()
        let rig = await rig(mode: .sounds, speakerCenter: speakerCenter)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(toolUse("Bash"))
        let bed = try XCTUnwrap(rig.players.bed)
        let act = try XCTUnwrap(rig.players.players.first { $0.name == "bloop_act" })
        let fades = bed.fades.count

        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await drain()
        XCTAssertNoThrow(try rig.audio.ensureLive(), "the session's handler did not make it live again")
        XCTAssertTrue(rig.audio.heldForATurn)

        rig.sounds.working(false)
        XCTAssertEqual(bed.fades.count, fades, "a bed made before the reset was faded")
        XCTAssertEqual(bed.pauses, 0, "a bed made before the reset was paused")
        XCTAssertTrue(rig.sounds.tool("Bash"))
        XCTAssertEqual(act.plays, 1, "a receipt made before the reset was played")
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile, "bloop_act", "bloop_act"])

        speakerCenter.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await drain()
        XCTAssertTrue(rig.speaker.awaiting.isEmpty)
    }

    /// A sound at the reset's notification, before any handler has run, is refused: the session
    /// counts the reset and stops being live at the notification itself.
    func testASoundAtTheResetNotificationIsRefused() async throws {
        let rig = await rig(mode: .sounds)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.sounds.follow(toolUse("Bash"))
        let bed = try XCTUnwrap(rig.players.bed)
        let act = try XCTUnwrap(rig.players.players.first { $0.name == "bloop_act" })
        let fades = bed.fades.count

        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        XCTAssertFalse(rig.sounds.tool("Bash"), "a receipt played at the reset's notification")
        rig.sounds.working(false)
        XCTAssertEqual(act.plays, 1, "a receipt made before the reset was played")
        XCTAssertEqual(bed.fades.count, fades, "a bed made before the reset was faded")
        XCTAssertEqual(rig.players.names, [KeeperSounds.bedFile, "bloop_act"], "a player was made on a reset session")
        await drain()
    }

    // MARK: - The harness

    /// Following the harness wraps what Topo installed: he still hears every activity, and the
    /// sounds hear it after him.
    func testFollowingTheHarnessLeavesTopoFollowingIt() async {
        let rig = await rig()
        let harness = Harness(database: InMemoryRecordDatabase(), device: DeviceID("phone"), ensureZone: {},
                              defaults: makeDefaults(), brain: NoBrain(),
                              leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                              pause: { _ in throw CancellationError() })
        let mascot = Mascot()
        mascot.follow(harness)
        rig.sounds.follow(harness)
        _ = rig.speaker.awaitReply("turn", readAloud: true)

        harness.onGuest?(.began(pid: nil, answering: []))
        harness.onGuest?(toolUse("WebSearch"))
        XCTAssertEqual(mascot.state.activity, .searching, "Topo stopped following the harness")
        XCTAssertEqual(rig.sounds.played, [.read])
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// Every sound has its file in the bundle, at the root, where `KeeperSounds` looks.
    func testEverySoundIsBundled() {
        let bundle = Bundle(for: KeeperSounds.self)
        for tone in KeeperSounds.Tone.allCases {
            XCTAssertNotNil(bundle.url(forResource: tone.file, withExtension: "wav"), "\(tone.file).wav is not in the bundle")
        }
        XCTAssertNotNil(bundle.url(forResource: KeeperSounds.bedFile, withExtension: "wav"))
    }
}

/// A sleep the test fires, so a bound or a pause is a moment the test chooses. Each sleep is its
/// own: cancelling one ends that one and no other.
final class PausedSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [UUID: (duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]
    /// Sleeps cancelled before their continuation was kept, which end as soon as it is.
    private var cancelled: Set<UUID> = []
    private var _asked: [Duration] = []

    var asked: [Duration] { lock.withLock { _asked } }

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Asked and waiting under one lock, so a sleep a test sees asked for is one it can fire.
                let early = lock.withLock { () -> Bool in
                    _asked.append(duration)
                    if cancelled.remove(id) != nil { return true }
                    waiting[id] = (duration, continuation)
                    return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let mine = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let continuation = waiting.removeValue(forKey: id)?.continuation else {
                    cancelled.insert(id)
                    return nil
                }
                return continuation
            }
            mine?.resume(throwing: CancellationError())
        }
    }

    /// Every sleep waiting ends now, or only those asked for `duration`.
    func fire(_ duration: Duration? = nil) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let ids = waiting.filter { duration == nil || $0.value.duration == duration }.map(\.key)
            return ids.compactMap { waiting.removeValue(forKey: $0)?.continuation }
        }
        due.forEach { $0.resume() }
    }
}

/// A brain for a harness no turn is sent through.
private struct NoBrain: Brain {
    struct NotHere: Error {}
    func answer(_ request: BrainRequest) async throws -> Reply { throw NotHere() }
    func describe() async -> String { "no brain" }
}
