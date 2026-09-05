import Foundation
import TopoCore

/// This device's name in the log. Stable across launches, unique across
/// devices: it is the first half of every turn ref this device writes, so it
/// must never be reused and never change.
enum DeviceIdentity {
    private static let key = "topo.deviceID"

    static let current: DeviceID = {
        let defaults = UserDefaults.standard
        if let stored = defaults.string(forKey: key), !stored.isEmpty { return DeviceID(stored) }
        // The platform is in the name because a person reads these: a fork
        // in the log says "watch" rather than a bare UUID. The UUID is what
        // makes it unique; two watches on one Apple ID are two devices.
        let name = "\(platform)-\(UUID().uuidString.prefix(8))"
        defaults.set(name, forKey: key)
        return DeviceID(name)
    }()

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
