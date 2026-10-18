import Foundation

/// iOS's background time as the lifecycle asks for it: `UIApplication` in the app, a double in
/// the suite.
@MainActor
public protocol BackgroundTime: AnyObject {
    /// Asks for background time; `expiration` is iOS's handler for its running out. Answers
    /// `GraceBudget.refused` when iOS will not give any.
    func begin(expiration: @escaping @MainActor () -> Void) -> Int
    func end(_ task: Int)
    /// `backgroundTimeRemaining`: infinite in the foreground, and inside `DidEnterBackground`
    /// itself, finite from the first tick after.
    var remaining: TimeInterval { get }
}

/// iOS's continued-processing task for a turn (`BGContinuedProcessingTask`): the app's wrapper of
/// it, a double in the suite. It keeps the app running behind another app until it is completed
/// or iOS expires it — the person's cancel in the system's pill included.
@MainActor
public protocol ContinuedTask: AnyObject {
    /// Sets iOS's handler for the task's expiry.
    func onExpiry(_ handler: @escaping @MainActor () -> Void)
    func complete(success: Bool)
}

/// How a turn's continued-processing task reports progress: iOS expires a task whose progress
/// stops moving, and a turn's length is not known, so the fraction rises with time alone —
/// `t / (t + halfway)` of `total` units — and never reaches the end before the turn does. One
/// unit at least changes per `tick` for the first three hours.
public enum TurnProgress {
    public static let total: Int64 = 1_000_000
    public static let tick: Duration = .seconds(2)
    /// When the bar is half full.
    public static let halfway: TimeInterval = 60

    public static func completed(after elapsed: TimeInterval) -> Int64 {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        return min(total - 1, Int64((Double(total) * elapsed / (elapsed + halfway)).rounded(.down)))
    }
}

/// How the grace is spent. Measured on an iPhone 15 Pro (sprint P0): iOS grants 29.2–29.3 s after
/// `DidEnterBackground`, the expiration handler fires with about 5 s still showing, so about 26 s
/// is usable, and ending Claude Code takes 3–4 s. The process is ended with 8 s of the usable time
/// left, so the teardown lands well inside it.
public enum GraceBudget {
    /// What `BackgroundTime.begin` answers when iOS refuses (`UIBackgroundTaskIdentifier.invalid`).
    public static let refused = 0
    /// When the remaining time is first read: `backgroundTimeRemaining` is infinite inside the
    /// notification and finite a tick later.
    public static let firstTick: Duration = .seconds(1)
    /// What iOS's expiration handler leaves on the clock when it fires.
    public static let expiryMargin: TimeInterval = 5
    /// The usable time kept back for the teardown.
    public static let reserve: TimeInterval = 8
    /// What is assumed when the reading is not a grant (still infinite, or absurd): the measured
    /// grant less the tick already spent.
    public static let assumedRemaining: TimeInterval = 28
    /// How long a teardown may take to be confirmed: the reserve less a second for ending the
    /// background task after it.
    public static let teardownBound: Duration = .seconds(7)
    /// The same once the expiration handler has fired: what the handler leaves, less a second.
    public static let expiredTeardownBound: Duration = .seconds(4)
    /// How long after the expiration handler the background task is held for a teardown still
    /// running before it is ended without it: just short of what the handler leaves.
    public static let expiryHold: Duration = .milliseconds(4_500)

    /// Whether a `backgroundTimeRemaining` reading is a grant rather than the foreground's infinity.
    public static func isGrant(_ remaining: TimeInterval) -> Bool {
        remaining.isFinite && remaining <= 600
    }

    /// How long a turn in flight may run, from the first tick, before the process is ended.
    public static func teardownDelay(remaining: TimeInterval) -> Duration {
        let reading = isGrant(remaining) ? remaining : assumedRemaining
        return .milliseconds(Int64((max(0, reading - expiryMargin - reserve) * 1000).rounded()))
    }
}

