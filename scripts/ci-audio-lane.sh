#!/usr/bin/env bash
# The microphone test's input-capable lane on a hosted macOS runner: BlackHole (a virtual
# loopback device; CI tooling, never bundled) as the default input and output, and the test
# fixture playing into it for the rest of the job, which is what the simulator's microphone
# hears. It installs a driver and changes the Mac's default audio devices: the CI runner's, and
# buddybox's for `scripts/simulator-run.sh --talk`, which stops it after the run.
#
#   scripts/ci-audio-lane.sh start [fixture]  # install, pin, and start the supervised feeder
#                                             # (default Tests/Fixtures/purple-elephants.wav)
#   scripts/ci-audio-lane.sh check <when>     # fail, naming what died, unless the lane still holds
#   scripts/ci-audio-lane.sh stop             # stop the feeder, restore the defaults start found
#
# The feeder (scripts/ci-audio-feeder.swift) is one long-lived engine that loops the fixture
# into the default output and listens to the default input in the same process; it restarts
# itself on three seconds of silence or a device change, and logs each restart. It runs under a
# loop that restarts it if it exits. `check` holds that the supervisor is alive, the feeder's
# heartbeat is fresh, both defaults are BlackHole, and that a separate meter
# (scripts/ci-audio-meter.swift) hears the fixture on BlackHole's input; it prints the feeder's
# log, with every restart or exit as a warning. It never makes a silent lane pass: the UI test
# still asserts the fixture's energy at the tap.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device="BlackHole 2ch"
state="${RUNNER_TEMP:-/tmp}/audio-lane"
pidfile="$state/supervisor.pid"
feederpid="$state/feeder.pid"
# The default input and output before start pinned BlackHole, one per line, for stop.
previous="$state/previous-defaults"
heartbeat="$state/heartbeat"
log="$state/feeder.log"
feeder="$state/ci-audio-feeder"
meter="$state/ci-audio-meter"
# The feeder writes a heartbeat every half second.
stale_after=10
# Over three seconds the looping fixture measures about 0.05 to 0.12 RMS; silence is 0.
audible=0.01

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

supervise() {
  fixture="$1"
  while true; do
    status=0
    "$feeder" "$fixture" "$state" &
    echo $! > "$feederpid"
    wait $! || status=$?
    echo "$(now) the feeder exited $status; restarting it" >> "$log"
    sleep 1
  done
}

start() {
  fixture="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  [ -f "$fixture" ] || { echo "no fixture at $1" >&2; exit 1; }
  mkdir -p "$state"
  : > "$log"
  brew install --quiet blackhole-2ch switchaudio-osx
  swiftc -O "$root/scripts/ci-audio-feeder.swift" -o "$feeder"
  swiftc -O "$root/scripts/ci-audio-meter.swift" -o "$meter"
  { SwitchAudioSource -c -t input 2>/dev/null || true; SwitchAudioSource -c -t output 2>/dev/null || true; } > "$previous"
  # A driver just installed is not a device until coreaudiod reloads its plug-ins.
  SwitchAudioSource -a -t input | grep -qx "$device" || sudo killall coreaudiod
  for _ in $(seq 30); do
    SwitchAudioSource -a -t input | grep -qx "$device" && break
    sleep 1
  done
  SwitchAudioSource -t input -s "$device"
  SwitchAudioSource -t output -s "$device"
  test "$(SwitchAudioSource -c -t input)" = "$device"
  test "$(SwitchAudioSource -c -t output)" = "$device"
  nohup "$0" supervise "$fixture" >/dev/null 2>&1 &
  echo $! > "$pidfile"
  for _ in $(seq 20); do
    [ -s "$heartbeat" ] && break
    sleep 0.5
  done
  sleep 3
  check started
}

check() {
  when="${1:-now}"
  failures=()
  if [ ! -s "$pidfile" ]; then
    failures+=("the feeder was never started (no $pidfile)")
  elif ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    failures+=("the feeder's supervisor $(cat "$pidfile") is dead")
  fi
  age="?"
  if [ ! -s "$heartbeat" ]; then
    failures+=("the feeder never wrote a heartbeat")
  else
    age=$(( $(date +%s) - $(cat "$heartbeat") ))
    [ "$age" -le "$stale_after" ] || failures+=("the feeder's last heartbeat was ${age} s ago")
  fi
  input="$(SwitchAudioSource -c -t input 2>&1 || true)"
  output="$(SwitchAudioSource -c -t output 2>&1 || true)"
  [ "$input" = "$device" ] || failures+=("the default input is \"$input\", not $device")
  [ "$output" = "$device" ] || failures+=("the default output is \"$output\", not $device")
  heard="no meter"
  if [ -x "$meter" ]; then
    heard="$("$meter" 3 2>&1 | tail -1)"
    rms="$(printf '%s\n' "$heard" | sed -nE 's/.* rms=([0-9.]+).*/\1/p')"
    if [ -z "$rms" ] || ! awk -v r="$rms" -v t="$audible" 'BEGIN { exit !(r >= t) }'; then
      failures+=("$device's input is silent over 3 s ($heard)")
    fi
  else
    failures+=("the meter was never built ($meter)")
  fi
  if [ -s "$log" ]; then
    while IFS= read -r line; do
      case "$line" in
        *restart*|*exited*|*"did not start"*|*"no format"*|*"could not"*) echo "::warning::audio lane: $line" ;;
        *) echo "audio lane: $line" ;;
      esac
    done < "$log"
  fi
  if [ "${#failures[@]}" -gt 0 ]; then
    for failure in "${failures[@]}"; do
      echo "::error::audio lane dead $when the microphone test: $failure"
    done
    exit 1
  fi
  echo "audio lane holds $when the microphone test: supervisor $(cat "$pidfile") alive, heartbeat ${age} s old, input and output $device, $heard"
}

# The supervisor first, so it restarts nothing, then the feeder; then the defaults start found.
stop() {
  for file in "$pidfile" "$feederpid"; do
    [ -s "$file" ] || continue
    pid="$(cat "$file")"
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    if kill -0 "$pid" 2>/dev/null; then echo "error: $pid ($file) is still running" >&2; exit 1; fi
    rm -f "$file"
  done
  if [ -s "$previous" ]; then
    { read -r input; read -r output; } < "$previous"
    # A Mac with no input of its own had no default before; with BlackHole installed it stays
    # the only input and so the default, which no switch can undo.
    if [ -n "$input" ]; then SwitchAudioSource -t input -s "$input"; else echo "there was no default input before start; BlackHole remains the only input"; fi
    if [ -n "$output" ]; then SwitchAudioSource -t output -s "$output"; else echo "no default output to restore"; fi
    rm -f "$previous"
  fi
  echo "audio lane stopped: input \"$(SwitchAudioSource -c -t input 2>&1 || true)\", output \"$(SwitchAudioSource -c -t output 2>&1 || true)\""
}

case "${1:-}" in
  start) start "${2:-$root/Tests/Fixtures/purple-elephants.wav}" ;;
  supervise) supervise "$2" ;;
  check) check "${2:-now}" ;;
  stop) stop ;;
  *) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
