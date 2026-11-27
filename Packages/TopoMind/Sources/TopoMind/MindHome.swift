import Foundation

/// The mind's home on a Mac: a working directory and a Claude Code config directory of its own
/// under `~/Library/Application Support/Topo Hub`, so nothing of the Mac user's own Claude Code
/// (`~/.claude`, its login, settings, memory and sessions) reaches it.
///
/// Claude Code reads a `CLAUDE.md`, a `CLAUDE.local.md` and a `.claude/CLAUDE.md` from the working
/// directory and from every directory above it, so a home under the user's home folder would read
/// `~/.claude/CLAUDE.md` as a project's memory. The config directory's `settings.json` therefore
/// carries a `claudeMdExcludes` entry for each of those in every directory above the working
/// directory; the working directory's own are the mind's and are left read.
public enum MindHome {
    /// `~/Library/Application Support/Topo Hub`.
    public static var root: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Topo Hub", directoryHint: .isDirectory)
    }

    /// Where the hub puts the mind's own commands (`topo`), first on its path.
    public static var bin: URL { root.appending(path: "bin", directoryHint: .isDirectory) }
    public static var work: URL { root.appending(path: "home", directoryHint: .isDirectory) }
    public static var config: URL { root.appending(path: "claude", directoryHint: .isDirectory) }

    /// What the Bash tool finds commands on: the hub's own (`bin`), Homebrew's two prefixes, the user's own `~/.local/bin`
    /// (where Claude Code's installer puts `claude`), then the system's.
    public static var path: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [bin.path, "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "\(home)/.local/bin",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    /// The brain's configuration in this home.
    public static func configuration(work: URL = MindHome.work, config: URL = MindHome.config,
                                     claude: URL = NativeBrain.Configuration.defaultClaude) -> NativeBrain.Configuration {
        var configuration = NativeBrain.Configuration(workingDirectory: work, configDirectory: config, claude: claude,
                                                      permissionMode: "auto", environment: ["PATH": path])
        let launch = config.deletingLastPathComponent().appending(path: MindLaunch.fileName)
        configuration.extraArguments = { MindLaunch.arguments(at: launch) }
        return configuration
    }

    public struct Unreadable: Error, CustomStringConvertible {
        public let description: String
    }

    /// Makes both directories and puts the excludes into the config directory's `settings.json`,
    /// keeping everything else the file holds. A file that is not a JSON object is left as it is
    /// and is an error: it is the person's, and nothing here writes over it.
    public static func prepare(work: URL = MindHome.work, config: URL = MindHome.config) throws {
        let files = FileManager.default
        try files.createDirectory(at: work, withIntermediateDirectories: true)
        try files.createDirectory(at: config, withIntermediateDirectories: true)
        let settings = config.appending(path: "settings.json")
        var object: [String: Any] = [:]
        if files.fileExists(atPath: settings.path) {
            let data = try Data(contentsOf: settings)
            guard let read = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw Unreadable(description: "\(settings.path) is not a JSON object")
            }
            object = read
        }
        let kept = object["claudeMdExcludes"] as? [String] ?? []
        let wanted = excludes(above: work)
        let merged = kept + wanted.filter { !kept.contains($0) }
        guard merged != kept || object["claudeMdExcludes"] == nil else { return }
        object["claudeMdExcludes"] = merged
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settings, options: .atomic)
    }

    /// The memory files Claude Code would read in every directory above `work`, by absolute path.
    static func excludes(above work: URL) -> [String] {
        var out: [String] = []
        var directory = work.standardizedFileURL.deletingLastPathComponent()
        while true {
            let base = directory.path == "/" ? "" : directory.path
            out += ["\(base)/CLAUDE.md", "\(base)/CLAUDE.local.md", "\(base)/.claude/CLAUDE.md"]
            if directory.path == "/" { break }
            directory = directory.deletingLastPathComponent()
        }
        return out
    }
}
