import Foundation
import Security
import TopoCore

/// One token per screen: what a web-page Womble is served under, and the
/// whole of the access control on it.
///
/// A token is a screen, not an account. It is minted when somebody in the
/// house registers that screen — the same tap that puts this hub on a
/// Bonjour surface's roster — and it carries what that screen may see and
/// nothing else. Revoking one in the app is what stops a screen showing
/// what it was showing, so the store is the authority and a page whose
/// token is not in it is answered `404`.
///
/// They live in the keychain rather than in preferences: a token is a
/// credential, and anybody who can read one can read the household's board
/// and somebody's transcript.
struct SurfaceTokens: Sendable {
    struct Screen: Codable, Sendable, Equatable {
        /// The screen this was minted for.
        var surface: DeviceID
        /// What it is called, so the menu can name what it is revoking.
        var name: String
        var mintedAt: Date
    }

    private static let service = HubIdentity.service
    private static let account = "surface-tokens"

    private(set) var screens: [String: Screen]

    init(screens: [String: Screen] = [:]) {
        self.screens = screens
    }

    static func load() -> SurfaceTokens {
        guard let data = KeychainItem.read(service: service, account: account),
              let screens = try? JSONDecoder().decode([String: Screen].self, from: data) else {
            return SurfaceTokens()
        }
        return SurfaceTokens(screens: screens)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(screens) else { return }
        KeychainItem.write(service: Self.service, account: Self.account, data: data)
    }

    func token(for surface: DeviceID) -> String? {
        screens.first { $0.value.surface == surface }?.key
    }

    func screen(for token: String) -> Screen? { screens[token] }

    /// The token for a screen, minting one if it has none. A screen keeps
    /// the token it has, so registering again — which is what a hub does
    /// after a restart — does not change the address the screen is on.
    @discardableResult
    mutating func mint(for surface: DeviceID, named name: String, now: Date = Date()) -> String {
        if let existing = token(for: surface) { return existing }
        let token = Self.freshToken()
        screens[token] = Screen(surface: surface, name: name, mintedAt: now)
        save()
        return token
    }

    mutating func revoke(_ surface: DeviceID) {
        screens = screens.filter { $0.value.surface != surface }
        save()
    }

    /// 128 bits from the system's cryptographic source, in the alphabet a
    /// path can carry without escaping. Not a device name, not a counter:
    /// guessing one is the only way in.
    static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
