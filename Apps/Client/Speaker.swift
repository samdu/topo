#if os(iOS)
import AVFoundation
import Observation

/// Reads a reply aloud. Speaking is foreground work: synthesis submits GPU commands and iOS kills
/// a backgrounded process that does, so the scene stops it on leaving the foreground. Pressing
/// the microphone stops it too, so the mic does not hear the speaker.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var speaking = false

    private let audio: AudioSession
    private let synthesizer = AVSpeechSynthesizer()
    /// The utterance being read; a delegate callback for any other is an old one's and is ignored,
    /// so stopping A to say B does not drop B's claim when A's cancellation lands.
    private var current: AVSpeechUtterance?

    init(audio: AudioSession) {
        self.audio = audio
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
            ?? AVSpeechSynthesisVoice(language: "en-GB")
        current = utterance
        speaking = true
        audio.wantScreenAwake(true, for: .speaking)
        synthesizer.speak(utterance)
    }

    func stop() {
        current = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        done()
    }

    private func done(_ utteranceID: ObjectIdentifier? = nil) {
        if let utteranceID, let current, utteranceID != ObjectIdentifier(current) { return }
        current = nil
        speaking = false
        audio.wantScreenAwake(false, for: .speaking)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.done(id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.done(id) }
    }
}
#endif
