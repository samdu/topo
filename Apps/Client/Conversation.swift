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
    /// How often what has arrived is taken: the detector fed its whole chunks, and the quiet
    /// counted in 100 ms frames, which is the turn's rule's own tick.
    static let feedEvery: Duration = .milliseconds(100)
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
    /// The idle clock's sleep, a seam for the suite.
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let now: @MainActor () -> Date

    /// The chat's send (`ChatView.sendSpoken`): the row, the one nonce, the wait and the mark.
    /// Installed where the chat appears and taken away where it goes; with none, nothing is
    /// carried.
    var send: (@MainActor (String) async -> Void)? {
        didSet {
            // The chat gone behind the lock (a sign-out, a takeover): nothing heard can be sent.
            if send == nil { stop("the chat stopped answering", sending: false) }
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
    /// True while a chunk counted in `fedTo` is with the detector: its verdict is not in yet.
    private var detecting = false
    /// The judge this conversation's utterances end by, taken as it begins: none when Smart Turn
    /// was not loaded, and then the utterances end on Silero's silence alone.
    @ObservationIgnored private var judge: (any TurnJudge)?
    /// The turn's rule over the quiet and the judge's verdicts (`Endpoint.Judging`), one per
    /// utterance, and how far into the sink its 100 ms frames have been counted.
    private var rule = Endpoint.Judging()
    private var framedTo = 0
    /// Whether this utterance has logged a judge that threw: once is enough.
    private var judgeThrew = false
    /// The wait the rule is judged against, read at each verdict.
    @ObservationIgnored private let wait: @MainActor () -> TimeInterval
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
    /// The card's mute: the microphone closed and kept closed until the unmute.
    private var muted = false
    private var lastEnd: Date?
    /// Which of the lock's two moments came first, for the log: the interruption's start or the
    /// call's placing.
    private var firstOff: String?

    init(voice: VoiceInput, speaker: Speaker, endpoint: Endpoint,
         enabled: @escaping @MainActor () -> Bool = { SpokenCallSetting.enabled() },
         appActive: @escaping @MainActor () -> Bool = { UIApplication.shared.applicationState == .active },
         holding: @escaping @MainActor () -> Bool,
         otherCall: @escaping @MainActor () -> Bool = { false },
         deafAfter: TimeInterval = Conversation.deafAfter,
         wait: @escaping @MainActor () -> TimeInterval = { QuietWait.value() },
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
        self.wait = wait
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
        voice.glancing = false
        AudioLog.say("conversation: begun behind the lock (\(firstOff.map { "the microphone came off at \($0)" } ?? "the microphone still running"))")
        judge = endpoint.judge
        AudioLog.say("conversation: \(endpoint.judgeLine)")
        freshUtterance()
        muted = false
        deafStrikes = 0
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
            // A suspended session being decoded resumes nothing: the decode ends it, and the
            // microphone opens again after.
            if voice.suspended, !endingUtterance, !muted { resumeOnTheCall() } else { react() }
        case .taken:
            callUp = false
            if on, voice.listening { voice.suspend("the call's session was taken") }
        case .hungUp:
            callUp = false
            stop("hung up from the call", sending: false)
        case .over:
            callUp = false
            stop("the call is over", sending: true)
        case .muted(let isMuted):
            muted = isMuted
            guard on else { return }
            if isMuted {
                // What is open goes unsent: the person muted it.
                feeder?.cancel()
                feeder = nil
                if endingUtterance { dropDecoded = true }
                // Opening counts: a cancel moves the generation, so a reopen waiting on its
                // permission opens nothing.
                if voice.owner == .chat, !endingUtterance { voice.cancel(.chat) }
                AudioLog.say("conversation: muted from the card; the microphone is closed")
            } else {
                AudioLog.say("conversation: unmuted from the card")
                restartIdle()
                react()
            }
        }
    }

    private func resumeOnTheCall() {
        guard voice.resume() else {
            AudioLog.say("conversation: the microphone did not resume; what was heard is sent")
            return stop("the microphone did not resume", sending: true)
        }
        AudioLog.say("conversation: resumed on the call's session")
        startFeeding(reset: fedTo == 0)
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
        freshUtterance()
        startFeeding(reset: true)
        restartIdle()
    }

    /// Nothing judged yet: what the next utterance starts from.
    private func freshUtterance() {
        policy = Endpoint.Policy()
        rule = Endpoint.Judging()
        fedTo = 0
        framedTo = 0
        judgeThrew = false
    }

    #if DEBUG
    /// The votes the rule holds now, for the suite.
    var votes: Int { rule.votes }
    #endif

    /// Silero's silence for this conversation's streams: the cap with a judge, the end without.
    private var silence: TimeInterval { Endpoint.silence(judged: judge != nil) }

    private func startFeeding(reset: Bool = false) {
        feeder?.cancel()
        guard let detector = endpoint.detector else { return }
        let mine = voice.generation
        let sink = voice.sink
        let now = now
        let deafLimit = deafLimit
        let silence = silence
        feeder = Task { [weak self] in
            if reset { await detector.reset(silence: silence) }
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
                    self.fedTo += Endpoint.chunk
                    let event: Endpoint.Event?
                    self.detecting = true
                    do { event = try await detector.feed(chunk) } catch {
                        AudioLog.say("conversation: the detector failed on a chunk: \(error.localizedDescription)")
                        event = nil
                    }
                    self.detecting = false
                    guard !Task.isCancelled, self.on, self.voice.generation == mine else { return }
                    guard let event, let heard = self.policy.take(event) else { continue }
                    switch heard {
                    case .speech:
                        // The quiet is counted from where speech began, not from the silence
                        // before it.
                        if case .start(let at) = event { self.framedTo = max(self.framedTo, at) }
                        self.restartIdle()
                    case .ended:
                        await self.endUtterance(self.sileroEnd)
                        return
                    }
                }
                // The quiet after speech, frame by frame, for the judge.
                if let judge = self.judge, self.policy.speaking,
                   let ending = self.frames(judge, generation: mine) {
                    await self.endUtterance(ending)
                    return
                }
                // A reply waiting on this microphone is judged once what was heard has been.
                if self.speaker.waitingForMicrophone { self.react() }
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

    /// Counts the whole frames that have arrived since the last pass into the rule, asking the
    /// judge where it says to. Answers the end, in the log's words, if a frame reached the cap.
    private func frames(_ judge: any TurnJudge, generation: Int) -> String? {
        let (samples, _) = voice.sink.peek(from: framedTo)
        let size = Endpoint.Judging.frame
        var offset = 0
        while samples.count - offset >= size {
            let loud = Endpoint.loud(samples[offset..<offset + size])
            offset += size
            framedTo += size
            switch rule.frame(loud: loud) {
            case .none: continue
            case .ask(let n): ask(n, of: judge, generation: generation)
            case .end(let ending): return said(ending)
            }
        }
        return nil
    }

    /// Hands the judge the utterance's last eight seconds, off the main actor; the verdict counts
    /// only for the session, the utterance and the ask it was asked for.
    private func ask(_ n: Int, of judge: any TurnJudge, generation: Int) {
        let tail = voice.sink.tail(SmartTurn.windowSamples)
        Task { [weak self] in
            let verdict: Float?
            var trouble: String?
            do { verdict = try await judge.complete(tail) } catch {
                verdict = nil
                trouble = error.localizedDescription
            }
            self?.landed(verdict, ask: n, generation: generation, trouble: trouble)
        }
    }

    private func landed(_ verdict: Float?, ask n: Int, generation: Int, trouble: String?) {
        // A verdict from an utterance that has ended, or a session that has, reaches nothing.
        guard on, voice.generation == generation, voice.listening, !endingUtterance else { return }
        if let trouble, !judgeThrew {
            judgeThrew = true
            AudioLog.say("conversation: the judge failed (\(trouble)); the utterance ends on the quiet's cap")
        }
        // Speech that turned out a cough is not an utterance to end.
        if let verdict, policy.speaking {
            if case .end(let ending) = rule.verdict(verdict, ask: n, wait: wait()) {
                feeder?.cancel()
                feeder = nil
                Task { await endUtterance(said(ending)) }
                return
            }
        } else {
            rule.unanswered(ask: n)
        }
        // A reply waiting on this microphone is judged once the verdict is in.
        if speaker.waitingForMicrophone { react() }
    }

    private func said(_ ending: Endpoint.Judging.Ending) -> String {
        switch ending {
        case .judged(let p, let quiet):
            return String(format: "complete %.2f after %.1f s quiet", p, quiet)
        case .quiet(let quiet):
            return String(format: "%.1f s of quiet", quiet) + lastVerdict
        }
    }

    private var lastVerdict: String {
        rule.lastVerdict.map { String(format: "; last verdict %.2f", $0) } ?? "; no verdict"
    }

    /// Silero's end, in the log's words.
    private var sileroEnd: String {
        String(format: "%.1f s of silence", silence) + (judge == nil ? "" : lastVerdict)
    }

    /// The utterance has ended, `why` saying how: it is decoded as a release decodes it, the next
    /// one opens at once unless a reply is to be read first, and the words are sent after, so the
    /// send's wait for its turn is not time the microphone is deaf. A detected end is a release:
    /// it is held from here as a thumb's is (`Speaker.releasing`), the speaker's account of a turn
    /// on its way, until the send has taken its turn's wait, or at once when nothing is sent.
    private func endUtterance(_ why: String) async {
        guard on, voice.listening, !endingUtterance else { return }
        endingUtterance = true
        lastEnd = now()
        feeder = nil
        AudioLog.say("conversation: ended an utterance (\(why))")
        let release = speaker.releasing()
        let heard = await voice.end(as: .chat)
        endingUtterance = false
        let dropped = dropDecoded
        dropDecoded = false
        // The next utterance starts unjudged: speech already sent is not speech going on.
        freshUtterance()
        if dropped {
            release.map { speaker.released($0, "its words were dropped") }
            AudioLog.say("conversation: the utterance being decoded was dropped (hung up or muted)")
        } else if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let send {
            let speaker = speaker
            Task {
                defer { release.map { speaker.released($0, "its send took no wait") } }
                speaker.sending(under: release)
                await send(heard)
            }
        } else {
            release.map { speaker.released($0, "it heard nothing to send") }
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
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.react()
                self.watch()
            }
        }
    }

    /// Whether the detector has been fed everything the sink holds but the part-chunk it is
    /// waiting to fill, and no verdict of the judge's is in flight: until then, an utterance with
    /// nothing said in it is not known to be one.
    private var caughtUp: Bool {
        !detecting && rule.inFlight == nil && voice.sink.peek(from: .max).end - fedTo < Endpoint.chunk
    }

    private func react() {
        guard on, !endingUtterance else { return }
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
        firstOff = nil
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
            // A suspended session was never judged by the detector: what it kept is decoded,
            // and silence decodes to nothing.
            if voice.listening, sending, !muted, policy.speaking || voice.suspended {
                handingOff = true
                Task {
                    let heard = await voice.end(as: .chat)
                    handingOff = false
                    if !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let send { await send(heard) }
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
