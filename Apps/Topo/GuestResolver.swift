import Foundation
import Network
import os
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
    /// Calls `changed` with the forwarder's port now (nil while it is down), then with its port
    /// each time it is ready and nil each time it goes down, all in order; answers once the first
    /// call has been made.
    func start(_ changed: @escaping @Sendable (UInt16?) -> Void) async
}

extension DNSForwarder: ForwarderChanges {
    func start(_ changed: @escaping @Sendable (UInt16?) -> Void) async {
        // On the forwarder's queue, so no change can be called back ahead of the port now.
        changed(observe(changed))
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
    private let retryDelay: Duration
    private let log: @Sendable (String) -> Void
    private var last: Task<Void, Never>?
    /// Bumped by every refresh, so a write still being tried gives way to a newer one.
    private var refreshes = 0
    /// The wait of a write that failed, before it tries again.
    private var napping: Task<Void, Never>?
    private var started = false
    /// The forwarder's changes are applied as they come rather than gathered for the first write.
    private var ready = false
    /// The forwarder's port while it is up.
    private var port: UInt16?

    init(changes: PathChanges = NetworkPathChanges(), forwarder: ForwarderChanges? = nil,
         servers: @escaping @Sendable () -> [String] = Guest.systemNameservers,
         setPort: @escaping @Sendable (UInt16?) -> Void = { Guest.shared.setDNSPort($0) },
         write: @escaping @Sendable ([String]) async throws -> Void = { try await Guest.shared.writeResolver(servers: $0) },
         retryDelay: Duration = .seconds(1),
         log: @escaping @Sendable (String) -> Void = { Logger(subsystem: "zone.hexagon.topo", category: "dns").error("\($0, privacy: .public)") }) {
        self.changes = changes
        self.forwarder = forwarder
        self.servers = servers
        self.setPort = setPort
        self.write = write
        self.retryDelay = retryDelay
        self.log = log
    }

    /// The longest wait between two tries of a write that keeps failing.
    static let retryCeiling: Duration = .seconds(30)

    /// Writes the resolver now and on every path change and forwarder change after. Answers once
    /// the first write has been tried, made or not. A write that fails is logged and tried again, waiting twice as
    /// long each time up to `retryCeiling`, until it is made or a newer write takes its place; while
    /// it fails the guest may have no name resolving, which is not the caller's.
    func start() async {
        guard !started else { return }
        started = true
        if let forwarder {
            // In order, on the main queue: the port now and every change after it are applied as
            // they came, and all of them before this start resumes there, so a change landing
            // during the start is never overtaken by the port it started with.
            await forwarder.start { port in
                DispatchQueue.main.async { MainActor.assumeIsolated { [weak self] in self?.forwarderChanged(port) } }
            }
            setPort(port)
        }
        ready = true
        // The first try, not the retries: a write that keeps failing must not hold the boot.
        await withCheckedContinuation { continuation in refresh(afterFirstTry: { continuation.resume() }) }
        changes.start { [weak self] in
            Task { @MainActor in _ = self?.refresh() }
        }
    }

    private func forwarderChanged(_ port: UInt16?) {
        guard ready else {
            self.port = port
            return
        }
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

    /// One write, after the one before it: the task that makes it. `afterFirstTry` is called once
    /// its first try has been made, written or not.
    @discardableResult
    func refresh(afterFirstTry: (@MainActor () -> Void)? = nil) -> Task<Void, Never> {
        let before = last
        let servers = servers
        let write = write
        refreshes += 1
        let mine = refreshes
        // A write waiting to try again gives way at once rather than at the end of its wait.
        napping?.cancel()
        let task = Task { @MainActor in
            await before?.value
            var afterFirstTry = afterFirstTry
            defer { afterFirstTry?() }
            var delay = self.retryDelay
            var failures = 0
            // Until it is written, or tried again only while no later refresh has taken over: a file
            // left naming the stub with no forwarder behind it is a guest in which no name resolves.
            while true {
                // What the state says as each try starts.
                let chosen = self.port == nil ? servers() : [Guest.dnsStub]
                do {
                    try await write(chosen)
                    return
                } catch {
                    failures += 1
                    self.log("dns: resolv.conf write failed (\(failures) so far), trying again in \(delay): \(error)")
                }
                afterFirstTry?()
                afterFirstTry = nil
                guard self.refreshes == mine else { return }
                let nap = Task { _ = try? await Task.sleep(for: delay) }
                self.napping = nap
                await nap.value
                delay = min(delay * 2, Self.retryCeiling)
                guard self.refreshes == mine else { return }
            }
        }
        last = task
        return task
    }
}
