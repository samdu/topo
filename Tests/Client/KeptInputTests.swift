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

/// The input kept running past a spoken release, so the app is recording when a lock straight
/// after the press places the call (`VoiceInput.inputKept`): what it hears reaches nothing, it
/// stops before the call's placing reconfigures the session and at every other end, and the
/// session is never reconfigured or handed back under it. Over `MediaServicesResetTests`' seams,
/// with the chat's own routing (`MicPress`) for the press and a fake call system for the call.
@MainActor
final class KeptInputTests: XCTestCase {
    /// Whether the microphone's engine was running at each thing done to the session: a
    /// configure, the call's category, a hand-back. Every entry must be false.
    /// Called from the session's seams, which run on the main actor.
    final class Watch: @unchecked Sendable {
        weak var voice: VoiceInput?
        private(set) var underInput: [String] = []
        private(set) var atCategory: [Bool] = []
        private(set) var atHandBack: [Bool] = []

        func saw(_ what: String) {
            let running = MainActor.assumeIsolated { voice?.inputRunning ?? false }
            if what == "category" { atCategory.append(running) }
            if what == "hand-back" { atHandBack.append(running) }
            if running { underInput.append(what) }
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

    private func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<6_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited a minute for \(what)", file: file, line: line)
    }

    private func defaults() -> UserDefaults {
        let name = "topo.tests.kept.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func rig(hears: String = "the weather in Bath", isActive: Bool = true) async -> Rig {
        let seams = Seams()
        let center = NotificationCenter()
        let watch = Watch()
        let audio = AudioSession(center: center,
                                 configure: { watch.saw("configure"); try seams.configure($0, $1) },
                                 setCategory: { watch.saw("category"); try seams.setCategory($0, $1) },
                                 deactivate: { watch.saw("hand-back"); try seams.deactivate($0) },
                                 isActive: { isActive })
        let spoken = Voice(engine: ScriptedVoice())
        spoken.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { spoken.state == .ready }
        let speaker = Speaker(audio: audio, voice: spoken, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) })
        let engine = CountingEar(hears: hears)
        let ear = Ear(vocabulary: Vocabulary(defaults: defaults()), engine: engine)
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear to load") { ear.ready }
        let voice = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) },
                               permission: { true },
                               voiceProcessing: { try seams.process($0, $1) },
                               defaults: defaults())
        watch.voice = voice
        speaker.microphoneOpen = { voice.listening }
        speaker.onCall = { voice.call($0) }
        return Rig(speaker: speaker, voice: voice, audio: audio, seams: seams, center: center, ear: engine,
                   watch: watch)
    }

    /// The thumb down and up on the microphone through the chat's routing, a second and a half
    /// of tone heard between, the release's words sent and their turn's wait taken as the chat's
    /// send takes it.
    private func say(_ rig: Rig, dictating: Bool = false, calls: Bool = true, waits: String? = "a-turn") async {
        let speaks = !dictating
        await rig.press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
                                dictating: dictating, speaks: speaks, calls: { calls }) { _ in }?.value
        XCTAssertTrue(rig.voice.listening, "the press opened the microphone")
        utterance(into: rig.voice.sink)
        await rig.press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
                                dictating: dictating, speaks: speaks, calls: { calls }) { text in
            rig.sent.add(text)
            if let waits { _ = rig.speaker.awaitReply(waits, readAloud: true) }
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

    // MARK: Review Focus 1: nothing the kept input hears reaches anything

    func testWhatTheKeptInputHearsReachesNoTurnCaptionOrRecogniser() async {
        let rig = await rig()
        await rig.press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
                                speaks: true, calls: { true }) { _ in }?.value
        // The tap this test feeds is the one that fills the sink while the microphone is open.
        feedTheTap()
        XCTAssertFalse(rig.voice.sink.peek().isEmpty, "the tap fed the sink while the press listened")
        utterance(into: rig.voice.sink)
        await rig.press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
                                speaks: true, calls: { true }) { text in
            rig.sent.add(text)
            _ = rig.speaker.awaitReply("a-turn", readAloud: true)
        }?.value
        XCTAssertEqual(rig.sent.texts, ["the weather in Bath"])
        XCTAssertTrue(rig.voice.inputKept)
        XCTAssertTrue(rig.voice.inputRunning, "the release's engine runs on")
        XCTAssertFalse(rig.voice.listening, "not the microphone left open: a reply is not held for it")
        let decodes = rig.ear.decodes
        for _ in 0..<30 { feedTheTap() }
        XCTAssertTrue(rig.voice.sink.peek().isEmpty, "nothing the kept input hears reaches the sink")
        // Past a caption glance's period, which would decode whatever reached the sink.
        try? await Task.sleep(for: VoiceInput.glanceEvery + .milliseconds(400))
        XCTAssertEqual(rig.voice.text, "", "no caption")
        XCTAssertEqual(rig.ear.decodes, decodes, "the recogniser heard nothing more")
        XCTAssertEqual(rig.sent.texts.count, 1, "nothing more was sent")
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        rig.voice.cancel()
        rig.speaker.stop()
    }

    func testADictatedReleaseKeepsNoInput() async {
        let rig = await rig()
        await say(rig, dictating: true, waits: nil)
        XCTAssertEqual(rig.sent.texts, ["the weather in Bath"], "written into the row by the chat")
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertFalse(rig.voice.inputRunning)
    }

    // MARK: Review Focus 2: the kept input outlives none of its ends

    func testWithTheSettingOffNoInputIsKept() async {
        let rig = await rig()
        await say(rig, calls: false)
        XCTAssertEqual(rig.sent.texts.count, 1)
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertFalse(rig.voice.inputRunning)
        rig.speaker.stop()
    }

    func testAReleaseThatSendsNothingKeepsNoInput() async {
        let rig = await rig(hears: "")
        await say(rig)
        XCTAssertEqual(rig.sent.texts, [], "nothing heard, nothing sent")
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertFalse(rig.voice.inputRunning)
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
    }

    /// The input runs while the start is asked for and judged, and is stopped as the system
    /// performs it, before `callPlaced` sets the call's category.
    func testTheKeptInputStopsBeforeThePlacingSetsTheCategory() async {
        let rig = await rig(isActive: false)
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        rig.speaker.attach(call)
        rig.speaker.onCall = { rig.voice.call($0) }
        await say(rig)
        XCTAssertTrue(rig.voice.inputRunning)
        call.start()
        XCTAssertEqual(system.starts.count, 1)
        XCTAssertTrue(rig.voice.inputRunning, "running while the call service judges the start")
        call.provider(system.provider, perform: system.starts.last!)
        XCTAssertEqual(rig.watch.atCategory, [false], "not running when callPlaced sets the category")
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertEqual(rig.audio.call, .placed)
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        call.end()
        rig.speaker.stop()
    }

    /// A refused placing is tried again with the input still running, and the input stops when
    /// the call fails for good.
    func testTheKeptInputRunsThroughTheRetriesAndStopsWhenTheCallFails() async {
        let rig = await rig(isActive: false)
        let system = FakeCallSystem()
        let sleep = ManualSleep()
        let call = SpokenCall(system: system, sleep: sleep.sleep)
        rig.speaker.attach(call)
        rig.speaker.onCall = { rig.voice.call($0) }
        await say(rig)
        call.start()
        for attempt in 1...SpokenCall.placeAttempts {
            XCTAssertTrue(rig.voice.inputRunning, "running at attempt \(attempt)")
            system.answer(system.requests.count - 1, FakeCallSystem.Refused())
            if attempt < SpokenCall.placeAttempts {
                await settle("the retry's wait") { sleep.waiting >= 1 }
                // The activation grace sleeps first; the retry is the newest sleep.
                while sleep.waiting > 0, system.starts.count == attempt { sleep.fire(); await Task.yield() }
                await settle("attempt \(attempt + 1)") { system.starts.count == attempt + 1 }
            }
        }
        await settle("the input stopped") { !rig.voice.inputKept }
        XCTAssertFalse(rig.voice.inputRunning)
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        rig.speaker.stop()
    }

    func testTheKeptInputStopsAtItsBound() async {
        let rig = await rig()
        let bound = ManualSleep()
        rig.voice.keptSleep = bound.sleep
        await say(rig)
        XCTAssertTrue(rig.voice.inputKept)
        await settle("the bound's wait") { bound.waiting == 1 }
        XCTAssertEqual(bound.asked, [VoiceInput.keptFor])
        bound.fire()
        await settle("the input stopped") { !rig.voice.inputKept }
        XCTAssertFalse(rig.voice.inputRunning)
        rig.speaker.stop()
    }

    func testTheKeptInputStopsAtAnInterruptionsStart() async {
        let rig = await rig()
        await say(rig)
        XCTAssertTrue(rig.voice.inputKept)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await settle("the input stopped") { !rig.voice.inputKept }
        XCTAssertFalse(rig.voice.inputRunning)
        rig.speaker.stop()
    }

    /// With no turn held there is no call to place: the input stops as the last turn's hold
    /// goes, before the session is handed back, away, or reconfigured, in front.
    func testTheKeptInputStopsBeforeTheLastTurnsHoldLetsTheSessionGo() async {
        for away in [true, false] {
            let rig = await rig(isActive: !away)
            await say(rig)
            XCTAssertTrue(rig.voice.inputKept)
            rig.audio.wantRecord(false, for: .warm)
            rig.speaker.endAwaiting("a-turn", "the test's turn is over")
            XCTAssertFalse(rig.voice.inputKept, "away \(away)")
            XCTAssertFalse(rig.voice.inputRunning, "away \(away)")
            if away { XCTAssertEqual(rig.watch.atHandBack, [false], "handed back with the input stopped") }
            XCTAssertTrue(rig.watch.underInput.isEmpty, "away \(away): \(rig.watch.underInput)")
            rig.speaker.stop()
        }
    }

    /// The input's voice unit ducks every other sound on the phone: it stops as the reply begins
    /// to be read, and nothing is reconfigured under it.
    func testTheKeptInputStopsAsTheReplyBeginsToBeRead() async {
        let rig = await rig()
        await say(rig)
        XCTAssertTrue(rig.voice.inputKept)
        XCTAssertTrue(rig.speaker.speak("It is warmer in Bristol.", answering: "a-turn"))
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertFalse(rig.voice.inputRunning)
        XCTAssertTrue(rig.watch.underInput.isEmpty, "\(rig.watch.underInput)")
        rig.speaker.stop()
    }

    /// The next press opens the kept engine as its own: stopped first, so voice processing is
    /// set on an engine that is not running.
    func testTheNextPressStopsTheKeptInputBeforeItOpens() async {
        let rig = await rig()
        await say(rig)
        XCTAssertTrue(rig.voice.inputKept)
        await rig.press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice,
                                speaks: true, calls: { true }) { _ in }?.value
        XCTAssertFalse(rig.voice.inputKept)
        XCTAssertTrue(rig.voice.listening)
        XCTAssertEqual(rig.seams.processing.last?.running, false)
        XCTAssertEqual(rig.seams.inputEngines, 1, "the kept engine is the next press's")
        rig.voice.cancel()
        rig.speaker.stop()
    }

    // MARK: Review Focus 3: the reset and the call

    /// A media services reset while the input is kept stops it and builds nothing in the
    /// handler, and leaves the call being asked for where it was.
    func testAResetWhileKeptStopsTheInputBuildsNothingAndLeavesTheCall() async {
        let rig = await rig(isActive: false)
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        rig.speaker.attach(call)
        rig.speaker.onCall = { rig.voice.call($0) }
        await say(rig)
        call.start()
        let engines = rig.seams.engines.count
        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        await settle("the input stopped") { !rig.voice.inputKept }
        XCTAssertFalse(rig.voice.inputRunning)
        XCTAssertEqual(rig.seams.engines.count, engines, "nothing is built in the handler")
        XCTAssertEqual(call.state, .starting, "the call's placing is untouched")
        XCTAssertEqual(rig.audio.call, .none)
        call.end()
        rig.speaker.stop()
    }
}
