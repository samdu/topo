import Foundation

/// The life of a login, as the features that hold work under it see it. Every way a login ends —
/// the settings sheet (`SignOut`), a takeover (`Takeover`), a viewer's arrival (`ViewerArrival`),
/// and the phase leaving signed in on its own (`SignIn.refresh` finding the login gone, which
/// `DefaultSurface.follow` hears) — moves the epoch and runs the teardowns here, so a feature
/// registers once and is ended on all of them.
///
/// Two rules, and they are the whole of it:
/// - Work begun under a login takes `epoch` and, when it lands after an await, checks
///   `isCurrent` before it keeps or changes anything; one that finds it moved drops itself.
/// - A teardown (`onEnd`) runs under the moved epoch and never checks it: a teardown guarded by
///   `isCurrent` is one that never runs.
@MainActor
final class LoginLife {
    static let shared = LoginLife()

    /// A login's mark: current until the login it was taken under ends.
    @MainActor
    struct Epoch {
        fileprivate let value: Int
        fileprivate let life: LoginLife

        /// Whether the login this was taken under still stands.
        var isCurrent: Bool { life.count == value }
    }

    private var count = 0
    private var teardowns: [@MainActor () -> Void] = []
    private var ending: [Task<Void, Never>] = []

    init() {}

    /// The standing login's mark, for work about to await something.
    var epoch: Epoch { Epoch(value: count, life: self) }

    /// Runs `body` at every end of a login, after the ones registered before it.
    func onEnd(_ body: @escaping @MainActor () -> Void) {
        teardowns.append(body)
    }

    /// Runs `body` at every end of a login, as `onEnd`, for a teardown that has to await: it is
    /// started in its place in the order, and `tornDown()` waits for it.
    func onEnd(awaiting body: @escaping @MainActor () async -> Void) {
        teardowns.append { [unowned self] in ending.append(Task { await body() }) }
    }

    /// Every epoch taken before this is no longer current. A sign-out's first step.
    func moveEpoch() {
        count += 1
    }

    /// Runs every registered teardown, in the order they were registered.
    func runTeardowns() {
        teardowns.forEach { $0() }
    }

    /// A login ending by a path with no steps of its own (the phase leaving signed in): both at once.
    func end() {
        moveEpoch()
        runTeardowns()
    }

    /// Returns once every awaiting teardown started so far has finished.
    func tornDown() async {
        while !ending.isEmpty {
            let started = ending
            ending = []
            for task in started { await task.value }
        }
    }
}
