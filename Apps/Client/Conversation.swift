#if os(iOS)
import Foundation
import Observation
import SwiftUI

/// An open microphone behind the lock is a call: with *Call for spoken replies* on, a hands-free
/// session on a spoken turn that is open as Topo leaves the front is carried into the call
/// (`SpokenCall`) rather than dropped. Topo keeps listening, ends each utterance itself when the
/// person stops speaking (`Endpoint`), sends it through the chat's own send, closes the
/// microphone while it reads the reply, and opens it again when the reading is done. The
/// conversation ends at a hang-up from the card, after `idle` with nothing said, when Topo comes
/// back to the front, or when the call is over by any other way; ending it lets the call go,
/// hands the session back, and lets the resident be frozen (`GuestLifecycle.conversing`).
///
/// One object for the app, started beside `MicrophoneWatch`, outside any view: behind the lock
/// nothing is drawn, so nothing it needs may live in a view's `onChange`.
@MainActor
@Observable
final class Conversation {
    /// Listening this long with nothing said ends the conversation. Counted only while the
    /// microphone listens with no wait standing and nothing being read.
    static let idle: Duration = .seconds(120)
    /// How often the detector is fed what has arrived.
    static let feedEvery: Duration = .milliseconds(256)

    private(set) var on = false

    @ObservationIgnored private let voice: VoiceInput
    @ObservationIgnored private let speaker: Speaker
    @ObservationIgnored private let endpoint: Endpoint
    @ObservationIgnored private let enabled: @MainActor () -> Bool
    @ObservationIgnored private let appActive: @MainActor () -> Bool
    @ObservationIgnored private let holding: @MainActor () -> Bool
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> Date

    /// The chat's send (`ChatView.sendSpoken`): the row, the one nonce, the wait and the mark.
    /// Installed where the chat appears and taken away where it goes; with none, nothing is
    /// carried.
    var send: (@MainActor (String) async -> Void)?
    /// The chat's answer to whether the open session's own destination is a send
    /// (`Dictation.sends`): dictation into the draft is never carried.
    var sends: (@MainActor () -> Bool)?
    /// Told the conversation's one fact for the call (`SpokenCallDriver.conversingChanged`).
    var conversingChanged: @MainActor (Bool) -> Void = { _ in }
    /// Told once each conversation has ended (`GuestLifecycle.conversationEnded`).
    var ended: @MainActor () -> Void = {}

    /// Whether the call's session is active: from its activation until a phone call takes it or
    /// the call is over. Behind the lock the microphone is opened only on it, since a session
    /// activated from the background without a call is refused and left invalid.
    private var callUp = false
    private var policy = Endpoint.Policy()
    private var fedTo = 0
    private var feeder: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var reopening = false
    private var endingUtterance = false
    private var lastEnd: Date?
    /// Which of the lock's two moments came first, for the log: the interruption's start or the
    /// call's placing.
    private var firstOff: String?

