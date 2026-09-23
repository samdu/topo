#!/usr/bin/env bash
# Builds Topo, boots a simulator, signs it in with the long-lived Claude setup token, and
# optionally makes it say something and asserts the reply landed in the log.
#
# A --send run takes the turn through the chat's own harness, which the guest's resident Claude
# Code answers. It passes only when the app printed `done`, printed no `error:`, printed
# `reply to <turn> in run <id> from session <session>, process <pid>:` under the id this script
# launched it with (the reply DebugRun found by the sent turn's nonce and the reply's parents,
# written by the resident process it names), and printed `mascot: turn began` and `mascot: turn
# gone` (Topo on the glass following the turn, with every pose between them). A launcher that
# exits before `done`, or non-zero at all, a turn not finished within TIMEOUT seconds (180), a
# missing or foreign reply, and a reply no resident session wrote each exit non-zero.
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
#   scripts/simulator-run.sh --screenshot ~/s.png   # ... and capture the screen
#   scripts/simulator-run.sh --erase                # tear the simulator down, keychain and all
#   DEVICE="iPad Pro 13-inch (M4)" scripts/simulator-run.sh   # a name, or a UDID when names repeat
#
# The token comes from the environment (CLAUDE_SETUP_TOKEN, which is what the vault item
# `long-lived-claude-auth-token` reaches this machine as) or, failing that, straight from the
# vault with `op-item`. It is handed to the app as SIMCTL_CHILD_TOPO_CLAUDE_SETUP_TOKEN and
# reaches no file, no scheme, no build setting and no artifact; the app writes it to that
# simulator's keychain, which --erase is how you clear.
#
# Every turn a debug build takes goes to Haiku, whatever the model setting says: the pin is
# ClaudeModel.pinned in Packages/TopoTurn/Sources/TopoTurn/MessagesAPI.swift.
#
# --talk runs the TopoTalk scheme's one UI test (Tests/ClientTalk) and nothing else: it fetches
# and verifies the ear's models into EAR_MODELS (build/ear-models) and the voice's into
# VOICE_MODELS (build/voice-models), starts the loopback lane with
# Tests/Fixtures/capital-of-france.wav (scripts/ci-audio-lane.sh; BlackHole as the Mac's default
# input and output), hands the token to the test runner as TEST_RUNNER_TOPO_TALK_SETUP_TOKEN, and
# passes only when scripts/ci-require-tests.sh finds the test ran and passed, never skipped. The
# lane is stopped and the Mac's defaults restored on every exit. Its turn is a real one.
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
# since the build is Debug) and an `answered in <seconds> s:` line.
#
# Building runs scripts/build-ish.sh first: the guest's framework is built from the fork's pin and
# is not in the repository.
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
fresh=no
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
    --fresh) fresh=yes; shift ;;
    -h|--help) sed -n '2,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

udid="$(xcrun simctl list devices available -j \
  | /usr/bin/python3 -c 'import json,sys;n=sys.argv[1];print(next((d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if n in (d["name"],d["udid"])),""))' "$device")"
[ -n "$udid" ] || { echo "no available simulator named '$device'; xcrun simctl list devices available" >&2; exit 1; }
echo "==> $device ($udid)"

if [ "$erase" = yes ]; then
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl erase "$udid"
  echo "==> erased; the token is no longer in that simulator's keychain"
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

if [ "$build" = yes ]; then
  scripts/build-ish.sh
fi

if [ "$talk" = yes ]; then
  read_token
  models="${EAR_MODELS:-$root/build/ear-models}"
  voice_models="${VOICE_MODELS:-$root/build/voice-models}"
  scripts/fetch-ear-models.sh "$models"
  scripts/fetch-voice-models.sh "$voice_models"
  trap 'scripts/ci-audio-lane.sh stop' EXIT
  scripts/ci-audio-lane.sh start "$root/Tests/Fixtures/capital-of-france.wav"
  # A simulator's audio is served by a host process bound to the coreaudiod it booted against,
  # so one booted before the lane installed BlackHole (which restarts coreaudiod) has no input.
  # Booting it again after the lane is up binds it to the loopback; its iCloud account and
  # keychain survive a reboot.
  echo "==> rebooting the simulator onto the lane's audio devices"
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  results="$derived/TopoTalk.xcresult"
  rm -rf "$results"
  echo "==> speaking a question into the microphone (TopoTalkTests)"
  status=0
  TEST_RUNNER_TOPO_TALK_SETUP_TOKEN="$token" TEST_RUNNER_TOPO_UITEST_EAR_MODELS="$models" \
  TEST_RUNNER_TOPO_UITEST_VOICE_MODELS="$voice_models" \
    xcodebuild test -project Topo.xcodeproj -scheme TopoTalk -configuration Debug \
      -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
      -resultBundlePath "$results" || status=$?
  scripts/ci-audio-lane.sh check after || status=1
  scripts/ci-require-tests.sh xcresult "$results" TopoTalkTests || status=1
  [ "$status" = 0 ] && echo "==> the spoken question was heard, answered and read aloud" \
    || echo "==> the spoken turn failed; $results says where" >&2
  exit "$status"
