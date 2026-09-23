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

    /// How long a turn in flight may run, from the first tick, before the process is ended.
    public static func teardownDelay(remaining: TimeInterval) -> Duration {
        let reading = remaining.isFinite && remaining <= 600 ? remaining : assumedRemaining
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

    public func willEnterForeground() {
        generation += 1
        let mine = generation
        let session = session
        Task { await session.foreground(generation: mine) }
    }

    public func didEnterBackground() {
        generation += 1
        let mine = generation
        let session = session
        tasks[mine] = time.begin { [weak self] in
            // The backstop: the teardown is budgeted to land before this. The process is told to
            // end now, and the task stays open until the teardown answers below, so iOS does not
            // suspend the app with the process alive — or, if the teardown has not answered just
            // short of what the handler leaves, it is ended without it and that is said.
            Task { await session.expire(generation: mine) }
            self?.holdAfterExpiry(mine)
        }
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
