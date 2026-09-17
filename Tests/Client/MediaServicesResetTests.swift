import AVFoundation
import UIKit
import XCTest

@testable import Topo

/// The seams the audio paths are built from, all writing to one log so the order they ran in is
/// observed rather than inferred: the audio session's configure step, the engine factory, the
/// synthesiser factory, and the reader of the input node's two formats.
@MainActor
private final class Seams {
    /// What ran, in the order it ran.
    private(set) var lines: [String] = []
    /// The record flag each configure was asked for, which is how a released claim is seen.
    private(set) var records: [Bool] = []
    /// Set to make the configure step throw, as an activation refused behind Settings does.
    var activationError: Error?
    /// What the format reader reports. A live 48 kHz mono input by default.
    var client = VoiceInput.Format(rate: 48_000, channels: 1)
    var hardware = VoiceInput.Format(rate: 48_000, channels: 1)
    private(set) var engines: [AVAudioEngine] = []
    private(set) var synthesizers: [SilentSynthesizer] = []
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
    /// and takes a tap, on a host with no audio device at all.
    func makeEngine() -> AVAudioEngine {
        lines.append("engine made")
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        engines.append(engine)
        return engine
    }

    func readFormats(_ engine: AVAudioEngine) -> (client: VoiceInput.Format, hardware: VoiceInput.Format) {
        lines.append("formats read")
        formatReads += 1
        return (client, hardware)
    }

    func makeSynthesizer() -> AVSpeechSynthesizer {
        lines.append("synthesiser made")
        let synthesizer = SilentSynthesizer()
        synthesizers.append(synthesizer)
        return synthesizer
    }
}

/// A synthesiser that never makes a sound and so never calls its delegate back: the state a
/// reset that swallowed the callbacks leaves behind.
private final class SilentSynthesizer: AVSpeechSynthesizer {
    private(set) var spoken: [String] = []
    override func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance.speechString) }
}

/// Recovery from a media services reset, against notifications posted on a private centre and
/// engines, synthesisers and formats from injected seams. No real reset happens here: a simulator
/// cannot trigger one, and none of these tests reaches an audio device.
@MainActor
final class MediaServicesResetTests: XCTestCase {
    private let reset = AVAudioSession.mediaServicesWereResetNotification

