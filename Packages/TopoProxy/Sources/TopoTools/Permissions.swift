import Foundation

/// Where one of the phone's permissions stands.
public enum Access: Sendable, Equatable {
    case granted
    /// Never asked: the first call that needs it asks.
    case undetermined
    /// Asked and refused, or allowed only in part (write-only calendar access); the person changes
    /// it in Settings.
    case denied
    /// Not the person's to give: a parent's or an organisation's restriction.
    case restricted
}

/// One of the phone's permissions, as a tool needs it: what it stands at, and the system's own
/// prompt for it.
public protocol Authorizer: Sendable {
    /// What the person knows it as: "Reminders", "Calendars", "Contacts", "Location", "Notifications", "HomeKit".
    var name: String { get }
    func access() async -> Access
    /// Raises the system's prompt and answers whether it was granted.
    func request() async -> Bool
}

/// Asks for a permission the first time a tool needs it and at no other moment — never at launch,
/// never for a framework nobody called — and once however many calls need it at the same moment:
/// calls that find it undetermined while a prompt is up wait on that prompt's answer. A refusal is a
/// `ToolReply` saying where to allow it, never an empty answer that reads as "nothing there".
public actor PermissionBroker {
    private var asking: [String: Task<Bool, Never>] = [:]

    public init() {}

    /// Nil when the tool may go ahead; otherwise what the call answers.
    public func admit(_ authorizer: any Authorizer) async -> ToolReply? {
        switch await authorizer.access() {
        case .granted:
            return nil
        case .denied:
            return Self.refusal(authorizer.name)
        case .restricted:
            return Self.restricted(authorizer.name)
        case .undetermined:
            let prompt: Task<Bool, Never>
            if let pending = asking[authorizer.name] {
                prompt = pending
            } else {
                prompt = Task { await authorizer.request() }
                asking[authorizer.name] = prompt
            }
            let granted = await prompt.value
            asking[authorizer.name] = nil
            return granted ? nil : Self.refusal(authorizer.name)
        }
    }

    /// Restricted is lifted where it was set, not under Topo's own settings.
    static func restricted(_ name: String) -> ToolReply {
        if name == "HomeKit" {
            return ToolReply(status: ToolReply.denied, text:
                "topo: HomeKit is restricted on this phone, so Topo cannot use it. A restriction is lifted by whoever set it — a device profile's by whoever manages the phone (Settings › General › VPN & Device Management) — and then the person allows Topo in the Settings app, under Privacy & Security › HomeKit › Topo. Ask the person, rather than trying again.\n")
        }
        let item = name == "Location" ? "Location Services" : name
        return ToolReply(status: ToolReply.denied, text:
            "topo: \(name) is restricted on this phone, so Topo cannot use it. A Screen Time restriction is lifted in the Settings app, under Screen Time › Content & Privacy Restrictions › \(item), by whoever holds the Screen Time passcode; a device profile's, by whoever manages the phone (Settings › General › VPN & Device Management). Ask the person, rather than trying again.\n")
    }

    /// HomeKit's switch is under Privacy & Security, not under the app's own settings.
    static func refusal(_ name: String) -> ToolReply {
        let place = name == "HomeKit" ? "Privacy & Security › HomeKit › Topo" : "Apps › Topo › \(name)"
        return ToolReply(status: ToolReply.denied, text:
            "topo: Topo is not allowed to use \(name) on this phone. The person can allow it in the Settings app, under \(place); ask them, rather than trying again.\n")
    }
}
