import CryptoKit
import Foundation
import TopoCore

/// How the resident Claude Code is started in the guest: `claude -p` reading turns as stream-json
/// on stdin and writing its events as stream-json on stdout, in its home — the app's
/// `Library/Application Support/home`, bind-mounted at `home` — which is also its working directory, so every
/// process finds the transcripts the one before it wrote. The environment is `Guest.environment`
/// with whatever `environment` answers at each launch on top (the proxy's base URL and the guest's
/// token, read fresh each time), and then the launcher's own keys, which nothing supplied
/// overrides: `HOME` at the mount and `IS_SANDBOX=1`.
public struct ClaudeLauncher: ResidentLauncher {
    /// Where the app mounts `Library/Application Support/home` in the guest.
    public static let home = "/home/topo"

    /// Where the memory's folder is mounted in the guest: beside the home rather than inside it,
    /// because the fork's mount lookup caches the last mount it found per thread and answers a
    /// path under a mount nested in that one with the outer mount.
    public static let vault = "/memory"

    /// The path the mind is told its memory is at: a link in the home to `vault`, so it is
    /// `memory/` from the working directory.
    public static let memory = "/home/topo/memory"

    /// What the conversation is told of the time a process has, since nothing in Claude Code knows
    /// it runs in an app iOS suspends: behind another app the process has only the time iOS
    /// allows, and it is ended, with everything it started, when that runs out or when its reply
    /// is done. Told by the launch's SessionStart hook (`hookCommand`), at most once a `timeGap`.
    public static let timePrompt = "You run inside Topo, an app on the person's iPhone. While Topo is on the screen "
        + "you run freely. Once it goes behind another app, iOS gives you only the time it allows: often a minute "
        + "or two, sometimes none, and it can take it back at any moment. When that runs out, or when your reply "
        + "is done and Topo is not on the screen, you are ended, and every process you started, background "
        + "commands included, is ended with you. Don't start work that has to outlive your reply or run for "
        + "minutes behind another app; when a job needs longer, tell the person to keep Topo open while it runs."