/// The app's lifecycle, carried to the session: the foreground starts (or keeps) the resident
/// process, and the background asks iOS for time, reads how much it got a tick later, gives the
/// session that budget less the reserve, and ends the background task once the session answers —
/// the process ended and confirmed, or kept because the app came back. Each foreground and
/// background is a generation the session is told, so the two can never act out of order on it.
@MainActor
public final class GuestLifecycle {
    public let session: GuestSession
    private let time: BackgroundTime
    private let sleep: Sleep
    private let report: @MainActor (GuestSession.BackgroundOutcome) -> Void
    private var generation = 0
    /// The background task each background generation holds, until it is ended.
    private var tasks: [Int: Int] = [:]
    /// The turn the app has open, by the number `turnBegan` gave it.
    private var openTurn: Int?
    private var turnCount = 0
    /// The continued-processing task held, for `heldTurn`.
    private var continued: ContinuedTask?
    private var heldTurn: Int?
    /// Whether `heldTurn` succeeded, once it has ended.
    private var heldResult: Bool?
    /// Tasks of turns a later turn was sent after before their end was heard, each completed with
    /// its own turn's result.
    private var parked: [Int: ContinuedTask] = [:]
    /// The background generation the continued task is carrying, in place of the grace.
    private var carrying: Int?
    /// Between an expiry handed to the grace and the tick that completes the expired task.
    private var handingOff = false
    private var inBackground = false

    public init(session: GuestSession, time: BackgroundTime,
                sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
                report: @escaping @MainActor (GuestSession.BackgroundOutcome) -> Void = { _ in }) {
        self.session = session
        self.time = time
        self.sleep = sleep
        self.report = report
    }

    /// Whether a background task is held.
    public var holdsBackgroundTime: Bool { !tasks.isEmpty }

    /// Whether a continued-processing task is held.
    public var holdsContinuedTask: Bool { continued != nil }

    // MARK: - A turn's continued-processing task

    /// A turn was sent: the answer names it to `held` and `turnEnded`. A task still held for an
    /// earlier turn whose end has not been heard yet is parked, to be completed at that end, so the
    /// new turn's task can be held.
    public func turnBegan() -> Int {
        turnCount += 1
        openTurn = turnCount
        if let task = continued, let turn = heldTurn, heldResult == nil, carrying == nil, !handingOff {
            parked[turn] = task
            continued = nil
            heldTurn = nil
        }
        return turnCount
    }

    /// iOS started the continued-processing task asked for `turn`. Held while the turn is open
    /// and the app has not gone to the background without it; otherwise completed at once — a
    /// task arriving after its turn ended, or after the way out began on the grace, is not
    /// needed and holding it would keep the app awake for nothing.
    public func held(_ task: ContinuedTask, turn: Int) {
        guard turn == openTurn, continued == nil, !inBackground else {
            task.complete(success: turn != openTurn)
            return
        }
        continued = task
        heldTurn = turn
        heldResult = nil
        task.onExpiry { [weak self, weak task] in
            guard let self, let task else { return }
            self.continuedExpired(task)
        }
    }

    /// `turn` ended: `succeeded` when its answer arrived. Its task is completed with that, now in
    /// the foreground; in the background, once the way out it carries has ended the process, and
    /// across an expiry handed to the grace, at the tick that hands it over.
    public func turnEnded(_ turn: Int, succeeded: Bool) {
        parked.removeValue(forKey: turn)?.complete(success: succeeded)
        if turn == openTurn { openTurn = nil }
        guard turn == heldTurn else { return }
        heldResult = succeeded
        if carrying == nil, !handingOff { completeContinued(success: succeeded) }
    }

    // MARK: - The app's lifecycle

    public func willEnterForeground() {
        inBackground = false
        generation += 1
        let mine = generation
        let session = session
        Task { await session.foreground(generation: mine) }
    }

    public func didEnterBackground() {
        inBackground = true
        generation += 1
        let mine = generation
        let session = session
        if continued != nil {
            // The continued task holds the app up, so no grace is begun: the turn is waited for
            // with no deadline, and the task is completed once the process is ended. Its expiry
            // hands what is left to the grace (`continuedExpired`).
            carrying = mine
            Task { [weak self] in
                let outcome = await session.background(budget: nil, generation: mine)
                guard let self else { return }
                self.report(outcome)
                self.endTask(mine)
                guard self.carrying == mine else { return }
                self.carrying = nil
                // A turn abandoned at the teardown point is a task that did not do what it was for.
                if case .ended(.abandoned, _) = outcome {
                    self.completeContinued(success: false)
                } else if let result = self.heldResult {
                    self.completeContinued(success: result)
                }
                // Otherwise the turn's end has not been heard: back in front with it still running,
                // the task stays for the next way out, and `turnEnded` completes it with its result.
            }
            return
        }
        beginGrace(mine)
        Task { [weak self, sleep] in
            try? await sleep(GraceBudget.firstTick)
            guard let self else { return }
            guard self.generation == mine else {
                // The app came back within the tick: nothing to end.
                self.endTask(mine)
                return
            }
            let budget = GraceBudget.teardownDelay(remaining: self.time.remaining)
            let outcome = await session.background(budget: budget, generation: mine)
            self.report(outcome)
            self.endTask(mine)
        }
    }

