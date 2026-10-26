import CryptoKit
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
    /// What every process is told of the time it has, since nothing in Claude Code knows it runs
    /// in an app iOS suspends: behind another app the process has only the time iOS allows, and it
    /// is ended, with everything it started, when that runs out or when its reply is done.
    public static let timePrompt = "You run inside Topo, an app on the person's iPhone. While Topo is on the screen "
        + "you run freely. Once it goes behind another app, iOS gives you only the time it allows: often a minute "
        + "or two, sometimes none, and it can take it back at any moment. When that runs out, or when your reply "
        + "is done and Topo is not on the screen, you are ended, and every process you started, background "
        + "commands included, is ended with you. Don't start work that has to outlive your reply or run for "
        + "minutes behind another app; when a job needs longer, tell the person to keep Topo open while it runs."

    public static func memoryPrompt(mounted: Bool) -> String {
        if mounted {
            return "Your memory is an Obsidian vault at \(memory) (memory/ from your working directory). "
                + "It is yours to read and write: a note you keep there is what you remember between "
                + "conversations, and it is synced to the person's other devices, where they read it in "
                + "Obsidian. Link notes with relative paths inside the vault, never absolute ones. The "
                + "hidden folder in it (.obsidian) is not yours to change."
        }
        return "Your memory, an Obsidian vault, cannot be reached on this phone right now. Nothing "
            + "written under \(memory) is kept, so if you are asked to remember something, say that "
            + "you cannot at the moment."
    }

    public let guest: Guest
    public let command: String
    public let home: String
    public let environment: @Sendable () async throws -> [String: String]

    public init(guest: Guest = .shared, command: String = ClaudeCodeInstaller.command,
                home: String = ClaudeLauncher.home,
                environment: @escaping @Sendable () async throws -> [String: String]) {
        self.guest = guest
        self.command = command
        self.home = home
        self.environment = environment
    }

    /// Claude Code's arguments: stream-json both ways (`--verbose` is what stream-json output
    /// requires), a message's text as it is written (`--include-partial-messages`), each input
    /// echoed as its turn begins (`--replay-user-messages`, `StreamEvent.received`), permissions bypassed, the model when one is given, and the session to resume
    /// when there is one. Bypassed because the guest is the sandbox: what the mind can reach is
    /// decided by the holes poked in it (the mounts, the proxy), and nothing inside it prompts.
    ///
    /// The system prompt is appended to with what the process is told of its time (`timePrompt`)
    /// and of its memory when `memory` is said. `note`, what became of the process before it when
    /// that was cut short (`GuestSession.Cut`), is not: Claude Code keeps the system prompt a
    /// conversation began with and sends that on every resume, so an appended note reaches only a
    /// fresh one. It is told by a SessionStart hook instead (`noteSettings`), whose output Claude
    /// Code adds to the conversation on a resume as on a start, and which reads the note from the
    /// environment (`launchEnvironment(note:)`).
    public static func arguments(model: String?, resume: String?, memory: Bool? = nil, note: String? = nil) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--replay-user-messages",
                         "--dangerously-skip-permissions"]
        if let model { arguments += ["--model", model] }
        let prompt = [timePrompt, memory.map { memoryPrompt(mounted: $0) }].compactMap { $0 }
        arguments += ["--append-system-prompt", prompt.joined(separator: "\n\n")]
        if note != nil { arguments += ["--settings", noteSettings] }
        if let resume { arguments += ["--resume", resume] }
        return arguments
    }

    /// The variables a launch's note and its mark are in (`launchEnvironment(note:)`), for the
    /// hook to print.
    public static let noteVariable = "TOPO_LAST_PROCESS"
    public static let noteMarkVariable = "TOPO_LAST_PROCESS_MARK"

    /// The line printed after a note, which the hook looks for in the conversation before it tells
    /// one: the same note gives the same mark, and a cut's note names when the app left, so two
    /// cuts never share one.
    public static func noteMark(_ note: String) -> String {
        let digest = SHA256.hash(data: Data(note.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "[topo: last process \(digest)]"
    }

    /// The hook's command: the conversation's transcript is the `transcript_path` of what the hook
    /// is handed on stdin, and a note whose mark is already in it is not told again, since a
    /// process ended after its hook ran and before it began leaves the note for the next. A
    /// transcript that cannot be read tells it, because a note told twice costs a line and one
    /// never told is a cut nobody hears of.
    public static let noteCommand = #"f=$(sed -n 's/.*"transcript_path" *: *"\([^"]*\)".*/\1/p'); "#
        + #"[ -n "$f" ] && grep -qF "$TOPO_LAST_PROCESS_MARK" "$f" 2>/dev/null || printf '%s\n%s' "$TOPO_LAST_PROCESS" "$TOPO_LAST_PROCESS_MARK""#

    /// The settings a launch with a note is given on top of the home's own, whose hooks still run:
    /// one SessionStart hook telling the note (`noteCommand`), which Claude Code adds to the
    /// conversation. Only on `startup` and `resume`, since a compaction or a clear inside the same
    /// process starts a session too.
    public static let noteSettings: String = {
        let hook: [String: Any] = ["matcher": "startup|resume", "hooks": [["type": "command", "command": noteCommand]]]
        let settings = ["hooks": ["SessionStart": [hook]]]
        let data = try! JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }()

    /// The whole command line: the shell moves into the home and `exec`s Claude Code, so the pid
    /// the app holds is Claude Code's own. `model` is the model every turn is asked of (the
    /// session's, which a debug build pins to Haiku); nil leaves it to Claude Code.
    public func commandLine(resume: String?, model: String?, memory: Bool? = nil, note: String? = nil) -> [String] {
        ["-c", "cd \"$HOME\" && exec \"$@\"", "sh", command]
            + Self.arguments(model: model, resume: resume, memory: memory, note: note)
    }

    /// The resident's environment: the guest's, what `environment` answers now, and last the
    /// launcher's own keys — `HOME` at the mount and `IS_SANDBOX=1` — so nothing the callback
    /// supplies overrides them. `IS_SANDBOX` is set by this launcher and no other launch path, and
    /// inherited, as part of the environment, by whatever the resident starts, which runs in the
    /// same sandbox (the bypass flag is an argument and is not inherited): the guest runs
    /// everything as root, and Claude Code refuses to bypass permissions as root unless it is told
    /// it is in a sandbox, which it is.
    public func launchEnvironment(compactAt: Int? = nil, note: String? = nil) async throws -> [String: String] {
        var environment = Guest.environment
        environment.merge(try await self.environment()) { _, new in new }
        environment["HOME"] = home
        environment["IS_SANDBOX"] = "1"
        // The threshold is the launcher's too. The window is always given, because Claude Code
        // enforces a threshold only over a window it was given: with none, a model whose window
        // it resolves itself is compacted when the API refuses the prompt. A percent lowers the
        // threshold, and none leaves that variable out, which is Claude Code's own number,
        // whatever the callback supplied.
        environment[Self.compactWindowVariable] = Self.compactWindow
        environment[Self.compactAtVariable] = compactAt.map(String.init)
        // The note is the launcher's as well, so one the callback supplied is never told.
        environment[Self.noteVariable] = note
        environment[Self.noteMarkVariable] = note.map(Self.noteMark)
        return environment
    }

    /// The share of its effective window, in whole percent, at which Claude Code compacts.
    public static let compactAtVariable = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"

    /// The window the threshold is taken over, which Claude Code clamps to the model's own: the
    /// largest it accepts, so it is every model's whole window.
    public static let compactWindowVariable = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
    public static let compactWindow = "1000000"

    /// `memory` is the session's (`GuestSession.use(memory:)`): true or false says so to the
    /// resident (`memoryPrompt`), nil says nothing. A launch mounts nothing: what it says is what
    /// the last reconcile of the mount found, and the session replaces a process told otherwise.
    public func launch(resume session: String?, model: String?, memory: Bool?, compactAt: Int?, note: String?) async throws -> any ResidentProcess {
        try await guest.spawn("/bin/sh", commandLine(resume: session, model: model, memory: memory, note: note),
                              environment: try await launchEnvironment(compactAt: compactAt, note: note))
    }
}