    /// The observers hop to the main actor; a test waits for the state it expects.
    private func settle(until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    /// Lets the observers' main-actor hops run, for a test that expects nothing to change.
    private func drain() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    private func voiceInput(_ seams: Seams, _ audio: AudioSession, _ center: NotificationCenter) -> VoiceInput {
        VoiceInput(audio: audio, ear: Ear(engine: NoEngine()), center: center,
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
        let voice = voiceInput(seams, audio, center)
        await behindSettings(seams, audio, center)
        XCTAssertEqual(seams.engines.count, 0, "nothing is built in the handler")
        voice.press(as: .chat, local: true, mine: 1)
        XCTAssertEqual(seams.lines, ["activate ok", "engine made", "formats read"])
        XCTAssertNil(voice.refusal)
        XCTAssertTrue(voice.tapped, "the tap is installed only after all three")
        XCTAssertTrue(voice.listening)
        voice.cancel()
    }

    // MARK: VoiceInput — activation refused

    func testAPressWhoseSessionWillNotActivateBuildsNothingAndRefuses() {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = voiceInput(seams, audio, center)
        seams.activationError = Seams.Refused()
        voice.press(as: .chat, local: true, mine: 1)
        XCTAssertEqual(seams.engines.count, 0, "no engine is built under a dead session")
        XCTAssertEqual(seams.formatReads, 0, "no format is read from one either")
        XCTAssertFalse(voice.tapped)
        XCTAssertEqual(voice.refusal?.hasPrefix("the audio session did not activate:"), true)
        XCTAssertNil(voice.owner)
        XCTAssertFalse(voice.listening)
        XCTAssertEqual(seams.records.last, false, "the record claim is released")
        let tried = seams.lines.count
        voice.press(as: .chat, local: true, mine: 2)
        XCTAssertGreaterThan(seams.lines.count, tried, "the next press configures again")
        XCTAssertEqual(seams.engines.count, 0)
    }

    // MARK: VoiceInput — the input guard

    func testTheGuardRefusesEveryFormatInstallTapWouldRaiseOn() {
        let live = VoiceInput.Format(rate: 48_000, channels: 1)
        XCTAssertTrue(VoiceInput.inputIsUsable(client: live, hardware: live))
        for (name, client, hardware) in Self.deadInputs {
            XCTAssertFalse(VoiceInput.inputIsUsable(client: client, hardware: hardware), name)
        }
    }

    /// Every way the input node can be reported that `installTap` raises on.
    private static let deadInputs: [(String, VoiceInput.Format, VoiceInput.Format)] = {
        let live = VoiceInput.Format(rate: 48_000, channels: 1)
        return [
            ("client rate 0", VoiceInput.Format(rate: 0, channels: 1), live),
            ("client channels 0", VoiceInput.Format(rate: 48_000, channels: 0), live),
            ("hardware rate 0", live, VoiceInput.Format(rate: 0, channels: 1)),
            ("hardware channels 0", live, VoiceInput.Format(rate: 48_000, channels: 0)),
            ("rates differ", VoiceInput.Format(rate: 44_100, channels: 1), live),
        ]
    }()

    func testADeadInputInstallsNoTapAndDropsTheEngineAndTheSession() {
        for (name, client, hardware) in Self.deadInputs {
            let seams = Seams()
            let center = NotificationCenter()
            let audio = AudioSession(center: center, configure: seams.configure)
            let voice = voiceInput(seams, audio, center)
            audio.wantRecord(true, for: .warm)
            seams.forget()
            seams.client = client
            seams.hardware = hardware
            voice.press(as: .chat, local: true, mine: 1)
            XCTAssertFalse(voice.tapped, name)
            XCTAssertEqual(voice.refusal, VoiceInput.noInput, name)
            XCTAssertNil(voice.owner, name)
            XCTAssertFalse(voice.listening, name)
            XCTAssertEqual(seams.lines, ["engine made", "formats read"], name)
            // The next press finds neither the engine nor the session it just refused on.
            voice.press(as: .chat, local: true, mine: 2)
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
        let voice = voiceInput(seams, audio, center)
        audio.wantRecord(true, for: .warm)
        seams.forget()
        voice.press(as: .chat, local: true, mine: 1)
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
        voice.press(as: .chat, local: true, mine: 2)
        XCTAssertEqual(seams.engines.count, 2, "the next press builds one")
        voice.cancel()
    }

    func testATeardownWithNoTapDoesNotReadTheInput() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = voiceInput(seams, audio, center)
        voice.cancel()
        let began = AVAudioSession.InterruptionType.began.rawValue
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: began])
        await drain()
        XCTAssertEqual(seams.engines.count, 0, "a teardown with no press builds and reads nothing")
        XCTAssertFalse(voice.tapped)
    }

    // MARK: Speaker

    func testAReplyAfterAResetActivatesTheSessionBeforeItBuildsASynthesiser() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = Speaker(audio: audio, voice: Voice(), center: center,
                              makeSynthesizer: { seams.makeSynthesizer() })
        speaker.speak("Hello there.")
        XCTAssertEqual(seams.lines, ["activate ok", "synthesiser made"],
                       "with no voice model the synthesiser reads it")
        XCTAssertTrue(speaker.speaking)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        seams.activationError = Seams.Refused()
        center.post(name: reset, object: nil)
        await settle { !speaker.speaking && seams.lines.count == 3 }
        XCTAssertEqual(seams.lines.last, "activate failed")
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the speaking claim is released")
        seams.activationError = nil
        seams.forget()
        // No press anywhere: Say it again is what reactivates the session and rebuilds.
        speaker.speak("Again then.")
        XCTAssertEqual(seams.lines, ["activate ok", "synthesiser made"])
        XCTAssertEqual(seams.synthesizers.count, 2)
        XCTAssertEqual(seams.synthesizers.last?.spoken, ["Again then."])
        XCTAssertTrue(seams.synthesizers.last?.delegate === speaker, "the fresh synthesiser reports to the speaker")
        XCTAssertTrue(speaker.speaking)
        speaker.stop()
    }

    func testAResetBumpsTheGenerationSoAClipMadeBeforeItIsNeverPlayed() async {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = Speaker(audio: audio, voice: Voice(), center: center,
                              makeSynthesizer: { seams.makeSynthesizer() })
        speaker.speak("Hello there.")
        let before = speaker.generation
        center.post(name: reset, object: nil)
        await settle { speaker.generation != before }
    }

    func testAReplyWhoseSessionWillNotActivateSpeaksNothing() {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let speaker = Speaker(audio: audio, voice: Voice(), center: center,
                              makeSynthesizer: { seams.makeSynthesizer() })
        seams.activationError = Seams.Refused()
        speaker.speak("Hello there.")
        XCTAssertEqual(seams.synthesizers.count, 0, "no synthesiser is built under a dead session")
        XCTAssertFalse(speaker.speaking)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the speaking claim is released")
    }

    // MARK: PlayQueue

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
