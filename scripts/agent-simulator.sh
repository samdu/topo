#!/bin/bash
# Reserves the one simulator an agent runs on through Xcode's MCP tools, `Topo Agent`
# (docs/xcode-mcp.md), for the session that calls it.
#
#   scripts/agent-simulator.sh take      # prints the udid; exit 3 when another session holds it,
#                                        # 4 when this one already does
#   scripts/agent-simulator.sh release   # shuts the device down and gives it up
#   scripts/agent-simulator.sh holder    # who holds it, if anyone; runs from anywhere
#
# The holder is the session, not this script: an agent's shell lives for one command, so nothing
# a command holds open outlasts it. The reservation is a file naming the session's process (the
# nearest `claude` above this script) and when that process started, and it stands for as long
# as that process lives. A session's subagents are that process too and cannot be told from it,
# so the main session alone takes and releases, and a second take by the holder is refused: a
# take that succeeded is the only thing that says the device is the caller's. Run from anything else, the
# script wants TOPO_AGENT_SESSION_PID, the pid of a process that lasts as long as the use does:
# the caller's own shell is gone at once under `$(...)`, and a holder that is gone holds nothing. A reservation whose process
# is gone is nobody's, and `take` takes it over. Reading and writing the file happen under a
# kernel lock (lockf(1), on descriptor 9) held only while this script runs, so of two sessions
# that take at once exactly one gets the device.
set -euo pipefail

name="Topo Agent"
state="${TOPO_AGENT_STATE:-$HOME/Library/Caches/topo-agent}"
holder="$state/holder"

die() { echo "agent-simulator: $*" >&2; exit 1; }

# The session's pid: TOPO_AGENT_SESSION_PID, else the nearest ancestor named claude.
session_pid() {
  if [ -n "${TOPO_AGENT_SESSION_PID:-}" ]; then echo "$TOPO_AGENT_SESSION_PID"; return; fi
  local pid="$PPID" comm
  while [ "${pid:-0}" -gt 1 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)" || break
    if [ "${comm##*/}" = claude ]; then echo "$pid"; return; fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
  done
  die "this is not run from a Claude Code session; set TOPO_AGENT_SESSION_PID to a process that lasts as long as the use does."
}

# When a pid started, which with the pid names one process and not whichever has the number now.
# In C and UTC, so sessions with different locales and zones read the same words.
started() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//' || true; }

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
  # 9>&-: a simctl that hangs after this script is killed does not keep the lock.
  [ "$(device state)" = Shutdown ] || xcrun simctl shutdown "$1" >/dev/null 2>&1 9>&- || true
  [ "$(device state)" = Shutdown ] || die "$name ($1) would not shut down."
}

cmd="${1:-}"
case "$cmd" in take|release|holder) ;; *) echo "usage: $0 take|release|holder" >&2; exit 2 ;; esac

mkdir -p "$state"
exec 9> "$state/mutex"
lockf -s -t 30 9 || die "another agent-simulator.sh has held $state/mutex for 30 seconds."

if [ "$cmd" = holder ]; then
  if held; then echo "held by $(held_by)"; else echo "free"; fi
  exit 0
fi

me="$(session_pid)" || exit 1
my_start="$(started "$me")"
[ -n "$my_start" ] || die "the session's process ($me) is not running."

case "$cmd" in
  take)
    if held; then
      if [ "$(held_pid)" = "$me" ] && [ "$(held_start)" = "$my_start" ]; then
        echo "agent-simulator: $name is already this session's ($(held_by)), taken once and not again. A subagent leaves it to the main session." >&2
        exit 4
      fi
      echo "agent-simulator: $name is held by $(held_by). Do without it: build and read through the bridge, and run nothing." >&2
      exit 3
    fi
    udid="$(device udid)"
    case "$udid" in
      count=0) die "there is no simulator named \"$name\"; docs/xcode-mcp.md has the command that makes it." ;;
      count=*) die "more than one simulator is named \"$name\" (${udid#count=}); there is to be one." ;;
    esac
    # Nobody holds it, so a booted device is what a session that died left running.
    shutdown_if_booted "$udid"
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
