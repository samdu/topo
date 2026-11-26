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
#   scripts/simulator-run.sh --send "hi || again"   # ... two turns, one after the other, in one launch
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
# vault with `op-item`. It is served once on the host's loopback, which a simulator shares, to
# the request carrying the launch's nonce, and the app is launched with only the port and the
# nonce (SIMCTL_CHILD_TOPO_DEBUG_TOKEN_PORT and _NONCE), from which it reads the token itself at
# launch (DebugRun.servedToken): the simulator's own log records each launch's environment, so
# the token is not in it. A signed-in run fails unless the listener served the token. The app
# hands it to every `claude` it starts in the guest for that launch and keeps nothing of it.
# Every xcodebuild runs with the exported variables whose names say they hold a secret taken out
# of its environment (scripts/secret-env.sh), since xcodebuild writes its own environment into
# the build description under build/sim's XCBuildData; and every test it runs collects no
# diagnostics, which are the simulator's log archive.
#
# --sign-in runs the TopoSimulatorSignIn scheme's sign-in test (Tests/SimulatorSignIn), which signs
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
# ends it without a restart, with an Apple Account Verification alert. --renew signs the account out in
# Settings and in again, typing the password once. A --send whose iCloud check answers "account
# temporarily unavailable" renews it itself, once a run, as do a --talk, a --guest-turn and a launch
# to drive by hand on a device the run booted, when a sign-in has passed on it since its last --erase
# (<udid>.signed-in); each renewal is logged with why in ~/Library/Caches/topo-sim/renewals.log.
# A sign-in that stopped is recorded there (<udid>.sign-in-stopped): no run renews that device until
# a --sign-in passes, nor shuts it down within the half hour its code screen may stand, since a refused password typed again is how an
# account is locked.
#
# A booted simulator holds gigabytes of the Mac's memory, so a run that used the device shuts it
# down as it ends, passed or failed, signal included, unless something else is using it (another
# simulator-run.sh, or an xcodebuild or simctl naming the udid) or the run leaves it up on
# purpose: a launch with nothing to wait for (to drive by hand), a --sign-in, and a sign-in that
# stopped in the last half hour (its code screen stays up for SIGNIN_CODE). The janitor shuts what is left once it has
# stood idle (docs/janitor.md). Every boot, the check before a shutdown and --talk's reboot are made under one lock in
# ~/Library/Caches/topo-sim (TOPO_SIM_STATE), with the device's last use beside it.
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
# ClaudeModel.pinned in Packages/TopoTurn/Sources/TopoTurn/ClaudeModel.swift, and the managed policy a
# debug build writes into the guest (Apps/Topo/GuestPolicy.swift).
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
# each xcodebuild, token listener and launcher; it is removed when the run ends. Ending a run is
# `kill $(head -1 build/sim/simulator-run.pids)`: the script ends what that file names and
# nothing else, so a sibling worktree's xcodebuild is never touched.
#
# On buddybox xcodebuild needs the login keychain, so run this from the GUI session:
#   ssh buddybox 'sudo launchctl asuser $(id -u) sudo -u buddy bash -lc "cd ~/github/topo && scripts/simulator-run.sh --send hello"'
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
source "$root/scripts/secret-env.sh"

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
    -h|--help) sed -n '2,136p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
[ "$resume" = no ] || [ -z "${SIGNIN_CODE:-}" ] || { echo "--resume types nothing, so it takes no SIGNIN_CODE" >&2; exit 2; }
[ "$leakcheck" = no ] || [ "$signin" = no ] || { echo "--leak-check signs nothing in: run it alone, on a simulator signed into nothing that matters" >&2; exit 2; }

# The device is shared by every worktree's runs, and a booted simulator holds gigabytes of
# buddybox's memory, so a run that used it shuts it down as it ends (`release_device`, from
# `cleanup`) unless another run is using it or this run's purpose is to leave it up. What says a
# run is using it is the process list, read and never signalled: a simulator-run.sh other than
# this one and its children (on any device, since DEVICE is not in its arguments), or an
# xcodebuild or simctl naming the udid. A boot and the check-then-shutdown are made under one
# lock (`$simstate/mutex`), so a run that starts while another is ending finds the device either
# up or shut, never mid-shutdown. `$simstate/<udid>.last-use` is when a run last used the device,
# which the janitor reads before shutting one that has stood idle (docs/janitor.md).
simstate="${TOPO_SIM_STATE:-$HOME/Library/Caches/topo-sim}"
mkdir -p "$simstate"
touched=no
booted_here=no
leave=""
stopped="$simstate/$udid.sign-in-stopped"
# A sign-in of the account passed on this device since its last --erase: the evidence a boot of it
# has a sign-in to renew, rather than a device a renewal would sign in for the first time.
signedin="$simstate/$udid.signed-in"

