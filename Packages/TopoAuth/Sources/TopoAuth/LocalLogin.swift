import Foundation

/// Using Topo without a Claude account: the mind is Apple's on-device model, answered on the phone
/// by the guest's proxy, and Claude Code in the guest is launched with a placeholder key in place
/// of a login (`GuestResident.launchCredential`). It is one boolean in the app's defaults, set from
/// the sign-in screen and cleared by a sign-out. While it is on, the login cache holds `status`, so
/// everything that asks whether the phone is signed in (the role, the memory, the guest) takes it
/// as signed in, and `SignIn.refresh` does not ask Claude Code, which has no login to report.
public struct LocalLogin: @unchecked Sendable {
    public let defaults: UserDefaults
    public static let key = "zone.hexagon.topo.on-device-only"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static var standard: LocalLogin { LocalLogin() }

    public var isOn: Bool { defaults.bool(forKey: Self.key) }

    public func set(_ on: Bool) {
        if on { defaults.set(true, forKey: Self.key) } else { defaults.removeObject(forKey: Self.key) }
    }

    /// What the login cache holds while it is on.
    public static let status = ClaudeLoginStatus(loggedIn: true, authMethod: "on-device")
}
