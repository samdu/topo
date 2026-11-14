#!/usr/bin/env bash
# Builds Topo, boots a simulator, signs it in with the long-lived Claude setup token, and
# optionally makes it say something and asserts the reply landed in the log.
#
# A --send run takes the turn through the chat's own harness, which the guest's resident Claude
# Code answers. It passes only when the app printed `done`, printed no `error:`, printed
# `reply to <turn> in run <id> from session <session>, process <pid>:` under the id this script
# launched it with (the reply DebugRun found by the sent turn's nonce and the reply's parents,
# written by the resident process it names), and printed `mascot: turn began for <refs>` and
# `mascot: turn gone for <refs>` with that turn among the refs, or, for words given ahead of their
# save, `heard:<nonce>` with the nonce of `sending under <nonce> in run <id>:` (Topo on the glass
# following this turn, with every pose between them), and `records: iCloud` (the turn's records are
# CloudKit's, not a journal on the phone; --fresh starts an install that decided on the phone again). A launcher that
# exits before `done`, or non-zero at all, a turn not finished within TIMEOUT seconds (180), a
# missing or foreign reply, and a reply no resident session wrote each exit non-zero. Before the
# turn the app asks CloudKit for the account and the Topo zone (`icloud: `, DebugRun.iCloud); a
# device with no account, or one whose sign-in has lapsed, which leaves CloudKit's requests
# hanging rather than failing, exits non-zero there with the --sign-in command that fixes it.
# scripts/tests/simulator-run-test.sh holds this against a fake xcrun.
#
#   scripts/simulator-run.sh                        # build, boot, install, launch signed in
#   scripts/simulator-run.sh --send "hello"         # ... and send one turn, asserting the reply
#   scripts/simulator-run.sh --press-mic            # ... after pressing the microphone (TopoUITests)
#   scripts/simulator-run.sh --talk                 # speak a question, assert it is answered aloud
#   scripts/simulator-run.sh --userland "echo hi" --expect hi   # boot the guest, run a command
#   scripts/simulator-run.sh --userland "echo hi" --fresh --expect-rootfs fetched
#   scripts/simulator-run.sh --userland "echo hi" --no-build --expect-rootfs reused
#   scripts/simulator-run.sh --userland "claude --version" --fresh --expect-claude fetched
#   scripts/simulator-run.sh --guest-turn "say hi || what did I ask?"   # turns to the resident Claude Code
#   scripts/simulator-run.sh --guest-turn "run echo topo-\$((6*7)) in bash" --expect-bash topo-42
#   scripts/simulator-run.sh --screenshot ~/s.png   # ... and capture the screen
#   scripts/simulator-run.sh --erase                # tear the simulator down, keychain and all
#   scripts/simulator-run.sh --sign-in              # sign the simulator into buddy's iCloud account
#   scripts/simulator-run.sh --sign-in --renew      # sign it out and in again after a restart ended it
#   DEVICE="iPad Pro 13-inch (M4)" scripts/simulator-run.sh   # a name, or a UDID when names repeat
#
# The token comes from the environment (CLAUDE_SETUP_TOKEN, which is what the vault item
# `long-lived-claude-auth-token` reaches this machine as) or, failing that, straight from the
# vault with `op-item`. It is handed to the app as SIMCTL_CHILD_TOPO_CLAUDE_SETUP_TOKEN, which the
# simulator's own log records with the launch's environment, and reaches no scheme, build setting
# or file the app reads; the app hands it to every `claude` it starts in the guest for that
# launch and keeps nothing of it. --talk hands it on otherwise, as below.
#
# --sign-in runs the TopoSimulatorSignIn scheme's one UI test (Tests/SimulatorSignIn), which signs
# the device into SIGNIN_ACCOUNT (buddy.durose@icloud.com) through Settings, as a first sign-in or
# again after a lapse, and passes only when scripts/ci-require-tests.sh finds it ran and passed.
# The password is the vault item `Buddy Apple ID`, read with `op-item` and handed to the test
# runner once over the host's loopback, never as an argument, a file or the runner's environment.
# It is typed once: a refusal, a two-factor code or a screen the test does not know stops the run
# with what the screen showed. A two-factor stop leaves the code screen up, and
# SIGNIN_CODE=<code> scripts/simulator-run.sh --sign-in types the code into it and goes on.
# The sign-in does not survive a restart of the simulator: it keeps no continuation key and no
# CloudKit token on disk, so after a reboot Settings still shows the account, nothing asks for the
# password, and CloudKit answers "temporarily unavailable"; a change of the account's password
# ends it the same way without a restart. --renew signs the account out in
# Settings and in again, typing the password once; it is asked for by name, never taken.
# The password is typed through RedactedTyping, never XCTest's typeText, which writes what it
# types into its activity's title and so into the run's output and the result bundle.
#
# --leak-check proves that on a dummy, on a simulator signed into nothing that matters: it types a
# random dummy, served as the password is, into a web page's password field in Safari, once with
# typeText (the control) and through RedactedTyping in a run that passes and one that fails after
# typing, and counts every 8-character run of each dummy in the run's output, the result bundle
# (its compressed blobs unpacked with zstd), build/sim/Logs/Test and the device's and the Mac's
# logs for the run. It passes only when the control's dummy is found in the output and the bundle,
# the redacted one nowhere, and neither redacted bundle holds a screen recording. It prints
# counts, never a dummy.
#
# Every turn a debug build takes goes to Haiku, whatever the model setting says: the pin is
# ClaudeModel.pinned in Packages/TopoTurn/Sources/TopoTurn/ClaudeModel.swift, and APIProxy.pinnedModel
# in the guest's proxy.
#
# --talk runs the TopoTalk scheme's one UI test (Tests/ClientTalk) and nothing else: it fetches
# and verifies the ear's models into EAR_MODELS (build/ear-models) and the voice's bundle into
# VOICE_MODELS (build/phonon; scripts/phonon-bundles.sh, with Sam's Hugging Face token), starts the loopback lane with
# Tests/Fixtures/capital-of-france.wav (scripts/ci-audio-lane.sh; BlackHole as the Mac's default
# input and output), serves the token once on the host's loopback (as --sign-in serves the
# password) to the app the test launches, which reads it itself from the port and nonce the test
# hands it, so neither the runner's environment nor the app's launch environment, both of which
# the result bundle records, carries it, and passes only when the listener served it and
# scripts/ci-require-tests.sh finds the test ran and passed, never skipped. The lane is stopped and the Mac's defaults restored on every exit. Its turn is a real one.
#
# A --userland run needs no token. The app fetches or reuses the guest's rootfs and Claude Code,
# boots the guest, verifies and mounts Claude Code at /usr/local/bin/claude, and runs the command
# under /bin/sh -c (DebugRun.userland, TOPO_DEBUG_USERLAND); the run passes only when the app
# printed `userland done`, no `userland error:`, a line saying Claude Code was verified and
# mounted, and `guest exit: 0`, and, when asked, the exact guest line --expect names, the rootfs
# line --expect-rootfs names (`fetched`: this launch downloaded and imported it; `reused`: it found
# the fakefs whole and fetched nothing) and the Claude Code line --expect-claude names (`fetched`:
# this launch downloaded it; `reused`: it was on the phone, and nothing was fetched or copied).
# --fresh uninstalls the app first, which takes its data container, fakefs and all, with it.
#
# A --guest-turn run launches signed in with TOPO_DEBUG_GUEST_TURN (DebugRun.guestTurn): the resident
# Claude Code in the guest takes the turns, separated by " || ", one after another in one process.
# It passes only when every turn names the same session and resident process, the app printed
# `guest turn done`, no `guest turn error:`, no turn that
# failed or was abandoned, and for every turn a `model:` line naming the model it ran on (Haiku,
# since the build is Debug) and an `answered in <seconds> s:` line. With --expect-bash OUTPUT it
# passes only when one turn made a Bash tool call (`guest turn N tool: Bash`), that call's result
# came back without an error (`guest turn N tool result: Bash: ok: …`) with OUTPUT in its text,
# the part after that prefix alone, and the same turn's reply text carries OUTPUT too: a reply alone proves nothing, since the model can
# write the output without running anything or after a call that failed.
#
# Building runs scripts/build-ish.sh first: the guest's framework is built from the fork's pin and
# is not in the repository.
#
# Every run writes two files under build/sim and prints their paths first. simulator-run.log is
# everything the run prints, kept after it, so a run started in the background can be read once
# it is over. simulator-run.pids is the pids the run started, the script's own first and then
# each xcodebuild and the launcher; it is removed when the run ends. Ending a run is
# `kill $(head -1 build/sim/simulator-run.pids)`: the script ends what that file names and
# nothing else, so a sibling worktree's xcodebuild is never touched.
#
# On buddybox xcodebuild needs the login keychain, so run this from the GUI session:
#   ssh buddybox 'sudo launchctl asuser $(id -u) sudo -u buddy bash -lc "cd ~/github/topo && scripts/simulator-run.sh --send hello"'
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

