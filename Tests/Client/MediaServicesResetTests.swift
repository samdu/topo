import AVFoundation
import ObjectiveC
import TopoCore
import UIKit
import XCTest

@testable import Topo

/// The seams the audio paths are built from, all writing to one log so the order they ran in is
/// observed rather than inferred: the audio session's configure step, the engine factory (the
/// microphone's and the play queue's alike), and the reader of the input node's two formats.
@MainActor
final class Seams {
    /// What ran, in the order it ran.
    private(set) var lines: [String] = []
    /// The record flag each configure was asked for, which is how a released claim is seen.
    private(set) var records: [Bool] = []
    /// Set to make the configure step throw, as an activation refused behind Settings does.
    var activationError: Error?
    /// What the format reader reports in place of the engine's own formats; nil leaves it
    /// reading the node, which is how a test that installs a tap gets a format the node accepts.
    var stubFormats: (client: AVAudioFormat, hardware: AVAudioFormat)?
    /// The client format the reader last handed over, which is the object the tap must carry.
    private(set) var lastClient: AVAudioFormat?
    private(set) var engines: [AVAudioEngine] = []
    private(set) var formatReads = 0

    struct Refused: Error {}

    /// Drops what has been logged, so a test asserts on the order of the part it is about rather
    /// than on the setup in front of it.
    func forget() {
        lines = []
        records = []
    }

    func configure(_ record: Bool) throws {
        records.append(record)
        if let activationError {
            lines.append("activate failed")
            throw activationError
        }
        lines.append("activate ok")
    }

    /// An engine in offline manual rendering: it starts, and its input node hands over a format
    /// and takes a tap, on a host with no audio device at all. Its input node records the format
    /// each tap is installed with.
    func makeEngine() -> AVAudioEngine {
        lines.append("engine made")
        let engine = CapturingEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        engines.append(engine)
        return engine
    }

    func readFormats(_ engine: AVAudioEngine) -> (client: AVAudioFormat, hardware: AVAudioFormat) {
        lines.append("formats read")
        formatReads += 1
        let read = stubFormats ?? (engine.inputNode.outputFormat(forBus: 0),
                                   engine.inputNode.inputFormat(forBus: 0))
        lastClient = read.client
        return read
    }

    /// The play queue's engine: offline manual rendering, so it starts and plays on a host with
    /// no audio device, and its player reclassed so every buffer scheduled on it is counted.
    func makePlayEngine(rate: Int) -> AVAudioEngine {
        lines.append("engine made")
        let engine = CapturingPlayEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
        try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        engines.append(engine)
        return engine
    }
}

/// An input node that remembers the format each tap was installed with. The engine's own node is
/// reclassed into this on the way out of `inputNode`: `AVAudioInputNode` cannot be constructed, and
/// this subclass adds no storage, so the instance's layout is the one it already had.
private final class CapturingInputNode: AVAudioInputNode {
    /// The last format a tap was installed with, anywhere. The suite is serial on the main actor.
    nonisolated(unsafe) static var installed: AVAudioFormat?

    override func installTap(onBus bus: AVAudioNodeBus, bufferSize: AVAudioFrameCount,
                             format: AVAudioFormat?, block: @escaping AVAudioNodeTapBlock) {
        CapturingInputNode.installed = format
        super.installTap(onBus: bus, bufferSize: bufferSize, format: format, block: block)
    }
}

/// A player node that remembers every buffer it was asked to schedule, which is the audio the
/// queue actually let through. Reclassed on the way through `attach`, as the input node is: the
/// play queue constructs its own player, and this subclass adds no storage, so the instance's
/// layout is the one it already had.
final class CapturingPlayerNode: AVAudioPlayerNode {
    /// The frame count of every buffer scheduled, anywhere, in order. The suite is serial on the
    /// main actor; a test that reads it clears it first.
    nonisolated(unsafe) static var scheduled: [AVAudioFrameCount] = []

    override func scheduleBuffer(_ buffer: AVAudioPCMBuffer,
                                 completionCallbackType: AVAudioPlayerNodeCompletionCallbackType,
                                 completionHandler: AVAudioPlayerNodeCompletionHandler?) {
        CapturingPlayerNode.scheduled.append(buffer.frameLength)
        super.scheduleBuffer(buffer, completionCallbackType: completionCallbackType,
                             completionHandler: completionHandler)
    }
}

private final class CapturingPlayEngine: AVAudioEngine {
    override func attach(_ node: AVAudioNode) {
        if node is AVAudioPlayerNode { object_setClass(node, CapturingPlayerNode.self) }
        super.attach(node)
    }
}

private final class CapturingEngine: AVAudioEngine {
    override var inputNode: AVAudioInputNode {
        let node = super.inputNode
        object_setClass(node, CapturingInputNode.self)
        return node
    }
}

/// A format that reports whatever numbers a test asks for, including the ones no real format
/// carries: `AVAudioFormat` refuses to be built with a zero sample rate or no channel, and those
/// are exactly the two an input node reports when the session has no input.
private final class StubFormat: AVAudioFormat {
    private let stubRate: Double
    private let stubChannels: AVAudioChannelCount

    init?(rate: Double, channels: AVAudioChannelCount) {
        stubRate = rate
        stubChannels = channels
        super.init(standardFormatWithSampleRate: 48_000, channels: 1)
    }

