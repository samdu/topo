import AVFoundation
import SwiftUI
import UIKit
import XCTest

@testable import Topo

/// What the detector says, scripted by the chunk: the nth chunk fed answers `events[n]`.
final class ScriptedDetector: VoiceDetector, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Int: Endpoint.Event]
    private var fed = 0
    private(set) var resets = 0
    private var silenced: [TimeInterval] = []

    init(_ events: [Int: Endpoint.Event] = [:]) { self.events = events }

    func script(_ events: [Int: Endpoint.Event]) { lock.withLock { self.events = events } }
    var chunks: Int { lock.withLock { fed } }
    /// The silence each stream was reset with.
    var silences: [TimeInterval] { lock.withLock { silenced } }

    func reset(silence: TimeInterval) async { lock.withLock { resets += 1; fed = 0; silenced.append(silence) } }

    /// The chunk whose verdict waits for `release`, and the wait itself.
    private var holdAt: Int?
    private var held: CheckedContinuation<Void, Never>?
    func hold(at chunk: Int) { lock.withLock { holdAt = chunk } }
    /// No chunk after this one waits; the one waiting still does, until `release`.
    func holdNoMore() { lock.withLock { holdAt = nil } }
    var holding: Bool { lock.withLock { held != nil } }
    func release() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holdAt = nil
            defer { held = nil }
            return held
        }
        waiting?.resume()
    }

    /// The first chunk every feed from on throws at.
    private var failFrom: Int?
    func fail(from chunk: Int) { lock.withLock { failFrom = chunk } }
    struct Failed: Error {}

    func feed(_ chunk: [Float]) async throws -> Endpoint.Event? {
        let (event, waits, fails) = lock.withLock { () -> (Endpoint.Event?, Bool, Bool) in
            defer { fed += 1 }
            return (events[fed], holdAt == fed, failFrom.map { fed >= $0 } ?? false)
        }
        if fails { throw Failed() }
        if waits {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { held = continuation }
            }
        }
        return event
    }
}

/// The microphone permission's answer, held while armed so a test can land something while a
/// press waits on it.
@MainActor
final class PermissionGate {
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    func arm() { armed = true }
    var waiting: Bool { held != nil }
    func release() {
        armed = false
        let waiting = held
        held = nil
        waiting?.resume()
    }
    func ask() async -> Bool {
        if armed { await withCheckedContinuation { held = $0 } }
        return true
    }
}

/// An ear whose decodes wait while the gate is shut, so a test can land something mid-decode.
final class GatedEngine: SpeechEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var shut = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    let heard: String
    init(_ heard: String) { self.heard = heard }

    func close() { lock.withLock { shut = true } }
    func open() {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            shut = false
            defer { waiting = [] }
            return waiting
        }
        woken.forEach { $0.resume() }
    }
    var held: Int { lock.withLock { waiting.count } }

    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {}
    func rebuild(terms: [String], version: Int) async throws {}
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = lock.withLock { () -> Bool in
                if shut { waiting.append(continuation); return false }
                return true
            }
            if go { continuation.resume() }
        }
        return heard
    }
}