used_now() { touch "$simstate/$udid.last-use" 2>/dev/null || true; }

# A record as it stands: its time and its words. A stop put back whole (the rename from .prior)
# is the record it was.
record_id() { { stat -f '%Fm' "$1" && cat "$1"; } 2>/dev/null || echo none; }
signed_seen=""

# Whether a sign-in stopped on the device within the last half hour, in which time its code screen
# may still be up for SIGNIN_CODE; an older stop still refuses a renewal, and keeps nothing up.
stop_fresh() {
  [ -e "$stopped" ] && [ $(( $(date +%s) - $(stat -f %m "$stopped" 2>/dev/null || echo 0) )) -lt 1800 ]
}

# The processes, other than this run and its children, using the device; one line each. A run
# is the script as the program, or as the first operand of a shell or env after its options; an
# xcodebuild or simctl uses the device when one of its arguments, or a comma-separated field of
# one (a destination's `id=<udid>`), names it. A process list that cannot be read fails, so a
# caller leaves the device as it is rather than taking the silence for nobody.
others_using() {
  local listed
  listed="$(ps -axwwo pid=,ppid=,command=)" && [ -n "$listed" ] || return 1
  printf '%s\n' "$listed" | awk -v me="$$" -v u="$udid" '
    function base(x,   n, a) { n = split(x, a, "/"); return a[n] }
    { pid[NR] = $1; ppid[NR] = $2; line[NR] = $0 }
    END {
      mine[me] = 1
      do { grew = 0; for (i = 1; i <= NR; i++) if (!(pid[i] in mine) && (ppid[i] in mine)) { mine[pid[i]] = 1; grew = 1 } } while (grew)
      for (i = 1; i <= NR; i++) {
        if (pid[i] in mine) continue
        nf = split(line[i], f, " ")
        prog = base(f[3]); using = (prog == "simulator-run.sh")
        if (!using && (prog ~ /^(ba|z|da)?sh$/ || prog == "env")) {
          for (j = 4; j <= nf; j++) {
            if (f[j] == "--") { j++; using = (j <= nf && base(f[j]) == "simulator-run.sh"); break }
            if (prog == "env") {
              if (f[j] ~ /^-[A-Za-z]*[uPSC]$/) { j++; continue }
              if (f[j] ~ /^-/ || f[j] ~ /=/) continue
              if (base(f[j]) ~ /^(ba|z|da)?sh$/) { prog = base(f[j]); continue }
            } else {
              if (f[j] ~ /^-[A-Za-z]*c[A-Za-z]*$/) break
              if (f[j] == "--rcfile" || f[j] == "--init-file" || f[j] ~ /^[-+][A-Za-z]*[oO]$/) { j++; continue }
              if (f[j] ~ /^[-+]/) continue
            }
            using = (base(f[j]) == "simulator-run.sh"); break
          }
        }
        if (!using && (prog == "xcodebuild" || prog == "xcrun" || prog == "simctl"))
          for (j = 4; j <= nf && !using; j++) {
            n = split(f[j], part, ",")
            for (k = 1; k <= n; k++) if (part[k] == u || part[k] == "id=" u) { using = 1; break }
          }
        if (using) print substr(line[i], 1, 160)
      }
    }'
}

# What is using the device, or why that cannot be told; empty when nothing is.
users_now() {
  others_using || echo "the process list could not be read"
}

# Boots the device, under the lock, and waits for it.
boot_device() {
  touched=yes
  used_now
  { lockf -s -t "${TOPO_SIM_LOCK_WAIT:-120}" 7 || { echo "==> another run has held $simstate/mutex for ${TOPO_SIM_LOCK_WAIT:-120} s" >&2; return 1; }
    ! xcrun simctl boot "$udid" 6>&- 7>&- 2>/dev/null || booted_here=yes
  } 7>"$simstate/mutex"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  # The first boot is when this run learned the sign-in ended; a later one learns nothing new.
  [ -n "$signed_seen" ] || signed_seen="$(record_id "$signedin")"
}

# Shuts the device down as the run ends, unless the run leaves it up on purpose or another run
# is using it. Bounded, and never failing the run: a device left up is the janitor's.
release_device() {
  [ "$touched" = yes ] || return 0
  used_now
  [ -n "$leave" ] || ! stop_fresh || leave="a sign-in on it stopped within the half hour, and its code screen may stand"
  if [ -n "$leave" ]; then
    echo "==> $udid is left booted: $leave. The janitor shuts it down once it has stood idle"
    return 0
  fi
  local users
  { if ! lockf -s -t 60 7; then
      echo "==> $udid is left booted: another run has held $simstate/mutex for a minute"
    else
      users="$(users_now)"
      if stop_fresh; then
        echo "==> $udid is left booted: a sign-in on it stopped within the half hour, and its code screen may stand"
      elif [ -n "$users" ]; then
        echo "==> $udid is left booted for the runs using it:"
        printf '%s\n' "$users" | sed 's/^/      /'
      elif timeout 120 xcrun simctl shutdown "$udid" 7>&- >/dev/null 2>&1; then
        echo "==> $udid is shut down; its iCloud sign-in ends with it, and the next --send renews it"
      else
        echo "==> $udid would not shut down; the janitor tries again once it has stood idle"
      fi
    fi
  } 7>"$simstate/mutex"
}

