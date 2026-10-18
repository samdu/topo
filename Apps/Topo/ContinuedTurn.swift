import BackgroundTasks
import Foundation
import TopoUserland

/// A turn's `BGContinuedProcessingTask`, as `GuestLifecycle` holds it: its progress rises with
/// time (`TurnProgress`), since iOS expires a task whose progress stands still, and is full only
/// at a completion that succeeded.
@available(iOS 26, *)
@MainActor
final class ContinuedTurnTask: ContinuedTask {
    private let task: BGContinuedProcessingTask
    private var ticker: Task<Void, Never>?

    init(_ task: BGContinuedProcessingTask) {
        self.task = task
        task.progress.totalUnitCount = TurnProgress.total
        let started = ContinuousClock.now
        ticker = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.task.progress.completedUnitCount = TurnProgress.completed(after: (ContinuousClock.now - started) / .seconds(1))
                try? await Task.sleep(for: TurnProgress.tick)
            }
        }
    }

    func onExpiry(_ handler: @escaping @MainActor () -> Void) {
        // The queue the handler is called on is not documented: the grace is begun from the main
        // actor either way, at once when it is already there.
        task.expirationHandler = { @Sendable in
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler() }
            } else {
                Task { @MainActor in handler() }
            }
        }
    }

    func complete(success: Bool) {
        ticker?.cancel()
        ticker = nil
        if success { task.progress.completedUnitCount = TurnProgress.total }
        task.setTaskCompleted(success: success)
    }
}

/// Asks iOS to keep the app running behind another app while a turn sent in front is in flight:
/// one `BGContinuedProcessingTaskRequest` a turn, `zone.hexagon.topo.turn.<uuid>`, under the
/// wildcard the Info.plist permits and registered once a process. The request fails rather than
/// queues, since a turn's task is only worth having now; a refusal leaves the turn to the grace.
/// The pill's words are fixed, never the turn's: it is drawn on the lock screen.
@available(iOS 26, *)
@MainActor
enum ContinuedTurns {
    nonisolated static let prefix = "zone.hexagon.topo.turn"
    nonisolated static let title = "Topo"
    nonisolated static let subtitle = "Working on a reply"

    /// Whether the wildcard is registered, once asked: registering it twice kills the app.
    private static var registered: Bool?
    /// The turns asked for and not yet started, by the identifier their request carries.
    private static var waiting: [String: (lifecycle: GuestLifecycle, turn: Int)] = [:]

    static func submit(turn: Int, to lifecycle: GuestLifecycle, log: @escaping @Sendable (String) -> Void) {
        guard register() else {
            log("continued: \(prefix).* is not permitted; the turn has the grace alone")
            return
        }
        let identifier = "\(prefix).\(UUID().uuidString)"
        waiting[identifier] = (lifecycle, turn)
        // Made and submitted here, at the send and on the main actor, so the app is in front for
        // both: the request "creates an instance on behalf of the currently foregrounded app"
        // (`BGTaskRequest.h`), and the system takes it from an app in front. The synchronous submit
        // is used on every iOS: the main-thread caution in `BGTaskScheduler.h` is on iOS 27's
        // completion-handler form alone, whose submission lands after the call returns.
        do {
            try BGTaskScheduler.shared.submit(ContinuedTurns.request(identifier: identifier))
        } catch {
            waiting.removeValue(forKey: identifier)
            log("continued: refused (\(error)); the turn has the grace alone")
        }
    }

    /// A turn's request: the fixed words, and the `fail` strategy.
    static func request(identifier: String) -> BGContinuedProcessingTaskRequest {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        return request
    }

    /// Registered at the first turn rather than at launch. `BGTaskScheduler.h`: "You must register
    /// launch handlers before your application finishes launching (``BGContinuedProcessingTask``
    /// registrations are exempt from this requirement)."
    private static func register() -> Bool {
        if let registered { return registered }
        let done = BGTaskScheduler.shared.register(forTaskWithIdentifier: "\(prefix).*", using: .main) { task in
            MainActor.assumeIsolated { launched(task) }
        }
        registered = done
        return done
    }

    private static func launched(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask,
              let asked = waiting.removeValue(forKey: task.identifier) else {
            task.setTaskCompleted(success: false)
            return
        }
        asked.lifecycle.held(ContinuedTurnTask(task), turn: asked.turn)
    }
}
