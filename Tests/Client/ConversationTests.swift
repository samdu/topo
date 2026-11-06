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
    private func make(detector: ScriptedDetector = ScriptedDetector(), endpoint: Endpoint? = nil,
                      sends: Bool = true, deafAfter: TimeInterval = 3_600,
                      sounding: Bool = false) async -> (Conversation, VoiceInput, Speaker) {
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
        let conversation = Conversation(voice: input, speaker: speaker, endpoint: endpoint ?? Endpoint(detector: detector),
                                        enabled: { [unowned self] in enabled },
                                        appActive: { [unowned self] in active },
                                        holding: { [unowned self] in holding },
                                        otherCall: { [unowned self] in other },
                                        deafAfter: deafAfter,
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

    private func begun(_ detector: ScriptedDetector = ScriptedDetector(),
                       deafAfter: TimeInterval = 3_600, sounding: Bool = false) async -> (Conversation, VoiceInput, Speaker) {
        let made = await make(detector: detector, deafAfter: deafAfter, sounding: sounding)
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
        // Long past the unmute's feeder's 256 ms sleep, so it has seen the suspension and gone.
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

// MARK: - The conversation's tones

/// Daphne's open-mic tones, on the conversation: the onset's `ack` once an utterance opens, the
/// go-ahead owed at the conversation's start, after a reply and at an unmute and paid as the
/// microphone opens again with nothing on its way, yielding to a cue that has just said it, and
/// the gate shut under a tone so the ear does not take it for speech.
extension ConversationTests {
    private var played: [KeeperSounds.Tone] { sounds?.played ?? [] }

    func testTheOnsetSoundsTheAckOnceAndTheGoAheadIsPaidAsTheMicrophoneOpensAgain() async {
        let detector = ScriptedDetector([0: .start(0), 2: .start(8_000), 4: .end(16_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        // The detector's resets at the start and the resume land before anything is heard.
        await drain()
        XCTAssertTrue(speaker.conversing)
        XCTAssertEqual(played, [], "a tone before anything was heard: the go-ahead is paid as the microphone opens again")
        utterance(into: voice.sink)
        await settle("the turn sent") { self.sent.count == 1 }
        XCTAssertEqual(played.first, .ack)
        await settle("the microphone open again") { voice.listening }
        await settle("the go-ahead") { self.played.count == 2 }
        XCTAssertEqual(played, [.ack, .speak], "an utterance's second onset sounded a second ack, or the go-ahead was not paid")
        await drain()
        XCTAssertEqual(played, [.ack, .speak], "the go-ahead was paid twice")
        conversation.stop("test", sending: false)
        XCTAssertFalse(speaker.conversing)
    }

    func testAReplyReadOwesTheGoAheadForTheMicrophoneThatOpensAfterIt() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, speaker) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        // The detector's resets at the start and the resume land before anything is heard.
        await drain()
        utterance(into: voice.sink)
        await settle("the go-ahead") { self.played == [.ack, .speak] }
        XCTAssertTrue(speaker.speak("The lights are off."))
        await settle("the microphone closed for the reply") { !voice.listening }
        speaker.stop()
        await settle("the microphone open again") { voice.listening }
        await settle("the go-ahead after the reply") { self.played == [.ack, .speak, .speak] }
    }

    func testAnUnmuteOwesTheGoAheadAndACueThatHasJustSoundedStandsInForIt() async {
        let (conversation, voice, speaker) = await begun(sounding: true)
        defer { conversation.stop("test", sending: false) }
        conversation.call(.muted(true))
        await settle("the microphone closed") { !voice.listening }
        conversation.call(.muted(false))
        await settle("the go-ahead at the unmute") { self.played == [.speak] }

        conversation.call(.muted(true))
        await settle("the microphone closed") { !voice.listening }
        XCTAssertTrue(speaker.earcons?.play(.listening) == true)
        conversation.call(.muted(false))
        await settle("the microphone open again") { voice.listening }
        await drain()
        XCTAssertEqual(played, [.speak], "the go-ahead sounded over the cue that had just said it")
    }

    /// The go-ahead shuts the gate: the ear hearing its tone, a third of a second (longer than
    /// the minimum), sends nothing, and opens no turn of its own.
    func testTheGoAheadShutsTheGateSoItsToneIsNoUtterance() async {
        let detector = ScriptedDetector([0: .start(0), 4: .end(16_000)])
        let (conversation, voice, _) = await begun(detector, sounding: true)
        defer { conversation.stop("test", sending: false) }
        // The detector's resets at the start and the resume land before anything is heard.
        await drain()
        utterance(into: voice.sink)
        await settle("the turn sent") { self.sent.count == 1 }
        detector.script([0: .start(0), 1: .end(6_000)])
        await settle("the go-ahead") { self.played == [.ack, .speak] }
        await drain()
        utterance(into: voice.sink)
        await settle("the chunks fed") { detector.chunks >= 5 }
        await drain()
        XCTAssertEqual(sent.count, 1, "the go-ahead's own tone was sent as a turn")
        XCTAssertEqual(played, [.ack, .speak], "the tone's onset sounded an ack")
    }
}

