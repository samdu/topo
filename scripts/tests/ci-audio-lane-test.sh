#!/usr/bin/env bash
# Holds scripts/ci-audio-lane.sh to one lane at a time, with no audio device: brew, sudo and
# SwitchAudioSource are fakes (the last keeps the two defaults in a file), and a fake swiftc
# builds a feeder that only writes the heartbeat and a meter that always hears the fixture. The
# script runs from a checkout whose path has a space in it. A second start refuses with exit 3
# and leaves the first lane running, its log, saved defaults and devices untouched; a start that
# arrives while another is held inside start refuses; a pid file naming a live process that is
# not the recorded supervisor refuses nothing; stop leaves nothing of its lane behind and puts
# the defaults back; and after the pid file of a running lane is lost and a second lane started,
# stop names the first lane's feeder and supervisor by pid and leaves them running; a silent input
# names the missing microphone grant when the meter reports auth=0, and only then. The --talk
# recipe in docs/simulator.md, run as written against a fake ssh and tmux, exits 1 naming the
# desktop session when no tmux server is running and never starts one, waits for the run whether
# its signal comes before or after the wait, exits with --talk's status and the end of its log when
# that is not 0 and 0 when it is, and answers each of two overlapping runs with its own status. macOS only: the script locks
# with lockf(1).
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

# A silent input says why when the meter's process holds no microphone grant (auth=0, a shell
# started over ssh), and only then.
run start "$work/fixture.wav" > /dev/null 2>&1
record
cp "$state/ci-audio-meter" "$work/meter.hears"
printf '#!/bin/sh\necho "auth=0 rate=48000 buffers=30 frames=144000 rms=0.0000 peak=0.0000"\n' > "$state/ci-audio-meter"
run check "before" > "$work/ungranted.out" 2>&1; status=$?
hold "ungranted meter: check exits 1 (got $status)" [ "$status" = 1 ]
hold "ungranted meter: names the missing grant and tmux" grep -q "auth=0 is a process that holds no microphone grant.*tmux server" "$work/ungranted.out"
printf '#!/bin/sh\necho "auth=3 rate=48000 buffers=30 frames=144000 rms=0.0000 peak=0.0000"\n' > "$state/ci-audio-meter"
run check "before" > "$work/granted-silent.out" 2>&1; status=$?
hold "granted, silent meter: check exits 1 (got $status)" [ "$status" = 1 ]
hold "granted, silent meter: says nothing of a grant" eval '! grep -q "microphone grant" "$work/granted-silent.out"'
cp "$work/meter.hears" "$state/ci-audio-meter"
run stop > /dev/null 2>&1

# The --talk recipe, as docs/simulator.md writes it with a UDID put in. ssh runs the string in a
# shell under a fake home. The fake tmux logs every call and, unless $talk/no-server exists, keeps
# tmux's order: new-window returns at once and its command runs behind it, `wait-for -S` marks the
# channel signalled whether or not anyone waits yet, and `wait-for` returns once it is (30 s at
# most). TALK_SLEEP holds --talk back, so its signal comes after the wait; WAIT_SLEEP holds the
# wait back, so the signal comes first. No verb of the fake starts a server.
doc="${DOC:-$here/../../docs/simulator.md}"
recipe="$(awk '/^ssh buddybox .*talk/ { on = 1 } on && /^```/ { exit } on' "$doc" | sed 's/<udid>/a-udid/g')"
talk="$work/talk"; talk_home="$talk/home"
mkdir -p "$talk/bin" "$talk/channels" "$talk_home/github/topo/scripts"
cat > "$talk/bin/ssh" <<FAKE
#!/bin/sh
shift
HOME="$talk_home" PATH="$talk/bin:\$PATH" exec bash -c "\$1"
FAKE
cat > "$talk/bin/tmux" <<FAKE
#!/bin/sh
echo "\$*" >> "$talk/calls"
if [ -e "$talk/no-server" ]; then
  echo "error connecting to /private/tmp/tmux-501/default (No such file or directory)" >&2; exit 1
