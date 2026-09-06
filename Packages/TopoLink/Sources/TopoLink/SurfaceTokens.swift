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
/// This is the rule rather than the store: what a mint, a revocation and a
/// second decision do to the set. The hub keeps it in the keychain, because
/// a token is a credential and anybody who can read one can read the
/// household's board and somebody's transcript.
public struct SurfaceTokens: Codable, Sendable, Equatable {
    public struct Screen: Codable, Sendable, Equatable {
        /// The screen this was minted for.
        public var surface: DeviceID
        /// What it is called, so the menu can name what it is revoking.
        public var name: String
        public var mintedAt: Date
    }

    public private(set) var screens: [String: Screen]
    /// Screens whose token was revoked and which are still on the hub's
    /// roster. They are served nothing until somebody serves them again.
    public private(set) var revoked: Set<DeviceID>

    public init(screens: [String: Screen] = [:], revoked: Set<DeviceID> = []) {
        self.screens = screens
        self.revoked = revoked
    }

    public func token(for surface: DeviceID) -> String? {
        screens.first { $0.value.surface == surface }?.key
    }

    public func screen(for token: String) -> Screen? { screens[token] }

    public func isRevoked(_ surface: DeviceID) -> Bool { revoked.contains(surface) }

    /// The token for a screen, minting one if it has none. A screen keeps
    /// the token it has, so registering again — which is what a hub does
    /// after a restart — does not change the address the screen is on.
    ///
    /// A revoked screen is minted nothing: it is still on the roster, and
    /// the roster is not what says a screen may be served. Somebody has to
    /// decide again, which is `serveAgain`.
    @discardableResult
    public mutating func mint(for surface: DeviceID, named name: String, now: Date = Date()) -> String? {
        if let existing = token(for: surface) { return existing }
        guard !revoked.contains(surface) else { return nil }
        let token = Self.freshToken()
        screens[token] = Screen(surface: surface, name: name, mintedAt: now)
        return token
    }

    public mutating func revoke(_ surface: DeviceID) {
        screens = screens.filter { $0.value.surface != surface }
        revoked.insert(surface)
    }

    /// Somebody in the house decided again: the screen is served, under a
    /// new token, because the old one is gone and a revoked address never
    /// comes back.
    @discardableResult
    public mutating func serveAgain(_ surface: DeviceID, named name: String, now: Date = Date()) -> String? {
        revoked.remove(surface)
        return mint(for: surface, named: name, now: now)
    }

    /// 128 bits from the system's cryptographic source, in the alphabet a
    /// path can carry without escaping. Not a device name, not a counter:
    /// guessing one is the only way in.
    public static func freshToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
