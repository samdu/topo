import Foundation

/// The guest's half of the tool service: the `topo` command and the skill that tells Claude Code
/// it is there. Both are written into the guest's home by the app on every start
/// (`install(home:)`), so they are always the ones this build of the app answers, and the command
/// is linked onto the guest's path at `command`.
public enum GuestTools {
    /// Where `topo` is on the guest's path.
    public static let command = "/usr/local/bin/topo"
    /// Where the script is written, under the home.
    public static let scriptPath = ".topo/bin/topo"
    /// Where the skill is written, under the home: Claude Code reads a user's skills from
    /// `$HOME/.claude/skills/<name>/SKILL.md`.
    public static let skillPath = ".claude/skills/topo/SKILL.md"

    /// Writes the script (executable: the guest sees the host's mode bits) and the skill under
    /// `home`, replacing whatever is there.
    public static func install(home: URL) throws {
        let files = FileManager.default
        let script = home.appendingPathComponent(scriptPath)
        let skill = home.appendingPathComponent(skillPath)
        for url in [script, skill] {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(self.script.utf8).write(to: script, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data(self.skill.utf8).write(to: skill, options: .atomic)
    }

    /// `topo`: carries its arguments to the app and prints what the app says, with its status. No
    /// logic of its own, and nothing but the rootfs' bash and BusyBox `wget`, so nothing is added
    /// to the guest for it. Its own statuses are 3 (the app did not answer, or refused the call).
    public static let script = #"""
    #!/bin/bash
    # topo: the phone's own tools, run by the Topo app on its loopback. `topo help` lists them.
    # Written by the app on every start; an edit here lasts until the next one.
    if [ -z "${TOPO_TOOLS_URL:-}" ] || [ -z "${TOPO_TOOLS_TOKEN:-}" ]; then
        echo "topo: the phone's tool service is not in this environment" >&2
        exit 3
    fi
    request="$(mktemp)" || exit 3
    response="$(mktemp)" || { rm -f "$request"; exit 3; }
    trap 'rm -f "$request" "$response"' EXIT
    # The token first, in the body: printf is bash's own, so the token is in no process's
    # arguments, where every process in the guest could read it. Then one argument a line, each
    # in base64, so whatever it holds arrives whole.
    printf '%s\n' "$TOPO_TOOLS_TOKEN" > "$request"
    for argument in "$@"; do
        printf '%s' "$argument" | base64 | tr -d '\n' >> "$request"
        printf '\n' >> "$request"
    done
    # -Y off: the service is on loopback, and BusyBox wget reads http_proxy (the egress proxy's)
    # but not no_proxy, so without it the call would go to the egress proxy and be refused.
    if ! failure="$(wget -q -Y off -T 100 -O "$response" \
            --header "Content-Type: text/plain" \
            --post-file "$request" "$TOPO_TOOLS_URL/run" 2>&1)"; then
        case "$failure" in
            *" 401"*|*" 403"*|*" 404"*|*" 405"*|*" 400"*)
                echo "topo: the phone's tool service refused the call" >&2 ;;
            *)
                echo "topo: the phone's tool service did not answer (the app may be in the background)" >&2 ;;
        esac
        exit 3
    fi
    IFS= read -r first < "$response"
    case "$first" in
        "exit: "*) status="${first#exit: }" ;;
        *) echo "topo: the phone's tool service answered something unreadable" >&2; exit 3 ;;
    esac
    tail -n +2 "$response"
    exit "$status"
    """#

    /// The skill: its description is the whole of what a turn pays for the tools until one is
    /// wanted, and its body points at `topo help`, which the app answers from the same table it
    /// dispatches through, so the two cannot drift.
    public static let skill = """
    ---
    name: topo
    description: The phone's own tools, through the `topo` command in Bash. Use it to see or change how the Topo app looks on this phone — the transcript's margins and insets, Topo's size, speed and the room he keeps from the words — whenever the person asks for the app to look or move differently ("tighten your margins", "make yourself bigger", "slow down").
    ---

    # topo

    `topo` is a command in this guest that asks the Topo app on the phone to do what only the app can. Run it with your Bash tool.

    Start with `topo help`: it lists every tool the app has, and `topo help <tool>` says how to call one. The list comes from the app itself, so it is always the current one.

    - Output is plain lines. Exit status 0 is done; 1 the tool could not do it and says why; 2 the call was not one the tool takes (read the usage it printed); 3 the app did not answer; 4 it took too long; 6 part of the call was refused, and the text says which part and why.
    - `topo look` shows the look this phone is wearing: each field you can tune, its value, its range and where the value came from. `topo look set <part.field> <value>` changes it on this phone at once, and the person can undo it from Settings › Tuning › Reset; `topo look reset` undoes it yourself. After a change, say in a few words what you changed.
    """
}
