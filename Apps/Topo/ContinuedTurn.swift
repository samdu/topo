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
/// wildcard the Info.plist permits. The launch handler is registered for that one identifier just
/// before its request is submitted, as Apple's "Performing long-running tasks on iOS and iPadOS"
/// does: a handler registered for the wildcard pattern itself is refused. The request fails rather
/// than queues, since a turn's task is only worth having now; a refusal leaves the turn to the
/// grace. The pill's words are fixed, never the turn's: it is drawn on the lock screen.
@available(iOS 26, *)
@MainActor
enum ContinuedTurns {
    nonisolated static let prefix = "zone.hexagon.topo.turn"
    nonisolated static let title = "Topo"
    nonisolated static let subtitle = "Working on a reply"

    /// The scheduler's two calls, apart so a suite can see what each is given.
    struct Scheduler {
        /// Registers a launch handler for one identifier, called on the main queue; false when
        /// iOS refuses it.
        var register: @MainActor (_ identifier: String, _ launched: @escaping @MainActor (BGTask) -> Void) -> Bool
        /// Submits a request already made on the main actor, answering with the error that refused
        /// it, or nil, on the main actor.
        var submit: @MainActor (_ request: BGContinuedProcessingTaskRequest, _ answer: @escaping @MainActor (Error?) -> Void) -> Void

        static let system = Scheduler(
            register: { identifier, launched in
                BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                    MainActor.assumeIsolated { launched(task) }
                }
            },
            submit: { request, answer in
                // On iOS 27 the throwing submit is deprecated, since it cannot report every failure,
                // and the completion-handler form is not called from the main thread
                // (`BGTaskScheduler.h`), so the submission lands a moment after the send: a Home
                // press inside that moment can find the app no longer in front and leave the turn
                // to the grace, which is the floor.
                if #available(iOS 27, *) {
                    let made = Made(request: request)
                    DispatchQueue.global(qos: .userInitiated).async {
                        BGTaskScheduler.shared.submitTaskRequest(made.request) { error in
                            let refusal = error.map { "\($0)" }
                            Task { @MainActor in answer(refusal.map(Refusal.init)) }
                        }
                    }
                } else {
                    do {
                        try BGTaskScheduler.shared.submit(request)
                        answer(nil)
                    } catch {
                        answer(error)
                    }
                }
            })
    }

    /// A request made on the main actor, carried to the queue that submits it and touched by
    /// nothing else after.
    private struct Made: @unchecked Sendable {
        let request: BGContinuedProcessingTaskRequest
    }

    /// A refusal carried across to the main actor as its description.
    struct Refusal: Error, CustomStringConvertible {
        let description: String
    }

    /// The turns asked for and not yet started, by the identifier their request carries.
    private static var waiting: [String: (lifecycle: GuestLifecycle, turn: Int, log: @Sendable (String) -> Void)] = [:]

    static func submit(turn: Int, to lifecycle: GuestLifecycle, log: @escaping @Sendable (String) -> Void,
                       scheduler: Scheduler = .system) {
        // A new identifier every turn, so none is registered twice, which ends the app.
        let identifier = "\(prefix).\(UUID().uuidString)"
        guard scheduler.register(identifier, { launched($0) }) else {
            log("continued: \(identifier) is not permitted; the turn has the grace alone")
            return
        }
        waiting[identifier] = (lifecycle, turn, log)
        // Made here, at the send and on the main actor, while the app is in front: the request
        // "creates an instance on behalf of the currently foregrounded app" (`BGTaskRequest.h`).
        scheduler.submit(request(identifier: identifier)) { error in
            if let error {
                waiting.removeValue(forKey: identifier)
                log("continued: refused (\(error)); the turn has the grace alone")
            } else {
                log("continued: asked for turn \(turn)")
            }
        }
    }

    /// A turn's request: the fixed words, and the `fail` strategy.
    nonisolated static func request(identifier: String) -> BGContinuedProcessingTaskRequest {
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        return request
    }

    private static func launched(_ task: BGTask) {
        guard let task = task as? BGContinuedProcessingTask,
              let asked = waiting.removeValue(forKey: task.identifier) else {
            GuestResident.note("continued: started for no turn asked; completed at once")
            task.setTaskCompleted(success: false)
            return
        }
        asked.log("continued: started for turn \(asked.turn)")
        asked.lifecycle.held(ContinuedTurnTask(task), turn: asked.turn)
    }
}
