import Foundation

/// The guest's half of the tool service: the `topo` command, the skill that tells Claude Code it
/// is there, and the two shims that hand GitHub's token to `git` and `gh` for one command. All are
/// written into the guest's home by the app on every start (`install(home:)`), so they are always
/// the ones this build of the app answers, and the commands are linked onto the guest's path
/// (`links`).
public enum GuestTools {
    /// Where `topo` is on the guest's path.
    public static let command = "/usr/local/bin/topo"
    /// Where the script is written, under the home.
    public static let scriptPath = ".topo/bin/topo"
    /// Where the skill is written, under the home: Claude Code reads a user's skills from
    /// `$HOME/.claude/skills/<name>/SKILL.md`.
    public static let skillPath = ".claude/skills/topo/SKILL.md"
    /// git's credential helper for github.com, under the home and on the path.
    public static let credentialHelperPath = ".topo/bin/git-credential-topo"
    public static let credentialHelperCommand = "/usr/local/bin/git-credential-topo"
    /// The `gh` wrapper, under the home and on the path ahead of `/usr/bin/gh`.
    public static let ghPath = ".topo/bin/gh"
    public static let ghCommand = "/usr/local/bin/gh"

    /// Each script under the home, and where it is linked on the guest's path.
    public static let links: [(script: String, command: String)] = [
        (scriptPath, command),
        (credentialHelperPath, credentialHelperCommand),
        (ghPath, ghCommand),
    ]

    /// What the guest's environment gains beside the service's URL and token: git told to ask
    /// `git-credential-topo`, and only it, for github.com over https, through git's own
    /// environment configuration, so nothing is written into the home's `.gitconfig`. The empty
    /// value first clears every helper configured before it (a `credential.helper store` in the
    /// home's config included), since git hands an answer to every helper on its list to keep,
    /// and a `store` would write the token to `~/.git-credentials` and answer from it after a
    /// disconnect.
    public static let environment: [String: String] = [
        "GIT_CONFIG_COUNT": "2",
        "GIT_CONFIG_KEY_0": "credential.https://github.com.helper",
        "GIT_CONFIG_VALUE_0": "",
        "GIT_CONFIG_KEY_1": "credential.https://github.com.helper",
        "GIT_CONFIG_VALUE_1": "topo",
    ]