    /// Asks iOS for the grace for background `mine`; answers whether it was given.
    @discardableResult
    private func beginGrace(_ mine: Int) -> Bool {
        let session = session
        let task = time.begin { [weak self] in
            // The backstop: the teardown is budgeted to land before this. The process is told to
            // end now, and the task stays open until the teardown answers below, so iOS does not
            // suspend the app with the process alive — or, if the teardown has not answered just
            // short of what the handler leaves, it is ended without it and that is said.
            Task { await session.expire(generation: mine) }
            self?.holdAfterExpiry(mine)
        }
        guard task != GraceBudget.refused else { return false }
        tasks[mine] = task
        return true
    }

    /// iOS expired the continued task, or the person cancelled it. In the foreground the task is
    /// let go and the turn runs on. Carrying a way out, the grace is begun first, and the task is
    /// completed a tick later rather than at once, since iOS grants the grace's assertion
    /// asynchronously; a turn that ends inside that tick leaves it to the tick. The grace is the
    /// one iOS answered an identifier for: nothing confirms the assertion further. The waiting turn
    /// is then given what the grace allows, read at that tick, or a tick later when the first
    /// reading is not a grant, and assumed (`assumedRemaining` less that tick) when neither is. How
    /// much grace iOS gives after a continued task expires is not measured. A grace iOS refuses leaves nothing
    /// to hand to: the process is ended now, and the expired task is held until the teardown
    /// answers, or let go just short of what an expiry leaves.
    private func continuedExpired(_ task: ContinuedTask) {
        if let turn = parked.first(where: { $0.value === task })?.key {
            parked.removeValue(forKey: turn)?.complete(success: false)
            return
        }
        guard task === continued else { return }
        guard let mine = carrying else {
            completeContinued(success: false)
            return
        }
        let session = session
        guard beginGrace(mine) else {
            // `carrying` stays: the way out's answer completes the task.
            report(.graceRefused)
            Task { await session.expire(generation: mine) }
            Task { [weak self, weak task, sleep] in
                try? await sleep(GraceBudget.expiryHold)
                // The task is let go whatever came of the way out since: one that answered `kept`,
                // the turn still running, leaves it held, and an expired task is never kept.
                guard let self, let task, task === self.continued else { return }
                if self.carrying == mine {
                    self.carrying = nil
                    self.report(.outOfTime)
                }
                self.completeContinued(success: false)
            }
            return
        }
        carrying = nil
        handingOff = true
        report(.handedToGrace)
        Task { [weak self, weak task, sleep] in
            try? await sleep(GraceBudget.firstTick)
            guard let self else { return }
            self.handingOff = false
            if let task, task === self.continued { self.completeContinued(success: false) }
            guard self.generation == mine else { return }
            var remaining = self.time.remaining
            if !GraceBudget.isGrant(remaining) {
                // Read again once the expired task is let go; still no grant, the grace is taken
                // as the one iOS gave its identifier for and assumed, less the extra tick.
                try? await sleep(GraceBudget.firstTick)
                guard self.generation == mine else { return }
                remaining = self.time.remaining
                if !GraceBudget.isGrant(remaining) {
                    remaining = GraceBudget.assumedRemaining - GraceBudget.firstTick / .seconds(1)
                }
            }
            await session.limit(budget: GraceBudget.teardownDelay(remaining: remaining), generation: mine)
        }
    }

    private func completeContinued(success: Bool) {
        guard let task = continued else { return }
        continued = nil
        heldTurn = nil
        heldResult = nil
        task.complete(success: success)
    }

    private func holdAfterExpiry(_ generation: Int) {
        Task { [weak self, sleep] in
            try? await sleep(GraceBudget.expiryHold)
            guard let self, self.tasks[generation] != nil else { return }
            self.report(.outOfTime)
            self.endTask(generation)
        }
    }

    private func endTask(_ generation: Int) {
        guard let task = tasks.removeValue(forKey: generation) else { return }
        time.end(task)
    }
}
