import Foundation

/// iOS's background time as the lifecycle asks for it: `UIApplication` in the app, a double in
/// the suite.
@MainActor
public protocol BackgroundTime: AnyObject {
    /// Asks for background time; `expiration` is iOS's handler for its running out.
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
    /// The continued-processing task held for the open turn.
    private var continued: ContinuedTask?
    /// The background generation the continued task is carrying, in place of the grace.
    private var carrying: Int?
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

    /// A turn was sent: the answer names it to `held` and `turnEnded`.
    public func turnBegan() -> Int {
        turnCount += 1
        openTurn = turnCount
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
        task.onExpiry { [weak self, weak task] in
            guard let self, let task else { return }
            self.continuedExpired(task)
        }
    }

    /// `turn` ended, however it went. In the foreground its task is completed now; in the
    /// background the way out it carries completes it once the process is ended.
    public func turnEnded(_ turn: Int) {
        guard turn == openTurn else { return }
        openTurn = nil
        if carrying == nil { completeContinued(success: true) }
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
                // Back in front with the turn still running: the task stays, for the next way out.
                if outcome != .kept || self.openTurn == nil { self.completeContinued(success: true) }
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

    /// Asks iOS for the grace for background `mine`.
    private func beginGrace(_ mine: Int) {
        let session = session
        tasks[mine] = time.begin { [weak self] in
            // The backstop: the teardown is budgeted to land before this. The process is told to
            // end now, and the task stays open until the teardown answers below, so iOS does not
            // suspend the app with the process alive — or, if the teardown has not answered just
            // short of what the handler leaves, it is ended without it and that is said.
            Task { await session.expire(generation: mine) }
            self?.holdAfterExpiry(mine)
        }
    }

    /// iOS expired the continued task, or the person cancelled it. Carrying a way out, the grace is
    /// begun first — so the app is never without a hold — then the task is completed, and the
    /// waiting turn is given what the grace allows, read a tick later (two when the first reading
    /// is not yet a grant). In the foreground the task is let go and the turn runs on.
    private func continuedExpired(_ task: ContinuedTask) {
        guard task === continued else { return }
        guard let mine = carrying else {
            completeContinued(success: false)
            return
        }
        carrying = nil
        beginGrace(mine)
        completeContinued(success: false)
        report(.handedToGrace)
        let session = session
        Task { [weak self, sleep] in
            try? await sleep(GraceBudget.firstTick)
            guard let self, self.generation == mine else { return }
            if !GraceBudget.isGrant(self.time.remaining) {
                try? await sleep(GraceBudget.firstTick)
                guard self.generation == mine else { return }
            }
            await session.limit(budget: GraceBudget.teardownDelay(remaining: self.time.remaining), generation: mine)
        }
    }

    private func completeContinued(success: Bool) {
        guard let task = continued else { return }
        continued = nil
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
