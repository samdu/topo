import Foundation
import TopoCore
import TopoTurn

/// The hub's mind: while it is on and the Mac is awake, this Mac holds the primary lease and
/// answers the person's turns from the log through a resident native Claude Code
/// (`NativeBrain`), one pass at a time (`TurnRunner.answerPending`).
///
/// **The lease.** Taken from whoever holds it (`PrimaryLease.takeOver()`) once each time the mind
/// starts: turned on, the hub launched with it on, and each wake from sleep. Kept from then on by
/// the lease's own heartbeats, which every write it answers starts, and by the runner's writes,
/// each a batch with a heartbeat. Before every pass a lease this Mac does not hold is asked for
/// with `acquire()`, never taken: a holder this Mac yielded to keeps it until it lapses, so a
/// phone that took it is not taken from on a timer. Every stop is `abandon()`, which stops the
/// heartbeats at once and lets the record lapse one duration later; there is no release.
///
/// **Starting**, in this order, so the lease is never held by a mind that cannot answer: Claude
/// Code's login is asked (`MindLogin`), the resident process is started, the runner made, then the
/// lease taken. A takeover that cannot be sent is sent again, backing off, until it is answered.
///
/// **Stopping.** Turning it off cancels the pass under way, abandons the lease and shuts the
/// process down; sleep does the same but leaves the process, which the Mac suspends with
/// everything else and which a turn cut off by the sleep is listened to again on at wake. A pass
/// that is cancelled writes nothing more: the runner checks before each append, and the abandoned
/// lease refuses any batch sent after it. A turn that finds Claude Code signed out, a turn given up
/// on (Claude Code silent on it for `NativeBrain.standardSilence`, or running past
/// `standardTurn`), or a process that cannot be started or a ledger that cannot be read, stops
/// the mind as turning it off does, and it stays stopped, saying why, until it is turned on again,
/// asked to try again, or the Mac wakes; the phone answers once the lease lapses. A stalled mind
/// is not started again on a timer, since it would take the lease from the phone to stall again.
///
/// **Triggers.** A pass runs when one is asked for (`trigger`: the push of a turn being created;
/// `nudge`: a phone on the LAN saying the log moved) and every `poll` otherwise. One pass at a time: a trigger while the loop waits starts the
/// next pass now, any number of triggers before it begins are that one pass, and any number during
/// a pass are one more pass after it, since that pass may have read the log before their turn.
public actor HubMind {
    public enum Trigger: String, Sendable {
        /// The first pass of a start.
        case start
        /// The push of a turn being created.
        case push
        /// The loop's own interval.
        case poll
        /// A phone on the LAN saying the log moved (`nudge`), or a pass after one that found
        /// nothing, in case the log's change feed was behind the phone's save.
        case nudge
    }

    public enum Phase: Sendable, Equatable {
        /// Turned off: no lease is claimed and no mind runs.
        case off
        /// Asking the login, starting the process, taking the lease.
        case starting
        /// Started, and holding off the start's takeover while a phone answers the person's turn
        /// at the log's head (`HubMind.HoldOff`).
        case deferring
        /// The loop is running.
        case answering
        /// On, with the Mac asleep: nothing is written until it wakes.
        case asleep
        /// On, and not answering, for this reason.
        case stopped(Stop)
    }

    public enum Stop: Sendable, Equatable {
        case signedOut
        /// Claude Code could not be asked whether it is signed in.
        case loginUnknown(String)
        case notStarted(String)
        case ledgerUnreadable(String)
        /// The mind's home could not be made.
        case home(String)
        /// A turn was given up on (`NativeBrainError.stalled`): Claude Code went silent on it, or it
        /// ran past its bound. The phone answers it once the lease lapses.
        case stalled(NativeBrainError.Stall)
    }

    public struct Pass: Sendable, Equatable {
        public enum Outcome: Sendable, Equatable {
            /// Nothing was waiting.
            case nothing
            /// A reply this pass wrote, or found already written.
            case answered
            /// Another device holds the lease and answers.
            case elsewhere
            /// Another device took the lease while the brain answered; nothing was written.
            case displaced
            /// The kind of failure, a name and nothing a turn said.
            case failed(String)
        }

        public var outcome: Outcome
        public var trigger: Trigger
        public var at: Date
    }

    public struct Snapshot: Sendable, Equatable {
        public var phase: Phase
        public var login: MindLogin?
        /// True while this Mac holds an unexpired lease.
        public var holds: Bool
        public var lastPass: Pass?
        /// Passes run since launch.
        public var passes: Int
        /// `takeOver()` calls answered since launch.
        public var takeovers: Int
        /// The brain's own line (`NativeBrain.describe()`), for the menu: with the reasons a start
        /// or a read failed, which may be Claude Code's own words.
        public var mind: String
        /// The same line with no reason in it (`describe(reasons: false)`), for the status a shell reads.
        public var mindKinds: String
    }

    private let database: any RecordDatabase
    private let device: DeviceID
    private let brain: NativeBrain
    private let timed: TimedBrain
    private let clock = PassClock()
    /// The reply being written, for the phones whose nudge asked for it (`nudge`).
    private let cast = ReplyCast()
    /// Internal for the suites, which read what it holds after a stop.
    let lease: PrimaryLease
    private let log: TurnLog
    private let login: @Sendable () async -> MindLogin
    private let prepare: @Sendable () throws -> Void
    private let model: @Sendable () -> ClaudeModel
    private let poll: Duration
    private let answeringPoll: Duration
    private let holdBound: TimeInterval
    private let holdCheck: Duration
    private let pause: @Sendable (Duration) async throws -> Void
    private let observe: @Sendable (Snapshot) -> Void

    private var on = false
    private var asleep = false
    private var phase: Phase = .off
    private var loginState: MindLogin?
    private var lastPass: Pass?
    private var passes = 0
    private var takeovers = 0
    private var runner: TurnRunner?
    /// The running start or loop. Nil while off, asleep or stopped.
    private var session: Task<Void, Never>?
    /// Moves at every stop: a session of an earlier generation does nothing more.
    private var generation = 0
    /// A pass asked for and not yet begun, and what asked first.
    private var requested: Trigger?
    private var waiting: Task<Void, any Error>?
    /// Nudges waiting for the end of the pass that reads after them (`nudge`).
    private var nudged: [(mark: String, answer: CheckedContinuation<Bool, Never>)] = []
    /// Passes run again after a nudged one found nothing, since the last that found something.
    private var againAfterNudge = 0
    /// Whether words handed over ahead of their turn are heard (`hear`): once a pass of this
    /// session has answered, until the next start or a pass that had to ask for the lease and did
    /// not answer. While this Mac holds the lease every turn of the log is its
    /// mind's to answer, so a mind that answered since it last took the lease has been told the
    /// log, and words given it with no read are given after all of it.
    private var hearReady = false
    /// The hand-overs being heard, which a stop cancels and waits for before it waits for the session.
    private var hearing: [UUID: Task<NativeBrain.HearRefusal?, Never>] = [:]
    /// A pass is running: one may be reading a turn the mind has not been told, which words heard
    /// now would go ahead of.
    private var passing = false

    /// - Parameters:
    ///   - database: the log's store; the lease, the log and the writer all go through it.
    ///   - device: this Mac's device ID (`mac-` and a UUID).
    ///   - endpoint: where this Mac answers lease probes.
    ///   - login: asks Claude Code whether it is signed in (`MindLogin.check`).
    ///   - prepare: makes the mind's home (`MindHome.prepare`) before anything starts.
    ///   - model: the menu's picker: the model where no device has said one (`ModelChoice`).
    ///   - poll: the backstop interval between passes.
    ///   - leaseSleep: how the lease's heartbeats wait; tests drive it.
    ///   - pause: how the loop and its retries wait; tests drive it.
    ///   - observe: told every change, on no particular actor.
    public init(database: any RecordDatabase, device: DeviceID, endpoint: String?, probe: any LeaseProbe,
                brain: NativeBrain, login: @escaping @Sendable () async -> MindLogin,
                prepare: @escaping @Sendable () throws -> Void = {},
                model: @escaping @Sendable () -> ClaudeModel, timing: LeaseTiming = .standard,
                poll: Duration = HubMind.standardPoll, answeringPoll: Duration? = nil,
                holdBound: Duration = HubMind.standardHoldBound, holdCheck: Duration = HubMind.standardHoldCheck,
                leaseSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                observe: @escaping @Sendable (Snapshot) -> Void = { _ in }) {
        let timedDatabase = TimedDatabase(base: database, clock: clock)
        self.database = timedDatabase
        self.device = device
        self.brain = brain
        self.timed = TimedBrain(inner: brain, clock: clock, cast: cast)
        self.lease = PrimaryLease(database: timedDatabase, device: device, endpoint: endpoint, probe: probe,
                                  timing: timing, sleep: leaseSleep)
        self.log = TurnLog(database: timedDatabase)
        self.login = login
        self.prepare = prepare
        self.model = model
        self.poll = poll
        self.answeringPoll = answeringPoll ?? min(poll, HubMind.standardAnsweringPoll)
        self.holdBound = TimeInterval(holdBound.components.seconds) + TimeInterval(holdBound.components.attoseconds) / 1e18
        self.holdCheck = holdCheck
        self.pause = pause
        self.observe = observe
    }

    /// Ten seconds: the poll while this Mac does not hold the lease (a phone does, or it lapsed). A
    /// pass with nothing waiting is one request, the zone's change feed, and touches nothing else
    /// (`TurnRunner.answerPending`). While it holds the lease the poll is `standardAnsweringPoll`;
    /// on the LAN a phone's nudge starts a pass at once.
    public static let standardPoll: Duration = .seconds(10)

    /// Five seconds: the poll while this Mac holds the lease, which off the LAN, with the push at
    /// APNs' low priority, is how a turn is found. A pass with nothing waiting is one request (the
    /// zone's change feed from its token), half the read the phone's loop makes every five seconds
    /// while its chat is open, in the same private database, so 0.2 a second. Apple publishes no per-user rate for the private database; the figure quoted for
    /// CloudKit is 40 requests a second, and a throttle answers `requestRateLimited` with a retry
    /// after, which fails that pass and no other.
    public static let standardAnsweringPoll: Duration = .seconds(5)

    /// How many passes a nudge that found nothing is followed by, a second apart, while the turn
    /// it named is not in the log: a pass begun the moment the phone's save was answered may read
    /// the zone's change feed before it has the turn, and then finds the log incomplete and waits.
    static let againAfterNudgeLimit = 3

    /// Ten minutes: how long the start's takeover holds off for a phone that holds a fresh lease
    /// while the person's turn at the log's head goes unanswered, counted from when the turn was
    /// said. A phone that is answering renews its lease while it does, and its guest has no bound on
    /// a whole turn, only on silence (`GuestSession.defaultTurnBound`, 3 min, after which the turn
    /// fails and the phone's own loop answers it again), so the bound is not a turn's length: it is
    /// what a phone that is alive and never answers (its guest not up, the turn held cut off) costs
    /// the turn before the hub answers it. A phone that stops renewing is no reason to wait at all.
    public static let standardHoldBound: Duration = .seconds(600)

    /// How often the hold reads the lease and the log: one fetch by ID, and while the lease is a
    /// phone's and fresh, one read of the log.
    public static let standardHoldCheck: Duration = .seconds(2)

    // MARK: - The switch, sleep and wake

    /// Starts the mind: login, process, runner, takeover, loop. Nothing when already on.
    public func turnOn() async {
        guard !on else { return }
        on = true
        if asleep { phase = .asleep; await publish(); return }
        begin()
    }

    /// Stops the loop and the pass under way, lets the lease go and shuts the process down, and
    /// returns once the process is gone. Nothing when already off.
    public func turnOff() async {
        guard on else { return }
        on = false
        await stop()
        _ = await brain.shutdown()
        phase = .off
        await publish()
    }

    /// The Mac is going to sleep: the loop and the pass under way stop and the lease is let go,
    /// before the call returns, so nothing is written after the sleep.
    public func willSleep() async {
        guard !asleep else { return }
        asleep = true
        guard on else { return }
        await stop()
        phase = .asleep
        await publish()
    }

    /// The Mac woke: the mind starts again, taking the lease over once.
    public func didWake() async {
        guard asleep else { return }
        asleep = false
        guard on else { return }
        begin()
    }

    /// Starts a mind that stopped (signed out, not started) again, from the login. Nothing while
    /// it runs, is off or the Mac is asleep.
    public func tryAgain() {
        guard on, !asleep, case .stopped = phase else { return }
        begin()
    }

    /// Asks for a pass. Nothing while the loop is not running.
    public func trigger(_ source: Trigger) {
        guard on, !asleep, session != nil else { return }
        if requested == nil { requested = source }
        waiting?.cancel()
    }

    /// A phone's word that the log moved, for the lease `holder` at `epoch` (`HubNudge`): a pass
    /// runs now, as a push's does, and the call returns true once the pass that read the log after
    /// it has ended, false at once when this Mac holds no such lease or the loop is not answering
    /// (off, asleep, stopped, starting or holding off), and false if the mind stops meanwhile.
    /// Any number of nudges during a pass are one more pass after it; a forged one costs a read.
    ///
    /// With `stream`, the reply to the turn `mark` names is handed to it as the mind writes it
    /// (`ReplyCast`), from the moment the mind is asked for a reply that answers that turn, or at
    /// once with what it has missed if that reply is being written already, until the call
    /// returns. What it is handed is the reply's words and where its messages and tool calls
    /// begin, nothing of a tool's; and only while this call stands, which a stop of the mind ends.
    public func nudge(holder: DeviceID, epoch: Int64, mark: String, stream: ReplyCast.Hand? = nil) async -> Bool {
        guard on, !asleep, session != nil, phase == .answering, await holds(holder, epoch: epoch),
              on, !asleep, session != nil, phase == .answering else { return false }
        Perf.mark("hub.nudge.received nudge=\(mark)\(stream == nil ? "" : " stream")")
        let following = stream.map { cast.follow(mark, $0) }
        defer { if let following { cast.stop(following) } }
        if requested == nil { requested = .nudge }
        waiting?.cancel()
        return await withCheckedContinuation { nudged.append((mark.lowercased(), $0)) }
    }

    /// A phone's hand-over of the person's words, said under `nonce` with `model` chosen, before
    /// their turn is saved (`HubNudge.hear`): the mind hears them now (`NativeBrain.hearAhead`) and
    /// the pass that finds the turn binds its reply to it, so the mind is asked a pass's whole read
    /// sooner. True once the mind has them. False, with nothing written, unless this Mac holds the
    /// lease `holder` at `epoch` fresh, the loop is answering (not off, asleep, stopped, starting
    /// or holding off) and ready to hear (`hearReady`), the model is one of the person's choices,
    /// and the mind can take them cleanly (`NativeBrain.HearRefusal`). Nothing is read from
    /// CloudKit: the turn comes in the log as ever, and the reply is written only by a pass, under
    /// the reply nonce of the turn saved, in the lease's batch.
    public func hear(holder: DeviceID, epoch: Int64, nonce: String, model: String, words: String) async -> Bool {
        let mark = Self.mark(of: nonce)
        Perf.mark("hub.hear.received hear=\(mark)")
        guard let chosen = ClaudeModel(rawValue: model) ?? ClaudeModel(setting: model) else {
            Perf.mark("hub.hear.dropped model")
            return false
        }
        let g = generation
        guard answers(g), await holds(holder, epoch: epoch), answers(g) else {
            Perf.mark("hub.hear.dropped notAnswering")
            return false
        }
        let id = UUID()
        let task = Task { [brain] in await brain.hearAhead(words, nonce: nonce, model: chosen) }
        hearing[id] = task
        let refusal = await task.value
        hearing[id] = nil
        if let refusal {
            Perf.mark("hub.hear.dropped \(refusal.rawValue)")
            return false
        }
        Perf.mark("hub.hear.asked hear=\(mark)")
        return true
    }

    /// Whether the session `g` is answering and ready to hear words ahead of their turn: every
    /// start, stop, halt and pass that asked for the lease takes `hearReady` away. Not while a pass
    /// runs, is asked for or is owed a nudge: the log has, or may have, a turn the mind has not
    /// been told, and words heard now would be told ahead of it.
    private func answers(_ g: Int) -> Bool {
        g == generation && hearReady && !passing && requested == nil && nudged.isEmpty
    }

    /// How a turn on words heard ahead ended, told by the brain: one given up on or signed out
    /// stops the mind, as a pass's does.
    private func heardEnded(_ end: NativeBrain.HeardEnd, _ g: Int) async {
        let why: Stop
        switch end {
        case .stalled(let stall): why = .stalled(stall)
        case .signedOut: why = .signedOut
        default: return
        }
        // The session is not this task's, as a pass's halt is: it is stopped as the switch stops
        // it, and then the mind is left stopped, saying why.
        guard g == generation, on, !asleep, session != nil else { return }
        await stop()
        _ = await brain.shutdown()
        guard on, !asleep, session == nil else { return }
        if why == .signedOut { loginState = .signedOut }
        phase = .stopped(why)
        Perf.mark("hub.mind.stopped \(Self.name(of: why))")
        await publish()
    }

    /// Whether a turn a nudge named is not in the log as read now: a pass that found nothing may
    /// have read the zone's change feed before it had the phone's save. A mark is the first eight
    /// letters or digits of the turn's nonce (`Harness.turnMark`). A read that fails is unseen.
    private func unseen(_ marks: [String]) async -> Bool {
        let named = Set(marks)
        guard !named.isEmpty else { return false }
        guard let transcript = try? await log.read() else { return true }
        let seen = Set(transcript.turns.values.map { Self.mark(of: $0.nonce) })
        return !named.isSubset(of: seen)
    }

    /// A turn's mark by its nonce, as the phone writes it on the wire.
    static func mark(of nonce: String) -> String {
        String(nonce.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8)).lowercased()
    }

    /// Every nudge waiting is answered: the loop has stopped.
    private func releaseNudges() {
        let waiting = nudged
        nudged = []
        againAfterNudge = 0
        waiting.forEach { $0.answer.resume(returning: false) }
    }

    /// Quit: as turning off, keeping the switch where it is.
    public func shutdown() async {
        await stop()
        _ = await brain.shutdown()
    }

    /// Whether this Mac holds the lease `holder` at `epoch`: the probe server's question.
    public nonisolated func holds(_ holder: DeviceID, epoch: Int64) async -> Bool {
        guard await lease.isPrimary(), let held = await lease.held else { return false }
        return held.holder == holder && held.epoch == epoch
    }

    public func snapshot() async -> Snapshot {
        Snapshot(phase: phase, login: loginState, holds: await lease.isPrimary(), lastPass: lastPass,
                 passes: passes, takeovers: takeovers, mind: await brain.describe(),
                 mindKinds: await brain.describe(reasons: false))
    }

    /// The resident's pid, for the suites.
    public var pid: Int32? { get async { await brain.pid } }

    // MARK: - Inside

    private func begin() {
        generation += 1
        let g = generation
        session?.cancel()
        requested = nil
        hearReady = false
        session = Task { await self.run(g) }
    }

    /// Stops whatever session runs and waits for it: the lease is abandoned before the wait, so a
    /// write the session sends after this begins holds nothing and a batch is refused.
    private func stop() async {
        generation += 1
        let running = session
        session = nil
        requested = nil
        running?.cancel()
        waiting?.cancel()
        await lease.abandon()
        await stopHearing()
        await running?.value
        releaseNudges()
    }

    /// Words on their way to the mind ahead of their turn stop, and the mind stops listening to
    /// any it has, before a stop waits for its session: a pass waiting for the one slot behind
    /// them would otherwise hold the stop for the whole of their turn. What the mind has of them
    /// it keeps, as for a turn a sleep cut off.
    private func stopHearing() async {
        hearReady = false
        let handing = Array(hearing.values)
        handing.forEach { $0.cancel() }
        for task in handing { _ = await task.value }
        await brain.stopFlight()
    }

    private func current(_ g: Int) -> Bool { g == generation && !Task.isCancelled }

    private func run(_ g: Int) async {
        // Every claim of this session's is made since this mark (`PrimaryLease.abandons`), taken
        // before anything that can be stopped: a stop moves `generation` before it abandons the
        // lease, so a mark read after the abandon is a session `current(g)` has ended, and every
        // claim made under a mark read before it is refused by the lease, however late it lands.
        let mark = await lease.abandons
        guard current(g) else { return }
        phase = .starting
        await publish()
        do {
            try prepare()
        } catch {
            await halt(.home(String(describing: error)), g)
            return
        }
        let login = await self.login()
        guard current(g) else { return }
        loginState = login
        switch login {
        case .signedIn: break
        case .signedOut: await halt(.signedOut, g); return
        case .unknown(let why): await halt(.loginUnknown(why), g); return
        }
        do {
            // What the mind writes of a reply goes to the phones that follow its turn.
            // and to the pass's marks, with where the process has the turn.
            await brain.writes(to: { [cast, clock] in clock.wrote($0); cast.write($0) })
            await brain.stages(to: { [clock] in clock.brain($0) })
            // What the mind writes of words heard ahead goes to the phones that follow their turn,
            // on a lane of its own, and none of it to a pass's marks.
            await brain.hearings(to: { [cast, weak self] hearing in
                switch hearing {
                case .began(let nonce): cast.beginHeard(nonce)
                case .frame(let frame): cast.writeHeard(frame)
                case .ended(_, let end):
                    if end.cuts { cast.cutHeard() }
                    cast.endHeard()
                    Task { await self?.heardEnded(end, g) }
                }
            })
            // The process starts with the model the next turn most likely asks for.
            await brain.use(model: await startingModel())
            try await brain.start()
        } catch {
            guard current(g) else { return }
            await halt(Self.stop(for: error) ?? .notStarted(String(describing: error)), g)
            return
        }
        guard current(g), let runner = await made(g) else { return }
        guard await heldOff(g), await tookOver(g, since: mark) else { return }
        phase = .answering
        requested = .start
        await publish()
        while current(g) {
            await wait(g, for: againAfterNudge > 0 ? .seconds(1) : (await lease.isPrimary() ? answeringPoll : poll))
            guard current(g) else { return }
            let source = requested ?? (againAfterNudge > 0 ? .nudge : .poll)
            requested = nil
            // The nudges this pass serves: those that came before it read the log.
            let served = nudged
            nudged = []
            let (stop, outcome) = await pass(runner, source, g, since: mark)
            if let stop {
                served.forEach { $0.answer.resume(returning: false) }
                await halt(stop, g)
                return
            }
            guard current(g) else {
                served.forEach { $0.answer.resume(returning: false) }
                return
            }
            if source == .nudge, outcome == .nothing, againAfterNudge < Self.againAfterNudgeLimit,
               await unseen(served.map(\.mark)), current(g) {
                againAfterNudge += 1
                Perf.mark("hub.nudge.again n=\(againAfterNudge)")
                nudged = served + nudged
            } else {
                againAfterNudge = 0
                served.forEach { $0.answer.resume(returning: true) }
            }
        }
    }

    /// The runner, made once and kept: its writer is this Mac's, read from the log. A failure is
    /// tried again, backing off; nil once the session is over.
    private func made(_ g: Int) async -> TurnRunner? {
        var delay: Duration = .seconds(1)
        while current(g) {
            if let runner { return runner }
            do {
                let writer = try await log.writer(for: device)
                guard current(g) else { return nil }
                let made = TurnRunner(log: log, writer: writer, lease: lease, brain: timed)
                runner = made
                return made
            } catch {
                Perf.mark("hub.writer.failed \(Self.kind(of: error))")
                try? await pause(delay)
                delay = min(delay * 2, .seconds(30))
            }
        }
        return nil
    }

    /// Why the start's takeover waits, or why it goes: the phone that holds a fresh lease may be
    /// answering the person's turn at the log's head, and a takeover then would have two brains run
    /// that turn and its tools (the phone's reply is refused by the lease, but its tools ran).
    public enum HoldOff: Equatable, Sendable {
        /// Wait, for the turn at the head (nil when the log could not be read).
        case hold(TurnRef?)
        /// Take over now, and why: `none` (no phone's fresh lease, or nothing of the person's
        /// waiting, at the first look), `replied` (the head is answered or gone on from),
        /// `lapsed` (the phone stopped renewing), `holder` (the lease is no longer a phone's),
        /// `bound` (the turn waited `standardHoldBound`).
        case go(String)
    }

    /// The hold's verdict on one look: `lease` the record as read (nil: none, or unreadable when
    /// `leaseRead` is false), `transcript` the log (nil: unreadable). Holds only over a lease of a
    /// device that is not a hub and not this Mac and has not expired, while a person's turn at the
    /// log's head goes unanswered and was said less than `bound` ago, and while the hold itself
    /// (from `began`) is younger than `bound`. A read that failed holds, within the same bound.
    static func holdOff(lease: Lease?, leaseRead: Bool, transcript: Transcript?, device: DeviceID,
                        now: Date, began: Date, bound: TimeInterval, holding: Bool) -> HoldOff {
        let goReason = holding ? nil : "none"
        if now.timeIntervalSince(began) >= bound { return .go("bound") }
        guard leaseRead else { return .hold(nil) }
        guard let lease, lease.holder != device, !HubLeaseProbe.isHub(lease.holder) else { return .go(goReason ?? "holder") }
        guard !lease.isExpired(at: now) else { return .go(goReason ?? "lapsed") }
        guard let transcript else { return .hold(nil) }
        let waiting = transcript.heads.compactMap { transcript[$0] }.filter { $0.role == .person }
        guard let newest = waiting.max(by: { $0.at < $1.at }) else { return .go(goReason ?? "replied") }
        if now.timeIntervalSince(newest.at) >= bound { return .go(goReason ?? "bound") }
        return .hold(newest.ref)
    }

    /// Before the start's one takeover: while a phone holds a fresh lease and the person's turn at
    /// the log's head is unanswered and young, the hub claims nothing and asks nothing, reading the
    /// lease and the log every `holdCheck`, until the phone's reply lands, its lease lapses or the
    /// bound passes; then the takeover goes. The loop has not started, so no pass's `acquire()`
    /// can claim over the phone meanwhile. False once the session is over.
    private func heldOff(_ g: Int) async -> Bool {
        let began = Date()
        var holding = false
        while current(g) {
            var lease: Lease?, leaseRead = true, transcript: Transcript?
            do {
                lease = try await database.fetch(Lease.recordID).flatMap(Lease.init(record:))
            } catch {
                leaseRead = false
            }
            if leaseRead, let lease, lease.holder != device, !HubLeaseProbe.isHub(lease.holder), !lease.isExpired(at: Date()) {
                transcript = try? await log.read()
            }
            guard current(g) else { return false }
            switch Self.holdOff(lease: lease, leaseRead: leaseRead, transcript: transcript, device: device,
                                now: Date(), began: began, bound: holdBound, holding: holding) {
            case .go(let why):
                if holding { Perf.mark("hub.lease.holdOff.end \(why) ms=\(Int(Date().timeIntervalSince(began) * 1000))") }
                return true
            case .hold:
                if !holding {
                    holding = true
                    Perf.mark("hub.lease.holdOff.begin")
                    phase = .deferring
                    await publish()
                }
                try? await pause(holdCheck)
            }
        }
        return false
    }

    /// The start's one takeover, sent again until it is answered, and refused by the lease once it
    /// has been abandoned since the session's `mark`. False once the session is over.
    private func tookOver(_ g: Int, since mark: Int) async -> Bool {
        var delay: Duration = .seconds(1)
        while current(g) {
            do {
                let outcome = try await lease.takeOver(since: mark)
                guard current(g) else { return false }
                takeovers += 1
                Perf.mark("hub.lease.takeOver \(Self.name(of: outcome))")
                return true
            } catch {
                guard current(g) else { return false }
                Perf.mark("hub.lease.takeOver.failed \(Self.kind(of: error))")
                try? await pause(delay)
                delay = min(delay * 2, .seconds(30))
            }
        }
        return false
    }

    /// Waits for a trigger or the poll, whichever is first. At once when a pass is asked for.
    private func wait(_ g: Int, for interval: Duration) async {
        guard requested == nil else { return }
        let pausing = Task { [pause] in try await pause(interval) }
        waiting = pausing
        _ = await withTaskCancellationHandler { await pausing.result } onCancel: { pausing.cancel() }
        if waiting == pausing { waiting = nil }
    }

    /// One pass: the lease asked for if this Mac does not hold it, then whatever waits answered.
    /// Every claim of it is made since the session's `mark`, so none is made after a stop's
    /// abandon. A reason to stop the mind, or nil.
    private func pass(_ runner: TurnRunner, _ source: Trigger, _ g: Int, since mark: Int) async -> (Stop?, Pass.Outcome?) {
        passing = true
        defer { passing = false }
        passes += 1
        clock.begin(source.rawValue)
        if !(await lease.isPrimary()) {
            // A lease asked for may have been another device's meanwhile, with turns answered
            // there: words are not heard ahead until a pass has told the mind the log again.
            hearReady = false
            // Lapsed, or taken: asked for, never taken from a holder this Mac yielded to.
            do {
                let outcome = try await lease.acquire(since: mark)
                Perf.mark("hub.lease.acquire \(Self.name(of: outcome))")
            } catch {
                Perf.mark("hub.lease.acquire.failed \(Self.kind(of: error))")
            }
        }
        let outcome: Pass.Outcome
        do {
            let picker = model
            outcome = try await runner.answerPending(since: mark, choosingFrom: { Self.chosen(said: $0, picker: picker) }) == nil
                ? .nothing : .answered
        } catch TurnRunnerError.notPrimary {
            outcome = .elsewhere
        } catch TurnRunnerError.displaced {
            outcome = .displaced
        } catch {
            // The runner wraps what the brain threw; the stop is judged on that.
            var error = error
            if case TurnRunnerError.answerFailed(_, let underlying) = error { error = underlying }
            if !current(g) || error is CancellationError {
                clock.end("cancelled")
                return (nil, nil)
            }
            if let stop = Self.stop(for: error) {
                clock.end(Self.kind(of: error))
                return (stop, nil)
            }
            outcome = .failed(Self.kind(of: error))
        }
        guard current(g) else {
            clock.end("cancelled")
            return (nil, nil)
        }
        clock.end(Self.name(of: outcome))
        switch outcome {
        // A pass that answered told the mind the log as it read it, and wrote under the lease.
        case .answered: hearReady = true
        case .nothing: break
        case .elsewhere, .displaced, .failed: hearReady = false
        }
        lastPass = Pass(outcome: outcome, trigger: source, at: Date())
        await publish()
        return (nil, outcome)
    }

    /// The model a turn is answered with: the person's choice in the zone (`ModelChoice`), which
    /// the device they hold says before it hands this Mac a turn, or this Mac's own picker where no
    /// device has said. A pass is handed the choice by the runner, read in the request that reads
    /// the log's newest turns, and only by a pass with a turn to answer
    /// (`answerPending(since:choosingFrom:)`).
    private static func chosen(said: ClaudeModel?, picker: @Sendable () -> ClaudeModel) -> ClaudeModel {
        let model = said ?? picker()
        Perf.mark("hub.pass.model \(model.rawValue) \(said == nil ? "picker" : "chosen")")
        return model
    }

    /// The model the start gives the process: the choice in the zone, one fetch by ID, or the
    /// picker where no device has said or the record cannot be read.
    private func startingModel() async -> ClaudeModel {
        ((try? await ModelChoice.read(from: database)) ?? nil) ?? model()
    }

    /// The mind stops, saying why: the lease let go and the process shut down. The session ends
    /// here, and nothing more is done until it is started again.
    private func halt(_ stop: Stop, _ g: Int) async {
        guard current(g) else { return }
        hearReady = false
        await lease.abandon()
        _ = await brain.shutdown()
        guard current(g) else { return }
        if stop == .signedOut { loginState = .signedOut }
        phase = .stopped(stop)
        releaseNudges()
        session = nil
        Perf.mark("hub.mind.stopped \(Self.name(of: stop))")
        await publish()
    }

    private func publish() async {
        observe(await snapshot())
    }

    /// The errors that stop the mind rather than fail a pass.
    static func stop(for error: any Error) -> Stop? {
        switch error as? NativeBrainError {
        case .notSignedIn?: .signedOut
        case .notStarted(let why)?: .notStarted(why)
        case .ledgerUnreadable(let why)?: .ledgerUnreadable(why)
        case .stalled(let stall)?: .stalled(stall)
        default: nil
        }
    }

    /// A failure's kind for a mark or the menu: the error's type and case and, for a database
    /// error, the record it names. Nothing a turn holds, and none of the strings Claude Code gave.
    static func kind(of error: any Error) -> String {
        switch error {
        case let e as NativeBrainError:
            switch e {
            case .notSignedIn: return "notSignedIn"
            case .notStarted: return "notStarted"
            case .failed: return "failed"
            case .unresolved: return "unresolved"
            case .ledgerUnreadable: return "ledgerUnreadable"
            case .stalled(.silent): return "stalled silent"
            case .stalled(.tooLong): return "stalled tooLong"
            }
        case RecordDatabaseError.serverRecordChanged(let id, _): return "serverRecordChanged \(id.name)"
        case RecordDatabaseError.unknownItem(let id): return "unknownItem \(id.name)"
        case RecordDatabaseError.unavailable(let underlying):
            return "unavailable \((underlying as NSError).domain)/\((underlying as NSError).code)"
        case RecordDatabaseError.rejected(let underlying):
            return "rejected \((underlying as NSError).domain)/\((underlying as NSError).code)"
        default: return "\(type(of: error))"
        }
    }

    static func name(of outcome: LeaseOutcome) -> String {
        switch outcome {
        case .primary: "primary"
        case .held: "held"
        case .unreachable: "unreachable"
        case .contended: "contended"
        }
    }

    static func name(of outcome: Pass.Outcome) -> String {
        switch outcome {
        case .nothing: "nothing"
        case .answered: "answered"
        case .elsewhere: "elsewhere"
        case .displaced: "displaced"
        case .failed(let kind): "failed \(kind)"
        }
    }

    static func name(of stop: Stop) -> String {
        switch stop {
        case .signedOut: "signedOut"
        case .loginUnknown: "loginUnknown"
        case .notStarted: "notStarted"
        case .ledgerUnreadable: "ledgerUnreadable"
        case .home: "home"
        case .stalled(.silent): "stalled silent"
        case .stalled(.tooLong): "stalled tooLong"
        }
    }
}

extension HubMind.Phase {
    /// The phase's name for a log line: a stop by its kind, never the words a reason carries.
    public var name: String {
        switch self {
        case .off: "off"
        case .starting: "starting"
        case .deferring: "deferring"
        case .answering: "answering"
        case .asleep: "asleep"
        case .stopped(let stop): "stopped " + HubMind.name(of: stop)
        }
    }
}
