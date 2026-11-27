import Foundation

/// What the mind adds to its own Claude Code's launch: `launch.json` in the mind's root, beside
/// the status, `{"arguments": ["--mcp-config", "/path/servers.json", "--channels", "name"]}`.
///
/// The mind writes it; the brain reads it as it is about to hand a turn to its process, and a
/// process started with other arguments is replaced then, between turns and never under one.
/// Only the flags in `allowed` are taken, each with the one value after it: the flags the brain
/// sets itself (the stream's form, the permission mode, the model, the session) are not the
/// document's to change. A pair that is refused costs itself and no other; a file that is
/// missing or is not this shape adds nothing.
public enum MindLaunch {
    public static let fileName = "launch.json"
    /// Flags the document may add, each taking one value.
    public static let allowed: Set<String> = ["--channels", "--mcp-config", "--add-dir", "--append-system-prompt",
                                              "--plugin-dir", "--settings"]
    public static let valueLimit = 8_000
    public static let pairLimit = 16

    public static var file: URL { MindHome.root.appending(path: fileName) }

    /// The arguments the document at `file` adds, in its order.
    public static func arguments(at file: URL = MindLaunch.file) -> [String] {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listed = object["arguments"] as? [String] else { return [] }
        return arguments(from: listed)
    }

    static func arguments(from listed: [String]) -> [String] {
        var taken: [String] = []
        var index = 0
        while index < listed.count, taken.count < pairLimit * 2 {
            let flag = listed[index]
            guard allowed.contains(flag), index + 1 < listed.count else { index += 1; continue }
            let value = listed[index + 1]
            index += 2
            // A value that reads as a flag would be one the document may not set.
            guard !value.isEmpty, !value.hasPrefix("-"), value.count <= valueLimit else { continue }
            taken += [flag, value]
        }
        return taken
    }
}
