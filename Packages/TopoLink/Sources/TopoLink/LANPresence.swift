import Foundation
import Network
import TopoCore

/// Who is on the LAN right now: the device IDs advertising `TopoService`.
/// Presence is a browse result, not a record; the directory says who is
/// paired, this says who is reachable.
public actor LANPresence {
    private var browser: NWBrowser?
    public private(set) var devices: Set<DeviceID> = []
    /// Why the browse is not running, if it is not: on macOS the usual
    /// reason is that the app has not been allowed on the local network.
    public private(set) var failure: String?
    private var listeners: [UUID: @Sendable (Set<DeviceID>) -> Void] = [:]

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: TopoService.type, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = Set(results.compactMap { result -> DeviceID? in
                if case .service(let name, _, _, _) = result.endpoint { return DeviceID(name) }
                return nil
            })
            Task { await self?.update(names) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let failure: String?
            switch state {
            case .failed(let error): failure = "\(error)"
            case .waiting(let error): failure = "\(error)"
            default: failure = nil
            }
            Task { await self?.setFailure(failure) }
        }
        browser.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.browse"))
        self.browser = browser
    }

    private func setFailure(_ failure: String?) {
        self.failure = failure
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Calls `handler` with every change until the returned token is dropped
    /// via `removeObserver`.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable (Set<DeviceID>) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handler
        handler(devices)
        return token
    }

    public func removeObserver(_ token: UUID) {
        listeners[token] = nil
    }

    private func update(_ names: Set<DeviceID>) {
        guard names != devices else { return }
        devices = names
        for handler in listeners.values { handler(names) }
    }
}
