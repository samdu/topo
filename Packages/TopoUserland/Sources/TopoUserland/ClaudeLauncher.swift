import Foundation

/// How the resident Claude Code is started in the guest: `claude -p` reading turns as stream-json
/// on stdin and writing its events as stream-json on stdout, in its home — the app's
/// `Documents/home`, bind-mounted at `home` — which is also its working directory, so every
/// process finds the transcripts the one before it wrote. The environment is `Guest.environment`
/// with `HOME` moved to the mount, and whatever `environment` answers at each launch on top (the
/// proxy's base URL and the guest's token, read fresh each time).
public struct ClaudeLauncher: ResidentLauncher {
    /// Where the app mounts `Documents/home` in the guest.
    public static let home = "/home/topo"

    public let guest: Guest
    public let command: String
    public let home: String
    /// The model every turn is asked of; nil leaves it to Claude Code. A debug build passes the
    /// pinned Haiku.
    public let model: String?
    public let environment: @Sendable () async throws -> [String: String]

    public init(guest: Guest = .shared, command: String = ClaudeCodeInstaller.command,
                home: String = ClaudeLauncher.home, model: String?,
                environment: @escaping @Sendable () async throws -> [String: String]) {
        self.guest = guest
        self.command = command
        self.home = home
        self.model = model
        self.environment = environment
    }

    /// Claude Code's arguments: stream-json both ways (`--verbose` is what stream-json output
    /// requires), the model when one is given, and the session to resume when there is one.
    public static func arguments(model: String?, resume: String?) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        if let model { arguments += ["--model", model] }
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// The whole command line: the shell moves into the home and `exec`s Claude Code, so the pid
    /// the app holds is Claude Code's own.
    public func commandLine(resume: String?) -> [String] {
        ["-c", "cd \"$HOME\" && exec \"$@\"", "sh", command] + Self.arguments(model: model, resume: resume)
    }

    public func launch(resume session: String?) async throws -> any ResidentProcess {
        var environment = Guest.environment
        environment["HOME"] = home
        environment.merge(try await self.environment()) { _, new in new }
        return try await guest.spawn("/bin/sh", commandLine(resume: session), environment: environment)
    }
}
