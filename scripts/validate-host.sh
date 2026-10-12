#!/usr/bin/env bash
# The switch that lends another Mac to validation, by hand: on for an afternoon, off after.
#
#   scripts/validate-host.sh on <host> [hours]
#   scripts/validate-host.sh off <host>
#   scripts/validate-host.sh status
#
# `on` names the Mac (an ssh alias) in ~/Library/Caches/topo-validate/hosts on this one, which
# is where scripts/validate-and-push.sh reads the Macs it may send `topo_unit` and `others`
# to, and holds that Mac awake and unlocked from then: a `caffeinate` there that keeps its
# display on and counts its person as present, for the hours given (six, and no more than
# twelve), so it neither sleeps nor locks for idleness between suites. The Mac is unlocked by
# its person first: `on` refuses one whose screen is locked, since nothing here unlocks it, and
# names nothing. A closed lid still sleeps it, whatever holds it awake.
#
# `off` takes the name out and ends that `caffeinate`, by the pid `on` left there and only
# while that pid is still a caffeinate. `status` says which Macs are named and how each is held.
# `on` again starts the hours afresh.
set -euo pipefail

cache="${TOPO_VALIDATE_CACHE:-$HOME/Library/Caches/topo-validate}"
DEFAULT_HOURS=6
MAX_HOURS=12

die() { echo "error: $*" >&2; exit 2; }
usage() { sed -n '4,6s/^#   //p' "${BASH_SOURCE[0]}" >&2; exit 2; }
ssh_to() { ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=10 "$@"; }
named() { sed -e 's/#.*//' -e 's/[[:space:]]//g' -e '/^$/d' "$cache/hosts" 2>/dev/null || true; }
check_name() {
  case "${1-}" in "" | *[!A-Za-z0-9._-]* | -*) die "'${1-}' is not a host: an ssh alias." ;; esac
}
# The hosts file without the name, or without the file when nothing else is in it.
unname() {
  [ -f "$cache/hosts" ] || return 0
  { grep -vx "[[:space:]]*$1[[:space:]]*" "$cache/hosts" || true; } > "$cache/hosts.$$"
  if [ -s "$cache/hosts.$$" ]; then mv -f "$cache/hosts.$$" "$cache/hosts"; else rm -f "$cache/hosts.$$" "$cache/hosts"; fi
}

# What runs on the Mac, as `bash -s -- <on|off|status> [seconds]`. The pid it keeps is ended
# only while it is still a caffeinate: a pid alone can be another process's by then.
there='
what="$1" seconds="${2-}"
cache="$HOME/Library/Caches/topo-validate"
held() {
  pid="$(sed -n 1p "$cache/awake" 2>/dev/null)"
  [ -n "$pid" ] && [ "$(ps -o comm= -p "$pid" 2>/dev/null | sed "s|.*/||")" = caffeinate ]
}
release() { if held; then kill "$pid" 2>/dev/null; fi; rm -f "$cache/awake"; }
case "$what" in
  on)
    console="$(ioreg -n Root -d1 2>/dev/null || true)"
    if awk '"'"'BEGIN { RS = "}" } /"kCGSSessionOnConsoleKey"=Yes/ && /"CGSSessionScreenIsLocked"=Yes/ { found = 1 } END { exit !found }'"'"' <<<"$console"; then
      echo "error: the screen of $(hostname -s) is locked; unlock it there, then run this again." >&2
      exit 76
    fi
    mkdir -p "$cache" || exit 1
    release
    nohup /usr/bin/caffeinate -dimsu -t "$seconds" > /dev/null 2>&1 &
    printf "%s\n%s\n" "$!" "$(($(date +%s) + seconds))" > "$cache/awake"
    ;;
  off) release ;;
  status)
    if held; then
      left=$(( $(sed -n 2p "$cache/awake") - $(date +%s) ))
      echo "held awake and unlocked for $((left / 3600)) h $((left % 3600 / 60)) min more"
    else
      echo "not held awake"
    fi
    ;;
esac
'

case "${1-}" in
  on)
    host="${2-}"; hours="${3:-$DEFAULT_HOURS}"
    check_name "$host"
    case "$hours" in "" | *[!0-9]* | 0) die "'$hours' is not a number of hours: one to $MAX_HOURS." ;; esac
    [ "$hours" -le "$MAX_HOURS" ] || die "$hours hours is more than $MAX_HOURS."
    status=0
    ssh_to "$host" bash -s -- on "$((hours * 3600))" <<<"$there" || status=$?
    case "$status" in
      0) ;;
      76) exit 1 ;;
      *) die "$host was not reached, or could not be held awake (ssh exited $status); it is not named." ;;
    esac
    mkdir -p "$cache"
    named | grep -qx "$host" || echo "$host" >> "$cache/hosts"
    echo "$host is named in $cache/hosts and held awake and unlocked for $hours hours; a closed lid still sleeps it. \`$0 off $host\` ends both."
    ;;
  off)
    host="${2-}"
    check_name "$host"
    unname "$host"
    if ssh_to "$host" bash -s -- off <<<"$there"; then
      echo "$host is no longer named, and nothing of this holds it awake."
    else
      echo "$host is no longer named; it was not reached, so what holds it awake there ends by itself when its hours are up."
    fi
    ;;
  status)
    [ -n "$(named)" ] || { echo "No Mac is named in $cache/hosts."; exit 0; }
    for host in $(named); do
      check_name "$host"
      echo "$host: $(ssh_to "$host" bash -s -- status <<<"$there" 2>/dev/null || echo "not reached")"
    done
    ;;
  *) usage ;;
esac
