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
    /// Chunks in a row the detector may fail on before the conversation ends with what was
    /// heard: about a second, since an utterance it cannot judge would otherwise never end.
    static let failuresTolerated = 4
    /// Listening this long with no samples arriving is a dead engine (a route change stops it
    /// under the call): the session is suspended and rebuilt, and a second time running ends
    /// the conversation.
    static let deafAfter: TimeInterval = 2

    private(set) var on = false

    @ObservationIgnored private let voice: VoiceInput
    @ObservationIgnored private let speaker: Speaker
    @ObservationIgnored private let endpoint: Endpoint
    @ObservationIgnored private let enabled: @MainActor () -> Bool
    @ObservationIgnored private let appActive: @MainActor () -> Bool
    @ObservationIgnored private let holding: @MainActor () -> Bool
    /// Whether a call other than Topo's is up: a phone call the person is on. Topo's call placed
    /// over one would put it on hold, so nothing is carried while one is.
    @ObservationIgnored private let otherCall: @MainActor () -> Bool
    @ObservationIgnored private let deafLimit: TimeInterval
    /// Times running the microphone was found deaf with no samples since: the second ends it.
    private var deafStrikes = 0
    /// Chunks in a row the detector has failed on; a verdict clears it.
    private var failures = 0
    /// The idle clock's sleep, a seam for the suite.
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> Date

    /// The chat's send (`ChatView.sendSpoken`): the row, the one nonce, the wait and the mark.
    /// Installed where the chat appears and taken away where it goes; with none, nothing is
    /// carried.
    var send: (@MainActor (String) async -> Void)? {
        didSet {
            // The chat gone behind the lock (a sign-out, a takeover): nothing heard can be sent.
            guard send == nil else { return }
            dropWhatIsDecoding()
            stop("the chat stopped answering", sending: false)
        }
    }
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
    /// The feeder whose chunk is with the detector, by its serial: that chunk is past `fedTo`
    /// until its verdict is in. Set and cleared by that feeder alone, so a cancelled one still
    /// waiting on its verdict says nothing of the feeder after it.
    private var judgingBy: Int?
    private var feederSerial = 0
    /// Whether the current feeder is waiting on a verdict.
    private var judging: Bool { judgingBy != nil && judgingBy == feederSerial }
    private var feeder: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var reopening = false
    private var endingUtterance = false
    /// Set by a stop that drops what is open while an utterance is being decoded: the decode's
    /// words go nowhere.
    private var dropDecoded = false
    /// From a stop that sends what is open until that send has decoded it: the session is the
    /// stop's, and nothing else drops it.
    private var handingOff = false
    /// Set by a hang-up or a mute while that send is decoding: its words go nowhere.
    private var dropHandoff = false
    /// The card's mute: the microphone closed and kept closed until the unmute.
    private var muted = false
    private var lastEnd: Date?
    /// The go-ahead is owed: the conversation began, an utterance was sent, a reply waited for
    /// the microphone or was read, or the card unmuted it; paid once the microphone is open, the
    /// detector has judged what it holds, nobody is speaking and nothing is on its way, at an
    /// utterance's start or as the last of those clears (Daphne's `cueOwed`).
    private var goAheadOwed = false
    /// Whether this utterance's onset has sounded its `ack`.
    private var acked = false
    /// The stretches of this utterance's samples a tone sounded into (Daphne's `holdGate`): an
    /// onset inside one is the tone's (`Endpoint.Policy.take`).
    private var gates: [Range<Int>] = []
    /// Which of the lock's two moments came first, for the log: the interruption's start or the
    /// call's placing.
    private var firstOff: String?

    init(voice: VoiceInput, speaker: Speaker, endpoint: Endpoint,
         enabled: @escaping @MainActor () -> Bool = { SpokenCallSetting.enabled() },
         appActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         holding: @escaping @MainActor () -> Bool,
         otherCall: @escaping @MainActor () -> Bool = { false },
         deafAfter: TimeInterval = Conversation.deafAfter,
         center: NotificationCenter = .default,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.voice = voice
        self.speaker = speaker
        self.endpoint = endpoint
        self.enabled = enabled
        self.appActive = appActive
        self.holding = holding
        self.otherCall = otherCall
        self.deafLimit = deafAfter
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
        speaker.sounds?.toneSounded = { [weak self] tone, length in self?.toneSounded(tone, length) }
        watch()
    }

    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    /// Whether the open session is one the lock carries rather than drops: the chat's microphone
    /// open hands-free on a spoken turn, the setting on, the detector loaded, the chat's send
    /// installed, no phone call up, and the app not in front (UIKit's word, read now: SwiftUI's
    /// phase lags it).
    func carries() -> Bool {
        if on { return true }
        return voice.listening && voice.owner == .chat && voice.handsFree && enabled()
            && endpoint.ready && send != nil && sends?() == true && !appActive() && !otherCall()
    }

    /// The app is in the background: the conversation begins if the open session is one it
    /// carries. Asked by the guest's lifecycle at the same notification, so whichever hears it
    /// first begins it; answers whether one is on.
    @discardableResult
    func beginIfCarried() -> Bool {
        if on { return true }
        guard carries() else { return false }
        on = true
        speaker.conversing = true
        goAheadOwed = true
        acked = false
        gates = []
        voice.glancing = false
        AudioLog.say("conversation: begun behind the lock (\(firstOff.map { "the microphone came off at \($0)" } ?? "the microphone still running"))")
        policy = Endpoint.Policy()
        fedTo = 0
        muted = false
        deafStrikes = 0
        failures = 0
        // A feeder of the last conversation still waiting on a verdict is not this one's.
        feederSerial += 1
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
    /// and all, unless the conversation carries it; a released press's decode finishes and sends
    /// (`VoiceInput.drop`).
    func scene(_ phase: ScenePhase) {
        guard phase != .active, !carries() else { return }
        voice.drop(.chat)
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
            // A suspended session being decoded resumes nothing: the decode ends it, and the
            // microphone opens again after.
            if voice.suspended, !endingUtterance, !muted { resumeOnTheCall() } else { react() }
        case .taken:
            callUp = false
            if on, voice.listening { voice.suspend("the call's session was taken") }
        case .hungUp:
            callUp = false
            dropWhatIsDecoding()
            stop("hung up from the call", sending: false)
        case .over:
            callUp = false
            stop("the call is over", sending: true)
        case .muted(let isMuted):
            muted = isMuted
            if isMuted { dropWhatIsDecoding() }
            guard on else { return }
            if isMuted {
                // What is open goes unsent: the person muted it.
                feeder?.cancel()
                feeder = nil
                // Opening counts: a cancel moves the generation, so a reopen waiting on its
                // permission opens nothing.
                if voice.owner == .chat, !endingUtterance { voice.cancel(.chat) }
                AudioLog.say("conversation: muted from the card; the microphone is closed")
            } else {
                AudioLog.say("conversation: unmuted from the card")
                goAheadOwed = true
                restartIdle()
                react()
            }
        }
    }

    /// The person ended it (a hang-up, a mute, the chat gone): whatever is being decoded to be
    /// sent goes nowhere — an utterance's own end, or the handoff of a stop that sends — whether
    /// or not the conversation is still on.
    private func dropWhatIsDecoding() {
        if endingUtterance { dropDecoded = true }
        if handingOff { dropHandoff = true }
    }

    private func resumeOnTheCall() {
        guard voice.resume() else {
            AudioLog.say("conversation: the microphone did not resume; what was heard is sent")
            return stop("the microphone did not resume", sending: true)
        }
        AudioLog.say("conversation: resumed on the call's session")
        // A feeder waiting on a verdict carries on once it has it: replaced, the verdict would be
        // lost, and the detector, which has already judged that chunk, would not give it again.
        if !judging { startFeeding(reset: fedTo == 0) }
        // A reply that waited while the microphone was suspended is judged now: `listening`
        // did not change, so nothing observed fires for it.
        react()
    }

    /// The app is active again with no conversation: a session suspended at an interruption's
    /// start in front (a phone call over the open microphone) is dropped, as an interruption
    /// drops it there.
    private func becameActive() {
        guard !on, !handingOff, voice.suspended, voice.owner == .chat else { return }
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
        acked = false
        gates = []
        startFeeding(reset: true)
        restartIdle()
        payGoAhead()
    }

    /// The go-ahead, if it is owed and the microphone can take the next turn: open and running,
    /// not muted, on the call's live session, with nothing on its way (Daphne's `cueIfReady`).
    /// A cue that has just sounded (the earcons') was this moment's receipt, and a second would
    /// say it twice.
    private func payGoAhead() {
        guard goAheadOwed, on, !muted, callUp, voice.listening, !voice.suspended, !speaker.awaitingAny else { return }
        goAheadOwed = false
        if speaker.earcons?.recent(Self.earconReceipt) == true {
            return AudioLog.say("conversation: no go-ahead; a cue has just said it")
        }
        speaker.sounds?.goAhead()
    }

    /// How recently a cue stands in for the go-ahead (Daphne's `earconReceipt`).
    static let earconReceipt: Duration = .milliseconds(1500)

    /// A tone sounded into the open microphone: its gate is shut while it sounds, so the ear
    /// does not take the tone for speech. The onset's own `ack` sounds over a turn already open,
    /// and shuts nothing (Daphne: "the receipt costs it nothing").
    private func toneSounded(_ tone: KeeperSounds.Tone, _ length: Duration) {
        guard on, tone != .ack, voice.listening, !voice.suspended else { return }
        let samples = Int(Double(length.components.attoseconds) / 1e18 * Double(Ear.rate))
            + Int(length.components.seconds) * Int(Ear.rate)
        let at = voice.sink.peek(from: .max).end
        gates.append(max(0, at - Endpoint.startEarly)..<(at + samples))
    }

    private func startFeeding(reset: Bool = false) {
        feeder?.cancel()
        guard let detector = endpoint.detector else { return }
        feederSerial += 1
        let serial = feederSerial
        let mine = voice.generation
        let sink = voice.sink
        let now = now
        let deafLimit = deafLimit
        feeder = Task { [weak self] in
            if reset { await detector.reset() }
            var heardAt = now()
            var arrived = -1
            while !Task.isCancelled {
                guard let self, self.on, self.voice.generation == mine, self.voice.listening,
                      !self.voice.suspended else { return }
                let (samples, end) = sink.peek(from: self.fedTo)
                // Deafness is the sink not growing, not an empty peek: a part-chunk left over
                // stays in every peek after the engine stops.
                if end == arrived {
                    if now().timeIntervalSince(heardAt) >= deafLimit { return self.deaf() }
                } else {
                    if arrived >= 0 { self.deafStrikes = 0 }
                    arrived = end
                    heardAt = now()
                }
                var offset = 0
                while samples.count - offset >= Endpoint.chunk {
                    let chunk = Array(samples[offset..<offset + Endpoint.chunk])
                    offset += Endpoint.chunk
                    let event: Endpoint.Event?
                    self.judgingBy = serial
                    do { event = try await detector.feed(chunk) } catch {
                        if self.judgingBy == serial { self.judgingBy = nil }
                        guard !Task.isCancelled, self.on, self.voice.generation == mine else { return }
                        self.failures += 1
                        AudioLog.say("conversation: the detector failed on a chunk (\(self.failures) in a row): \(error.localizedDescription)")
                        // The chunk stays unjudged, so it is tried again and a stop decodes it.
                        if self.failures > Self.failuresTolerated {
                            return self.stop("the detector kept failing", sending: true)
                        }
                        break
                    }
                    if self.judgingBy == serial { self.judgingBy = nil }
                    guard !Task.isCancelled, self.on, self.voice.generation == mine else { return }
                    // Counted fed only with its verdict in: a chunk whose verdict was lost is one
                    // a stop still decodes.
                    self.fedTo += Endpoint.chunk
                    self.failures = 0
                    guard let event, let heard = self.policy.take(event, gates: self.gates) else { continue }
                    switch heard {
                    case .speech:
                        self.restartIdle()
                        // The utterance's first onset: its receipt, once (Daphne's `Keeper.heard`).
                        if !self.acked {
                            self.acked = true
                            self.speaker.sounds?.heard()
                        }
                    case .ended:
                        await self.endUtterance()
                        return
                    }
                }
                // A reply waiting on this microphone, or a go-ahead owed, is judged once what was
                // heard has been.
                if self.speaker.waitingForMicrophone || self.goAheadOwed { self.react() }
                try? await Task.sleep(for: Self.feedEvery)
            }
        }
    }

    /// The microphone listened with nothing arriving: suspended so the call's live session
    /// rebuilds it, once; deaf again with nothing heard since, the conversation ends with what
    /// was kept.
    private func deaf() {
        deafStrikes += 1
        guard deafStrikes < 2 else {
            return stop("the microphone stayed deaf after a rebuild", sending: true)
        }
        AudioLog.say("conversation: no samples for \(deafLimit) s; the microphone is rebuilt")
        voice.suspend("no samples arriving")
        react()
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
        let dropped = dropDecoded
        dropDecoded = false
        // The next utterance starts unjudged: speech already sent is not speech going on.
        policy = Endpoint.Policy()
        if dropped {
            AudioLog.say("conversation: the utterance being decoded was dropped (hung up or muted)")
        } else if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let send {
            // The turn sent owes the go-ahead, paid once nothing is on its way: its reply's wait,
            // taken by the send, holds it back until the reply has been read.
            goAheadOwed = true
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
            _ = voice.suspended
            _ = speaker.speaking
            _ = speaker.waitingForMicrophone
            _ = speaker.awaitingAny
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.react()
                self.watch()
            }
        }
    }

    /// Whether the detector has been fed everything the sink holds but the part-chunk it is
    /// waiting to fill: until then, an utterance with nothing said in it is not known to be one.
    private var caughtUp: Bool {
        !judging && voice.sink.peek(from: .max).end - fedTo < Endpoint.chunk
    }

    private func react() {
        guard on, !endingUtterance else { return }
        // A reply waiting on the microphone or being read owes the go-ahead for the microphone
        // that opens after it.
        if speaker.speaking || speaker.waitingForMicrophone { goAheadOwed = true }
        if voice.listening, !voice.suspended, speaker.waitingForMicrophone, !policy.speaking, caughtUp {
            // A reply landed over an utterance with nothing said in it: the microphone closes
            // unsent, and the reply is read.
            AudioLog.say("conversation: a reply landed over silence; the microphone closes for it")
            feeder?.cancel()
            feeder = nil
            voice.cancel(.chat)
            return
        }
        if voice.suspended, callUp, !muted, !voice.ending {
            // Suspended with the call's session live: resumed, whatever suspended it.
            return resumeOnTheCall()
        }
        // The microphone open, every whole chunk it holds judged, and nothing on its way or being
        // said: an owed go-ahead is paid (the conversation's start, a wait that has ended under an
        // open microphone), never over an onset the detector has yet to give. Not while a reopen
        // is landing: its utterance's start pays it, after the gates are reset.
        if voice.listening, !voice.suspended, !reopening, caughtUp, !policy.speaking, !speaker.speaking,
           !speaker.waitingForMicrophone {
            payGoAhead()
        }
        guard !voice.listening, !reopening, callUp, !muted, !speaker.speaking, !speaker.waitingForMicrophone else { return }
        reopening = true
        Task { await reopen() }
    }

    private func reopen() async {
        // The call over or taken between `react` and this task: nothing opens on a session the
        // background cannot activate.
        guard on, callUp else {
            reopening = false
            return
        }
        let opened = await voice.reopen(as: .chat)
        reopening = false
        guard on, !muted else {
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
            // A microphone suspended this long is a dead one, whatever waits: what it kept is
            // sent and the conversation ends, so nothing holds the call and the resident for it.
            if self.voice.suspended {
                return self.stop("two minutes with the microphone suspended", sending: true)
            }
            // A wait standing, a reading or an utterance under way is not idleness: the clock
            // starts again.
            if self.endingUtterance || self.holding() || self.speaker.speaking
                || (self.policy.speaking && self.voice.listening) {
                self.restartIdle()
                return
            }
            self.stop(self.muted ? "two minutes muted" : "two minutes with nothing said", sending: false)
        }
    }

    /// Ends the conversation: what is open is sent once if `sending` and it held speech, or
    /// dropped; the call is let go, and the guest's lifecycle told. Nothing when none is on.
    func stop(_ why: String, sending: Bool) {
        guard on else { return }
        on = false
        speaker.conversing = false
        goAheadOwed = false
        firstOff = nil
        // Read before the feeder goes: a chunk with the detector, or any sample not yet fed — a
        // word shorter than a chunk included — is unjudged.
        let unjudged = judging || voice.sink.peek(from: .max).end > fedTo
        feeder?.cancel()
        feeder = nil
        idleTimer?.cancel()
        idleTimer = nil
        voice.glancing = true
        AudioLog.say("conversation: ended (\(why))")
        let send = send
        if endingUtterance {
            // The decode under way finishes the open utterance: sent, or dropped with the end.
            if !sending { dropDecoded = true }
        } else if voice.owner == .chat {
            // Samples the detector has not judged — a suspended session's, a chunk with it or
            // not yet fed — are decoded, and silence decodes to nothing.
            if voice.listening, sending, !muted, policy.speaking || voice.suspended || unjudged {
                handingOff = true
                dropHandoff = false
                Task {
                    let heard = await voice.end(as: .chat)
                    handingOff = false
                    // A hang-up or a mute while it decoded: the person ended it, unsent.
                    let dropped = dropHandoff
                    dropHandoff = false
                    if dropped {
                        AudioLog.say("conversation: the handoff being decoded was dropped (hung up or muted)")
                    } else if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let send {
                        await send(heard)
                    }
                }
            } else {
                voice.cancel(.chat)
            }
        }
        muted = false
        conversingChanged(false)
        ended()
    }
}
#endif