bundle=zone.hexagon.topo
device="${DEVICE:-iPhone 17}"
derived="$root/build/sim"
send=""
screenshot=""
erase=no
build=yes
pressmic=no
talk=no
userland=""
guestturn=""
expect=""
expect_rootfs=""
expect_claude=""
expect_bash=""
fresh=no
signin=no
renew=no
resume=no
leakcheck=no
timeout="${TIMEOUT:-180}"

while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --send) send="$2"; shift 2 ;;
    --press-mic) pressmic=yes; shift ;;
    --screenshot) screenshot="$2"; shift 2 ;;
    --erase) erase=yes; shift ;;
    --no-build) build=no; shift ;;
    --talk) talk=yes; shift ;;
    --userland) userland="$2"; shift 2 ;;
    --guest-turn) guestturn="$2"; shift 2 ;;
    --expect) expect="$2"; shift 2 ;;
    --expect-rootfs) expect_rootfs="$2"; shift 2 ;;
    --expect-claude) expect_claude="$2"; shift 2 ;;
    --expect-bash) expect_bash="$2"; shift 2 ;;
    --fresh) fresh=yes; shift ;;
    --sign-in) signin=yes; shift ;;
    --renew) renew=yes; shift ;;
    --resume) resume=yes; shift ;;
    --leak-check) leakcheck=yes; shift ;;
    -h|--help) sed -n '2,114p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# A name matches the device of that name on the newest iOS runtime that has one, so the default
# is the iPhone 17 on the runtime the suites pin rather than whichever the list gives first.
udid="$(xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, re, sys
n = sys.argv[1]
def version(runtime):
    m = re.search(r"iOS-(\d+(?:-\d+)*)$", runtime)
    return tuple(int(x) for x in m[1].split("-")) if m else ()
found = [(version(r), d["udid"]) for r, ds in json.load(sys.stdin)["devices"].items() for d in ds if n in (d["name"], d["udid"])]
print(max(found)[1] if found else "")' "$device")"
[ -n "$udid" ] || { echo "no available simulator named '$device'; xcrun simctl list devices available" >&2; exit 1; }

[ "$renew" = no ] || [ "$signin" = yes ] || { echo "--renew is a way of --sign-in: --sign-in --renew" >&2; exit 2; }
[ "$resume" = no ] || { [ "$signin" = yes ] && [ "$renew" = no ]; } || { echo "--resume is a way of --sign-in, without --renew: --sign-in --resume" >&2; exit 2; }
[ "$leakcheck" = no ] || [ "$signin" = no ] || { echo "--leak-check signs nothing in: run it alone, on a simulator signed into nothing that matters" >&2; exit 2; }

