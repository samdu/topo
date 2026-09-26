import Foundation

/// How the resident Claude Code is started in the guest: `claude -p` reading turns as stream-json
/// on stdin and writing its events as stream-json on stdout, in its home — the app's
/// `Documents/home`, bind-mounted at `home` — which is also its working directory, so every
/// process finds the transcripts the one before it wrote. The environment is `Guest.environment`
/// with whatever `environment` answers at each launch on top (the proxy's base URL and the guest's
/// token, read fresh each time), and then the launcher's own keys, which nothing supplied
/// overrides: `HOME` at the mount and `IS_SANDBOX=1`.
public struct ClaudeLauncher: ResidentLauncher {
    /// Where the app mounts `Documents/home` in the guest.
    public static let home = "/home/topo"

    /// Where the memory's folder is mounted in the guest: beside the home rather than inside it,
    /// because the fork's mount lookup caches the last mount it found per thread and answers a
    /// path under a mount nested in that one with the outer mount.
    public static let vault = "/memory"

    /// The path the mind is told its memory is at: a link in the home to `vault`, so it is
    /// `memory/` from the working directory.
    public static let memory = "/home/topo/memory"

    /// What the resident is told of its memory, appended to Claude Code's own system prompt:
    /// where the vault is and how to write in it when it is mounted, and that nothing written
    /// there is kept when it is not.
    public static func memoryPrompt(mounted: Bool) -> String {
        if mounted {
            return "Your memory is an Obsidian vault at \(memory) (memory/ from your working directory). "
                + "It is yours to read and write: a note you keep there is what you remember between "
                + "conversations, and it is synced to the person's other devices, where they read it in "
                + "Obsidian. Link notes with relative paths inside the vault, never absolute ones. The "
                + "hidden folders in it (.obsidian, .topo) are not yours to change."
        }
        return "Your memory, an Obsidian vault, cannot be reached on this phone right now. Nothing "
            + "written under \(memory) is kept, so if you are asked to remember something, say that "
            + "you cannot at the moment."
    }

    public let guest: Guest
    public let command: String
    public let home: String
    public let environment: @Sendable () async throws -> [String: String]
    /// Asked at each launch whether the memory is mounted, after whatever it does to mount it:
    /// true or false says so to the resident (`memoryPrompt`), nil says nothing.
    public let memory: @Sendable () async -> Bool?

    public init(guest: Guest = .shared, command: String = ClaudeCodeInstaller.command,
                home: String = ClaudeLauncher.home,
                memory: @escaping @Sendable () async -> Bool? = { nil },
                environment: @escaping @Sendable () async throws -> [String: String]) {
        self.guest = guest
        self.command = command
        self.home = home
        self.memory = memory
        self.environment = environment
    }

    /// Claude Code's arguments: stream-json both ways (`--verbose` is what stream-json output
    /// requires), permissions bypassed, the model when one is given, and the session to resume
    /// when there is one. Bypassed because the guest is the sandbox: what the mind can reach is
    /// decided by the holes poked in it (the mounts, the proxy), and nothing inside it prompts.
    public static func arguments(model: String?, resume: String?, memory: Bool? = nil) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--dangerously-skip-permissions"]
        if let model { arguments += ["--model", model] }
        if let memory { arguments += ["--append-system-prompt", memoryPrompt(mounted: memory)] }
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// The whole command line: the shell moves into the home and `exec`s Claude Code, so the pid
    /// the app holds is Claude Code's own. `model` is the model every turn is asked of (the
    /// session's, which a debug build pins to Haiku); nil leaves it to Claude Code.
    public func commandLine(resume: String?, model: String?, memory: Bool? = nil) -> [String] {
        ["-c", "cd \"$HOME\" && exec \"$@\"", "sh", command]
            + Self.arguments(model: model, resume: resume, memory: memory)
    }

    /// The resident's environment: the guest's, what `environment` answers now, and last the
    /// launcher's own keys — `HOME` at the mount and `IS_SANDBOX=1` — so nothing the callback
    /// supplies overrides them. `IS_SANDBOX` is set by this launcher and no other launch path, and
    /// inherited, as part of the environment, by whatever the resident starts, which runs in the
    /// same sandbox (the bypass flag is an argument and is not inherited): the guest runs
    /// everything as root, and Claude Code refuses to bypass permissions as root unless it is told
    /// it is in a sandbox, which it is.
    public func launchEnvironment() async throws -> [String: String] {
        var environment = Guest.environment
        environment.merge(try await self.environment()) { _, new in new }
        environment["HOME"] = home
        environment["IS_SANDBOX"] = "1"
        return environment
    }

    public func launch(resume session: String?, model: String?) async throws -> any ResidentProcess {
        let memory = await self.memory()
        return try await guest.spawn("/bin/sh", commandLine(resume: session, model: model, memory: memory),
                              environment: try await launchEnvironment())
    }
}
