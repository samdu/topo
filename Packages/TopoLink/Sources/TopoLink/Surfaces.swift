import Foundation
import Network
import TopoCore

/// A screen in the house, as a browse of `_topo._tcp` finds it.
///
/// The other end is Womble's `SurfaceServer`, which cannot link this package
/// (its minimum is iOS 17, six years past the devices that bundle exists
/// for), so the format is written in both and pinned by the tests on both
/// sides. `docs/surfaces.md` is the arrangement.
public struct Surface: Sendable, Equatable, Identifiable {
    /// The screen's own device ID, which is also the name of its advert.
    public let device: DeviceID
    /// What the screen is called: "Drawer iPad".
    public let name: String
    /// `womble` today. A kind this hub does not know is still listed, since
    /// the roster question is the same for any of them.
    public let kind: String
    /// The agents the TXT record says are registered here.
    public let agents: [DeviceID]
    /// True when the roster did not fit in the TXT record, so `agents` is
    /// the beginning of it and the whole is a `roster` request away.
    public let agentsArePartial: Bool

    public var id: DeviceID { device }

    public init(device: DeviceID, name: String, kind: String, agents: [DeviceID], agentsArePartial: Bool) {
        self.device = device
        self.name = name
        self.kind = kind
        self.agents = agents
        self.agentsArePartial = agentsArePartial
    }

    public func registers(_ agent: DeviceID) -> Bool { agents.contains(agent) }
}

/// The hub's half of the surface protocol: what a TXT record means, and the
/// two requests a surface answers, one line of UTF-8 each way.
public enum SurfaceWire {
    public static let version = "1"
    /// A `roster` answer can carry every agent in the house; a refusal is a
    /// sentence. Neither is large, and a peer that will not stop talking is
    /// not answering.
    static let answerLimit = 4096