if [ "$erase" = yes ]; then
  echo "==> $device ($udid)"
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl erase "$udid"
  rm -f "$signedin" "$stopped" "$stopped.prior" "$stopped.new"
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
served_by=""
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
  # A signal inside a brace group holding the mutex on 7 leaves it open here; release takes the
  # mutex afresh, and would otherwise wait on this run's own hold.
  exec 7>&-
  release_device || true
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
# Descriptor 6 is the sign-in lock (take_sign_in), closed here and in serve_once's listener,
# since a redirect on the function's call does not reach what the function starts in the background.
# With tracked_out set, what the command prints goes to that file alone, for its caller to read
# and pass on once it has ended.
tracked() {
  if [ -n "${tracked_out:-}" ]; then "$@" 6>&- >"$tracked_out" 2>&1 & else "$@" 6>&- & fi
  local pid=$! status=0
  echo "$pid" >>"$pids"
  started_pids="$started_pids $pid"
  wait "$pid" || status=$?
  return "$status"
}

# Serves one secret once on the host's loopback, which a simulator shares: a listener that answers
# the first request carrying the nonce with the secret and exits, hands nothing to a request
# without it, and gives up unasked after <seconds> (30 minutes by default). The secret leaves its variable once, on a
# pipe to the listener, never as an argument or a file. The listener is a recorded child, so
# `cleanup` ends one nobody asked. Sets served_port, and served_by to the listener's pid, whose
# exit status is 0 once it has served the secret.
# serve_once <nonce> <name of the variable holding the secret> [<seconds>]
serve_once() {
  local nonce="$1" portfile="$derived/served.$$.port" seconds="${3:-1800}" listener
  rm -f "$portfile"
  /usr/bin/python3 -c '
import socket, sys, time
nonce, portfile, seconds, secret = sys.argv[1].encode(), sys.argv[2], int(sys.argv[3]), sys.stdin.buffer.read()
server = socket.socket()
server.bind(("127.0.0.1", 0))
server.listen(4)
open(portfile, "w").write(str(server.getsockname()[1]))
deadline = time.monotonic() + seconds
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
sys.exit(1)' "$nonce" "$portfile" "$seconds" < <(printf '%s' "${!2}") 6>&- &
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
# ps writes and date reads it in C and UTC whatever the caller's locale and zone, as
# scripts/validate-and-push.sh's began_of does, and through env rather than an assignment of the
# shell's own, for the reason given there.
process_start() {
  [ -n "$1" ] || return 0
  local started
  started="$(env LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')" || return 0
  [ -n "$started" ] || return 0
  env LC_ALL=C TZ=UTC date -j -f '%a %b %d %T %Y' "$started" +%s 2>/dev/null || true
}

# Exits non-zero, which a caller takes as nothing proven, when the secret cannot be read or is
# shorter than a run.
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
secret = os.fdopen(3, "rb").read().decode("utf-8")
if len(secret) < 8:
    sys.exit("the secret is shorter than the 8 characters a run is counted in")
# Runs of characters, not bytes, so a character past ASCII is never split across two.
chars = {secret[i:i + 8] for i in range(len(secret) - 7)}
runs = {r.encode("utf-8") for r in chars} | {r.encode("utf-16-le") for r in chars}
def blobs(path):
    videos[path] = 0
    if path == "-":
        data = sys.stdin.buffer.read()
        if not data:
            unread.add(path)
        yield data; return
    files = [path] if os.path.isfile(path) else [os.path.join(d, f) for d, _, fs in os.walk(path, onerror=lambda e: unread.add(path)) for f in fs]
    for f in files:
        try:
            data = open(f, "rb").read()
        except OSError:
            unread.add(path)
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
                unread.add(path)
for path in paths:
    found = path == "-" or os.path.exists(path)
    n = sum(blob.count(r) for blob in blobs(path) for r in runs) if found else "absent"
    if path in unread:
        n = "unreadable"
    elif videos.get(path):
        n = f"{n} and {videos[path]} screen recording(s)"
    print(f"{label} {path}: {n}")' "$@"
}

