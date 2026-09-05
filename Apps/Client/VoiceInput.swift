#if os(iOS)
import AVFoundation
import Observation
import Speech

/// Push to talk: speech to text from the microphone between a press and a release, on the device
/// where it can be. One object for the whole app, and one gate on its microphone, enforced: a
/// surface that presses while another holds it is refused, because two gates on one input answer
/// the same utterance twice. Both permissions are asked at the first press and nowhere earlier.
@MainActor
@Observable
final class VoiceInput {
    enum Gate: Hashable { case firstRun, chat }

    private(set) var listening = false
    /// What has been recognised so far, as it comes.
    private(set) var text = ""
    private(set) var denied = false
    private(set) var owner: Gate?
    /// True when recognition ran on the device; false when it went to Apple's servers.
    private(set) var onDevice = false

    private let audio: AudioSession
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Set when the recogniser has said its last word for this press.
    private var finalArrived = false

    init(audio: AudioSession) {
        self.audio = audio
    }

    /// Starts listening for `gate`. False, and nothing changed, when another gate holds the
    /// microphone or a permission is denied.
    func begin(as gate: Gate) async -> Bool {
        if listening { return owner == gate }
        guard await AVAudioApplication.requestRecordPermission() else { denied = true; return false }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard speech == .authorized, let recognizer, recognizer.isAvailable else { denied = true; return false }
        denied = false
        text = ""
        finalArrived = false
        audio.wantRecord(true, for: gate == .chat ? .chat : .firstRun)
        do {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            onDevice = recognizer.supportsOnDeviceRecognition
            request.requiresOnDeviceRecognition = onDevice
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            // A dead input format means the session is playback-only right now; installTap raises
            // an uncatchable exception on it, so refuse here and the next press works.
            guard format.sampleRate > 0, format.channelCount > 0 else { throw InputUnavailable() }
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            engine.prepare()
            try engine.start()
            owner = gate
            listening = true
            audio.wantScreenAwake(true, for: .listening)
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.text = result.bestTranscription.formattedString }
                    if result?.isFinal == true { self.finalArrived = true }
                    if error != nil { self.finalArrived = true; self.finish() }
                }
            }
            return true
        } catch {
            tearDown()
            audio.wantRecord(false, for: gate == .chat ? .chat : .firstRun)
            return false
        }
    }

    /// Stops listening and returns what was said, once the recogniser has said its last word or
    /// a second has passed. Empty when nothing was heard.
    func end() async -> String {
        guard listening else { return text }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        let deadline = Date().addingTimeInterval(1)
        while !finalArrived, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let heard = text
        finish()
        return heard
    }

    /// Stops listening and drops what was heard.
    func cancel() {
        text = ""
        finish()
    }

    private func finish() {
        guard listening || task != nil else { return }
        let gate = owner
        tearDown()
        if let gate { audio.wantRecord(false, for: gate == .chat ? .chat : .firstRun) }
    }

    /// Safe at any point, including after a start that never got going: the tap comes off
    /// whether or not the engine ran, so the next start does not install a second one.
    private func tearDown() {
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        owner = nil
        audio.wantScreenAwake(false, for: .listening)
    }

    private struct InputUnavailable: Error {}
}
#endif
