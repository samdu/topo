#!/usr/bin/env bash
# Holds scripts/ci-audio-lane.sh to one lane at a time, with no audio device: brew, sudo and
# SwitchAudioSource are fakes (the last keeps the two defaults in a file), and a fake swiftc
# builds a feeder that only writes the heartbeat and a meter that always hears the fixture. The
# script runs from a checkout whose path has a space in it. A second start refuses with exit 3
# and leaves the first lane running, its log, saved defaults and devices untouched; a start that
# arrives while another is held inside start refuses; a pid file naming a live process that is
# not the recorded supervisor refuses nothing; stop leaves nothing of its lane behind and puts
# the defaults back; and after the pid file of a running lane is lost and a second lane started,
# stop names the first lane's feeder and supervisor by pid and leaves them running. macOS only:
# the script locks with lockf(1).
#
#   scripts/tests/ci-audio-lane-test.sh
#   SCRIPT=/path/to/other/ci-audio-lane.sh scripts/tests/ci-audio-lane-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(cd "$(mktemp -d)" && pwd -P)"
checkout="$work/a checkout"
lane="$checkout/scripts/ci-audio-lane.sh"
state="$work/audio-lane"
mkdir -p "$checkout/scripts" "$work/bin"
cp "${SCRIPT:-$here/../ci-audio-lane.sh}" "$lane"
echo fixture > "$work/fixture.wav"

# Every pid a start under test recorded, so that whatever a failed case leaves is killed by pid;
# and any feeder built under $work with its supervisor, which a start that should have refused
# leaves unrecorded.
started=()
cleanup() {
  for pid in ${started[@]+"${started[@]}"}; do kill "$pid" 2>/dev/null; done
  ps -axwwo pid=,ppid=,comm= | while read -r pid parent executable; do
    [ "$executable" != "$state/ci-audio-feeder" ] || { [ "$parent" = 1 ] || kill "$parent"; kill "$pid"; } 2>/dev/null
  done
  rm -rf "$work"
}
trap cleanup EXIT

printf '#!/bin/sh\nexit 0\n' > "$work/bin/sudo"
# brew is where a start can be held: while $work/hold exists it says it has arrived and waits,
# for at most 30 s, for the file to go.
cat > "$work/bin/brew" <<FAKE
#!/bin/sh
[ -e "$work/hold" ] || exit 0
touch "$work/arrived"
for _ in \$(seq 300); do [ -e "$work/hold" ] || exit 0; sleep 0.1; done
FAKE
# The Mac's two defaults, in $work/input and $work/output.
printf 'Fake Microphone\n' > "$work/input"; printf 'Fake Speakers\n' > "$work/output"
cat > "$work/bin/SwitchAudioSource" <<FAKE
#!/bin/sh
# SwitchAudioSource -c -t <type> | -a -t <type> | -t <type> -s <device>
case "\$1" in
  -c) cat "$work/\$3" ;;
  -a) printf 'BlackHole 2ch\n'; cat "$work/\$3" ;;
  -t) printf '%s\n' "\$4" > "$work/\$2"; echo "\$2 audio device set to \"\$4\"" ;;
esac
FAKE
cat > "$work/bin/swiftc" <<'FAKE'
#!/bin/sh
# swiftc -O <source> -o <binary>
case "$2" in
  *ci-audio-feeder.swift)
    cc -x c - -o "$4" <<'C'
#include <stdio.h>
#include <time.h>
#include <unistd.h>
int main(int argc, char **argv) {
  char path[4096];
  snprintf(path, sizeof path, "%s/heartbeat", argv[2]);
  for (;;) {
    FILE *f = fopen(path, "w");
    if (f) { fprintf(f, "%ld\n", (long)time(0)); fclose(f); }
    usleep(500000);
  }
}
C
    ;;
  *) printf '#!/bin/sh\necho "auth=3 rms=0.1000 peak=0.5000"\n' > "$4"; chmod +x "$4" ;;
esac
FAKE
chmod +x "$work/bin/"*

run() { PATH="$work/bin:$PATH" RUNNER_TEMP="$work" "$lane" "$@"; }
alive() { kill -0 "$1" 2>/dev/null; }
# Record the lane the pid files name, in `supervisor` and `feeder`.
record() {
  supervisor="$(cat "$state/supervisor.pid")"; feeder="$(cat "$state/feeder.pid")"
  started+=("$supervisor" "$feeder")
}

failures=0
hold() {
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; failures=$((failures + 1)); fi
}

# A second start refuses, and the first lane is as it was.
run start "$work/fixture.wav" > "$work/first.out" 2>&1; status=$?
hold "start: exits 0" [ "$status" = 0 ]
record; first_supervisor="$supervisor"; first_feeder="$feeder"
run start "$work/fixture.wav" > "$work/second.out" 2>&1; status=$?
hold "second start: exits 3" [ "$status" = 3 ]
hold "second start: names the running supervisor" grep -q "supervisor $first_supervisor is running" "$work/second.out"
hold "second start: the pid file still names the first supervisor" [ "$(cat "$state/supervisor.pid")" = "$first_supervisor" ]
hold "second start: the first supervisor and feeder still run" eval 'alive "$first_supervisor" && alive "$first_feeder"'
run check "after the refused start" > "$work/check.out" 2>&1
hold "second start: the first lane still holds" [ "$?" = 0 ]