    /// What the conversation is told of its memory: where the vault is and how to write in it when
    /// it is mounted, and that nothing written there is kept when it is not. Told by the launch's
    /// SessionStart hook when it differs from what the conversation was last told, so it is worded
    /// as the state now: a conversation begun before the hook keeps the line its first launch
    /// appended to the system prompt for good, and this stands over it.
    public static func memoryPrompt(mounted: Bool) -> String {
        if mounted {
            return "Your memory is an Obsidian vault at \(memory) (memory/ from your working directory). "
                + "It is yours to read and write: a note you keep there is what you remember between "
                + "conversations, and it is synced to the person's other devices, where they read it in "
                + "Obsidian. Link notes with relative paths inside the vault, never absolute ones. The "
                + "hidden folder in it (.obsidian) is not yours to change. This is where your memory "
                + "stands now, over anything said of it earlier in this conversation."
        }
        return "Your memory, an Obsidian vault, cannot be reached on this phone right now. Nothing "
            + "written under \(memory) is kept, so if you are asked to remember something, say that "
            + "you cannot at the moment. This is where your memory stands now, over anything said of "
            + "it earlier in this conversation."
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
    /// What the conversation is told of its time (`timePrompt`), of its memory when `memory` is
    /// said, and of what became of the process before it when that was cut short (the note,
    /// `GuestSession.Cut`, which the launch puts in the environment), are told by a SessionStart hook (`settings(memory:)`) and not by
    /// appending to the system prompt: Claude Code keeps the system prompt a conversation began
    /// with and sends that on every resume, so anything appended at a later launch reaches only a
    /// fresh one, while a hook's output is added to the conversation on a resume as on a start.
    public static func arguments(model: String?, resume: String?, memory: Bool? = nil) -> [String] {
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                         "--include-partial-messages", "--replay-user-messages",
                         "--dangerously-skip-permissions"]
        if let model { arguments += ["--model", model] }
        arguments += ["--settings", settings(memory: memory)]
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

    /// The least time between two tellings of `timePrompt` to one conversation: a phone can launch
    /// a process on its conversation many times in a few minutes, and a dozen launches in ten
    /// minutes tell it once.
    public static let timeGap = 600

    /// The mark printed after the time prompt, with the time it was told in seconds since 1970,
    /// and the one printed after the memory prompt, with the state it told and the time; each
    /// ends with the launch's own id (`launchVariable`). The hook builds both from `%s`, so
    /// neither is in its own command, which Claude Code keeps in the transcript beside the output.
    /// Every telling carries the launch's id because Claude Code drops a hook's output that is the
    /// same, byte for byte, as one the conversation already holds, and records nothing of it: the
    /// memory told unmounted, mounted, then unmounted again would otherwise leave the conversation
    /// told it is mounted, and a time alone repeats whenever the clock is set back.
    static func timeMark(_ seconds: Int, launch: String) -> String { "[topo: time \(seconds) \(launch)]" }
    static func memoryMark(mounted: Bool, at seconds: Int, launch: String) -> String {
        "[topo: memory \(mounted ? "mounted" : "unmounted") at \(seconds) \(launch)]"
    }

    /// The variable a launch's id is in, a fresh UUID at every launch (`launchEnvironment`), which
    /// the hook ends its marks with.
    public static let launchVariable = "TOPO_LAUNCH"

    /// The most of a transcript the hook reads: its last 4 MB. A transcript grows for the life of
    /// a conversation and the hook runs at every launch, so it reads a window of fixed size and
    /// its cost does not grow with the file. Claude Code compacts a 200 000-token window inside
    /// some 3 MB of a transcript of text (at most 15 bytes a token of context), so there the
    /// window holds everything since the last compaction; images (their base64 is in the
    /// transcript) or a larger window's model can run past it, and then a mark before the window
    /// is not seen and its line is told again, once a window's growth.
    public static let transcriptWindow = 4 * 1024 * 1024

    /// The hook's command: one pass over the conversation's transcript (the `transcript_path` of
    /// what the hook is handed on stdin), or over its last `transcriptWindow` bytes less the line
    /// the window begins inside when it is longer, reading only Claude Code's compaction
    /// boundaries and its records of a SessionStart hook's output on the main chain — a line that is such a record
    /// from its first byte, as 2.1.316 writes one, with marks read from its `content` alone — so a
    /// mark a person writes, a reply quotes or a tool call carries is not one the hook printed. A
    /// record laid out otherwise by a later Claude Code reads as none, which tells everything
    /// rather than less. Then it prints, each with its mark after it:
    ///
    /// - `timePrompt`, unless a time mark since the last compaction is less than `timeGap` old;
    /// - `memoryPrompt` when `memory` is said, unless the last memory mark since the last
    ///   compaction is that state;
    /// - the note in `TOPO_LAST_PROCESS`, unless its mark is in any SessionStart output read,
    ///   before a compaction included, since a process ended after its hook ran and before it began leaves the note
    ///   for the next, and never on a compaction or a clear, whose process told it at its start
    ///   (that record is written only with the first input, so a `/compact` as the first one
    ///   finds no mark, and a clear's transcript is a new one). Neither unsays it: a cut is told
    ///   once, not once per context.
    ///
    /// A compaction ends what the conversation was told: what came before the boundary is not
    /// sent again. The hook a compaction runs (`source` `compact` on its stdin) is run before
    /// Claude Code has written that boundary, and a clear's (`clear`) is handed the new session's
    /// transcript, so both take nothing as told and tell the time and the memory. A path that is not a readable file, or none, tells all
    /// of it, because a line told twice costs a line and one never told is a conversation without
    /// it. Nothing printed is nothing added to the conversation.
    public static func hookCommand(memory: Bool?) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
        var command = #"i=$(cat); f=$(printf '%s' "$i" | sed -n 's/.*"transcript_path" *: *"\([^"]*\)".*/\1/p'); id=${TOPO_LAUNCH:-$$}; "#
            + #"c=$(printf '%s' "$i" | sed -n 's/.*"source" *: *"\([a-z]*\)".*/\1/p'); now=$(date +%s); t=; m=; n=; o=; "#
            + #"say() { if [ -n "$o" ]; then o=$(printf '%s\n\n%s' "$o" "$1"); else o=$1; fi; }; "#
            + #"if [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ]; then z=$(ls -ln "$f" 2>/dev/null | awk '{ print $5 }'); "#
            + #"set -- $({ if [ "$z" -le \#(transcriptWindow) ] 2>/dev/null; then cat "$f"; else tail -c \#(transcriptWindow + 1) "$f" | sed 1d; fi; } 2>/dev/null "#
            + #"| grep -F -e '"compact_boundary"' -e '"hook_success"' | awk -v note="$TOPO_LAST_PROCESS_MARK" '"#
            + #"index($0, "\"type\":\"system\",\"subtype\":\"compact_boundary\"") { t = ""; m = ""; next } "#
            + #"match($0, /^\{"parentUuid":("[^"]*"|null),"isSidechain":false,"attachment":\{"type":"hook_success","hookName":"SessionStart:[a-z]+","toolUseID":"[^"]*","hookEvent":"SessionStart","content":"/) { "#
            + #"s = substr($0, RLENGTH + 1); s = substr(s, 1, index(s, "\",\"") - 1); c = s; "#
            + #"if (note != "" && index(c, note)) n = 1; "#
            + #"while (match(s, /\[topo: time [0-9]+ [0-9a-z-]+\]/)) { t = substr(s, RSTART + 12, RLENGTH - 13); sub(/ .*/, "", t); s = substr(s, RSTART + RLENGTH) } "#
            + #"s = c; while (match(s, /\[topo: memory [a-z]+ at [0-9]+ [0-9a-z-]+\]/)) { m = substr(s, RSTART + 14, RLENGTH - 15); sub(/ .*/, "", m); s = substr(s, RSTART + RLENGTH) } } "#
            + #"END { print (t == "" ? "-" : t), (m == "" ? "-" : m), (n ? "told" : "-") }'); "#
            + #"t=$1; m=$2; n=$3; fi; [ "$t" = - ] && t=; case "$c" in compact|clear) t=; m=;; esac; "#
            + #"if [ -z "$t" ] || [ "$t" -gt "$now" ] || [ $((now - t)) -ge \#(timeGap) ]; then "#
            + #"say "$(printf '%s\n[topo: time %s %s]' \#(quoted(timePrompt)) "$now" "$id")"; fi; "#
        if let memory {
            command += #"s=\#(memory ? "mounted" : "unmounted"); "#
                + #"[ "$m" = "$s" ] || say "$(printf '%s\n[topo: memory %s at %s %s]' \#(quoted(memoryPrompt(mounted: memory))) "$s" "$now" "$id")"; "#
        }
        command += #"[ -z "$TOPO_LAST_PROCESS" ] || [ "$n" = told ] || [ "$c" = compact ] || [ "$c" = clear ] || say "$(printf '%s\n%s' "$TOPO_LAST_PROCESS" "$TOPO_LAST_PROCESS_MARK")"; "#
            + #"[ -z "$o" ] || printf '%s' "$o""#
        return command
    }

