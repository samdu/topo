#if os(iOS)
import AVFoundation
import Observation
import Speech

/// Push to talk: speech to text from the microphone between a press and a release, on the device
/// where it can be. Hold to talk and release to send; a tap (a press shorter than `tapLimit`)
/// opens the microphone until the next press. One object for the whole app, and one gate on its
/// microphone, enforced: a surface that presses while another holds it is refused, because two
/// gates on one input answer the same utterance twice; the two surfaces (first run, chat) are
/// never mounted together, and each cancels its own session on disappearing. Both permissions
/// are asked at the first press and nowhere earlier.
///
/// Every press is one session with a generation number. A release, a cancel, a late recogniser
/// callback or a second `end()` that belongs to another generation does nothing, so nothing said
/// in one session can become a turn in the next, a session cannot be ended twice, and a press
/// released while the permission prompts are up starts no microphone.
@MainActor
@Observable
final class VoiceInput {
    enum Gate: Hashable { case firstRun, chat }

    /// A press shorter than this is a tap: it opens the microphone until the next press.
    static let tapLimit: TimeInterval = 0.4
    /// How long a release waits for the recogniser's last word before sending what it has.
    static let finalWait: TimeInterval = 1

    private(set) var listening = false
    /// What has been recognised so far in this session, as it comes.
    private(set) var text = ""
    private(set) var denied = false
    private(set) var owner: Gate?
    /// True while the microphone stays open after a tap, until the next press.
    private(set) var handsFree = false
    /// True when recognition ran on the device; false when it went to Apple's servers.
    private(set) var onDevice = false
    /// Words a session heard before the recogniser ended it on its own (server recognition's
    /// one-minute cap in hands-free, a network or no-speech error), waiting for the owner to
    /// send them; `takeUnsent` hands them over. Nothing said is dropped for an error.
    private(set) var unsent: Unsent?

    struct Unsent: Equatable {
        var gate: Gate
        var text: String
    }

    private let audio: AudioSession
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Counts sessions; everything asynchronous checks it belongs to the current one.
    private var generation = 0
    /// True from the press until the microphone is running: the permission prompts, mainly.
    private var starting = false
    /// True from a release until the session is torn down: the wait for the last word.
    private var ending = false
    private var pressedAt: Date?
    private var finalArrived = false
    private var interruptionObserver: NSObjectProtocol?

    init(audio: AudioSession) {
        self.audio = audio
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            // A call or Siri took the session; whatever was being said is over. Only the start
            // of an interruption: iOS posts its end seconds later, by which time a new session
            // may be up and is not to be cancelled for it.
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor in self?.cancel() }
        }
    }

    /// The thumb comes down for `gate`. Ends a hands-free session and returns what it heard, to
    /// be sent; otherwise starts a session and returns nil. Nothing happens for a press while
    /// another gate holds the microphone, while a release is still waiting for the last word, or
    /// when a permission is denied.
    func pressDown(as gate: Gate) async -> String? {
        if listening, owner == gate, handsFree { return await end(as: gate) }
        guard !listening, !starting, !ending else { return nil }
        pressedAt = Date()
        await begin(as: gate)
        return nil
    }

    /// The thumb comes up for `gate`. A hold ends and returns what it heard, to be sent; a tap
    /// leaves the microphone open and returns nil. A release while the permission prompts are
    /// still up cancels the press, so no microphone is left open with nobody holding it.
    func pressUp(as gate: Gate) async -> String? {
        if starting, owner == gate {
            generation += 1
            starting = false
            owner = nil
            return nil
        }
        guard listening, owner == gate, !ending else { return nil }
        if let pressedAt, Date().timeIntervalSince(pressedAt) < Self.tapLimit, !handsFree {
            handsFree = true
            return nil
        }
        return await end(as: gate)
    }

    /// The words kept from a session the recogniser ended, once; nil when there are none.
    func takeUnsent(for gate: Gate) -> String? {
        guard let unsent, unsent.gate == gate else { return nil }
        self.unsent = nil
        return unsent.text
    }

    /// The recogniser ended the session on its own: the words it heard are kept for the owner
    /// to send, and the microphone is released as on a release.
    private func endedByRecogniser(_ gate: Gate) {
        let heard = text
        generation += 1
        text = ""
        tearDown()
        if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            unsent = Unsent(gate: gate, text: heard)
        }
    }

    /// Stops listening and drops what was heard. Any gate's session, or `gate`'s only.
    func cancel(_ gate: Gate? = nil) {
        if let gate, owner != gate { return }
        generation += 1
        text = ""
        tearDown()
    }

    private func begin(as gate: Gate) async {
        generation += 1
        let mine = generation
        starting = true
        owner = gate
        text = ""
        handsFree = false
        finalArrived = false
        defer { if generation == mine { starting = false } }
        guard await AVAudioApplication.requestRecordPermission() else { denied = true; owner = nil; return }
        let speech = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        // Released or cancelled while the prompts were up: start nothing.
        guard generation == mine else { return }
        guard speech == .authorized, let recognizer, recognizer.isAvailable else { denied = true; owner = nil; return }
        denied = false
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
            listening = true
            audio.wantScreenAwake(true, for: .listening)
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.generation == mine else { return }
                    if let result { self.text = result.bestTranscription.formattedString }
                    if result?.isFinal == true { self.finalArrived = true }
                    if error != nil {
                        self.finalArrived = true
                        if !self.ending { self.endedByRecogniser(gate) }
                    }
                }
            }
        } catch {
            owner = nil
            tearDown()
            audio.wantRecord(false, for: gate == .chat ? .chat : .firstRun)
        }
    }

    /// Ends the session and returns what was said, once the recogniser has said its last word or
    /// `finalWait` has passed; what arrives later belongs to no session. Empty when nothing was
    /// heard.
    private func end(as gate: Gate) async -> String {
        guard listening, owner == gate, !ending else { return "" }
        ending = true
        let mine = generation
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        let deadline = Date().addingTimeInterval(Self.finalWait)
        while !finalArrived, Date() < deadline, generation == mine {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard generation == mine else { ending = false; return "" }
        let heard = text
        generation += 1
        text = ""
        tearDown()
        ending = false
        return heard
    }

    /// Safe at any point, including after a start that never got going: the tap comes off
    /// whether or not the engine ran, so the next start does not install a second one.
    private func tearDown() {
        let gate = owner
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        listening = false
        starting = false
        ending = false
        handsFree = false
        owner = nil
        pressedAt = nil
        audio.wantScreenAwake(false, for: .listening)
        if let gate { audio.wantRecord(false, for: gate == .chat ? .chat : .firstRun) }
    }

    private struct InputUnavailable: Error {}
}
#endif
