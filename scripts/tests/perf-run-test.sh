#!/bin/bash
# scripts/perf-run.sh refuses what it could never count, before it reaches a phone.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
expect() { # <status> <args...>
  local want="$1"; shift
  env -u TOPO_PERF_DEVICE scripts/perf-run.sh "$@" >/dev/null 2>&1
  local got=$?
  [ "$got" = "$want" ] || { echo "FAIL: perf-run.sh $* exited $got, wanted $want"; fail=1; }
}
expect 2 --device none
expect 2 --device none '' 'hello'
expect 2 --device none '   '
expect 2 'hello'

# A copy that brings back the last run's finished file is not taken for this run's: the script
# waits for a file whose first mark is this launch's. xcrun is a stand-in that serves a stale
# file on the first copy and this run's on the second.
fake="$(mktemp -d -t perf-run-test)"
trap 'rm -rf "$fake"' EXIT
cat > "$fake/xcrun" <<'FAKE'
#!/bin/bash
case "$*" in
  *"copy from"*)
    while [ $# -gt 0 ]; do [ "$1" = --destination ] && to="$2"; shift; done
    n=$(( $(cat "$FAKE_DIR/copies" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/copies"
    if [ "$n" = 1 ]; then
      printf 'mark t=1000 app.init.begin\nmark t=2000 perf.run.done answered=1/1\n' > "$to"
    else
      now=$(python3 -c 'import time; print(int(time.time() * 1000))')
      printf 'mark t=%s app.init.begin\nmark t=%s perf.run.done answered=0/1\n' "$now" "$now" > "$to"
    fi ;;
esac
FAKE
chmod +x "$fake/xcrun"
FAKE_DIR="$fake" PATH="$fake:$PATH" scripts/perf-run.sh --device fake --timeout 60 --out "$fake/marks.txt" 'hello' >/dev/null 2>&1
got=$?
[ "$got" = 4 ] || { echo "FAIL: a stale marks file was taken for this run's (exit $got, wanted 4)"; fail=1; }
[ "$(cat "$fake/copies" 2>/dev/null)" = 2 ] || { echo "FAIL: the stale file ended the wait"; fail=1; }

[ "$fail" = 0 ] && echo "perf-run-test: ok"
exit "$fail"
