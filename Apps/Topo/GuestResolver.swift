import Foundation
import Network
import TopoProxy
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

/// What tells the resolver the guest's DNS forwarder came up or went down: the forwarder itself
/// on the phone, a fake in the tests.
protocol ForwarderChanges: Sendable {
    /// Calls `changed` with the forwarder's port each time it is ready and nil each time it goes
    /// down, in order, and answers with its port now (nil while it is down).
    func start(_ changed: @escaping @Sendable (UInt16?) -> Void) async -> UInt16?
}

extension DNSForwarder: ForwarderChanges {
    func start(_ changed: @escaping @Sendable (UInt16?) -> Void) async -> UInt16? {
        observe(changed)
    }
}

/// The guest's `/etc/resolv.conf`. While the app's DNS forwarder is up it names the guest's stub,
/// `127.0.0.53`, which the guest's socket layer carries to the forwarder's port, so the guest's
/// names are resolved by the phone's own resolver (`DNSForwarder`); while it is down, the phone's
/// own name servers — its network's, or a VPN's while one is up — as upstream iSH keeps it,
/// falling back to public servers only when the phone lists none. Written once the guest is
/// booted, again on every change of the network path, and on every change of the forwarder: up,
/// the guest's rewrite is given its port and the stub is written; down, the rewrite is cleared and
/// the phone's servers are written. The writes run one after another, each reading the state as it
/// starts, so the last one written is the newest.
@MainActor final class GuestResolver {
    private let changes: PathChanges
    private let forwarder: ForwarderChanges?
    private let servers: @Sendable () -> [String]
    private let setPort: @Sendable (UInt16?) -> Void
    private let write: @Sendable ([String]) async throws -> Void
    private var last: Task<Void, Never>?
    private var started = false
    /// The forwarder's port while it is up.
    private var port: UInt16?

    init(changes: PathChanges = NetworkPathChanges(), forwarder: ForwarderChanges? = nil,
         servers: @escaping @Sendable () -> [String] = Guest.systemNameservers,
         setPort: @escaping @Sendable (UInt16?) -> Void = { Guest.shared.setDNSPort($0) },
         write: @escaping @Sendable ([String]) async throws -> Void = { try await Guest.shared.writeResolver(servers: $0) }) {
        self.changes = changes
        self.forwarder = forwarder
        self.servers = servers
        self.setPort = setPort
        self.write = write
    }

    /// Writes the resolver now and on every path change and forwarder change after. Answers once
    /// the first write has been made; a failed write leaves a guest in which no name resolves and
    /// is not the caller's.
    func start() async {
        guard !started else { return }
        started = true
        if let forwarder {
            // In order, on the main queue: an up and a down in quick succession are applied as they came.
            let now = await forwarder.start { port in
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.forwarderChanged(port) } }
            }
            port = now
            setPort(now)
        }
        await refresh().value
        changes.start { [weak self] in
            Task { @MainActor in _ = self?.refresh() }
        }
    }

    private func forwarderChanged(_ port: UInt16?) {
        guard port != self.port else { return }
        self.port = port
        setPort(port)
        refresh()
    }

    /// Once every cue delivered before this call has been applied and its write made.
    func settle() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        await last?.value
    }

    /// One write, after the one before it: the task that makes it.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        let before = last
        let servers = servers
        let write = write
        let task = Task { @MainActor in
            await before?.value
            let chosen = self.port == nil ? servers() : [Guest.dnsStub]
            try? await write(chosen)
        }
        last = task
        return task
    }
}