if [ "$erase" = yes ]; then
  echo "==> $device ($udid)"
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl erase "$udid"
  echo "==> erased; the simulator's iCloud account and the app's data are gone"
  exit 0
fi

# The token, read once into a variable and never echoed. `set -u` makes an unset one an error
# rather than an empty header the API answers 401 to.
read_token() {
  token="${CLAUDE_SETUP_TOKEN:-}"
  if [ -z "$token" ]; then
    token="$(op-item get long-lived-claude-auth-token 'oauth token')"
  fi
  [ -n "$token" ] || { echo "no Claude setup token: set CLAUDE_SETUP_TOKEN or check the vault item" >&2; exit 1; }
}

case "$expect_rootfs" in
  ""|fetched|reused) ;;
  *) echo "--expect-rootfs takes fetched or reused, not '$expect_rootfs'" >&2; exit 2 ;;
esac
case "$expect_claude" in
  ""|fetched|reused) ;;
  *) echo "--expect-claude takes fetched or reused, not '$expect_claude'" >&2; exit 2 ;;
esac

# What this run started, and nothing else on the Mac: the pids file names the script and every
# xcodebuild and launcher it starts, and `cleanup` ends those. An xcodebuild runs in the
# background under `wait`, so a signal to the script reaches the trap at once rather than after
# the build.
mkdir -p "$derived"
pids="$derived/simulator-run.pids"
runlog="$derived/simulator-run.log"
started_pids=""
lane=no
log=""
echo "$$" >"$pids"

# Everything printed from here goes to the run's log as well as to where it was going. tee reads
# a fifo rather than a process substitution, so its pid is known and `cleanup` can wait for the
# last line to be written; it ignores SIGPIPE and SIGINT, so a caller that has gone, or a ^C,
# leaves the file whole. That wait is bounded by the clock, not a count of polls: tee ends when
# the last writer of the fifo does, and a process an ended xcodebuild left behind may still hold
# it. The wait ends at the first poll after two seconds (one to two, `$SECONDS` being whole), so
# it is that plus the one `sleep` in progress; a poll starts no other process, since on a loaded
# Mac every process a poll starts is slower, and a count of polls would stretch with them. The
# poll is `kill -0`, not `cleanup`'s running-child test: a pid reissued once tee is reaped costs
# nothing worse than the wait's bound.
fifo="$derived/simulator-run.$$.fifo"
rm -f "$fifo"
mkfifo "$fifo"
(trap '' PIPE; exec tee -i "$runlog") <"$fifo" &
tee_pid=$!
exec >"$fifo" 2>&1
rm -f "$fifo"
echo "==> $device ($udid)"
echo "==> log: $runlog"
echo "==> pids: $pids"

cleanup() {
  # Only a recorded pid that is still this shell's running child is signalled: one already
  # reaped is a number the system may have handed to somebody else's process.
  local pid live
  live=" $(jobs -pr | tr '\n' ' ')"
  for pid in $started_pids; do
    case "$live" in *" $pid "*) kill "$pid" 2>/dev/null || true ;; esac
  done
  [ "$lane" != ours ] || scripts/ci-audio-lane.sh stop || true
  [ -z "$log" ] || rm -f "$log"
  # A newer run in this worktree has its own pids file under the same name.
  [ "$(head -1 "$pids" 2>/dev/null)" != "$$" ] || rm -f "$pids"
  exec >&- 2>&-
  local deadline=$((SECONDS + 2))
  while [ "$SECONDS" -lt "$deadline" ] && kill -0 "$tee_pid" 2>/dev/null; do
    sleep 0.1
  done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Whether the pid is one of this shell's children and still running.
