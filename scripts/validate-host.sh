#!/usr/bin/env bash
# The switch that lends another Mac to validation, by hand: on for an afternoon, off after.
#
#   scripts/validate-host.sh on <host> [hours]
#   scripts/validate-host.sh off <host>
#   scripts/validate-host.sh status
#
# `on` names the Mac (an ssh alias) in ~/Library/Caches/topo-validate/hosts on this one, which
# is where scripts/validate-and-push.sh reads the Macs it may send `topo_unit` and `others`
# to, and holds that Mac awake and unlocked from then: a `caffeinate -dimsu` there that keeps
# its display on and counts its person as present, for the hours given (six, and one to
# twelve), so it neither sleeps nor locks for idleness between suites. The Mac is unlocked by
# its person first: `on` refuses one where the session of the user it reaches is not the one
# on the screen, or is locked, since nothing here unlocks it, and names nothing. A closed lid
# still sleeps it, whatever holds it awake.
#
# `off` takes the name out and ends that `caffeinate`: the one whose pid, hours and end `on`
# left on record there, and only while that pid is still that command and its hours are not
# up. `status` says which Macs are named and how each is held. `on` again starts the hours
# afresh. One `on` or `off` runs at a time on this Mac.
set -euo pipefail

cache="${TOPO_VALIDATE_CACHE:-$HOME/Library/Caches/topo-validate}"
DEFAULT_HOURS=6
MAX_HOURS=12

die() { echo "error: $*" >&2; exit 2; }
usage() { sed -n '4,6s/^#   //p' "${BASH_SOURCE[0]}" >&2; exit 2; }
# The lock is this script's alone: nothing a connection starts holds it.
ssh_to() { ssh -o BatchMode=yes -o ControlPath=none -o ConnectTimeout=10 "$@" 9>&-; }
# The names in the file, one a line: any number to a line, a `#` and what follows it no name.
named() { { sed -e 's/#.*//' "$cache/hosts" 2>/dev/null || true; } | tr -s ' \t' '\n\n' | sed '/^$/d'; }
is_named() { named | grep -qxF "$1"; }
check_name() {
  case "${1-}" in "" | *[!A-Za-z0-9._-]* | -*) die "'${1-}' is not a host: an ssh alias." ;; esac
}
# The file without the name, wherever on a line it stands: a comment stays, a line left with
# nothing goes, and so does a file left with nothing.
unname() {
  [ -f "$cache/hosts" ] || return 0
  awk -v name="$1" '
    {
      comment = ""; at = index($0, "#")
      if (at) { comment = substr($0, at); $0 = substr($0, 1, at - 1) }
      had = NF; kept = ""
      for (i = 1; i <= NF; i++) if ($i != name) kept = kept (kept == "" ? "" : " ") $i
      if (kept == "" && comment == "" && had) next
      print kept (kept != "" && comment != "" ? " " : "") comment
    }' "$cache/hosts" > "$cache/hosts.$$"
  if [ -s "$cache/hosts.$$" ]; then mv -f "$cache/hosts.$$" "$cache/hosts"; else rm -f "$cache/hosts.$$" "$cache/hosts"; fi
}
# One `on` or `off` at a time: each reads the file and writes it, and starts or ends a hold.
alone() {
  mkdir -p "$cache"
  exec 9>> "$cache/hosts.lock"
  lockf -s -t 60 9 || die "another scripts/validate-host.sh has been at the names for a minute; nothing was changed."
}

# What runs on the Mac, as `bash -s -- <on|off|status> [seconds]`. The record is the hold's
# pid, the seconds it was started for and when they end. It is this script's to end only
# while its time is not up and the pid is still that very command: a pid alone, or any
# caffeinate, can be another's by then.
there='
what="$1" seconds="${2-}"
cache="$HOME/Library/Caches/topo-validate"
held() {
  pid="$(sed -n 1p "$cache/awake" 2>/dev/null)"
  secs="$(sed -n 2p "$cache/awake" 2>/dev/null)"
  ends="$(sed -n 3p "$cache/awake" 2>/dev/null)"
  [ -n "$pid" ] && [ -n "$secs" ] && [ -n "$ends" ] && [ "$ends" -gt "$(date +%s)" ] \
    && [ "$(ps -o args= -p "$pid" 2>/dev/null)" = "/usr/bin/caffeinate -dimsu -t $secs" ]
}
release() { if held; then kill "$pid" 2>/dev/null; fi; rm -f "$cache/awake"; }
case "$what" in
  on)
    sessions="$(ioreg -n Root -d1 2>/dev/null | tr "}" "\n" || true)"
    mine="$(grep -F "\"kCGSSessionUserNameKey\"=\"$(id -un)\"" <<<"$sessions" || true)"
    case "$mine" in
      *"\"CGSSessionScreenIsLocked\"=Yes"*) open=no ;;
      *"\"kCGSSessionOnConsoleKey\"=Yes"*) open=yes ;;
      *) open=no ;;
    esac
    if [ "$open" = no ]; then
      echo "error: on $(hostname -s) the session of $(id -un) is locked, or is not the one on the screen; unlock it there, then run this again." >&2
      exit 76
    fi
    mkdir -p "$cache" || exit 1
    release
    nohup /usr/bin/caffeinate -dimsu -t "$seconds" > /dev/null 2>&1 &
    printf "%s\n%s\n%s\n" "$!" "$seconds" "$(($(date +%s) + seconds))" > "$cache/awake"
    ;;
  off) release ;;
  status)
    if held; then
      left=$((ends - $(date +%s)))
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
    case "$hours" in [1-9] | [1-9][0-9]) ;; *) die "'$hours' is not a number of hours: 1 to $MAX_HOURS." ;; esac
    [ "$hours" -le "$MAX_HOURS" ] || die "$hours hours is more than $MAX_HOURS."
    alone
    status=0
    ssh_to "$host" bash -s -- on "$((hours * 3600))" <<<"$there" || status=$?
    case "$status" in
      0) ;;
      76) exit 1 ;;
      *)
        # It may have been started there before the connection went: asked to end, once.
        ssh_to "$host" bash -s -- off <<<"$there" 2>/dev/null || true
        die "$host was not reached, or the connection did not last (ssh exited $status); it is not named."
        ;;
    esac
    if ! is_named "$host"; then
      # After a last line that has no newline of its own, on a line of its own.
      [ ! -s "$cache/hosts" ] || [ -z "$(tail -c 1 "$cache/hosts")" ] || echo >> "$cache/hosts"
      echo "$host" >> "$cache/hosts"
    fi
    echo "$host is named in $cache/hosts and held awake and unlocked for $hours hours; a closed lid still sleeps it. \`$0 off $host\` ends both."
    ;;
  off)
    host="${2-}"
    check_name "$host"
    alone
    unname "$host"
    if ssh_to "$host" bash -s -- off <<<"$there"; then
      echo "$host is no longer named, and the hold this started there is ended."
    else
      echo "$host is no longer named; it was not reached, so the hold this started there ends by itself when its hours are up."
    fi
    ;;
  status)
    [ -n "$(named)" ] || { echo "No Mac is named in $cache/hosts."; exit 0; }
    named | while IFS= read -r host; do
      case "$host" in *[!A-Za-z0-9._-]* | -*) echo "$host: not a host"; continue ;; esac
      echo "$host: $(ssh_to "$host" bash -s -- status <<<"$there" 2>/dev/null || echo "not reached")"
    done
    ;;
  *) usage ;;
esac
