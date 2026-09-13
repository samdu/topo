#!/usr/bin/env bash
# The microphone test's input-capable lane on a hosted macOS runner: BlackHole (a virtual
# loopback device; CI tooling, never bundled) as the default input and output, and the test
# fixture playing into it for the rest of the job, which is what the simulator's microphone
# hears. CI only: it installs a driver and changes the Mac's default audio devices.
#
#   scripts/ci-audio-lane.sh start          # install, pin, and start the supervised feeder
#   scripts/ci-audio-lane.sh check <when>   # fail, naming what died, unless the lane still holds
#
# The feeder is a supervised loop rather than a bare `afplay` loop. Every pass it re-pins
# BlackHole as the default input and output (afplay plays to whatever the default output is
# when it starts), logging the devices it found instead when they had moved; writes a
# heartbeat; and runs one play of the fixture under a watchdog, so a hung afplay is killed and
# logged rather than leaving a live process playing nothing. `check` holds that the feeder's
# process is alive, its heartbeat is fresh, and both defaults are BlackHole, and prints every
# drift or hang the log recorded. It never makes a silent lane pass: the UI test still asserts
# the fixture's energy at the tap.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
device="BlackHole 2ch"
fixture="$root/Tests/Fixtures/purple-elephants.wav"
state="${RUNNER_TEMP:-/tmp}/audio-lane"
pidfile="$state/feeder.pid"
heartbeat="$state/heartbeat"
log="$state/feeder.log"
# One pass is a 2.9 s play plus the re-pin; a heartbeat older than this is a feeder that stopped.
stale_after=20

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

feed() {
  while true; do
    input="$(SwitchAudioSource -c -t input 2>&1 || true)"
    output="$(SwitchAudioSource -c -t output 2>&1 || true)"
    if [ "$input" != "$device" ] || [ "$output" != "$device" ]; then
      echo "$(now) drift: default input \"$input\", output \"$output\"; re-pinned to $device" >> "$log"
      SwitchAudioSource -t input -s "$device" >/dev/null 2>&1 || echo "$(now) could not re-pin the input" >> "$log"
      SwitchAudioSource -t output -s "$device" >/dev/null 2>&1 || echo "$(now) could not re-pin the output" >> "$log"
    fi
    date +%s > "$heartbeat"
    afplay "$fixture" &
    player=$!
    for _ in $(seq 60); do
      kill -0 "$player" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$player" 2>/dev/null; then
      kill -9 "$player" 2>/dev/null || true
      echo "$(now) afplay hung past 6 s and was killed" >> "$log"
    fi
    status=0
    wait "$player" 2>/dev/null || status=$?
    # 137 is the watchdog's own kill, already logged.
    if [ "$status" != 0 ] && [ "$status" != 137 ]; then
      echo "$(now) afplay exited $status" >> "$log"
    fi
  done
}

start() {
  mkdir -p "$state"
  : > "$log"
  brew install --quiet blackhole-2ch switchaudio-osx
  sudo killall coreaudiod
  for _ in $(seq 30); do
    SwitchAudioSource -a -t input | grep -qx "$device" && break
    sleep 1
  done
  SwitchAudioSource -t input -s "$device"
  SwitchAudioSource -t output -s "$device"
  test "$(SwitchAudioSource -c -t input)" = "$device"
  test "$(SwitchAudioSource -c -t output)" = "$device"
  nohup "$0" feed >/dev/null 2>&1 &
  echo $! > "$pidfile"
  for _ in $(seq 20); do
    [ -s "$heartbeat" ] && break
    sleep 0.5
  done
  check started
}

check() {
  when="${1:-now}"
  failures=()
  if [ ! -s "$pidfile" ]; then
    failures+=("the feeder was never started (no $pidfile)")
  elif ! kill -0 "$(cat "$pidfile")" 2>/dev/null; then
    failures+=("the feeder process $(cat "$pidfile") is dead")
  fi
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
  if [ -s "$log" ]; then
    while IFS= read -r line; do echo "::warning::audio lane: $line"; done < "$log"
  fi
  if [ "${#failures[@]}" -gt 0 ]; then
    for failure in "${failures[@]}"; do
      echo "::error::audio lane dead $when the microphone test: $failure"
    done
    exit 1
  fi
  echo "audio lane holds $when the microphone test: feeder $(cat "$pidfile") alive, heartbeat ${age} s old, input and output $device"
}

case "${1:-}" in
  start) start ;;
  feed) feed ;;
  check) check "${2:-now}" ;;
  *) sed -n '2,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
