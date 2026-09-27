import Foundation
import TopoUserland

/// What `op` said: its status and its two streams.
struct OnePasswordExit: Sendable, Equatable {
    var status: Int32
    var output: String
    var errors: String
}

/// Runs 1Password's `op` with a service-account token, so a test can stand in for the guest.
protocol OnePasswordRunning: Sendable {
    func run(_ arguments: [String], token: String) async throws -> OnePasswordExit
}

/// `op` in the guest, started by the app: the token is in that one process's environment, never
/// an argument and never the resident's; `op`'s own config directory is made for the call and
/// removed after it, so nothing of the account is left in the guest; and the call is bounded at
/// 60 s, under the tool service's 90.
struct GuestOnePassword: OnePasswordRunning {
    /// The whole of what the guest runs: `$@` is `op`'s arguments.
    static let script = #"d="$(mktemp -d)" || exit 70; OP_CONFIG_DIR="$d" timeout 60 "#
        + OnePasswordInstaller.command + #" "$@"; s=$?; rm -rf "$d"; exit $s"#

    func run(_ arguments: [String], token: String) async throws -> OnePasswordExit {
        _ = try await Userland.shared.onePassword()
        var environment = Guest.environment
        environment["OP_SERVICE_ACCOUNT_TOKEN"] = token
        environment["OP_CACHE"] = "false"
        let exit = try await Guest.shared.run("/bin/sh", ["-c", Self.script, "op"] + arguments, environment: environment)
        return OnePasswordExit(status: exit.status, output: exit.output,
                               errors: exit.errors.replacingOccurrences(of: token, with: "[token]"))
    }
}

extension OnePasswordExit {
    /// What `op` said went wrong: its `[ERROR]` lines when it wrote any, without the notes it
    /// writes on every run in the guest (the daemon it may not start, the config directory the
    /// call made), otherwise all of its standard error; empty when it said nothing.
    var said: String {
        let lines = errors.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let errorLines = lines.filter { $0.hasPrefix("[ERROR]") }
        return (errorLines.isEmpty ? lines.filter { !$0.isEmpty } : errorLines).joined(separator: "\n")
    }
}

/// The vaults `op vault list --format json` names, or nil when what it printed is not that list.
enum OnePasswordVaults {
    static let arguments = ["vault", "list", "--format", "json"]

    struct Vault: Decodable, Equatable {
        var id: String
        var name: String
    }

    static func read(_ output: String) -> [Vault]? {
        try? JSONDecoder().decode([Vault].self, from: Data(output.utf8))
    }
}
