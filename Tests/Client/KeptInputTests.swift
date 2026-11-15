import AVFoundation
import XCTest

@testable import Topo

/// The ear's engine, counting every decode: a release's, a glance's, anything the kept input
/// could have reached the recogniser by.
final class CountingEar: SpeechEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let hears: String

    init(hears: String) { self.hears = hears }

    var decodes: Int { lock.withLock { count } }

    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {}
    func rebuild(terms: [String], version: Int) async throws {}
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String {
        lock.withLock { count += 1 }
        return hears
    }
}

/// The conversation's input kept running through a reading (`VoiceInput.inputKept`), Daphne's
/// half-duplex: an utterance's end shuts the gate and leaves the engine running, what it hears
/// reaches nothing, the next utterance opens the gate on the same engine with no session, engine,
/// voice processing or format touched, and the input stops at the conversation's end, a cancel,
/// an interruption's start, a reset and the next press. The session is never reconfigured or
/// handed back under it. Over `MediaServicesResetTests`' seams.
@MainActor
final class KeptInputTests: XCTestCase {
    /// Whether the microphone's engine was running at each thing done to the session: a
    /// configure, a hand-back. Every entry must be false.
    /// Called from the session's seams, which run on the main actor.
    final class Watch: @unchecked Sendable {
        weak var voice: VoiceInput?
        weak var speaker: Speaker?
        private(set) var underInput: [String] = []
        /// What was done to the session while the speaker's keeper was rendering.
        private(set) var underKeeper: [String] = []
        private(set) var atHandBack: [Bool] = []

        func saw(_ what: String) {
            let running = MainActor.assumeIsolated { voice?.inputRunning ?? false }
            if what == "hand-back" { atHandBack.append(running) }
            if running { underInput.append(what) }
            if MainActor.assumeIsolated({ speaker?.keeping ?? false }) { underKeeper.append(what) }
        }
    }

    final class Sent {
        private(set) var texts: [String] = []
        func add(_ text: String) { texts.append(text) }
    }

    @MainActor struct Rig {
        let speaker: Speaker
        let voice: VoiceInput
        let audio: AudioSession
        let seams: Seams
        let center: NotificationCenter
        let ear: CountingEar
        let watch: Watch
        let press = MicPress()
        let sent = Sent()

        func showing() -> Composer.MicState { Composer.MicState(voice, speaking: speaker.speaking) }
    }

