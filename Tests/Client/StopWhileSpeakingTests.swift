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

    /// A speaker over a resident voice whose second frame is held back, so a reply it starts
    /// cannot end on its own under the test, and a microphone over a resident ear whose release
    /// hears `heard`, sharing one audio session. The microphone prompt answers yes, so a press
    /// goes through `pressDown` and `pressUp` as the chat's does.
    private func chat(heard: String = "") async -> (Speaker, VoiceInput, HeldVoice) {
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
                      engine: ScriptedEngine(bare: heard, boosted: heard))
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear to load") { ear.ready }
        let input = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) },
                               permission: { true })
        return (speaker, input, held)
    }

    /// Topo mid-reply: Say it again, which is `speak` with no turn behind it.
    private func startSpeaking(_ speaker: Speaker) async {
        XCTAssertTrue(speaker.speak("Paris is the capital. It is on the Seine."))
        await settle("the reply to start") { speaker.report.started }
        XCTAssertTrue(speaker.speaking)
    }

    private func speakingChat() async -> (Speaker, VoiceInput, HeldVoice) {
        let (speaker, voice, held) = await chat()
        await startSpeaking(speaker)
        return (speaker, voice, held)
    }

    /// A second and a half of tone at the ear's rate, as the tap would have delivered it.
    private func utterance(into sink: SampleSink) {
        let format = sink.format
        let frames = AVAudioFrameCount(format.sampleRate * 1.5)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData else { return XCTFail("no buffer at the ear's rate") }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { channel[0][frame] = 0.1 * Float(sin(Double(frame) * 0.05)) }
        sink.append(buffer)
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

    /// The press is what the button showed when the finger landed. Stop was showing; the reply
    /// ends before the gesture's task runs. The press is still a stop: nothing reaches
    /// `VoiceInput`, from the press or from its release.
    func testAStopPressedAsTheReplyEndsOpensNoTurn() async {
        let (speaker, voice, held) = await speakingChat()
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let showing = { Composer.MicState(voice, speaking: speaker.speaking) }

        let down = press.gesture(true, showing: showing, speaker: speaker, voice: voice) { sent.add($0) }
        // The reply ends between the finger landing and the task running.
        speaker.stop()
        await down.value
        XCTAssertEqual(voice.presses, 0, "a press on Stop reached VoiceInput because the reply ended first")
        XCTAssertNil(voice.owner)
        XCTAssertFalse(voice.listening)

        await press.gesture(false, showing: showing, speaker: speaker, voice: voice) { sent.add($0) }.value
        XCTAssertEqual(voice.releases, 0, "the release of a stop reached VoiceInput")
        XCTAssertEqual(sent.texts, [])
        XCTAssertFalse(speaker.speaking)
    }

    /// The other way round: the microphone was showing, and a reply begins before the task runs.
    /// The press is the microphone's — it stops that reply, so the mic does not hear it, and opens
    /// the session — and is not taken for a stop.
    func testAMicrophonePressedAsAReplyBeginsOpensTheMicrophone() async {
        let (speaker, voice, held) = await chat()
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let showing = { Composer.MicState(voice, speaking: speaker.speaking) }
        XCTAssertEqual(showing().appearance, .idle)

        let down = press.gesture(true, showing: showing, speaker: speaker, voice: voice) { _ in }
        // Say it again lands between the finger landing and the task running.
        XCTAssertTrue(speaker.speak("Paris is the capital. It is on the Seine."))
        await down.value
        XCTAssertEqual(voice.presses, 1, "a press on the microphone was taken for a stop")
        XCTAssertTrue(voice.listening, "the microphone opened")
        XCTAssertFalse(speaker.speaking, "the press stops the reply, so the mic does not hear it")
    }

    /// Hands free and Say it again: the chat's own open microphone keeps its waveform over a
    /// reply, and a press on it sends what was heard, as it would with Topo silent.
    func testAPressOnTheWaveformWhileSpeakingSendsWhatWasHeard() async {
        let (speaker, voice, held) = await chat(heard: "purple elephants")
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let showing = { Composer.MicState(voice, speaking: speaker.speaking) }

        // A tap opens the chat's microphone hands free.
        await press.gesture(true, showing: showing, speaker: speaker, voice: voice) { sent.add($0) }.value
        await press.gesture(false, showing: showing, speaker: speaker, voice: voice) { sent.add($0) }.value
        XCTAssertTrue(voice.handsFree, "the tap left the microphone open")
        XCTAssertEqual(showing().appearance, .handsFree)

        // Say it again starts while it is open, and the person goes on talking.
        await startSpeaking(speaker)
        utterance(into: voice.sink)
        XCTAssertEqual(showing().appearance, .handsFree, "the open microphone was turned into a stop")
        XCTAssertEqual(showing().label, "Listening; press to send")

        // The press on the waveform sends, and the release after it reaches nothing.
        await press.gesture(true, showing: showing, speaker: speaker, voice: voice) { sent.add($0) }.value
        await press.gesture(false, showing: showing, speaker: speaker, voice: voice) { sent.add($0) }.value
        XCTAssertEqual(sent.texts, ["purple elephants"], "what the open microphone heard was not sent")
        XCTAssertFalse(voice.listening)
        XCTAssertFalse(speaker.speaking, "the press stopped the reply")
        XCTAssertEqual(showing().appearance, .idle)
    }
}

/// What the chat was handed to send, in order.
@MainActor
private final class Sent {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}
