import AVFoundation
import XCTest

@testable import Topo

/// The ear's engine as these tests script it: it loads at once, and each decode returns what it
/// was told to or throws, which is the Parakeet pass failing on an utterance. `bare` is what a
/// caption glance hears, `boosted` what the release's decode hears.
struct ScriptedEngine: SpeechEngine {
    var bare: String? = ""
    var boosted: String? = ""

    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {}
    func rebuild(terms: [String], version: Int) async throws {}

    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String {
        guard let heard = boosted ? self.boosted : bare else {
            throw EarError.unavailable("the decode failed")
        }
        return heard
    }
}

/// An engine whose load never returns, which holds the ear at `loading`.
struct StallingEngine: SpeechEngine {
    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
        while true { try await Task.sleep(for: .seconds(3600)) }
    }
    func rebuild(terms: [String], version: Int) async throws {}
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String { "" }
}

/// An engine whose load waits to be let go, so a test sees the ear at `loading` and then ready.
final class LoadOnCue: SpeechEngine, @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)

    func finish() { done.signal() }

    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
        let done = done
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                done.wait()
                continuation.resume()
            }
        }
    }
    func rebuild(terms: [String], version: Int) async throws {}
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String { "" }
}

/// An engine whose load fails, which is the ear at `failed`.
struct BrokenEngine: SpeechEngine {
    static let why = "the models did not compile"
    func load(parakeet: URL, ctc: URL, onProgress: @escaping @Sendable (String) -> Void) async throws {
        throw EarError.unavailable(Self.why)
    }
    func rebuild(terms: [String], version: Int) async throws {}
    func transcribe(_ samples: [Float], boosted: Bool) async throws -> String { "" }
}

