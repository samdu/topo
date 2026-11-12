import AVFoundation
import TopoCore
import TopoCoreTesting
import TopoTurn
import TopoUserland
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

    private(set) var stops = 0
    func stop() {
        stops += 1
        whenDone = nil
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

/// An `AVAudioPlayer` whose sounding the suite states: `play` starts it, and the test says when
/// it falls silent, as the hardware would.
final class StatedPlayer: AVAudioPlayer {
    var sounding = false
    override var isPlaying: Bool { sounding }
    override func play() -> Bool {
        sounding = true
        return true
    }
    override func stop() { sounding = false }
    override func prepareToPlay() -> Bool { true }
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
                     sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                     tail: Duration = .zero) async -> Rig {
        let seams = Seams()
        let center = NotificationCenter()
        let defaults = makeDefaults()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { isActive })
        let cues = CueRecorder()
        let earcons = Earcons(audio: audio, defaults: defaults, bundle: Bundle(for: Earcons.self),
                              makePlayer: { cues.make($0) }, sleep: sleep, tail: { tail })
        let voice = Voice(engine: engine)
        voice.load(folder: URL(fileURLWithPath: "/dev/null"))
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
    private func press(_ rig: Rig, _ down: Bool, _ sent: Sent, held: Bool = false, dictating: Bool = false) async {
        await rig.press.gesture(down, held: held, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
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
        await press(rig, false, sent, held: true)
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
        await press(rig, false, sent, held: true)
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
        await press(rig, false, sent, held: true, dictating: true)
        XCTAssertEqual(sent.texts, ["purple elephants"], "the words were not handed to the row")
        XCTAssertEqual(rig.earcons.played, [.listening], "a release into the row sounded")
    }

    /// A hands-free session over the row: the tap sounds `listening`, and the press on the
    /// waveform that writes what it heard into the row sounds nothing, since nothing went.
    func testTheWaveformPressIntoTheRowSoundsNothing() async {
        let rig = await rig(hears: "purple elephants")
        let sent = Sent()
        defer { rig.voice.cancel() }
        await press(rig, true, sent, dictating: true)
        await press(rig, false, sent, dictating: true)
        XCTAssertTrue(rig.voice.handsFree)
        XCTAssertEqual(rig.earcons.played, [.listening])

        utterance(into: rig.voice.sink)
        await press(rig, true, sent, dictating: true)
        XCTAssertEqual(sent.texts, ["purple elephants"], "the words were not handed to the row")
        XCTAssertEqual(rig.earcons.played, [.listening], "a waveform press into the row sounded")
        await press(rig, false, sent, dictating: true)
        XCTAssertEqual(rig.earcons.played, [.listening])
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

    /// A chat press while another gate holds the microphone — the first run's — opens nothing,
    /// and sounds nothing though the microphone is listening: the cue is the chat's own.
    func testAPressWhileAnotherGateHoldsTheMicrophoneSoundsNothing() async {
        let rig = await rig()
        let sent = Sent()
        defer { rig.voice.cancel() }
        _ = await rig.voice.pressDown(as: .firstRun)
        XCTAssertTrue(rig.voice.listening)
        XCTAssertEqual(rig.voice.owner, .firstRun)

        await press(rig, true, sent)
        XCTAssertEqual(rig.voice.owner, .firstRun, "the chat's press took the microphone from the first run")
        XCTAssertEqual(rig.earcons.played, [], "listening sounded for a microphone the chat does not hold")
        await press(rig, false, sent)
        XCTAssertEqual(rig.earcons.played, [])
        XCTAssertEqual(sent.texts, [])
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

    /// In a conversation the reply's end is the go-ahead's (`Conversation`): a reply heard out
    /// under one sounds no `done`, so the moment has one tone, and one cut short by its turn's
    /// failure still sounds `failed`.
    /// With no keeper's sounds to say the go-ahead, a conversation's reply still ends in `done`
    /// (`KeeperSoundsTests` has the go-ahead taking its place).
    func testAReplyHeardOutInAConversationWithNoGoAheadSoundsDone() async throws {
        let rig = await rig(heard: .dataRendered)
        rig.speaker.conversing = true
        XCTAssertTrue(rig.speaker.speak("Hi."))
        await settle("the reply to start") { rig.speaker.report.started }
        try await render(rig, until: "the reply to finish") { rig.speaker.report.finished }
        XCTAssertEqual(rig.earcons.played, [.done], "a conversation's reply with no go-ahead to come ended in silence")
        XCTAssertFalse(rig.speaker.speaking)
    }

    /// A cue stands in for the go-ahead for a second and a half after it begins, and no longer.
    func testACueIsRecentForASecondAndAHalf() async {
        let rig = await rig()
        var now = ContinuousClock.now
        rig.earcons.now = { now }
        try? rig.audio.ensureActive()
        XCTAssertFalse(rig.earcons.recent(Conversation.earconReceipt), "recent before any cue")
        XCTAssertTrue(rig.earcons.play(.listening))
        now += .milliseconds(1400)
        XCTAssertTrue(rig.earcons.recent(Conversation.earconReceipt))
        now += .milliseconds(200)
        XCTAssertFalse(rig.earcons.recent(Conversation.earconReceipt), "a cue stood in past a second and a half")
    }

    // MARK: - The turn

    /// A harness over an in-memory log whose brain is the test's. No lease loop runs under it:
    /// its sleep is parked and its pause throws.
    private func harness(brain: any Brain, relay: GuestRelay = GuestRelay()) -> Harness {
        Harness(database: InMemoryRecordDatabase(), device: DeviceID("phone"), ensureZone: {},
                defaults: makeDefaults(), brain: brain, relay: relay,
                leaseSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
                pause: { _ in throw CancellationError() })
    }

    /// A spoken turn that fails — a real turn, through the harness, whose brain throws — sounds
    /// `failed`, once, before its wait ends and under the wait's hold; a typed turn that fails
    /// the same way sounds nothing; and the other ends of a wait the harness reports through
    /// `onTurnFailed` alone (a limb's turn, iCloud behind a finished reply) sound nothing.
    func testASpokenTurnThatFailsSoundsFailedOnceAndOtherEndsSoundNothing() async {
        let rig = await rig()
        let harness = harness(brain: NoBrain())
        SpokenReply.follow(harness, speaker: rig.speaker) { true }
        let spoken = harness.willSend("what is the capital of France")
        harness.markSpoken(spoken)
        let ask = rig.speaker.awaitReply(spoken, readAloud: true)
        XCTAssertTrue(ask.spoken)
        XCTAssertEqual(rig.speaker.awaiting, [spoken])

        // The turn fails for the person: the brain throws.
        await harness.retry()
        XCTAssertNotNil(harness.error)
        XCTAssertEqual(rig.earcons.played, [.failed])
        XCTAssertEqual(rig.speaker.awaiting, [])
        XCTAssertTrue(rig.audio.holding, "the cue's hold went with the wait's")
        XCTAssertFalse(rig.speaker.keeperTransitions.contains("stopped"), "the keeper stopped between the wait's hold and the cue's")
        rig.cues.players.last?.finish()
        XCTAssertFalse(rig.audio.holding)

        // A typed turn fails the same way: no wait, no cue.
        harness.willSend("and of Italy")
        await harness.retry()
        XCTAssertEqual(rig.earcons.played, [.failed])

        // A spoken turn ends another way: answered by another device, or finished with iCloud
        // behind. The harness ends the wait and says nothing of a failure.
        _ = rig.speaker.awaitReply("limb", readAloud: true)
        harness.onTurnFailed?("limb")
        XCTAssertEqual(rig.speaker.awaiting, [])
        XCTAssertEqual(rig.earcons.played, [.failed])
    }

    /// A spoken turn whose reply is being read as the guest writes it, and whose turn then
    /// fails, ends with `failed`, not `done`: what was heard was cut short. Driven through the
    /// harness twice: a brain that tells the relay the guest's writing, then its failed end, then
    /// throws (the guest's shape), and one that throws with no end told (a brain over the API),
    /// where only the attempt's own order — the failure before the writing is dropped — says so.
    func testASpokenTurnThatFailsMidReplySoundsFailedNotDone() async throws {
        for tellsEnd in [true, false] {
            let rig = await rig(heard: .dataRendered)
            let relay = GuestRelay()
            let brain = StreamingBrain(relay: relay, tellsEnd: tellsEnd) { [speaker = rig.speaker] in
                for _ in 0..<600 where await !speaker.report.started { try? await Task.sleep(for: .milliseconds(10)) }
            }
            let harness = harness(brain: brain, relay: relay)
            let mascot = Mascot(model: "claude-haiku-4-5")
            mascot.follow(harness)
            SpokenReply.follow(harness, speaker: rig.speaker) { true }
            let spoken = harness.willSend("what is the capital of France")
            harness.markSpoken(spoken)
            _ = rig.speaker.awaitReply(spoken, readAloud: true)

            await harness.retry()
            XCTAssertNotNil(harness.error)
            XCTAssertTrue(rig.speaker.report.started, "the reply was not read as it was written")
            try await render(rig, until: "the reply to finish") { rig.speaker.report.finished }
            XCTAssertEqual(rig.earcons.played, [.failed], "end told \(tellsEnd): a reply cut short by its turn's failure sounded done")
            XCTAssertEqual(rig.speaker.awaiting, [])
            XCTAssertTrue(rig.audio.holding, "the cue's hold did not stand once the reply's dropped")
            rig.cues.players.last?.finish()
            XCTAssertFalse(rig.audio.holding)
        }
    }

    /// A reply marked failed and stopped before it drained leaves nothing behind: the next reply,
    /// read to its end, sounds `done`. The mark is the reading's, not the speaker's.
    func testAReplyAfterAFailedOneStoppedMidwayEndsDone() async throws {
        let rig = await rig(heard: .dataRendered)
        // A whole sentence, so the reading begins and the failure marks it.
        rig.speaker.speak(writing: "The lights are on. And", answering: "turn")
        await settle("the failed reply to start") { rig.speaker.report.started }
        rig.speaker.turnFailed("turn")
        rig.speaker.stop()
        XCTAssertEqual(rig.earcons.played, [], "a stop sounded a cue")
        XCTAssertTrue(rig.speaker.speak("The lights are off."))
        try await render(rig, until: "the reply to finish") { rig.speaker.report.finished }
        XCTAssertEqual(rig.earcons.played, [.done], "the reply after a failed one stopped midway did not end done")
    }

    /// A guest that exits before its turn's end is not a failure: the bridge reads its transcript
    /// and a reply found there answers the turn, so the reading-under-way site tells no failure
    /// for that end — only for an error result, the one end nothing is recovered from. Through the
    /// harness: a brain that tells the guest's exit, then answers.
    func testAGuestThatExitsAndIsAnsweredFromItsTranscriptSoundsNoFailure() async {
        let rig = await rig()
        let relay = GuestRelay()
        let harness = harness(brain: ExitedThenAnswered(relay: relay), relay: relay)
        SpokenReply.follow(harness, speaker: rig.speaker) { true }
        let spoken = harness.willSend("what is the capital of France")
        harness.markSpoken(spoken)
        _ = rig.speaker.awaitReply(spoken, readAloud: true)

        await harness.retry()
        XCTAssertNil(harness.error)
        XCTAssertFalse(rig.earcons.played.contains(.failed), "a turn answered from the transcript sounded failed: \(rig.earcons.played)")
        XCTAssertEqual(rig.speaker.awaiting, [])
    }

    /// A failure told twice for one turn with its wait standing — the guest's end and the
    /// attempt's own — sounds `failed` once.
    func testAFailureToldTwiceForOneWaitSoundsFailedOnce() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.speaker.turnFailed("turn")
        rig.speaker.turnFailed("turn")
        XCTAssertEqual(rig.earcons.played, [.failed])
        rig.speaker.endAwaiting("turn", "the turn failed")
        // The next wait for the same nonce is its own: a failure of it sounds again.
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.speaker.turnFailed("turn")
        XCTAssertEqual(rig.earcons.played, [.failed, .failed])
        rig.speaker.endAwaiting("turn", "the test is done")
    }

    /// The microphone opening is what lets the stopped cue's hold go, not the `listening` played
    /// after it: held at the opening alone, with no press to sound anything.
    func testTheMicrophoneOpeningLetsTheStoppedCuesHoldGo() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.failed))
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertTrue(rig.audio.holding, "the cue's hold did not outlast the wait's")
        rig.speaker.microphoneOpening()
        XCTAssertFalse(rig.audio.holding, "the stopped cue's hold outlived it")
        XCTAssertEqual(rig.cues.players.last?.stops, 1)
        rig.speaker.microphoneOpened(counted: true)
    }

    /// The real player's finish ends a play only if the player is silent when it arrives: the
    /// first play ends, the cue begins again on the same player before the first's finish is
    /// posted, and that finish, arriving with the second sounding, ends nothing; the second's own
    /// ends it. Over a player whose sounding the suite states.
    func testAStaleFinishOfTheRealPlayerEndsNothing() async throws {
        let url = try XCTUnwrap(Bundle(for: Earcons.self).url(forResource: "earcon_listening", withExtension: "mp3"))
        let stated = try StatedPlayer(contentsOf: url)
        let player = EarconPlayer(player: stated)
        var first = 0
        var second = 0
        _ = player.play { first += 1 }
        stated.sounding = false
        _ = player.play { second += 1 }
        player.audioPlayerDidFinishPlaying(stated, successfully: true)
        await drain()
        XCTAssertEqual(first, 0, "the first play's finish was delivered to a play started again")
        XCTAssertEqual(second, 0, "the first play's finish ended the second while it sounded")
        stated.sounding = false
        player.audioPlayerDidFinishPlaying(stated, successfully: true)
        await drain()
        XCTAssertEqual(second, 1)
        XCTAssertEqual(first, 0)
    }

    /// A finish arriving with the player silent ends the play standing, once: a second finish
    /// finds nothing to end.
    func testAFinishArrivingOnceThePlayerIsSilentEndsThePlayStanding() async throws {
        let url = try XCTUnwrap(Bundle(for: Earcons.self).url(forResource: "earcon_listening", withExtension: "mp3"))
        let stated = try StatedPlayer(contentsOf: url)
        let player = EarconPlayer(player: stated)
        var ends = 0
        _ = player.play { ends += 1 }
        stated.sounding = false
        player.audioPlayerDidFinishPlaying(stated, successfully: true)
        await drain()
        XCTAssertEqual(ends, 1)
        player.audioPlayerDidFinishPlaying(stated, successfully: true)
        await drain()
        XCTAssertEqual(ends, 1, "a second finish ended the play twice")
    }

    /// A cue still sounding as a press opens the microphone is stopped there, and its hold goes:
    /// `done` is not heard by the microphone, and `listening` is the one that sounds.
    func testACueSoundingAsAPressOpensTheMicrophoneIsStopped() async {
        let rig = await rig()
        let sent = Sent()
        defer { rig.voice.cancel() }
        // A wait standing, as one does under a reply's `sent` and `failed`: the session is live
        // and the cues hold. `sent`, then `failed` over it while it still sounds.
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.sent))
        XCTAssertTrue(rig.earcons.play(.failed))
        XCTAssertEqual(rig.cues.players.map(\.sounding), [true, true])
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertTrue(rig.audio.holding, "the cue's hold did not outlast the wait's")
        await press(rig, true, sent)
        XCTAssertTrue(rig.voice.listening)
        XCTAssertEqual(rig.cues.players.prefix(2).map(\.stops), [1, 1], "a cue sounding went on into the open microphone")
        XCTAssertEqual(rig.earcons.played, [.sent, .failed, .listening])
        let listening = rig.cues.players.last
        XCTAssertEqual(listening?.url.deletingPathExtension().lastPathComponent, "earcon_listening")
        XCTAssertEqual(listening?.stops, 0, "the press stopped its own cue")
        XCTAssertFalse(rig.audio.holding, "the stopped cues' hold outlived them")
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
        // Anything kept that is not true reads as off, as the toggle reads it.
        defaults.set("loud", forKey: EarconsSetting.key)
        XCTAssertFalse(EarconsSetting.enabled(defaults))
    }

    /// Review Focus 11: a cue on a session that is not live is refused, not played, and it
    /// configures nothing to get one: no player is made, no hold is taken, and the session is
    /// left for the next path, which is what activates it. Behind the lock that is the lock
    /// screen's interruption with a claim change deferred under the wait's hold: `failed` for the
    /// turn that then fails applies nothing from the background.
    func testACueOnASessionThatIsNotLiveIsRefusedAndConfiguresNothing() async {
        let rig = await rig(isActive: false)
        rig.audio.wantRecord(true, for: .warm)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        rig.audio.wantRecord(false, for: .warm)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await drain()
        rig.seams.forget()

        rig.speaker.turnFailed("turn")
        XCTAssertEqual(rig.earcons.played, [])
        XCTAssertTrue(rig.cues.players.isEmpty, "a player was made on a session that is not live")
        XCTAssertEqual(rig.seams.lines, [], "a cue configured the session")
        XCTAssertEqual(rig.seams.records, [], "a cue applied a claim change from the background")
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertFalse(rig.audio.holding, "a hold was taken for a cue that was refused")

        // In front, the next path activates the session, and the cue after it is played.
        rig.audio.wantRecord(true, for: .warm)
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
    /// made under it is applied at once rather than kept waiting on the cue. The session is the
    /// foreground's, live by its warm claim; a cue on one nothing has activated is refused.
    func testACueBegunWithNothingHeldHoldsNothing() async {
        let rig = await rig()
        XCTAssertFalse(rig.earcons.play(.sent), "a cue was played on a session nothing had activated")
        rig.audio.wantRecord(true, for: .warm)
        rig.seams.forget()
        XCTAssertTrue(rig.earcons.play(.sent))
        XCTAssertFalse(rig.audio.holding, "a cue held alone")
        rig.audio.wantRecord(false, for: .warm)
        XCTAssertEqual(rig.seams.lines, ["activate ok"], "the claim waited on the cue")
        rig.cues.players.last?.finish()
        XCTAssertFalse(rig.audio.holding)
    }

    /// A cue begun under nothing but the cue before it lets that one's hold go: cues cannot keep
    /// the process alive by themselves, and a claim change made under the second applies at once.
    func testACueUnderNothingButACuesHoldLetsItGo() async {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.failed))
        rig.speaker.endAwaiting("turn", "the turn failed")
        XCTAssertTrue(rig.audio.holding, "the cue's hold went with the wait's")
        XCTAssertFalse(rig.audio.heldForATurn)

        XCTAssertTrue(rig.earcons.play(.listening))
        XCTAssertFalse(rig.audio.holding, "a cue held under nothing but a cue's hold")
        rig.seams.forget()
        rig.audio.wantRecord(true, for: .warm)
        XCTAssertEqual(rig.seams.lines, ["activate ok"], "the claim waited on the cue")
        rig.cues.players[0].finish()
        rig.cues.players[1].finish()
        XCTAssertFalse(rig.audio.holding)
    }

    /// The cue's hold is bounded: a player whose finish never comes is let go of at `Earcons.bound`,
    /// so no hold outlives its cue. A finish after that moves nothing.
    func testTheBoundLetsGoOfAHoldWhosePlayerNeverFinishes() async {
        let clock = CueSleep()
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

    /// The whole of the lock's end, wired as the app wires it (`speaker.onHold` into the call
    /// driver with `heldForATurn`): a reply read behind the lock on the call, then `done` under
    /// it, and the call is ended — the session handed back — only once the cue is heard out and
    /// the route's tail has passed, never at the reply's end or the player's.
    func testTheCallEndsOnlyOnceDoneAndItsTailAreOver() async throws {
        let clock = CueSleep()
        let tail: Duration = .milliseconds(300)
        let rig = await rig(isActive: false, heard: .dataRendered, sleep: { try await clock.sleep($0) }, tail: tail)
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        let driver = SpokenCallDriver(call: call, enabled: { true }, center: NotificationCenter(), initial: .background)
        rig.speaker.onHold = { [audio = rig.audio] in driver.holdChanged($0, forATurn: audio.heldForATurn) }
        defer { withExtendedLifetime(driver) {} }

        XCTAssertTrue(rig.speaker.speak("Hi."))
        await settle("the reply to start") { rig.speaker.report.started }
        XCTAssertEqual(system.starts.count, 1, "the reply's hold behind the lock placed no call")
        try await render(rig, until: "the reply to finish") { rig.speaker.report.finished }
        XCTAssertEqual(rig.earcons.played, [.done])
        XCTAssertEqual(system.ends.count, 0, "the call ended at the reply's end, under its done")

        rig.cues.players.last?.finish()
        await settle("the tail to be asked for") { clock.asked.contains(tail) }
        XCTAssertTrue(rig.audio.holding, "the cue's hold went at the player's finish, before the tail")
        XCTAssertEqual(system.ends.count, 0, "the call ended inside the route's tail")

        clock.fire()
        await settle("the hold to go") { !rig.audio.holding }
        XCTAssertEqual(system.ends.count, 1, "the call outlived the cue and its tail")
    }

    /// A cue the player has finished is still in the route: the hold stands for the route's tail,
    /// so `done` behind the lock is not cut off by the call it ends, and goes when the tail has
    /// passed. A cue begun in the tail keeps the hold, and the first one's tail moves nothing.
    func testTheHoldStandsForTheRoutesTailAfterTheFinish() async {
        let clock = CueSleep()
        let tail = Duration.milliseconds(400)
        let rig = await rig(sleep: { try await clock.sleep($0) }, tail: tail)
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.done))
        rig.speaker.endAwaiting("turn", "the reply was read")
        rig.cues.players.last?.finish()
        await settle("the tail to be asked for") { clock.asked.contains(tail) }
        XCTAssertTrue(rig.audio.holding, "the hold went as the player finished, with the cue still in the route")
        clock.fire(tail)
        await settle("the hold to go after the tail") { !rig.audio.holding }
        await settle("the bound to be cancelled") { clock.cancelled }

        _ = rig.speaker.awaitReply("second", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.failed))
        rig.speaker.endAwaiting("second", "the turn failed")
        rig.cues.players.last?.finish()
        await settle("the first tail") { clock.asked.filter { $0 == tail }.count == 2 }
        // A cue begun inside the first's tail, under the cue's hold alone, lets that hold go
        // (cues hold nothing by themselves), and the first tail ending moves nothing after.
        XCTAssertTrue(rig.earcons.play(.done))
        XCTAssertFalse(rig.audio.holding)
        XCTAssertEqual(rig.earcons.playingForATest, rig.earcons.serialForATest, "the cue begun in the tail is the one playing")
        clock.fire(tail)
        await drain()
        XCTAssertEqual(rig.earcons.playingForATest, rig.earcons.serialForATest, "the first cue's tail ended the one begun in it")
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
    func testAMediaServicesResetDropsThePlayersAndBuildsNothing() async throws {
        let rig = await rig()
        _ = rig.speaker.awaitReply("turn", readAloud: true)
        XCTAssertTrue(rig.earcons.play(.done))
        XCTAssertEqual(rig.cues.files, ["earcon_done"])
        XCTAssertTrue(rig.audio.holding)
        let engines = rig.seams.engines.count
        let transitions = rig.speaker.keeperTransitions.count
        // The reset leaves the engine stopped, as the offline one is not by the notification
        // alone. The wait and the cue's hold both stand: the wait ends under the handler with the
        // cue's hold still there, which re-notifies the hold, and on a stopped engine that is the
        // keeper started again.
        let engine = try XCTUnwrap(rig.seams.engines.last)
        engine.stop()
        let starts = rig.seams.playEngineStarts

        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await drain()
        XCTAssertEqual(rig.cues.files, ["earcon_done"], "a player was built in the reset handler")
        XCTAssertFalse(rig.audio.holding, "the reset left the cue's hold standing")
        XCTAssertEqual(rig.speaker.awaiting, [])
        XCTAssertEqual(rig.seams.engines.count, engines, "an engine was built in the reset handler")
        XCTAssertFalse(rig.speaker.keeperTransitions.dropFirst(transitions).contains("playing"), "the keeper was started in the reset handler: \(rig.speaker.keeperTransitions)")
        XCTAssertEqual(rig.seams.playEngineStarts, starts, "the engine the reset killed was started again")
        XCTAssertFalse(engine.isRunning)
        XCTAssertFalse(rig.speaker.running)

        // The old player is not heard out, and its late finish moves nothing.
        rig.cues.players[0].finish()
        XCTAssertFalse(rig.audio.holding)

        XCTAssertTrue(rig.earcons.play(.done))
        XCTAssertEqual(rig.cues.files, ["earcon_done", "earcon_done"], "the next cue reused a player the reset invalidated")
        XCTAssertEqual(rig.cues.players[1].plays, 1)
    }

    /// A cue at the reset under an active call speaks to no player made before it.
    func testACueAtTheResetUnderAnActiveCallSpeaksToNoPlayerMadeBeforeIt() async {
        let rig = await rig()
        rig.audio.callPlaced()
        rig.audio.callActivated()
        XCTAssertTrue(rig.earcons.play(.sent))
        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        XCTAssertFalse(rig.earcons.play(.sent), "a cue was played on a call's session the reset killed")
        XCTAssertEqual(rig.cues.players[0].plays, 1, "a player made before the reset was spoken to")
        rig.audio.callOver()
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

/// A sleep the test fires, so a bound is a moment the test chooses. A cancellation wakes only
/// the sleep it cancels, as `Task.sleep`'s does, and a sleep is counted in `asked` only once it
/// is waiting, so a test that settles on `asked` and then fires cannot miss it.
final class CueSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(id: Int, duration: Duration, continuation: CheckedContinuation<Void, any Error>)] = []
    private var cancelledEarly: Set<Int> = []
    private var next = 0
    private var _asked: [Duration] = []
    private var _cancelled = false

    var asked: [Duration] { lock.withLock { _asked } }
    var cancelled: Bool { lock.withLock { _cancelled } }

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { () -> Int in next += 1; return next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Cancelled before the sleep began, which a finish straight after the play does:
                // as cancelled as one cut short.
                let early = lock.withLock { () -> Bool in
                    _asked.append(duration)
                    if cancelledEarly.remove(id) != nil || Task.isCancelled { _cancelled = true; return true }
                    waiting.append((id, duration, continuation))
                    return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let mine = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                _cancelled = true
                guard let index = waiting.firstIndex(where: { $0.id == id }) else {
                    cancelledEarly.insert(id)
                    return nil
                }
                return waiting.remove(at: index).continuation
            }
            mine?.resume(throwing: CancellationError())
        }
    }

    func fire() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let all = waiting.map(\.continuation)
            waiting = []
            return all
        }
        all.forEach { $0.resume() }
    }

    /// Wakes only the sleeps asked for `duration`, so a tail is told apart from a bound.
    func fire(_ duration: Duration) {
        let some = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let some = waiting.filter { $0.duration == duration }.map(\.continuation)
            waiting.removeAll { $0.duration == duration }
            return some
        }
        some.forEach { $0.resume() }
    }
}