fi

if [ "$build" = yes ]; then
  echo "==> building"
  xcodebuild -project Topo.xcodeproj -scheme Topo -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
    build
fi

app="$derived/Build/Products/Debug-iphonesimulator/Topo.app"
[ -d "$app" ] || { echo "no app at $app; build first" >&2; exit 1; }

if [ "$pressmic" = yes ]; then
  # The XCUITest that taps, holds and releases the microphone (Tests/ClientUI), on this device.
  # It launches the app signed in with a placeholder token, which the launch below replaces with
  # the real one; docs/simulator.md says what the press reaches and what it cannot.
  echo "==> pressing the microphone"
  # The test counts the permission prompts the run raises, so the app's grants go first, and the
  # flag says the reset happened: the count is exact only on a simulator that has answered nothing.
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl privacy "$udid" reset all "$bundle"
  TEST_RUNNER_TOPO_UITEST_PRIVACY_RESET=1 \
    xcodebuild test -project Topo.xcodeproj -scheme Topo -configuration Debug \
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
trap '[ -z "$launcher" ] || kill "$launcher" 2>/dev/null; rm -f "$log"' EXIT
# This run's id: the app prints it on the reply to the turn it sent, so neither a line from an
# earlier launch nor a reply to some other turn can stand in for this run's answer.
run="$(uuidgen)"
echo "==> launching (run $run)"
SIMCTL_CHILD_TOPO_CLAUDE_SETUP_TOKEN="$token" \
SIMCTL_CHILD_TOPO_DEBUG_SEND="$send" \
SIMCTL_CHILD_TOPO_DEBUG_USERLAND="$userland" \
SIMCTL_CHILD_TOPO_DEBUG_GUEST_TURN="$guestturn" \
SIMCTL_CHILD_TOPO_DEBUG_RUN="$run" \
  xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle" >"$log" 2>&1 &
launcher=$!

fail() {
  grep '\[topo-debug\]' "$log" || cat "$log"
  echo "==> $*" >&2
  exit 1
}

# Waits for the app to print `marker`: one prefixed line per step and a closing line when the
# work has settled, rather than for the app to exit, which it never does. A launcher that exits
# first is a launch or an app that died, and fails the run there rather than at the timeout.
wait_for() {
  local marker="$1" what="$2" waited=0
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

[ -z "$send" ] || wait_for done "the turn"
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
  grep -q '\[topo-debug\] mascot: turn began' "$log" && grep -q '\[topo-debug\] mascot: turn gone' "$log" \
    || fail "Topo on the glass did not follow the guest's turn"
  echo "==> the message landed and was answered by the guest"
fi

if [ -n "$userland" ]; then
  lines="$(grep '\[topo-debug\]' "$log" | tr -d '\r')"
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
  lines="$(grep '\[topo-debug\]' "$log" | tr -d '\r')"
  grep -q '\[topo-debug\] guest turn error:' <<< "$lines" && fail "the guest's turns reported an error"
  grep -Eq '^\[topo-debug\] guest turn [0-9]+ (failed|abandoned)' <<< "$lines" && fail "a guest turn failed or was abandoned"
  count="$(awk -F ' \\|\\| ' '{ n = 0; for (i = 1; i <= NF; i++) if ($i ~ /[^ ]/) n++; print n }' <<< "$guestturn")"
  resident=""
  for n in $(seq 1 "$count"); do
    started="$(grep -E "^\[topo-debug\] guest turn $n model: claude-haiku-4-5[^ ]*, session [^ ]+, process [0-9]+$" <<< "$lines" | head -1 || true)"
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
  echo "==> the resident Claude Code answered $count turns in one process (session ${resident})"
fi

if [ -n "$send" ] || [ -n "$userland" ] || [ -n "$guestturn" ]; then
  grep '\[topo-debug\]' "$log"
else
  wait "$launcher" && status=0 || status=$?; launcher=""
  [ "$status" = 0 ] || fail "the launcher exited ($status)"
fi