/// The phone has one ear. A press it cannot hear is refused with the ear's own words before
/// anything is claimed, and an utterance the ear fails on is answered with the caption rather
/// than dropped. The seams are `MediaServicesResetTests`': one log for the audio session's
/// configure step, the engine factory and the format reader, so what a refused press did not
/// touch is observed rather than inferred.
@MainActor
final class PressRefusalTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "topo.tests.\(UUID().uuidString)")!
    }

    private func ear(_ engine: any SpeechEngine) -> Ear {
        Ear(vocabulary: Vocabulary(defaults: defaults()), engine: engine)
    }

    /// An ear loaded from nowhere over `engine`; the URLs reach no loader that reads them.
    private func loaded(_ engine: any SpeechEngine) -> Ear {
        let ear = ear(engine)
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        return ear
    }

    private func settle(_ what: String, until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }

    private func voiceInput(_ seams: Seams, _ audio: AudioSession, _ center: NotificationCenter,
                            ear: Ear) -> VoiceInput {
        VoiceInput(audio: audio, ear: ear, center: center,
                   makeEngine: { seams.makeEngine() },
                   formats: { seams.readFormats($0) })
    }

    /// A second of tone at the ear's rate, as the tap would have delivered it.
    private func utterance(into sink: SampleSink, seconds: Double = 1.5) {
        let format = sink.format
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData else { return XCTFail("no buffer at the ear's rate") }
        buffer.frameLength = frames
        for frame in 0..<Int(frames) { channel[0][frame] = 0.1 * Float(sin(Double(frame) * 0.05)) }
        sink.append(buffer)
    }

    // MARK: A press the ear cannot hear

    func testAPressIsRefusedWhileTheEarIsNotResidentAndTouchesNothing() async {
        let cold = ear(ScriptedEngine())
        let loading = loaded(StallingEngine())
        await settle("the ear is loading") { loading.state == .loading }
        let failed = loaded(BrokenEngine())
        await settle("the ear failed") { failed.state == .failed }

        for (name, ear) in [("cold", cold), ("loading", loading), ("failed", failed)] {
            let seams = Seams()
            let center = NotificationCenter()
            let audio = AudioSession(center: center, configure: seams.configure)
            let voice = voiceInput(seams, audio, center, ear: ear)
            voice.press(as: .chat, mine: 1)
            XCTAssertEqual(voice.refusal, ear.summary, "\(name): the refusal is the ear's own words")
            XCTAssertEqual(seams.lines, [], "\(name): the audio session and the engine are untouched")
            XCTAssertEqual(seams.records, [], "\(name): no record claim was made")
            XCTAssertEqual(seams.engines.count, 0, name)
            XCTAssertNil(voice.owner, name)
            XCTAssertFalse(voice.listening, name)
            XCTAssertFalse(voice.tapped, name)
            XCTAssertEqual(voice.sessions, 0, name)
        }
        XCTAssertEqual(failed.summary, "failed: \(BrokenEngine.why)", "the reason travels with the refusal")
    }

    func testAPressOnAResidentEarReachesTheEngine() async {
        let ear = loaded(ScriptedEngine())
        await settle("the ear is resident") { ear.ready }
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = voiceInput(seams, audio, center, ear: ear)
        voice.press(as: .chat, mine: 1)
        XCTAssertNil(voice.refusal)
        XCTAssertEqual(seams.lines, ["activate ok", "engine made", "formats read"])
        XCTAssertTrue(voice.tapped)
        XCTAssertTrue(voice.listening)
        voice.cancel()
    }

    /// The button dims from the state as it is, not from the last press: an ear that is loading
    /// has the microphone dimmed from launch, and the load finishing undims it with no press in
    /// between.
    func testTheMicrophoneReadsTheEarAsItIsRatherThanTheLastPress() async {
        let engine = LoadOnCue()
        let ear = loaded(engine)
        await settle("the ear is loading") { ear.state == .loading }
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = voiceInput(seams, audio, center, ear: ear)
        XCTAssertFalse(voice.canListen, "a loading ear dims the microphone before any press")
        XCTAssertNil(voice.refusal, "nothing has been pressed")
        engine.finish()
        await settle("the ear is resident") { ear.ready }
        XCTAssertTrue(voice.canListen, "the load finishing undims it, with no press in between")
    }

    func testADeniedMicrophoneDimsAResidentEar() async {
        let ear = loaded(ScriptedEngine())
        await settle("the ear is resident") { ear.ready }
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = voiceInput(seams, audio, center, ear: ear)
        XCTAssertTrue(voice.canListen)
        voice.microphoneDenied()
        XCTAssertFalse(voice.canListen, "a denied microphone dims the button whatever the ear is doing")
    }

    // MARK: A decode that throws

    func testAReleaseWhoseDecodeThrowsSendsTheCaption() async {
        let ear = loaded(ScriptedEngine(bare: "purple elephants", boosted: nil))
        await settle("the ear is resident") { ear.ready }
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = voiceInput(seams, audio, center, ear: ear)
        voice.press(as: .chat, mine: voice.generation)
        utterance(into: voice.sink)
        await settle("a glance captioned the utterance") { !voice.text.isEmpty }
        let heard = await voice.end(as: .chat)
        XCTAssertEqual(heard, "purple elephants", "the caption is sent when the decode throws")
        XCTAssertEqual(voice.capture.heard, "purple elephants")
        XCTAssertNotNil(voice.capture.recogniserError, "the diagnostics say why there was no decode")
    }

    func testAReleaseWhoseDecodeThrowsWithNoCaptionSendsNothing() async {
        let ear = loaded(ScriptedEngine(bare: nil, boosted: nil))
        await settle("the ear is resident") { ear.ready }
        let seams = Seams()
        let center = NotificationCenter()
        let audio = AudioSession(center: center, configure: seams.configure)
        let voice = voiceInput(seams, audio, center, ear: ear)
        voice.press(as: .chat, mine: voice.generation)
        utterance(into: voice.sink)
        let heard = await voice.end(as: .chat)
        XCTAssertEqual(heard, "", "nothing is invented for an utterance nothing was heard in")
        XCTAssertNotNil(voice.capture.recogniserError, "the diagnostics say why there was no decode")
    }
}