# True once tee has written the run's log up to a mark printed now, so nothing printed before it
# is still on its way to the file: a log is counted only after this, and a mark not seen within
# ten seconds is a log not read.
# log_drained <what the mark says>
log_drained() {
  local mark
  mark="==> $1 ($(uuidgen))"
  echo "$mark"
  for _ in $(seq 50); do grep -qxF "$mark" "$runlog" && return 0; sleep 0.2; done
  return 1
}

# Counts the dummy in what a command prints, read on a pipe and never kept. A command that fails
# or runs out its time, or prints nothing, is a log not read, which says "unreadable", not 0.
# count_log <label> <name> <command…>
count_log() {
  local label="$1" name="$2" out
  shift 2
  if out="$("$@" 2>/dev/null | count_runs "$label" - 3< <(printf '%s' "$dummy"))"; then
    printf '%s\n' "$out" | sed "s/ -:/ $name:/"
  else
    echo "$label $name: unreadable"
  fi
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
  boot_device
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
      tracked "${scrubbed[@]}" xcodebuild test -project Topo.xcodeproj -scheme TopoSimulatorSignIn -configuration Debug \
        -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
        -only-testing:TopoSimulatorSignInTests/LeakCheckTests \
        -collect-test-diagnostics never -resultBundlePath "$results" && ran=0 || ran=$?
    # Everything below reads the run's log, so it waits for tee to have written all of it.
    drained=yes
    log_drained "reading the $route run's log" || drained=no
    # Each run says it typed its own dummy whole, by the page's hash, before anything else fails.
    [ "$(grep -cx "\[leak-check\] $route typed the dummy whole" "$runlog")" = 1 ] \
      || { echo "==> the $route run did not type its dummy whole" >&2; status=1; }
    if [ "$route" = failing ]; then
      [ "$ran" != 0 ] && grep -q 'failing after the dummy' "$runlog" \
        || { echo "==> the failing run did not fail after typing the dummy" >&2; status=1; }
    else
      [ "$ran" = 0 ] || status=1
      scripts/ci-require-tests.sh named "$results" TopoSimulatorSignInTests/LeakCheckTests || status=1
    fi
    # The logs are read on a pipe and counted, never kept: a device's log can hold what other
    # runs launched with.
    [ "$drained" = yes ] || echo "$route $runlog: unreadable" >>"$counts"
    {
      count_runs "$route" "$runlog" "$results" "$derived/Logs/Test" 3< <(printf '%s' "$dummy") || echo "$route count: unreadable"
      count_log "$route" "device log" timeout 300 xcrun simctl spawn "$udid" log show --start "$since" --style compact --info --debug
      count_log "$route" "Mac log" timeout 300 log show --start "$since" --style compact --info --debug \
        --predicate 'process == "xcodebuild" OR process == "testmanagerd" OR process BEGINSWITH "XC" OR process == "CoreSimulatorService"'
    } | tee -a "$counts"
    unset dummy
  done
  # The control's bundle holds its dummy, which is worth nothing, but is not kept either.
  # A folder the count could not read is one rm cannot empty either, until it may be read.
  chmod -R u+rwX "$derived"/TopoLeakCheck-*.xcresult 2>/dev/null || true
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

# Whether the listener served the token within <seconds>. Whether it is still running is asked
# of the shell's own jobs, not of the pid, which the system may have given another process once
# the shell reaped it; the shell keeps a reaped child's status for `wait`.
token_served() {
  local deadline=$((SECONDS + $1))
  while running_child "$served_by" && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.2; done
  ! running_child "$served_by" && wait "$served_by"
}

if [ "$build" = yes ]; then
  scripts/build-ish.sh
  scripts/fetch-phonon.sh
fi

# Signs the device into the account through Settings (TopoSimulatorSignIn), a first sign-in or,
# with renew=yes, out and in again. Returns the run's status; a stop is recorded in $stopped,
# which a later automatic renewal reads and does not try past, and a pass clears it.
sign_in() {
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
    password="$(op-item get 'Buddy Apple ID' password 6>&-)" || password=""
    [ -n "$password" ] || { echo "no password from the vault item 'Buddy Apple ID'" >&2; exit 1; }
    nonce="$(uuidgen)"
    serve_once "$nonce" password
    port="$served_port"
  fi
  results="$derived/TopoSimulatorSignIn.xcresult"
  signout="$derived/TopoSimulatorSignIn.out"
  : >"$signout"
  # Recorded before Settings is driven, so a run that ends mid-sign-in, by a signal included,
  # leaves a stop behind: an attempt nobody saw finish is one that may have been refused.
  # A stop standing is kept aside, with its time, for a sign-in that types nothing to put back.
  # The new record replaces it whole (a rename), so the stop never goes missing meanwhile.
  rm -f "$stopped.prior" "$stopped.new"
  [ ! -e "$stopped" ] || ln "$stopped" "$stopped.prior"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) in $root: begun and not seen to finish; see $results" >"$stopped.new"
  mv -f "$stopped.new" "$stopped"
  rm -rf "$results"
  # A boot that could not be made under the lock is no device to type a password into.
  # Nothing has been typed, so the records go back as they were.
  if ! boot_device; then
    if [ -e "$stopped.prior" ]; then mv -f "$stopped.prior" "$stopped"; else rm -f "$stopped"; fi
    echo "==> the device could not be booted for the sign-in, so nothing was typed" >&2
    return 1
  fi
  echo "==> signing $udid into $account through Settings (TopoSimulatorSignInTests)"
  status=0
  TEST_RUNNER_TOPO_SIGNIN_ACCOUNT="$account" TEST_RUNNER_TOPO_SIGNIN_PORT="$port" \
  TEST_RUNNER_TOPO_SIGNIN_NONCE="$nonce" TEST_RUNNER_TOPO_SIGNIN_CODE="${SIGNIN_CODE:-}" \
  TEST_RUNNER_TOPO_SIGNIN_RENEW="$([ "$renew" = yes ] && echo 1 || echo 0)" \
  TEST_RUNNER_TOPO_SIGNIN_RESUME="$([ "$resume" = yes ] && echo 1 || echo 0)" \
    tracked_out="$signout" tracked "${scrubbed[@]}" xcodebuild test -project Topo.xcodeproj -scheme TopoSimulatorSignIn -configuration Debug \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
      -only-testing:TopoSimulatorSignInTests/SimulatorSignInTests \
      -collect-test-diagnostics never -resultBundlePath "$results" || status=$?
  # The test's own words, kept apart from the run's log, which another run in this worktree
  # starts afresh: what the sign-in found is read from these.
  cat "$signout"
  scripts/ci-require-tests.sh named "$results" TopoSimulatorSignInTests/SimulatorSignInTests || status=1
  # What the run left is counted for the password itself, as --leak-check counts a dummy: any run
  # of 8 of its characters in the run's log or the bundle fails the run and says where, never what.
  if [ "$resume" = no ]; then
    counted="" leaked=""
    if log_drained "counting the password in what this run left" \
      && counted="$(count_runs password "$runlog" "$signout" "$results" 3< <(printf '%s' "$password"))"; then
      leaked="$(printf '%s\n' "$counted" | grep -Ev ': (0|absent)$' || true)"
    else
      leaked="the count could not be made${counted:+: $counted}"
    fi
    unset password
    if [ -n "$leaked" ]; then
      echo "==> the password is in what this run left, by count: $leaked. Delete those files before anything else" >&2
      status=1
    else
      if [ -d "$results" ]; then
        echo "==> the password is in nothing this run left: no 8 of its characters in the run's log or the bundle"
      else
        echo "==> no 8 of the password's characters are in the run's log, and the run wrote no bundle"
      fi
    fi
  fi
  if [ "$status" = 0 ] && grep -q '^\[sign-in\] already signed in' "$signout"; then
    echo "==> $udid was signed in already and Settings asks for no password. If --send reports 'account temporarily unavailable', its sign-in has ended (a restart of the simulator ends it with no prompt; a change of the account's password ends it with an Apple Account Verification alert, and dismissing that does not mend it): DEVICE=$udid scripts/simulator-run.sh --sign-in --renew signs the account out and in again, typing the password once. If --send reports another lapse, the test does not know the screen it shows"
  elif [ "$status" = 0 ]; then
    echo "==> $udid is signed in; DEVICE=$udid scripts/simulator-run.sh --send hello proves CloudKit answers"
  else
    echo "==> the sign-in stopped; the '[sign-in] stopped:' line above and $results say where. Type no password by hand before reading why: a refused one tried again locks the account" >&2
  fi
  if [ "$status" = 0 ] && grep -q '^\[sign-in\] already signed in' "$signout"; then
    # Nothing was typed, so nothing is mended: a stop that stood still stands, and no sign-in is
    # recorded for a run waiting on this one to read as a renewal.
    if [ -e "$stopped.prior" ]; then mv -f "$stopped.prior" "$stopped"; else rm -f "$stopped"; fi
  elif [ "$status" = 0 ]; then
    # The pass recorded before the stop goes, so no moment stands with neither.
    uuidgen >"$signedin"
    rm -f "$stopped" "$stopped.prior"
  else
    rm -f "$stopped.prior"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) in $root: see $results" >"$stopped"
    leave="its sign-in stopped, and a two-factor code screen it stopped on stays up for SIGNIN_CODE"
  fi
  return "$status"
}

