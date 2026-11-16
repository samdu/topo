#!/usr/bin/env bash
# Turns the hub's mind on or off, or says where it stands, from a shell on the Mac.
#
#   scripts/hub-mind.sh [--memory] on|off|status
#
# The switch ("Run the mind on this Mac") is a boolean in the hub's defaults, domain
# zone.hexagon.topo.hub, key mind.on (docs/hub.md). on and off write it, and a running hub follows
# it at its next 10 s refresh; this script also sends the hub SIGUSR1, which makes it follow the
# defaults at once (never a flip), then waits for the hub's status to show the switch applied. A hub
# launched later starts with the switch as it was left. With no hub running, the switch is only kept.
# A mind that stopped (signed out, stalled) is started again as the menu's Try again does by `off`
# then `on`; `on` over a switch already on changes nothing.
#
# status prints what the menu's mind section says, from the status the hub writes at every change
# and refresh (hub-status.json in the mind's root): the switch, whether Claude Code is signed in,
# who holds the lease, the mind's state by kind, the mind's own line (process, model, session) and
# the last pass. No word of a turn is in it. A status whose pid is not a running TopoHub is said to
# be a stopped hub's.
#
# --memory addresses a hub launched with TOPO_STORE=memory: its switch is memory.mind.on and its
# root is "Topo Hub (memory store)", so nothing done to it touches the real switch.
#
# The hub's own pid, which `kill -TERM` takes for a clean quit (the lease let go, the mind reaped,
# within 10 s), is the status's pid line. It drives an unsandboxed hub (scripts/hub-dev-build.sh's):
# a sandboxed build keeps its defaults in its container, out of `defaults`' reach.
set -euo pipefail

domain=zone.hexagon.topo.hub
key=mind.on
root="$HOME/Library/Application Support/Topo Hub"
if [ "${1-}" = --memory ]; then
  key=memory.mind.on
  root="$HOME/Library/Application Support/Topo Hub (memory store)"
  shift
fi
status_file="$root/hub-status.json"
wait_for="${HUB_MIND_WAIT:-20}"

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

field() { jq -r --arg k "$1" '.[$k] | if . == null then empty else tostring end' "$status_file" 2>/dev/null; }

# The hub's pid when the status names a running TopoHub, else nothing.
running_pid() {
  local pid
  pid="$(field pid)"
  [ -n "$pid" ] || return 0
  case "$(ps -p "$pid" -o args= 2>/dev/null)" in
    *TopoHub.app/Contents/MacOS/TopoHub*) echo "$pid" ;;
  esac
}

show() {
  if [ ! -f "$status_file" ]; then
    echo "no hub has written a status in $root"
    echo "switch:  $(kept)"
    return 0
  fi
  local pid
  pid="$(running_pid)"
  if [ -n "$pid" ]; then echo "hub:     running, pid $pid, store $(field store)"
  else echo "hub:     not running (the status below is from pid $(field pid), at $(field at))"; fi
  echo "switch:  $(field on | sed 's/true/on/; s/false/off/') (kept: $(kept))"
  echo "login:   $(field login)"
  if [ "$(field holds)" = true ]; then echo "lease:   this Mac"
  elif [ -n "$(field leaseHolder)" ]; then echo "lease:   $(field leaseHolder)"
  else echo "lease:   nobody holds a fresh lease"; fi
  echo "mind:    $(field phase)"
  echo "process: $(field mind)"
  echo "last:    $(field lastPass || true)"
  echo "passes:  $(field passes), status at $(field at)"
}

kept() {
  case "$(defaults read "$domain" "$key" 2>/dev/null || true)" in
    1) echo on ;;
    *) echo off ;;
  esac
}

switch() { # switch true|false
  local want="$1" pid n
  defaults write "$domain" "$key" -bool "$want"
  pid="$(running_pid)"
  if [ -z "$pid" ]; then
    echo "switch kept $( [ "$want" = true ] && echo on || echo off ); no hub is running to follow it"
    return 0
  fi
  kill -USR1 "$pid"
  for n in $(seq $((wait_for * 10))); do
    # Applied: on, past starting (answering, or stopped saying why); off, off.
    case "$want/$(field on)/$(field phase)" in
      true/true/off|true/true/starting|true/true/) ;;
      true/true/*|false/false/off) show; return 0 ;;
    esac
    perl -e 'select(undef,undef,undef,0.1)'
  done
  show
  echo "the hub (pid $pid) did not show the switch $( [ "$want" = true ] && echo on || echo off ) within ${wait_for}s" >&2
  return 1
}

case "${1-}" in
  on) switch true ;;
  off) switch false ;;
  status) show ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
