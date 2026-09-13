#!/usr/bin/env bash
# Builds Topo, boots a simulator, signs it in with the long-lived Claude setup token, and
# optionally makes it say something and asserts the reply landed in the log.
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
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
trap 'rm -f "$log"' EXIT
echo "==> launching"
SIMCTL_CHILD_TOPO_CLAUDE_SETUP_TOKEN="$token" \
SIMCTL_CHILD_TOPO_DEBUG_SEND="$send" \
  xcrun simctl launch --console-pty --terminate-running-process "$udid" "$bundle" >"$log" 2>&1 &
launcher=$!

if [ -n "$send" ]; then
  # The app prints one prefixed line per step and `done` when the turn has settled; wait for it
  # rather than for the app to exit, which it never does.
  waited=0
  until grep -q '\[topo-debug\] done' "$log" 2>/dev/null; do
    [ "$waited" -lt "$timeout" ] || { echo "==> no turn finished within ${timeout}s" >&2; break; }
    sleep 2
    waited=$((waited + 2))
  done
fi

if [ -n "$screenshot" ]; then
  xcrun simctl io "$udid" screenshot "$screenshot"
  echo "==> $screenshot"
fi

if [ -n "$send" ]; then
  kill "$launcher" 2>/dev/null || true
  grep '\[topo-debug\]' "$log" || true
  if grep -q '\[topo-debug\] error:' "$log"; then
    echo "==> the turn reported an error" >&2
    exit 1
  fi
  grep -q '\[topo-debug\] reply:' "$log" || { echo "==> no reply came back" >&2; exit 1; }
  echo "==> the message landed and was answered"
else
  wait "$launcher" || true
fi
