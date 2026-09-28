import Foundation
import Network
import TopoUserland

/// What tells the resolver the phone's network changed: `NWPathMonitor` on the phone, a fake in
/// the tests.
protocol PathChanges: Sendable {
    /// Calls `changed` on every change of the phone's network path, the first as it starts.
    func start(_ changed: @escaping @Sendable () -> Void)
    func cancel()
}

final class NetworkPathChanges: PathChanges {
    private let monitor = NWPathMonitor()

    func start(_ changed: @escaping @Sendable () -> Void) {
        monitor.pathUpdateHandler = { _ in changed() }
        monitor.start(queue: DispatchQueue(label: "zone.hexagon.topo.guest-resolver"))
    }

    func cancel() { monitor.cancel() }
}

/// The guest's `/etc/resolv.conf`, kept to the phone's own name servers — its network's, or a
/// VPN's while one is up — as upstream iSH keeps it: written once the guest is booted and again on
/// every change of the network path, whatever the file held, falling back to public servers only
/// when the phone lists none. The writes run one after another, each reading the servers as it
/// starts, so the last one written is the newest.
@MainActor final class GuestResolver {
    private let changes: PathChanges
    private let servers: @Sendable () -> [String]
    private let write: @Sendable ([String]) async throws -> Void
    private var last: Task<Void, Never>?
    private var started = false

    init(changes: PathChanges = NetworkPathChanges(),
         servers: @escaping @Sendable () -> [String] = Guest.systemNameservers,
         write: @escaping @Sendable ([String]) async throws -> Void = { try await Guest.shared.writeResolver(servers: $0) }) {
        self.changes = changes
        self.servers = servers
        self.write = write
    }

    /// Writes the resolver now and on every path change after. Answers once the first write has
    /// been made; a failed write leaves a guest in which no name resolves and is not the caller's.
    func start() async {
        guard !started else { return }
        started = true
        await refresh().value
        changes.start { [weak self] in
            Task { @MainActor in _ = self?.refresh() }
        }
    }

    /// One write, after the one before it: the task that makes it.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        let before = last
        let servers = servers
        let write = write
        let task = Task {
            await before?.value
            try? await write(servers())
        }
        last = task
        return task
    }
}
