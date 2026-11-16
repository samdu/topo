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
/// **Triggers.** A pass runs when one is asked for (`trigger`: the push of a turn being created)
/// and every `poll` otherwise. One pass at a time: a trigger while the loop waits starts the
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
    }

    public enum Phase: Sendable, Equatable {
        /// Turned off: no lease is claimed and no mind runs.
        case off
        /// Asking the login, starting the process, taking the lease.
        case starting
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
    private let lease: PrimaryLease
    private let log: TurnLog
    private let login: @Sendable () async -> MindLogin
    private let prepare: @Sendable () throws -> Void
    private let model: @Sendable () -> ClaudeModel
    private let poll: Duration
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

    /// - Parameters:
    ///   - database: the log's store; the lease, the log and the writer all go through it.
    ///   - device: this Mac's device ID (`mac-` and a UUID).
    ///   - endpoint: where this Mac answers lease probes.
    ///   - login: asks Claude Code whether it is signed in (`MindLogin.check`).
    ///   - prepare: makes the mind's home (`MindHome.prepare`) before anything starts.
    ///   - model: the model setting, read at every start and pass.
    ///   - poll: the backstop interval between passes.
    ///   - leaseSleep: how the lease's heartbeats wait; tests drive it.
    ///   - pause: how the loop and its retries wait; tests drive it.
    ///   - observe: told every change, on no particular actor.
    public init(database: any RecordDatabase, device: DeviceID, endpoint: String?, probe: any LeaseProbe,
                brain: NativeBrain, login: @escaping @Sendable () async -> MindLogin,
                prepare: @escaping @Sendable () throws -> Void = {},
                model: @escaping @Sendable () -> ClaudeModel, timing: LeaseTiming = .standard,
                poll: Duration = HubMind.standardPoll,
                leaseSleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                observe: @escaping @Sendable (Snapshot) -> Void = { _ in }) {
        let timedDatabase = TimedDatabase(base: database, clock: clock)
        self.database = timedDatabase
        self.device = device
        self.brain = brain
        self.timed = TimedBrain(inner: brain, clock: clock)
        self.lease = PrimaryLease(database: timedDatabase, device: device, endpoint: endpoint, probe: probe,
                                  timing: timing, sleep: leaseSleep)
        self.log = TurnLog(database: timedDatabase)
        self.login = login
        self.prepare = prepare
        self.model = model
        self.poll = poll
        self.pause = pause
        self.observe = observe
    }

    /// Ten seconds. A pass with nothing waiting is one read of the log (the zone's change feed and
    /// a fetch by ID of each device's next sequence number) and touches nothing else; the push is
    /// the fast path, and this bounds what a dropped one costs. The phone's loop reads every five
    /// seconds while it is on the screen; this is half that.
    public static let standardPoll: Duration = .seconds(10)

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
        await running?.value
    }

    private func current(_ g: Int) -> Bool { g == generation && !Task.isCancelled }

    private func run(_ g: Int) async {
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
            await brain.use(model: model())
            try await brain.start()
        } catch {
            guard current(g) else { return }
            await halt(Self.stop(for: error) ?? .notStarted(String(describing: error)), g)
            return
        }
        guard current(g), let runner = await made(g) else { return }
        guard await tookOver(g) else { return }
        phase = .answering
        requested = .start
        await publish()
        while current(g) {
            await wait(g)
            guard current(g) else { return }
            let source = requested ?? .poll
            requested = nil
            if let stop = await pass(runner, source, g) {
                await halt(stop, g)
                return
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

    /// The start's one takeover, sent again until it is answered. False once the session is over.
    private func tookOver(_ g: Int) async -> Bool {
        var delay: Duration = .seconds(1)
        while current(g) {
            do {
                let outcome = try await lease.takeOver()
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
    private func wait(_ g: Int) async {
        guard requested == nil else { return }
        let pausing = Task { [pause, poll] in try await pause(poll) }
        waiting = pausing
        _ = await withTaskCancellationHandler { await pausing.result } onCancel: { pausing.cancel() }
        if waiting == pausing { waiting = nil }
    }

    /// One pass: the lease asked for if this Mac does not hold it, then whatever waits answered.
    /// A reason to stop the mind, or nil.
    private func pass(_ runner: TurnRunner, _ source: Trigger, _ g: Int) async -> Stop? {
        passes += 1
        clock.begin(source.rawValue)
        if !(await lease.isPrimary()) {
            // Lapsed, or taken: asked for, never taken from a holder this Mac yielded to.
            do {
                let outcome = try await lease.acquire()
                Perf.mark("hub.lease.acquire \(Self.name(of: outcome))")
            } catch {
                Perf.mark("hub.lease.acquire.failed \(Self.kind(of: error))")
            }
        }
        let outcome: Pass.Outcome
        do {
            outcome = try await runner.answerPending(model: model()) == nil ? .nothing : .answered
        } catch TurnRunnerError.notPrimary {
            outcome = .elsewhere
        } catch TurnRunnerError.displaced {
            outcome = .displaced
        } catch {
            if !current(g) || error is CancellationError {
                clock.end("cancelled")
                return nil
            }
            if let stop = Self.stop(for: error) {
                clock.end(Self.kind(of: error))
                return stop
            }
            outcome = .failed(Self.kind(of: error))
        }
        guard current(g) else {
            clock.end("cancelled")
            return nil
        }
        clock.end(Self.name(of: outcome))
        lastPass = Pass(outcome: outcome, trigger: source, at: Date())
        await publish()
        return nil
    }

    /// The mind stops, saying why: the lease let go and the process shut down. The session ends
    /// here, and nothing more is done until it is started again.
    private func halt(_ stop: Stop, _ g: Int) async {
        guard current(g) else { return }
        await lease.abandon()
        _ = await brain.shutdown()
        guard current(g) else { return }
        if stop == .signedOut { loginState = .signedOut }
        phase = .stopped(stop)
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
        case .answering: "answering"
        case .asleep: "asleep"
        case .stopped(let stop): "stopped " + HubMind.name(of: stop)
        }
    }
}
