import AVFoundation
import UIKit
import XCTest

@testable import Topo

/// The press's verdict is the gesture's (#703): the microphone opens as the thumb comes down, and
/// the release is a hold only when SwiftUI's long press fired before it (`MicPress.hold`), however
/// long the app took to open the microphone. Driven through `MicPress.gesture`, the chat's own path.
@MainActor
final class PressGestureTests: XCTestCase {
    private final class Sent {
        private(set) var texts: [String] = []
        func add(_ text: String) { texts.append(text) }
    }

    /// The microphone's answer held until the test gives it, with the microphone already allowed:
    /// the press waits on it with no prompt up, as on a phone the hop to the answer takes a moment.
    @MainActor private final class Answer {
        private var waiting: CheckedContinuation<Bool, Never>?
        private var given: Bool?
        private(set) var asked = false

        func ask() async -> Bool {
            asked = true
            if let given { return given }
            return await withCheckedContinuation { waiting = $0 }
        }

        func give(_ allowed: Bool = true) {
            given = allowed
            waiting?.resume(returning: allowed)
            waiting = nil
        }
    }

    private func settle(_ what: String, until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited ten seconds for \(what)")
    }

    @MainActor private struct Rig {
        let speaker: Speaker
        let voice: VoiceInput
        let seams: Seams
        func showing() -> Composer.MicState { Composer.MicState(voice, speaking: speaker.speaking) }
    }

    /// `openTakes` is how long making the input's engine takes, which is inside the open.
    private func rig(openTakes: TimeInterval = 0, permitted: Bool = true,
                     permission: (@MainActor () async -> Bool)? = nil) async -> Rig {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, setCategory: seams.setCategory,
                                 deactivate: seams.deactivate, isActive: { true })
        let voice = Voice(engine: HeldVoice())
        voice.load(folder: URL(fileURLWithPath: "/dev/null"))
        await settle("the voice") { voice.state == .ready }
        let speaker = Speaker(audio: audio, voice: voice, center: center,
                              makeEngine: { seams.makePlayEngine(rate: Voice.rate) })
        let ear = Ear(vocabulary: Vocabulary(defaults: UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!),
                      engine: ScriptedEngine(bare: "purple elephants", boosted: "purple elephants"))
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear") { ear.ready }
        let input = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: {
                                   if openTakes > 0 { Thread.sleep(forTimeInterval: openTakes) }
                                   return seams.makeEngine()
                               },
                               formats: { seams.readFormats($0) },
                               permission: permission ?? { true }, permitted: { permitted },
                               voiceProcessing: { try seams.process($0, $1) })
        speaker.microphoneOpen = { input.listening }
        return Rig(speaker: speaker, voice: input, seams: seams)
    }

    /// A second and a half of tone at the ear's rate.
    private func utterance(into sink: SampleSink) {
        let format = sink.format
        let frames = AVAudioFrameCount(format.sampleRate * 1.5)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData else { return XCTFail("no buffer at the ear's rate") }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { channel[0][frame] = 0.1 * Float(sin(Double(frame) * 0.05)) }
        sink.append(buffer)
    }

    /// The down and the up callbacks back to back, as a quick tap on the glass delivers them, over
    /// an open that takes half a second: a tap, so the microphone stays open hands-free.
    func testATapOverASlowOpenStaysATap() async {
        let rig = await rig(openTakes: 0.5)
        defer { rig.voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let down = press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }
        let up = press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }
        await down?.value
        await up?.value
        XCTAssertTrue(rig.voice.listening, "a quick tap over a 0.5 s open closed the microphone")
        XCTAssertTrue(rig.voice.handsFree, "a quick tap over a 0.5 s open was read as a hold")
        XCTAssertEqual(sent.texts, [])
    }

    /// The release's task run only after the down's has finished a half-second open, which is the
    /// order a main actor busy with the open runs them in: still a tap.
    func testATapWhoseReleaseRunsAfterASlowOpenStaysATap() async {
        let rig = await rig(openTakes: 0.5)
        defer { rig.voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        await press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        await press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        XCTAssertTrue(rig.voice.listening && rig.voice.handsFree, "a tap whose release ran after a 0.5 s open was read as a hold")
        XCTAssertEqual(sent.texts, [])
    }

    /// The long press fired, and the release comes straight after it in the app's time: a hold,
    /// which closes the microphone and sends what it heard, whatever the clock says.
    func testAHoldSendsHoweverSoonItsReleaseRuns() async {
        let rig = await rig()
        let press = MicPress()
        let sent = Sent()
        await press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        XCTAssertTrue(rig.voice.listening)
        utterance(into: rig.voice.sink)
        press.hold()
        await press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        XCTAssertFalse(rig.voice.listening, "a hold left the microphone open")
        XCTAssertEqual(sent.texts, ["purple elephants"])
    }

    /// The verdict is one press's: a hold recorded on one press is not the next press's, which is
    /// a tap unless its own long press fires.
    func testAHoldIsOnePressesVerdict() async {
        let rig = await rig()
        defer { rig.voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        await press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        utterance(into: rig.voice.sink)
        press.hold()
        await press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        XCTAssertEqual(sent.texts, ["purple elephants"])
        await press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        await press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        XCTAssertTrue(rig.voice.listening && rig.voice.handsFree, "the second press took the first's hold")
    }

    /// The thumb lifts before the microphone is open (the press still waiting on the microphone's
    /// answer, with no prompt up): a tap, so the microphone opens hands-free once it can.
    func testATapReleasedWhileTheMicrophoneOpensOpensItHandsFree() async {
        let answer = Answer()
        let rig = await rig(permission: { await answer.ask() })
        defer { answer.give(); rig.voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let down = press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }
        await settle("the press waiting on the microphone's answer") { answer.asked }
        await press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        XCTAssertFalse(rig.voice.listening)
        answer.give()
        await down?.value
        XCTAssertTrue(rig.voice.listening, "a tap released while the microphone opened was taken for a cancel")
        XCTAssertTrue(rig.voice.handsFree)
        XCTAssertEqual(sent.texts, [])
    }

    /// A hold whose thumb lifts before the microphone is open cancels the press: nothing listens.
    func testAHoldReleasedWhileTheMicrophoneOpensCancelsIt() async {
        let answer = Answer()
        let rig = await rig(permission: { await answer.ask() })
        defer { answer.give(); rig.voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let down = press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }
        await settle("the press waiting on the microphone's answer") { answer.asked }
        press.hold()
        await press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        answer.give()
        await down?.value
        XCTAssertFalse(rig.voice.listening, "a hold released before the microphone opened left it open")
        XCTAssertEqual(rig.voice.sessions, 0)
        XCTAssertEqual(sent.texts, [])
    }

    /// With the system's prompt up the alert takes the touch, so the release is no verdict of the
    /// thumb's: even a tap cancels the press, and allowing the microphone opens nothing.
    func testAReleaseWhileThePromptIsUpCancelsEvenATap() async {
        let answer = Answer()
        let rig = await rig(permitted: false, permission: { await answer.ask() })
        defer { answer.give(); rig.voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let down = press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }
        await settle("the prompt") { answer.asked }
        await press.gesture(false, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { sent.add($0) }?.value
        answer.give()
        await down?.value
        XCTAssertFalse(rig.voice.listening, "a release during the prompt opened the microphone")
        XCTAssertEqual(rig.voice.sessions, 0)
    }
}