    required init?(coder: NSCoder) { fatalError("not decoded") }

    override var sampleRate: Double { stubRate }
    override var channelCount: AVAudioChannelCount { stubChannels }
}

/// 1920 samples, one Pocket frame, at `level`; a level of zero is silence.
func toneFrame(_ level: Float) -> [Float] {
    (0 ..< 1_920).map { level * sin(Float($0) * 0.3) }
}

/// A frame of tone of an exact length, so a test can state the audio a reply made in seconds.
func toneFrame(seconds: Double) -> [Float] {
    (0 ..< Int(seconds * Double(Voice.rate))).map { 0.5 * sin(Float($0) * 0.3) }
}

/// Counts the queue's drains, which fire on the audio thread.
final class Drains: @unchecked Sendable {
    private let lock = NSLock()
    private var drains = 0
    var value: Int { lock.withLock { drains } }
    func count() { lock.withLock { drains += 1 } }
}

/// The clock a test drives instead of the continuous one, so the report's measurements are read
/// off arithmetic rather than raced: nothing here waits for time to pass.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

/// A voice resident over an engine that reads a script: the frames it yields for a sentence, in
/// the order the speaker asks for them. It needs no model.
struct ScriptedVoice: VoiceEngine {
    /// Set to fail the load, which leaves the voice at `failed`.
    var loads = true
    /// The frames of each sentence; one frame of quiet tone by default.
    var frames: @Sendable (String) -> [[Float]] = { _ in [toneFrame(0.5)] }

    func load(base: URL) async throws {
        guard loads else { throw VoiceError.unavailable("no models here") }
    }

    func stream(_ text: String) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        let script = frames(text)
        return AsyncThrowingStream { continuation in
            for samples in script {
                continuation.yield(Voice.Frame(samples: samples, rate: Voice.rate))
            }
            continuation.finish()
        }
    }
}

/// A voice whose second frame waits for the test to let it go, and which records having yielded
/// it: the frame a media services reset lands in the middle of. Breaking out of the stream
/// cancels the task behind it, which is what the sleep returns on, so the held frame is always
/// produced — into a stream nobody is reading any more.
final class HeldVoice: VoiceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var delivered = false

    /// True once the second frame has been yielded.
    var yieldedTheHeldFrame: Bool { lock.withLock { delivered } }
    func releaseTheHeldFrame() { lock.withLock { released = true } }

    func load(base: URL) async throws {}

    func stream(_ text: String) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(Voice.Frame(samples: toneFrame(0.5), rate: Voice.rate))
                while !self.lock.withLock({ self.released }) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                continuation.yield(Voice.Frame(samples: toneFrame(0.5), rate: Voice.rate))
                self.lock.withLock { self.delivered = true }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}


