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
        let audio: AudioSession
        let center: NotificationCenter
        let latch: OpenLatch
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
        let latch = OpenLatch()
        EngineWatch.reset()
        CapturingInputNode.installed = nil
        let input = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: {
                                   if openTakes > 0 { Thread.sleep(forTimeInterval: openTakes) }
                                   latch.pass()
                                   return seams.makeEngine()
                               },
                               formats: { seams.readFormats($0) },
                               permission: permission ?? { true }, permitted: { permitted },
                               voiceProcessing: { try seams.process($0, $1) })
        speaker.microphoneOpen = { input.busy }
        MicrophoneWatch.start(input, speaker)
        return Rig(speaker: speaker, voice: input, seams: seams, audio: audio, center: center, latch: latch)
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

    // MARK: - The open, off the main actor

    /// The main actor goes on running while a half-second open is in flight: the gesture's events
    /// and the long press's verdict arrive on it. A ticker on the main actor never waits as long as
    /// the open takes.
    func testTheMainActorRunsWhileTheMicrophoneOpens() async {
        let rig = await rig(openTakes: 0.5)
        defer { rig.voice.cancel() }
        let press = MicPress()
        var ticks: [ContinuousClock.Instant] = []
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                ticks.append(.now)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        await press.gesture(true, drawn: rig.showing(), speaker: rig.speaker, voice: rig.voice) { _ in }?.value
        ticker.cancel()
        XCTAssertTrue(rig.voice.listening)
        let gaps = zip(ticks, ticks.dropFirst()).map { $1 - $0 }
        XCTAssertLessThan(gaps.max() ?? .zero, .milliseconds(250), "the main actor stopped for the open")
    }

    /// The open runs in its one safe order on the input's queue and not the main thread: the
    /// session made active first, then the engine, voice processing, the formats read once and the
    /// tap on the format the guard judged.
    func testTheOpenRunsInOrderOffTheMainThread() async {
        let rig = await rig()
        defer { rig.voice.cancel() }
        _ = await rig.voice.pressDown(as: .chat)
        XCTAssertTrue(rig.voice.listening)
        XCTAssertEqual(rig.seams.lines, ["activate ok", "engine made", "formats read"])
        XCTAssertEqual(rig.seams.offMain, [true, true, true], "a step of the open ran on the main thread")
        XCTAssertEqual(rig.seams.formatReads, 1)
        XCTAssertEqual(rig.seams.processing.map(\.formatReads), [0], "voice processing was set after the formats were read")
        XCTAssertTrue(CapturingInputNode.installed === rig.seams.lastClient, "the tap was not installed on the format the guard judged")
    }

    /// Starts a press and holds its open on the queue, with the microphone opening.
    private func opening(_ rig: Rig) async -> Task<String?, Never> {
        rig.latch.arm()
        let voice = rig.voice
        let speaker = rig.speaker
        // As the chat's press does: the speaker told before the press, and after its answer.
        speaker.microphoneOpening()
        let down = Task {
            let heard = await voice.pressDown(as: .chat)
            speaker.microphoneOpened(counted: true)
            return heard
        }
        await settle("the open held on the queue") { rig.latch.waiting && voice.opening }
        return down
    }

    /// A cancel while the open is in flight: it returns only once the engine the open started is
    /// stopped, and the open's answer reaches nothing.
    func testACancelWhileTheMicrophoneOpensStopsWhatTheOpenStarted() async {
        let rig = await rig()
        let down = await opening(rig)
        let latch = rig.latch
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { latch.open() }
        rig.voice.cancel()
        XCTAssertEqual(EngineWatch.starts, 1, "the cancel returned before the open it tore down had run")
        XCTAssertEqual(EngineWatch.running, 0, "the cancel returned with the engine still running")
        XCTAssertFalse(rig.voice.inputTapped)
        _ = await down.value
        XCTAssertFalse(rig.voice.listening)
        XCTAssertFalse(rig.voice.opening)
        XCTAssertEqual(rig.voice.sessions, 0)
        XCTAssertFalse(rig.voice.inputRunning)
    }

    /// An interruption's start while the open is in flight, on a press no conversation carries:
    /// the press is over, and nothing the open started runs.
    func testAnInterruptionWhileTheMicrophoneOpensEndsAPressNobodyCarries() async {
        let rig = await rig()
        rig.voice.carries = { false }
        let down = await opening(rig)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        let latch = rig.latch
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { latch.open() }
        _ = await down.value
        await settle("the interruption's handler") { !rig.voice.opening }
        XCTAssertFalse(rig.voice.listening, "the microphone opened across the interruption")
        XCTAssertFalse(rig.voice.suspended)
        XCTAssertEqual(EngineWatch.running, 0)
    }

    /// The same on a session the conversation carries: it is suspended as the open answers, its
    /// engine dropped, as an open one would be, and resumes on a fresh engine; the conversation
    /// is not ended for an interruption that landed while it opened.
    func testAnInterruptionWhileACarriedOpenIsInFlightSuspendsIt() async {
        let rig = await rig()
        rig.voice.carries = { true }
        let down = await opening(rig)
        rig.center.post(name: AVAudioSession.interruptionNotification, object: nil,
                        userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        let latch = rig.latch
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { latch.open() }
        _ = await down.value
        await settle("the interruption's handler") { rig.voice.suspended }
        XCTAssertTrue(rig.voice.listening, "a carried session was ended by an interruption while it opened")
        XCTAssertEqual(EngineWatch.running, 0, "an engine ran on across the interruption")
        XCTAssertFalse(rig.voice.opening)
        XCTAssertTrue(rig.voice.resume(), "the suspended session did not resume")
        XCTAssertEqual(EngineWatch.running, 1)
        rig.voice.cancel()
        XCTAssertEqual(EngineWatch.running, 0)
    }

    /// A hold released at once, as the open is handed to the queue (the release that queued
    /// behind a stall runs right then): the release's teardown is behind the open on the queue,
    /// so it returns with what the open started already stopped, and nothing is left running.
    func testAHoldReleasedAsTheOpenIsHandedOverStopsWhatItStarts() async {
        let rig = await rig()
        rig.latch.arm()
        let voice = rig.voice
        let down = Task { await voice.pressDown(as: .chat) }
        await settle("the open handed over") { voice.opening }
        let latch = rig.latch
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { latch.open() }
        _ = await voice.pressUp(as: .chat, held: true)
        XCTAssertEqual(EngineWatch.starts, 1, "the release returned before the open it tore down had run")
        XCTAssertEqual(EngineWatch.running, 0, "the release returned with the open's engine running")
        XCTAssertFalse(voice.inputTapped, "the release returned with the open's tap on")
        _ = await down.value
        XCTAssertFalse(voice.listening)
        XCTAssertFalse(voice.opening)
        XCTAssertEqual(EngineWatch.running, 0)
        XCTAssertEqual(voice.sessions, 0)
    }

    /// A conversation's reopen tells the speaker nothing but what `busy` says: a reply landing
    /// while its open is in flight waits for the microphone.
    func testAReplyLandingWhileAReopenOpensWaits() async {
        let rig = await rig()
        defer { rig.speaker.stop() }
        rig.latch.arm()
        let voice = rig.voice
        let reopened = Task { await voice.reopen(as: .chat) }
        await settle("the reopen's open held on the queue") { rig.latch.waiting && voice.opening }
        XCTAssertTrue(rig.speaker.speak("Paris is the capital.", answering: "earlier"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(rig.speaker.speaking, "the reply was read into the reopening microphone")
        rig.latch.open()
        let opened = await reopened.value
        XCTAssertTrue(opened)
        XCTAssertFalse(rig.speaker.speaking)
        rig.voice.cancel()
        await settle("the reply to be read once the microphone closed") { rig.speaker.report.started }
    }

    /// The call's placing while the open is in flight ends the press: the session is the
    /// system's from here, and an engine started on it is the call's defect. The cancel returns
    /// only once what the open started has stopped.
    func testACallPlacedWhileTheMicrophoneOpensEndsThePress() async {
        let rig = await rig()
        let down = await opening(rig)
        let latch = rig.latch
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { latch.open() }
        rig.voice.call(.placing)
        XCTAssertEqual(EngineWatch.starts, 1, "the placing returned before the open it tore down had run")
        XCTAssertEqual(EngineWatch.running, 0, "the placing returned with the engine still running")
        XCTAssertFalse(rig.voice.opening)
        _ = await down.value
        XCTAssertFalse(rig.voice.listening, "the microphone opened under the call's placing")
        XCTAssertEqual(rig.voice.sessions, 0)
        XCTAssertFalse(rig.voice.inputRunning)
    }

    /// A media services reset while the open is in flight: no handle is made on the dead server
    /// once the open sees it, and whatever it made is dropped; nothing listens.
    func testAResetWhileTheMicrophoneOpensLeavesNothingRunning() async {
        let rig = await rig()
        let down = await opening(rig)
        rig.center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        rig.latch.open()
        _ = await down.value
        await settle("the reset's handlers") { !rig.voice.opening }
        XCTAssertFalse(rig.voice.listening, "the microphone opened across a media services reset")
        XCTAssertNil(CapturingInputNode.installed, "the open installed its tap on the dead server")
        XCTAssertEqual(EngineWatch.running, 0)
        XCTAssertEqual(rig.voice.sessions, 0)
    }

    /// While the open is in flight the session is kept as for an open microphone: a change of
    /// voice processing waits and is applied once the microphone has closed.
    func testTheSessionIsNotReconfiguredUnderAnOpenInFlight() async {
        let rig = await rig()
        let down = await opening(rig)
        let configures = rig.seams.records.count
        rig.audio.wantVoiceProcessing(!rig.audio.voiceProcessed)
        XCTAssertEqual(rig.seams.records.count, configures, "the session was reconfigured under an open in flight")
        rig.latch.open()
        _ = await down.value
        XCTAssertTrue(rig.voice.listening)
        XCTAssertEqual(rig.seams.records.count, configures, "the session was reconfigured under the open microphone")
        rig.voice.cancel()
        XCTAssertGreaterThan(rig.seams.records.count, configures, "what waited was not applied at the close")
    }

    /// A reply landing while the open is in flight is not read into the opening microphone: it
    /// waits, and is read once the microphone has closed.
    func testAReplyLandingWhileTheMicrophoneOpensWaits() async {
        let rig = await rig()
        defer { rig.speaker.stop() }
        let down = await opening(rig)
        XCTAssertTrue(rig.speaker.speak("Paris is the capital.", answering: "earlier"))
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(rig.speaker.speaking, "the reply was read into the opening microphone")
        XCTAssertTrue(rig.speaker.waitingForMicrophone)
        rig.latch.open()
        _ = await down.value
        XCTAssertTrue(rig.voice.listening)
        XCTAssertFalse(rig.speaker.speaking)
        rig.voice.cancel()
        await settle("the reply to be read once the microphone closed") { rig.speaker.report.started }
    }
}

/// Holds the input's open on its queue until the test lets it go: `pass` is called from a seam
/// inside the open and waits there while armed.
final class OpenLatch: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = false
    private var reached = false
    func arm() { lock.withLock { armed = true } }
    var waiting: Bool { lock.withLock { reached } }
    func pass() {
        guard lock.withLock({ armed }) else { return }
        lock.withLock { reached = true }
        semaphore.wait()
    }
    func open() {
        let wasArmed = lock.withLock { () -> Bool in
            let was = armed
            armed = false
            return was
        }
        if wasArmed { semaphore.signal() }
    }
}
