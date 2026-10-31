import Foundation
import TopoAuth
import TopoCore

/// This device's name in the log. Stable across launches, unique across
/// devices: it is the first half of every turn ref this device writes, so it
/// must never be reused and never change.
///
/// On a phone or a pad the name is kept in the device keychain (`keychain`, its own item,
/// `AfterFirstUnlockThisDeviceOnly`) beside the copy in the app's defaults. The keychain outlives
/// a delete of the app and is never synced or restored to another device, so a reinstall is the
/// device it was: the lease that names it is still its own. Nothing clears the item, a sign-out
/// and a demotion included; it is the device's, not the login's. The watch and the TV keep theirs
/// in defaults alone.
enum DeviceIdentity {
    static let key = "topo.deviceID"

    static let current: DeviceID = {
        #if os(iOS)
        return resolve(keychain: keychain, defaults: .standard).id
        #else
        return resolve(keychain: nil, defaults: .standard).id
        #endif
    }()

    /// The item the name is kept in: its own service, apart from the Claude login's and the
    /// connections', so nothing that clears those reaches it.
    static let keychain = KeychainItem(service: "zone.hexagon.topo.device", account: "name")

    /// Where the name is kept, as bytes; `KeychainItem` is one.
    protocol Keychain {
        /// Nil when the item holds none; a throw when it could not be read, which is not "none".
        func read() throws -> Data?
        func write(_ data: Data) throws
    }

    struct Resolved: Equatable {
        var id: DeviceID
        /// False for a name minted while the keychain could not be read and defaults held none:
        /// written nowhere, so no later launch takes it for its own.
        var kept: Bool
    }

    /// The keychain's name when it holds one (copied into defaults); else the defaults' copy,
    /// carried into the keychain; else a new one, written to both. A keychain that cannot be read
    /// is not one that holds none: the defaults' copy is used and nothing is written, and with
    /// no copy there the name is minted and kept nowhere, so nothing is minted over an item that
    /// could not be seen. A write that fails is left for the next launch, which carries the
    /// defaults' copy again.
    ///
    /// The platform is in a minted name because a person reads these: a fork in the log says
    /// "watch" rather than a bare UUID. The UUID is what makes it unique; two watches on one
    /// Apple ID are two devices.
    static func resolve(keychain: (any Keychain)?, defaults: UserDefaults,
                        mint: () -> String = { "\(platform)-\(UUID().uuidString.prefix(8))" }) -> Resolved {
        let stored = defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
        guard let keychain else {
            if let stored { return Resolved(id: DeviceID(stored), kept: true) }
            let name = mint()
            defaults.set(name, forKey: key)
            return Resolved(id: DeviceID(name), kept: true)
        }
        let held: String?
        do {
            held = try keychain.read().flatMap { String(data: $0, encoding: .utf8) }.flatMap { $0.isEmpty ? nil : $0 }
        } catch {
            if let stored { return Resolved(id: DeviceID(stored), kept: true) }
            return Resolved(id: DeviceID(mint()), kept: false)
        }
        if let held {
            if stored != held { defaults.set(held, forKey: key) }
            return Resolved(id: DeviceID(held), kept: true)
        }
        let name = stored ?? mint()
        try? keychain.write(Data(name.utf8))
        if stored == nil { defaults.set(name, forKey: key) }
        return Resolved(id: DeviceID(name), kept: true)
    }

    private static var platform: String {
        #if os(watchOS)
        return "watch"
        #elseif os(tvOS)
        return "tv"
        #elseif os(macOS)
        return "mac"
        #elseif os(iOS)
        return "ios"
        #else
        return "device"
        #endif
    }
}

extension KeychainItem: DeviceIdentity.Keychain {}