/// A voice whose second sentence is held until the test lets it go, and whose sentences make no
/// audio at all: the queue is idle while a sentence is still being made, which is the gap that
/// must not read as the reply's end.
final class HeldSecondSentence: VoiceEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var asked = 0

    /// How many sentences have been asked for; two means the first is made and the second is in
    /// flight, with nothing in the queue behind it.
    var sentencesAsked: Int { lock.withLock { asked } }
    func releaseTheSecondSentence() { lock.withLock { released = true } }

    func load(base: URL) async throws {}

    func stream(_ text: String) async throws -> AsyncThrowingStream<Voice.Frame, Error> {
        let mine = lock.withLock { asked += 1; return asked }
        return AsyncThrowingStream { continuation in
            let task = Task {
                while mine > 1, !self.lock.withLock({ self.released }) {
                    try? await Task.sleep(for: .milliseconds(5))
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// Recovery from a media services reset, against notifications posted on a private centre and
/// engines, synthesisers and formats from injected seams. No real reset happens here: a simulator
/// cannot trigger one, and none of these tests reaches an audio device.
@MainActor
final class MediaServicesResetTests: XCTestCase {
    private let reset = AVAudioSession.mediaServicesWereResetNotification
    private let began = AVAudioSession.InterruptionType.began.rawValue
    private let ended = AVAudioSession.InterruptionType.ended.rawValue

    /// The observers hop to the main actor; a test waits for the state it expects. The budget is
    /// far longer than the work, because a runner building a hundredth audio engine takes seconds
    /// over one that is idle, and a wait that runs out is a failure named by what it waited for.
    private func settle(_ what: String = "the expected state",
                        file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<12_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited two minutes for \(what)", file: file, line: line)
    }

    /// Lets the observers' main-actor hops run, for a test that expects nothing to change.
    private func drain() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    /// A `VoiceInput` over a resident ear, which is what a press needs: an ear that is not
    /// resident is refused before any of these seams is reached.
    private func voiceInput(_ seams: Seams, _ audio: AudioSession,
                            _ center: NotificationCenter) async -> VoiceInput {
        let ear = Ear(vocabulary: Vocabulary(defaults: UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!),
                      engine: ScriptedEngine())
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle { ear.ready }
        return VoiceInput(audio: audio, ear: ear, center: center,
                          makeEngine: { seams.makeEngine() },
                          formats: { seams.readFormats($0) })
    }

    // MARK: AudioSession

    func testEnsureActiveConfiguresOnceAndIsFreeWhileValid() throws {
        let seams = Seams()
        let audio = AudioSession(center: NotificationCenter(), configure: seams.configure)
        try audio.ensureActive()
        try audio.ensureActive()
        try audio.ensureActive()
        XCTAssertEqual(seams.lines, ["activate ok"], "a valid session is configured once")
    }

    func testAResetInvalidatesTheSessionSoTheNextPathConfiguresItAgain() async throws {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        try audio.ensureActive()
        center.post(name: reset, object: nil)
        // The reset re-applies a session that had been configured, and the next path finds it valid.
        await settle { seams.lines == ["activate ok", "activate ok"] }
        try audio.ensureActive()
        XCTAssertEqual(seams.lines, ["activate ok", "activate ok"])
    }

    func testAConfigureThatThrowsLeavesTheSessionInvalidAndTheNextEnsureRetries() throws {
        let seams = Seams()
        let audio = AudioSession(center: NotificationCenter(), configure: seams.configure)
        seams.activationError = Seams.Refused()
        XCTAssertThrowsError(try audio.ensureActive())
        seams.activationError = nil
        try audio.ensureActive()
        XCTAssertEqual(seams.lines, ["activate failed", "activate ok"])
    }

    func testAResetLeavesANeverConfiguredSessionAlone() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        center.post(name: reset, object: nil)
        await drain()
        XCTAssertEqual(seams.lines, [], "a reset does not activate a session nobody configured")
        withExtendedLifetime(audio) {}
    }

    func testAResetAppliesTheClaimedRecordConfigurationAgain() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        audio.wantRecord(true, for: .chat)
        XCTAssertEqual(seams.records, [true])
        center.post(name: reset, object: nil)
        await settle { seams.records == [true, true] }
    }

    func testAFailedReapplicationAfterAResetIsRememberedRatherThanSwallowed() async throws {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        try audio.ensureActive()
        seams.activationError = Seams.Refused()
        center.post(name: reset, object: nil)
        await settle { seams.lines == ["activate ok", "activate failed"] }
        seams.activationError = nil
        try audio.ensureActive()
        XCTAssertEqual(seams.lines, ["activate ok", "activate failed", "activate ok"],
                       "the next audio path retries rather than trusting the reset's attempt")
    }

    // MARK: VoiceInput — the order of a press

    /// The situation the crash logs came from: the reset landed while Topo was behind Settings,
    /// where activation is refused, so the session is invalid when the thumb comes down.
    private func behindSettings(_ seams: Seams, _ audio: AudioSession,
                                _ center: NotificationCenter) async {
        // The foreground's warm claim, so a press changes no claim and touches the session only
        // through `ensureActive` — which is what made the old press activate nothing.
        audio.wantRecord(true, for: .warm)
        seams.activationError = Seams.Refused()
        center.post(name: reset, object: nil)
        await settle { seams.lines == ["activate ok", "activate failed"] }
        seams.activationError = nil
        seams.forget()
    }

    func testAPressActivatesTheSessionBeforeItBuildsAnEngineOrReadsAFormat() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = await voiceInput(seams, audio, center)
        await behindSettings(seams, audio, center)
        XCTAssertEqual(seams.engines.count, 0, "nothing is built in the handler")
        voice.press(as: .chat, mine: 1)
        XCTAssertEqual(seams.lines, ["activate ok", "engine made", "formats read"])
        XCTAssertNil(voice.refusal)
        XCTAssertTrue(voice.tapped, "the tap is installed only after all three")
        XCTAssertTrue(voice.listening)
        voice.cancel()
    }

    func testTheTapCarriesTheVeryFormatTheGuardJudged() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = await voiceInput(seams, audio, center)
        await behindSettings(seams, audio, center)
        CapturingInputNode.installed = nil
        voice.press(as: .chat, mine: 1)
        XCTAssertTrue(voice.tapped)
        XCTAssertEqual(seams.formatReads, 1, "the input node's format is read once and no more")
        XCTAssertTrue(CapturingInputNode.installed === seams.lastClient,
                      "a second read could be a route change later, which is what installTap raises on")
        voice.cancel()
    }

    // MARK: VoiceInput — activation refused

    func testAPressWhoseSessionWillNotActivateBuildsNothingAndRefuses() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = await voiceInput(seams, audio, center)
        seams.activationError = Seams.Refused()
        voice.press(as: .chat, mine: 1)
        XCTAssertEqual(seams.engines.count, 0, "no engine is built under a dead session")
        XCTAssertEqual(seams.formatReads, 0, "no format is read from one either")
        XCTAssertFalse(voice.tapped)
        XCTAssertEqual(voice.refusal?.hasPrefix("the audio session did not activate:"), true)
        XCTAssertNil(voice.owner)
        XCTAssertFalse(voice.listening)
        XCTAssertEqual(seams.records.last, false, "the record claim is released")
        let tried = seams.lines.count
        voice.press(as: .chat, mine: 2)
        XCTAssertGreaterThan(seams.lines.count, tried, "the next press configures again")
        XCTAssertEqual(seams.engines.count, 0)
    }

    // MARK: VoiceInput — the input guard

    func testTheGuardRefusesEveryFormatInstallTapWouldRaiseOn() {
        let live = VoiceInput.Format(rate: 48_000, channels: 1)
        XCTAssertTrue(VoiceInput.inputIsUsable(client: live, hardware: live))
        for (name, client, hardware) in Self.deadInputs {
            XCTAssertFalse(VoiceInput.inputIsUsable(client: VoiceInput.Format(client),
                                                    hardware: VoiceInput.Format(hardware)), name)
        }
    }

    /// Every way the input node can be reported that `installTap` raises on, as the formats a
    /// press would be handed.
    private static let deadInputs: [(String, AVAudioFormat, AVAudioFormat)] = {
        let live = StubFormat(rate: 48_000, channels: 1)!
        return [
            ("client rate 0", StubFormat(rate: 0, channels: 1)!, live),
            ("client channels 0", StubFormat(rate: 48_000, channels: 0)!, live),
            ("hardware rate 0", live, StubFormat(rate: 0, channels: 1)!),
            ("hardware channels 0", live, StubFormat(rate: 48_000, channels: 0)!),
            ("rates differ", StubFormat(rate: 44_100, channels: 1)!, live),
        ]
    }()

    func testADeadInputInstallsNoTapAndDropsTheEngineAndTheSession() async {
        for (name, client, hardware) in Self.deadInputs {
            let seams = Seams()
            let center = NotificationCenter()
            let audio = AudioSession(center: center, configure: seams.configure)
            let voice = await voiceInput(seams, audio, center)
            audio.wantRecord(true, for: .warm)
            seams.forget()
            seams.stubFormats = (client, hardware)
            voice.press(as: .chat, mine: 1)
            XCTAssertFalse(voice.tapped, name)
            XCTAssertEqual(voice.refusal, VoiceInput.noInput, name)
            XCTAssertNil(voice.owner, name)
            XCTAssertFalse(voice.listening, name)
            XCTAssertEqual(seams.lines, ["engine made", "formats read"], name)
            // The next press finds neither the engine nor the session it just refused on.
            voice.press(as: .chat, mine: 2)
            XCTAssertEqual(seams.lines, ["engine made", "formats read",
                                         "activate ok", "engine made", "formats read"],
                           "\(name): the engine was dropped and the session invalidated")
        }
    }

    // MARK: VoiceInput — the reset itself

    func testAResetCancelsThePressAndDropsTheEngineWithoutBuildingOne() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = await voiceInput(seams, audio, center)
        audio.wantRecord(true, for: .warm)
        seams.forget()
        voice.press(as: .chat, mine: 1)
        XCTAssertTrue(voice.listening)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        XCTAssertEqual(seams.engines.count, 1)
        center.post(name: reset, object: nil)
        await settle { !voice.listening }
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the press was torn down")
        XCTAssertNil(voice.owner)
        XCTAssertFalse(voice.handsFree)
        XCTAssertFalse(voice.tapped)
        XCTAssertEqual(seams.engines.count, 1, "no engine is built in the handler")
        voice.press(as: .chat, mine: 2)
        XCTAssertEqual(seams.engines.count, 2, "the next press builds one")
        voice.cancel()
    }

    func testATeardownWithNoTapDoesNotReadTheInput() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = await voiceInput(seams, audio, center)
        voice.cancel()
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: began])
        await drain()
        XCTAssertEqual(seams.engines.count, 0, "a teardown with no press builds and reads nothing")
        XCTAssertFalse(voice.tapped)
    }

    // MARK: Speaker

    /// A speaker over a resident voice, which is what a reply needs: a voice that is not
    /// resident speaks nothing and reaches none of these seams.
    private func speaker(_ seams: Seams, _ audio: AudioSession, _ center: NotificationCenter,
                         engine: any VoiceEngine = ScriptedVoice(), ready: Bool = true,
                         ceiling: Duration = .seconds(120),
                         clock: ManualClock? = nil) async -> Speaker {
        CapturingPlayerNode.scheduled = []
        let voice = Voice(engine: engine)
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == (ready ? .ready : .failed) }
        return Speaker(audio: audio, voice: voice, center: center,
                       makeEngine: { seams.makePlayEngine(rate: Voice.rate) },
                       ceiling: ceiling,
                       now: clock.map { clock in { clock.now } } ?? PrimaryLease.continuousUptime)
    }

    func testAReplyActivatesTheSessionBeforeItBuildsTheQueueAndScheduling() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.speak("Hello there.")
        XCTAssertTrue(speaker.speaking)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        await settle { speaker.report.started }
        XCTAssertEqual(seams.lines, ["activate ok", "engine made"],
                       "the session is active before the queue exists")
        XCTAssertEqual(speaker.report.engine, .pocket, "there is one voice")
        speaker.stop()
    }

    /// No press anywhere: Say it again is what reactivates the session and rebuilds the queue.
    func testAReplyAfterAResetActivatesTheSessionAgainAndBuildsAFreshQueue() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.speak("Hello there.")
        await settle { speaker.report.started }
        seams.activationError = Seams.Refused()
        center.post(name: reset, object: nil)
        await settle { !speaker.speaking && seams.lines.last == "activate failed" }
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the speaking claim is released")
        seams.activationError = nil
        seams.forget()
        speaker.speak("Again then.")
        await settle("the reply to start") { speaker.report.started }
        XCTAssertEqual(seams.lines, ["activate ok", "engine made"])
        XCTAssertEqual(seams.engines.count, 2, "the engine the reset dropped is not reused")
        XCTAssertEqual(speaker.report.text, "Again then.")
        XCTAssertTrue(speaker.report.started)
        speaker.stop()
    }

    /// A frame the voice yields after the reset is never heard: what it lands on is a queue the
    /// handler has already dropped, and the reply it belonged to is over.
    func testAFrameTheVoiceYieldsAfterAResetIsNeverScheduled() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let held = HeldVoice()
        let speaker = await self.speaker(seams, audio, center, engine: held)
        speaker.speak("Hello there.")
        await settle("the first sentence's frame") { CapturingPlayerNode.scheduled.count >= 1 }
        let before = speaker.generation
        center.post(name: reset, object: nil)
        await settle { speaker.generation != before }
        // The frame that was in flight when the reset landed, delivered before anything is read.
        held.releaseTheHeldFrame()
        await settle { held.yieldedTheHeldFrame }
        await drain()
        XCTAssertEqual(CapturingPlayerNode.scheduled.count, 1, "the held frame reached no player")
        XCTAssertEqual(seams.engines.count, 1, "and built no queue to reach one on")
    }

    func testAReplyWhoseSessionWillNotActivateBuildsNothing() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        seams.activationError = Seams.Refused()
        speaker.speak("Hello there.")
        await drain()
        XCTAssertEqual(seams.engines.count, 0, "no play queue is built under a dead session")
        XCTAssertFalse(speaker.speaking)
        XCTAssertFalse(speaker.report.started)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the speaking claim is released")
    }

    func testAReplyToAVoiceThatIsNotResidentIsNotSpoken() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center,
                                         engine: ScriptedVoice(loads: false), ready: false)
        speaker.speak("Hello there.")
        await drain()
        XCTAssertEqual(seams.lines, [], "the session is not even activated for a voice there is not")
        XCTAssertFalse(speaker.speaking)
        XCTAssertEqual(speaker.report.speaks, 0)
    }

    /// There is no scene in it: a reply is spoken wherever the process is, and the hold it takes
    /// is what keeps the process there.
    func testAReplyIsSpokenWithNoSceneToBeInAndHoldsTheProcessOpen() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.speak("Hello there.")
        await settle { speaker.report.started }
        XCTAssertEqual(seams.lines, ["activate ok", "engine made"])
        XCTAssertEqual(speaker.report.speaks, 1)
        XCTAssertTrue(speaker.holding, "the reply holds the process open while it is read")
        XCTAssertTrue(speaker.keeping, "and the keeper is what holds it")
        speaker.stop()
        XCTAssertFalse(speaker.holding, "a stopped reply lets go")
        XCTAssertFalse(speaker.keeping)
    }

    /// `first` is the time from `speak` to the reply's first frame, and nothing else: the clock
    /// moves two tenths between the two, so that is what the report says.
    func testTheReplysFirstFrameIsTheTimeFromSpeakToIt() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let clock = ManualClock()
        let voice = ScriptedVoice(frames: { _ in clock.advance(0.2); return [toneFrame(0.5)] })
        let speaker = await self.speaker(seams, audio, center, engine: voice, clock: clock)
        speaker.speak("Two tenths.")
        await settle("the reply's frame") { CapturingPlayerNode.scheduled.count >= 1 }
        XCTAssertEqual(speaker.report.first, 0.2, "what a listener waited, off the clock")
        speaker.stop()
    }

    /// `rtf` is the time the reply spent being made over the audio it made: half a second over
    /// two seconds is a quarter, exactly, since neither number is measured against the wall.
    func testTheReplysRealTimeFactorIsItsSynthesisOverItsAudio() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let clock = ManualClock()
        let voice = ScriptedVoice(frames: { _ in clock.advance(0.5); return [toneFrame(seconds: 2)] })
        let speaker = await self.speaker(seams, audio, center, engine: voice, clock: clock)
        speaker.speak("Two seconds of it.")
        await settle("the sentence to be measured") { speaker.report.rtf != nil }
        XCTAssertEqual(speaker.report.rtf, 0.25, "half a second of making, two seconds made")
        speaker.stop()
    }

    /// The measurements are the reply's, and made rather than defaulted: a stream that ends with
    /// no frame times nothing, so a reply nobody heard reports no number at all.
    func testASentenceThatSchedulesNoFrameLeavesTheReplyUnmeasured() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center,
                                         engine: ScriptedVoice(frames: { _ in [] }))
        speaker.speak("Nothing comes of this.")
        // Nothing is scheduled, so the queue is idle the moment the sentence is made and the
        // reply comes to its end: `speaking` going false is the reply having run.
        await settle("the reply to end") { !speaker.speaking }
        XCTAssertNil(speaker.report.first, "no frame was scheduled, so nothing was timed")
        XCTAssertNil(speaker.report.rtf)
        XCTAssertFalse(speaker.report.started)
        XCTAssertEqual(CapturingPlayerNode.scheduled.count, 0)
        speaker.stop()
    }

    /// And it is written once, by the first frame of the reply: a later sentence that makes
    /// nothing schedules nothing and leaves that time where it was.
    func testALaterSentenceThatSchedulesNoFrameLeavesTheReplysFirstFrame() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = ScriptedVoice(frames: { $0.hasPrefix("Loud") ? [toneFrame(0.5)] : [] })
        let speaker = await self.speaker(seams, audio, center, engine: voice)
        speaker.speak("Loud one. Nothing two. Loud three.")
        // The report is written in the same step as the frame it times, so a scheduled buffer is
        // the measurement being there. The waits are `>=` because the count only grows and two
        // sentences can pass between two polls; what the reply scheduled is asserted below, once
        // every sentence of it has been made.
        await settle("the first sentence's frame") { CapturingPlayerNode.scheduled.count >= 1 }
        let first = speaker.report.first
        XCTAssertNotNil(first, "the first sentence's frame was timed")
        await settle("the third sentence's frame") { CapturingPlayerNode.scheduled.count >= 2 }
        await drain()
        XCTAssertEqual(speaker.report.first, first, "the first frame's time is the first sentence's")
        XCTAssertEqual(CapturingPlayerNode.scheduled.count, 2,
                       "the sentence that made nothing scheduled nothing")
        speaker.stop()
    }


    // MARK: The hold behind the lock

    /// A release that will be answered aloud holds the process open from there, and the keeper is
    /// what holds it: the silence is rendering before the turn has even been written.
    func testASpokenReleaseHoldsTheProcessOpenAndTheKeeperPlays() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.awaitReply(readAloud: true)
        XCTAssertTrue(speaker.holding)
        XCTAssertTrue(speaker.keeping)
        XCTAssertEqual(seams.lines, ["activate ok", "engine made"],
                       "the session is active before the engine the keeper needs")
        speaker.stop()
    }

    /// Nothing is held for a reply that could not be heard: the setting off, or a voice that is
    /// not resident at the release. A typed turn takes no hold because the chat never asks for
    /// one; what is held here is the ask itself.
    func testNothingIsHeldForAReplyThatCouldNotBeHeard() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.awaitReply(readAloud: false)
        XCTAssertFalse(speaker.holding, "replies are not read aloud")
        XCTAssertFalse(speaker.keeping)
        XCTAssertEqual(seams.lines, [], "and nothing is built for one")

        let quiet = await self.speaker(seams, audio, center,
                                       engine: ScriptedVoice(loads: false), ready: false)
        quiet.awaitReply(readAloud: true)
        XCTAssertFalse(quiet.holding, "the voice is not resident")
        XCTAssertFalse(quiet.keeping)
        XCTAssertEqual(seams.lines, [])
    }

    /// The handover between the two owners: the reply arrives, `.speaking` is taken and the wait
    /// is let go, and the keeper never stops in between — a gap there is the process suspended
    /// with the reply half read.
    func testTheKeeperDoesNotStopBetweenTheWaitAndTheReply() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.awaitReply(readAloud: true)
        XCTAssertEqual(speaker.keeperTransitions, ["playing"])
        speaker.speak("Hello there.")
        await settle { speaker.report.started }
        XCTAssertTrue(speaker.holding)
        XCTAssertEqual(speaker.keeperTransitions, ["playing"],
                       "the silence carried on from the wait into the reply")
        speaker.stop()
        XCTAssertEqual(speaker.keeperTransitions, ["playing", "stopped"])
        XCTAssertFalse(speaker.holding)
    }

    /// The reply coming to its end is what lets go, and the reply is over only when every
    /// sentence is made and the queue is empty: a queue idle between two sentences is not it.
    func testTheHoldOutlastsAQueueThatIsIdleWhileASentenceIsStillBeingMade() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let held = HeldSecondSentence()
        let speaker = await self.speaker(seams, audio, center, engine: held)
        speaker.speak("One. Two.")
        await settle("the second sentence to be asked for") { held.sentencesAsked == 2 }
        XCTAssertTrue(speaker.speaking, "one sentence is made and the queue is empty; the reply is not over")
        XCTAssertTrue(speaker.holding)
        XCTAssertTrue(speaker.keeping)
        held.releaseTheSecondSentence()
        await settle("the reply to end") { !speaker.speaking }
        XCTAssertFalse(speaker.holding, "the last sentence made, and nothing left to hear")
        XCTAssertFalse(speaker.keeping)
    }

    /// The wait is let go when the turn it was taken for cannot land: the chat calls this on a
    /// failure and when it stops answering at all.
    func testTheWaitIsLetGoWhenTheTurnFails() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.awaitReply(readAloud: true)
        XCTAssertTrue(speaker.keeping)
        speaker.endAwaiting("the turn failed")
        XCTAssertFalse(speaker.holding)
        XCTAssertFalse(speaker.keeping)
    }

    /// An uncapped wait would keep a pocketed phone awake for as long as nothing came back.
    func testTheWaitIsCappedSoAReplyThatNeverComesLetsGo() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center, ceiling: .milliseconds(20))
        speaker.awaitReply(readAloud: true)
        XCTAssertTrue(speaker.holding)
        await settle("the ceiling to run out") { !speaker.holding }
        XCTAssertFalse(speaker.keeping)
    }

    /// iOS posts an interruption at the lock screen with no call and no Siri in it. Dropping the
    /// hold there is the process suspended with the reply unheard, so a `.began` ends nothing: it
    /// marks the engine dead, and the rebuild that follows brings the keeper back.
    func testAnInterruptionWhileAwaitingKeepsTheHoldAndTheRebuildBringsTheKeeperBack() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.awaitReply(readAloud: true)
        XCTAssertTrue(speaker.keeping)

        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: began])
        await settle("the engine to be marked dead") { !speaker.keeping }
        XCTAssertTrue(speaker.holding, "the wait stands: nothing said the reply was not coming")

        seams.forget()
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: ended])
        await settle("the keeper to come back") { speaker.keeping }
        XCTAssertTrue(speaker.holding)
        XCTAssertEqual(seams.lines, ["activate ok", "engine made"],
                       "the session is active before the engine that was rebuilt for it")
        speaker.stop()
    }

    /// The same mid-reply, recovered by the configuration change a real interruption's end posts:
    /// what nobody had heard is scheduled again and the reply carries on.
    func testAnInterruptionMidReplyKeepsWhatWasOwedAndAConfigurationChangePutsItBack() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.awaitReply(readAloud: true)
        speaker.speak("Hello there.")
        await settle { speaker.report.started }
        let scheduled = CapturingPlayerNode.scheduled.count
        XCTAssertGreaterThan(scheduled, 0)
        let engine = try? XCTUnwrap(seams.engines.last)

        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: began])
        await settle("the engine to be marked dead") { !speaker.keeping }
        XCTAssertTrue(speaker.holding, "both owners stand")
        XCTAssertTrue(speaker.speaking, "and the reply is not over")

        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        await settle("the keeper to come back") { speaker.keeping }
        XCTAssertEqual(CapturingPlayerNode.scheduled.count, scheduled * 2,
                       "what nobody heard was scheduled again")
        XCTAssertTrue(speaker.holding)
        speaker.stop()
    }

    /// A call still up when the end arrives: activation is refused, so nothing is rebuilt and the
    /// keeper stays down — but the hold is not dropped by that, it is dropped by its ceiling.
    func testARebuildThatCannotActivateLeavesTheHoldUpUntilTheCeiling() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center, ceiling: .seconds(2))
        speaker.awaitReply(readAloud: true)
        XCTAssertTrue(speaker.keeping)

        seams.activationError = Seams.Refused()
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: began])
        await settle("the engine to be marked dead") { !speaker.keeping }
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: ended])
        await settle("the refused activation") { seams.lines.contains("activate failed") }
        XCTAssertFalse(speaker.keeping, "nothing is built under a session that will not activate")
        XCTAssertTrue(speaker.holding, "and the refusal is not the reply's end")

        await settle("the ceiling to run out") { !speaker.holding }
    }

    /// The other owner's bound: a reply whose audio stopped and whose engine nothing rebuilt is
    /// over when the ceiling says so, so a hold cannot outlive its reply by more than that.
    func testAReplyThatStopsMakingProgressIsEndedByTheCeiling() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let held = HeldSecondSentence()
        let speaker = await self.speaker(seams, audio, center, engine: held, ceiling: .milliseconds(100))
        speaker.speak("One. Two.")
        await settle("the reply to be held up") { held.sentencesAsked == 2 }
        XCTAssertTrue(speaker.speaking)
        await settle("the ceiling to end it") { !speaker.speaking }
        XCTAssertFalse(speaker.holding, "no hold stands past the ceiling without progress")
        XCTAssertFalse(speaker.keeping)
        held.releaseTheSecondSentence()
    }

    /// Signing out mid-reply: the login goes, so the reply goes with it. What the chat calls is
    /// `stop`, and a reply that had begun must not carry on reading for an account that is gone,
    /// nor leave `.speaking` standing until a drain nobody is waiting for.
    func testStoppingMidReplyEndsTheReplyAndBothHolds() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let held = HeldVoice()
        let speaker = await self.speaker(seams, audio, center, engine: held)
        speaker.awaitReply(readAloud: true)
        speaker.speak("Hello there.")
        await settle("the reply to start") { speaker.report.started }
        XCTAssertTrue(speaker.speaking)
        XCTAssertTrue(speaker.holding)

        speaker.stop()

        XCTAssertFalse(speaker.speaking, "the reply is over")
        XCTAssertFalse(speaker.holding, "and neither owner is still holding the process open")
        XCTAssertFalse(speaker.keeping)
        // The frame that was in flight belongs to a reply nobody is hearing.
        held.releaseTheHeldFrame()
        await settle("the held frame") { held.yieldedTheHeldFrame }
        await drain()
        XCTAssertEqual(CapturingPlayerNode.scheduled.count, 1, "nothing was queued after the stop")
        XCTAssertFalse(speaker.holding)
    }

    /// A reset takes the engine, so it takes the keeper too; both owners go with the reply.
    func testAResetWhileAHoldStandsDropsBothOwnersAndTheKeeper() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = await self.speaker(seams, audio, center)
        speaker.awaitReply(readAloud: true)
        speaker.speak("Hello there.")
        await settle { speaker.report.started }
        XCTAssertTrue(speaker.keeping)
        center.post(name: reset, object: nil)
        await settle("the reply to end") { !speaker.speaking }
        XCTAssertFalse(speaker.holding, "both owners let go")
        XCTAssertFalse(speaker.keeping, "and the keeper went with the engine")
    }

    // MARK: PlayQueue


    /// The category flipping as the phone locks, or a route change: the engine stops and posts a
    /// configuration change, taking what was scheduled on its node with it. What had not been
    /// heard is put back, in order, on a fresh engine over a session activated first.
    func testAConfigurationChangeRebuildsTheQueueAndReschedulesWhatWasNotHeard() async throws {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let queue = PlayQueue(makeEngine: { seams.makePlayEngine(rate: Voice.rate) }, center: center)
        queue.ensureActive = { try audio.ensureActive() }
        CapturingPlayerNode.scheduled = []
        try queue.play(toneFrame(0.1), rate: Voice.rate)
        try queue.play(toneFrame(0.2), rate: Voice.rate)
        XCTAssertEqual(CapturingPlayerNode.scheduled.count, 2)
        let engine = try XCTUnwrap(seams.engines.last)
        seams.forget()

        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        await settle("the rebuild") { queue.rescheduled != nil }
        XCTAssertEqual(queue.rescheduled, 2, "both buffers were still owed")
        XCTAssertEqual(seams.lines, ["activate ok", "engine made"],
                       "the session is active before the new engine exists")
        XCTAssertEqual(seams.engines.count, 2, "the dead engine is not reused")
        XCTAssertEqual(CapturingPlayerNode.scheduled.count, 4,
                       "and what was not heard was scheduled again, and nothing else")
        XCTAssertFalse(queue.isIdle, "the same two buffers are owed, not four")
        XCTAssertFalse(queue.keeping, "no hold stood, so no keeper came back")
    }

    /// The buffers the dead node discards fire their completions as if they had played. Under a
    /// new epoch they move nothing: after the rebuild the frame is owed on the new engine and
    /// nothing has announced a drain, so a reply is not ended by the engine it lost.
    func testTheStaleCompletionsOfARebuildMoveTheCountNowhere() async throws {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let queue = PlayQueue(makeEngine: { seams.makePlayEngine(rate: Voice.rate) }, center: center)
        queue.ensureActive = { try audio.ensureActive() }
        let drained = Drains()
        queue.onDrained = { drained.count() }
        try queue.play(toneFrame(0.1), rate: Voice.rate)
        let engine = try XCTUnwrap(seams.engines.last)

        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        await settle("the rebuild") { queue.rescheduled != nil }
        await drain()
        XCTAssertEqual(drained.value, 0, "the discarded buffer's completion drained nothing")
        XCTAssertFalse(queue.isIdle, "the frame is still owed on the new engine")
    }

    /// A hold that stood through the rebuild is still standing after it, on the new engine.
    func testARebuildBringsTheKeeperBackWhenAHoldStands() async throws {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let queue = PlayQueue(makeEngine: { seams.makePlayEngine(rate: Voice.rate) }, center: center)
        queue.ensureActive = { try audio.ensureActive() }
        queue.hold(true)
        XCTAssertTrue(queue.keeping)
        let engine = try XCTUnwrap(seams.engines.last)

        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        await settle("the rebuild") { queue.rescheduled != nil }
        XCTAssertEqual(queue.rescheduled, 0, "nothing was owed")
        XCTAssertTrue(queue.keeping, "the silence came back with the engine")
        XCTAssertEqual(queue.keeperTransitions, ["playing", "stopped", "playing"])
        queue.hold(false)
    }

    /// One engine's configuration change is not another's: a queue told about a change in the
    /// microphone's engine rebuilds nothing.
    func testAConfigurationChangeForAnotherEngineChangesNothing() async throws {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let queue = PlayQueue(makeEngine: { seams.makePlayEngine(rate: Voice.rate) }, center: center)
        queue.ensureActive = { try audio.ensureActive() }
        try queue.play(toneFrame(0.1), rate: Voice.rate)
        seams.forget()
        let somebodyElse = AVAudioEngine()

        center.post(name: .AVAudioEngineConfigurationChange, object: somebodyElse)
        await drain()
        XCTAssertNil(queue.rescheduled, "nothing was rebuilt")
        XCTAssertEqual(seams.lines, [])
        XCTAssertEqual(seams.engines.count, 1)
    }

    func testAResetQueueBuildsANewEngineAndNewNodesOnTheNextPlay() throws {
        var built = 0
        let rate = 24_000
        // Offline manual rendering: the engine starts and the node plays without an audio device.
        let queue = PlayQueue(makeEngine: {
            built += 1
            let engine = AVAudioEngine()
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)!
            try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
            return engine
        })
        let clip = [Float](repeating: 0.1, count: 480)
        try queue.play(clip, rate: rate)
        try queue.play(clip, rate: rate)
        XCTAssertEqual(built, 1, "the engine is kept between clips")
        let node = try XCTUnwrap(queue.node)
        let timePitch = try XCTUnwrap(queue.timePitch)
        queue.reset()
        XCTAssertNil(queue.node, "a node cannot be attached to a second engine")
        XCTAssertNil(queue.timePitch)
        try queue.play(clip, rate: rate)
        XCTAssertEqual(built, 2)
        XCTAssertFalse(queue.node === node, "a new player")
        XCTAssertFalse(queue.timePitch === timePitch, "a new time-pitch unit")
    }
}
