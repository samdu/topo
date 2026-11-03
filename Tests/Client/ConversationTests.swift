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
    private func make(heard: String = "turn the lights off", detector: ScriptedDetector = ScriptedDetector(),
                      sends: Bool = true) async -> (Conversation, VoiceInput, Speaker) {
        let seams = Seams()
        let audio = AudioSession(center: center, configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true })
        let voice = Voice(engine: HeldVoice())
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) })
        let ear = Ear(vocabulary: Vocabulary(defaults: UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!),
                      engine: ScriptedEngine(bare: heard, boosted: heard))
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
        made.0.call(.placing)
        made.0.call(.active)
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

    /// The idle clock firing as an utterance is sent: one end, one send.
    func testTheIdleClockRacingASendEndsOnceAndSendsOnce() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, _) = await begun(detector)
        utterance(into: voice.sink)
        while idle.waiting > 0 { idle.fire() }
        await settle("ended") { !conversation.on }
        await drain()
        XCTAssertEqual(ends, 1)
        XCTAssertLessThanOrEqual(sent.count, 1, "one utterance was sent twice across the end")
        XCTAssertFalse(voice.listening, "the microphone was left open after the conversation ended")
    }
}
