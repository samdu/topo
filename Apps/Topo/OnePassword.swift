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

/// `op` in the guest, started by the app: installed at its pin first, then run as
/// `OnePasswordRun` runs it — the token in that one process's environment, never an argument and
/// never the resident's, the call's config directory removed and the daemon `op` leaves ended
/// after it — with the token taken out of what `op` said on stderr.
struct GuestOnePassword: OnePasswordRunning {
    var install: @Sendable () async throws -> Void = { _ = try await Userland.shared.onePassword() }
    var runner: @Sendable ([String], String) async throws -> Guest.Exit = { try await OnePasswordRun.run($0, token: $1) }

    func run(_ arguments: [String], token: String) async throws -> OnePasswordExit {
        try await install()
        let exit = try await runner(arguments, token)
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