running_child() {
  case " $(jobs -pr | tr '\n' ' ') " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Runs a command as a recorded child and waits for it, returning its status.
tracked() {
  "$@" &
  local pid=$! status=0
  echo "$pid" >>"$pids"
  started_pids="$started_pids $pid"
  wait "$pid" || status=$?
  return "$status"
}

# Serves one secret once on the host's loopback, which a simulator shares: a listener that answers
# the first request carrying the nonce with the secret and exits, hands nothing to a request
# without it, and gives up after 30 minutes unasked. The secret leaves its variable once, on a
# pipe to the listener, never as an argument or a file. The listener is a recorded child, so
# `cleanup` ends one nobody asked. Sets served_port, and served_by to the listener's pid, whose
# exit status is 0 once it has served the secret.
# serve_once <nonce> <name of the variable holding the secret>
serve_once() {
  local nonce="$1" portfile="$derived/served.$$.port" listener
  rm -f "$portfile"
  /usr/bin/python3 -c '
import socket, sys, time
nonce, portfile, secret = sys.argv[1].encode(), sys.argv[2], sys.stdin.buffer.read()
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(4)
open(portfile, "w").write(str(server.getsockname()[1]))
deadline = time.monotonic() + 1800
while time.monotonic() < deadline:
    server.settimeout(max(1, deadline - time.monotonic()))
    try:
        peer, _ = server.accept()
    except socket.timeout:
        break
    with peer:
        peer.settimeout(10)
        try:
            asked = peer.makefile("rb").readline().strip()
        except OSError:
            continue
        if asked == nonce:
            peer.sendall(secret)
            sys.exit(0)
sys.exit(1)' "$nonce" "$portfile" < <(printf '%s' "${!2}") &
  listener=$!
  served_by=$listener
  echo "$listener" >>"$pids"
  started_pids="$started_pids $listener"
  for _ in $(seq 50); do [ -s "$portfile" ] && break; sleep 0.2; done
  served_port="$(cat "$portfile" 2>/dev/null)"
  rm -f "$portfile"
  [ -n "$served_port" ] || { echo "the listener that serves the $2 did not start" >&2; exit 1; }
}

# When the process with this pid started, in seconds since the epoch, or nothing for no pid.
process_start() {
  [ -n "$1" ] || return 0
  local started
  started="$(ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')" || return 0
  [ -n "$started" ] || return 0
  LC_ALL=C date -j -f '%a %b %d %T %Y' "$started" +%s 2>/dev/null || true
}

# How many times any 8-character run of the secret on fd 3 is in each path (a file, or a folder
# read whole, its gzip and zstd blobs unpacked, which a result bundle's are) or, for "-", in
# stdin. Prints "<label> <path>: <count>", "unreadable" for a blob it could not unpack, and the
# screen recordings among the files, which show what a secure field is given and which no count
# of bytes can read; nothing of the secret, which arrives on a pipe and never as an argument.
# count_runs <label> <path>...
count_runs() {
  /usr/bin/python3 -c '
import gzip, os, subprocess, sys
label, paths = sys.argv[1], sys.argv[2:]
unread, videos = set(), {}
secret = os.fdopen(3, "rb").read()
runs = {secret[i:i + 8] for i in range(len(secret) - 7)}
runs |= {r.decode().encode("utf-16-le") for r in list(runs)}
def blobs(path):
    videos[path] = 0
    if path == "-":
        yield sys.stdin.buffer.read(); return
    files = [path] if os.path.isfile(path) else [os.path.join(d, f) for d, _, fs in os.walk(path) for f in fs]
    for f in files:
        try:
            data = open(f, "rb").read()
        except OSError:
            continue
        yield data
        if data[4:8] == b"ftyp":
            videos[path] += 1
        if data[:4] == b"\x28\xb5\x2f\xfd":
            try:
                yield subprocess.run(["zstd", "-dcq", f], capture_output=True, check=True, timeout=120).stdout
            except Exception:
                unread.add(path)
        if data[:2] == b"\x1f\x8b":
            try:
                yield gzip.decompress(data)
            except Exception:
                pass
for path in paths:
    found = path == "-" or os.path.exists(path)
    n = sum(blob.count(r) for blob in blobs(path) for r in runs) if found else "absent"
    if path in unread:
        n = "unreadable"
    elif videos.get(path):
        n = f"{n} and {videos[path]} screen recording(s)"
    print(f"{label} {path}: {n}")' "$@"
}

if [ "$leakcheck" = yes ]; then
  # The page the dummy is typed into, served on the host's loopback until the run ends.
  pagefile="$derived/leak-check.$$.port"
  rm -f "$pagefile"
  /usr/bin/python3 -c '
import http.server, sys
page = b"""<!doctype html><meta name=viewport content="width=device-width">
<form><input type=password aria-label="leak-check" autocomplete=off oninput="shown(this.value)"></form><p id=h>sha none</p>
<script>
function shown(value) {
  crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)).then(function (b) {
    document.getElementById("h").textContent = "sha " + Array.from(new Uint8Array(b), function (x) { return x.toString(16).padStart(2, "0"); }).join("");
  });
}
</script>"""
class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers(); self.wfile.write(page)
    def log_message(self, *_): pass
server = http.server.HTTPServer(("127.0.0.1", 0), Page)
open(sys.argv[1], "w").write(str(server.server_address[1]))
server.timeout = 1800
server.serve_forever()' "$pagefile" &
  page_pid=$!
  echo "$page_pid" >>"$pids"
  started_pids="$started_pids $page_pid"
  for _ in $(seq 50); do [ -s "$pagefile" ] && break; sleep 0.2; done
  page_port="$(cat "$pagefile" 2>/dev/null)"
  rm -f "$pagefile"
  [ -n "$page_port" ] || { echo "the leak check's page did not start" >&2; exit 1; }
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  status=0
  counts="$derived/leak-check.$$.counts"
  : >"$counts"
  # A failing run is the one a stopped sign-in leaves, which keeps what a passing one may not.
  for route in typeText redacted failing; do
    # Letters and digits with symbols among them, as a password has, in runs longer than eight.
    dummy="$(openssl rand -base64 48 | tr -dc A-Za-z0-9 | cut -c1-30)"
    dummy="${dummy:0:10}#${dummy:10:10}%!${dummy:20}"
    nonce="$(uuidgen)"
    serve_once "$nonce" dummy
    results="$derived/TopoLeakCheck-$route.xcresult"
    rm -rf "$results"
    since="$(date '+%Y-%m-%d %H:%M:%S')"
    xcrun simctl openurl "$udid" "http://127.0.0.1:$page_port/"
    echo "==> typing a dummy into Safari's password field by $route"
    TEST_RUNNER_TOPO_SIGNIN_PORT="$served_port" TEST_RUNNER_TOPO_SIGNIN_NONCE="$nonce" \
    TEST_RUNNER_TOPO_LEAKCHECK_ROUTE="$([ "$route" = failing ] && echo redacted || echo "$route")" \
    TEST_RUNNER_TOPO_LEAKCHECK_FAIL="$([ "$route" = failing ] && echo 1 || echo 0)" \
      tracked xcodebuild test -project Topo.xcodeproj -scheme TopoSimulatorSignIn -configuration Debug \
        -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
        -only-testing:TopoSimulatorSignInTests/LeakCheckTests \
        -collect-test-diagnostics never -resultBundlePath "$results" && ran=0 || ran=$?
    if [ "$route" = failing ]; then
      [ "$ran" != 0 ] && grep -q 'failing after the dummy' "$runlog" \
        || { echo "==> the failing run did not fail after typing the dummy" >&2; status=1; }
    else
      [ "$ran" = 0 ] || status=1
      scripts/ci-require-tests.sh named "$results" TopoSimulatorSignInTests/LeakCheckTests || status=1
    fi
    # The logs are read on a pipe and counted, never kept: a device's log can hold what other
    # runs launched with.
    {
      count_runs "$route" "$runlog" "$results" "$derived/Logs/Test" 3< <(printf '%s' "$dummy")
      timeout 300 xcrun simctl spawn "$udid" log show --start "$since" --style compact --info --debug 2>/dev/null \
        | count_runs "$route" - 3< <(printf '%s' "$dummy") | sed 's/ -:/ device log:/'
      timeout 300 log show --start "$since" --style compact --info --debug \
          --predicate 'process == "xcodebuild" OR process == "testmanagerd" OR process BEGINSWITH "XC" OR process == "CoreSimulatorService"' 2>/dev/null \
        | count_runs "$route" - 3< <(printf '%s' "$dummy") | sed 's/ -:/ Mac log:/'
    } | tee -a "$counts"
    unset dummy
  done
  # The control's bundle holds its dummy, which is worth nothing, but is not kept either.
  rm -rf "$derived"/TopoLeakCheck-*.xcresult
  for sink in "$runlog" "TopoLeakCheck-typeText.xcresult"; do
    grep -E "^typeText [^ ]*$(basename "$sink" | sed 's/[.]/[.]/g'): [1-9]" "$counts" >/dev/null \
      || { echo "==> the control's dummy is not in $(basename "$sink"): this check cannot see what typeText records there" >&2; status=1; }
  done
  if grep -E '^(redacted|failing) .*: ([1-9]|absent|unreadable|0 and)' "$counts" | grep -v 'Logs/Test: absent' >&2; then
    echo "==> the redacted dummy is in what the run left, a sink was not read, or the screen was recorded" >&2; status=1
  fi
  rm -f "$counts"
  [ "$status" = 0 ] && echo "==> leak check passed: typeText's dummy is in the run's output and bundle, RedactedTyping's in nothing a passing or a failing run left"
  exit "$status"
fi

if [ "$build" = yes ]; then
  scripts/build-ish.sh
  scripts/fetch-phonon.sh
fi

if [ "$signin" = yes ]; then
  # The password is read into a variable and leaves it once, on a pipe to a listener on the
  # host's loopback that answers one request carrying this run's nonce and exits. It is never an
  # argument, a file or a variable of the test runner's environment, which the result bundle's
  # session log records whole; the runner types it into a secure field through RedactedTyping,
  # which --leak-check proves records nothing of it. Tests/SimulatorSignIn says what the test
  # answers and what it refuses to.
  account="${SIGNIN_ACCOUNT:-buddy.durose@icloud.com}"
  nonce="" port=""
  # --resume reads no password and serves none: it only answers the screens after one.
  if [ "$resume" = no ]; then
    password="$(op-item get 'Buddy Apple ID' password)" || password=""
    [ -n "$password" ] || { echo "no password from the vault item 'Buddy Apple ID'" >&2; exit 1; }
    nonce="$(uuidgen)"
    serve_once "$nonce" password
    unset password
    port="$served_port"
  fi
  results="$derived/TopoSimulatorSignIn.xcresult"
  rm -rf "$results"
  xcrun simctl boot "$udid" 2>/dev/null || true
  xcrun simctl bootstatus "$udid" -b >/dev/null
  echo "==> signing $udid into $account through Settings (TopoSimulatorSignInTests)"
  status=0
  TEST_RUNNER_TOPO_SIGNIN_ACCOUNT="$account" TEST_RUNNER_TOPO_SIGNIN_PORT="$port" \
  TEST_RUNNER_TOPO_SIGNIN_NONCE="$nonce" TEST_RUNNER_TOPO_SIGNIN_CODE="${SIGNIN_CODE:-}" \
  TEST_RUNNER_TOPO_SIGNIN_RENEW="$([ "$renew" = yes ] && echo 1 || echo 0)" \
  TEST_RUNNER_TOPO_SIGNIN_RESUME="$([ "$resume" = yes ] && echo 1 || echo 0)" \
    tracked xcodebuild test -project Topo.xcodeproj -scheme TopoSimulatorSignIn -configuration Debug \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
      -only-testing:TopoSimulatorSignInTests/SimulatorSignInTests \
      -collect-test-diagnostics never -resultBundlePath "$results" || status=$?
  scripts/ci-require-tests.sh named "$results" TopoSimulatorSignInTests/SimulatorSignInTests || status=1
  if [ "$status" = 0 ] && grep -q '^\[sign-in\] already signed in' "$runlog"; then
    echo "==> $udid was signed in already and Settings asks for no password. If --send reports 'account temporarily unavailable', its sign-in has ended (a restart of the simulator ends it, and so does a change of the account's password), and no prompt will come for it: DEVICE=$udid scripts/simulator-run.sh --sign-in --renew signs the account out and in again, typing the password once. If --send reports another lapse, the test does not know the screen it shows"
  elif [ "$status" = 0 ]; then
    echo "==> $udid is signed in; DEVICE=$udid scripts/simulator-run.sh --send hello proves CloudKit answers"
  else
    echo "==> the sign-in stopped; the '[sign-in] stopped:' line above and $results say where. Type no password by hand before reading why: a refused one tried again locks the account" >&2
  fi
  exit "$status"
fi

if [ "$talk" = yes ]; then
  read_token
  models="${EAR_MODELS:-$root/build/ear-models}"
  voice_models="${VOICE_MODELS:-$root/build/phonon}"
  scripts/fetch-ear-models.sh "$models"
  scripts/phonon-bundles.sh "$voice_models"
  # A start that refuses (exit 3) found another run's lane, which is not this run's to stop.
  # The lane is this run's (AUDIO_LANE_OWNER), so a later start finds it abandoned once this
  # run has ended without stopping it, a SIGKILL's, and stops it.
  lane=ours
  AUDIO_LANE_OWNER=$$ scripts/ci-audio-lane.sh start "$root/Tests/Fixtures/capital-of-france.wav" || {
    status=$?
    [ "$status" = 3 ] && lane=theirs
    exit "$status"
  }
  # A simulator's audio is served by a host process bound to the coreaudiod it booted against,
  # so one booted before the lane installed BlackHole (which restarts coreaudiod) has no input,
  # and booting it again binds it to the loopback. A reboot also ends the device's iCloud
  # sign-in (docs/simulator.md, *A lapse*), so a device booted since coreaudiod started, which
  # already hears the lane, is not rebooted.
  booted="$(process_start "$(pgrep -f "/Devices/$udid/data/var/run/launchd_bootstrap.plist" | head -1)")"
  audio="$(process_start "$(pgrep -x coreaudiod | head -1)")"
  if [ -n "$booted" ] && [ -n "$audio" ] && [ "$booted" -gt "$audio" ]; then
    echo "==> the simulator booted after coreaudiod started, so it hears the lane without a reboot"
  elif [ -z "$booted" ]; then
    echo "==> booting the simulator onto the lane's audio devices"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
  else
    echo "==> rebooting the simulator onto the lane's audio devices, since it booted before coreaudiod started; the reboot ends its iCloud sign-in, so the turn's iCloud half will be refused until: DEVICE=$udid scripts/simulator-run.sh --sign-in --renew"
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null
  fi
  # The result bundle's session log records the test runner's environment whole, and the
  # environment the runner launches the app with, so the token is in neither: it is served once
  # on the loopback, and the runner hands the app only the port and the nonce, from which the
  # app reads it itself at launch (DebugRun.servedToken). The script's own CLAUDE_SETUP_TOKEN
  # is taken out of xcodebuild's environment, whose build description keeps it otherwise. The
  # test is built before the listener starts, so a slow build does not use up its 30 minutes.
  # The test collects no diagnostics: they are the simulator's log archive, and that log records
  # the environment of every process the simulator launched, a token-carrying launch's included.
  echo "==> building the talk test (TopoTalkTests)"
  tracked env -u CLAUDE_SETUP_TOKEN xcodebuild build-for-testing -project Topo.xcodeproj -scheme TopoTalk \
    -configuration Debug -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived"
  nonce="$(uuidgen)"
  serve_once "$nonce" token
  unset token
  results="$derived/TopoTalk.xcresult"
  rm -rf "$results"
  echo "==> speaking a question into the microphone (TopoTalkTests)"
  status=0
  TEST_RUNNER_TOPO_DEBUG_TOKEN_PORT="$served_port" TEST_RUNNER_TOPO_DEBUG_TOKEN_NONCE="$nonce" \
  TEST_RUNNER_TOPO_UITEST_EAR_MODELS="$models" \
  TEST_RUNNER_TOPO_UITEST_VOICE_MODELS="$voice_models/phonon-40m-en" \
    tracked env -u CLAUDE_SETUP_TOKEN xcodebuild test-without-building -project Topo.xcodeproj -scheme TopoTalk \
      -configuration Debug -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
      -collect-test-diagnostics never -resultBundlePath "$results" || status=$?
  scripts/ci-audio-lane.sh check after || status=1
  # A test that passed on some other login proves nothing of the token: the listener has to have
  # served it.
  # A listener that has just answered may still be on its way out. Whether it is still running
  # is asked of the shell's own jobs, not of the pid, which the system may have given another
  # process once the shell reaped it; the shell keeps a reaped child's status for `wait`.
  served=1
  for _ in $(seq 10); do running_child "$served_by" || break; sleep 0.2; done
  if ! running_child "$served_by"; then wait "$served_by" && served=0 || true; fi
  [ "$served" = 0 ] || { echo "==> the app never read the served token" >&2; status=1; }
  scripts/ci-require-tests.sh xcresult "$results" TopoTalkTests || status=1
  [ "$status" = 0 ] && echo "==> the spoken question was heard, answered and read aloud" \
    || echo "==> the spoken turn failed; $results says where" >&2
  exit "$status"
fi

if [ "$build" = yes ]; then
  echo "==> building"
  tracked xcodebuild -project Topo.xcodeproj -scheme Topo -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
    build
fi

app="$derived/Build/Products/Debug-iphonesimulator/Topo.app"
[ -d "$app" ] || { echo "no app at $app; build first" >&2; exit 1; }

if [ "$pressmic" = yes ]; then
  # The XCUITest that taps, holds and releases the microphone (Tests/ClientUI), on this device.
  # It launches the app signed in with a placeholder token; the launch below carries the real
  # one. docs/simulator.md says what the press reaches and what it cannot.
  echo "==> pressing the microphone"
  # The test counts the permission prompts the run raises, so the app's grants go first, and the
  # flag says the reset happened: the count is exact only on a simulator that has answered nothing.
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl privacy "$udid" reset all "$bundle"
  TEST_RUNNER_TOPO_UITEST_PRIVACY_RESET=1 \
    tracked xcodebuild test -project Topo.xcodeproj -scheme Topo -configuration Debug \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
      -only-testing:TopoUITests
fi

# A guest command alone needs no sign-in; anything else launches signed in.
token=""
if [ -z "$userland" ] || [ -n "$send" ]; then
  read_token
fi

xcrun simctl bootstatus "$udid" -b >/dev/null
if [ "$fresh" = yes ]; then
  xcrun simctl uninstall "$udid" "$bundle" 2>/dev/null || true
fi
xcrun simctl install "$udid" "$app"

log="$(mktemp -t topo-sim)"
launcher=""
# The launcher stays attached to the app's console only when there is a closing line to wait for.
# An attached launcher never exits, since the app never does, so a run with nothing to wait for
# launches detached: simctl returns once the app is up, and the run ends there.
attach=""
if [ -n "$send" ] || [ -n "$userland" ] || [ -n "$guestturn" ]; then
  attach=--console-pty
fi
# This run's id: the app prints it on the reply to the turn it sent, so neither a line from an
# earlier launch nor a reply to some other turn can stand in for this run's answer.
run="$(uuidgen)"
echo "==> launching (run $run)"
SIMCTL_CHILD_TOPO_CLAUDE_SETUP_TOKEN="$token" \
SIMCTL_CHILD_TOPO_DEBUG_SEND="$send" \
SIMCTL_CHILD_TOPO_DEBUG_USERLAND="$userland" \
SIMCTL_CHILD_TOPO_DEBUG_GUEST_TURN="$guestturn" \
SIMCTL_CHILD_TOPO_DEBUG_RUN="$run" \
  xcrun simctl launch $attach --terminate-running-process "$udid" "$bundle" >"$log" 2>&1 &
launcher=$!
echo "$launcher" >>"$pids"
started_pids="$started_pids $launcher"

fail() {
  grep '\[topo-debug\]' "$log" || cat "$log"
  echo "==> $*" >&2
  exit 1
}

# Waits for the app to print `marker`: one prefixed line per step and a closing line when the
# work has settled, rather than for the app to exit, which it never does. A launcher that exits
# first is a launch or an app that died, and fails the run there rather than at the timeout.
# TIMEOUT is one budget for every wait on the app's lines after the launch; the build, the boot
# and the install before it are not under it.
waited=0
wait_for() {
  local marker="$1" what="$2"
  until grep -q "\[topo-debug\] $marker" "$log" 2>/dev/null; do
    if ! kill -0 "$launcher" 2>/dev/null; then
      wait "$launcher" && status=0 || status=$?; launcher=""
      grep -q "\[topo-debug\] $marker" "$log" || fail "the launcher exited ($status) before $what finished"
      break
    fi
    [ "$waited" -lt "$timeout" ] || fail "$what did not finish within ${timeout}s"
    sleep 1
    waited=$((waited + 1))
  done
}

if [ -n "$send" ]; then
  # The app asks CloudKit before the turn (DebugRun.iCloud) and says what it found in one line;
  # anything but an answer is a device whose iCloud sign-in is missing or has lapsed, which the
  # turn would only wait on at "Reaching iCloud…".
  wait_for "icloud: " "the iCloud check"
  icloud="$(grep -o '\[topo-debug\] icloud: .*' "$log" | head -1 | tr -d '\r')"
  icloud="${icloud#\[topo-debug\] icloud: }"
  case "$icloud" in
    answered) ;;
    "no account") fail "the simulator $udid has no iCloud account; sign it in with: DEVICE=$udid scripts/simulator-run.sh --sign-in" ;;
    # Signed in to Settings with CloudKit refusing and nothing asking: a sign-in the device's last
    # restart ended, which only signing out and in again mends (docs/simulator.md, *A lapse*).
    "account temporarily unavailable") fail "the simulator $udid is signed in to Settings but CloudKit refuses its account (account temporarily unavailable): its sign-in has ended (a restart of the simulator ends it, and so does a change of the account's password), and no prompt will come for it. Sign it out and in again with: DEVICE=$udid scripts/simulator-run.sh --sign-in --renew" ;;
    *) fail "the simulator $udid's iCloud account did not answer CloudKit ($icloud), which is how a lapsed sign-in shows (a network fault shows so too); sign it in again with: DEVICE=$udid scripts/simulator-run.sh --sign-in" ;;
  esac
  wait_for done "the turn"