fi
case "\$1" in
  new-window) for last; do :; done; (cd "$talk_home" && sh -c "\$last") > /dev/null 2>&1 & ;;
  wait-for)
    if [ "\$2" = -S ]; then touch "$talk/channels/\$3"; exit 0; fi
    sleep "\${WAIT_SLEEP:-0}"
    for _ in \$(seq 300); do [ -e "$talk/channels/\$2" ] && { rm "$talk/channels/\$2"; exit 0; }; sleep 0.1; done
    echo "fake tmux: \$2 was never signalled" >&2; exit 1 ;;
  *) echo "fake tmux: \$1 is not a verb the recipe uses" >&2; exit 1 ;;
esac
FAKE
cat > "$talk_home/github/topo/scripts/simulator-run.sh" <<'FAKE'
#!/bin/sh
sleep "${TALK_SLEEP:-0}"
echo "talk: run $TALK_EXIT's own reason"
exit "${TALK_EXIT:-0}"
FAKE
chmod +x "$talk/bin/ssh" "$talk/bin/tmux" "$talk_home/github/topo/scripts/simulator-run.sh"
talk() { : > "$talk/calls"; PATH="$talk/bin:$PATH" bash -c "$recipe"; }
hold "talk recipe: found in docs/simulator.md" eval '[ -n "$recipe" ]'

touch "$talk/no-server"
talk > "$work/talk-no-server.out" 2>&1; status=$?
rm "$talk/no-server"
hold "talk, no tmux server: exits 1 (got $status)" [ "$status" = 1 ]
hold "talk, no tmux server: relays tmux's error" grep -q "error connecting to" "$work/talk-no-server.out"
hold "talk, no tmux server: names the desktop session" grep -q "no tmux server running: start it from the desktop session" "$work/talk-no-server.out"
hold "talk, no tmux server: calls nothing that starts one" eval '! grep -qE "^(new-session|new|start-server|start)( |$)" "$talk/calls"'
hold "talk, no tmux server: runs nothing" eval '! ls "$talk_home/github/topo/build"/*.log > /dev/null 2>&1'

TALK_EXIT=7 TALK_SLEEP=1 talk > "$work/talk-fails.out" 2>&1; status=$?
hold "talk, --talk fails after the wait began: exits with its status (got $status)" [ "$status" = 7 ]
hold "talk, --talk fails after the wait began: says so" grep -q -- "--talk exited 7" "$work/talk-fails.out"
hold "talk, --talk fails after the wait began: prints the run's reason" grep -q "talk: run 7's own reason" "$work/talk-fails.out"

TALK_EXIT=5 WAIT_SLEEP=1 talk > "$work/talk-fails-early.out" 2>&1; status=$?
hold "talk, --talk fails before the wait began: exits with its status (got $status)" [ "$status" = 5 ]

TALK_EXIT=0 TALK_SLEEP=1 talk > "$work/talk-passes.out" 2>&1; status=$?
hold "talk, --talk passes: exits 0 (got $status)" [ "$status" = 0 ]
hold "talk, --talk passes: reports no failure" eval '! grep -q "exited" "$work/talk-passes.out"'
hold "talk: never calls new-session" eval '! grep -q "new-session" "$talk/calls"'

# Two runs at once: the second's failure, signalled while the first still runs, is not the
# first's answer.
TALK_EXIT=0 TALK_SLEEP=3 talk > "$work/talk-first.out" 2>&1 &
first=$!
sleep 1
TALK_EXIT=3 talk > "$work/talk-second.out" 2>&1; second_status=$?
wait "$first"; first_status=$?
hold "talk, overlapping runs: the second exits with its own status (got $second_status)" [ "$second_status" = 3 ]
hold "talk, overlapping runs: the first exits with its own status (got $first_status)" [ "$first_status" = 0 ]

if [ "$failures" -gt 0 ]; then
  for out in "$work"/*.out; do echo "--- $out"; cat "$out"; done
  echo "$failures failed"
  exit 1
fi
echo "all passed"