    init(voice: VoiceInput, speaker: Speaker, endpoint: Endpoint,
         enabled: @escaping @MainActor () -> Bool = { SpokenCallSetting.enabled() },
         appActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         holding: @escaping @MainActor () -> Bool,
         center: NotificationCenter = .default,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.voice = voice
        self.speaker = speaker
        self.endpoint = endpoint
        self.enabled = enabled
        self.appActive = appActive
        self.holding = holding
        self.sleep = sleep
        self.now = now
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.beginIfCarried() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.stop("Topo came to the front", sending: true) }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameActive() }
            },
        ]
        watch()
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Whether the open session is one the lock carries rather than drops: the chat's microphone
    /// open hands-free on a spoken turn, the setting on, the detector loaded, the chat's send
    /// installed, and the app not in front (UIKit's word, read now: SwiftUI's phase lags it).
    func carries() -> Bool {
        if on { return true }
        return voice.listening && voice.owner == .chat && voice.handsFree && enabled()
            && endpoint.ready && send != nil && sends?() == true && !appActive()
    }

    /// The app is in the background: the conversation begins if the open session is one it
    /// carries. Asked by the guest's lifecycle at the same notification, so whichever hears it
    /// first begins it; answers whether one is on.
    @discardableResult
    func beginIfCarried() -> Bool {
        if on { return true }
        guard carries() else { return false }
        on = true
        voice.glancing = false
        AudioLog.say("conversation: begun behind the lock (\(firstOff.map { "the microphone came off at \($0)" } ?? "the microphone still running"))")
        policy = Endpoint.Policy()
        fedTo = 0
        restartIdle()
        conversingChanged(true)
        // Suspended at the interruption's start, it waits for the call's activation; still
        // running, the detector is fed what the press has heard so far.
        if voice.suspended {
            if callUp { resumeOnTheCall() }
        } else {
            startFeeding(reset: true)
        }
        return true
    }

    /// The scene's phase, from the chat: an open microphone is dropped as the scene goes, words
    /// and all, unless the conversation carries it.
    func scene(_ phase: ScenePhase) {
        guard phase != .active, !carries() else { return }
        voice.cancel(.chat)
    }

    /// The call's moments, from the speaker (`Speaker.onCall`).
    func call(_ moment: Speaker.CallMoment) {
        switch moment {
        case .placing:
            callUp = false
            if voice.listening, voice.owner == .chat, carries() {
                if firstOff == nil { firstOff = "the call's placing" }
                voice.suspend("the call's placing")
            }
        case .active:
            callUp = true
            guard on else { return }
            if voice.suspended { resumeOnTheCall() } else { react() }
        case .taken:
            callUp = false
            if on, voice.listening { voice.suspend("the call's session was taken") }
        case .hungUp:
            callUp = false
            stop("hung up from the call", sending: false)
        case .over:
            callUp = false
            stop("the call is over", sending: true)
        }
    }

    private func resumeOnTheCall() {
        guard voice.resume() else {
            AudioLog.say("conversation: the microphone did not resume; what was heard is sent")
            return stop("the microphone did not resume", sending: true)
        }
        AudioLog.say("conversation: resumed on the call's session")
        startFeeding()
    }

    /// The app is active again with no conversation: a session suspended at an interruption's
    /// start in front (a phone call over the open microphone) is dropped, as an interruption
    /// drops it there.
    private func becameActive() {
        guard !on, voice.suspended, voice.owner == .chat else { return }
        AudioLog.say("conversation: none began; the suspended microphone is dropped")
        voice.cancel(.chat)
    }

    /// The interruption's start, from `VoiceInput` (`carries` answered true): which came first.
    func noteInterruption() {
        if firstOff == nil { firstOff = "the interruption's start" }
    }

    // MARK: - Utterances

    private func startUtterance() {
        policy = Endpoint.Policy()
        fedTo = 0
        startFeeding(reset: true)
        restartIdle()
    }

    private func startFeeding(reset: Bool = false) {
        feeder?.cancel()
        guard let detector = endpoint.detector else { return }
        let mine = voice.generation
        let sink = voice.sink
        let sleep = sleep
        feeder = Task { [weak self] in
            if reset { await detector.reset() }
            while !Task.isCancelled {
                guard let self, self.on, self.voice.generation == mine, self.voice.listening else { return }
                let (samples, _) = sink.peek(from: self.fedTo)
                var offset = 0
                while samples.count - offset >= Endpoint.chunk {
                    let chunk = Array(samples[offset..<offset + Endpoint.chunk])
                    offset += Endpoint.chunk
                    self.fedTo += Endpoint.chunk
                    let event: Endpoint.Event?
                    do { event = try await detector.feed(chunk) } catch {
                        AudioLog.say("conversation: the detector failed on a chunk: \(error.localizedDescription)")
                        event = nil
                    }
                    guard !Task.isCancelled, self.on, self.voice.generation == mine else { return }
                    guard let event, let heard = self.policy.take(event) else { continue }
                    switch heard {
                    case .speech:
                        self.restartIdle()
                    case .ended:
                        await self.endUtterance()
                        return
                    }
                }
                try? await sleep(Self.feedEvery)
            }
        }
    }

    /// The detector heard the utterance end: it is decoded as a release decodes it, the next one
    /// opens at once unless a reply is to be read first, and the words are sent after, so the
    /// send's wait for its turn is not time the microphone is deaf.
    private func endUtterance() async {
        guard on, voice.listening, !endingUtterance else { return }
        endingUtterance = true
        lastEnd = now()
        feeder = nil
        let heard = await voice.end(as: .chat)
        endingUtterance = false
        if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let send {
            Task { await send(heard) }
        }
        react()
    }

    // MARK: - The microphone and the reading

    /// Keeps the microphone open exactly while the conversation is on and the speaker is neither
    /// reading nor holding a reply for the microphone to close.
    private func watch() {
        withObservationTracking {
            _ = voice.listening
            _ = speaker.speaking
            _ = speaker.waitingForMicrophone
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.react()
                self.watch()
            }
        }
    }

    private func react() {
        guard on, !endingUtterance else { return }
        if voice.listening, !voice.suspended, speaker.waitingForMicrophone, !policy.speaking {
            // A reply landed over an utterance with nothing said in it: the microphone closes
            // unsent, and the reply is read.
            AudioLog.say("conversation: a reply landed over silence; the microphone closes for it")
            feeder?.cancel()
            feeder = nil
            voice.cancel(.chat)
            return
        }
        guard !voice.listening, !reopening, callUp, !speaker.speaking, !speaker.waitingForMicrophone else { return }
        reopening = true
        Task { await reopen() }
    }

    private func reopen() async {
        let opened = await voice.reopen(as: .chat)
        reopening = false
        guard on else {
            if opened { voice.cancel(.chat) }
            return
        }
        guard opened else {
            AudioLog.say("conversation: the microphone did not open again (\(voice.refusal ?? "refused"))")
            return stop("the microphone did not open again", sending: false)
        }
        let gap = lastEnd.map { Int(now().timeIntervalSince($0) * 1000) }
        AudioLog.say("conversation: reopened\(gap.map { " after \($0) ms" } ?? "")")
        // A reading begun while it opened: the microphone does not hear it.
        if speaker.speaking || speaker.waitingForMicrophone {
            voice.cancel(.chat)
            return
        }
        startUtterance()
    }

    // MARK: - The end

    private func restartIdle() {
        idleTimer?.cancel()
        let sleep = sleep
        idleTimer = Task { [weak self] in
            do { try await sleep(Self.idle) } catch { return }
            guard let self, self.on, !Task.isCancelled else { return }
            // A wait standing or a reading under way is not idleness: the clock starts again.
            if self.holding() || self.speaker.speaking || self.policy.speaking {
                self.restartIdle()
                return
            }
            self.stop("two minutes with nothing said", sending: false)
        }
    }

    /// Ends the conversation: what is open is sent once if `sending` and it held speech, or
    /// dropped; the call is let go, and the guest's lifecycle told. Nothing when none is on.
    func stop(_ why: String, sending: Bool) {
        guard on else { return }
        on = false
        firstOff = nil
        feeder?.cancel()
        feeder = nil
        idleTimer?.cancel()
        idleTimer = nil
        voice.glancing = true
        AudioLog.say("conversation: ended (\(why))")
        let send = send
        if voice.listening, voice.owner == .chat, !endingUtterance {
            if sending, policy.speaking {
                Task {
                    let heard = await voice.end(as: .chat)
                    if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let send { await send(heard) }
                }
            } else {
                voice.cancel(.chat)
            }
        }
        conversingChanged(false)
        ended()
    }
}
#endif
