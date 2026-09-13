#!/usr/bin/env bash
# Builds Topo, boots a simulator, signs it in with the long-lived Claude setup token, and
# optionally makes it say something and asserts the reply landed in the log.
#
# A --send run passes only when the app printed `done`, printed no `error:`, and printed
# `reply to <turn> in run <id>:` under the id this script launched it with (the reply DebugRun
# found by the sent turn's nonce and the reply's parents). A launcher that exits before `done`,
# or non-zero at all, a turn not finished within TIMEOUT seconds (180), and a missing or foreign
# reply each exit non-zero. scripts/tests/simulator-run-test.sh holds this against a fake xcrun.
#
#   scripts/simulator-run.sh                        # build, boot, install, launch signed in
#   scripts/simulator-run.sh --send "hello"         # ... and send one turn, asserting the reply
#   scripts/simulator-run.sh --press-mic            # ... after pressing the microphone (TopoUITests)
#   scripts/simulator-run.sh --screenshot ~/s.png   # ... and capture the screen
#   scripts/simulator-run.sh --erase                # tear the simulator down, keychain and all
#   DEVICE="iPad Pro 13-inch (M4)" scripts/simulator-run.sh
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
timeout="${TIMEOUT:-180}"

while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --send) send="$2"; shift 2 ;;
    --press-mic) pressmic=yes; shift ;;
    --screenshot) screenshot="$2"; shift 2 ;;
    --erase) erase=yes; shift ;;
    --no-build) build=no; shift ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

udid="$(xcrun simctl list devices available -j \
  | /usr/bin/python3 -c 'import json,sys;n=sys.argv[1];print(next((d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"]==n),""))' "$device")"
[ -n "$udid" ] || { echo "no available simulator named '$device'; xcrun simctl list devices available" >&2; exit 1; }
echo "==> $device ($udid)"

if [ "$erase" = yes ]; then
  xcrun simctl shutdown "$udid" 2>/dev/null || true
  xcrun simctl erase "$udid"
  echo "==> erased; the token is no longer in that simulator's keychain"
  exit 0
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
  xcodebuild test -project Topo.xcodeproj -scheme Topo -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$derived" \
    -only-testing:TopoUITests
fi

# The token, read once into a variable and never echoed. `set -u` makes an unset one an error
# rather than an empty header the API answers 401 to.
token="${CLAUDE_SETUP_TOKEN:-}"
if [ -z "$token" ]; then
  token="$(op-item get long-lived-claude-auth-token 'oauth token')"
fi
[ -n "$token" ] || { echo "no Claude setup token: set CLAUDE_SETUP_TOKEN or check the vault item" >&2; exit 1; }

xcrun simctl bootstatus "$udid" -b >/dev/null
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
SIMCTL_CHILD_TOPO_DEBUG_RUN="$run" \
  xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle" >"$log" 2>&1 &
launcher=$!

fail() {
  grep '\[topo-debug\]' "$log" || cat "$log"
  echo "==> $*" >&2
  exit 1
}

if [ -n "$send" ]; then
  # The app prints one prefixed line per step and `done` when the turn has settled; wait for it
  # rather than for the app to exit, which it never does. A launcher that exits first is a launch
  # or an app that died, and fails the run there rather than at the timeout.
  waited=0
  until grep -q '\[topo-debug\] done' "$log" 2>/dev/null; do
    if ! kill -0 "$launcher" 2>/dev/null; then
      wait "$launcher" && status=0 || status=$?; launcher=""
      grep -q '\[topo-debug\] done' "$log" || fail "the launcher exited ($status) before the turn finished"
      break
    fi
    [ "$waited" -lt "$timeout" ] || fail "no turn finished within ${timeout}s"
    sleep 1
    waited=$((waited + 1))
  done
  # `done` is printed; a launcher already gone by now has to have gone cleanly.
  if [ -n "$launcher" ] && ! kill -0 "$launcher" 2>/dev/null; then
    wait "$launcher" && status=0 || status=$?; launcher=""
  fi
  [ "${status:-0}" = 0 ] || fail "the launcher exited ($status) after the turn finished"
fi

if [ -n "$screenshot" ]; then
  xcrun simctl io "$udid" screenshot "$screenshot"
  echo "==> $screenshot"
fi

if [ -n "$send" ]; then
  grep -q '\[topo-debug\] error:' "$log" && fail "the turn reported an error"
  grep -Eq "\[topo-debug\] reply to [^ ]+ in run $run: " "$log" \
    || fail "no reply to the turn this run sent (run $run)"
  grep '\[topo-debug\]' "$log"
  echo "==> the message landed and was answered"
else
  wait "$launcher" && status=0 || status=$?; launcher=""
  [ "$status" = 0 ] || fail "the launcher exited ($status)"
fi
