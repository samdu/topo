import CoreFoundation
import Foundation

/// What a launch of the hub runs against, and what may drive it, read once from its environment
/// and its entitlements.
public struct HubLaunch: Sendable, Equatable {
    /// The hub's defaults domain: its bundle identifier.
    public static let domain = "zone.hexagon.topo.hub"

    public enum Store: String, Sendable { case cloudKit, memory }

    /// The smoke-test controls, for a run of the hub against nothing real.
    public struct Controls: Sendable, Equatable {
        /// `TOPO_HUB_CLAUDE`: the `claude` the mind runs (the suites' fake, behind a wrapper).
        public var claude: URL?
        /// `TOPO_HUB_LIMB_SAYS`: a limb's turn written to the log at launch.
        public var limbSays: String?
        /// `TOPO_HUB_SILENCE`, in seconds: the mind's silence bound, so a hang is given up on
        /// within a smoke test.
        public var silence: Duration?
    }

    public let store: Store
    /// Nil on the real store whatever the environment says: none of these reaches a launch that
    /// touches the person's records.
    public let controls: Controls?

    /// CloudKit when the build is entitled to it and `TOPO_STORE=memory` is not set; otherwise
    /// the in-memory store, the only one with controls.
    public init(environment: [String: String], entitled: Bool) {
        store = entitled && environment["TOPO_STORE"] != "memory" ? .cloudKit : .memory
        guard store == .memory else {
            controls = nil
            return
        }
        controls = Controls(claude: environment["TOPO_HUB_CLAUDE"].map { URL(fileURLWithPath: $0) },
                            limbSays: environment["TOPO_HUB_LIMB_SAYS"],
                            silence: environment["TOPO_HUB_SILENCE"].flatMap(Double.init).map { .milliseconds(Int($0 * 1000)) })
    }

    /// The switch's key in the hub's defaults: `mind.on` for the real store, and one of the
    /// in-memory store's own, so a run against nothing real never leaves the real switch on.
    public var switchKey: String { store == .cloudKit ? "mind.on" : "memory.mind.on" }
}

/// The switch, "Run the mind on this Mac": a boolean in the hub's defaults, which the menu sets and
/// a shell can set (`defaults write zone.hexagon.topo.hub mind.on -bool true`, `scripts/hub-mind.sh`).
/// The mind follows what the defaults say whenever it is asked to (`follow`): at launch, at the
/// hub's 10 s refresh, and at SIGUSR1. Each change is applied after the one before it, so the mind
/// ends where the switch did however fast it is flipped.
public actor MindSwitch {
    private let mind: HubMind
    private let domain: String
    private let key: String
    private var last: Task<Void, Never>?

    public init(mind: HubMind, domain: String = HubLaunch.domain, key: String) {
        self.mind = mind
        self.domain = domain
        self.key = key
    }

    /// What the defaults say now, read past this process's cache: false when the key is not set.
    public static func persisted(domain: String = HubLaunch.domain, key: String) -> Bool {
        CFPreferencesAppSynchronize(domain as CFString)
        return CFPreferencesGetAppBooleanValue(key as CFString, domain as CFString, nil)
    }

    /// The menu's switch: kept in the defaults, then applied. Returns once the mind is where the
    /// switch is (off: the process is gone).
    public func set(_ on: Bool) async {
        Self.keep(on, domain: domain, key: key)
        await apply(on)
    }

    /// Writes the switch to the defaults, where another process reads it at once.
    public static func keep(_ on: Bool, domain: String = HubLaunch.domain, key: String) {
        CFPreferencesSetAppValue(key as CFString, on as CFBoolean, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
    }

    /// Brings the mind to what the defaults say, and returns it.
    @discardableResult
    public func follow() async -> Bool {
        let on = Self.persisted(domain: domain, key: key)
        await apply(on)
        return on
    }

    private func apply(_ on: Bool) async {
        let before = last
        let applying = Task { [mind] in
            await before?.value
            if on { await mind.turnOn() } else { await mind.turnOff() }
        }
        last = applying
        await applying.value
    }
}

/// What the hub says of its mind to a shell (`scripts/hub-mind.sh status`): the menu's mind
/// section, kept as JSON in the mind's root (`hub-status.json`) and written at every change and
/// refresh. Kinds, names and times only: no word of a turn, and no reason Claude Code gave.
public struct HubStatus: Codable, Sendable, Equatable {
    /// The hub's pid, so a reader can tell a running hub's status from a dead one's.
    public var pid: Int32
    public var store: String
    public var at: Date
    /// The switch, as the hub last applied it.
    public var on: Bool
    /// The mind's phase by name (`HubMind.Phase.name`): a stop by its kind.
    public var phase: String
    /// Signed in (with Claude Code's method and subscription), signed out, unknown, or not asked.
    public var login: String
    /// True while this Mac holds an unexpired lease.
    public var holds: Bool
    /// The holder of a fresh lease, this Mac included; nil when none is fresh.
    public var leaseHolder: String?
    /// `NativeBrain.describe(reasons: false)`: the process, model and session, and where the
    /// record stands, with no reason Claude Code gave.
    public var mind: String
    /// The last pass's outcome, trigger and time.
    public var lastPass: String?
    public var passes: Int
    /// Whether this launch's key for the nudge's channel is saved (`saved`, or `not saved` and the
    /// failure's kind); nil with no channel. Never the key.
    public var nudgeKey: String?
    /// Connections to the channel whose handshake failed since launch: a count alone.
    public var handshakesFailed: Int?

    public static let fileName = "hub-status.json"

    public init(pid: Int32, store: HubLaunch.Store, on: Bool, snapshot: HubMind.Snapshot?, leaseHolder: String?,
                nudgeKey: String? = nil, handshakesFailed: Int? = nil, at: Date = Date()) {
        self.nudgeKey = nudgeKey
        self.handshakesFailed = handshakesFailed
        self.pid = pid
        self.store = store.rawValue
        self.at = at
        self.on = on
        phase = snapshot?.phase.name ?? "not made"
        switch snapshot?.login {
        case .signedIn(let summary)?: login = "signed in (\(summary))"
        case .signedOut?: login = "signed out"
        case .unknown?: login = "unknown"
        case nil: login = "not asked"
        }
        holds = snapshot?.holds ?? false
        self.leaseHolder = leaseHolder
        mind = snapshot?.mindKinds ?? ""
        lastPass = snapshot?.lastPass.map { pass in
            "\(HubMind.name(of: pass.outcome)) by \(pass.trigger.rawValue) at \(pass.at.formatted(.iso8601))"
        }
        passes = snapshot?.passes ?? 0
    }

    public func write(in root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(self).write(to: root.appending(path: Self.fileName), options: .atomic)
    }
}