# Renews a sign-in the device's restart ended: once a run, never past a sign-in that stopped
# (a refused password typed again is how an account is locked), and logged with why, so the
# count of password sign-ins is in $simstate/renewals.log.
renew_sign_in() {
  local why="$1" status=0
  take_sign_in || exit 1
  refuse_if_stopped "$why"
  if [ "$signed_meanwhile" = yes ]; then
    echo "==> $udid's iCloud sign-in had lapsed ($why), and another run's sign-in has renewed it since this run found it so"
    drop_sign_in
    return 0
  fi
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $udid $why ($root)" >>"$simstate/renewals.log"
  echo "==> $udid's iCloud sign-in has lapsed ($why); renewing it: --sign-in --renew, one password sign-in"
  renew=yes
  sign_in || status=$?
  renew=no
  drop_sign_in
  if [ "$status" != 0 ]; then
    echo "==> the renewal stopped, and no run renews this device again until a --sign-in passes. A two-factor stop leaves its code screen up: SIGNIN_CODE=<code> DEVICE=$udid scripts/simulator-run.sh --sign-in types the code and goes on" >&2
    exit "$status"
  fi
}

# Fails the run, touching nothing, while a sign-in on the device stands stopped.
refuse_if_stopped() {
  [ -e "$stopped" ] || return 0
  echo "==> $udid's iCloud sign-in has lapsed ($1), and an earlier sign-in on it stopped ($(cat "$stopped")), so this run types no password. Read why it stopped, then: DEVICE=$udid scripts/simulator-run.sh --sign-in --renew (or SIGNIN_CODE=<code> DEVICE=$udid scripts/simulator-run.sh --sign-in after a two-factor stop)" >&2
  exit 1
}

