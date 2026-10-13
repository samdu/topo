#!/usr/bin/env bash
# scripts/validate-host.sh, against a fake `ssh` that runs what it is given in a scratch home
# and a fake `ioreg` that says whose session is on the screen there and whether it is locked.
# The `caffeinate` is the real one, for an hour at most, and every one started is ended by the
# test. `on` names the Mac and holds it with the very command the script says; again, it
# starts the hours afresh with one name in the file; a Mac that is locked, on another user's
# screen or not reached is not named, and none is asked anything for a name or hours that are
# not; two at once leave one hold, which `off` ends; `off` takes the name out wherever on a
# line it stands, leaves the rest, and ends no process but the hold on record.
#
#   scripts/tests/validate-host-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../validate-host.sh"
work="$(mktemp -d -t validate-host-test)"
export FAKE_HOSTS="$work/hosts" TOPO_VALIDATE_CACHE="$work/cache" SSH_CALLS="$work/ssh.calls" STARTED="$work/started"
: > "$SSH_CALLS"; : > "$STARTED"
# Every hold a case started, whatever became of its record: the fake `nohup` notes each.
cleanup() {
  local pid
  while IFS= read -r pid; do
    case "$(ps -o args= -p "$pid" 2>/dev/null)" in "/usr/bin/caffeinate -dimsu -t "*) kill "$pid" 2>/dev/null ;; esac
  done < "$STARTED"
  rm -rf "$work"
}
trap cleanup EXIT
unset FAKE_LOCKED FAKE_AWAY FAKE_UNREACHABLE FAKE_DROP

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', wanted '$3': $out"; fi; }

mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<'SSH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
host="$1"; shift
echo "$host $*" >> "$SSH_CALLS"
[ "${FAKE_UNREACHABLE-}" != "$host" ] || exit 255
mkdir -p "$FAKE_HOSTS/$host"
cd "$FAKE_HOSTS/$host" || exit 255
# A connection that goes once the Mac has done what it was asked.
case "${FAKE_DROP-}:$*" in 1:*" on "*) HOME="$FAKE_HOSTS/$host" bash -c "$*"; exit 255 ;; esac
HOME="$FAKE_HOSTS/$host" exec bash -c "$*"
SSH
# Two sessions: another user's, and this one's, which is on the screen unless FAKE_AWAY.
cat > "$work/bin/ioreg" <<'IOREG'
#!/usr/bin/env bash
if [ -n "${FAKE_AWAY-}" ]; then theirs=Yes mine=No; else theirs=No mine=Yes; fi
echo "    \"IOConsoleUsers\" = ({\"kCGSSessionOnConsoleKey\"=$theirs,\"kCGSSessionUserNameKey\"=\"another\"},{\"kCGSSessionOnConsoleKey\"=$mine,\"kCGSSessionUserNameKey\"=\"$(id -un)\"${FAKE_LOCKED:+,\"CGSSessionScreenIsLocked\"=Yes}})"
IOREG
# The real one, with the pid it becomes on a list this test ends.
cat > "$work/bin/nohup" <<'NOHUP'
#!/usr/bin/env bash
echo $$ >> "$STARTED"
exec /usr/bin/nohup "$@"
NOHUP
chmod +x "$work/bin/ssh" "$work/bin/ioreg" "$work/bin/nohup"

run() { out="$(PATH="$work/bin:$PATH" "$script" "$@" 2>&1)" && status=0 || status=$?; }
awake() { sed -n 1p "$FAKE_HOSTS/$1/Library/Caches/topo-validate/awake" 2>/dev/null; }
args() { ps -o args= -p "${1:-0}" 2>/dev/null; }
# A hold just started is `nohup` for a moment before it is the command: waited for, two seconds.
settled() {
  local n=0
  while [ "$n" -lt 20 ] && case "$(args "$1")" in *nohup*) true ;; *) false ;; esac; do
    perl -e 'select(undef,undef,undef,0.1)'; n=$((n + 1))
  done
}
holds() { ps -axo args= | grep -c '^/usr/bin/caffeinate -dimsu -t 3600$' || true; }
file() { tr '\n' '|' < "$TOPO_VALIDATE_CACHE/hosts" 2>/dev/null; }
before="$(holds)"

run on laptop 1
first="$(awake laptop)"
settled "$first"
is "on: exits 0" "$status" 0
is "on: named" "$(file)" "laptop|"
is "on: held by the command it says, for the hour asked" "$(args "$first")" "/usr/bin/caffeinate -dimsu -t 3600"
case "$out" in *"closed lid still sleeps it"*) ok "on: the lid is said" ;; *) fail "on: $out" ;; esac
run status
case "$out" in "laptop: held awake and unlocked for "[01]" h "*" min more") ok "status: held, and for how long" ;; *) fail "status: $out" ;; esac

run on laptop 1
second="$(awake laptop)"
settled "$second"
is "on again: exits 0" "$status" 0
is "on again: named once" "$(file)" "laptop|"
is "on again: the first hold is ended" "$(args "$first")" ""
is "on again: held afresh" "$(args "$second")" "/usr/bin/caffeinate -dimsu -t 3600"