fi
[ -z "$userland" ] || wait_for "userland done" "the guest command"
[ -z "$guestturn" ] || wait_for "guest turn done" "the guest's turns"
if [ -n "$send" ] || [ -n "$userland" ] || [ -n "$guestturn" ]; then
  # The closing lines are printed; a launcher already gone by now has to have gone cleanly.
  if [ -n "$launcher" ] && ! kill -0 "$launcher" 2>/dev/null; then
    wait "$launcher" && status=0 || status=$?; launcher=""
  fi
  [ "${status:-0}" = 0 ] || fail "the launcher exited ($status) after the work finished"
fi

if [ -n "$screenshot" ]; then
  xcrun simctl io "$udid" screenshot "$screenshot"
  echo "==> $screenshot"
fi

if [ -n "$send" ]; then
  grep -q '\[topo-debug\] error:' "$log" && fail "the turn reported an error"
  grep -Eq "\[topo-debug\] reply to [^ ]+ in run $run from " "$log" \
    || fail "no reply to the turn this run sent (run $run)"
  grep -Eq "\[topo-debug\] reply to [^ ]+ in run $run from session [^ ,]+, process [0-9]+: " "$log" \
    && ! grep -Eq "\[topo-debug\] reply to [^ ]+ in run $run from session none," "$log" \
    || fail "the reply to this run's turn was not written by a resident guest session"
  # The mascot's lines name the turns the guest turn answered: this run's turn has to be among
  # them, on the line it began with and the line it went with. Words given ahead of their save
  # answer a turn no ref names yet, so those lines name it `heard:` the nonce this run sent under.
  turn="$(grep -Eo "\[topo-debug\] reply to [^ ]+ in run $run from " "$log" | head -1 | awk '{print $4}')"
  nonce="$(grep -Eo "\[topo-debug\] sending under [^ ]+ in run $run: " "$log" | head -1 | awk '{print $4}' || true)"
  pattern="$(printf '%s' "$turn" | sed 's/[][\.*^$+?(){}|/]/\\&/g')"
  if [ -n "$nonce" ]; then
    pattern="($pattern|heard:$(printf '%s' "$nonce" | sed 's/[][\.*^$+?(){}|/]/\\&/g'))"
  fi
  grep -Eq "\[topo-debug\] mascot: turn began for ([^ ,]+\+)?$pattern(\+[^ ,]+)?, process " "$log" \
    && grep -Eq "\[topo-debug\] mascot: turn gone for ([^ ,]+\+)?$pattern(\+[^ ,]+)?, " "$log" \
    || fail "Topo on the glass did not follow the guest's turn for $turn"
  # A phone that had no iCloud account when Topo was first opened keeps its records on the phone
  # for good (docs/cloudkit.md), so a turn there never reached CloudKit, account or not.
  grep -Fq '[topo-debug] records: iCloud' "$log" \
    || fail "the turn's records are not iCloud's ($(grep -o '\[topo-debug\] records: .*' "$log" | head -1)): this install decided on the phone; --fresh starts it again"
  echo "==> the message landed in iCloud and was answered by the guest"
