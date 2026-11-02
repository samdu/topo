import AVFoundation
import TopoCore
import TopoCoreTesting
import TopoTurn
import UIKit
import XCTest

@testable import Topo

/// A cue's player as the suite has it: it records each play and is heard out when the test says.
@MainActor
final class FakeCuePlayer: CuePlayer {
    let url: URL
    private(set) var plays = 0
    var refusesToStart = false
    private var whenDone: (@MainActor () -> Void)?

    init(url: URL) { self.url = url }

    func play(whenDone: @escaping @MainActor () -> Void) -> Bool {
        guard !refusesToStart else { return false }
        plays += 1
        self.whenDone = whenDone
        return true
    }

    /// Whether a play is still being heard out.
    var sounding: Bool { whenDone != nil }

    /// The cue heard out, as the player's delegate would say.
    func finish() {
        let done = whenDone
        whenDone = nil
        done?()
    }
}

/// Every player `Earcons` asked for, in order, and the file each was made over.
@MainActor
final class CueRecorder {
    private(set) var players: [FakeCuePlayer] = []
    var nextRefusesToStart = false
    var files: [String] { players.map { $0.url.deletingPathExtension().lastPathComponent } }

    func make(_ url: URL) -> FakeCuePlayer {
        let player = FakeCuePlayer(url: url)
        player.refusesToStart = nextRefusesToStart
        nextRefusesToStart = false
        players.append(player)
        return player
    }
}

/// The four cues of a spoken exchange, each at its moment and once, over the chat's own press
/// path (`MicPress`), a real `Speaker` and `VoiceInput` on the audio seams and the harness's
/// handlers as `SpokenReply.follow` installs them; the cues' players are the suite's. What is held
/// is that a cue follows a decision rather than making one, that nothing sounds at a stop, a
/// refused press, a muted setting or a dead session, and that a cue's hold is taken under the
/// hold it follows and let go of when it has been heard out or at its bound.
@MainActor
final class EarconsTests: XCTestCase {
    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    @MainActor struct Rig {
        let speaker: Speaker
        let voice: VoiceInput
        let earcons: Earcons
        let cues: CueRecorder
        let seams: Seams
        let audio: AudioSession
        let center: NotificationCenter
        let defaults: UserDefaults
        let press = MicPress()
        var sent: [String] = []

        func showing() -> Composer.MicState { Composer.MicState(voice, speaking: speaker.speaking) }
    }

