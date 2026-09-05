import Foundation

/// What this screen says about itself on the LAN, and the two things it
/// answers on its socket. The other end of all of this is `TopoLink`'s
/// `SurfaceAdvert` and `SurfaceWire`; Womble cannot link that package (its
/// minimum is iOS 17, six years past the devices this bundle exists for),
/// so the format lives in both and is pinned by the tests on both sides.
enum SurfaceWire {
    static let version = "1"
    static let serviceType = "_topo._tcp"
    /// The most one TXT entry can carry.
    static let entryLimit = 255
    static let requestLimit = 2048

    /// The TXT record: `v` the version, `n` the name, `k` the kind, `a` the
    /// roster as a comma-separated list, and `a+` where the roster was too
    /// long for one entry and has to be asked for over the socket.
    static func txt(name: String, agents: [DeviceID]) -> [String: Data] {
        var listed: [String] = []
        var used = 2  // the "a=" the roster is written under
        for agent in agents {
            let addition = agent.rawValue.count + (listed.isEmpty ? 0 : 1)
            if used + addition > entryLimit { break }
            used += addition
            listed.append(agent.rawValue)
        }
        var fields = [
            "v": Data(version.utf8),
            "n": Data(name.utf8),
            "k": Data("womble".utf8),
            "a": Data(listed.joined(separator: ",").utf8),
        ]
        if listed.count < agents.count { fields["a+"] = Data("1".utf8) }
        return fields
    }

    enum Request: Equatable {
        case roster
        case register(PairingToken)
    }

    enum Answer: Equatable {
        case roster([DeviceID])
        case registered(DeviceID)
        case waiting
        case refused(String)
    }

    static func request(_ line: String) -> Request? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "roster" { return .roster }
        let prefix = "register "
        guard trimmed.hasPrefix(prefix), let token = PairingToken(string: String(trimmed.dropFirst(prefix.count))) else {
            return nil
        }
        return .register(token)
    }

    static func line(_ answer: Answer) -> String {
        switch answer {
        case .roster(let agents):
            return "roster " + agents.map { $0.rawValue }.joined(separator: ",")
        case .registered(let device):
            return "ok " + device.rawValue
        case .waiting:
            return "wait"
        case .refused(let reason):
            return "no " + reason
        }
    }
}

/// The pairing code from `docs/pairing.md`, as much of it as this screen
/// needs: `topo://pair?v=1&d=<id>&n=<name>&k=<publicKey>&e=<endpoint>`.
/// Womble is not a party to pairing — it writes no device record — so the
/// token is read here only to know who is asking to register.
struct PairingToken: Equatable {
    let device: DeviceID
    let name: String
    let publicKey: String
    let endpoint: String?

    init?(string: String) {
        guard let url = URL(string: string), url.scheme == "topo", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        var fields: [String: String] = [:]
        for item in items { fields[item.name] = item.value }
        guard fields["v"] == SurfaceWire.version,
              let device = fields["d"], !device.isEmpty,
              let key = fields["k"], !key.isEmpty else { return nil }
        self.device = DeviceID(device)
        self.name = fields["n"] ?? device
        self.publicKey = key
        self.endpoint = fields["e"]
    }
}