    private func defaults() -> UserDefaults {
        let name = "topo.tests.kept.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    /// The keeper's sounds (the bed on) and the earcons on, for the test of sounds under the
    /// kept input; nil in every other rig.
    struct Sounding {
        let sounds: KeeperSounds
        let players: WorkingRecorder
        let cues: CueRecorder
    }

    private func rig(hears: String = "the weather in Bath", isActive: Bool = true,
                     sounding: Bool = false) async -> (Rig, Sounding?) {
        let seams = Seams()
        let center = NotificationCenter()
        let watch = Watch()
        let audio = AudioSession(center: center,
                                 configure: { watch.saw("configure"); try seams.configure($0, $1) },
                                 deactivate: { watch.saw("hand-back"); try seams.deactivate($0) },
                                 isActive: { isActive })
        var made: Sounding?
        var earcons: Earcons?
        if sounding {
            let soundDefaults = defaults()
            soundDefaults.set(WorkingSounds.Mode.sounds.rawValue, forKey: WorkingSounds.key)
            soundDefaults.set(true, forKey: EarconsSetting.key)
            let players = WorkingRecorder()
            let cues = CueRecorder()
            made = Sounding(sounds: KeeperSounds(audio: audio, defaults: soundDefaults, bundle: Bundle(for: KeeperSounds.self),
                                                 makePlayer: { players.make($0) }),
                            players: players, cues: cues)
            earcons = Earcons(audio: audio, defaults: soundDefaults, bundle: Bundle(for: Earcons.self),
                              makePlayer: { cues.make($0) }, tail: { .zero })
        }
        let spoken = Voice(engine: ScriptedVoice())
        spoken.load(folder: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { spoken.state == .ready }
        let speaker = Speaker(audio: audio, voice: spoken, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) },
                              sounds: made?.sounds, earcons: earcons)
        let engine = CountingEar(hears: hears)
        let ear = Ear(vocabulary: Vocabulary(defaults: defaults()), engine: engine)
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear to load") { ear.ready }
        let voice = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) },
                               permission: { true }, permitted: { true },
                               voiceProcessing: { try seams.process($0, $1) },
                               defaults: defaults())
        watch.voice = voice
        watch.speaker = speaker
        speaker.microphoneOpen = { voice.busy }
        return (Rig(speaker: speaker, voice: voice, audio: audio, seams: seams, center: center, ear: engine,
                    watch: watch), made)
    }

    /// One utterance of the conversation's, as `Conversation` takes it: the microphone opened
    /// with no thumb (`reopen`), a second and a half of tone heard, the utterance ended keeping
    /// the input (`endUtterance`), and the turn's wait taken as the send takes it.
    @discardableResult
    private func converse(_ rig: Rig, waits: String? = "a-turn") async -> String {
        let opened = await rig.voice.reopen(as: .chat)
        XCTAssertTrue(opened, "the conversation's microphone did not open: \(rig.voice.refusal ?? "")")
        utterance(into: rig.voice.sink)
        let heard = await rig.voice.end(as: .chat, keepingInput: true)
        if !heard.isEmpty {
            rig.sent.add(heard)
            if let waits { _ = rig.speaker.awaitReply(waits, readAloud: true) }
        }
        return heard
    }

    /// The thumb down and up on the microphone through the chat's routing, held past a tap.
    private func say(_ rig: Rig) async {
        await rig.press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
                                speaks: true) { _ in }?.value
        XCTAssertTrue(rig.voice.listening, "the press opened the microphone")
        utterance(into: rig.voice.sink)
        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        await rig.press.gesture(false, held: true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
                                speaks: true) { text in
            guard !text.isEmpty else { return }
            rig.sent.add(text)
            _ = rig.speaker.awaitReply("a-turn", readAloud: true)
        }?.value
    }

    private func utterance(into sink: SampleSink) {
        let format = sink.format
        let frames = AVAudioFrameCount(format.sampleRate * 1.5)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData else { return XCTFail("no buffer at the ear's rate") }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { channel[0][frame] = 0.1 * Float(sin(Double(frame) * 0.05)) }
        sink.append(buffer)
    }

    /// The audio thread handing the installed tap a tenth of a second of tone, in the format the
    /// tap was installed with.
    private func feedTheTap() {
        guard let tap = CapturingInputNode.tap, let format = CapturingInputNode.installed,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate / 10)),
              let channel = buffer.floatChannelData else { return XCTFail("no tap to feed") }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { channel[0][frame] = 0.2 * Float(sin(Double(frame) * 0.07)) }
        tap(buffer, AVAudioTime(sampleTime: 0, atRate: format.sampleRate))
    }

    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    // MARK: Nothing the kept input hears reaches anything

    /// The take the working bed waits for (`VoiceInput.onTaken`) is told with the kept input's
    /// gate already shut, so the bed's onset reaches no sink.
    func testTheTakeIsToldWithTheKeptInputsGateShut() async {
        let (rig, _) = await rig()
        var atTake: (kept: Bool, passes: Bool)?
        rig.voice.onTaken = {
            var passes = false
            rig.voice.gate.pass { passes = true }
            atTake = (rig.voice.inputKept, passes)
        }
        await converse(rig, waits: nil)
        XCTAssertEqual(atTake?.kept, true, "the take was told before the input was kept, or not at all")
        XCTAssertEqual(atTake?.passes, false, "the kept input's gate was open at the take")
        rig.voice.cancel()
    }

    func testWhatTheKeptInputHearsReachesNoTurnCaptionOrRecogniser() async {
        let (rig, _) = await rig()
        let opened = await rig.voice.reopen(as: .chat)
        XCTAssertTrue(opened)
        // The tap this test feeds is the one that fills the sink while the microphone is open.
        feedTheTap()
        XCTAssertFalse(rig.voice.sink.peek().isEmpty, "the tap fed the sink while the microphone listened")
        utterance(into: rig.voice.sink)
        let heard = await rig.voice.end(as: .chat, keepingInput: true)
        XCTAssertEqual(heard, "the weather in Bath")
        XCTAssertTrue(rig.voice.inputKept)
        XCTAssertTrue(rig.voice.inputRunning, "the utterance's engine runs on")
        XCTAssertFalse(rig.voice.listening, "not the microphone left open: a reply is not held for it")
        XCTAssertFalse(rig.voice.busy, "a reply would wait for a microphone nobody is speaking into")
        let decodes = rig.ear.decodes
        for _ in 0..<30 { feedTheTap() }
        XCTAssertTrue(rig.voice.sink.peek().isEmpty, "nothing the kept input hears reaches the sink")
        // Past a caption glance's period, which would decode whatever reached the sink.
        try? await Task.sleep(for: VoiceInput.glanceEvery + .milliseconds(400))
        XCTAssertEqual(rig.voice.text, "", "no caption")
        XCTAssertEqual(rig.ear.decodes, decodes, "the recogniser heard nothing more")
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        rig.voice.cancel()
    }

    /// A reply is read with the input kept: the input runs through the reading, its gate shut,
    /// and nothing is done to the session under it.
    func testAReplyIsReadOverTheKeptInputWithNothingReconfigured() async {
        let (rig, _) = await rig()
        await converse(rig)
        XCTAssertTrue(rig.voice.inputKept)
        XCTAssertTrue(rig.speaker.speak("It is warmer in Bristol.", answering: "a-turn"))
        await settle("the reply to start") { rig.speaker.report.started }
        XCTAssertTrue(rig.voice.inputKept, "the reading stopped the conversation's input")
        XCTAssertTrue(rig.voice.inputRunning)
        for _ in 0..<10 { feedTheTap() }
        XCTAssertTrue(rig.voice.sink.peek().isEmpty, "the reading reached the sink through the kept tap")
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        rig.speaker.stop()
        rig.voice.cancel()
    }

    // MARK: The next utterance opens on the engine that never stopped

    /// Behind the lock, where an input started is one started from the background: the next
    /// utterance opens the gate on the kept engine, with no configure, no engine made, no voice
    /// processing set and no format read, and an empty sink.
    func testTheNextUtteranceOpensOnTheKeptEngineTouchingNoSession() async {
        let (rig, _) = await rig(isActive: false)
        await converse(rig, waits: nil)
        XCTAssertTrue(rig.voice.inputKept)
        let engines = rig.seams.inputEngines
        let reads = rig.seams.formatReads
        let processing = rig.seams.processing.count
        rig.seams.forget()
        for _ in 0..<5 { feedTheTap() }

        let opened = await rig.voice.reopen(as: .chat)
        XCTAssertTrue(opened, "the kept input was not taken: \(rig.voice.refusal ?? "")")
        XCTAssertTrue(rig.voice.listening)
        XCTAssertTrue(rig.voice.handsFree)
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertTrue(rig.voice.sink.peek().isEmpty, "what the kept input heard is in the next utterance")
        XCTAssertEqual(rig.seams.lines, [], "the session was touched to reopen on the kept input")
        XCTAssertEqual(rig.seams.inputEngines, engines, "an engine was made for the reopen")
        XCTAssertEqual(rig.seams.formatReads, reads, "the formats were read again")
        XCTAssertEqual(rig.seams.processing.count, processing, "voice processing was set again")
        feedTheTap()
        XCTAssertFalse(rig.voice.sink.peek().isEmpty, "the reopened gate passes nothing")
        XCTAssertEqual(rig.watch.atHandBack, [], "the session was handed back between the two utterances")
        rig.voice.cancel()
    }

    /// A session no longer live (an interruption standing) refuses the reopen on the kept input,
    /// and the input stays kept for the conversation to end or reopen.
    func testAReopenOnTheKeptInputIsRefusedWithNoLiveSession() async {
        let (rig, _) = await rig(isActive: false)
        await converse(rig, waits: nil)
        let opened = await rig.voice.reopen(as: .chat, live: { false })
        XCTAssertFalse(opened)
        XCTAssertEqual(rig.voice.refusal, "no live session")
        XCTAssertFalse(rig.voice.listening)
        XCTAssertTrue(rig.voice.inputKept)
        rig.voice.cancel()
    }

    /// The chat's cancels (the keyboard up, a typed send, the chat going), scoped to the chat's
    /// gate though its session has ended, stop the kept input; another gate's cancel leaves it.
    func testAnotherGatesCancelLeavesTheKeptInput() async {
        let (rig, _) = await rig()
        await converse(rig, waits: nil)
        rig.voice.cancel(.firstRun)
        XCTAssertTrue(rig.voice.inputKept, "another gate's cancel stopped the chat's kept input")
        rig.voice.cancel(.chat)
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertFalse(rig.voice.inputRunning)
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
    }

    // MARK: The kept input holds the session, and outlives none of its ends

    /// Away, the turn's hold going leaves the kept input holding the session: nothing is handed
    /// back under it. Its stop at the conversation's end hands the session back, once, with the
    /// input stopped.
    func testTheKeptInputHoldsTheSessionAwayAndItsStopHandsItBack() async {
        let (rig, _) = await rig(isActive: false)
        await converse(rig)
        rig.speaker.endAwaiting("a-turn", "the test's turn is over")
        XCTAssertFalse(rig.audio.holding)
        XCTAssertTrue(rig.voice.inputKept, "the turn's end stopped the conversation's input")
        XCTAssertEqual(rig.watch.atHandBack, [], "the session was handed back under the kept input")
        rig.voice.stopKeptInput("the conversation ended")
        XCTAssertFalse(rig.voice.inputRunning)
        XCTAssertEqual(rig.watch.atHandBack, [false], "handed back other than once with the input stopped")
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        XCTAssertTrue(rig.watch.underKeeper.isEmpty, "\(rig.watch.underKeeper)")
        rig.speaker.stop()
    }

    /// In front, a claim change made under the kept input waits for its stop, and is applied
    /// there with the input already stopped: the session is reactivated for what is claimed, and
    /// nothing is reconfigured under the running input before the stop.
    func testInFrontTheKeptInputsStopAppliesTheClaimWithTheInputStopped() async {
        let (rig, _) = await rig()
        await converse(rig)
        rig.audio.wantRecord(false, for: .warm)
        rig.speaker.endAwaiting("a-turn", "the test's turn is over")
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        rig.seams.forget()
        rig.voice.stopKeptInput("the conversation ended")
        XCTAssertEqual(rig.watch.atHandBack, [false], "the claim was not applied once with the input stopped")
        XCTAssertEqual(rig.seams.lines.last, "activate ok", "in front the session was left handed back")
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        rig.speaker.stop()
    }

    /// A press's release keeps no input: only a conversation's utterance asks for it.
    func testAPressesReleaseKeepsNoInput() async {
        let (rig, _) = await rig()
        await say(rig)
        XCTAssertEqual(rig.sent.texts, ["the weather in Bath"])
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertFalse(rig.voice.inputRunning)
        rig.speaker.stop()
    }

    /// An utterance that heard nothing keeps its input as one that heard words: the conversation
    /// goes on listening.
    func testAnUtteranceThatHeardNothingStillKeepsItsInput() async {
        let (rig, _) = await rig(hears: "")
        let heard = await converse(rig)
        XCTAssertEqual(heard, "")
        XCTAssertTrue(rig.voice.inputKept)
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        rig.voice.cancel()
    }

    /// The interruption's start stops the input and hands nothing back: the session is the
    /// interruption's.
    func testTheKeptInputStopsAtAnInterruptionsStartAndNothingIsHandedBack() async {
        let (rig, _) = await rig(isActive: false)
        await converse(rig)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await settle("the input stopped") { !rig.voice.inputKept }
        XCTAssertFalse(rig.voice.inputRunning)
        XCTAssertEqual(rig.watch.atHandBack, [], "the session was handed back under the interruption")
        rig.speaker.stop()
    }

    /// A media services reset while the input is kept stops it and builds nothing in the handler.
    func testAResetWhileKeptStopsTheInputAndBuildsNothing() async {
        let (rig, _) = await rig(isActive: false)
        await converse(rig)
        let engines = rig.seams.engines.count
        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await settle("the input stopped") { !rig.voice.inputKept }
        XCTAssertFalse(rig.voice.inputRunning)
        XCTAssertEqual(rig.seams.engines.count, engines, "nothing is built in the handler")
        rig.speaker.stop()
    }

    /// The next press opens the kept engine as its own: stopped first, so voice processing is
    /// set on an engine that is not running.
    func testTheNextPressStopsTheKeptInputBeforeItOpens() async {
        let (rig, _) = await rig()
        await converse(rig)
        XCTAssertTrue(rig.voice.inputKept)
        await rig.press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
                                speaks: true) { _ in }?.value
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertTrue(rig.voice.listening)
        XCTAssertEqual(rig.seams.processing.last?.running, false)
        XCTAssertEqual(rig.seams.inputEngines, 1, "the kept engine is the next press's")
        rig.voice.cancel()
        rig.speaker.stop()
    }
}