/// A brain whose turn the guest writes part of a reply to, then ends in a failure: it tells the
/// relay the guest's beginning and its writing, waits for `beforeFailing`, tells its failed end
/// if `tellsEnd`, and then throws as the attempt does.
private struct StreamingBrain: Brain {
    struct Died: Error {}
    let relay: GuestRelay
    var tellsEnd = true
    let beforeFailing: @Sendable () async -> Void

    func answer(_ request: BrainRequest) async throws -> Reply {
        let answering = request.answering.map(\.ref)
        await MainActor.run {
            relay.tell(.began(pid: nil, answering: answering))
            relay.tell(.update(.event(.writingBegan)))
            relay.tell(.update(.event(.writing("Paris is the capital. It is on the Seine and"))))
        }
        await beforeFailing()
        if tellsEnd {
            await MainActor.run { relay.tell(.update(.ended(.failed(.result(StreamingBrain.errorResult))))) }
        }
        throw Died()
    }

    func describe() async -> String { "a brain that dies mid-reply" }

    /// Claude Code's own word that it received the turn and ended it without an answer.
    static let errorResult = StreamEvent.TurnResult(isError: true, subtype: "error_during_execution", text: nil, session: nil, duration: nil)
}

/// A brain whose guest exits before the stream's end, and whose reply is then found in the
/// transcript: the harness's turn is answered, not failed.
private struct ExitedThenAnswered: Brain {
    let relay: GuestRelay

    func answer(_ request: BrainRequest) async throws -> Reply {
        let answering = request.answering.map(\.ref)
        await MainActor.run {
            relay.tell(.began(pid: nil, answering: answering))
            relay.tell(.update(.ended(.failed(.exited("the guest died")))))
        }
        return Reply(text: "Paris.", model: "claude-haiku-4-5", context: 0, outputTokens: 0)
    }

    func describe() async -> String { "a brain whose guest exits and is answered from its transcript" }
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
