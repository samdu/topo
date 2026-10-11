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
    /// goes through `pressDown` and `pressUp` as the chat's does. The speaker asks the microphone
    /// whether it is open, as the app wires the two.
    private func chat(heard: String = "",
                      permission: @escaping @MainActor () async -> Bool = { true }) async -> (Speaker, VoiceInput, HeldVoice) {
        let held = HeldVoice()
        let (speaker, input, _) = await chat(heard: heard, voice: held, permission: permission)
        return (speaker, input, held)
    }

    private func chat(heard: String, voice engine: any VoiceEngine,
                      permission: @escaping @MainActor () async -> Bool) async -> (Speaker, VoiceInput, Seams) {
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: { true })
        let voice = Voice(engine: engine)
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
                               permission: permission,
                               voiceProcessing: { try seams.process($0, $1) })
        speaker.microphoneOpen = { input.listening }
        return (speaker, input, seams)
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
    /// and the release is that press's own, so it reaches no session either. Both are decided in
    /// the gesture's callback: the reply is stopped before the callback returns, and the release
    /// of a stop spawns no task, so nothing a scheduler does can put it in front of its press.
    func testAPressWhileSpeakingStopsTheReplyAndOpensNoTurn() async {
        let (speaker, voice, held) = await speakingChat()
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let drawn = Composer.MicState(voice, speaking: speaker.speaking)
        XCTAssertEqual(drawn.appearance, .stop)

        // The press and its release, back to back, with nothing run in between.
        let down = press.gesture(true, drawn: drawn, speaker: speaker, voice: voice) { sent.add($0) }
        XCTAssertFalse(speaker.speaking, "the stop waited for a task instead of happening at the callback")
        let after = Composer.MicState(voice, speaking: speaker.speaking)
        let up = press.gesture(false, drawn: after, speaker: speaker, voice: voice) { sent.add($0) }
        XCTAssertNil(down, "the stop spawned a task")
        XCTAssertNil(up, "the release of a stop spawned a task that could reach pressUp ahead of its press")

        await up?.value
        await down?.value
        await drain()
        XCTAssertEqual(voice.presses, 0, "the press reached VoiceInput and began a session")
        XCTAssertEqual(voice.releases, 0, "the release of a stop reached VoiceInput")
        XCTAssertNil(voice.owner, "a press while speaking left the microphone claimed")
        XCTAssertFalse(voice.listening)
        XCTAssertFalse(speaker.report.finished, "the reply was stopped, not finished")
        XCTAssertEqual(sent.texts, [])
        // The button is the microphone again.
        XCTAssertEqual(after.appearance, .idle)
        XCTAssertEqual(Composer.MicState(voice, speaking: speaker.speaking).label, "Hold to talk")
    }

    /// The press is what the composer drew, not what the speaker says by the time the callback
    /// runs. Stop was drawn and the reply has ended since: the press is still a stop, and nothing
    /// reaches `VoiceInput`.
    func testAStopDrawnAsTheReplyEndsOpensNoTurn() async {
        let (speaker, voice, held) = await speakingChat()
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let drawn = Composer.MicState(voice, speaking: speaker.speaking)
        XCTAssertEqual(drawn.appearance, .stop)
        // The reply ends between the frame being drawn and the finger's callback.
        speaker.stop()

        await press.gesture(true, drawn: drawn, speaker: speaker, voice: voice) { sent.add($0) }?.value
        await drain()
        XCTAssertEqual(voice.presses, 0, "a press on the drawn Stop reached VoiceInput because the reply had ended")
        XCTAssertNil(voice.owner)
        XCTAssertFalse(voice.listening)

        let after = Composer.MicState(voice, speaking: speaker.speaking)
        await press.gesture(false, drawn: after, speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertEqual(voice.releases, 0, "the release of a stop reached VoiceInput")
        XCTAssertEqual(sent.texts, [])
    }

    /// The other way round: the microphone was drawn, and a reply began before the callback. The
    /// press is the microphone's — it stops that reply, so the mic does not hear it, and opens the
    /// session — and is not taken for a stop.
    func testAMicrophoneDrawnAsAReplyBeginsOpensTheMicrophone() async {
        let (speaker, voice, held) = await chat()
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let drawn = Composer.MicState(voice, speaking: speaker.speaking)
        XCTAssertEqual(drawn.appearance, .idle)
        // Say it again lands between the frame being drawn and the finger's callback.
        XCTAssertTrue(speaker.speak("Paris is the capital. It is on the Seine."))

        await press.gesture(true, drawn: drawn, speaker: speaker, voice: voice) { _ in }?.value
        XCTAssertEqual(voice.presses, 1, "a press on the drawn microphone was taken for a stop")
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
        await press.gesture(true, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        await press.gesture(false, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertTrue(voice.handsFree, "the tap left the microphone open")
        XCTAssertEqual(showing().appearance, .handsFree)

        // Say it again while it is open, and the person goes on talking. The reply waits for the
        // microphone rather than being read into it.
        XCTAssertTrue(speaker.speak("Paris is the capital. It is on the Seine."))
        utterance(into: voice.sink)
        XCTAssertFalse(speaker.speaking, "a reply was read into the open microphone")
        XCTAssertEqual(speaker.report.speaks, 0)
        XCTAssertEqual(showing().appearance, .handsFree, "the open microphone was turned into a stop")
        XCTAssertEqual(showing().label, "Listening; press to send")

        // The press on the waveform sends, then the reply is read and the button is Stop.
        await press.gesture(true, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertEqual(sent.texts, ["purple elephants"], "what the open microphone heard was not sent")
        XCTAssertFalse(voice.listening)
        await settle("the reply to start once the microphone closed") { speaker.report.started }
        XCTAssertTrue(speaker.speaking)
        XCTAssertEqual(showing().appearance, .stop)
        await press.gesture(false, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertEqual(voice.releases, 2, "the release after the sending press reaches VoiceInput, which ignores it")
        XCTAssertEqual(sent.texts, ["purple elephants"])
    }

    /// The blocker from review: a spoken reply landing while the person holds the microphone is
    /// not read into it. Nothing is spoken until the release; the release sends what was held,
    /// and then the reply is read, with the button as Stop.
    func testAReplyLandingWhileTheMicrophoneIsHeldWaitsForTheRelease() async {
        let (speaker, voice, held) = await chat(heard: "purple elephants")
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let showing = { Composer.MicState(voice, speaking: speaker.speaking) }

        // The thumb comes down and stays.
        await press.gesture(true, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertTrue(voice.listening)
        XCTAssertEqual(showing().appearance, .held)

        // The reply to an earlier spoken turn lands, as `Harness.onReply` hands it over.
        XCTAssertTrue(speaker.speak("Paris is the capital. It is on the Seine.", answering: "earlier"),
                      "the reply is taken, to be read once the microphone closes")
        utterance(into: voice.sink)
        await drain()
        XCTAssertFalse(speaker.speaking, "the reply was read into the held microphone")
        XCTAssertEqual(speaker.report.speaks, 0, "the reply reached the voice while the microphone was held")
        XCTAssertEqual(showing().appearance, .held)

        // A hold, not a tap: the release sends what was said.
        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        await press.gesture(false, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertEqual(sent.texts, ["purple elephants"], "the release did not send the recording")
        XCTAssertFalse(voice.listening)
        await settle("the reply to start once the microphone closed") { speaker.report.started }
        XCTAssertEqual(speaker.report.speaks, 1)
        XCTAssertTrue(speaker.speaking)
        XCTAssertEqual(showing().appearance, .stop)
    }

    /// Round four's blocker: the press has left the gesture but the microphone is not yet
    /// listening — `VoiceInput.begin` is waiting on the permission prompt — when a reply lands. It
    /// is not read: the microphone is opening from the press on, and the reply waits for the
    /// release like any other.
    func testAReplyLandingWhileTheMicrophoneIsOpeningWaitsForTheRelease() async {
        let prompt = Prompt()
        let (speaker, voice, held) = await chat(heard: "purple elephants", permission: { await prompt.ask() })
        defer { prompt.allow(); held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let showing = { Composer.MicState(voice, speaking: speaker.speaking) }

        let down = press.gesture(true, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }
        await settle("the prompt to be up") { prompt.up }
        XCTAssertFalse(voice.listening, "the microphone is still opening")

        // The reply lands while the prompt is up.
        speaker.speak("Paris is the capital. It is on the Seine.", answering: "earlier")
        await drain()
        XCTAssertFalse(speaker.speaking, "the reply was read while the microphone was opening")
        XCTAssertEqual(speaker.report.speaks, 0, "the reply reached the voice while the microphone was opening")

        // The prompt is answered, the microphone opens, and the reply still waits.
        prompt.allow()
        await down?.value
        XCTAssertTrue(voice.listening)
        utterance(into: voice.sink)
        await drain()
        XCTAssertFalse(speaker.speaking, "the reply was read into the open microphone")
        XCTAssertEqual(speaker.report.speaks, 0)

        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        await press.gesture(false, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertEqual(sent.texts, ["purple elephants"], "the release did not send the recording")
        await settle("the reply to start once the microphone closed") { speaker.report.started }
        XCTAssertEqual(speaker.report.speaks, 1)
        XCTAssertEqual(showing().appearance, .stop)
    }

    /// The reply that waited for the microphone, refused by the session at the release: it is
    /// not lost. It keeps waiting and its turn stays unsettled (so its spoken mark stands), and
    /// the next close reads it and settles it.
    func testAWaitingReplyTheSessionRefusesAtTheReleaseIsStillOwed() async {
        let held = HeldVoice()
        let (speaker, voice, seams) = await chat(heard: "purple elephants", voice: held, permission: { true })
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let settled = Sent()
        speaker.settled = { settled.add($0) }
        let showing = { Composer.MicState(voice, speaking: speaker.speaking) }

        await press.gesture(true, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertTrue(speaker.speak("Paris is the capital. It is on the Seine.", answering: "earlier"))
        XCTAssertTrue(speaker.waitingForMicrophone)
        XCTAssertEqual(settled.texts, [], "a reply still waiting settled its turn")

        // The play queue's engine will not start when the release comes to read the reply.
        seams.playEngineRefusals = 1
        utterance(into: voice.sink)
        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        await press.gesture(false, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertEqual(sent.texts, ["purple elephants"])
        XCTAssertFalse(speaker.speaking, "nothing renders, so nothing is read")
        XCTAssertTrue(speaker.waitingForMicrophone, "the refused reply was dropped")
        XCTAssertEqual(settled.texts, [], "the refused reply settled its turn, so it is owed nothing")

        // A wait stands for it now (the refusal's own engine is gone and the next one starts). The
        // next ordinary press keeps the reply and its wait; its release reads it, and only
        // then is its turn settled and its wait let go.
        XCTAssertTrue(speaker.awaitReply("earlier", readAloud: true).held)
        XCTAssertEqual(speaker.awaiting, ["earlier"])
        await press.gesture(true, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertTrue(speaker.waitingForMicrophone)
        XCTAssertEqual(speaker.awaiting, ["earlier"], "the press ended the wait of a reply still owed")
        utterance(into: voice.sink)
        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        await press.gesture(false, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        await settle("the reply to start") { speaker.report.started }
        XCTAssertFalse(speaker.waitingForMicrophone)
        XCTAssertEqual(settled.texts, ["earlier"])
        XCTAssertEqual(speaker.awaiting, [])
    }

    /// Round five's blocker: two spoken replies land while the microphone is open. The second
    /// replaces the first, and the first's wait goes with it, so no hold stands for a reply that
    /// will never be read. (In the chat the press that opened the microphone has already ended
    /// the waits; the waits here are taken after it, which the speaker allows.)
    func testAWaitingReplyReplacedByANewerOneLetsGoOfItsWait() async {
        let (speaker, voice, held) = await chat(heard: "purple elephants")
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let settled = Sent()
        speaker.settled = { settled.add($0) }
        let showing = { Composer.MicState(voice, speaking: speaker.speaking) }

        await press.gesture(true, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertTrue(voice.listening)
        XCTAssertTrue(speaker.awaitReply("one", readAloud: true).held)
        XCTAssertTrue(speaker.awaitReply("two", readAloud: true).held)
        XCTAssertEqual(speaker.awaiting, ["one", "two"])

        XCTAssertTrue(speaker.speak("Paris.", answering: "one"))
        XCTAssertEqual(speaker.awaiting, ["one", "two"], "a reply waiting for the microphone keeps its wait")
        XCTAssertTrue(speaker.speak("Rome.", answering: "two"))
        XCTAssertEqual(settled.texts, ["one"], "the replaced reply's turn is settled")
        XCTAssertEqual(speaker.awaiting, ["two"], "the replaced reply's wait still holds the process")

        try? await Task.sleep(for: .seconds(VoiceInput.tapLimit + 0.1))
        utterance(into: voice.sink)
        await press.gesture(false, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        await settle("the newer reply to start") { speaker.report.started }
        XCTAssertEqual(speaker.report.text, "Rome.")
        XCTAssertEqual(speaker.awaiting, [], "a wait outlived the reply it was for")
    }

    /// The keyboard closes a hands-free microphone with a reply waiting for it: nothing in the
    /// press path runs, and the reply is read all the same, by the app's watch on
    /// `VoiceInput.listening` (`MicrophoneWatch`), which is not a view and runs behind the lock.
    func testAReplyWaitingForAHandsFreeMicrophoneIsReadWhenTheKeyboardClosesIt() async {
        let (speaker, voice, held) = await chat(heard: "purple elephants")
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        MicrophoneWatch.start(voice, speaker)
        let press = MicPress()
        let sent = Sent()
        let showing = { Composer.MicState(voice, speaking: speaker.speaking) }

        await press.gesture(true, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        await press.gesture(false, drawn: showing(), speaker: speaker, voice: voice) { sent.add($0) }?.value
        XCTAssertTrue(voice.handsFree)
        XCTAssertTrue(speaker.speak("Paris is the capital. It is on the Seine.", answering: "earlier"))
        XCTAssertTrue(speaker.waitingForMicrophone)

        // What raising the keyboard does to a hands-free session (`ChatView`, `row.typing`).
        voice.cancel(.chat)
        XCTAssertFalse(voice.listening)
        await settle("the reply to be read once the keyboard closed the microphone") { speaker.report.started }
        XCTAssertFalse(speaker.waitingForMicrophone)
        XCTAssertEqual(sent.texts, [], "the keyboard sends nothing")
        XCTAssertEqual(showing().appearance, .stop)
    }

    /// A tap's two callbacks back to back, neither awaited before the other: the press reaches
    /// `pressDown` and the release `pressUp`, in that order, and the tap leaves the microphone
    /// open hands free with nothing sent and nothing taken for a stop.
    func testABackToBackTapOpensTheMicrophoneHandsFree() async {
        let (speaker, voice, held) = await chat()
        defer { held.releaseTheHeldFrame(); speaker.stop(); voice.cancel() }
        let press = MicPress()
        let sent = Sent()
        let drawn = Composer.MicState(voice, speaking: speaker.speaking)
        XCTAssertEqual(drawn.appearance, .idle)

        let down = press.gesture(true, drawn: drawn, speaker: speaker, voice: voice) { sent.add($0) }
        let up = press.gesture(false, drawn: drawn, speaker: speaker, voice: voice) { sent.add($0) }
        XCTAssertNotNil(down)
        XCTAssertNotNil(up)
        await down?.value
        await up?.value
        XCTAssertEqual(voice.presses, 1)
        XCTAssertEqual(voice.releases, 1)
        XCTAssertTrue(voice.listening, "the tap opened the microphone")
        XCTAssertTrue(voice.handsFree, "the release was taken for the end of a hold, or ran before the press")
        XCTAssertEqual(sent.texts, [])
        XCTAssertEqual(Composer.MicState(voice, speaking: speaker.speaking).appearance, .handsFree)
    }
}

/// A microphone prompt that stays up until the test answers it.
@MainActor
private final class Prompt {
    private var answer: CheckedContinuation<Bool, Never>?
    private(set) var up = false

    func ask() async -> Bool {
        await withCheckedContinuation { continuation in
            answer = continuation
            up = true
        }
    }

    func allow() {
        up = false
        answer?.resume(returning: true)
        answer = nil
    }
}

/// What the chat was handed to send, in order.
@MainActor
private final class Sent {
    private(set) var texts: [String] = []
    func add(_ text: String) { texts.append(text) }
}