    private func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<6_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited a minute for \(what)", file: file, line: line)
    }

    private func drain() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "topo.tests.earcons.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// A speaker over a resident voice and a microphone over a resident ear whose release hears
    /// `hears`, sharing one audio session, with the speaker's earcons over the recorder's players.
    private func rig(hears: String = "", engine: any VoiceEngine = ScriptedVoice(),
                     permission: @escaping @MainActor () async -> Bool = { true },
                     isActive: Bool = true,
                     heard: AVAudioPlayerNodeCompletionCallbackType = .dataPlayedBack,
                     sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async -> Rig {
        let seams = Seams()
        let center = NotificationCenter()
        let defaults = makeDefaults()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { isActive })
        let cues = CueRecorder()
        let earcons = Earcons(audio: audio, center: center, defaults: defaults, bundle: Bundle(for: Earcons.self),
                              makePlayer: { cues.make($0) }, sleep: sleep)
        let voice = Voice(engine: engine)
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) },
                              heard: heard, earcons: earcons)
        let ear = Ear(vocabulary: Vocabulary(defaults: makeDefaults()),
                      engine: ScriptedEngine(bare: hears, boosted: hears))
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear to load") { ear.ready }
        let input = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) },
                               permission: permission,
                               voiceProcessing: { try seams.process($0, $1) })
        speaker.microphoneOpen = { input.listening }
        return Rig(speaker: speaker, voice: input, earcons: earcons, cues: cues, seams: seams,
                   audio: audio, center: center, defaults: defaults)
    }

    /// The thumb on the microphone, through the chat's own routing.
    private func press(_ rig: Rig, _ down: Bool, _ sent: Sent, dictating: Bool = false) async {
        await rig.press.gesture(down, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
                                dictating: dictating) { sent.add($0) }?.value
    }

    /// A second and a half of tone at the ear's rate, as the tap would have delivered it.
    private func utterance(into sink: SampleSink) {
        let format = sink.format
        let frames = AVAudioFrameCount(format.sampleRate * 1.5)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData else { return XCTFail("no buffer at the ear's rate") }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { channel[0][frame] = 0.1 * Float(sin(Double(frame) * 0.05)) }
        sink.append(buffer)
    }

    /// Renders the play queue's offline engine a slice at a time until `condition` holds.
    private func render(_ rig: Rig, until what: String, slices: Int = 400,
                        file: StaticString = #filePath, line: UInt = #line,
                        _ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<slices {
            if condition() { return }
            let engine = try XCTUnwrap(rig.seams.engines.last, file: file, line: line)
            let out = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                                     frameCapacity: engine.manualRenderingMaximumFrameCount))
            _ = try? engine.renderOffline(256, to: out)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        await drain()
        XCTAssertTrue(condition(), "rendered \(slices) slices waiting for \(what)", file: file, line: line)
    }

    // MARK: - The press

    /// Hold to talk: the microphone opening sounds `listening`, once, over the bundled file; the
    /// release that heard words sounds `sent`, once, and sends them.
    func testAHeldPressSoundsListeningAndItsReleaseSoundsSent() async {
        let rig = await rig(hears: "purple elephants")
        let sent = Sent()
        defer { rig.voice.cancel() }

        await press(rig, true, sent)
        XCTAssertTrue(rig.voice.listening)
        XCTAssertEqual(rig.earcons.played, [.listening])
        XCTAssertEqual(rig.cues.files, ["earcon_listening"], "the cue was not made over the bundled file")
        XCTAssertEqual(rig.cues.players.first?.plays, 1)

        utterance(into: rig.voice.sink)
        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        await press(rig, false, sent)
        XCTAssertEqual(sent.texts, ["purple elephants"])
        XCTAssertEqual(rig.earcons.played, [.listening, .sent])
        XCTAssertEqual(rig.cues.files, ["earcon_listening", "earcon_sent"])
    }

    /// A release that heard nothing sends nothing worth sending and sounds `failed`.
    func testAReleaseThatHeardNothingSoundsFailed() async {
        let rig = await rig(hears: "")
        let sent = Sent()
        defer { rig.voice.cancel() }

        await press(rig, true, sent)
        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        await press(rig, false, sent)
        XCTAssertFalse(rig.voice.listening)
        XCTAssertEqual(rig.earcons.played, [.listening, .failed])
        XCTAssertEqual(rig.cues.files, ["earcon_listening", "earcon_failed"])
    }

    /// A release whose words are written into the row rather than sent (`Dictation`) sounds
    /// nothing: nothing went. The microphone's own `listening` is heard as at any press.
    func testAReleaseWrittenIntoTheRowSoundsNothingButListening() async {
        let rig = await rig(hears: "purple elephants")
        let sent = Sent()
        defer { rig.voice.cancel() }
        await press(rig, true, sent, dictating: true)
        XCTAssertEqual(rig.earcons.played, [.listening])
        utterance(into: rig.voice.sink)
        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        await press(rig, false, sent, dictating: true)
        XCTAssertEqual(sent.texts, ["purple elephants"], "the words were not handed to the row")
        XCTAssertEqual(rig.earcons.played, [.listening], "a release into the row sounded")
    }

    /// A tap opens the microphone hands free and its release sounds nothing, since nothing went;
    /// the press on the waveform sends what was heard and sounds `sent`.
    func testATapsReleaseSoundsNothingAndThePressOnTheWaveformSoundsSent() async {
        let rig = await rig(hears: "purple elephants")
        let sent = Sent()
        defer { rig.voice.cancel() }

        await press(rig, true, sent)
        await press(rig, false, sent)
        XCTAssertTrue(rig.voice.handsFree)
        XCTAssertEqual(rig.earcons.played, [.listening])

        utterance(into: rig.voice.sink)
        await press(rig, true, sent)
        XCTAssertEqual(sent.texts, ["purple elephants"])
        XCTAssertEqual(rig.earcons.played, [.listening, .sent])
        // Its release is the sending press's own and reaches no session.
        await press(rig, false, sent)
        XCTAssertEqual(rig.earcons.played, [.listening, .sent])
    }

    /// A press while Topo speaks is Stop: it opens nothing, and neither it, its release nor the
    /// reply it cut short sounds anything. `done` is a reply heard to its end, not one stopped.
    func testAStopAndTheReplyItCutsShortSoundNothing() async {
        let held = HeldVoice()
        let rig = await rig(engine: held)
        let sent = Sent()
        defer { held.releaseTheHeldFrame(); rig.speaker.stop(); rig.voice.cancel() }
        XCTAssertTrue(rig.speaker.speak("Paris is the capital. It is on the Seine."))
        await settle("the reply to start") { rig.speaker.report.started }
        XCTAssertEqual(rig.showing().appearance, .stop)

        await press(rig, true, sent)
        XCTAssertFalse(rig.speaker.speaking)
        await press(rig, false, sent)
        await drain()
        XCTAssertEqual(rig.voice.presses, 0)
        XCTAssertEqual(rig.earcons.played, [])
        XCTAssertTrue(rig.cues.players.isEmpty, "a player was made for a cue nothing sounded")
    }

    /// Released while the permission prompt is up: the press is cancelled, no microphone opens,
    /// and nothing sounds — not at the release, and not when the prompt is answered after it.
    func testAReleaseDuringThePermissionPromptSoundsNothing() async {
        let prompt = Prompt()
        let rig = await rig(permission: { await prompt.answer() })
        let sent = Sent()
        defer { rig.voice.cancel() }

        let down = rig.press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }
        await settle("the press to reach the prompt") { prompt.asked }
        await press(rig, false, sent)
        prompt.allow()
        await down?.value
        await drain()
        XCTAssertFalse(rig.voice.listening)
        XCTAssertEqual(rig.earcons.played, [])
        XCTAssertEqual(sent.texts, [])
    }

    /// A press the microphone refuses (no permission) opens nothing and sounds nothing: the cue
    /// follows `VoiceInput`'s decision.
    func testARefusedPressSoundsNothing() async {
        let rig = await rig(permission: { false })
        let sent = Sent()
        await press(rig, true, sent)
        XCTAssertFalse(rig.voice.listening)
        XCTAssertEqual(rig.earcons.played, [])
        XCTAssertTrue(rig.cues.players.isEmpty)
    }

    // MARK: - The reply

    /// A reply heard to its end sounds `done`, and sounds it under the reply's own hold: the cue's
    /// hold is taken before `.speaking` drops, so the holds never go empty between the two and
    /// nothing is configured or activated again on their way. Behind the lock that gap is a hold
    /// retaken on a session the last one's going left to wait, which is a refused activation.
    func testAFinishedReplySoundsDoneUnderTheReplysHoldAndRetakesNothing() async throws {
        let rig = await rig(isActive: false, heard: .dataRendered)
        // The foreground's warm claim, then the lock: the claim dropped under the reply's hold is
        // deferred, and what matters is that nothing applies it between the two holds.
        rig.audio.wantRecord(true, for: .warm)
        XCTAssertTrue(rig.speaker.speak("Hi."))
        await settle("the reply to start") { rig.speaker.report.started }
        rig.audio.wantRecord(false, for: .warm)
        rig.seams.forget()

        try await render(rig, until: "the reply to finish") { rig.speaker.report.finished }
        XCTAssertEqual(rig.earcons.played, [.done])
        XCTAssertEqual(rig.cues.files, ["earcon_done"])
        XCTAssertFalse(rig.speaker.speaking)
        XCTAssertTrue(rig.audio.holding, "the cue's hold did not stand once the reply's dropped")
        XCTAssertFalse(rig.seams.lines.contains("activate ok"), rig.seams.lines.joined(separator: ", "))
        XCTAssertFalse(rig.speaker.keeperTransitions.suffix(1) == ["stopped"], "the keeper stopped between the reply's hold and the cue's")

        // Heard out: the cue's hold goes, and with it the keeper and the engine.
        rig.cues.players.last?.finish()
        XCTAssertFalse(rig.audio.holding)
        XCTAssertFalse(rig.speaker.running, "the engine ran on with nothing held")
    }

    // MARK: - The turn

    /// A spoken turn that fails sounds `failed`, once, before its wait ends; a turn no wait stands
    /// for — a typed one, or one whose reply was already read — sounds nothing; and the other
    /// ends of a wait the harness reports through `onTurnFailed` alone (a limb's turn, iCloud
    /// behind a finished reply) sound nothing.
    func testASpokenTurnThatFailsSoundsFailedOnceAndOtherEndsSoundNothing() async {
        let rig = await rig()
        // No lease loop runs under the test: its sleep is parked and its pause throws.
        let harness = Harness(database: InMemoryRecordDatabase(), device: DeviceID("phone"), ensureZone: {},
                              defaults: makeDefaults(), brain: NoBrain(),
                              leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                              pause: { _ in throw CancellationError() })
        SpokenReply.follow(harness, speaker: rig.speaker) { true }
        let ask = rig.speaker.awaitReply("spoken", readAloud: true)
        XCTAssertTrue(ask.spoken)
        XCTAssertEqual(rig.speaker.awaiting, ["spoken"])

        // The turn fails for the person: the harness tells the failure, then the end.
        harness.onTurnFailure?("spoken")
        XCTAssertEqual(rig.earcons.played, [.failed])
        XCTAssertTrue(rig.audio.holding, "the wait ended before the cue took its hold")
        harness.onTurnFailed?("spoken")
        XCTAssertEqual(rig.speaker.awaiting, [])
        XCTAssertEqual(rig.earcons.played, [.failed], "the end of the wait sounded again")
        XCTAssertTrue(rig.audio.holding, "the cue's hold went with the wait's")
        rig.cues.players.last?.finish()
        XCTAssertFalse(rig.audio.holding)

        // A typed turn fails: no wait, no cue.
        harness.onTurnFailure?("typed")
        harness.onTurnFailed?("typed")
        XCTAssertEqual(rig.earcons.played, [.failed])

        // A spoken turn ends another way: answered by another device, or finished with iCloud
        // behind. The harness ends the wait and says nothing of a failure.
        _ = rig.speaker.awaitReply("limb", readAloud: true)
        harness.onTurnFailed?("limb")
        XCTAssertEqual(rig.speaker.awaiting, [])
        XCTAssertEqual(rig.earcons.played, [.failed])
    }

    /// The failure's cue is not played into an open microphone: a second press while the first
    /// turn is in flight is allowed, and a cue is a moment, not a reply, so it is dropped rather
    /// than deferred. `listening` is the microphone's own and is the one exception.
    func testAFailedCueIsNotPlayedIntoAnOpenMicrophone() async {
        let rig = await rig()
        let sent = Sent()
        defer { rig.voice.cancel() }
        await press(rig, true, sent)
        XCTAssertTrue(rig.voice.listening)
        XCTAssertEqual(rig.earcons.played, [.listening])

        XCTAssertFalse(rig.earcons.play(.failed))
        XCTAssertFalse(rig.earcons.play(.done))
        XCTAssertEqual(rig.earcons.played, [.listening])
        XCTAssertEqual(rig.cues.files, ["earcon_listening"], "a player was made for a cue the open microphone refused")
    }

    // MARK: - The setting and the session

    /// Earcons off: nothing sounds, and no player is made for it. Back on, the next cue sounds.
    func testOffSoundsNothingAndMakesNoPlayer() async {
        let rig = await rig()
        let sent = Sent()
        defer { rig.voice.cancel() }
        rig.defaults.set(false, forKey: EarconsSetting.key)
        XCTAssertFalse(EarconsSetting.enabled(rig.defaults))

        await press(rig, true, sent)
        XCTAssertTrue(rig.voice.listening)
        XCTAssertEqual(rig.earcons.played, [])
        XCTAssertTrue(rig.cues.players.isEmpty)
        XCTAssertFalse(rig.earcons.play(.done))

        rig.defaults.set(true, forKey: EarconsSetting.key)
        XCTAssertTrue(rig.earcons.play(.listening))
        XCTAssertEqual(rig.earcons.played, [.listening])
    }

    /// A phone never asked sounds them; anything kept that is not a Boolean reads as off only when
    /// it is false.
    func testAPhoneNeverAskedSoundsThem() {
        let defaults = makeDefaults()
        XCTAssertTrue(EarconsSetting.enabled(defaults))
        defaults.set(false, forKey: EarconsSetting.key)
        XCTAssertFalse(EarconsSetting.enabled(defaults))
        defaults.set(true, forKey: EarconsSetting.key)
        XCTAssertTrue(EarconsSetting.enabled(defaults))
    }

    /// Review Focus 11: a cue on a session that will not activate is refused, not played. No
    /// player is made, no hold is taken, and the refusal leaves the session for the next path.
    func testACueOnAnInvalidSessionIsRefusedNotPlayed() async {
        let rig = await rig()
        rig.seams.activationError = Seams.Refused()
        rig.audio.invalidate()

        XCTAssertFalse(rig.earcons.play(.done))
        XCTAssertEqual(rig.earcons.played, [])
        XCTAssertTrue(rig.cues.players.isEmpty, "a player was made on a session that did not activate")
        XCTAssertFalse(rig.audio.holding, "a hold was taken for a cue that was refused")
        XCTAssertEqual(rig.seams.lines, ["activate failed"])

        // The session back: the next cue is played, and the one before it stays refused.
        rig.seams.activationError = nil
        XCTAssertTrue(rig.earcons.play(.done))
        XCTAssertEqual(rig.earcons.played, [.done])
    }

    /// A player that will not start takes no hold and is not counted as played.
    func testACueWhosePlayerWillNotStartHoldsNothing() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.cues.nextRefusesToStart = true
        XCTAssertFalse(rig.earcons.play(.failed))
        XCTAssertEqual(rig.earcons.played, [])
        XCTAssertEqual(rig.cues.files, ["earcon_failed"])
        rig.speaker.endAwaiting("turn", "the test is done with it")
        XCTAssertFalse(rig.audio.holding, "a hold was taken for a cue that did not start")
    }

    /// A cue begun with nothing held holds nothing: in front nothing suspends, and a claim change
    /// made under it is applied at once rather than kept waiting on the cue.
    func testACueBegunWithNothingHeldHoldsNothing() async {
        let rig = await rig()
        XCTAssertTrue(rig.earcons.play(.sent))
        XCTAssertFalse(rig.audio.holding, "a cue held alone")
        rig.seams.forget()
        rig.audio.wantRecord(true, for: .warm)
        XCTAssertEqual(rig.seams.lines, ["activate ok"], "the claim waited on the cue")
        rig.cues.players.last?.finish()
        XCTAssertFalse(rig.audio.holding)
    }

    /// The cue's hold is bounded: a player whose finish never comes is let go of at `Earcons.bound`,
    /// so no hold outlives its cue. A finish after that moves nothing.
    func testTheBoundLetsGoOfAHoldWhosePlayerNeverFinishes() async {
        let clock = ManualSleep()
        let rig = await rig(sleep: { try await clock.sleep($0) })
        // The wait the cue follows, ended under it as the harness ends one.
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.failed))
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertTrue(rig.audio.holding, "the cue's hold did not outlast the wait's")
        await settle("the bound to be asked for") { clock.asked == [Earcons.bound] }
        clock.fire()
        await settle("the hold to go") { !rig.audio.holding }
        XCTAssertFalse(rig.speaker.running)

        rig.cues.players.last?.finish()
        XCTAssertFalse(rig.audio.holding)

        // Heard out in time: the bound is cancelled rather than fired.
        _ = rig.speaker.awaitReply("second", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.failed))
        rig.speaker.endAwaiting("second", "the turn failed")
        XCTAssertTrue(rig.audio.holding)
        rig.cues.players.last?.finish()
        XCTAssertFalse(rig.audio.holding)
        await drain()
        XCTAssertEqual(clock.asked.count, 2)
        XCTAssertTrue(clock.cancelled, "the bound was left running after the cue was heard out")
    }

    /// A second cue while the first is still sounding keeps the one hold and lets it go when the
    /// second is heard out, not the first.
    func testASecondCueKeepsTheHoldUntilItIsHeardOut() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.sent))
        XCTAssertTrue(rig.earcons.play(.done))
        XCTAssertEqual(rig.cues.files, ["earcon_sent", "earcon_done"])
        rig.speaker.endAwaiting("turn", "the turn failed")
        rig.cues.players[0].finish()
        XCTAssertTrue(rig.audio.holding, "the first cue's finish let go of the second's hold")
        rig.cues.players[1].finish()
        XCTAssertFalse(rig.audio.holding)
    }

    /// iOS reset the media server: the players were handles into it and are dropped, the cue
    /// that was playing is over with its hold, and nothing is built in the handler — the next
    /// cue makes its own player afresh.
    func testAMediaServicesResetDropsThePlayersAndBuildsNothing() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.done))
        XCTAssertEqual(rig.cues.files, ["earcon_done"])
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertTrue(rig.audio.holding)

        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await drain()
        XCTAssertEqual(rig.cues.files, ["earcon_done"], "a player was built in the reset handler")
        XCTAssertFalse(rig.audio.holding, "the reset left the cue's hold standing")

        // The old player is not heard out, and its late finish moves nothing.
        rig.cues.players[0].finish()
        XCTAssertFalse(rig.audio.holding)

        XCTAssertTrue(rig.earcons.play(.done))
        XCTAssertEqual(rig.cues.files, ["earcon_done", "earcon_done"], "the next cue reused a player the reset invalidated")
        XCTAssertEqual(rig.cues.players[1].plays, 1)
    }

    /// Every cue has its file in the bundle, at the root, where `Earcons` looks.
    func testEveryCueIsBundled() {
        let bundle = Bundle(for: Earcons.self)
        for cue in Earcons.Cue.allCases {
            XCTAssertNotNil(bundle.url(forResource: cue.file, withExtension: "mp3"), "\(cue.file).mp3 is not in the bundle")
        }
        XCTAssertEqual(Earcons.Cue.sending(""), .failed)
        XCTAssertEqual(Earcons.Cue.sending("purple elephants"), .sent)
    }
}

