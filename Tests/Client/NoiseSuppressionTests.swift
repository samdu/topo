import AVFoundation
import XCTest

@testable import Topo

/// Noise suppression is the input node's voice processing, set at the press from the setting as
/// it stands: before the formats are read, since it changes them, on an engine that is not
/// running, since it can be changed on no other, and a node that will not take it is a refusal.
/// The seams are `MediaServicesResetTests`'; the offline engine has no voice unit, so what is held
/// here is what the press asked for and when, and the unit itself is a device's to show.
@MainActor
final class NoiseSuppressionTests: XCTestCase {
    private func settle(_ what: String, until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }

    private func voiceInput(_ seams: Seams, defaults: UserDefaults, ready: Bool = true) async -> VoiceInput {
        await pair(seams, defaults: defaults, ready: ready).voice
    }

    private func pair(_ seams: Seams, defaults: UserDefaults, ready: Bool = true,
                      isActive: @escaping @MainActor () -> Bool = { true }) async -> (voice: VoiceInput, audio: AudioSession) {
        let ear = Ear(vocabulary: Vocabulary(defaults: defaults), engine: ScriptedEngine())
        if ready {
            let nowhere = URL(fileURLWithPath: "/dev/null")
            ear.load(parakeet: nowhere, ctc: nowhere)
            await settle("the ear is resident") { ear.ready }
        }
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure, isActive: isActive)
        let voice = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { seams.makeEngine() },
                               formats: { seams.readFormats($0) },
                               voiceProcessing: { try seams.process($0, $1) },
                               defaults: defaults)
        return (voice, audio)
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!
    }

    func testAPhoneNeverAskedSuppressesBeforeTheFormatsAreRead() async {
        let seams = Seams()
        let voice = await voiceInput(seams, defaults: defaults())
        voice.press(as: .chat, mine: 1)
        XCTAssertNil(voice.refusal)
        XCTAssertTrue(voice.listening)
        XCTAssertEqual(seams.processing.map(\.on), [true])
        XCTAssertEqual(seams.processing.map(\.formatReads), [0], "voice processing changes the formats, so it is set before they are read")
        XCTAssertEqual(seams.formatReads, 1, "and they are read once")
        voice.cancel()
    }

    /// The setting is read at each press, so a change — the toggle's or the mind's — is the next
    /// press's, and every press finds its engine stopped.
    func testEachPressAsksForTheSettingAsItStandsOnAStoppedEngine() async {
        let seams = Seams()
        let defaults = defaults()
        let voice = await voiceInput(seams, defaults: defaults)
        defaults.set(false, forKey: NoiseSuppression.key)
        voice.press(as: .chat, mine: 1)
        XCTAssertTrue(voice.listening)
        // Changed while the microphone is open: nothing is asked of a running engine.
        defaults.set(true, forKey: NoiseSuppression.key)
        XCTAssertEqual(seams.processing.map(\.on), [false])
        _ = await voice.end(as: .chat)
        voice.press(as: .chat, mine: voice.generation)
        XCTAssertTrue(voice.listening)
        XCTAssertEqual(seams.processing.map(\.on), [false, true])
        XCTAssertEqual(seams.processing.map(\.running), [false, false])
        XCTAssertEqual(seams.engines.count, 1, "the engine is kept between presses")
        voice.cancel()
    }

    /// A node that will not take the unit is a refusal in words, with no tap installed, no format
    /// read and the record claim handed back; the engine is dropped, and the next press builds one.
    func testANodeThatWillNotTakeItRefusesThePress() async {
        let seams = Seams()
        let voice = await voiceInput(seams, defaults: defaults())
        seams.processingError = Seams.Refused()
        voice.press(as: .chat, mine: 1)
        XCTAssertEqual(voice.refusal, "noise suppression did not turn on: \(Seams.Refused())")
        XCTAssertFalse(voice.listening)
        XCTAssertFalse(voice.tapped)
        XCTAssertNil(voice.owner)
        XCTAssertEqual(voice.sessions, 0)
        XCTAssertEqual(seams.formatReads, 0)
        XCTAssertEqual(seams.records.last, false, "the record claim is handed back")

        seams.processingError = nil
        voice.press(as: .chat, mine: voice.generation)
        XCTAssertTrue(voice.listening)
        XCTAssertEqual(seams.engines.count, 2, "the refused engine was dropped")
        voice.cancel()
    }

    /// The session's mode is the session's own: the record configuration is asked for with voice
    /// processing when the setting is on and without it when it is off, and a change of setting
    /// reconfigures before the unit is asked to follow, so the unit never makes a mode by itself
    /// and `default` comes back when it goes.
    func testTheSessionsModeChangesWithTheUnitAndBeforeIt() async {
        let seams = Seams()
        let defaults = defaults()
        let voice = await voiceInput(seams, defaults: defaults)
        voice.press(as: .chat, mine: 1)
        XCTAssertEqual(seams.records, [true])
        XCTAssertEqual(seams.modes, [true], "the record configuration is the voice processing one")
        _ = await voice.end(as: .chat)
        defaults.set(false, forKey: NoiseSuppression.key)
        seams.forget()
        voice.press(as: .chat, mine: voice.generation)
        XCTAssertTrue(voice.listening)
        XCTAssertEqual(seams.records, [true])
        XCTAssertEqual(seams.modes, [false], "off is the default mode, asked for by the session")
        XCTAssertEqual(seams.processing.map(\.on), [true, false])
        XCTAssertEqual(seams.processing.last?.configures, 1, "the session was configured before the unit was asked")
        voice.cancel()
    }

    /// While a hold stands the session is not reconfigured, so a setting changed under one waits,
    /// and the unit waits with it: a press there asks for the state the session is in.
    func testUnderAHoldTheUnitFollowsTheSessionAsItWasLeft() async {
        let seams = Seams()
        let defaults = defaults()
        let (voice, audio) = await pair(seams, defaults: defaults)
        audio.wantRecord(true, for: .warm)
        XCTAssertEqual(seams.modes, [true])
        audio.wantAlive(true, for: .speaking)
        defaults.set(false, forKey: NoiseSuppression.key)
        seams.forget()
        voice.press(as: .chat, mine: 1)
        XCTAssertTrue(voice.listening)
        XCTAssertEqual(seams.records, [], "nothing is reconfigured under a hold")
        XCTAssertEqual(seams.processing.map(\.on), [true], "the unit is asked for what the session is in")
        _ = await voice.end(as: .chat)
        audio.wantAlive(false, for: .speaking)
        XCTAssertEqual(seams.modes.last, false, "the change is applied when the last hold goes")
        voice.press(as: .chat, mine: voice.generation)
        XCTAssertEqual(seams.processing.map(\.on), [true, false])
        voice.cancel()
    }

    /// An open microphone keeps the session as a hold does: its engine is running on the mode
    /// its unit was made for, so a change that waited on a hold goes on waiting when that hold
    /// drops over it, and is applied when the microphone closes.
    func testAHoldDroppedOverAnOpenMicrophoneLeavesTheSessionUntilItCloses() async {
        let seams = Seams()
        let defaults = defaults()
        let (voice, audio) = await pair(seams, defaults: defaults)
        audio.wantRecord(true, for: .warm)
        audio.wantAlive(true, for: .awaitingReply("a turn"))
        defaults.set(false, forKey: NoiseSuppression.key)
        seams.forget()
        voice.press(as: .chat, mine: 1)
        XCTAssertTrue(voice.listening)
        XCTAssertEqual(seams.processing.map(\.on), [true])
        audio.wantAlive(false, for: .awaitingReply("a turn"))
        XCTAssertEqual(seams.records, [], "nothing is reconfigured under a running engine")
        XCTAssertTrue(audio.voiceProcessed, "the session is still in the mode the unit was made for")
        _ = await voice.end(as: .chat)
        XCTAssertEqual(seams.records, [true], "one configuration once the microphone has closed")
        XCTAssertEqual(seams.modes, [false])
        XCTAssertFalse(audio.voiceProcessed)
        voice.press(as: .chat, mine: voice.generation)
        XCTAssertEqual(seams.processing.map(\.on), [true, false])
        voice.cancel()
    }

    /// A release with the app away leaves what waited for the next audio path: nothing is
    /// configured from the background, and the next press configures before its unit is asked.
    func testAMicrophoneClosedWithTheAppAwayLeavesTheChangeToTheNextPress() async {
        let seams = Seams()
        let defaults = defaults()
        var active = true
        let (voice, audio) = await pair(seams, defaults: defaults, isActive: { active })
        audio.wantRecord(true, for: .warm)
        audio.wantAlive(true, for: .awaitingReply("a turn"))
        defaults.set(false, forKey: NoiseSuppression.key)
        voice.press(as: .chat, mine: 1)
        audio.wantAlive(false, for: .awaitingReply("a turn"))
        seams.forget()
        active = false
        _ = await voice.end(as: .chat)
        XCTAssertEqual(seams.records, [], "nothing is configured from the background")
        active = true
        voice.press(as: .chat, mine: voice.generation)
        XCTAssertEqual(seams.modes, [false])
        XCTAssertEqual(seams.processing.last?.on, false)
        voice.cancel()
    }

    func testAPressTheEarRefusesAsksForNone() async {
        let seams = Seams()
        let voice = await voiceInput(seams, defaults: defaults(), ready: false)
        voice.press(as: .chat, mine: 1)
        XCTAssertNotNil(voice.refusal)
        XCTAssertTrue(seams.processing.isEmpty)
    }
}
