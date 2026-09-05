#if os(iOS)
import AVFoundation
import Observation
import Speech

/// Speech to text from the microphone. Both permissions are asked at the first press and nowhere
/// earlier; the transcript lands in `text` as it is recognised.
@MainActor
@Observable
final class Dictation {
    private(set) var listening = false
    private(set) var text = ""
    private(set) var denied = false

    private let engine = AVAudioEngine()
    private var recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func toggle() async {
        if listening { stop() } else { await start() }
    }

    private func start() async {
        guard await AVAudioApplication.requestRecordPermission() else { denied = true; return }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized, let recognizer, recognizer.isAvailable else { denied = true; return }
        denied = false
        text = ""
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            listening = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.text = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.stop() }
                }
            }
        } catch {
            stop()
        }
    }

    /// Safe to call at any point, including after a start that never got going: the tap comes
    /// off whether or not the engine ran, so the next start does not install a second one.
    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
#endif