/// An open microphone behind the lock is a call (`Conversation`): which sessions are carried, an
/// utterance the detector ends sent once, the microphone suspended across the call's session
/// changing hands, and every way the conversation ends telling the resident's lifecycle once.
/// A real `VoiceInput` and `Speaker` on the audio seams, a scripted detector, a manual idle clock.
@MainActor
final class ConversationTests: XCTestCase {
    private var active = false
    private var enabled = true
    private var holding = false
    private var sent: [String] = []
    /// The tones played by the time of each send.
    private var tonesAtSend: [[KeeperSounds.Tone]] = []
    /// Whether the chat's send takes the turn's wait, as `ChatView.sendSpoken` does.
    private var waitOnSend = false
    private var told: [Bool] = []
    private var ends = 0
    private var idle = ManualSleep()
    private var center = NotificationCenter()
    private var other = false
    private var audio: AudioSession!
    private var gate = GatedEngine("turn the lights off")
    private var seams: Seams!
    private var permission = PermissionGate()
    private var spoken = HeldVoice()
    private var sounds: KeeperSounds?
    private var tones = WorkingRecorder()
    private var cues = CueRecorder()

    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    private func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited ten seconds for \(what)", file: file, line: line)
    }

    private func drain() async { try? await Task.sleep(for: .milliseconds(300)) }

    /// The app's wiring over the seams: the speaker tells the conversation the call's moments,
    /// the microphone asks it at an interruption, and the chat's send is installed.
    private func make(detector: ScriptedDetector = ScriptedDetector(), endpoint: Endpoint? = nil, judge: ScriptedJudge? = nil,
                      sends: Bool = true, deafAfter: TimeInterval = 3_600,
                      sounding: Bool = false,
                      feedSleep: (@Sendable (Duration) async throws -> Void)? = nil) async -> (Conversation, VoiceInput, Speaker) {
        let seams = Seams()
        self.seams = seams
        let permission = permission
        let audio = AudioSession(center: center, configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true })
        self.audio = audio
        let spoken = HeldVoice()
        self.spoken = spoken
        let voice = Voice(engine: spoken)
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        // The keeper's sounds and the cues, on players of the suite's, when a test asks for them.
        var earcons: Earcons?
        if sounding {
            let name = "topo.tests.conversation.\(UUID().uuidString)"
            addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
            let defaults = UserDefaults(suiteName: name)!
            defaults.set(true, forKey: EarconsSetting.key)
            let tones = tones, cues = cues
            sounds = KeeperSounds(audio: audio, defaults: defaults, bundle: Bundle(for: KeeperSounds.self),
                                  makePlayer: { tones.make($0) })
            earcons = Earcons(audio: audio, defaults: defaults, bundle: Bundle(for: Earcons.self),
                              makePlayer: { cues.make($0) }, tail: { .zero })
        }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) },
                              sounds: sounds, earcons: earcons)
        let ear = Ear(vocabulary: Vocabulary(defaults: UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!),
                      engine: gate)
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear to load") { ear.ready }
        let input = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) },
                               permission: { await permission.ask() }, permitted: { true },
                               voiceProcessing: { try seams.process($0, $1) })
        speaker.microphoneOpen = { input.listening }
        MicrophoneWatch.start(input, speaker)
        let conversation = Conversation(voice: input, speaker: speaker, endpoint: endpoint ?? Endpoint(detector: detector, judge: judge),
                                        enabled: { [unowned self] in enabled },
                                        appActive: { [unowned self] in active },
                                        holding: { [unowned self] in holding },
                                        otherCall: { [unowned self] in other },
                                        deafAfter: deafAfter, wait: { 1.2 },
                                        center: center, sleep: idle.sleep)
        speaker.onCall = { conversation.call($0) }
        conversation.conversingChanged = { [unowned self] in told.append($0) }
        conversation.ended = { [unowned self] in ends += 1 }
        conversation.send = { [unowned self] in
            sent.append($0)
            tonesAtSend.append(sounds?.played ?? [])
            if waitOnSend { _ = speaker.awaitReply("spoken-\(sent.count)", readAloud: true) }
        }
        conversation.sends = { sends }
        if let feedSleep { conversation.feedSleep = feedSleep }
        input.carries = { [weak conversation] in
            guard let conversation else { return false }
            guard conversation.carries() else {
                if conversation.inFront { conversation.stop("an interruption in front", sending: false, keepingDecode: true) }
                return false
            }
            conversation.noteInterruption()
            return true
        }
        return (conversation, input, speaker)
    }

    /// A tap: the microphone open hands-free for the chat, as the glass leaves it.
    private func tap(_ voice: VoiceInput) async {
        _ = await voice.pressDown(as: .chat)
        _ = await voice.pressUp(as: .chat)
        XCTAssertTrue(voice.listening && voice.handsFree, "the tap did not leave the microphone open hands-free")
    }

    /// A second and a half of tone at the ear's rate, as the tap would have delivered it: six chunks.
    private func utterance(into sink: SampleSink, seconds: Double = 1.5) {
        let format = sink.format
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData else { return XCTFail("no buffer at the ear's rate") }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { channel[0][frame] = 0.1 * Float(sin(Double(frame) * 0.05)) }
        sink.append(buffer)
    }

    /// The call's placing and activation, as the speaker tells them, with the session's phase
    /// moved as `Speaker.attach` moves it.
    private func placeAndActivate(_ conversation: Conversation) {
        audio.callPlaced()
        conversation.call(.placing)
        audio.callActivated()
        conversation.call(.active)
    }

    private func beganInterruption() {
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
    }

    private func leave() {
        active = false
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    }

    // MARK: - What is carried

    func testOnlyAHandsFreeSpokenTurnLeavingTheFrontWithEverythingReadyIsCarried() async {
        let (conversation, voice, _) = await make()
        defer { voice.cancel() }
        XCTAssertFalse(conversation.carries(), "a closed microphone was carried")
        await tap(voice)
        active = true
        XCTAssertFalse(conversation.carries(), "a session in front was carried")
        active = false
        XCTAssertTrue(conversation.carries())
        enabled = false
        XCTAssertFalse(conversation.carries(), "a session was carried with the call setting off")
        enabled = true
        let send = conversation.send
        conversation.send = nil
        XCTAssertFalse(conversation.carries(), "a session was carried with no chat to send through")
        conversation.send = send
        XCTAssertTrue(conversation.carries())
    }

    func testNothingIsCarriedUntilTheDetectorHasLoaded() async {
        let (conversation, voice, _) = await make(endpoint: Endpoint())
        defer { voice.cancel() }
        await tap(voice)
        active = false
        XCTAssertFalse(conversation.carries(), "a session was carried with no detector to end its utterances")
        leave()
        XCTAssertFalse(conversation.on)
    }

    func testAHeldPressIsNotCarried() async {
        let (conversation, voice, _) = await make()
        defer { voice.cancel() }
        _ = await voice.pressDown(as: .chat)
        XCTAssertTrue(voice.listening)
        XCTAssertFalse(voice.handsFree)
        XCTAssertFalse(conversation.carries(), "a press with a thumb on it was carried behind the lock")
    }

    func testDictationIntoTheDraftIsNeverCarriedAndIsDroppedAsTheSceneGoes() async {
        let (conversation, voice, _) = await make(sends: false)
        await tap(voice)
        leave()
        XCTAssertFalse(conversation.on, "dictation into the draft began a conversation")
        XCTAssertEqual(told, [])
        conversation.scene(.background)
        XCTAssertFalse(voice.listening, "dictation was left open behind the lock")
    }

    func testTheSceneGoingCarriesTheSessionTheLockWillCarry() async {
        let (conversation, voice, _) = await make()
        defer { conversation.stop("test", sending: false) }
        await tap(voice)
        active = false
        conversation.scene(.inactive)
        XCTAssertTrue(voice.listening, "the scene's going dropped a session the conversation carries")
    }

    // MARK: - The conversation

    func testLeavingBeginsItTellsTheCallAndStopsTheGlances() async {
        let (conversation, voice, _) = await make()
        defer { conversation.stop("test", sending: false) }
        await tap(voice)
        leave()
        XCTAssertTrue(conversation.on)
        XCTAssertEqual(told, [true])
        XCTAssertFalse(voice.glancing, "the captions glance on behind the lock")
        XCTAssertTrue(conversation.beginIfCarried(), "the lifecycle's ask after the app's did not answer on")
        XCTAssertEqual(told, [true], "a second ask began a second conversation")
    }

    func testAnUtteranceTheDetectorEndsIsSentOnceAndTheMicrophoneOpensAgainOnTheCall() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, _) = await make(detector: detector)
        defer { conversation.stop("test", sending: false) }
        await tap(voice)
        leave()
        conversation.call(.placing)
        XCTAssertTrue(voice.suspended, "the placing did not suspend the microphone")
        conversation.call(.active)
        XCTAssertTrue(voice.listening && !voice.suspended, "the activation did not resume the microphone")
        utterance(into: voice.sink)
        await settle("the turn sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
        await settle("the microphone open again") { voice.listening }
        XCTAssertTrue(voice.handsFree)
        XCTAssertEqual(voice.owner, .chat)
        await drain()
        XCTAssertEqual(sent.count, 1, "one utterance was sent twice")
        XCTAssertTrue(conversation.on)
    }

    func testACoughIsNotAnUtterance() async {
        let detector = ScriptedDetector([0: .start(0), 1: .end(1_000)])
        let (conversation, voice, _) = await make(detector: detector)
        defer { conversation.stop("test", sending: false) }
        await tap(voice)
        leave()
        utterance(into: voice.sink)
        await settle("the chunks fed") { detector.chunks >= 5 }
        XCTAssertEqual(sent, [], "a quarter second's sound was sent as a turn")
        XCTAssertTrue(voice.listening)
    }

    func testTheMicrophoneOpensOnlyOnTheCallsSession() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, _) = await make(detector: detector)
        defer { conversation.stop("test", sending: false) }
        await tap(voice)
        leave()
        utterance(into: voice.sink)
        await settle("the turn sent") { self.sent.count == 1 }
        await drain()
        XCTAssertFalse(voice.listening, "the microphone was opened behind the lock with no call")
        conversation.call(.placing)
        conversation.call(.active)
        await settle("the microphone open on the call") { voice.listening }
        conversation.call(.taken)
        XCTAssertTrue(voice.suspended, "a phone call taking the session left the microphone on it")
    }

    /// Either order of the lock's two moments: the interruption's start suspends first, and the
    /// call's activation resumes what it kept.
    func testTheInterruptionsStartBeforeTheBackgroundIsCarriedAndResumedAtTheActivation() async {
        let (conversation, voice, _) = await make()
        defer { conversation.stop("test", sending: false) }
        await tap(voice)
        active = false
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await settle("suspended at the interruption") { voice.suspended }
        XCTAssertTrue(voice.listening, "the interruption dropped a carried session")
        leave()
        XCTAssertTrue(conversation.on)
        conversation.call(.placing)
        XCTAssertTrue(voice.suspended)
        conversation.call(.active)
        XCTAssertTrue(voice.listening && !voice.suspended, "the activation did not resume the kept session")
    }

    func testASessionSuspendedInFrontWithNoConversationIsDroppedWhenTheAppIsActive() async {
        let (conversation, voice, _) = await make()
        await tap(voice)
        active = false
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        await settle("suspended") { voice.suspended }
        active = true
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertFalse(voice.listening, "a suspended session outlived the app's return with no conversation")
        XCTAssertFalse(conversation.on)
    }

    // MARK: - The end, every way

    private func begun(_ detector: ScriptedDetector = ScriptedDetector(), judge: ScriptedJudge? = nil,
                       deafAfter: TimeInterval = 3_600, sounding: Bool = false,
                       feedSleep: (@Sendable (Duration) async throws -> Void)? = nil) async -> (Conversation, VoiceInput, Speaker) {
        let made = await make(detector: detector, judge: judge, deafAfter: deafAfter, sounding: sounding, feedSleep: feedSleep)
        await tap(made.1)
        leave()
        placeAndActivate(made.0)
        XCTAssertTrue(made.0.on)
        return made
    }

    private func assertEndedOnce(_ conversation: Conversation, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(conversation.on, file: file, line: line)
        XCTAssertEqual(ends, 1, "the lifecycle was told \(ends) times", file: file, line: line)
        XCTAssertEqual(told.last, false, "the call was not let go", file: file, line: line)
    }

    func testAHangUpEndsItOnceAndDropsWhatIsOpen() async {
        let (conversation, voice, _) = await begun()
        conversation.call(.hungUp)
        assertEndedOnce(conversation)
        XCTAssertFalse(voice.listening)
        conversation.call(.over)
        XCTAssertEqual(ends, 1, "the call's end after a hang-up told the lifecycle again")
    }

    func testTheCallBeingOverEndsIt() async {
        let (conversation, _, _) = await begun()
        conversation.call(.over)
        assertEndedOnce(conversation)
    }

    func testComingToTheFrontEndsItAndAHangUpRacingItEndsNothingMore() async {
        let (conversation, voice, _) = await begun()
        active = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        assertEndedOnce(conversation)
        conversation.call(.hungUp)
        XCTAssertEqual(ends, 1)
        await drain()
        XCTAssertFalse(voice.listening, "what was open with nothing said in it outlived the end")
    }

    func testTwoMinutesWithNothingSaidEndsIt() async {
        let (conversation, voice, _) = await begun()
        await settle("the idle clock running") { self.idle.waiting >= 1 }
        XCTAssertTrue(idle.asked.contains(Conversation.idle))
        while idle.waiting > 0 { idle.fire(); await drain() }
        assertEndedOnce(conversation)
        XCTAssertFalse(voice.listening)
    }

    func testAWaitStandingIsNotIdleness() async {
        let (conversation, _, _) = await begun()
        holding = true
        await settle("the idle clock running") { self.idle.waiting >= 1 }
        idle.fire()
        await settle("the clock started again") { self.idle.waiting >= 1 }
        XCTAssertTrue(conversation.on, "the idle clock ended a conversation with a reply on its way")
        holding = false
        idle.fire()
        await settle("ended") { !conversation.on }
        XCTAssertEqual(ends, 1)
    }

    /// The idle clock firing while an utterance is being decoded: the decode is not idleness, and
    /// its words are sent once.
    func testTheIdleClockFiringMidDecodeLosesNothingAndSendsOnce() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, _) = await begun(detector)
        await settle("the idle clock running") { self.idle.waiting >= 1 }
        gate.close()
        utterance(into: voice.sink)
        await settle("the decode under way") { self.gate.held == 1 }
        idle.fire()
        await settle("the clock started again") { self.idle.waiting >= 1 }
        XCTAssertTrue(conversation.on, "the idle clock ended a conversation mid-decode")
        gate.open()
        await settle("sent") { self.sent.count == 1 }
        await drain()
        XCTAssertEqual(sent, ["turn the lights off"], "one utterance was sent other than once")
        XCTAssertEqual(ends, 0)
    }

    // MARK: - The review's blockers

    /// The lock's `.began` under the active call: the session is suspended, never carried across
    /// it on its engine, and rebuilt at once on the call's live session.
    func testAnInterruptionsStartUnderTheActiveCallRebuildsTheMicrophone() async {
        let (conversation, voice, _) = await begun()
        defer { conversation.stop("test", sending: false) }
        XCTAssertTrue(voice.listening && !voice.suspended)
        let starts = voice.sessions
        let engines = seams.inputEngines
        beganInterruption()
        await settle("the engine replaced") { self.seams.inputEngines == engines + 1 }
        await settle("resumed on it") { voice.listening && !voice.suspended }
        XCTAssertTrue(conversation.on)
        XCTAssertEqual(voice.sessions, starts, "a rebuild counted as a new session")
    }

    /// A reply that landed while a phone call held the session is read once the call is back
    /// and nothing has been said: it is judged at the resume, not left waiting for an
    /// utterance.
    func testAReplyThatWaitedThroughAPhoneCallIsReadAtTheResume() async {
        let (conversation, voice, speaker) = await begun()
        defer { conversation.stop("test", sending: false) }
        audio.callDeactivated()
        conversation.call(.taken)
        XCTAssertTrue(voice.suspended)
        CapturingPlayerNode.scheduled = []
        CapturingPlayerNode.peaks = []
        XCTAssertTrue(speaker.speak("The lights are off."), "the reply was refused rather than kept")
        XCTAssertTrue(speaker.waitingForMicrophone, "a reply was read into a suspended microphone")
        XCTAssertEqual(CapturingPlayerNode.scheduled, [], "a reply was played into a suspended microphone")
        audio.callActivated()
        conversation.call(.active)
        await settle("the microphone closed for the reply") { !voice.listening }
        await assertReadOnce(speaker)
    }

    /// The reply played, and played once: its wait over is not proof, since a close that threw
    /// the reply away ends the wait too. Its one sentence is asked of the voice once, and the
    /// voice's first frame — all it gives before the suite lets the rest go — is the one buffer
    /// with sound in it.
    private func assertReadOnce(_ speaker: Speaker, file: StaticString = #filePath, line: UInt = #line) async {
        await settle("the reply read", file: file, line: line) {
            !speaker.waitingForMicrophone && !CapturingPlayerNode.scheduled.isEmpty
        }
        await drain()
        XCTAssertEqual(spoken.streams, 1, "the reply's sentence was asked for other than once", file: file, line: line)
        // A lead of silence may go ahead of the first frame; only the frame carries sound.
        XCTAssertEqual(CapturingPlayerNode.peaks.filter { $0 > 0 }.count, 1, "the reply was played other than once",
                       file: file, line: line)
    }

    /// Words said into the microphone before a reply landed are judged before the reply closes
    /// it: sent, then the reply read.
    func testWordsHeardBeforeAWaitingReplyAreJudgedBeforeTheReplyClosesTheMicrophone() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, speaker) = await begun(detector)
        defer { conversation.stop("test", sending: false) }
        audio.callDeactivated()
        conversation.call(.taken)
        CapturingPlayerNode.scheduled = []
        CapturingPlayerNode.peaks = []
        XCTAssertTrue(speaker.speak("The lights are off."))
        utterance(into: voice.sink)
        audio.callActivated()
        conversation.call(.active)
        await settle("the words sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"], "words heard before the reply were dropped for it")
        await assertReadOnce(speaker)
    }

    /// A reply landing while the detector is judging the chunk speech starts in waits for the
    /// verdict: the microphone stays open, and the words are sent.
    func testAReplyLandingMidVerdictWaitsForIt() async {
        // Two utterances are eleven whole chunks and a part: the held one is the last whole one,
        // so only the verdict in flight stands between the reply and the close.
        let detector = ScriptedDetector([10: .start(40_960), 12: .end(52_000)])
        detector.hold(at: 10)
        let (conversation, voice, speaker) = await begun(detector)
        defer { conversation.stop("test", sending: false) }
        utterance(into: voice.sink)
        utterance(into: voice.sink)
        await settle("the verdict pending") { detector.holding }
        XCTAssertTrue(speaker.speak("The lights are off."))
        await drain()
        XCTAssertTrue(voice.listening, "a reply closed the microphone over a chunk the detector was judging")
        detector.release()
        utterance(into: voice.sink)
        await settle("the words sent") { self.sent.count == 1 }
    }

    /// Silence the detector has not yet been fed: the reply waits for it, then closes the
    /// microphone unsent, from the feeder's own pass.
    func testAReplyOverAnUnjudgedSilenceIsReadOnceTheSilenceIsJudged() async {
        let detector = ScriptedDetector()
        let (conversation, voice, speaker) = await begun(detector)
        defer { conversation.stop("test", sending: false) }
        audio.callDeactivated()
        conversation.call(.taken)
        CapturingPlayerNode.scheduled = []
        CapturingPlayerNode.peaks = []
        XCTAssertTrue(speaker.speak("The lights are off."))
        utterance(into: voice.sink)
        audio.callActivated()
        conversation.call(.active)
        await settle("the silence judged") { detector.chunks >= 5 }
        await settle("the microphone closed for the reply") { !voice.listening }
        await assertReadOnce(speaker)
        XCTAssertEqual(sent, [])
    }

    /// The engine stops under the call with nothing to say so (a route change): no samples for
    /// the deaf window rebuilds it once, and deaf again ends the conversation with what was kept.
    func testADeafMicrophoneIsRebuiltOnceThenEndsTheConversationWithItsWords() async {
        let detector = ScriptedDetector([0: .start(0)])
        let (conversation, voice, _) = await begun(detector, deafAfter: 0.5)
        let engines = seams.inputEngines
        utterance(into: voice.sink)
        await settle("ended") { !conversation.on }
        XCTAssertEqual(seams.inputEngines, engines + 1, "the deaf microphone was not rebuilt exactly once before the end")
        XCTAssertEqual(ends, 1)
        await settle("what was kept sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
        XCTAssertFalse(voice.listening)
    }

    func testAMuteClosesTheMicrophoneAndAReopenWaitingOnItOpensNothing() async {
        let (conversation, voice, _) = await begun()
        defer { conversation.stop("test", sending: false) }
        conversation.call(.muted(true))
        XCTAssertFalse(voice.listening)
        // The unmute's reopen held at its permission, and the mute landing while it waits.
        permission.arm()
        conversation.call(.muted(false))
        await settle("the reopen waiting on its permission") { self.permission.waiting }
        let engines = seams.inputEngines
        conversation.call(.muted(true))
        permission.release()
        await drain()
        XCTAssertFalse(voice.listening, "the microphone opened under the mute")
        XCTAssertEqual(seams.inputEngines, engines, "a reopen under the mute made an engine")
        conversation.call(.muted(false))
        await settle("open at the unmute") { voice.listening }
    }

    // MARK: - The second round's blockers

    /// A hang-up while the foreground's handoff is decoding: the person ended it, and nothing is
    /// sent after the call's waits are gone.
    func testAHangUpDuringTheForegroundsHandoffSendsNothing() async {
        let detector = ScriptedDetector([0: .start(0)])
        let (conversation, voice, _) = await begun(detector)
        utterance(into: voice.sink)
        await settle("the start judged") { detector.chunks >= 2 }
        gate.close()
        active = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await settle("the handoff decoding") { self.gate.held == 1 }
        conversation.call(.hungUp)
        gate.open()
        await drain()
        XCTAssertEqual(sent, [], "a handoff decoded across a hang-up was sent")
        XCTAssertEqual(ends, 1)
    }

    /// The same handoff with nothing ending it is sent once: the drop is the hang-up's alone.
    func testTheForegroundsHandoffIsSentOnce() async {
        let detector = ScriptedDetector([0: .start(0)])
        let (_, voice, _) = await begun(detector)
        utterance(into: voice.sink)
        await settle("the start judged") { detector.chunks >= 2 }
        active = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await settle("sent") { self.sent.count == 1 }
        await drain()
        XCTAssertEqual(sent, ["turn the lights off"])
    }

    /// The call's session taken and given back while a verdict is with the detector: the
    /// verdict is kept, whichever it was, and the utterance ends and is sent.
    private func assertAVerdictHeldAcrossAHandoffIsKept(holding chunk: Int, file: StaticString = #filePath,
                                                        line: UInt = #line) async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        detector.hold(at: chunk)
        let (conversation, voice, _) = await begun(detector)
        defer { conversation.stop("test", sending: false) }
        utterance(into: voice.sink)
        await settle("the verdict pending", file: file, line: line) { detector.holding }
        audio.callDeactivated()
        conversation.call(.taken)
        XCTAssertTrue(voice.suspended, file: file, line: line)
        audio.callActivated()
        conversation.call(.active)
        XCTAssertTrue(voice.listening && !voice.suspended, file: file, line: line)
        detector.release()
        await settle("the words sent", file: file, line: line) { self.sent.count == 1 }
        await drain()
        XCTAssertEqual(sent, ["turn the lights off"], file: file, line: line)
    }

    func testASpeechStartHeldAcrossTheCallsSessionChangingHandsIsKept() async {
        await assertAVerdictHeldAcrossAHandoffIsKept(holding: 0)
    }

    func testASpeechEndHeldAcrossTheCallsSessionChangingHandsIsKept() async {
        await assertAVerdictHeldAcrossAHandoffIsKept(holding: 4)
    }

    /// Coming to the front with the speech's first verdict still with the detector: the words
    /// are not judged silent, and are sent.
    func testComingToTheFrontMidVerdictSendsTheWords() async {
        let detector = ScriptedDetector([0: .start(0)])
        detector.hold(at: 0)
        let (_, voice, _) = await begun(detector)
        utterance(into: voice.sink)
        await settle("the verdict pending") { detector.holding }
        active = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        detector.release()
        await settle("sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
    }

    /// Coming to the front with speech the detector has not been fed at all: sent, not dropped.
    func testComingToTheFrontBeforeTheDetectorIsFedSendsTheWords() async {
        let detector = ScriptedDetector([0: .start(0)])
        let (_, voice, _) = await begun(detector)
        await drain()
        utterance(into: voice.sink)
        active = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await settle("sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
        XCTAssertEqual(detector.chunks, 0, "the test meant to land before any chunk was fed")
    }

    /// A word shorter than one of the detector's chunks, the unlock landing before more arrives:
    /// nothing has been fed, and it is sent rather than taken for silence.
    func testComingToTheFrontWithLessThanAChunkUnfedSendsTheWord() async {
        let (_, voice, _) = await begun()
        await drain()
        utterance(into: voice.sink, seconds: 0.25)
        XCTAssertLessThan(voice.sink.peek(from: 0).end, Endpoint.chunk, "the test meant less than a chunk")
        active = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await settle("sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
    }

    /// A detector that fails on every chunk after speech starts: the conversation ends within
    /// its bound, sending the words, rather than running with speech that never ends.
    func testADetectorThatKeepsFailingEndsTheConversationWithTheWords() async {
        let detector = ScriptedDetector([0: .start(0)])
        detector.fail(from: 1)
        let (conversation, voice, _) = await begun(detector)
        utterance(into: voice.sink)
        await settle("ended") { !conversation.on }
        XCTAssertEqual(detector.chunks, 1 + Conversation.failuresTolerated + 1,
                       "it ended other than at the first failure past its bound")
        XCTAssertEqual(ends, 1)
        await settle("sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
        XCTAssertFalse(voice.listening)
    }

    /// Every way the person ends it while the decode of a stop that sends is under way drops the
    /// words: the hang-up and the mute from the card, and the chat going.
    private func assertTheForegroundsHandoffIsDropped(by end: (Conversation) -> Void,
                                                      file: StaticString = #filePath, line: UInt = #line) async {
        let detector = ScriptedDetector([0: .start(0)])
        let (conversation, voice, _) = await begun(detector)
        utterance(into: voice.sink)
        await settle("the start judged", file: file, line: line) { detector.chunks >= 2 }
        gate.close()
        active = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        await settle("the handoff decoding", file: file, line: line) { self.gate.held == 1 }
        end(conversation)
        gate.open()
        await drain()
        XCTAssertEqual(sent, [], "a handoff decoded across the person's end was sent", file: file, line: line)
    }

    func testAMuteDuringTheForegroundsHandoffSendsNothing() async {
        await assertTheForegroundsHandoffIsDropped { $0.call(.muted(true)) }
    }

    func testTheChatGoingDuringTheForegroundsHandoffSendsNothing() async {
        await assertTheForegroundsHandoffIsDropped { $0.send = nil }
    }

    /// The detector's own end being decoded as Topo comes to the front, then the person ends it:
    /// the stop that sent left that decode to send, and the hang-up or mute after it drops it.
    private func assertAnUtterancesDecodeAfterTheUnlockIsDropped(by end: (Conversation) -> Void,
                                                               file: StaticString = #filePath, line: UInt = #line) async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, _) = await begun(detector)
        gate.close()
        utterance(into: voice.sink)
        await settle("the utterance decoding", file: file, line: line) { self.gate.held == 1 }
        active = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertFalse(conversation.on, file: file, line: line)
        end(conversation)
        gate.open()
        await drain()
        XCTAssertEqual(sent, [], "an utterance decoded across the person's end was sent", file: file, line: line)
    }

    func testAHangUpAfterTheUnlockDropsTheUtteranceBeingDecoded() async {
        await assertAnUtterancesDecodeAfterTheUnlockIsDropped { $0.call(.hungUp) }
    }

    func testAMuteAfterTheUnlockDropsTheUtteranceBeingDecoded() async {
        await assertAnUtterancesDecodeAfterTheUnlockIsDropped { $0.call(.muted(true)) }
    }

    /// A verdict still with the detector for a feeder the mute cancelled says nothing of the
    /// feeders after it: a resume past the unmute's reopen feeds the detector again.
    func testACancelledFeedersVerdictDoesNotKeepTheNextResumeFromFeeding() async {
        let detector = ScriptedDetector([0: .start(0)])
        detector.hold(at: 0)
        let (conversation, voice, _) = await begun(detector)
        defer { conversation.stop("test", sending: false); detector.release() }
        utterance(into: voice.sink)
        await settle("the first feeder's verdict pending") { detector.holding }
        detector.holdNoMore()
        conversation.call(.muted(true))
        conversation.call(.muted(false))
        await settle("open again at the unmute") { voice.listening && !voice.suspended }
        detector.script([0: .start(0), 4: .end(16_000)])
        audio.callDeactivated()
        conversation.call(.taken)
        XCTAssertTrue(voice.suspended)
        // Long past the unmute's feeder's 100 ms sleep, so it has seen the suspension and gone.
        try? await Task.sleep(for: .milliseconds(800))
        audio.callActivated()
        conversation.call(.active)
        XCTAssertTrue(voice.listening && !voice.suspended)
        utterance(into: voice.sink)
        await settle("the words sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
    }

    /// A reopen whose permission answers after the call's session began changing hands refuses,
    /// rather than waiting the change out behind the lock.
    func testAReopenWhosePermissionLandsWhileTheSessionChangesHandsRefuses() async {
        let (conversation, voice, _) = await begun()
        voice.callSettle = .seconds(30)
        permission.arm()
        conversation.call(.muted(true))
        conversation.call(.muted(false))
        await settle("the reopen waiting on its permission") { self.permission.waiting }
        let engines = seams.inputEngines
        audio.callDeactivated()
        permission.release()
        await settle("refused") { voice.refusal == "the call's session is changing hands" }
        await drain()
        XCTAssertFalse(voice.listening)
        XCTAssertEqual(seams.inputEngines, engines, "the reopen opened on a session changing hands")
        XCTAssertFalse(conversation.on, "a refused reopen left the conversation on")
    }

    /// A phone call takes the session and never gives it back: the idle clock ends the
    /// conversation with a wait standing, sending what was kept, so neither the call nor the
    /// resident is held for a dead microphone.
    func testAMicrophoneSuspendedPastTheIdleClockEndsTheConversationWhateverWaits() async {
        let (conversation, voice, _) = await begun()
        await settle("the idle clock running") { self.idle.waiting >= 1 }
        audio.callDeactivated()
        conversation.call(.taken)
        XCTAssertTrue(voice.suspended)
        holding = true
        idle.fire()
        await settle("ended") { !conversation.on }
        XCTAssertEqual(ends, 1)
        await drain()
        XCTAssertFalse(voice.listening, "the suspended session outlived the conversation")
    }

    /// The session suspended under a live call by any path is resumed, not left deaf.
    func testASessionSuspendedWithTheCallLiveIsResumed() async {
        let (conversation, voice, _) = await begun()
        defer { conversation.stop("test", sending: false) }
        voice.suspend("a test")
        conversation.call(.active)
        await settle("resumed") { voice.listening && !voice.suspended }
    }

    func testAHangUpMidDecodeSendsNothing() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, _) = await begun(detector)
        gate.close()
        utterance(into: voice.sink)
        await settle("the decode under way") { self.gate.held == 1 }
        conversation.call(.hungUp)
        gate.open()
        await drain()
        XCTAssertEqual(sent, [], "a turn the person hung up on was sent")
        XCTAssertEqual(ends, 1)
    }

    func testAMuteMidDecodeSendsNothingAndKeepsTheMicrophoneClosedUntilTheUnmute() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, _) = await begun(detector)
        defer { conversation.stop("test", sending: false) }
        gate.close()
        utterance(into: voice.sink)
        await settle("the decode under way") { self.gate.held == 1 }
        conversation.call(.muted(true))
        gate.open()
        await drain()
        XCTAssertEqual(sent, [], "a muted utterance was sent")
        XCTAssertFalse(voice.listening, "the microphone opened again under the mute")
        conversation.call(.muted(false))
        await settle("open again at the unmute") { voice.listening }
    }

    /// Words said before the lock, the session suspended at the interruption's start, the call
    /// never activating: what was kept is decoded and sent.
    func testWordsSaidBeforeTheLockAreSentWhenTheCallNeverActivates() async {
        let (conversation, voice, _) = await make()
        await tap(voice)
        utterance(into: voice.sink)
        active = false
        beganInterruption()
        await settle("suspended") { voice.suspended }
        leave()
        audio.callPlaced()
        conversation.call(.placing)
        conversation.call(.over)
        await settle("sent") { self.sent.count == 1 }
        XCTAssertEqual(ends, 1)
    }

    func testWordsSaidBeforeTheLockAreSentWhenTheAppComesBackBeforeTheActivation() async {
        let (conversation, voice, _) = await make()
        await tap(voice)
        utterance(into: voice.sink)
        active = false
        beganInterruption()
        await settle("suspended") { voice.suspended }
        leave()
        audio.callPlaced()
        conversation.call(.placing)
        active = true
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        await settle("sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
    }

    /// A phone call up: nothing is carried, and an interruption in front drops the session.
    func testNothingIsCarriedOverAPhoneCall() async {
        let (conversation, voice, _) = await make()
        await tap(voice)
        other = true
        active = false
        XCTAssertFalse(conversation.carries(), "a session was carried over the person's phone call")
        beganInterruption()
        await drain()
        XCTAssertFalse(voice.listening, "the interruption kept a session over a phone call")
        leave()
        XCTAssertFalse(conversation.on)
        XCTAssertEqual(told, [])
    }

    func testTheChatGoingEndsTheConversation() async {
        let (conversation, _, _) = await begun()
        conversation.send = nil
        assertEndedOnce(conversation)
    }

    // MARK: - The judge

    /// Silence at the ear's rate, `seconds` of it: all at once, or paced as the tap delivers it,
    /// 100 ms at a time, so the feeder counts a frame or so a pass and the judge is asked at each
    /// boundary the rule asks at.
    private func quiet(_ seconds: Double, into sink: SampleSink, paced: Bool = true,
                       until done: (@MainActor () -> Bool)? = nil) async {
        let format = sink.format
        let step = paced ? 0.1 : seconds
        var left = seconds
        while left > 0.0001 {
            if let done, done() { return }
            let frames = AVAudioFrameCount((format.sampleRate * min(step, left)).rounded())
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return XCTFail("no buffer") }
            buffer.frameLength = frames
            for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = 0 }
            sink.append(buffer)
            left -= step
            if paced { try? await Task.sleep(for: .milliseconds(110)) }
        }
    }

    func testAPauseTheJudgeCallsIncompleteIsNotAnEnd() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.2])
        let (conversation, voice, _) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        utterance(into: voice.sink)
        await quiet(3.5, into: voice.sink)
        await drain()
        await settle("the detector reset") { !detector.silences.isEmpty }
        XCTAssertGreaterThan(judge.asks, 4, "the judge was not asked through the pause")
        XCTAssertEqual(sent, [], "a pause the judge called unfinished ended the turn")
        XCTAssertTrue(voice.listening)
        // Silero's own end is the cap with a judge loaded, so it does not cut the pause at 2.1 s.
        XCTAssertEqual(detector.silences.first, Endpoint.silence(judged: true))
        XCTAssertEqual(Endpoint.silence(judged: true), 4.0)
    }

    func testFourSecondsOfQuietEndsWhateverTheJudgeSays() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.2])
        let (conversation, voice, _) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        utterance(into: voice.sink)
        await quiet(3.8, into: voice.sink, paced: false)
        await drain()
        XCTAssertEqual(sent, [], "the turn ended before four seconds of quiet")
        await quiet(0.3, into: voice.sink, paced: false)
        await settle("the turn sent at the cap") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
    }

    func testTwoCompleteVerdictsAfterTheWaitEndTheTurn() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.95])
        let (conversation, voice, _) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        utterance(into: voice.sink)
        await quiet(3.0, into: voice.sink) { self.sent.count == 1 }
        await settle("the turn sent") { self.sent.count == 1 }
        // Ended by the judge after the wait, well inside the 4 s cap.
        XCTAssertGreaterThanOrEqual(judge.asks, 2)
        XCTAssertEqual(sent, ["turn the lights off"])
    }

    /// One of the feeder's passes over what the sink holds, driven by hand through its sleep
    /// (`Conversation.feedSleep`), then parked again.
    private func pass(_ feed: ManualSleep, _ what: String) async {
        feed.fire()
        await settle(what) { feed.waiting == 1 }
        await Task.yield()
    }

    /// Quiet a frame at a time, a pass each, until `done`; the frames the sink holds past a
    /// detector chunk are counted a pass late, so the count is watched rather than assumed.
    private func quietUntil(_ what: String, _ sink: SampleSink, _ feed: ManualSleep, frames: Int = 60,
                            file: StaticString = #filePath, line: UInt = #line,
                            _ done: @MainActor () -> Bool) async {
        for _ in 0..<frames where !done() {
            await quiet(0.1, into: sink, paced: false)
            await pass(feed, what)
        }
        XCTAssertTrue(done(), "fed \(frames) quiet frames without \(what)", file: file, line: line)
    }

    /// Speech resuming between an ask and its verdict, with the verdict landing before the
    /// feeder's next pass: the frame that arrived first is counted first, so the verdict was
    /// asked before speech resumed and counts for nothing. The feeder's passes are driven by hand,
    /// so the loud frame and the verdict land between two of them by construction.
    func testAVerdictLandingAfterSpeechResumedButBeforeTheNextPassCountsForNothing() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.95])
        judge.hold(calls: [1])
        let feed = ManualSleep()
        let (conversation, voice, _) = await begun(detector, judge: judge, feedSleep: feed.sleep)
        defer { conversation.stop("test", sending: false); judge.releaseAll() }
        await settle("the feeder parked after its first pass") { feed.waiting == 1 }
        utterance(into: voice.sink)
        await pass(feed, "the speech counted")
        // The first ask, answered complete at once, is one vote; the second is held.
        await quietUntil("the first verdict counted", voice.sink, feed) { conversation.votes == 1 }
        await quietUntil("the second ask held", voice.sink, feed) { judge.held == 1 }
        // On to the wait: nothing is asked while the second is in flight.
        await quietUntil("the quiet counted to the wait", voice.sink, feed) { conversation.quietFrames >= 12 }
        XCTAssertEqual(conversation.votes, 1)
        XCTAssertEqual(judge.asks, 2)
        XCTAssertEqual(sent, [])
        XCTAssertEqual(feed.waiting, 1, "the feeder is parked between passes")
        // A whole loud frame arrives and the held verdict lands, with the feeder parked.
        utterance(into: voice.sink, seconds: 0.1)
        judge.release(call: 1)
        await drain()
        XCTAssertEqual(feed.waiting, 1, "a pass ran before the verdict was judged")
        XCTAssertEqual(sent, [], "a verdict asked before speech resumed ended the turn over it")
        XCTAssertTrue(voice.listening)
        XCTAssertEqual(conversation.quietFrames, 0, "the loud frame was not counted before the verdict")
        XCTAssertEqual(conversation.votes, 1, "the verdict asked before speech resumed was a vote")
        await pass(feed, "the next pass")
        XCTAssertEqual(sent, [])
    }

    /// Speech under 0.25 s is a cough to Silero's end, and so to the judge's: a pulse with
    /// Silero's end not yet come is not ended by the judge, however complete it calls it.
    func testAPulseShorterThanACoughIsNoUtteranceTheJudgeCanEnd() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.95])
        let (conversation, voice, _) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        utterance(into: voice.sink, seconds: 0.1)
        await quiet(3.0, into: voice.sink)
        await drain()
        XCTAssertGreaterThanOrEqual(judge.asks, 2, "the judge was not asked")
        XCTAssertEqual(sent, [], "the judge ended a 0.1 s pulse")
        XCTAssertTrue(voice.listening)
    }

    /// And to the cap's: with verdicts that never end it, a pulse's quiet runs to the cap, which
    /// is turned away, the rule starting over, and nothing is sent.
    func testAPulseShorterThanACoughIsNoUtteranceTheCapCanEnd() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.1])
        let feed = ManualSleep()
        let (conversation, voice, _) = await begun(detector, judge: judge, feedSleep: feed.sleep)
        defer { conversation.stop("test", sending: false) }
        await settle("the feeder parked after its first pass") { feed.waiting == 1 }
        utterance(into: voice.sink, seconds: 0.1)
        await pass(feed, "the pulse counted")
        var most = 0
        await quietUntil("the cap reached and turned away", voice.sink, feed) {
            most = max(most, conversation.quietFrames)
            return most >= Endpoint.Judging.cap - 1 && conversation.quietFrames < most
        }
        await drain()
        XCTAssertGreaterThanOrEqual(most, Endpoint.Judging.cap - 1, "the quiet never ran to the cap")
        XCTAssertEqual(sent, [], "the cap ended a 0.1 s pulse")
        XCTAssertTrue(voice.listening)
    }

    /// A pulse's cap turned away starts the rule over with the ask in flight still in flight and
    /// the next numbered on from it: no second ask goes while the first is out, and the first's
    /// answer, landing under the rule started over, is no vote of its.
    func testAnAskInFlightAcrossACoughsCapIsTheOnlyOneAndCountsForNothing() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.95])
        judge.hold(calls: [0])
        let feed = ManualSleep()
        let (conversation, voice, _) = await begun(detector, judge: judge, feedSleep: feed.sleep)
        defer { conversation.stop("test", sending: false); judge.releaseAll() }
        await settle("the feeder parked after its first pass") { feed.waiting == 1 }
        utterance(into: voice.sink, seconds: 0.1)
        await pass(feed, "the pulse counted")
        await quietUntil("the first ask held", voice.sink, feed) { judge.held == 1 }
        var most = 0
        await quietUntil("the cap reached and turned away", voice.sink, feed) {
            most = max(most, conversation.quietFrames)
            return most >= Endpoint.Judging.cap - 1 && conversation.quietFrames < most
        }
        // Past where the rule started over asks: nothing goes while the first ask is out.
        await quietUntil("the quiet counted past the first ask's place", voice.sink, feed) {
            conversation.quietFrames >= Endpoint.Judging.askFrom + Endpoint.Judging.askEvery
        }
        XCTAssertEqual(judge.asks, 1, "a second ask went while the first was in flight")
        judge.release(call: 0)
        await drain()
        XCTAssertEqual(conversation.votes, 0, "the answer to an ask made before the rule started over was a vote")
        // The first ask's answer has come back, so the next ask goes.
        await quietUntil("the next ask", voice.sink, feed) { judge.asks == 2 }
        XCTAssertEqual(sent, [])
        XCTAssertTrue(voice.listening)
    }

    /// A verdict the rule turns away (asked before speech resumed) leaves the latency the end's
    /// line says as the last counted verdict's.
    func testAVerdictTurnedAwayLeavesTheLatencyOfTheLastCountedOne() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.2])
        judge.hold(calls: [1])
        let (conversation, voice, _) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false); judge.releaseAll() }
        utterance(into: voice.sink)
        await quiet(0.7, into: voice.sink)
        await settle("the second ask held") { judge.held == 1 }
        let counted = conversation.judgedLatency
        XCTAssertNotNil(counted, "the first verdict counted no latency")
        utterance(into: voice.sink, seconds: 0.3)
        await settle("the loud frames counted") { conversation.quietFrames == 0 }
        try? await Task.sleep(for: .milliseconds(400))
        judge.release(call: 1)
        await drain()
        XCTAssertEqual(conversation.judgedLatency, counted, "a turned-away verdict's 400 ms became the line's latency")
    }

    /// The verdict lands after the utterance it was asked for has ended and the microphone has
    /// opened again: it counts in the next utterance's rule for nothing, and holds back none of that
    /// rule's own asks, which are numbered on from it.
    func testAVerdictAfterTheEndReachesNothing() async {
        let detector = ScriptedDetector([0: .start(0), 7: .end(30_000)])
        let judge = ScriptedJudge([0.95])
        judge.hold(calls: [0, 1])
        let (conversation, voice, _) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false); judge.releaseAll() }
        utterance(into: voice.sink)
        await quiet(0.5, into: voice.sink)
        await settle("the first ask held") { judge.held == 1 }
        // One frame more completes Silero's eighth chunk, and nothing after it reaches the next
        // session's sink.
        await quiet(0.1, into: voice.sink)
        await settle("Silero's end sent the turn") { self.sent.count == 1 }
        await settle("the microphone open again") { voice.listening }
        // The next utterance asks its first question, held too.
        utterance(into: voice.sink)
        await quiet(0.5, into: voice.sink)
        await settle("the second utterance's first ask held") { judge.held == 2 }
        judge.release(call: 0)
        await drain()
        XCTAssertEqual(conversation.votes, 0, "a verdict from the ended utterance counted in the next")
        judge.release(call: 1)
        await settle("the next utterance's own verdict counted") { conversation.votes == 1 }
    }

    func testAJudgeThatThrowsLeavesTheCap() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.95])
        judge.throwing = true
        let (conversation, voice, _) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        utterance(into: voice.sink)
        await quiet(4.5, into: voice.sink) { self.sent.count == 1 }
        await settle("the turn sent at the cap") { self.sent.count == 1 }
        XCTAssertGreaterThan(judge.asks, 1, "a judge that threw was not asked again")
    }

    func testNoJudgeEndsAsToday() async {
        let detector = ScriptedDetector([0: .start(0)])
        let (conversation, voice, _) = await begun(detector)
        defer { conversation.stop("test", sending: false) }
        await settle("the detector reset") { !detector.silences.isEmpty }
        XCTAssertEqual(detector.silences.first, Endpoint.silence(judged: false))
        XCTAssertEqual(Endpoint.silence(judged: false), 2.1)
        utterance(into: voice.sink)
        await quiet(4.5, into: voice.sink, paced: false)
        await drain()
        XCTAssertEqual(sent, [], "with no judge, the quiet's cap ended a turn Silero had not")
        // Silero's end is the end, as it is with no judge at all.
        detector.script([0: .start(0), 27: .end(100_000)])
        await quiet(1.5, into: voice.sink, paced: false)
        await settle("Silero's end sent the turn") { self.sent.count == 1 }
    }

    /// A reply landing while a verdict is in flight waits for it: speech that Silero has since
    /// called a cough leaves nothing said, and the reply closes the microphone only once the
    /// judge has answered.
    func testAReplyWaitsForAVerdictInFlight() async {
        let detector = ScriptedDetector([0: .start(0), 7: .end(1_000)])
        let judge = ScriptedJudge([0.2])
        judge.hold(calls: [0])
        let (conversation, voice, speaker) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false); judge.releaseAll() }
        utterance(into: voice.sink)
        await quiet(0.5, into: voice.sink)
        await settle("the ask held") { judge.held == 1 }
        await quiet(0.2, into: voice.sink)
        await settle("the cough judged") { detector.chunks >= 8 }
        XCTAssertTrue(speaker.speak("The lights are off."))
        await drain()
        XCTAssertTrue(voice.listening, "a reply closed the microphone over a verdict in flight")
        judge.release(call: 0)
        await settle("the microphone closed for the reply") { !voice.listening }
        XCTAssertEqual(sent, [])
    }

    func testADetectedEndHoldsUntilItsSend() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.95])
        let (conversation, voice, speaker) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        var heldAtTheSend = false
        var releasesPastTheWait = -1
        conversation.send = { [unowned self] heard in
            heldAtTheSend = self.audio.holding
            _ = speaker.awaitReply("turn", readAloud: true)
            releasesPastTheWait = speaker.releasesHeld
            self.sent.append(heard)
        }
        gate.close()
        utterance(into: voice.sink)
        await quiet(3.0, into: voice.sink) { self.gate.held == 1 }
        await settle("the decode under way") { self.gate.held == 1 }
        XCTAssertEqual(speaker.releasesHeld, 1, "the detected end took no release")
        XCTAssertTrue(audio.holding, "the process was not held from the detected end")
        gate.open()
        await settle("sent") { self.sent.count == 1 }
        XCTAssertTrue(heldAtTheSend, "the process was not held between the end and the send")
        XCTAssertEqual(releasesPastTheWait, 0, "the release outlived its turn's wait")
        XCTAssertEqual(speaker.awaiting, ["turn"])
        speaker.endAwaiting("turn", "the test is done")
    }

    func testADetectedEndThatSendsNothingLetsItsHoldGo() async {
        gate = GatedEngine("")
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.95])
        let (conversation, voice, speaker) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        gate.close()
        utterance(into: voice.sink)
        await quiet(3.0, into: voice.sink) { self.gate.held == 1 }
        await settle("the decode under way") { self.gate.held == 1 }
        XCTAssertEqual(speaker.releasesHeld, 1, "the detected end took no release")
        gate.open()
        await settle("the release let go") { speaker.releasesHeld == 0 }
        XCTAssertEqual(sent, [])
        XCTAssertFalse(audio.holding, "an end that sent nothing kept its hold")
    }

    func testNothingIsJudgedBeforeSileroHearsSpeech() async {
        let detector = ScriptedDetector()
        let judge = ScriptedJudge([0.95])
        let (conversation, voice, _) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        utterance(into: voice.sink)
        await quiet(1.0, into: voice.sink)
        await drain()
        XCTAssertEqual(judge.asks, 0, "the judge was asked about an utterance with no speech in it")
        XCTAssertEqual(sent, [])
    }

    /// The speaker's wiring: the call's hang-up reaches the conversation through `onCall`.
    func testTheCardsHangUpReachesTheConversationThroughTheSpeaker() async {
        let (conversation, _, speaker) = await begun()
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        speaker.attach(call)
        speaker.onCall = { conversation.call($0) }
        call.onHangUp()
        assertEndedOnce(conversation)
    }
}

