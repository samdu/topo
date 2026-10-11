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
        let ear = Ear(vocabulary: Vocabulary(defaults: defaults), engine: ScriptedEngine())
        if ready {
            let nowhere = URL(fileURLWithPath: "/dev/null")
            ear.load(parakeet: nowhere, ctc: nowhere)
            await settle("the ear is resident") { ear.ready }
        }
        let center = NotificationCenter()
        return VoiceInput(audio: AudioSession(center: center, configure: seams.configure), ear: ear, center: center,
                          makeEngine: { seams.makeEngine() },
                          formats: { seams.readFormats($0) },
                          voiceProcessing: { try seams.process($0, $1) },
                          defaults: defaults)
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

    func testAPressTheEarRefusesAsksForNone() async {
        let seams = Seams()
        let voice = await voiceInput(seams, defaults: defaults(), ready: false)
        voice.press(as: .chat, mine: 1)
        XCTAssertNotNil(voice.refusal)
        XCTAssertTrue(seams.processing.isEmpty)
    }
}