// MARK: - The keeper's sounds under the kept input

extension KeptInputTests {
    /// Receipts, the bed, the queue's bleep, an error and the earcons all sound while the input is
    /// kept: none reaches the sink, and none reconfigures or hands back the session under the
    /// running input, the turn's hold going and the sounds' holds after it included.
    func testSoundsUnderTheKeptInputReachNothingAndChangeNoSession() async throws {
        for away in [false, true] {
            let (rig, made) = await rig(isActive: !away, sounding: true)
            let sounding = try XCTUnwrap(made)
            await converse(rig)
            XCTAssertTrue(rig.voice.inputKept, "away \(away)")
            XCTAssertTrue(sounding.players.bed?.isPlaying == true, "away \(away): the bed fades in under the kept input")
            XCTAssertTrue(sounding.sounds.tool("Read"))
            XCTAssertTrue(sounding.sounds.tool("Bash"))
            XCTAssertTrue(sounding.sounds.queued())
            sounding.sounds.result(isError: true)
            XCTAssertEqual(sounding.sounds.played, [.read, .act, .queue, .error], "away \(away)")
            for _ in 0..<20 { feedTheTap() }
            XCTAssertTrue(rig.voice.sink.peek().isEmpty, "away \(away): a tone reached the sink through the kept tap")
            rig.speaker.endAwaiting("a-turn", "the test's turn is over")
            await settle("the sounds' holds let go") { !rig.audio.holding }
            XCTAssertTrue(rig.voice.inputKept, "away \(away): the sounds' end stopped the conversation's input")
            XCTAssertEqual(rig.watch.atHandBack, [], "away \(away): handed back under the kept input")
            XCTAssertTrue(rig.watch.underInput.isEmpty, "away \(away): \(rig.watch.underInput)")
            XCTAssertTrue(rig.watch.underKeeper.isEmpty, "away \(away), the keeper still rendering: \(rig.watch.underKeeper)")
            rig.voice.stopKeptInput("the conversation ended")
            if away { XCTAssertEqual(rig.watch.atHandBack, [false], "away: handed back once, with the input stopped") }
            rig.speaker.stop()
        }
    }
}