/// The judge, scripted by the call: the nth call answers `verdicts[n]` (the last repeated), or
/// throws, and a call named in `hold` waits for its `release`.
final class ScriptedJudge: TurnJudge, @unchecked Sendable {
    private let lock = NSLock()
    private let verdicts: [Float]
    private var calls = 0
    private var holding: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var thrown = false
    var throwing: Bool {
        get { lock.withLock { thrown } }
        set { lock.withLock { thrown = newValue } }
    }

    init(_ verdicts: [Float]) { self.verdicts = verdicts }

    var asks: Int { lock.withLock { calls } }
    var held: Int { lock.withLock { waiting.count } }
    func hold(calls: Set<Int>) { lock.withLock { holding = calls } }
    func release(call: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            holding.remove(call)
            return waiting.removeValue(forKey: call)
        }
        continuation?.resume()
    }
    func releaseAll() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            holding = []
            defer { waiting = [:] }
            return Array(waiting.values)
        }
        all.forEach { $0.resume() }
    }

    struct Threw: Error {}

    func complete(_ tail: [Float]) async throws -> Float {
        let (call, waits) = lock.withLock { () -> (Int, Bool) in
            defer { calls += 1 }
            return (calls, holding.contains(calls))
        }
        if waits {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.withLock { waiting[call] = continuation }
            }
        }
        if throwing { throw Threw() }
        return verdicts[min(call, verdicts.count - 1)]
    }
}

