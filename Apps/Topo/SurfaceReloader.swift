import Foundation
import WidgetKit

/// Every reload of the widgets' timelines goes through here, so a burst of writes — the mind
/// setting a slot, then its image, then another slot — is one reload and not a storm WidgetKit
/// budgets against the app: a write asks for a reload, and the reload happens once, `window`
/// after the first ask, for every ask made in between.
@MainActor
final class SurfaceReloader {
    static let window: Duration = .seconds(2)
    static let shared = SurfaceReloader()

    /// Runs `body` once `delay` has passed. The app's is a task's sleep; a suite's is a clock it
    /// moves.
    typealias Schedule = @MainActor (Duration, @escaping @MainActor () -> Void) -> Void

    private let reloadKind: @MainActor (String) -> Void
    private let reloadEverything: @MainActor () -> Void
    private let schedule: Schedule
    /// The kinds a reload is already scheduled for.
    private var scheduled: Set<String> = []

    init(reloadKind: @escaping @MainActor (String) -> Void = { WidgetCenter.shared.reloadTimelines(ofKind: $0) },
         reloadEverything: @escaping @MainActor () -> Void = { WidgetCenter.shared.reloadAllTimelines() },
         schedule: @escaping Schedule = { delay, body in
             Task { @MainActor in
                 try? await Task.sleep(for: delay)
                 body()
             }
         }) {
        self.reloadKind = reloadKind
        self.reloadEverything = reloadEverything
        self.schedule = schedule
    }

    /// Asks for the timelines of `kind` to be read again.
    func reload(kind: String = SurfaceStore.kind) {
        guard scheduled.insert(kind).inserted else { return }
        schedule(Self.window) { [self] in
            scheduled.remove(kind)
            reloadKind(kind)
        }
    }

    /// Every timeline, now: a sign-out, which has to take the conversation off a lock screen at
    /// once rather than two seconds later.
    func reloadAll() {
        reloadEverything()
    }
}
