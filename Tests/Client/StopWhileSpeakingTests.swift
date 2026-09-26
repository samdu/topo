import AVFoundation
import UIKit
import XCTest

@testable import Topo

/// While Topo is reading a reply aloud the microphone is a stop button: a press ends the reply and
/// opens nothing, its release reaches no session, and once the reply is over the button is the
/// microphone again. The press is routed by `MicPress`, which is the chat's own path, over a real
/// `Speaker` and `VoiceInput` on the audio seams, so what is held is what a press on the glass does.
@MainActor
final class StopWhileSpeakingTests: XCTestCase {
    override func tearDown() {
        UIApplication.shared.isIdleTimerDisabled = false
        super.tearDown()
    }

    private func settle(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                        until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<12_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited two minutes for \(what)", file: file, line: line)
    }

    /// Lets any task a press started run, for a check that expects nothing to have happened.
    private func drain() async {
        try? await Task.sleep(for: .milliseconds(200))
    }

    /// A speaker in the middle of a reply (its second frame held back, so it cannot end on its
    /// own under the test) and a microphone over a resident ear, sharing one audio session.
    private func speakingChat() async -> (Speaker, VoiceInput, HeldVoice) {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let held = HeldVoice()
        let voice = Voice(engine: held)
        voice.load(base: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice to load") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) })
        let ear = Ear(vocabulary: Vocabulary(defaults: UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!),
                      engine: ScriptedEngine())
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear to load") { ear.ready }
        let input = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) })
        XCTAssertTrue(speaker.speak("Paris is the capital. It is on the Seine."))
        await settle("the reply to start") { speaker.report.started }
        XCTAssertTrue(speaker.speaking)
        return (speaker, input, held)
    }

    func testTheMicrophoneIsAStopButtonWhileTopoSpeaks() async {
        let (speaker, voice, held) = await speakingChat()
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let mic = Composer.MicState(voice, speaking: speaker.speaking)
        XCTAssertEqual(mic.appearance, .stop, "the glass draws the stop button while the reply is read")
        XCTAssertEqual(mic.label, "Stop speaking")
        XCTAssertFalse(mic.open, "a stop button is not an open microphone")
    }

    /// The press the issue is about: pressing during the reply stops it and starts no voice turn,
    /// and the release is that press's own, so it reaches no session either.
    func testAPressWhileSpeakingStopsTheReplyAndOpensNoTurn() async {
        let (speaker, voice, held) = await speakingChat()
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()

        // Each half of the gesture is its own task, as the chat hands them over.
        Task { _ = await press.handle(true, mic: Composer.MicState(voice, speaking: speaker.speaking),
                                      speaker: speaker, voice: voice) }
        await settle("the reply to stop") { !speaker.speaking }
        await drain()
        XCTAssertEqual(voice.presses, 0, "the press reached VoiceInput and began a session")
        XCTAssertNil(voice.owner, "a press while speaking left the microphone claimed")
        XCTAssertFalse(voice.listening)
        XCTAssertFalse(speaker.report.finished, "the reply was stopped, not finished")

        // The button is the microphone again as soon as the reply is gone, with the thumb still down.
        let after = Composer.MicState(voice, speaking: speaker.speaking)
        XCTAssertEqual(after.appearance, .idle)
        XCTAssertEqual(after.label, "Hold to talk")

        let heard = await press.handle(false, mic: after, speaker: speaker, voice: voice)
        XCTAssertNil(heard, "the release of a stop sent something")
        XCTAssertEqual(voice.releases, 0, "the release of a stop reached VoiceInput")
        XCTAssertEqual(voice.presses, 0)
        XCTAssertNil(voice.owner)
        XCTAssertEqual(Composer.MicState(voice, speaking: speaker.speaking).label, "Hold to talk")
    }
}