    /// The settings every launch is given on top of the home's own, whose hooks still run: one
    /// SessionStart hook (`hookCommand`), whose output Claude Code adds to the conversation. On
    /// `startup` and `resume`, and on `compact` and `clear`, since a compaction or a `/clear`
    /// typed in the chat takes what the conversation was told away inside the process.
    public static func settings(memory: Bool?) -> String {
        let hook: [String: Any] = ["matcher": "startup|resume|compact|clear", "hooks": [["type": "command", "command": hookCommand(memory: memory)]]]
        let settings = ["hooks": ["SessionStart": [hook]]]
        let data = try! JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
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
    ///
    /// `threads` is the name of the variable that turns on Claude Code's message threads
    /// (`MessageThreads`), set to `1`, or nil to set none. It is the mind's to rename, so it is set
    /// only where nothing else is: a name the guest's environment or the callback sets is left as
    /// they have it, and one of the launcher's own (`ownNames`) is not set for threads at all;
    /// either way the launch goes without threads. A launch that sets it also leaves
    /// `nonessentialVariable` out, which threads want (below); one that sets none keeps it, so
    /// off lets none of that out (a full-scope login still asks about its account: its profile and
    /// connectors among what was checked).
    public func launchEnvironment(compactAt: Int? = nil, note: String? = nil, threads: String? = nil) async throws -> [String: String] {
        var environment = Guest.environment
        environment.merge(try await self.environment()) { _, new in new }
        if let threads, environment[threads] == nil, !Self.ownNames.contains(threads) {
            environment[threads] = Self.threadsValue
            // With its nonessential traffic off, Claude Code 2.1.316 sent a phone's full-scope
            // login's turns on no thread at all (samdu/topo#782), and any login's continues with
            // system and tools again, since what leaves them to the thread is a feature flag it
            // fetches. So asking for threads lets that traffic out: the flags, the usage
            // telemetry to Anthropic and Datadog, the public MCP registry's listing.
            environment[Self.nonessentialVariable] = nil
        }
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
        // A launch's id, which the hook's marks end with, so no two tellings are the same bytes.
        environment[Self.launchVariable] = UUID().uuidString.lowercased()
        // A timed run asks Claude Code how each turn's time to its first request was spent; an
        // ordinary launch never does, whatever the callback supplied.
        environment[Self.timingVariable] = Perf.recording ? "1" : nil
        return environment
    }

    /// The guest's switch for Claude Code's traffic beside its turns, which a launch with threads
    /// takes away (`Guest.environment` sets it for every other program the app starts in the guest;
    /// what the resident starts inherits the resident's).
    public static let nonessentialVariable = "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

    /// The names the launcher sets or clears below whatever came before, so none of them can be
    /// the threads variable's.
    static let ownNames: Set<String> = ["HOME", "IS_SANDBOX", compactWindowVariable, compactAtVariable, noteVariable, noteMarkVariable, launchVariable, timingVariable]

    /// What the threads variable is set to: the one value, whatever its name.
    public static let threadsValue = "1"

    /// Claude Code puts `time_to_request_ms` and its phases on each result while this is set.
    public static let timingVariable = "CLAUDE_CODE_EMIT_STARTUP_TIMING"

    /// The share of its effective window, in whole percent, at which Claude Code compacts.
    public static let compactAtVariable = "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"

    /// The window the threshold is taken over, which Claude Code clamps to the model's own: the
    /// largest it accepts, so it is every model's whole window.
    public static let compactWindowVariable = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
    public static let compactWindow = "1000000"

    /// `memory` is the session's (`GuestSession.use(memory:)`): true or false says so to the
    /// resident (`memoryPrompt`), nil says nothing. A launch mounts nothing: what it says is what
    /// the last reconcile of the mount found, and the session replaces a process told otherwise.
    public func launch(resume session: String?, model: String?, memory: Bool?, compactAt: Int?, threads: String?, note: String?) async throws -> any ResidentProcess {
        try await guest.spawn("/bin/sh", commandLine(resume: session, model: model, memory: memory),
                              environment: try await launchEnvironment(compactAt: compactAt, note: note, threads: threads))
    }
}