// MARK: - The conversation's tones

/// The open mic's own tone, on the conversation: no tone at an utterance's onset, the
/// go-ahead owed at the conversation's start, after a turn sent, after a reply and at an unmute
/// and paid once the microphone is open with nothing on its way, yielding to a cue that has just
/// said it, and the gate shut under a tone so the ear does not take it for speech.
extension ConversationTests {
    private var played: [KeeperSounds.Tone] { sounds?.played ?? [] }

    func testTheGoAheadSoundsAtTheStartAndAfterATurnOnceNothingIsOnItsWay() async {
        waitOnSend = true
        let detector = ScriptedDetector([1: .start(8_000), 2: .start(12_000), 4: .end(20_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        // The detector's resets at the start and the resume land before anything is heard.
        await drain()
        XCTAssertTrue(speaker.conversing)
        await settle("the go-ahead at the start") { self.played == [.speak] }
        utterance(into: voice.sink)
        await settle("the turn sent") { self.sent.count == 1 }
        XCTAssertEqual(played, [.speak], "the utterance's onset sounded a tone")
        await settle("the microphone open again") { voice.listening }
        await drain()
        XCTAssertEqual(played, [.speak], "the go-ahead sounded with the turn on its way")
        speaker.endAwaiting("spoken-1", "the reply is in")
        await settle("the go-ahead once the turn is in") { self.played == [.speak, .speak] }
        await drain()
        XCTAssertEqual(played, [.speak, .speak], "the go-ahead was paid twice")
        detector.script([1: .start(8_000), 4: .end(16_000)])
        utterance(into: voice.sink)
        await settle("the second turn sent") { self.sent.count == 2 }
        XCTAssertEqual(played, [.speak, .speak], "the next utterance's onset sounded a tone")
        speaker.endAwaiting("spoken-2", "the test is done")
        conversation.stop("test", sending: false)
        XCTAssertFalse(speaker.conversing)
    }

    func testAReplyReadOwesTheGoAheadForTheMicrophoneThatOpensAfterIt() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        utterance(into: voice.sink)
        await settle("the go-ahead after the turn") { self.played == [.speak, .speak] }
        XCTAssertTrue(speaker.speak("The lights are off."))
        await settle("the microphone closed for the reply") { !voice.listening }
        speaker.stop()
        await settle("the microphone open again") { voice.listening }
        await settle("the go-ahead after the reply") { self.played == [.speak, .speak, .speak] }
    }

    func testAnUnmuteOwesTheGoAheadAndACueThatHasJustSoundedStandsInForIt() async {
        let (conversation, voice, speaker) = await begun(sounding: true)
        defer { conversation.stop("test", sending: false) }
        await settle("the go-ahead at the start") { self.played == [.speak] }
        conversation.call(.muted(true))
        await settle("the microphone closed") { !voice.listening }
        conversation.call(.muted(false))
        await settle("the go-ahead at the unmute") { self.played == [.speak, .speak] }

        conversation.call(.muted(true))
        await settle("the microphone closed") { !voice.listening }
        XCTAssertTrue(speaker.earcons?.play(.listening) == true)
        conversation.call(.muted(false))
        await settle("the microphone open again") { voice.listening }
        await drain()
        XCTAssertEqual(played, [.speak, .speak], "the go-ahead sounded over the cue that had just said it")
    }

    /// The go-ahead shuts the gate: the ear hearing its tone, a third of a second (longer than
    /// the minimum), sends nothing, and opens no turn of its own.
    func testTheGoAheadShutsTheGateSoItsToneIsNoUtterance() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, _) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        utterance(into: voice.sink)
        await settle("the turn sent") { self.sent.count == 1 }
        detector.script([0: .start(0), 1: .end(6_000)])
        await settle("the go-ahead") { self.played == [.speak, .speak] }
        await drain()
        utterance(into: voice.sink)
        await settle("the chunks fed") { detector.chunks >= 5 }
        await drain()
        XCTAssertEqual(sent.count, 1, "the go-ahead's own tone was sent as a turn")
        XCTAssertEqual(played, [.speak, .speak], "the tone's onset sounded a tone")
        XCTAssertFalse(conversation.heardOnset, "the go-ahead's own onset was given to the person")
    }