fi

if [ -n "$userland" ]; then
  # Each line from its first marker on: another process's stderr written without a trailing
  # newline (CoreML's E5RT does this) lands in front of the next marker, and the checks below
  # match from the start of a line.
  lines="$(grep -o '\[topo-debug\].*' "$log" | tr -d '\r')"
  grep -q '\[topo-debug\] userland error:' <<< "$lines" && fail "the guest reported an error"
  grep -Eq '^\[topo-debug\] userland: claude code [^ ]+ verified in [0-9]+ ms, mounted at /usr/local/bin/claude$' <<< "$lines" \
    || fail "Claude Code was not verified and mounted"
  grep -Fxq '[topo-debug] guest exit: 0' <<< "$lines" || fail "the guest command did not exit 0"
  if [ -n "$expect" ]; then
    grep -Fxq "[topo-debug] guest: $expect" <<< "$lines" || fail "the guest did not print '$expect'"
  fi
  case "$expect_rootfs" in
    fetched) grep -Fxq '[topo-debug] userland: rootfs fetched and imported' <<< "$lines" \
               || fail "this launch did not fetch and import the rootfs" ;;
    reused) grep -Fxq '[topo-debug] userland: rootfs reused: nothing fetched, nothing imported' <<< "$lines" \
              || fail "this launch did not reuse the fakefs" ;;
  esac
  case "$expect_claude" in
    fetched) grep -Eq '^\[topo-debug\] userland: claude code [^ ]+ fetched$' <<< "$lines" \
               || fail "this launch did not fetch Claude Code" ;;
    reused) grep -Eq '^\[topo-debug\] userland: claude code [^ ]+ reused: nothing fetched, nothing copied$' <<< "$lines" \
              || fail "this launch did not reuse Claude Code" ;;
  esac
  echo "==> the guest booted and ran the command"