# One sign-in on a device at a time: a run holds `<udid>.renewing` while it drives Settings, and
# another that wants to waits for it (20 minutes at most). What the records were is read before
# the lock is tried, so a sign-in that ended at any moment before this run held it is seen: one
# that passed (a new `<udid>.signed-in`, signed_meanwhile) or one that stopped (a new stop,
# stop_meanwhile). The lock is on descriptor 6, which the background jobs close (tracked,
# serve_once), and drop_sign_in closes once the sign-in is over.
take_sign_in() {
  local signed_before stop_before prior_before
  local waited=no
  signed_meanwhile=no stop_meanwhile=no
  # The sign-in this run found lapsed is the one recorded when it learned so, at its launch or
  # its boot (signed_seen), not when it came here.
  # A sign-in in flight has put the stop it found aside (.prior) and stands its own in its place;
  # that one's end puts it back, removes it or writes its own, so the stop to compare with is the
  # one put aside. A .prior still standing once this run holds the lock is no sign-in's in
  # flight (every end takes it away but a signal's) and stands for nothing.
  signed_before="${signed_seen:-$(record_id "$signedin")}" stop_before="$(record_id "$stopped")"
  prior_before="$(record_id "$stopped.prior")"
  exec 6>"$simstate/$udid.renewing"
  if ! lockf -s -t 0 6; then
    waited=yes
    echo "==> another run is signing $udid in; waiting for it, 20 minutes at most"
    if ! lockf -s -t 1200 6; then
      echo "==> another run has been signing $udid in for 20 minutes; this run types nothing" >&2
      return 1
    fi
  fi
  [ "$(record_id "$signedin")" = "$signed_before" ] || [ ! -e "$signedin" ] || signed_meanwhile=yes
  [ -e "$stopped.prior" ] || [ "$prior_before" = none ] || stop_before="$prior_before"
  [ "$(record_id "$stopped")" = "$stop_before" ] || [ ! -e "$stopped" ] || stop_meanwhile=yes
  # The record of a sign-in this run waited on, still standing as it began: it was ended unseen,
  # a signal's end, and an attempt nobody saw finish may have been refused.
  case "$waited $stop_before" in
    "yes "*"begun and not seen to finish"*) [ "$(record_id "$stopped")" != "$stop_before" ] || stop_meanwhile=yes ;;
  esac
}
drop_sign_in() { exec 6>&-; }

# Renews the sign-in after this run booted the device, which ended it, when a sign-in has passed
# on it before: a device with none recorded is not signed in for the first time unasked.
renew_after_boot() {
  if [ -e "$signedin" ]; then
    renew_sign_in "$1"
  else
    echo "==> $udid has no sign-in recorded since its last --erase, so the run renews nothing; if it has an account, DEVICE=$udid scripts/simulator-run.sh --sign-in --renew"
  fi
}

