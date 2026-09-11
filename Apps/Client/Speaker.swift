#if os(iOS)
import AVFoundation
import Observation

/// Reads a reply aloud. Speaking is foreground work: synthesis submits GPU commands and iOS kills
/// a backgrounded process that does, so the scene stops it on leaving the foreground. Pressing
/// the microphone stops it too, so the mic does not hear the speaker.
///
/// Two voices. When the `Voice` (Kokoro, on the device) is resident and the scene is active, the
/// reply is cut into sentences, each synthesised behind the one before and played the moment it
/// exists, so what a listener waits for is the first sentence rather than the reply. Otherwise
/// the reply goes to `AVSpeechSynthesizer`. The choice is made at `speak` and kept for the reply.
///
/// Every `speak` is a generation. A clip that lands after a `stop`, or a delegate callback for
/// an earlier utterance, belongs to no reply and changes nothing.
@MainActor
@Observable
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var speaking = false

    let voice: Voice
    private let audio: AudioSession
    private let synthesizer = AVSpeechSynthesizer()
    private let queue = PlayQueue()
    /// The utterance being read; a delegate callback for any other is an old one's and is ignored,
    /// so stopping A to say B does not drop B's claim when A's cancellation lands.
    private var current: AVSpeechUtterance?
    /// Counts replies on the voice's path. A forward pass in flight does not notice a
    /// cancellation, so a clip carrying an older number is made and dropped.
    private var generation = 0
    /// The tail of the synthesis chain: each sentence waits on the one in front of it, which is
    /// what keeps a reply in the order it was written though the clips are made one at a time.
    private var chain: Task<Void, Never>?
    /// Sentences of the current reply not yet made.
    private var making = 0
    /// True while the scene is active; the scene sets it. A reply that starts while it is false
    /// goes to `AVSpeechSynthesizer`, since the voice is Metal work.
    var foreground = true

    init(audio: AudioSession, voice: Voice = Voice()) {
        self.audio = audio
        self.voice = voice
        super.init()
        synthesizer.delegate = self
        queue.onDrained = { [weak self] in Task { @MainActor in self?.drained() } }
    }

    /// Loads the voice's model, downloading it on the first run. Called on the foreground so it
    /// is resident by the first reply; idempotent.
    func prepare() { voice.prepare() }

    func speak(_ text: String) {
        stop()
        speaking = true
        audio.wantScreenAwake(true, for: .speaking)
        if voice.ready, foreground {
            speakLocally(text)
        } else {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: Locale.current.identifier)
                ?? AVSpeechSynthesisVoice(language: "en-GB")
            current = utterance
            synthesizer.speak(utterance)
        }
    }

    func stop() {
        current = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        generation += 1
        chain = nil
        making = 0
        queue.stop()
        done()
    }

    /// The reply on the voice's path: one sentence at a time, each synthesised behind the one
    /// before and queued for playback as soon as it exists. A sentence the voice fails on is
    /// skipped rather than ending the reply.
    private func speakLocally(_ text: String) {
        let sentences = Self.sentences(of: text)
        guard !sentences.isEmpty else { done(); return }
        let mine = generation
        making = sentences.count
        for sentence in sentences {
            let previous = chain
            chain = Task { [weak self] in
                await previous?.value
                guard let self, self.generation == mine else { return }
                defer { if self.generation == mine { self.made() } }
                guard self.foreground else { return }
                do {
                    let clip = try await self.voice.synthesise(sentence)
                    guard self.generation == mine else { return }
                    try self.queue.play(clip.samples, rate: clip.rate)
                } catch {}
            }
        }
    }

    /// One sentence is made, played or failed. The reply is over when nothing is left to make
    /// and nothing is left to hear; both halves have to agree, since the queue drains between
    /// two sentences and the last sentence is made while the queue is still full.
    private func made() {
        making -= 1
        if making == 0, queue.isIdle { done() }
    }

    private func drained() {
        if making == 0 { done() }
    }

    /// The cut: sentence-final punctuation followed by whitespace, or a line break. Deliberately
    /// simple, because a cutter nobody can predict makes the same reply sound different twice.
    static func sentences(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            if character.isNewline || (character.isWhitespace && current.last.map { ".!?".contains($0) } == true) {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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

/// Whatever the voice has made, in the order it was made, on one player node. A player node
/// with nothing scheduled renders silence rather than stopping and picks up the moment a buffer
/// arrives, so a sentence appended behind a playing one is seamless and one appended into an
/// empty queue simply starts talking.
final class PlayQueue: @unchecked Sendable {
    /// Fires, on the audio thread, when every scheduled buffer has been heard.
    var onDrained: (@Sendable () -> Void)?

    private var engine: AVAudioEngine?
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    private let lock = NSLock()
    private var pending = 0
    /// Bumped by `stop`. Stopping the node fires the completion of every buffer it discards,
    /// and without this the count would run negative and the queue never read as drained.
    private var epoch = 0

    var isIdle: Bool { lock.withLock { pending == 0 } }

    /// The engine is built on the first clip, because the sample rate is the synthesiser's to
    /// report, and left running between clips so no sentence after the first pays for a route.
    func play(_ samples: [Float], rate: Int) throws {
        guard !samples.isEmpty else { return }
        if engine == nil {
            guard let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate),
                                        channels: 1, interleaved: false) else { throw VoiceError.noPlayer }
            let e = AVAudioEngine()
            e.attach(node)
            e.connect(node, to: e.mainMixerNode, format: f)
            engine = e
            format = f
        }
        guard let engine, let format, format.sampleRate == Double(rate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw VoiceError.noPlayer }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        if !node.isPlaying { node.play() }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let era: Int = lock.withLock {
            pending += 1
            return epoch
        }
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            let done: Bool = self.lock.withLock {
                guard era == self.epoch else { return false }
                self.pending -= 1
                return self.pending == 0
            }
            if done { self.onDrained?() }
        }
    }

    /// Cuts what is playing and drops everything behind it.
    func stop() {
        lock.withLock {
            pending = 0
            epoch += 1
        }
        node.stop()
    }
}
#endif