fi

if [ -n "$guestturn" ]; then
  lines="$(grep -o '\[topo-debug\].*' "$log" | tr -d '\r')"  # from the first marker, as for --userland
  grep -q '\[topo-debug\] guest turn error:' <<< "$lines" && fail "the guest's turns reported an error"
  grep -Eq '^\[topo-debug\] guest turn [0-9]+ (failed|abandoned)' <<< "$lines" && fail "a guest turn failed or was abandoned"
  count="$(awk -F ' \\|\\| ' '{ n = 0; for (i = 1; i <= NF; i++) if ($i ~ /[^ ]/) n++; print n }' <<< "$guestturn")"
  resident=""
  for n in $(seq 1 "$count"); do
    started="$(grep -E "^\[topo-debug\] guest turn $n model: claude-haiku-5-5[^ ]*, session [^ ]+, process [0-9]+$" <<< "$lines" | head -1 || true)"
    [ -n "$started" ] || fail "guest turn $n did not start on Haiku in a named session and process"
    grep -Eq "^\[topo-debug\] guest turn $n answered in [0-9.]+ s: " <<< "$lines" \
      || fail "guest turn $n was not answered"
    # Every turn of a run goes to one resident process in one session: a turn answered by a
    # process started after the first is a restart the run did not ask for.
    this="${started#*, session }"
    [ -z "$resident" ] || [ "$this" = "$resident" ] \
      || fail "guest turn $n went to session and process ${this/, process / in process }, not ${resident/, process / in process }"
    resident="$this"
  done
  if [ -n "$expect_bash" ]; then
    ran=""
    for n in $(seq 1 "$count"); do
      # Every line is matched from its start: the call as a whole line, and the result and the
      # reply by their fixed prefixes (`sed -n 's/^…//p'` keeps only the lines that begin with
      # one, and only the text after it), so a prefix echoed inside another line — the turn's own
      # `sent:` line, a reply quoting one — never counts. The status is read from the prefix and
      # OUTPUT from the text after it alone, so no word of a prefix stands in for it.
      grep -Fxq "[topo-debug] guest turn $n tool: Bash" <<< "$lines" || continue
      sed -n "s/^\[topo-debug\] guest turn $n tool result: Bash: ok: //p" <<< "$lines" \
        | grep -Fq -- "$expect_bash" || continue
      sed -En "s/^\[topo-debug\] guest turn $n answered in [0-9.]+ s: //p" <<< "$lines" \
        | grep -Fq -- "$expect_bash" || continue
      ran="$n"
      break
    done
    [ -n "$ran" ] || fail "no guest turn ran Bash and got back '$expect_bash' from it, in its tool result and its reply"
    echo "==> guest turn $ran ran Bash in the guest and got back '$expect_bash'"
  fi
  echo "==> the resident Claude Code answered $count turns in one process (session ${resident})"
fi

if [ -n "$send" ] || [ -n "$userland" ] || [ -n "$guestturn" ]; then
  grep '\[topo-debug\]' "$log"
else
  wait "$launcher" && status=0 || status=$?; launcher=""
  [ "$status" = 0 ] || fail "the launcher exited ($status)"
  echo "==> launched signed in"
fi