    /// Words carried into the conversation from the press, judged only after the call's resume,
    /// are the person's: the go-ahead waits for the detector to give them, and they are sent.
    func testWordsCarriedInAreSentBeforeTheGoAheadSounds() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(18_000)])
        let (conversation, voice, _) = await make(detector: detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await tap(voice)
        utterance(into: voice.sink)
        active = false
        beganInterruption()
        await settle("suspended") { voice.suspended }
        leave()
        placeAndActivate(conversation)
        await settle("the carried words sent") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
        XCTAssertEqual(tonesAtSend, [[]], "the go-ahead sounded over words the detector had yet to give")
    }

    /// A wait that ends while the next onset is still with the detector pays no go-ahead over it:
    /// the words are judged first, and sent.
    func testAWaitEndingOverAnOnsetNotYetJudgedPaysNoGoAheadOverIt() async {
        waitOnSend = true
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        utterance(into: voice.sink)
        await settle("the first turn sent") { self.sent.count == 1 }
        await settle("the microphone open again") { voice.listening }
        await drain()
        detector.script([2: .start(8_192), 4: .end(18_000)])
        detector.hold(at: 2)
        utterance(into: voice.sink)
        await settle("the onset's chunk with the detector") { detector.holding }
        let before = played
        speaker.endAwaiting("spoken-1", "a reply nobody reads")
        await drain()
        XCTAssertEqual(played, before, "the go-ahead sounded over an onset the detector had yet to give")
        detector.release()
        await settle("the second turn sent") { self.sent.count == 2 }
        speaker.endAwaiting("spoken-2", "the test is done")
    }

    /// A wait that ends while a chunk with nothing said in it is still with the detector has its
    /// go-ahead paid once the detector has judged it.
    func testAWaitEndingOverSilenceNotYetJudgedPaysTheGoAheadOnceItIs() async {
        waitOnSend = true
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        utterance(into: voice.sink)
        await settle("the first turn sent") { self.sent.count == 1 }
        await settle("the microphone open again") { voice.listening }
        await drain()
        detector.script([:])
        detector.hold(at: 0)
        utterance(into: voice.sink)
        await settle("a chunk with the detector") { detector.holding }
        let before = played
        speaker.endAwaiting("spoken-1", "a reply nobody reads")
        await drain()
        XCTAssertEqual(played, before, "the go-ahead sounded over a chunk the detector had yet to judge")
        detector.release()
        await settle("the go-ahead once it is judged") { self.played == before + [.speak] }
    }

    /// A receipt sounded while the onset of words begun before it is still with the detector
    /// takes nothing of them.
    func testAReceiptOverAnOnsetNotYetJudgedTakesNothingOfIt() async {
        let detector = ScriptedDetector([2: .start(8_192), 3: .end(16_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        _ = speaker.awaitReply("before", readAloud: true)
        detector.hold(at: 2)
        utterance(into: voice.sink)
        await settle("the onset's chunk with the detector") { detector.holding }
        sounds?.follow(.update(.event(.toolUse(name: "Bash"))))
        XCTAssertEqual(played, [.speak, .act])
        detector.release()
        await settle("the turn sent") { self.sent.count == 1 }
        speaker.endAwaiting("before", "the test is done")
    }

    /// A delegate's tone heard a fifth of a second late, as the pinned Silero gives it through a
    /// room (an onset inside the gate, an end past it by the detector's lateness), is no
    /// utterance.
    func testADelegatesToneHeardLateIsNoUtterance() async {
        let detector = ScriptedDetector([5: .start(18_880), 7: .end(30_272)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        _ = speaker.awaitReply("before", readAloud: true)
        utterance(into: voice.sink, seconds: 19_328.5 / Double(voice.sink.format.sampleRate))
        await settle("what the sink holds judged") { detector.chunks >= 4 }
        sounds?.follow(.update(.event(.toolUse(name: "Agent"))))
        utterance(into: voice.sink, seconds: 1.5)
        await settle("the chunks fed") { detector.chunks >= 9 }
        await drain()
        XCTAssertEqual(sent, [], "the delegate's own tone was sent as a turn")
        XCTAssertFalse(conversation.heardOnset, "the tone's onset was given to the person")
        speaker.endAwaiting("before", "the test is done")
    }

    /// A receipt whose onset the detector puts a chunk and the pad before the receipt's place in
    /// the stream is the receipt's, not the person's.
    func testAReceiptsOnsetReportedEarlyIsTheReceipts() async {
        let detector = ScriptedDetector([3: .start(10_688), 6: .end(22_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        _ = speaker.awaitReply("before", readAloud: true)
        utterance(into: voice.sink, seconds: 16_000.5 / Double(voice.sink.format.sampleRate))
        await settle("what the sink holds judged") { detector.chunks >= 3 }
        sounds?.follow(.update(.event(.toolUse(name: "Bash"))))
        utterance(into: voice.sink, seconds: 1.0)
        await settle("the chunks fed") { detector.chunks >= 7 }
        await drain()
        XCTAssertEqual(sent, [], "the receipt's own onset was taken for the person's")
        XCTAssertFalse(conversation.heardOnset, "the receipt's onset was given to the person")
        speaker.endAwaiting("before", "the test is done")
    }

    /// The gates go with their utterance: the next one's onset, in the same stretch of a sink
    /// begun again, is the person's.
    func testAnUtterancesGatesGoWithIt() async {
        let detector = ScriptedDetector([1: .start(8_000), 7: .end(26_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        _ = speaker.awaitReply("before", readAloud: true)
        utterance(into: voice.sink)
        await settle("the onset") { conversation.heardOnset }
        await settle("what the sink holds judged") { detector.chunks >= 5 }
        sounds?.follow(.update(.event(.toolUse(name: "Bash"))))
        utterance(into: voice.sink, seconds: 0.75)
        await settle("the first turn sent") { self.sent.count == 1 }
        speaker.endAwaiting("before", "its reply is in")
        await settle("the microphone open again") { voice.listening }
        await drain()
        detector.script([5: .start(20_000), 7: .end(28_000)])
        utterance(into: voice.sink, seconds: 2.25)
        await settle("the second turn sent") { self.sent.count == 2 }
    }

    /// A tone sounded over words already begun (a receipt of the turn still being worked on)
    /// takes nothing of them: the utterance is counted from its own start and sent.
    func testAToneOverWordsAlreadyBegunTakesNothingOfThem() async {
        let detector = ScriptedDetector([1: .start(8_000), 7: .end(16_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        // A turn on its way, whose tools sound while the person speaks.
        _ = speaker.awaitReply("before", readAloud: true)
        utterance(into: voice.sink)
        await settle("the onset") { conversation.heardOnset }
        sounds?.follow(.update(.event(.toolUse(name: "Bash"))))
        XCTAssertEqual(played, [.speak, .act])
        utterance(into: voice.sink, seconds: 0.75)
        await settle("the turn sent") { self.sent.count == 1 }
        speaker.endAwaiting("before", "the test is done")
    }
}

// MARK: - The tones with the judge loaded

extension ConversationTests {
    /// Speech-level tone at the ear's rate, paced as the tap delivers it, a tenth of a second at
    /// a time; `between` runs before each tenth with its index.
    private func pacedSpeech(_ seconds: Double, into sink: SampleSink, between: (Int) -> Void = { _ in }) async {
        let format = sink.format
        let steps = Int((seconds * 10).rounded())
        for step in 0..<steps {
            between(step)
            let frames = AVAudioFrameCount((format.sampleRate * 0.1).rounded())
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return XCTFail("no buffer") }
            buffer.frameLength = frames
            for frame in 0..<Int(frames) { buffer.floatChannelData![0][frame] = 0.1 * Float(sin(Double(frame) * 0.05)) }
            sink.append(buffer)
            try? await Task.sleep(for: .milliseconds(110))
        }
    }

    /// `testTheGoAheadShutsTheGateSoItsToneIsNoUtterance` with Smart Turn loaded and
    /// Silero's end where a judged stream puts it (4 s of silence, past what is fed here).
    func testTheGoAheadsGatedOnsetEndsNoUtteranceUnderTheJudge() async {
        let detector = ScriptedDetector()
        let judge = ScriptedJudge([0.2])
        let (conversation, voice, _) = await begun(detector, judge: judge, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        await drain()
        let resets = detector.resets
        let fedBefore = detector.chunks
        detector.script([fedBefore: .start(1_000)])
        await quiet(4.6, into: voice.sink)
        await drain()
        XCTAssertEqual(judge.asks, 0, "the judge was asked about the go-ahead's own tone")
        XCTAssertEqual(detector.resets, resets, "the tone ended an utterance: the microphone closed and opened again")
        XCTAssertEqual(sent, [], "the tone's utterance was decoded and sent (the suite's ear hears words in anything)")
        XCTAssertTrue(voice.listening)
    }

    /// `testADelegatesToneHeardLateIsNoUtterance`'s shape, a receipt into an idle microphone
    /// with a turn on its way, with Smart Turn loaded.
    func testAReceiptsGatedOnsetEndsNoUtteranceUnderTheJudge() async {
        let detector = ScriptedDetector()
        let judge = ScriptedJudge([0.2])
        let (conversation, voice, speaker) = await begun(detector, judge: judge, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        _ = speaker.awaitReply("before", readAloud: true)
        await quiet(1.0, into: voice.sink)
        await settle("what the sink holds judged") { detector.chunks >= 3 }
        await drain()
        let resets = detector.resets
        sounds?.follow(.update(.event(.toolUse(name: "Read"))))
        XCTAssertEqual(played, [.speak, .read])
        // Silero hears the receipt inside its gate: chunk 4 is [16384, 20480).
        detector.script([4: .start(17_000)])
        await quiet(4.6, into: voice.sink)
        await drain()
        XCTAssertEqual(judge.asks, 0, "the judge was asked about a receipt's own tone")
        XCTAssertEqual(detector.resets, resets, "the receipt ended an utterance: the microphone closed and opened again")
        XCTAssertEqual(sent, [], "the receipt's utterance was decoded and sent")
        speaker.endAwaiting("before", "the test is done")
    }

    /// The person talks on without a pause while the turn on its way reaches for a tool every
    /// 0.6 s: the rule's cap is quiet frames, and none of these is quiet.
    func testReceiptsOverContinuingSpeechDoNotReachTheCap() async {
        let detector = ScriptedDetector([1: .start(8_000)])
        let judge = ScriptedJudge([0.2])
        let (conversation, voice, speaker) = await begun(detector, judge: judge, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        _ = speaker.awaitReply("before", readAloud: true)
        await pacedSpeech(5.5, into: voice.sink) { step in
            if step >= 6, step % 6 == 0 { self.sounds?.follow(.update(.event(.toolUse(name: "Read")))) }
        }
        let sentWhileSpeaking = sent
        await drain()
        XCTAssertTrue(conversation.heardOnset, "the person's onset")
        XCTAssertGreaterThanOrEqual(played.filter { $0 == .read }.count, 7, "the receipts sounded")
        XCTAssertEqual(sentWhileSpeaking, [], "the turn was ended at the quiet's cap while the person was still speaking")
        speaker.endAwaiting("before", "the test is done")
    }

    /// Three receipts 0.6 s apart over continuing speech, with a judge that calls everything
    /// complete: the wait (1.2 s, the standard) is quiet, and none of this is.
    func testThreeReceiptsOverContinuingSpeechDoNotLetTheJudgeEndIt() async {
        let detector = ScriptedDetector([1: .start(8_000)])
        let judge = ScriptedJudge([0.95])
        let (conversation, voice, speaker) = await begun(detector, judge: judge, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        _ = speaker.awaitReply("before", readAloud: true)
        await pacedSpeech(4.5, into: voice.sink) { step in
            if [12, 18, 24].contains(step) { self.sounds?.follow(.update(.event(.toolUse(name: "Read")))) }
        }
        let sentWhileSpeaking = sent
        let asks = judge.asks
        await drain()
        XCTAssertEqual(asks, 0, "the judge was asked while the person was speaking")
        XCTAssertEqual(sentWhileSpeaking, [], "the judge ended the turn while the person was still speaking")
        speaker.endAwaiting("before", "the test is done")
    }

    /// Control: the same speech with no receipts is never asked about and never ended.
    func testContinuingSpeechAloneIsNeverAskedAbout() async {
        let detector = ScriptedDetector([1: .start(8_000)])
        let judge = ScriptedJudge([0.95])
        let (conversation, voice, speaker) = await begun(detector, judge: judge, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        _ = speaker.awaitReply("before", readAloud: true)
        await pacedSpeech(5.5, into: voice.sink)
        XCTAssertEqual(judge.asks, 0, "control: continuous speech was asked about")
        XCTAssertEqual(sent, [], "control: continuous speech was ended")
        speaker.endAwaiting("before", "the test is done")
    }
}

extension ConversationTests {
    /// A receipt heard after five seconds of an idle microphone with a turn on its way: the
    /// frames counted from the utterance's start reach the cap in one pass.
    func testAReceiptAfterALongSilenceEndsNoUtteranceUnderTheJudge() async {
        let detector = ScriptedDetector()
        let judge = ScriptedJudge([0.2])
        let (conversation, voice, speaker) = await begun(detector, judge: judge, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await drain()
        await settle("the go-ahead at the start") { self.played == [.speak] }
        _ = speaker.awaitReply("before", readAloud: true)
        await quiet(5.0, into: voice.sink, paced: false)
        await settle("what the sink holds judged") { detector.chunks >= 19 }
        await drain()
        let resets = detector.resets
        sounds?.follow(.update(.event(.toolUse(name: "Bash"))))
        // Chunk 20 is [81920, 86016), inside the receipt's gate.
        detector.script([20: .start(82_000)])
        await quiet(0.6, into: voice.sink)
        let sentSoon = sent
        await drain()
        XCTAssertEqual(sentSoon, [], "a receipt after a long silence ended an utterance at once")
        XCTAssertEqual(detector.resets, resets, "the microphone closed and opened again for a receipt")
        speaker.endAwaiting("before", "the test is done")
    }

    /// The test-coverage lens's pin for startUtterance's freshUtterance(): an ask in flight across
    /// a mute leaves the next utterance caught up.
    func testAnAskInFlightAcrossAMuteLeavesTheNextUtteranceCaughtUp() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.2]); judge.hold(calls: [0])
        let (conversation, voice, speaker) = await begun(detector, judge: judge)
        defer { conversation.stop("test", sending: false); judge.releaseAll() }
        utterance(into: voice.sink)
        await quiet(0.5, into: voice.sink)
        await settle("the ask held") { judge.held == 1 }
        conversation.call(.muted(true))
        await settle("closed") { !voice.listening }
        judge.release(call: 0)
        await drain()
        conversation.call(.muted(false))
        await settle("open again") { voice.listening }
        XCTAssertTrue(speaker.speak("The lights are off."))
        await settle("the mic closed for the reply over silence") { !voice.listening }
    }
}

// MARK: - In front

/// A tap in front is a conversation on the app's own session, with no call: the judge ends each
/// utterance and the microphone opens again (#622). Any press but Stop ends it; Stop keeps it
/// listening (Sam's rulings in plan-open-mic-in-front.md).
extension ConversationTests {
    /// A tap with Topo in front, the call setting off: a conversation in front.
    private func inFront(_ detector: ScriptedDetector, judge: ScriptedJudge? = nil, sounding: Bool = false,
                         sends: Bool = true,
                         wire: (Conversation, VoiceInput, Speaker) -> Void = { _, _, _ in }) async -> (Conversation, VoiceInput, Speaker) {
        active = true
        enabled = false
        let made = await make(detector: detector, judge: judge, sends: sends, sounding: sounding)
        wire(made.0, made.1, made.2)
        await tap(made.1)
        return made
    }

    private func drawn(_ voice: VoiceInput, _ speaker: Speaker) -> Composer.MicState {
        Composer.MicState(voice, speaking: speaker.speaking)
    }

    func testATapInFrontIsAConversationThatSendsByItselfAndOpensAgain() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, _) = await inFront(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await settle("the conversation in front") { conversation.on && conversation.inFront }
        XCTAssertEqual(told, [true])
        await settle("the go-ahead at the start") { self.played == [.speak] }
        utterance(into: voice.sink)
        await settle("the turn sent with no second tap") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
        await settle("the microphone open again") { voice.listening }
        await settle("the go-ahead after the turn") { self.played == [.speak, .speak] }
        XCTAssertTrue(conversation.inFront)
        XCTAssertEqual(audio.call, .none, "a call was placed in front")
    }

    /// In front the turn ends on Smart Turn as behind the lock: a sentence the judge calls
    /// complete is sent after the wait, inside the cap.
    func testInFrontACompleteSentenceIsSentOnTheJudgeAfterTheWait() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.95])
        let (conversation, voice, _) = await inFront(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        await settle("the conversation in front") { conversation.on && conversation.inFront }
        utterance(into: voice.sink)
        await quiet(3.0, into: voice.sink) { self.sent.count == 1 }
        await settle("the turn sent") { self.sent.count == 1 }
        XCTAssertGreaterThanOrEqual(judge.asks, 2, "the turn ended in front without the judge")
        XCTAssertEqual(sent, ["turn the lights off"])
    }

    /// In front a pause the judge calls unfinished holds: Silero's own end is the cap.
    func testInFrontAPauseTheJudgeCallsUnfinishedHolds() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.2])
        let (conversation, voice, _) = await inFront(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        await settle("the conversation in front") { conversation.on && conversation.inFront }
        utterance(into: voice.sink)
        await quiet(3.5, into: voice.sink)
        await drain()
        XCTAssertGreaterThan(judge.asks, 4, "the judge was not asked through the pause in front")
        XCTAssertEqual(sent, [], "a pause the judge called unfinished ended the turn in front")
        XCTAssertTrue(voice.listening)
        XCTAssertEqual(detector.silences.first, Endpoint.silence(judged: true))
    }

    /// In front four seconds of quiet ends the turn whatever the judge says.
    func testInFrontFourSecondsOfQuietEndsWhateverTheJudgeSays() async {
        let detector = ScriptedDetector([0: .start(0)])
        let judge = ScriptedJudge([0.2])
        let (conversation, voice, _) = await inFront(detector, judge: judge)
        defer { conversation.stop("test", sending: false) }
        await settle("the conversation in front") { conversation.on && conversation.inFront }
        utterance(into: voice.sink)
        await quiet(3.8, into: voice.sink, paced: false)
        await drain()
        XCTAssertEqual(sent, [], "the turn ended in front before four seconds of quiet")
        await quiet(0.3, into: voice.sink, paced: false)
        await settle("the turn sent at the cap") { self.sent.count == 1 }
        XCTAssertEqual(sent, ["turn the lights off"])
    }

    /// With *Call for spoken replies* on and the call driver wired as the app wires it, a front
    /// conversation, its turn and the reply's wait and reading place no call.
    func testInFrontWithTheSettingOnNoCallIsPlaced() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let system = FakeCallSystem()
        let call = SpokenCall(system: system, sleep: ManualSleep().sleep)
        let driver = SpokenCallDriver(call: call, enabled: { true }, center: NotificationCenter(), initial: .active)
        defer { withExtendedLifetime(driver) {} }
        let (conversation, voice, speaker) = await inFront(detector) { [unowned self] conversation, _, speaker in
            enabled = true
            let audio: AudioSession = self.audio
            speaker.onHold = { [weak audio] in driver.holdChanged($0, forATurn: audio?.heldForATurn ?? $0) }
            speaker.onMicrophone = { driver.microphoneChanged($0) }
            conversation.conversingChanged = { driver.conversingChanged($0) }
        }
        defer { conversation.stop("test", sending: false) }
        await settle("the conversation in front") { conversation.on && conversation.inFront }
        utterance(into: voice.sink)
        await settle("sent") { self.sent.count == 1 }
        XCTAssertTrue(speaker.speak("The lights are off."))
        await drain()
        speaker.stop()
        await settle("open again") { voice.listening }
        await drain()
        XCTAssertTrue(conversation.on)
        XCTAssertEqual(system.starts.count, 0, "a front conversation placed a call")
    }

    /// The press's own path in two halves, deterministically: `pressed()` ends the conversation,
    /// leaving the session open hands-free for the press, and a reaction to a change the
    /// conversation watches runs before the press reaches the session. It begins no second
    /// conversation on that session.
    func testASessionAFrontConversationEndedOnBeginsNoOther() async {
        let detector = ScriptedDetector([1: .start(8_000)])
        let (conversation, voice, speaker) = await inFront(detector)
        await settle("the conversation in front") { conversation.on && conversation.inFront }
        conversation.pressed()
        XCTAssertFalse(conversation.on)
        XCTAssertTrue(voice.listening && voice.handsFree, "the press's stop closed the session it leaves to the press")
        // A reply landing waits for the open microphone (`waitingForMicrophone`, which the
        // conversation watches): its reaction runs here, before the press reaches the session.
        XCTAssertTrue(speaker.speak("Elsewhere."))
        await settle("the reply waiting on the microphone") { speaker.waitingForMicrophone }
        await drain()
        XCTAssertFalse(conversation.on, "the session the press ended the conversation on began another")
        speaker.stop()
        _ = await voice.pressDown(as: .chat)
        _ = await voice.pressUp(as: .chat)
        await drain()
        XCTAssertFalse(conversation.on)
    }

    func testNoConversationInFrontForDictationOrUnderAPhoneCall() async {
        let (dictating, voice, _) = await inFront(ScriptedDetector(), sends: false)
        await drain()
        XCTAssertFalse(dictating.on, "dictation into the draft began a conversation")
        voice.cancel()
        other = true
        let (calling, second, _) = await inFront(ScriptedDetector())
        await drain()
        XCTAssertFalse(calling.on, "a conversation began under a phone call")
        second.cancel()
    }

    /// A tap on the open microphone sends what it heard, once, and closes it: the conversation
    /// ends before the press reaches the session.
    func testATapOnTheOpenMicrophoneInFrontSendsOnceAndCloses() async {
        let detector = ScriptedDetector([1: .start(8_000)])
        let (conversation, voice, speaker) = await inFront(detector)
        await settle("the conversation in front") { conversation.on }
        utterance(into: voice.sink)
        await settle("the onset") { conversation.heardOnset }
        let press = MicPress()
        var pressSent: [String] = []
        await press.gesture(true, drawn: drawn(voice, speaker), speaker: speaker, voice: voice,
                            pressed: { conversation.pressed() }) { pressSent.append($0) }?.value
        await press.gesture(false, drawn: drawn(voice, speaker), speaker: speaker, voice: voice,
                            pressed: { conversation.pressed() }) { pressSent.append($0) }?.value
        XCTAssertFalse(conversation.on)
        XCTAssertEqual(pressSent, ["turn the lights off"])
        await drain()
        XCTAssertEqual(sent, [], "the conversation sent what the press sent")
        XCTAssertFalse(voice.listening, "the microphone opened again after the tap")
        XCTAssertFalse(conversation.on, "the press's own session began a conversation")
    }

    /// Stop while Topo reads stops the reading and keeps the conversation: neither the press nor
    /// its release reaches the microphone, which the conversation opens again with the go-ahead.
    func testStopWhileTopoReadsInFrontKeepsItListening() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, speaker) = await inFront(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await settle("the conversation in front") { conversation.on }
        utterance(into: voice.sink)
        await settle("the turn sent") { self.sent.count == 1 }
        await settle("the microphone open again") { voice.listening }
        XCTAssertTrue(speaker.speak("The lights are off, and the heating is down."))
        await settle("the microphone closed for the reading") { !voice.listening && speaker.speaking }
        let tonesBefore = played.count
        let releases = voice.releases
        let press = MicPress()
        let stop = drawn(voice, speaker)
        XCTAssertEqual(stop.appearance, .stop)
        _ = press.gesture(true, drawn: stop, speaker: speaker, voice: voice, pressed: { conversation.pressed() }) { _ in }
        _ = press.gesture(false, drawn: drawn(voice, speaker), speaker: speaker, voice: voice,
                          pressed: { conversation.pressed() }) { _ in }
        XCTAssertFalse(speaker.speaking, "Stop did not stop the reading")
        XCTAssertEqual(voice.releases, releases, "Stop's release reached the microphone")
        XCTAssertTrue(conversation.on && conversation.inFront, "Stop ended the conversation")
        await settle("the microphone open again after Stop") { voice.listening }
        await settle("the go-ahead after Stop") { self.played.count == tonesBefore + 1 }
        XCTAssertEqual(played.last, .speak)
        XCTAssertEqual(sent.count, 1)
    }

    /// A reply that is not read (muted, `SpokenReply.read(muted:)`) ends its wait: the microphone
    /// opens again with the go-ahead.
    func testAWaitEndingUnreadInFrontOpensAgainWithTheGoAhead() async {
        waitOnSend = true
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, speaker) = await inFront(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        await settle("the go-ahead at the start") { self.played == [.speak] }
        utterance(into: voice.sink)
        await settle("the turn sent") { self.sent.count == 1 }
        await settle("the microphone open again") { voice.listening }
        await drain()
        XCTAssertEqual(played, [.speak], "the go-ahead sounded with the turn on its way")
        speaker.endAwaiting("spoken-1", "muted: nothing read")
        await settle("the go-ahead once the wait is over") { self.played == [.speak, .speak] }
        XCTAssertTrue(voice.listening)
    }

    /// Leaving the front with the setting on carries it into the call, as a tapped session is.
    func testLeavingTheFrontCarriesItIntoTheCall() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, _) = await inFront(detector)
        defer { conversation.stop("test", sending: false) }
        await settle("the conversation in front") { conversation.on }
        enabled = true
        leave()
        XCTAssertTrue(conversation.on)
        XCTAssertFalse(conversation.inFront)
        placeAndActivate(conversation)
        await settle("the microphone resumed on the call") { voice.listening && !voice.suspended }
        utterance(into: voice.sink)
        await settle("the turn sent behind the lock") { self.sent.count == 1 }
    }

    /// Leaving the front with the setting off has nothing to carry it: it ends, and what was open
    /// is dropped as the scene's drop drops a session.
    func testLeavingTheFrontWithTheSettingOffEndsIt() async {
        let detector = ScriptedDetector([1: .start(8_000)])
        let (conversation, voice, _) = await inFront(detector)
        await settle("the conversation in front") { conversation.on }
        utterance(into: voice.sink)
        active = false
        conversation.scene(.inactive)
        XCTAssertFalse(conversation.on)
        await drain()
        XCTAssertFalse(voice.listening)
        XCTAssertEqual(sent, [])
        XCTAssertEqual(ends, 1)
    }

    /// An interruption over it in front (a phone call, the app still active) ends it and drops
    /// what was open.
    func testAnInterruptionInFrontEndsIt() async {
        let detector = ScriptedDetector([1: .start(8_000)])
        let (conversation, voice, _) = await inFront(detector)
        await settle("the conversation in front") { conversation.on }
        utterance(into: voice.sink)
        beganInterruption()
        await settle("ended") { !conversation.on }
        await drain()
        XCTAssertFalse(voice.listening)
        XCTAssertEqual(sent, [])
    }

    /// the lock's `.began` before `didEnterBackground` (either order is real,
    /// testTheInterruptionsStartBeforeTheBackgroundIsCarriedAndResumedAtTheActivation),
    /// the setting on: a front conversation the lock carries stays suspended until the call's activation.
    func testTheLocksBeganBeforeTheBackgroundKeepsAFrontConversationSuspendedForTheCall() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, _) = await inFront(detector)
        defer { conversation.stop("test", sending: false) }
        await settle("the conversation in front") { conversation.on && conversation.inFront }
        enabled = true
        let engines = seams.inputEngines
        active = false
        beganInterruption()
        await drain()
        XCTAssertTrue(conversation.on, "the lock's .began ended the front conversation")
        XCTAssertTrue(voice.listening && voice.suspended,
                      "the microphone was rebuilt on the app's own session at the lock's .began, with no call")
        XCTAssertEqual(seams.inputEngines, engines, "an engine was made between the lock's .began and the call")
        XCTAssertEqual(audio.call, .none)
        leave()
        XCTAssertTrue(conversation.on && !conversation.inFront)
        placeAndActivate(conversation)
        await settle("resumed on the call") { voice.listening && !voice.suspended }
        utterance(into: voice.sink)
        await settle("the turn sent behind the lock") { self.sent.count == 1 }
    }

    /// the same lock with the activation refused, as iOS refuses one from an app that is not
    /// active with no call: the front conversation is still carried, and nothing is sent at the lock.
    func testTheLocksBeganBeforeTheBackgroundWithTheActivationRefusedStillCarries() async {
        let detector = ScriptedDetector([1: .start(8_000)])
        let (conversation, voice, _) = await inFront(detector)
        defer { conversation.stop("test", sending: false) }
        await settle("the conversation in front") { conversation.on && conversation.inFront }
        utterance(into: voice.sink)
        await settle("the onset") { conversation.heardOnset }
        enabled = true
        active = false
        seams.activationError = Seams.Refused()
        beganInterruption()
        await drain()
        XCTAssertTrue(conversation.on, "the lock's .began ended the front conversation")
        XCTAssertEqual(sent, [], "half an utterance was sent at the lock")
        XCTAssertEqual(ends, 0)
        leave()
        XCTAssertTrue(conversation.on, "a front conversation the lock carries was not carried")
        seams.activationError = nil
    }

    /// A lock in front with the setting off: the judge has
    /// ended the utterance and its decode is under way when the scene goes. The words are sent, as a
    /// released press's are (StopWhileSpeakingTests.testALockDuringTheReleasesDecodeKeepsItsWords).
    func testALockDuringAFrontUtterancesDecodeKeepsItsWords() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, _) = await inFront(detector)
        await settle("the conversation in front") { conversation.on && conversation.inFront }
        gate.close()
        utterance(into: voice.sink)
        await settle("the utterance's decode under way") { voice.ending }
        active = false
        conversation.scene(.inactive)
        beganInterruption()
        await drain()
        gate.open()
        await drain()
        XCTAssertEqual(sent, ["turn the lights off"], "the lock dropped the words the judge had ended")
    }

    /// an interruption in front (a phone call, the app still active) while the judge's
    /// utterance decodes: the words are sent, as an interruption leaves a release's decode to send.
    func testAnInterruptionInFrontDuringAnUtterancesDecodeKeepsItsWords() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, _) = await inFront(detector)
        await settle("the conversation in front") { conversation.on }
        gate.close()
        utterance(into: voice.sink)
        await settle("the utterance's decode under way") { voice.ending }
        beganInterruption()
        await drain()
        XCTAssertFalse(conversation.on)
        gate.open()
        await drain()
        XCTAssertEqual(sent, ["turn the lights off"], "the interruption dropped the words the judge had ended")
    }

    /// a reopen waiting on the permission when the phone
    /// locks: the lock's placing makes the reopen refuse, and the carried conversation ends.
    func testAReopenSpanningTheLockWaitsForTheActivation() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, _) = await inFront(detector)
        defer { conversation.stop("test", sending: false) }
        enabled = true
        await settle("on") { conversation.on }
        permission.arm()
        utterance(into: voice.sink)
        await settle("the reopen waiting") { self.sent.count == 1 && self.permission.waiting }
        leave()
        XCTAssertTrue(conversation.on && !conversation.inFront)
        audio.callPlaced()
        conversation.call(.placing)
        permission.release()
        await drain()
        XCTAssertTrue(conversation.on, "the lock's placing ended the carried conversation")
        audio.callActivated()
        conversation.call(.active)
        await settle("open on the call") { voice.listening }
    }

    /// A reopen whose permission answers after the lock's `.began` (the app no longer active, no
    /// call yet) opens nothing and reads nothing, and opens on the call once it is live.
    func testAReopenWhosePermissionLandsAsTheAppLeavesTheFrontOpensNothing() async {
        let detector = ScriptedDetector([1: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, _) = await inFront(detector)
        defer { conversation.stop("test", sending: false) }
        enabled = true
        await settle("on") { conversation.on }
        permission.arm()
        utterance(into: voice.sink)
        await settle("the reopen waiting") { self.sent.count == 1 && self.permission.waiting }
        let reads = seams.formatReads
        active = false
        permission.release()
        await drain()
        XCTAssertTrue(conversation.on)
        XCTAssertFalse(voice.listening, "the reopen opened the microphone from an inactive app with no call")
        XCTAssertEqual(seams.formatReads, reads, "the input node was read from an inactive app with no call")
        leave()
        placeAndActivate(conversation)
        await settle("open on the call") { voice.listening && !voice.suspended }
    }
}
