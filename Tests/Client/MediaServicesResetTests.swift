import AVFoundation
import UIKit
import XCTest

@testable import Topo

/// Counts calls made through a seam.
@MainActor
private final class Counter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// An engine that counts reads of `inputNode`, the property that creates the hardware input on
/// its first read, so a test can hold that nothing outside a press reads it.
private final class InputCountingEngine: AVAudioEngine {
    private(set) var inputReads = 0
    override var inputNode: AVAudioInputNode {
        inputReads += 1
        return super.inputNode
    }
}

/// A synthesiser that never makes a sound and so never calls its delegate back: the state a
/// reset that swallowed the callbacks leaves behind.
private final class SilentSynthesizer: AVSpeechSynthesizer {
    private(set) var spoken: [String] = []
    override func speak(_ utterance: AVSpeechUtterance) { spoken.append(utterance.speechString) }
}

/// Recovery from a media services reset, against notifications posted on a private centre and
/// engines and synthesisers from injected factories. No real reset happens here: a simulator
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

    // MARK: AudioSession

    func testAResetAppliesTheClaimedRecordConfigurationAgain() async {
        let center = NotificationCenter()
        var applied: [Bool] = []
        let audio = AudioSession(center: center, configure: { applied.append($0) })
        audio.wantRecord(true, for: .chat)
        XCTAssertEqual(applied, [true])
        center.post(name: reset, object: nil)
        await settle { applied == [true, true] }
    }

    func testAResetLeavesANeverConfiguredSessionAlone() async {
        let center = NotificationCenter()
        var applied: [Bool] = []
        let audio = AudioSession(center: center, configure: { applied.append($0) })
        center.post(name: reset, object: nil)
        await drain()
        XCTAssertEqual(applied, [], "a reset does not activate a session nobody configured")
        withExtendedLifetime(audio) {}
    }

    // MARK: VoiceInput

    func testAResetCancelsThePressAndBuildsAFreshEngine() async {
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: { _ in })
        let built = Counter()
        var engines: [InputCountingEngine] = []
        let voice = VoiceInput(audio: audio, ear: Ear(engine: NoEngine()), center: center, makeEngine: {
            built.bump()
            let engine = InputCountingEngine()
            engines.append(engine)
            return engine
        })
        XCTAssertEqual(built.count, 1)
        // A listening claim stands in for a press: the cancel's teardown is what releases it.
        audio.wantScreenAwake(true, for: .listening)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        center.post(name: reset, object: nil)
        await settle { built.count == 2 }
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the press was torn down")
        XCTAssertNil(voice.owner)
        XCTAssertFalse(voice.listening)
        XCTAssertFalse(voice.handsFree)
        XCTAssertEqual(engines.map(\.inputReads), [0, 0], "no tap was installed, so no input was read")
    }

    func testATeardownWithNoTapDoesNotReadTheInput() async {
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: { _ in })
        let engine = InputCountingEngine()
        let voice = VoiceInput(audio: audio, ear: Ear(engine: NoEngine()), center: center, makeEngine: { engine })
        voice.cancel()
        let began = AVAudioSession.InterruptionType.began.rawValue
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: began])
        await drain()
        XCTAssertEqual(engine.inputReads, 0)
    }

    // MARK: Speaker

    func testAResetEndsTheReplyAndBuildsAFreshSynthesiser() async {
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: { _ in })
        var synthesizers: [SilentSynthesizer] = []
        let speaker = Speaker(audio: audio, voice: Voice(), center: center, makeSynthesizer: {
            let synthesizer = SilentSynthesizer()
            synthesizers.append(synthesizer)
            return synthesizer
        })
        speaker.speak("Hello there.")
        XCTAssertEqual(synthesizers.first?.spoken, ["Hello there."], "with no voice model the synthesiser reads it")
        XCTAssertTrue(speaker.speaking)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        center.post(name: reset, object: nil)
        await settle { synthesizers.count == 2 }
        XCTAssertFalse(speaker.speaking)
        XCTAssertFalse(UIApplication.shared.isIdleTimerDisabled, "the speaking claim is released")
        XCTAssertTrue(synthesizers.last?.delegate === speaker, "the fresh synthesiser reports to the speaker")
    }

    func testAResetQueueBuildsANewEngineOnTheNextPlay() throws {
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
        queue.reset()
        try queue.play(clip, rate: rate)
        XCTAssertEqual(built, 2)
    }
}
