#!/bin/bash
# Reserves the one simulator an agent runs on through Xcode's MCP tools, `Topo Agent`
# (docs/xcode-mcp.md), for the session that calls it.
#
#   scripts/agent-simulator.sh take      # prints the udid; exit 3 when another session holds it
#   scripts/agent-simulator.sh release   # shuts the device down and gives it up
#   scripts/agent-simulator.sh holder    # who holds it, if anyone
#
# The holder is the session, not this script: an agent's shell lives for one command, so nothing
# a command holds open outlasts it. The reservation is a file naming the session's process (the
# nearest `claude` above this script, or the calling shell when there is none) and when that
# process started, and it stands for as long as that process lives. A reservation whose process
# is gone is nobody's, and `take` takes it over. Reading and writing the file happen under a
# kernel lock (lockf(1), on descriptor 9) held only while this script runs, so of two sessions
# that take at once exactly one gets the device.
set -euo pipefail

name="Topo Agent"
state="${TOPO_AGENT_STATE:-$HOME/Library/Caches/topo-agent}"
holder="$state/holder"

die() { echo "agent-simulator: $*" >&2; exit 1; }

# The session's pid: TOPO_AGENT_SESSION_PID, else the nearest ancestor named claude, else the caller.
session_pid() {
  if [ -n "${TOPO_AGENT_SESSION_PID:-}" ]; then echo "$TOPO_AGENT_SESSION_PID"; return; fi
  local pid="$PPID" comm
  while [ "${pid:-0}" -gt 1 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || break
    if [ "$(basename "$comm")" = claude ]; then echo "$pid"; return; fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  echo "$PPID"
}

# When a pid started, which with the pid names one process and not whichever has the number now.
started() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'; }

# The holder file is three lines: pid, when that process started, and a line for people.
held_pid() { sed -n 1p "$holder" 2>/dev/null; }
held_start() { sed -n 2p "$holder" 2>/dev/null; }
held_by() { sed -n 3p "$holder" 2>/dev/null; }
# True when the file names a process that is still the one it named.
held() {
  local pid; pid="$(held_pid)"
  [ -n "$pid" ] && [ -n "$(held_start)" ] && [ "$(started "$pid")" = "$(held_start)" ]
}

device() { # <field>
  xcrun simctl list devices -j \
    | jq -r --arg n "$name" --arg f "$1" '[.devices[][] | select(.name == $n)] | if length == 1 then .[0][$f] else "count=\(length)" end'
}

shutdown_if_booted() {
  [ "$(device state)" = Shutdown ] || xcrun simctl shutdown "$1" >/dev/null 2>&1 || true
  [ "$(device state)" = Shutdown ] || die "$name ($1) would not shut down."
}

cmd="${1:-}"
case "$cmd" in take|release|holder) ;; *) echo "usage: $0 take|release|holder" >&2; exit 2 ;; esac

mkdir -p "$state"
exec 9> "$state/mutex"
lockf -s -t 30 9 || die "another agent-simulator.sh has held $state/mutex for 30 seconds."

me="$(session_pid)"
my_start="$(started "$me")"
[ -n "$my_start" ] || die "the session's process ($me) is not running."

case "$cmd" in
  holder)
    if held; then echo "held by $(held_by)"; else echo "free"; fi ;;

  take)
    if held && { [ "$(held_pid)" != "$me" ] || [ "$(held_start)" != "$my_start" ]; }; then
      echo "agent-simulator: $name is held by $(held_by). Do without it: build and read through the bridge, and run nothing." >&2
      exit 3
    fi
    udid="$(device udid)"
    case "$udid" in
      count=0) die "there is no simulator named \"$name\"; docs/xcode-mcp.md has the command that makes it." ;;
      count=*) die "more than one simulator is named \"$name\" (${udid#count=}); there is to be one." ;;
    esac
    # Nobody holds it, so a booted device is what a session that died left running.
    held || shutdown_if_booted "$udid"
    printf '%s\n%s\n%s\n' "$me" "$my_start" \
      "pid $me, $(git rev-parse --abbrev-ref HEAD 2>/dev/null || basename "$PWD"), since $(date '+%H:%M')" > "$holder.new"
    mv "$holder.new" "$holder"
    echo "$udid" ;;

  release)
    if ! held; then rm -f "$holder"; exit 0; fi
    if [ "$(held_pid)" != "$me" ] || [ "$(held_start)" != "$my_start" ]; then
      echo "agent-simulator: $name is held by $(held_by), not by this session; it is not this session's to release." >&2
      exit 3
    fi
    # Shut down before giving it up, so the next to take it finds it as it expects.
    udid="$(device udid)"
    case "$udid" in count=*) ;; *) shutdown_if_booted "$udid" ;; esac
    rm -f "$holder" ;;
esac