/// A permission prompt the test answers when it chooses.
@MainActor
private final class Prompt {
    private(set) var asked = false
    private var waiting: CheckedContinuation<Bool, Never>?
    private var answered: Bool?

    func answer() async -> Bool {
        asked = true
        if let answered { return answered }
        return await withCheckedContinuation { waiting = $0 }
    }

    func allow() {
        answered = true
        waiting?.resume(returning: true)
        waiting = nil
    }
}

/// A sleep the test fires, so a bound is a moment the test chooses.
final class ManualSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, any Error>] = []
    private var _asked: [Duration] = []
    private var _cancelled = false

    var asked: [Duration] { lock.withLock { _asked } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { _asked.append(duration) }
        // Cancelled before the sleep began, which a finish straight after the play does: as
        // cancelled as one cut short.
        do { try Task.checkCancellation() } catch {
            lock.withLock { _cancelled = true }
            throw error
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { waiting.append(continuation) }
            }
        } onCancel: {
            let cancelled = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
                _cancelled = true
                let all = waiting
                waiting = []
                return all
            }
            cancelled.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    func fire() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let all = waiting
            waiting = []
            return all
        }
        all.forEach { $0.resume() }
    }
}

/// A brain for a harness no turn is sent through.
private struct NoBrain: Brain {
    struct NotHere: Error {}
    func answer(_ request: BrainRequest) async throws -> Reply { throw NotHere() }
    func describe() async -> String { "no brain" }
}

/// What the chat was handed to send, in order.
@MainActor
private final class Sent {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}