FAKE_LOCKED=1 run on locked 1
is "a locked Mac: exits 1" "$status" 1
is "a locked Mac: not named" "$(file)" "laptop|"
is "a locked Mac: nothing started there" "$(awake locked)" ""
case "$out" in *"unlock it there"*) ok "a locked Mac: it is said" ;; *) fail "a locked Mac: $out" ;; esac
FAKE_AWAY=1 run on away 1
is "another user's session on the screen: exits 1" "$status" 1
is "another user's session on the screen: nothing started there" "$(awake away)" ""
FAKE_UNREACHABLE=gone run on gone 1
is "a Mac not reached: exits 2" "$status" 2
is "a Mac not reached: not named" "$(file)" "laptop|"
FAKE_DROP=1 run on dropped 1
is "a connection that went: exits 2" "$status" 2
is "a connection that went: not named" "$(file)" "laptop|"
is "a connection that went: what it started there is ended" "$(holds)" "$((before + 1))"
: > "$SSH_CALLS"
for bad in "on lap;top" "on -laptop" "on laptop 0" "on laptop 00" "on laptop 08" "on laptop 010" "on laptop 13" "on laptop soon" "on" "off" "off -laptop" "sideways laptop"; do
  # shellcheck disable=SC2086
  run $bad
  is "'$bad': exits 2" "$status" 2
done
is "a name or hours that are not: no Mac was asked anything" "$(wc -l < "$SSH_CALLS" | tr -d ' ')" 0
is "a name or hours that are not: nothing named" "$(file)" "laptop|"

# Two at once: one hold, one name, and `off` ends it.
run off laptop
PATH="$work/bin:$PATH" "$script" on twin 1 > /dev/null 2>&1 &
one=$!
PATH="$work/bin:$PATH" "$script" on twin 1 > /dev/null 2>&1 &
two=$!
wait "$one" "$two"
is "two at once: one hold" "$(holds)" "$((before + 1))"
is "two at once: named once" "$(file)" "twin|"
run off twin
is "two at once, then off: no hold left" "$(holds)" "$before"

# The name wherever it stands in the file, and nothing else of the file.
printf 'other' > "$TOPO_VALIDATE_CACHE/hosts"
run on laptop 1
is "after a last line with no newline: on a line of its own" "$(file)" "other|laptop|"
printf 'laptop2 # not laptop\n' > "$TOPO_VALIDATE_CACHE/hosts"
run on laptop 1
is "a name inside another, and in a comment: neither is it" "$(file)" "laptop2 # not laptop|laptop|"
printf 'laptop   # the den\nmacXlocal laptop\n# a note\nmac.local\n' > "$TOPO_VALIDATE_CACHE/hosts"
run on laptop 1
is "named on a line with a comment already: not named again" "$(file)" "laptop   # the den|macXlocal laptop|# a note|mac.local|"
held="$(awake laptop)"
settled "$held"
run off laptop
is "off: exits 0" "$status" 0
is "off: out of every line it was on, the rest left" "$(file)" "# the den|macXlocal|# a note|mac.local|"
is "off: the hold is ended" "$(args "$held")" ""
[ ! -e "$FAKE_HOSTS/laptop/Library/Caches/topo-validate/awake" ] && ok "off: no record left there" || fail "off: the record is still there"
run off mac.local
is "off: a dot in a name is a dot" "$(file)" "# the den|macXlocal|# a note|"
run status
case "$out" in "macXlocal: not held awake") ok "status: a Mac named and not held" ;; *) fail "status: $out" ;; esac
run off macXlocal
is "off: the last name out, the comments left" "$(file)" "# the den|# a note|"
run status
case "$out" in *"No Mac is named"*) ok "status: a file of comments names nobody" ;; *) fail "status: $out" ;; esac

# A record is the script's to end only while it is that command, inside its hours.
mkdir -p "$FAKE_HOSTS/stale/Library/Caches/topo-validate"
/usr/bin/caffeinate -i -t 120 & stray=$!
printf '%s\n%s\n%s\n' "$stray" 3600 "$(($(date +%s) + 3600))" > "$FAKE_HOSTS/stale/Library/Caches/topo-validate/awake"
run off stale
is "off: another caffeinate under a recorded pid is left alone" "$(args "$stray")" "/usr/bin/caffeinate -i -t 120"
kill "$stray" 2>/dev/null; wait "$stray" 2>/dev/null
/usr/bin/caffeinate -dimsu -t 3600 & old=$!
echo "$old" >> "$STARTED"
perl -e 'select(undef,undef,undef,0.3)'
printf '%s\n%s\n%s\n' "$old" 3600 "$(($(date +%s) - 60))" > "$FAKE_HOSTS/stale/Library/Caches/topo-validate/awake"
run off stale
is "off: a record whose hours are up ends nothing" "$(args "$old")" "/usr/bin/caffeinate -dimsu -t 3600"
kill "$old" 2>/dev/null; wait "$old" 2>/dev/null
is "nothing this test started is left" "$(holds)" "$before"

[ "$failures" = 0 ] && echo "all passed" || { echo "$failures failure(s)"; exit 1; }
