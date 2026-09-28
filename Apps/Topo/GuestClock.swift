import Foundation
import TopoUserland
import UIKit

/// What tells the clock the phone's zone may have changed: the system's zone change and every
/// foreground (a zone that changed while the app was suspended is not promised a notification) on
/// the phone, a fake in the tests.
protocol ZoneChanges: Sendable {
    /// Calls `changed` on every cue after it starts.
    func start(_ changed: @escaping @Sendable () -> Void)
    func cancel()
}

final class SystemZoneChanges: ZoneChanges, @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [NSObjectProtocol] = []

    func start(_ changed: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        let added = [Notification.Name.NSSystemTimeZoneDidChange, UIApplication.willEnterForegroundNotification].map {
            center.addObserver(forName: $0, object: nil, queue: nil) { _ in changed() }
        }
        lock.withLock { observers += added }
    }

    func cancel() {
        let removed = lock.withLock { () -> [NSObjectProtocol] in
            defer { observers = [] }
            return observers
        }
        removed.forEach(NotificationCenter.default.removeObserver)
    }
}

/// The guest's `/etc/localtime`, kept to the phone's zone, as `GuestResolver` keeps its name
/// servers: written once the guest is booted and again on every cue, each write reading the zone
/// as it starts. Every cue writes, whatever was written before, since a command in the guest may
/// have pointed the link elsewhere since; a write is one guest shell. No `TZ` is set anywhere,
/// because a `TZ` fixed in the resident's environment would outrank the file for everything it
/// starts until a relaunch.
@MainActor final class GuestClock {
    private let changes: ZoneChanges
    private let zone: @Sendable () -> String
    private let write: @Sendable (String) async throws -> Void
    private var last: Task<Void, Never>?
    private var started = false

    init(changes: ZoneChanges = SystemZoneChanges(),
         zone: @escaping @Sendable () -> String = { NSTimeZone.resetSystemTimeZone(); return TimeZone.current.identifier },
         write: @escaping @Sendable (String) async throws -> Void = { try await Guest.shared.writeTimeZone(identifier: $0) }) {
        self.changes = changes
        self.zone = zone
        self.write = write
    }

    /// Writes the zone now and on every cue after. It listens before the first write, so a change
    /// that lands while that write runs is a cue after it. Answers once the first write has been
    /// made; a failed write leaves the guest on the zone it had and is not the caller's.
    func start() async {
        guard !started else { return }
        started = true
        changes.start { [weak self] in
            Task { @MainActor in _ = self?.refresh() }
        }
        await refresh().value
    }

    /// One write, after the one before it: the task that makes it.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        let before = last
        let task = Task { @MainActor in
            await before?.value
            try? await self.write(self.zone())
        }
        last = task
        return task
    }
}
