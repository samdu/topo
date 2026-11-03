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

    init(_ events: [Int: Endpoint.Event] = [:]) { self.events = events }

    func script(_ events: [Int: Endpoint.Event]) { lock.withLock { self.events = events; fed = 0 } }
    var chunks: Int { lock.withLock { fed } }

    func reset() async { lock.withLock { resets += 1; fed = 0 } }

    func feed(_ chunk: [Float]) async throws -> Endpoint.Event? {
        lock.withLock {
            defer { fed += 1 }
            return events[fed]
        }
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
    private var told: [Bool] = []
    private var ends = 0
    private var idle = ManualSleep()
    private var center = NotificationCenter()
    private var other = false
    private var audio: AudioSession!
    private var gate = GatedEngine("turn the lights off")

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
    private func make(detector: ScriptedDetector = ScriptedDetector(),
                      sends: Bool = true) async -> (Conversation, VoiceInput, Speaker) {
        let seams = Seams()
        let audio = AudioSession(center: center, configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true })
        self.audio = audio
        let voice = Voice(engine: HeldVoice())
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) })
        let ear = Ear(vocabulary: Vocabulary(defaults: UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!),
                      engine: gate)
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear to load") { ear.ready }
        let input = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) },
                               permission: { true }, permitted: { true },
                               voiceProcessing: { try seams.process($0, $1) })
        speaker.microphoneOpen = { input.listening }
        let conversation = Conversation(voice: input, speaker: speaker, endpoint: Endpoint(detector: detector),
                                        enabled: { [unowned self] in enabled },
                                        appActive: { [unowned self] in active },
                                        holding: { [unowned self] in holding },
                                        otherCall: { [unowned self] in other },
                                        center: center, sleep: idle.sleep)
        speaker.onCall = { conversation.call($0) }
        conversation.conversingChanged = { [unowned self] in told.append($0) }
        conversation.ended = { [unowned self] in ends += 1 }
        conversation.send = { [unowned self] in sent.append($0) }
        conversation.sends = { sends }
        input.carries = { [weak conversation] in
            guard let conversation, conversation.carries() else { return false }
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
    private func utterance(into sink: SampleSink) {
        let format = sink.format
        let frames = AVAudioFrameCount(format.sampleRate * 1.5)
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

    private func begun(_ detector: ScriptedDetector = ScriptedDetector()) async -> (Conversation, VoiceInput, Speaker) {
        let made = await make(detector: detector)
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

    /// The lock's `.began` under the active call leaves the microphone running: the session stays
    /// live, and a suspend there had no way back.
    func testAnInterruptionsStartUnderTheActiveCallLeavesTheMicrophoneRunning() async {
        let (conversation, voice, _) = await begun()
        defer { conversation.stop("test", sending: false) }
        XCTAssertTrue(voice.listening && !voice.suspended)
        beganInterruption()
        await drain()
        XCTAssertFalse(voice.suspended, "the lock's interruption suspended a microphone on the active call")
        XCTAssertTrue(voice.listening)
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