# What a refused start must not touch: the log, the saved defaults, the devices.
snapshot() { cat "$state/feeder.log" "$state/previous-defaults" "$work/input" "$work/output"; }
echo "a line the first lane logged" >> "$state/feeder.log"
before="$(snapshot)"
hold "start saved the defaults it found" [ "$(cat "$state/previous-defaults")" = "Fake Microphone
Fake Speakers" ]
run start "$work/fixture.wav" > /dev/null 2>&1
hold "refused start: the log, saved defaults and devices are as they were" [ "$(snapshot)" = "$before" ]

# Stop leaves nothing of its lane.
run stop > "$work/stop.out" 2>&1; status=$?
hold "stop: exits 0" [ "$status" = 0 ]
hold "stop: the supervisor and feeder are gone" eval '! alive "$first_supervisor" && ! alive "$first_feeder"'
hold "stop: warns of neither" eval '! grep -Eq "::warning::.*( |r )($first_supervisor|$first_feeder)[ )]" "$work/stop.out"'
hold "stop: the defaults start found are back" [ "$(cat "$work/input" "$work/output")" = "Fake Microphone
Fake Speakers" ]

# A start that arrives while another is held inside start, before it has a supervisor, refuses.
touch "$work/hold"
run start "$work/fixture.wav" > "$work/held.out" 2>&1 & held=$!
for _ in $(seq 100); do [ -e "$work/arrived" ] && break; sleep 0.1; done
hold "overlapping start: the first is held inside start" [ -e "$work/arrived" ]
hold "overlapping start: the first has no supervisor yet" [ ! -s "$state/supervisor.pid" ]
run start "$work/fixture.wav" > "$work/overlap.out" 2>&1; status=$?
hold "overlapping start: the second exits 3 (got $status)" [ "$status" = 3 ]
hold "overlapping start: the second says another start holds the lock" grep -q "is being started by another" "$work/overlap.out"
rm "$work/hold"
wait "$held"; status=$?
hold "overlapping start: the first exits 0 (got $status)" [ "$status" = 0 ]
record
# ps is read before grep runs, so grep's own command line is not in it.
processes="$(ps -axwwo pid=,command=)"
supervisors="$(grep -cF "$lane supervise " <<< "$processes")"
hold "overlapping start: one supervisor runs (got $supervisors)" [ "$supervisors" = 1 ]
run stop > /dev/null 2>&1

# A pid file left naming a pid that now belongs to something else refuses nothing.
sleep 300 & bystander=$!
started+=("$bystander")
echo "$bystander" > "$state/supervisor.pid"
echo "Thu Jan  1 00:00:00 1970" > "$state/supervisor.started"
run start "$work/fixture.wav" > "$work/recycled.out" 2>&1; status=$?
hold "recycled pid: start exits 0 (got $status)" [ "$status" = 0 ]
record
run stop > /dev/null 2>&1
echo "$bystander" > "$state/supervisor.pid"
echo "Thu Jan  1 00:00:00 1970" > "$state/supervisor.started"
run stop > /dev/null 2>&1; status=$?
hold "recycled pid: stop exits 0 (got $status)" [ "$status" = 0 ]
hold "recycled pid: stop does not kill the bystander" alive "$bystander"
kill "$bystander" 2>/dev/null

# A lane whose pid file was lost is named by stop, by pid, and left running.
run start "$work/fixture.wav" > /dev/null 2>&1
record; lost_supervisor="$supervisor"; lost_feeder="$feeder"
rm "$state/supervisor.pid"
run start "$work/fixture.wav" > /dev/null 2>&1; status=$?
hold "start after the pid file is lost: exits 0" [ "$status" = 0 ]
record; second_supervisor="$supervisor"; second_feeder="$feeder"
run stop > "$work/orphan.out" 2>&1; status=$?
hold "stop with an orphan: exits 0" [ "$status" = 0 ]
hold "stop with an orphan: its own supervisor and feeder are gone" eval '! alive "$second_supervisor" && ! alive "$second_feeder"'
hold "stop with an orphan: warns of the orphaned feeder and its supervisor by pid" grep -q "::warning::audio lane: feeder $lost_feeder (supervisor $lost_supervisor) is still running" "$work/orphan.out"
hold "stop with an orphan: warns of nothing it stopped" eval '! grep -q "feeder $second_feeder " "$work/orphan.out"'
hold "stop with an orphan: leaves both running" eval 'alive "$lost_supervisor" && alive "$lost_feeder"'

if [ "$failures" -gt 0 ]; then
  for out in "$work"/*.out; do echo "--- $out"; cat "$out"; done
  echo "$failures failed"
  exit 1
fi
echo "all passed"
