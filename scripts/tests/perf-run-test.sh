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
[ "$fail" = 0 ] && echo "perf-run-test: ok"
exit "$fail"
