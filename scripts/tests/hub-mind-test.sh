#!/usr/bin/env bash
# scripts/hub-mind.sh against a fake `defaults` and a fake hub, in a home made here: on and off keep
# the switch in the hub's domain under mind.on, and under memory.mind.on with --memory, each in its
# own root; a running hub is sent SIGUSR1 and its status shown once it says the switch is applied;
# a hub that does not apply it fails within the wait; with no hub running the switch is only kept;
# a status whose pid is not a TopoHub is a stopped hub's, and that pid is never signalled; status
# prints the menu's fields and nothing else the status holds.
#
#   scripts/tests/hub-mind-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"
work="$(mktemp -d)"
hubs=()
cleanup() {
  local pid
  for pid in "${hubs[@]-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  rm -rf "$work"
}
trap cleanup EXIT

export HOME="$work/home" DEFAULTS_DIR="$work/defaults"
mkdir -p "$HOME" "$DEFAULTS_DIR" "$work/bin"
real="$HOME/Library/Application Support/Topo Hub"
memory="$HOME/Library/Application Support/Topo Hub (memory store)"

# defaults: write <domain> <key> -bool <v> and read <domain> <key>, one file per key.
cat > "$work/bin/defaults" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  write) [ "$4" = -bool ] || exit 2; case "$5" in true|YES|1) v=1 ;; *) v=0 ;; esac; echo "$v" > "$DEFAULTS_DIR/$2.$3" ;;
  read) cat "$DEFAULTS_DIR/$2.$3" 2>/dev/null || { echo "does not exist" >&2; exit 1; } ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$work/bin/defaults"
export PATH="$work/bin:$PATH"

# A hub: writes its status at launch and, unless DEAF, at every SIGUSR1, from the switch as kept.
app="$work/TopoHub.app/Contents/MacOS"
mkdir -p "$app"
cat > "$app/TopoHub" <<'FAKE'
#!/usr/bin/env bash
root="$1" key="$2"
mkdir -p "$root"
write() {
  local on=false phase=off
  [ "$(cat "$DEFAULTS_DIR/zone.hexagon.topo.hub.$key" 2>/dev/null)" = 1 ] && on=true phase=answering
  printf '{"pid": %d, "store": "memory", "at": "2026-11-15T19:00:00Z", "on": %s, "phase": "%s", "login": "signed in (claude.ai, max)", "holds": %s, "mind": "Claude Code on this Mac, pid 7, model m", "lastPass": "answered by push at 2026-11-15T19:00:00Z", "passes": 3, "words": "octarine"}\n' \
    $$ "$on" "$phase" "$on" > "$root/hub-status.json.tmp"
  mv "$root/hub-status.json.tmp" "$root/hub-status.json"
}
trap '[ -n "${DEAF-}" ] || write' USR1
write
while true; do sleep 0.1 & wait $!; done
FAKE
chmod +x "$app/TopoHub"

hub() { # hub <root> <key> [VAR=value...]: a fake hub running, its pid in $hub_pid
  local root="$1" key="$2"; shift 2
  env "$@" "$app/TopoHub" "$root" "$key" & hub_pid=$!
  hubs+=("$hub_pid")
  until_true test -f "$root/hub-status.json" || fail "the fake hub wrote no status"
}

script="$here/../hub-mind.sh"
kept() { cat "$DEFAULTS_DIR/zone.hexagon.topo.hub.$1" 2>/dev/null; }

out="$("$script" status 2>&1)"; code=$?
is "status with no hub is not a failure" "$code" 0
case "$out" in *"no hub has written a status"*) ok "status says no hub has written one" ;; *) fail "status with no hub: $out" ;; esac

out="$("$script" on 2>&1)"; code=$?
is "on with no hub running succeeds" "$code" 0
is "on keeps mind.on" "$(kept mind.on)" 1
case "$out" in *"no hub is running"*) ok "on says no hub follows it" ;; *) fail "on with no hub: $out" ;; esac
"$script" off >/dev/null 2>&1
is "off keeps mind.on off" "$(kept mind.on)" 0

hub "$real" mind.on
out="$("$script" on 2>&1)"; code=$?
is "on with a hub succeeds" "$code" 0
is "on keeps mind.on" "$(kept mind.on)" 1
for want in "hub:     running, pid $hub_pid" "switch:  on" "login:   signed in (claude.ai, max)" "lease:   this Mac" "mind:    answering" \
            "process: Claude Code on this Mac, pid 7, model m" "last:    answered by push"; do
  case "$out" in *"$want"*) ok "status shows '$want'" ;; *) fail "status lacks '$want': $out" ;; esac
done
case "$out" in *octarine*) fail "status printed a field the menu does not show" ;; *) ok "status prints nothing else" ;; esac
out="$("$script" off 2>&1)"; code=$?
is "off with a hub succeeds" "$code" 0
case "$out" in *"mind:    off"*) ok "off is applied" ;; *) fail "off not applied: $out" ;; esac
kill "$hub_pid" 2>/dev/null; wait "$hub_pid" 2>/dev/null

hub "$real" mind.on DEAF=1
out="$(HUB_MIND_WAIT=1 "$script" on 2>&1)"; code=$?
[ "$code" -ne 0 ] && ok "a hub that does not follow fails the call" || fail "a deaf hub passed: $out"
case "$out" in *"did not show the switch on"*) ok "it says the switch was not applied" ;; *) fail "a deaf hub: $out" ;; esac
kill "$hub_pid" 2>/dev/null; wait "$hub_pid" 2>/dev/null
"$script" off >/dev/null 2>&1

# A status left by a hub that is gone, naming a pid that is now something else.
/bin/sleep 30 & other=$!
hubs+=("$other")
jq --argjson p "$other" '.pid = $p' "$real/hub-status.json" > "$work/s" && mv "$work/s" "$real/hub-status.json"
out="$("$script" status 2>&1)"
case "$out" in *"not running"*) ok "a status of a pid that is no hub is a stopped hub's" ;; *) fail "stale status: $out" ;; esac
"$script" on >/dev/null 2>&1
kill -0 "$other" 2>/dev/null && ok "a pid that is no hub is never signalled" || fail "the script signalled a process that is not the hub"
"$script" off >/dev/null 2>&1

hub "$memory" memory.mind.on
out="$("$script" --memory on 2>&1)"; code=$?
is "--memory on with a hub succeeds" "$code" 0
is "--memory keeps memory.mind.on" "$(kept memory.mind.on)" 1
is "--memory leaves mind.on alone" "$(kept mind.on)" 0
case "$out" in *"hub:     running, pid $hub_pid"*) ok "--memory reads the memory store's status" ;; *) fail "--memory status: $out" ;; esac
"$script" --memory off >/dev/null 2>&1
is "--memory off" "$(kept memory.mind.on)" 0

"$script" bogus >/dev/null 2>&1; is "an unknown command is a usage error" "$?" 2

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
