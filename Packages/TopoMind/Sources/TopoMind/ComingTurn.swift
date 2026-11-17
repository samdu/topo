import Foundation
import TopoCore
import TopoTurn

/// A phone's heads-up that a turn is being saved, as the pass it began waits on it
/// (`HubMind.headsUp`): the hub's listener says the turn's ref once the phone's `saved` line
/// comes (`saved`), or that the heads-up ended without one (`end`: the bound, the connection
/// closed, a line that is not one); the mind ends it too as it stops. Another trigger during the
/// wait (`interrupt`) has the pass read the log again and wait on. The wait itself is bounded from
/// the heads-up, and a cancelled wait answers `gone` at once.
public final class ComingTurn: @unchecked Sendable {
    /// The turn's mark, as the phone's marks carry it, in lower case.
    public let mark: String
    private let deadline: ContinuousClock.Instant
    private let lock = NSLock()
    private var ref: TurnRef?
    private var told = false
    private var ended = false
    private var interrupted = false
    private var waiter: CheckedContinuation<TurnRunner.Coming, Never>?

    init(mark: String, bound: Duration) {
        self.mark = mark
        self.deadline = .now + bound
    }

    /// The turn is saved as `ref`. Only the first word counts, and none once the heads-up ended.
    public func saved(_ ref: TurnRef) {
        let waiter = lock.withLock { () -> CheckedContinuation<TurnRunner.Coming, Never>? in
            guard !ended, self.ref == nil else { return nil }
            self.ref = ref
            guard let waiter = self.waiter else { return nil }
            self.waiter = nil
            told = true
            return waiter
        }
        waiter?.resume(returning: .saved(ref))
    }

    /// No word of the turn is coming: the wait answers `gone`, now and from now.
    public func end() {
        let waiter = lock.withLock { () -> CheckedContinuation<TurnRunner.Coming, Never>? in
            ended = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: .gone)
    }

    /// Whether the turn's ref has come.
    var isSaved: Bool { lock.withLock { ref != nil } }

    /// Something else asked for a pass: the wait answers `other` once, so the pass reads the log
    /// again. Nothing once the ref has come or the heads-up ended.
    func interrupt() {
        let waiter = lock.withLock { () -> CheckedContinuation<TurnRunner.Coming, Never>? in
            guard ref == nil, !ended else { return nil }
            guard let waiter = self.waiter else {
                interrupted = true
                return nil
            }
            self.waiter = nil
            return waiter
        }
        waiter?.resume(returning: .other)
    }

    /// What the pass hears: the turn's ref once, `other` after an interrupt, `gone` once the
    /// heads-up ended, its bound passed, or the waiting task was cancelled.
    func wait() async -> TurnRunner.Coming {
        if let now = answerNow() { return now }
        let timer = Task { [deadline] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            self.timedOut()
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let now = lock.withLock { () -> TurnRunner.Coming? in
                    if let answer = pendingAnswer() { return answer }
                    if Task.isCancelled { return .gone }
                    waiter = continuation
                    return nil
                }
                if let now { continuation.resume(returning: now) }
            }
        } onCancel: {
            self.cancelled()
        }
    }

    private func answerNow() -> TurnRunner.Coming? {
        lock.withLock { pendingAnswer() }
    }

    /// Under the lock: what a wait answers without waiting, if anything.
    private func pendingAnswer() -> TurnRunner.Coming? {
        if let ref, !told {
            told = true
            return .saved(ref)
        }
        if ended || told || ContinuousClock.now >= deadline { return .gone }
        if interrupted {
            interrupted = false
            return .other
        }
        return nil
    }

    private func timedOut() {
        let waiter = lock.withLock { () -> CheckedContinuation<TurnRunner.Coming, Never>? in
            guard ref == nil else { return nil }
            ended = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: .gone)
    }

    private func cancelled() {
        let waiter = lock.withLock { () -> CheckedContinuation<TurnRunner.Coming, Never>? in
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(returning: .gone)
    }
}
