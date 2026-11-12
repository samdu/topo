import AVFoundation
import UIKit
import XCTest

@testable import Topo

/// Scratch for #703, not committed: a tap through `MicPress`, the chat's own path, over a press
/// whose open takes `openTakes` on the main actor.
@MainActor
final class Scratch703Tests: XCTestCase {
    private func settle(_ what: String, until condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "waited ten seconds for \(what)")
    }

    private func rig(openTakes: TimeInterval) async -> (Speaker, VoiceInput) {
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
                      engine: ScriptedEngine(bare: "", boosted: ""))
        let nowhere = URL(fileURLWithPath: "/dev/null")
        ear.load(parakeet: nowhere, ctc: nowhere)
        await settle("the ear") { ear.ready }
        let input = VoiceInput(audio: audio, ear: ear, center: center,
                               makeEngine: { Thread.sleep(forTimeInterval: openTakes); return seams.makeEngine() },
                               formats: { seams.readFormats($0) },
                               permission: { true }, permitted: { true },
                               voiceProcessing: { try seams.process($0, $1) })
        speaker.microphoneOpen = { input.listening }
        return (speaker, input)
    }

    /// The thumb down and up back to back, as a quick tap's two callbacks come.
    private func glassTap(openTakes: TimeInterval) async -> (listening: Bool, handsFree: Bool, took: TimeInterval) {
        let (speaker, voice) = await rig(openTakes: openTakes)
        let press = MicPress()
        let start = Date()
        let down = press.gesture(true, drawn: Composer.MicState(voice, speaking: false), speaker: speaker, voice: voice) { _ in }
        let up = press.gesture(false, drawn: Composer.MicState(voice, speaking: false), speaker: speaker, voice: voice) { _ in }
        await down?.value
        await up?.value
        let took = Date().timeIntervalSince(start)
        defer { voice.cancel() }
        print("[703] glass tap, open takes \(openTakes): listening \(voice.listening) handsFree \(voice.handsFree) presses \(voice.presses) sessions \(voice.sessions) refusal \(voice.refusal ?? "none") took \(took)")
        return (voice.listening, voice.handsFree, took)
    }

    /// The down's task run to its end, then the up: the order the main actor runs them in when
    /// the open blocks it (the release's callback cannot run until it is free).
    private func awaitedTap(openTakes: TimeInterval) async -> (listening: Bool, handsFree: Bool) {
        let (speaker, voice) = await rig(openTakes: openTakes)
        let press = MicPress()
        await press.gesture(true, drawn: Composer.MicState(voice, speaking: false), speaker: speaker, voice: voice) { _ in }?.value
        await press.gesture(false, drawn: Composer.MicState(voice, speaking: false), speaker: speaker, voice: voice) { _ in }?.value
        defer { voice.cancel() }
        print("[703] awaited tap, open takes \(openTakes): listening \(voice.listening) handsFree \(voice.handsFree) sessions \(voice.sessions)")
        return (voice.listening, voice.handsFree)
    }

    func testGlassTapFastOpen() async {
        let r = await glassTap(openTakes: 0)
        XCTAssertTrue(r.listening && r.handsFree)
    }

    func testGlassTapSlowOpen() async {
        let r = await glassTap(openTakes: 0.5)
        XCTAssertTrue(r.listening && r.handsFree, "a quick tap over a 0.5 s open was read as a hold")
    }

    func testAwaitedTapSlowOpen() async {
        let r = await awaitedTap(openTakes: 0.5)
        XCTAssertTrue(r.listening && r.handsFree, "a tap whose release ran after a 0.5 s open was read as a hold")
    }
}