    /// Writes the scripts (executable: the guest sees the host's mode bits) and the skill under
    /// `home`, replacing whatever is there.
    public static func install(home: URL) throws {
        let files = FileManager.default
        let skill = home.appendingPathComponent(skillPath)
        let scripts = [(scriptPath, script), (credentialHelperPath, credentialHelper), (ghPath, gh)]
        for url in [skill] + scripts.map({ home.appendingPathComponent($0.0) }) {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        for (path, text) in scripts {
            let url = home.appendingPathComponent(path)
            try Data(text.utf8).write(to: url, options: .atomic)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
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
    # The body: the token first (printf is bash's own, so the token is in no process's
    # arguments, where every process in the guest could read it), then one argument a line, each
    # in base64, so whatever it holds arrives whole. `wget` posts from a file it opens by name,
    # and iSH cannot open a pipe by path (no `/dev/stdin`, and `/proc/self/fd` does not reopen),
    # so the body goes through a FIFO in a directory of its own: a FIFO holds nothing on the
    # disk, so neither the token nor an argument is ever written down, and the answer comes back
    # on wget's standard output. The writer is bounded, so one whose reader never came (a wget
    # that failed first, a `topo` killed) is gone within the call's own bound, and it writes
    # nothing unless it opened the FIFO: a `topo` ended before then has removed the directory,
    # and a writer that carried on would print the token on the standard output it inherited. `wget -q` says
    # nothing on success, so its standard error joins the answer only when it failed; the
    # trailing `.` keeps the answer's last newlines, which a command substitution would strip.
    fifo_dir="$(mktemp -d)" || { echo "topo: no room in /tmp for the call" >&2; exit 3; }
    trap 'rm -rf "$fifo_dir"' EXIT
    mkfifo -m 600 "$fifo_dir/request" || { echo "topo: no room in /tmp for the call" >&2; exit 3; }
    timeout 110 bash -c '
        exec > "$1" || exit 1; shift
        printf "%s\n" "$TOPO_TOOLS_TOKEN"
        for argument in "$@"; do
            printf "%s" "$argument" | base64 | tr -d "\n"
            printf "\n"
        done
    ' topo-request "$fifo_dir/request" "$@" &
    writer=$!
    answer="$(
        wget -q -T 100 -O - --header "Content-Type: text/plain" \
            --post-file "$fifo_dir/request" "$TOPO_TOOLS_URL/run" 2>&1
        fetched=$?
        printf .
        exit "$fetched"
    )"
    fetched=$?
    answer="${answer%.}"
    kill "$writer" 2>/dev/null
    wait "$writer" 2>/dev/null
    if [ "$fetched" != 0 ]; then
        case "$answer" in
            *" 401"*|*" 403"*|*" 404"*|*" 405"*|*" 400"*)
                echo "topo: the phone's tool service refused the call" >&2 ;;
            *)
                echo "topo: the phone's tool service did not answer (the app may be in the background)" >&2 ;;
        esac
        exit 3
    fi
    first="${answer%%$'\n'*}"
    case "$first" in
        "exit: "*) status="${first#exit: }" ;;
        *) echo "topo: the phone's tool service answered something unreadable" >&2; exit 3 ;;
    esac
    if [ "$first" != "$answer" ]; then
        printf '%s' "${answer#*$'\n'}"
    fi
    exit "$status"
    """#

    /// git's credential helper: git runs it as `git credential-topo get` for an https URL on
    /// github.com (`environment`), with the request's attributes on stdin. It answers with what
    /// `topo github credential` says, and with nothing for any other host, so git carries on as it
    /// would have; when the app has no token to give it says why on stderr — not connected, the
    /// keychain unreadable, or the app not answering, as `topo` said — which git relays. `store`
    /// and `erase` do nothing, since the app holds the token.
    public static let credentialHelper = #"""
    #!/bin/bash
    # git-credential-topo: GitHub's token from the Topo app, for one git command.
    # Written by the app on every start; an edit here lasts until the next one.
    if [ "${1:-}" != get ]; then
        cat > /dev/null
        exit 0
    fi
    protocol=
    host=
    while IFS= read -r line && [ -n "$line" ]; do
        case "$line" in
            protocol=*) protocol="${line#protocol=}" ;;
            host=*) host="${line#host=}" ;;
        esac
    done
    if [ "$protocol" != https ] || [ "$host" != github.com ]; then
        exit 0
    fi
    if answer="$(topo github credential)"; then
        printf '%s\n' "$answer"
    else
        status=$?
        # Status 1 is the app's own sentence (not connected, or the keychain unreadable) on
        # stdout; any other status, `topo` has already said why on stderr.
        [ -n "$answer" ] && printf 'git-credential-topo: %s\n' "$answer" >&2
        echo "git-credential-topo: no GitHub token from the Topo app (topo github: status $status)" >&2
    fi
    exit 0
    """#

    /// `gh` with GitHub's token from the app in that one process's environment, never the
    /// resident's. A `GH_TOKEN` or `GITHUB_TOKEN` already set is left to `gh`; when the app has no
    /// token to give it says why, as `topo` said, and runs `gh` as it is.
    public static let gh = #"""
    #!/bin/bash
    # gh: GitHub's CLI with the token from the Topo app, for this one command.
    # Written by the app on every start; an edit here lasts until the next one.
    real=/usr/bin/gh
    if [ ! -x "$real" ]; then
        echo "gh is not installed in the guest: apk add github-cli" >&2
        exit 127
    fi
    if [ -n "${GH_TOKEN:-}" ] || [ -n "${GITHUB_TOKEN:-}" ]; then
        exec "$real" "$@"
    fi
    token="$(topo github token)"
    status=$?
    if [ "$status" = 0 ]; then
        GH_TOKEN="$token" exec "$real" "$@"
    fi
    # Status 1 is the app's own sentence on stdout; any other, `topo` has said why on stderr.
    [ -n "$token" ] && printf 'gh: %s\n' "$token" >&2
    # gh is not run without the app's token: it would use a login of the guest's own, which can be
    # another account's and outlives a disconnect.
    echo "gh: no GitHub token from the Topo app (topo github: status $status); gh not run (set GH_TOKEN to run it with a token of your own)" >&2
    exit "$status"
    """#

    /// The skill: its description is the whole of what a turn pays for the tools until one is
    /// wanted, and its body points at `topo help`, which the app answers from the same table it
    /// dispatches through, so the two cannot drift.
    public static let skill = """
    ---
    name: topo
    description: The phone's own tools, through the `topo` command in Bash. Use it for the person's reminders, calendar and contacts, their GitHub connection, the lights, locks, thermostats and scenes of their home, where the phone is, a notification on the phone now or later, and how the Topo app looks on this phone (the transcript's margins and insets, Topo's size, speed and the room he keeps from the words), and the person's home-screen, lock-screen and watch widgets, which you design and wire up yourself — whenever the person asks about their day, to be reminded, to add or check something, who someone is, to turn a light on or run a scene, where they are, or for the app to look or move differently ("tighten your margins").
    ---

    # topo

    `topo` is a command in this guest that asks the Topo app on the phone to do what only the app can. Run it with your Bash tool.

    Start with `topo help`: it lists every tool the app has, and `topo help <tool>` says how to call one. The list comes from the app itself, so it is always the current one.

    - Output is plain lines, one record a line with its id first, so a later call can name it. Exit status 0 is done; 1 the tool could not do it and says why; 2 the call was not one the tool takes (read the usage it printed); 3 the app did not answer; 4 it took too long (a permission prompt still waiting on the person, perhaps), and a call that was waiting on a prompt does nothing once it has, so run it again after they answer; 5 the person has not allowed it on this phone, and the text says where they can — tell them, rather than trying again; 6 part of the call was refused, and the text says which part and why.
    - The first call that needs Reminders, Calendars, Contacts, Location, Notifications or HomeKit puts up the phone's own permission prompt, and waits for the person to answer it.
    - Dates are ISO 8601 in the phone's time zone: 2026-09-27, 2026-09-27T14:30. Work out the date yourself from what the person said.
    - An option's value never starts with `--`; write one that does as `--notes=--like-this`.
    - Nothing here deletes anything. `topo reminders done` is the one change to something that already exists.
    - `topo home` lists the home with every accessory's id; `topo home get ID` says what each of its characteristics takes before you `topo home set` one. Set only what the person asked for, one accessory at a time.
    - GitHub: `topo github` says whether the person has connected it and as whom. Once they have, plain `git` over `https://github.com/…` and `gh` use it by themselves (`apk add git github-cli` if they are not installed), as the person, on any repository they can reach. Never write the token into a file, a remote URL or a git config, and never set `GH_TOKEN` yourself. When it is not connected, tell the person to connect it in Settings › Connections.
    - `topo look` shows the look this phone is wearing: each field you can tune, its value, its range and where the value came from. `topo look set <part.field> <value>` changes it on this phone at once, and the person can undo it from Settings › Tuning › Reset; `topo look reset` undoes it yourself. After a change, say in a few words what you changed.
    """
}
