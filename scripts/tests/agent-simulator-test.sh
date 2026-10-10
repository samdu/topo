#!/bin/bash
# scripts/agent-simulator.sh gives the agent's simulator to one session at a time, takes over
# from a session that is gone, and shuts the device down before it gives it up. xcrun is a
# stand-in that keeps the device's state in a file and records each shutdown.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
fake="$(mktemp -d -t agent-simulator-test)"
a="" b=""
trap 'kill $a $b 2>/dev/null; rm -rf "$fake"' EXIT
cat > "$fake/xcrun" <<'FAKE'
#!/bin/bash
case "$*" in
  "simctl list devices -j")
    printf '{"devices":{"rt":[{"name":"Topo Agent","udid":"UDID-1","state":"%s"},{"name":"Topo Agent 2","udid":"UDID-2","state":"Booted"}]}}\n' "$(cat "$FAKE_DIR/state")" ;;
  "simctl shutdown UDID-1") echo Shutdown > "$FAKE_DIR/state"; echo shutdown >> "$FAKE_DIR/calls" ;;
  *) echo "unexpected xcrun $*" >> "$FAKE_DIR/calls"; exit 1 ;;
esac
FAKE
chmod +x "$fake/xcrun"
echo Shutdown > "$fake/state"
: > "$fake/calls"

# Two sessions, each a process that outlives the commands run for it.
sleep 600 & a=$!; disown
sleep 600 & b=$!; disown
as() { # <session pid> <args...>
  local pid="$1"; shift
  FAKE_DIR="$fake" PATH="$fake:$PATH" TOPO_AGENT_STATE="$fake/state.d" TOPO_AGENT_SESSION_PID="$pid" scripts/agent-simulator.sh "$@" 2>/dev/null
}
check() { # <what> <got> <want>
  [ "$2" = "$3" ] || { echo "FAIL: $1: got '$2', wanted '$3'"; fail=1; }
}

check "nobody holds it at first" "$(as "$a" holder)" free
check "take prints the udid of the one device of that name" "$(as "$a" take)" UDID-1
as "$b" take >/dev/null; check "a second session is refused" "$?" 3
check "the holder taking again keeps it" "$(as "$a" take)" UDID-1
as "$b" release; check "a session cannot release another's" "$?" 3
as "$a" holder | grep -q "pid $a" || { echo "FAIL: holder does not name the session"; fail=1; }

# Release shuts a booted device down, and the other session can then take it.
echo Booted > "$fake/state"
as "$a" release; check "the holder releases" "$?" 0
check "release shut the device down" "$(cat "$fake/state") $(cat "$fake/calls")" "Shutdown shutdown"
check "the other session takes it after a release" "$(as "$b" take)" UDID-1

# A holder that died leaves a reservation that is nobody's, and a device still booted.
echo Booted > "$fake/state"; : > "$fake/calls"
kill "$b"; while kill -0 "$b" 2>/dev/null; do :; done; b=""
check "a dead session's reservation is taken over" "$(as "$a" take)" UDID-1
check "taking over shut down what the dead session left" "$(cat "$fake/state") $(cat "$fake/calls")" "Shutdown shutdown"

# A pid alone is not the session: the same number with another start time is another process.
sed -i '' '2s/.*/Thu Jan  1 00:00:00 1970/' "$fake/state.d/holder"
sleep 600 & b=$!; disown
check "a reused pid does not hold it" "$(as "$b" take)" UDID-1
as "$b" release

# Of several sessions taking at once, one gets it.
pids=() takes=() winners=0
for i in 1 2 3 4 5 6; do sleep 600 & pids+=($!); disown; done
for p in "${pids[@]}"; do ( as "$p" take >/dev/null ) & takes+=($!); done
for t in "${takes[@]}"; do wait "$t" && winners=$((winners + 1)); done
kill "${pids[@]}" 2>/dev/null
check "sessions that took at once and got it" "$winners" 1

as "$a" bogus; check "an unknown command is a usage error" "$?" 2

[ "$fail" = 0 ] && echo "agent-simulator-test: ok"
exit "$fail"
