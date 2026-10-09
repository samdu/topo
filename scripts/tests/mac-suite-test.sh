#!/usr/bin/env bash
# Holds scripts/mac-suite.sh's own control flow in a scratch tree: the real script beside fakes
# of every script it calls, with fake xcodebuild, xcodegen, swift, xcrun, nm and sw_vers ahead
# of the real ones on PATH. Each fake logs its call. A signal to this test is waited on until
# the scratch run it has going is over, and only then is the tree removed: a run outliving its
# fakes would find the real tools behind them.
#
# What it holds: the audio lane is stopped after a `start` that failed and after a signal while
# `start` was under way, and is left alone when `start` refused because another run's lane is
# up; a suite whose test run fails is `failure` in suites.txt with the suites after it still
# run; a toolchain off its pin runs no suite and fails each one asked for; a signal while the
# lane's start is refusing another run's lane leaves that lane alone; and a signal ends the
# command the run is waiting on, a bounded one included.
#
#   scripts/tests/mac-suite-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../.."
work="$(mktemp -d -t mac-suite-test)"
running=""
finish() {
  if [ -n "$running" ]; then
    kill "$running" 2>/dev/null
    rm -f "$work"/*.hold
    wait "$running" 2>/dev/null
  fi
  rm -rf "$work"
}
trap finish EXIT
# Deferred by bash until the scratch run in the foreground has ended.
trap 'exit 143' TERM INT HUP

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }
is() {  # is <case> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', wanted '$3'"; fi
}

tree="$work/tree"
mkdir -p "$tree/scripts" "$tree/Womble" "$work/bin"
cp "$root/scripts/mac-suite.sh" "$tree/scripts/"

# fake <path> <body> — a script that logs its name and arguments, then runs the body.
fake() {
  { echo '#!/usr/bin/env bash'; echo "echo \"$(basename "$1") \$*\" >> \"\$CALLS\""; echo "$2"; } > "$1"
  chmod +x "$1"
}
# Waits, on a marker holding its own pid, for as long as the case wants a command to be running.
hold='if [ -n "${HOLD-}" ]; then echo $$ > "$HOLD"; while [ -e "$HOLD" ]; do perl -e "select(undef,undef,undef,0.1)"; done; fi'
fake "$tree/scripts/ci-audio-lane.sh" '
case "$1" in
  start) [ "${HOLD_AT-}" != lane ] || { '"$hold"'; }; exit "${LANE_START:-0}" ;;
  *) exit 0 ;;
esac'
fake "$tree/scripts/build-ish.sh" 'exit 0'
fake "$tree/scripts/ci-require-tests.sh" 'exit 0'
fake "$tree/scripts/check-built-plist.sh" 'exit 0'
fake "$tree/scripts/fetch-pinned.sh" 'echo "$2"'
fake "$tree/scripts/fetch-ear-models.sh" 'exit 0'
fake "$tree/scripts/model-manifest.sh" 'exit 0'
fake "$work/bin/xcodebuild" '
case "$*" in
  -version) echo "Xcode ${FAKE_XCODE:-26.6}"; echo "Build version 1" ;;
  *test-without-building*-only-testing:TopoUITests*) exit "${UI_TEST:-0}" ;;
  *) exit 0 ;;
esac'
fake "$work/bin/xcodegen" 'case "$1" in --version) echo "Version: 2.46.0" ;; esac'
fake "$work/bin/swift" '[ "${HOLD_AT-}" != swift ] || [ "$1" != test ] || { '"$hold"'; }; exit 0'
fake "$work/bin/sw_vers" 'exit 0'
# The simulator's own record of the photos grant: the row as the suite leaves it, or as simctl does.
fake "$work/bin/sqlite3" 'case "$2" in select*) echo "${PHOTOS_GRANT:-2|2}" ;; esac'
fake "$work/bin/nm" 'for s in ish_mem_refresh_hook ish_dns_sentinel_port topo_ish_set_dns_port; do echo "0 T _$s"; done'
fake "$work/bin/xcrun" '
case "$1 $2" in
  "simctl list") echo "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-26-5\":[{\"name\":\"iPhone 1\",\"deviceTypeIdentifier\":\"type.iPhone\"}],\"com.apple.CoreSimulator.SimRuntime.watchOS-26-5\":[{\"name\":\"Apple Watch 1\",\"deviceTypeIdentifier\":\"type.Watch\"}]}}" ;;
  "simctl create") echo "UDID-$3" ;;
esac'
# The scripts' own tests are not this test's to run again: each is a fake that passes.
mkdir -p "$tree/scripts/tests"
for name in $(sed -n '/^  for test in /,/; do$/p' "$root/scripts/mac-suite.sh" | tr -d '\\' | sed 's/^ *for test in//; s/; do$//'); do
  fake "$tree/scripts/tests/$name-test.sh" 'exit 0'
done
for package in TopoAuth TopoCore TopoLink TopoMascot TopoProxy TopoTurn; do
  mkdir -p "$tree/Packages/$package" && : > "$tree/Packages/$package/Package.swift"
done

# suite <case> [suite...] — runs the scratch mac-suite.sh; its exit in $status, its calls in $CALLS.
suite() {
  local name="$1"; shift
  export CALLS="$work/$name.calls" RESULTS_DIR="$work/$name.results"
  : > "$CALLS"
  (cd "$tree" && PATH="$work/bin:$PATH" scripts/mac-suite.sh --lane fast --results "$RESULTS_DIR" --cache "$work/cache" "$@") \
    > "$work/$name.log" 2>&1 && status=0 || status=$?
}
calls() { grep -c "^$1" "$CALLS"; }
results() { tr '\n' ' ' < "$RESULTS_DIR/suites.txt"; }

# Green: every suite, the lane started and stopped once, each simulator deleted.
suite green topo_unit topo_ui others
is "green: exits 0" "$status" 0
is "green: every suite a success" "$(results)" "topo_unit=success topo_ui=success others=success "
is "green: the lane is started once" "$(calls 'ci-audio-lane.sh start')" 1
is "green: and stopped" "$(calls 'ci-audio-lane.sh stop')" 1
is "green: every simulator made is deleted" "$(calls 'xcrun simctl delete')" "$(calls 'xcrun simctl create')"

# A start that failed may have pinned the devices and left a feeder: it is stopped.
LANE_START=1 suite lane-failed topo_ui
is "lane start failed: exits 1" "$status" 1
is "lane start failed: topo_ui is a failure" "$(results)" "topo_ui=failure "
is "lane start failed: the lane is stopped" "$(calls 'ci-audio-lane.sh stop')" 1
is "lane start failed: no test ran" "$(calls 'xcodebuild test-without-building')" 0

# A start that refused found another run's lane: not this run's to stop.
LANE_START=3 suite lane-theirs topo_ui
is "another run's lane: exits 1" "$status" 1
is "another run's lane: left alone" "$(calls 'ci-audio-lane.sh stop')" 0

# A red test run: that suite is a failure, the lane is still stopped, the next suite still runs.
UI_TEST=1 suite ui-red topo_ui others
is "red UI run: exits 1" "$status" 1
is "red UI run: topo_ui failed, others ran and passed" "$(results)" "topo_ui=failure others=success "
is "red UI run: the lane is stopped" "$(calls 'ci-audio-lane.sh stop')" 1

# A photos grant that is not full access would put a prompt up under the tests: no test runs.
PHOTOS_GRANT="2|1" suite photos-grant topo_unit
is "photos grant not full access: exits 1" "$status" 1
is "photos grant not full access: topo_unit is a failure" "$(results)" "topo_unit=failure "
is "photos grant not full access: no test ran" "$(calls 'xcodebuild test-without-building')" 0

# A toolchain off its pin: no suite runs, and each one asked for is a failure.
FAKE_XCODE=99.0 suite off-pin topo_unit others
is "off the pin: exits 1" "$status" 1
is "off the pin: each suite a failure" "$(results)" "topo_unit=failure others=failure "
is "off the pin: nothing built or tested" "$(grep -c '^xcodebuild .*\(build\|test\)' "$CALLS")" 0

# signalled <case> <where> <suite> — starts the run, waits for it to reach the held command, sends
# it a TERM by the pid it recorded, and waits for it to end. The held command's marker is $HOLD.
signalled() {
  local name="$1" pid
  export HOLD="$work/$name.hold" HOLD_AT="$2"
  CALLS="$work/$name.calls" RESULTS_DIR="$work/$name.results"
  export CALLS RESULTS_DIR
  : > "$CALLS"
  (cd "$tree" && PATH="$work/bin:$PATH" exec scripts/mac-suite.sh --lane fast --results "$RESULTS_DIR" --cache "$work/cache" "$3") \
    > "$work/$name.log" 2>&1 &
  pid=$!
  running=$pid
  for _ in $(seq 300); do [ -s "$HOLD" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
  [ -s "$HOLD" ] || fail "$name: the run never reached the held command"
  held="$(cat "$HOLD" 2>/dev/null)"
  is "$name: the run's pid is the first on record" "$(sed -n 1p "$RESULTS_DIR/mac-suite.pids" 2>/dev/null)" "$pid"
  kill -TERM "$pid"
  # A command the run is waiting on under `run` ends it at once. One it called in the foreground
  # (the lane's start) is waited out by bash before the trap runs, so that one is let finish.
  for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
  if kill -0 "$pid" 2>/dev/null; then waited=yes; rm -f "$HOLD"; else waited=no; fi
  wait "$pid"; status=$?
  running=""
  unset HOLD HOLD_AT
}

# A signal while the lane is starting: the start is waited out, and the lane it left is stopped.
signalled lane-signal lane topo_ui
is "signal during the lane's start: exits 143" "$status" 143
is "signal during the lane's start: the lane is stopped" "$(calls 'ci-audio-lane.sh stop')" 1
rm -f "$work/lane-signal.hold"

# The same signal while the start is refusing another run's lane: that lane is left alone.
LANE_START=3 signalled lane-signal-theirs lane topo_ui
is "signal during a start that refuses: exits 143" "$status" 143
is "signal during a start that refuses: the other run's lane is left alone" "$(calls 'ci-audio-lane.sh stop')" 0
rm -f "$work/lane-signal-theirs.hold"

# A signal while a bounded command runs: the command itself ends, not a shell left waiting on it,
# and the simulators the run made are deleted.
signalled bounded-signal swift others
is "signal during a bounded command: exits 143" "$status" 143
is "signal during a bounded command: ends without waiting the command out" "$waited" no
if [ -z "$held" ] || kill -0 "$held" 2>/dev/null; then
  fail "signal during a bounded command: pid $held outlived the run"
  kill "$held" 2>/dev/null
else
  ok "signal during a bounded command: the command ended with the run"
fi
rm -f "$work/bounded-signal.hold"
is "signal during a bounded command: its pids file is gone" "$([ -e "$work/bounded-signal.results/mac-suite.pids" ] && echo there || echo gone)" gone

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
