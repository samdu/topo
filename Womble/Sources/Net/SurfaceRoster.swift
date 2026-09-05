import Foundation

/// The agents registered to this screen, and the rule for adding one.
///
/// Reading the roster is open to anyone on the LAN: it is in the TXT record
/// and answered on the socket without ceremony, which is what lets a hub
/// list the surfaces in the house and see whose they are. Joining it is
/// not. An agent nobody here has agreed to gets `wait` and a question on
/// the screen; it is on the roster only once someone in the room taps
/// Register, which is the HomePod's bargain — the network can ask, the room
/// decides.
///
/// A registration this screen has already accepted is answered straight
/// away, so a hub that asks again after a restart is not a decision anyone
/// has to make twice. A refusal is not remembered: asking again asks the
/// room again, because the answer to "not now" is often "later".
final class SurfaceRoster {
    /// Where the roster is kept between launches. A Womble writes no
    /// CloudKit record of its own — it is a reader there — so this is the
    /// only place it lives.
    private let defaults: UserDefaults
    private let key = "surface.roster"

    private(set) var agents: [DeviceID]
    /// Registrations waiting on somebody in the room, oldest first.
    private(set) var pending: [PairingToken] = []
    /// Called when the pending list changes, so the screen can ask.
    var pendingChanged: (() -> Void)?
    /// Called when the roster changes, so the advert can be rewritten.
    var rosterChanged: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        agents = (defaults.array(forKey: key) as? [String] ?? []).map { DeviceID($0) }
    }

    func isRegistered(_ device: DeviceID) -> Bool { agents.contains(device) }

    /// The answer to a request, and the asking it may have started.
    func answer(to request: SurfaceWire.Request) -> SurfaceWire.Answer {
        switch request {
        case .roster:
            return .roster(agents)
        case .register(let token):
            if isRegistered(token.device) { return .registered(token.device) }
            if !pending.contains(where: { $0.device == token.device }) {
                pending.append(token)
                pendingChanged?()
            }
            return .waiting
        }
    }

    /// Somebody tapped Register.
    func accept(_ device: DeviceID) {
        pending.removeAll { $0.device == device }
        if !agents.contains(device) {
            agents.append(device)
            defaults.set(agents.map { $0.rawValue }, forKey: key)
            rosterChanged?()
        }
        pendingChanged?()
    }

    /// Somebody tapped Not now. The asker hears `no`, and is free to ask
    /// again later.
    func decline(_ device: DeviceID) {
        pending.removeAll { $0.device == device }
        pendingChanged?()
    }

    /// Takes an agent off the roster.
    func remove(_ device: DeviceID) {
        guard agents.contains(device) else { return }
        agents.removeAll { $0 == device }
        defaults.set(agents.map { $0.rawValue }, forKey: key)
        rosterChanged?()
    }
}