if [ "$signin" = yes ]; then
  status=0
  take_sign_in || exit 1
  # A sign-in asked for by hand is the recovery from a stop, but only from one the person read:
  # a sign-in that passed or stopped while this one waited for it is not what was asked about.
  if [ "$signed_meanwhile" = yes ]; then
    echo "==> the run this one waited for signed $udid in; this run types nothing"
    leave="it was signed in for the runs after this one"
    exit 0
  elif [ "$stop_meanwhile" = yes ]; then
    echo "==> the sign-in this run waited for stopped ($(cat "$stopped")), so this run types nothing. Read why it stopped, then run --sign-in again" >&2
    exit 1
  fi
  sign_in || status=$?
  drop_sign_in
  # A sign-in shut down at once would end with the device: it lives in cloudd's memory alone.
  [ "$status" != 0 ] || leave="it was signed in for the runs after this one"
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
    # The test uses the device whether or not this run booted it.
    touched=yes
    echo "==> the simulator booted after coreaudiod started, so it hears the lane without a reboot"
  elif [ -e "$stopped" ]; then
    # A boot here renews the sign-in, which a standing stop refuses: say so before a reboot
    # takes down the screen the stop may have left up.
    refuse_if_stopped "a boot onto the lane's audio devices would end it"
  elif [ -z "$booted" ]; then
    echo "==> booting the simulator onto the lane's audio devices"
    boot_device
    renew_after_boot "this run booted it, which ends its sign-in"
  else
    echo "==> rebooting the simulator onto the lane's audio devices, since it booted before coreaudiod started"
    { lockf -s -t 120 7 || { echo "==> another run has held $simstate/mutex for 2 minutes" >&2; exit 1; }
      users="$(users_now)"
      if [ -n "$users" ]; then
        echo "==> $udid booted before coreaudiod started and has to be rebooted to hear the lane, but these runs are using it; run --talk once they are done:" >&2
        printf '%s\n' "$users" | sed 's/^/      /' >&2
        exit 1
      fi
      refuse_if_stopped "a boot onto the lane's audio devices would end it"
      xcrun simctl shutdown "$udid" 7>&- 2>/dev/null || true
    } 7>"$simstate/mutex"
    boot_device
    renew_after_boot "this run rebooted it, which ends its sign-in"
  fi
  # The result bundle's session log records the test runner's environment whole, and the
  # environment the runner launches the app with, so the token is in neither: it is served once
  # on the loopback, and the runner hands the app only the port and the nonce, from which the
  # app reads it itself at launch (DebugRun.servedToken). The test is built before the listener
  # starts, so a slow build does not use up its 30 minutes.
  echo "==> building the talk test (TopoTalkTests)"
  tracked "${scrubbed[@]}" xcodebuild build-for-testing -project Topo.xcodeproj -scheme TopoTalk \
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
    tracked "${scrubbed[@]}" xcodebuild test-without-building -project Topo.xcodeproj -scheme TopoTalk \
      -configuration Debug -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
      -collect-test-diagnostics never -resultBundlePath "$results" || status=$?
  scripts/ci-audio-lane.sh check after || status=1
  # A test that passed on some other login proves nothing of the token: the listener has to have
  # served it. One that has just answered may still be on its way out.
  token_served 2 || { echo "==> the app never read the served token" >&2; status=1; }
  scripts/ci-require-tests.sh xcresult "$results" TopoTalkTests || status=1
  [ "$status" = 0 ] && echo "==> the spoken question was heard, answered and read aloud" \
    || echo "==> the spoken turn failed; $results says where" >&2
  exit "$status"
fi

if [ "$build" = yes ]; then
  echo "==> building"
  tracked "${scrubbed[@]}" xcodebuild -project Topo.xcodeproj -scheme Topo -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
    build
fi

app="$derived/Build/Products/Debug-iphonesimulator/Topo.app"
[ -d "$app" ] || { echo "no app at $app; build first" >&2; exit 1; }

if [ "$pressmic" = yes ]; then
  # The XCUITest that taps, holds and releases the microphone (Tests/ClientUI), on this device.
  # It launches the app signed in with a placeholder token; the launch below is served the real
  # one. docs/simulator.md says what the press reaches and what it cannot.
  echo "==> pressing the microphone"
  # The test counts the permission prompts the run raises, so the app's grants go first, and the
  # flag says the reset happened: the count is exact only on a simulator that has answered nothing.
  boot_device
  xcrun simctl privacy "$udid" reset all "$bundle"
  TEST_RUNNER_TOPO_UITEST_PRIVACY_RESET=1 \
    tracked "${scrubbed[@]}" xcodebuild test -project Topo.xcodeproj -scheme Topo -configuration Debug \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
      -collect-test-diagnostics never -only-testing:TopoUITests
fi

boot_device
if [ "$fresh" = yes ]; then
  xcrun simctl uninstall "$udid" "$bundle" 2>/dev/null || true
fi
xcrun simctl install "$udid" "$app"
# A launch to drive by hand or for guest turns has no iCloud check to find a lapse at, and the
# role it decides from CloudKit's records can sign the launch out (a viewer's arrival), which the
# resident refuses to start under; so one on a device this run booted is renewed first. A guest
# command alone needs no sign-in; a --send renews at its check.
if [ -z "$send$userland" ] && [ "$booted_here" = yes ]; then
  renew_after_boot "this run booted it, which ends its sign-in"
