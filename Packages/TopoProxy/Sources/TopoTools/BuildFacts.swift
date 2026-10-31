import Foundation

/// Which build of Topo the guest is running under, told to it in its environment beside the tool
/// service's variables, so a command in the guest can name the build it runs on (a device check's
/// issue in samdu/topo-link is titled `Build <number> (<commit>)`).
public enum BuildFacts {
    /// `CFBundleVersion`: the build number, minutes since 2026 for a build the pipeline cut.
    public static let buildVariable = "TOPO_BUILD"
    /// `CFBundleShortVersionString`: the marketing version.
    public static let versionVariable = "TOPO_VERSION"
    /// `TopoSourceCommit`: the full hash of the commit the build was cut from.
    public static let commitVariable = "TOPO_COMMIT"
    /// `TopoChannel`: `main`, `dev` or `testflight`, the pipeline that cut the build.
    public static let channelVariable = "TOPO_CHANNEL"

    /// The variables for an Info.plist's keys. A key that is missing or blank — a build from Xcode
    /// carries no commit and no channel — leaves its variable out rather than set empty.
    public static func environment(info: [String: Any]?) -> [String: String] {
        let keys = [
            (buildVariable, "CFBundleVersion"),
            (versionVariable, "CFBundleShortVersionString"),
            (commitVariable, "TopoSourceCommit"),
            (channelVariable, "TopoChannel"),
        ]
        var environment: [String: String] = [:]
        for (variable, key) in keys {
            guard let value = (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { continue }
            environment[variable] = value
        }
        return environment
    }

    /// This process's own build.
    public static let current = environment(info: Bundle.main.infoDictionary)
}