    /// A browse result is a surface only when it says what it is: `v=1`, a
    /// name and a kind. Anything else on the type is another Topo device —
    /// the lease probe advertises here too — and is passed over.
    public static func surface(device: DeviceID, fields: [String: String]) -> Surface? {
        guard fields["v"] == version,
              let name = fields["n"], !name.isEmpty,
              let kind = fields["k"], !kind.isEmpty else { return nil }
        let agents = (fields["a"] ?? "")
            .split(separator: ",")
            .map { DeviceID(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.rawValue.isEmpty }
        return Surface(device: device, name: name, kind: kind, agents: agents,
                       agentsArePartial: fields["a+"] == "1")
    }

    static let rosterRequest = Data("roster\n".utf8)

    static func registerRequest(_ code: PairingCode) -> Data {
        Data("register \(code.url.absoluteString)\n".utf8)
    }

    /// What a surface answered. `wait` is not a failure: it means somebody in
    /// the room has been asked and has not said yes yet.
    public enum Answer: Sendable, Equatable {
        case roster([DeviceID])
        case registered(DeviceID)
        case waiting
        case refused(String)
    }

    static func answer(_ line: String) -> Answer? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "wait" { return .waiting }
        if trimmed == "roster" { return .roster([]) }
        if let rest = after("roster ", in: trimmed) {
            return .roster(rest.split(separator: ",").map { DeviceID(String($0).trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.rawValue.isEmpty })
        }
        if let rest = after("ok ", in: trimmed), !rest.isEmpty { return .registered(DeviceID(rest)) }
        if let rest = after("no ", in: trimmed) { return .refused(rest) }
        if trimmed == "no" { return .refused("no reason given") }
        return nil
    }

    private static func after(_ prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

public enum SurfaceError: Error, Sendable, Equatable {
    /// The surface is not on this network right now — it was in the browse
    /// and has gone, or the app on it is in the background.
    case notHere(DeviceID)
    /// It answered something this hub does not understand.
    case notASurface
}

/// The screens in the house, and the two things one can be asked.
///
/// A browse of `_topo._tcp` finds every Topo device; the TXT record is what
/// tells a screen from a phone, so this listens to the same type the lease
/// probe advertises on and keeps only what says it is a surface. Reading a
/// roster needs no pairing and asks nobody: it is in the advert already.
/// Registering is the room's decision, so it is a question that comes back
/// `wait` until somebody taps Register on the screen itself.
public actor SurfaceBrowser {
    private var browser: NWBrowser?
    public private(set) var surfaces: [Surface] = []
    /// Why the browse is not running, if it is not: on macOS the usual
    /// reason is that the app has not been allowed on the local network.
    public private(set) var failure: String?
    private var endpoints: [DeviceID: NWEndpoint] = [:]
    private var listeners: [UUID: @Sendable ([Surface]) -> Void] = [:]
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        // With the TXT record: a plain `.bonjour` browse hands back no
        // metadata at all, and the TXT record is the whole of what tells a
        // screen from another Topo device on this type.
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: TopoService.type, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { Self.surface(from: $0) }
            Task { await self?.update(found) }
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
        browser.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.surfaces"))
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Calls `handler` with every change until the token is dropped.
    @discardableResult
    public func observe(_ handler: @escaping @Sendable ([Surface]) -> Void) -> UUID {
        let token = UUID()
        listeners[token] = handler
        handler(surfaces)
        return token
    }

    public func removeObserver(_ token: UUID) {
        listeners[token] = nil
    }

    /// The whole roster, asked over the socket. The TXT record carries as
    /// much of it as fits, so this is what `agentsArePartial` is for — and
    /// what a hub uses to see the house without pairing with anything.
    public func roster(of surface: Surface) async throws -> [DeviceID] {
        guard case .roster(let agents) = try await ask(surface, SurfaceWire.rosterRequest) else {
            throw SurfaceError.notASurface
        }
        return agents
    }

    /// Asks a screen to answer for an agent. `waiting` means the question is
    /// on the screen and somebody in the room has to say yes; asking again
    /// later is how the answer is found, and an agent already registered is
    /// answered `registered` at once, so a hub that restarted asks nobody
    /// anything twice.
    public func register(_ code: PairingCode, with surface: Surface) async throws -> SurfaceWire.Answer {
        let answer = try await ask(surface, SurfaceWire.registerRequest(code))
        guard case .roster = answer else { return answer }
        throw SurfaceError.notASurface
    }

    /// One line out, one line back, on a connection that lives no longer
    /// than the question.
    private func ask(_ surface: Surface, _ request: Data) async throws -> SurfaceWire.Answer {
        guard let endpoint = endpoints[surface.device] else { throw SurfaceError.notHere(surface.device) }
        let connection = NWConnection(to: endpoint, using: .tcp)
        // The deadline cancels the connection, which fails whichever step is
        // pending; nothing here waits on anything the cancel cannot reach.
        let deadline = Task { [timeout] in
            try? await Task.sleep(for: .seconds(timeout))
            connection.cancel()
        }
        defer {
            deadline.cancel()
            connection.cancel()
        }
        connection.start(queue: DispatchQueue(label: "zone.hexagon.topo.link.surface.ask"))
        try await connection.waitUntilReady()
        try await connection.send(request)
        let line = try await connection.readLine(maximum: SurfaceWire.answerLimit)
        guard let answer = SurfaceWire.answer(line) else { throw SurfaceError.notASurface }
        return answer
    }

    /// Endpoints are kept for surfaces only, so a lease-probe advert on the
    /// same type leaves nothing behind here.
    private func update(_ found: [(Surface, NWEndpoint)]) {
        endpoints = Dictionary(found.map { ($0.0.device, $0.1) }, uniquingKeysWith: { first, _ in first })
        let listed = found.map(\.0).sorted { ($0.name, $0.device.rawValue) < ($1.name, $1.device.rawValue) }
        guard listed != surfaces else { return }
        surfaces = listed
        for handler in listeners.values { handler(listed) }
    }

    private func setFailure(_ failure: String?) {
        self.failure = failure
    }

    /// A surface and where to reach it, without a browse. Bonjour is not
    /// something a test can stand up, so the tests put a listener here and
    /// ask it the same two questions a screen is asked.
    func seed(_ surface: Surface, at endpoint: NWEndpoint) {
        endpoints[surface.device] = endpoint
        if !surfaces.contains(surface) { surfaces.append(surface) }
    }

    private static func surface(from result: NWBrowser.Result) -> (Surface, NWEndpoint)? {
        guard case .service(let name, _, _, _) = result.endpoint,
              case .bonjour(let txt) = result.metadata else { return nil }
        var fields: [String: String] = [:]
        for key in txt.dictionary.keys {
            if let value = txt[key] { fields[key] = value }
        }
        guard let surface = SurfaceWire.surface(device: DeviceID(name), fields: fields) else { return nil }
        return (surface, result.endpoint)
    }
}