fi

launcher=""
# The launcher stays attached to the app's console only when there is a closing line to wait for.
# An attached launcher never exits, since the app never does, so a run with nothing to wait for
# launches detached: simctl returns once the app is up, and the run ends there.
attach=""
if [ -n "$send" ] || [ -n "$userland" ] || [ -n "$guestturn" ]; then
  attach=--console-pty
fi
# Launches the app: a fresh log, run id and served token each time, so a relaunch reads nothing
# of the launch before it. A guest command alone needs no sign-in; anything else launches signed in.
launch_app() {
  token=""
  if [ -z "$userland" ] || [ -n "$send" ]; then
    read_token
  fi
  signed_seen="$(record_id "$signedin")"
  [ -z "$log" ] || rm -f "$log"
  log="$(mktemp -t topo-sim)"
  # This run's id: the app prints it on the reply to the turn it sent, so neither a line from an
  # earlier launch nor a reply to some other turn can stand in for this run's answer.
  run="$(uuidgen)"
  launch=(SIMCTL_CHILD_TOPO_DEBUG_SEND="$send" SIMCTL_CHILD_TOPO_DEBUG_USERLAND="$userland"
          SIMCTL_CHILD_TOPO_DEBUG_GUEST_TURN="$guestturn" SIMCTL_CHILD_TOPO_DEBUG_RUN="$run")
  # The token is served, never put in the launch's environment, which the simulator's log records.
  # The port goes in only with a token behind it: a launch that names a port and gets no token is
  # signed out (DebugRun.signIn), which a guest command alone is not asked to be. The app asks at
  # launch, so the listener waits two minutes and no longer, which bounds what a run killed by
  # SIGKILL, whose `cleanup` never runs, leaves listening.
  if [ -n "$token" ]; then
    nonce="$(uuidgen)"
    serve_once "$nonce" token 120
    unset token
    launch+=(SIMCTL_CHILD_TOPO_DEBUG_TOKEN_PORT="$served_port" SIMCTL_CHILD_TOPO_DEBUG_TOKEN_NONCE="$nonce")
  fi
  echo "==> launching (run $run)"
  "${scrubbed[@]}" "${launch[@]}" \
    xcrun simctl launch $attach --terminate-running-process "$udid" "$bundle" >"$log" 2>&1 &
  launcher=$!
  echo "$launcher" >>"$pids"
  started_pids="$started_pids $launcher"
}
launch_app

fail() {
  grep '\[topo-debug\]' "$log" || cat "$log"
  echo "==> $*" >&2
  exit 1
}

# Ends this run's launcher and any listener still waiting to serve it.
stop_launch() {
  local pid
  for pid in "$launcher" "$served_by"; do
    if [ -n "$pid" ] && running_child "$pid"; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi
  done
  launcher="" served_by=""
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
  read_icloud() {
    wait_for "icloud: " "the iCloud check"
    icloud="$(grep -o '\[topo-debug\] icloud: .*' "$log" | head -1 | tr -d '\r')"
    icloud="${icloud#\[topo-debug\] icloud: }"
  }
  read_icloud
  # Signed in to Settings with CloudKit refusing and nothing asking is the sign-in a restart of
  # the device ended (docs/simulator.md, *A lapse*), which is every boot of a device this script
  # shut down: the run renews it, once, and launches again.
  if [ "$icloud" = "account temporarily unavailable" ]; then
    stop_launch
    renew_sign_in "CloudKit answered account temporarily unavailable"
    waited=0
    launch_app
    read_icloud
  fi
  case "$icloud" in
    answered) ;;
    "no account") fail "the simulator $udid has no iCloud account; sign it in with: DEVICE=$udid scripts/simulator-run.sh --sign-in" ;;
    # Signed in to Settings with CloudKit refusing and nothing asking: a sign-in the device's last
    # restart ended, which only signing out and in again mends (docs/simulator.md, *A lapse*).
    "account temporarily unavailable") fail "the simulator $udid is signed in to Settings but CloudKit refuses its account (account temporarily unavailable): its sign-in has ended (a restart of the simulator ends it with no prompt; a change of the account's password ends it with an Apple Account Verification alert, and dismissing that does not mend it). Sign it out and in again with: DEVICE=$udid scripts/simulator-run.sh --sign-in --renew" ;;
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
# The app reads the token at launch, so by the end of the work it has been served or never will.
if [ -n "$served_by" ] && [ -n "$send$userland$guestturn" ]; then
  token_served 2 || fail "the app never read the served token"
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
  # A detached launcher returns once the app is up, which can be before the app has asked; the
  # wait for it is under TIMEOUT, as every wait on the app after the launch is.
  token_served "$timeout" || fail "the app never read the served token"
  echo "==> launched signed in"
  leave="it was launched to be driven by hand"
fi
