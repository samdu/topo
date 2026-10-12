#!/usr/bin/env bash
# scripts/validate-host.sh, against a fake `ssh` that runs what it is given in a scratch home
# and a fake `ioreg` that says whether the screen there is locked. The `caffeinate` is the
# real one, for an hour at most and ended by the test: `on` names the Mac and holds it awake;
# again, it starts the hours afresh with one line in the file; a locked or unreached Mac is not
# named; `off` takes the name out, leaves the file's other lines, and ends what held it.
#
#   scripts/tests/validate-host-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../validate-host.sh"
work="$(mktemp -d -t validate-host-test)"
started=()
cleanup() {
  local pid
  for pid in ${started[@]+"${started[@]}"}; do
    [ "$(ps -o comm= -p "$pid" 2>/dev/null | sed 's|.*/||')" != caffeinate ] || kill "$pid" 2>/dev/null
  done
  rm -rf "$work"
}
trap cleanup EXIT
unset FAKE_LOCKED FAKE_UNREACHABLE

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }
is() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', wanted '$3': $out"; fi; }

mkdir -p "$work/bin"
cat > "$work/bin/ssh" <<'SSH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
host="$1"; shift
[ "${FAKE_UNREACHABLE-}" != "$host" ] || exit 255
mkdir -p "$FAKE_HOSTS/$host"
cd "$FAKE_HOSTS/$host" && HOME="$FAKE_HOSTS/$host" exec bash -c "$*"
SSH
cat > "$work/bin/ioreg" <<'IOREG'
#!/usr/bin/env bash
echo "    \"IOConsoleUsers\" = ({\"kCGSSessionOnConsoleKey\"=No,\"CGSSessionScreenIsLocked\"=Yes},{\"kCGSSessionOnConsoleKey\"=Yes${FAKE_LOCKED:+,\"CGSSessionScreenIsLocked\"=Yes}})"
IOREG
chmod +x "$work/bin/ssh" "$work/bin/ioreg"
export FAKE_HOSTS="$work/hosts" TOPO_VALIDATE_CACHE="$work/cache"

run() { out="$(PATH="$work/bin:$PATH" "$script" "$@" 2>&1)" && status=0 || status=$?; }
awake() { sed -n 1p "$FAKE_HOSTS/$1/Library/Caches/topo-validate/awake" 2>/dev/null; }
alive() { [ "$(ps -o comm= -p "${1:-0}" 2>/dev/null | sed 's|.*/||')" = caffeinate ]; }
lines() { grep -cx "$1" "$TOPO_VALIDATE_CACHE/hosts" 2>/dev/null || true; }

run on laptop 1
first="$(awake laptop)"; started+=("$first")
is "on: exits 0" "$status" 0
is "on: named" "$(lines laptop)" 1
alive "$first" && ok "on: held awake" || fail "on: nothing holds it awake: $out"
case "$out" in *"closed lid still sleeps it"*) ok "on: the lid is said" ;; *) fail "on: $out" ;; esac
run status
case "$out" in *"laptop: held awake and unlocked for "[01]" h "*" min more"*) ok "status: held, and for how long" ;; *) fail "status: $out" ;; esac

run on laptop 1
second="$(awake laptop)"; started+=("$second")
is "on again: exits 0" "$status" 0
is "on again: named once" "$(lines laptop)" 1
alive "$first" && fail "on again: the first hold is still there" || ok "on again: the first hold is ended"
alive "$second" && ok "on again: held afresh" || fail "on again: nothing holds it awake"

FAKE_LOCKED=1 run on locked 1
is "a locked Mac: exits 1" "$status" 1
is "a locked Mac: not named" "$(lines locked)" 0
is "a locked Mac: nothing started there" "$(awake locked)" ""
case "$out" in *"unlock it there"*) ok "a locked Mac: it is said" ;; *) fail "a locked Mac: $out" ;; esac
FAKE_UNREACHABLE=away run on away 1
is "a Mac not reached: exits 2" "$status" 2
is "a Mac not reached: not named" "$(lines away)" 0
for bad in "on lap;top" "on -laptop" "on laptop 0" "on laptop 13" "on laptop soon" "on" "off" "sideways laptop"; do
  # shellcheck disable=SC2086
  run $bad
  is "'$bad': exits 2" "$status" 2
done
is "nothing bad was named" "$(wc -l < "$TOPO_VALIDATE_CACHE/hosts" | tr -d ' ')" 1

printf '# the den\nother\n' >> "$TOPO_VALIDATE_CACHE/hosts"
run off laptop
is "off: exits 0" "$status" 0
is "off: no longer named" "$(lines laptop)" 0
is "off: the file's other lines are left" "$(tr '\n' '|' < "$TOPO_VALIDATE_CACHE/hosts")" "# the den|other|"
alive "$second" && fail "off: it is still held awake" || ok "off: what held it is ended"
[ ! -e "$FAKE_HOSTS/laptop/Library/Caches/topo-validate/awake" ] && ok "off: no record left there" || fail "off: the record is still there"
# A pid that is no longer a caffeinate is nobody's to end.
perl -e 'sleep 60' & stray=$!
mkdir -p "$FAKE_HOSTS/other/Library/Caches/topo-validate"
printf '%s\n%s\n' "$stray" 0 > "$FAKE_HOSTS/other/Library/Caches/topo-validate/awake"
run off other
kill -0 "$stray" 2>/dev/null && ok "off: a pid that is not a caffeinate is left alone" || fail "off: another process was ended"
kill "$stray" 2>/dev/null; wait "$stray" 2>/dev/null
is "off: the last name out, the comment left" "$(tr '\n' '|' < "$TOPO_VALIDATE_CACHE/hosts")" "# the den|"
run status
case "$out" in *"No Mac is named"*) ok "status: a file of comments names nobody" ;; *) fail "status: $out" ;; esac

[ "$failures" = 0 ] && echo "all passed" || { echo "$failures failure(s)"; exit 1; }
