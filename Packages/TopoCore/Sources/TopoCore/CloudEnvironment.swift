import Foundation
#if os(macOS)
import Security
#endif

/// The CloudKit environment this build talks to. A change token is the server's, so one kept on
/// disk is kept under the environment that issued it and offered to that one alone.
///
/// No target sets `com.apple.developer.icloud-container-environment` itself, so CloudKit takes
/// the environment from the signing: a development-signed build talks to Development, a
/// distribution-signed one (TestFlight, the App Store) to Production. iOS and watchOS have no
/// public API for an app's own signed entitlements, so there it is read from the provisioning
/// profile the build carries, on one assumption: a development-signed build carries a profile
/// whose `get-task-allow` is true. A distribution profile says false, and an app installed from
/// TestFlight or the App Store carries none. macOS reads the signed entitlements themselves.
public enum CloudEnvironment: String, Sendable, Equatable {
    case development, production

    /// This build's environment, or nil when the profile it carries cannot be read: a reader
    /// that cannot say keeps nothing under any environment rather than guess.
    public static let current: CloudEnvironment? = {
        #if targetEnvironment(simulator)
        // The simulator talks to Development alone.
        return .development
        #elseif os(macOS)
        return CloudEnvironment(entitlements: signedEntitlements())
        #else
        let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
        return CloudEnvironment(profile: url.flatMap { try? Data(contentsOf: $0) } ?? Data(),
                                present: url != nil)
        #endif
    }()

    /// The environment entitlements say: the environment entitlement when it is one value, and
    /// otherwise Development exactly when the build may be debugged.
    init(entitlements: [String: Any]) {
        if let named = entitlements["com.apple.developer.icloud-container-environment"] as? String {
            self = named == "Development" ? .development : .production
            return
        }
        let debuggable = (entitlements["get-task-allow"] as? Bool) ?? (entitlements["com.apple.security.get-task-allow"] as? Bool) ?? false
        self = debuggable ? .development : .production
    }

    /// The environment of a build carrying `profile` (an `embedded.mobileprovision`, a plist in a
    /// CMS envelope), or Production when it carries none. Nil for a profile that is there and
    /// whose entitlements cannot be read.
    init?(profile: Data, present: Bool) {
        guard present else { self = .production; return }
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return nil }
        self.init(entitlements: entitlements)
    }

    #if os(macOS)
    private static func signedEntitlements() -> [String: Any] {
        guard let task = SecTaskCreateFromSelf(nil) else { return [:] }
        var out: [String: Any] = [:]
        for key in ["com.apple.developer.icloud-container-environment", "get-task-allow", "com.apple.security.get-task-allow"] {
            if let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil) { out[key] = value }
        }
        return out
    }
    #endif
}
