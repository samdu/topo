#!/usr/bin/env bash
# Holds scripts/ci-audio-lane.sh to one lane at a time, with no audio device: brew, sudo and
# SwitchAudioSource are fakes, and a fake swiftc builds a feeder that only writes the heartbeat
# and a meter that always hears the fixture. The script runs from a checkout whose path has a
# space in it. A second start refuses with exit 3 and leaves the first lane running; of two
# starts at once exactly one wins; stop leaves nothing of its lane behind; and after the pid file
# of a running lane is lost and a second lane started, stop names the first lane's supervisor and
# feeder by pid and leaves them running. macOS only: the script locks with lockf(1).
#
#   scripts/tests/ci-audio-lane-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(cd "$(mktemp -d)" && pwd -P)"
checkout="$work/a checkout"
lane="$checkout/scripts/ci-audio-lane.sh"
state="$work/audio-lane"
mkdir -p "$checkout/scripts" "$work/bin"
cp "$here/../ci-audio-lane.sh" "$lane"
echo fixture > "$work/fixture.wav"

# Every pid a start under test recorded, so that whatever a failed case leaves is killed by pid.
started=()
trap 'for pid in ${started[@]+"${started[@]}"}; do kill "$pid" 2>/dev/null; done; rm -rf "$work"' EXIT

for fake in brew sudo; do printf '#!/bin/sh\nexit 0\n' > "$work/bin/$fake"; done
cat > "$work/bin/SwitchAudioSource" <<'FAKE'
#!/bin/sh
case " $* " in
  *" -s "*) echo "audio device set" ;;
  *) echo "BlackHole 2ch" ;;
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

# Stop leaves nothing of its lane.
run stop > "$work/stop.out" 2>&1; status=$?
hold "stop: exits 0" [ "$status" = 0 ]
hold "stop: the supervisor and feeder are gone" eval '! alive "$first_supervisor" && ! alive "$first_feeder"'
hold "stop: warns of neither" eval '! grep -Eq "::warning::.* ($first_supervisor|$first_feeder) " "$work/stop.out"'

# Two starts at once: one wins, the other refuses.
run start "$work/fixture.wav" > "$work/race-a.out" 2>&1 & a=$!
run start "$work/fixture.wav" > "$work/race-b.out" 2>&1 & b=$!
wait "$a"; status_a=$?
wait "$b"; status_b=$?
record
hold "two starts at once: one exits 0 and one exits 3 (got $status_a and $status_b)" eval '[ "$status_a$status_b" = 03 ] || [ "$status_a$status_b" = 30 ]'
# ps is read before grep runs, so grep's own command line is not in it.
processes="$(ps -axwwo pid=,command=)"
supervisors="$(grep -cF "$lane supervise " <<< "$processes")"
hold "two starts at once: one supervisor runs (got $supervisors)" [ "$supervisors" = 1 ]
run stop > /dev/null 2>&1

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
hold "stop with an orphan: warns of the orphaned supervisor by pid" grep -q "::warning::audio lane: supervisor $lost_supervisor is still running" "$work/orphan.out"
hold "stop with an orphan: warns of the orphaned feeder by pid" grep -q "::warning::audio lane: feeder $lost_feeder is still running" "$work/orphan.out"
hold "stop with an orphan: leaves both running" eval 'alive "$lost_supervisor" && alive "$lost_feeder"'

if [ "$failures" -gt 0 ]; then
  for out in "$work"/*.out; do echo "--- $out"; cat "$out"; done
  echo "$failures failed"
  exit 1
fi
echo "all passed"
