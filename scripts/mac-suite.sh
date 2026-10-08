#!/usr/bin/env bash
# The PR check's Mac suites, run against the checkout this script is in. No hosted runner runs
# them: scripts/validate-and-push.sh runs this on buddybox at the commit being pushed and posts
# each suite's result to the PR as a commit status, which pr-validate.yaml's `test` job reads.
#
#   scripts/mac-suite.sh [--lane fast|full] [--results <dir>] [--cache <dir>] <suite>...
#
# The suites, by the names scripts/ci-select-suites.sh selects them under:
#
#   topo_unit  the Topo scheme's test action less the UI tests: TopoTests, hosted by the iOS app,
#              and the userland package's two bundles, against the pinned rootfs, bash and
#              Claude Code.
#   topo_ui    TopoUITests behind the input-capable audio lane (scripts/ci-audio-lane.sh). The
#              full lane adds Parakeet's models and the test in which the real ear hears the
#              fixture; the fast lane deselects that test by name, so it neither runs nor skips.
#   others     the scripts' own tests, the committed manifest, the Swift packages, Womble, the
#              watch's suite, and the builds no suite hosts: the watch and TV for their own
#              simulators, a Release build for iOS devices, and the hub.
#
# Green means the named suites ran, not that nothing complained: every package and project is
# named and a missing one fails, and scripts/ci-require-tests.sh reads each result and fails on a
# target that did not run, a suite with no tests, a failure or a skip. Every suite asked for runs
# even after one fails, and within `others` every step does, so one run reports everything.
#
# --results (default build/validate) takes the logs, the result bundles and `suites.txt`, one
# `<suite>=success|failure` line per suite asked for, which is what the caller reads. It exits 0
# only when every line is `success`. --cache (default ~/Library/Caches/topo-validate) keeps the
# pinned downloads between runs.
#
# Other sessions share this Mac (CLAUDE.md, *Working here*), so each suite runs on a simulator
# this run created and deletes, this script kills nothing by name (the audio lane restarts
# coreaudiod, by name, when it has just installed its driver), and `mac-suite.pids` in --results
# lists this script's pid and then each command it is waiting on: `kill $(head -1 <file>)` ends
# the run, which stops that command, the audio lane it started and its simulators. A second
# signal while that is under way, or a SIGKILL, ends it with them left behind. The audio lane is
# one per Mac and `start` refuses a second, so two runs at once are the caller's to queue;
# validate-and-push.sh holds one lock for the whole run.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2

# The toolchain the suite is held to, so a new Xcode or runtime on the Mac cannot silently
# change what it is compiled and run with. XcodeGen's is the version the committed projects are
# generated with.
XCODE_VERSION="26.6"
IOS_SIMULATOR_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-26-5"
WATCHOS_SIMULATOR_RUNTIME="com.apple.CoreSimulator.SimRuntime.watchOS-26-5"
XCODEGEN_VERSION="2.46.0"
# The one test only the full lane runs: Parakeet hearing the fixture.
REAL_EAR_TEST="TopoUITests/MicrophonePressTests/testParakeetHearsTheFixtureThroughTheMicrophone"
SUITES=(topo_unit topo_ui others)

lane=fast
RESULTS="$root/build/validate"
cache="$HOME/Library/Caches/topo-validate"
asked=()
while [ $# -gt 0 ]; do
  case "$1" in
    --lane) lane="${2:-}"; shift 2 ;;
    --results) RESULTS="${2:-}"; shift 2 ;;
    --cache) cache="${2:-}"; shift 2 ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) asked+=("$1"); shift ;;
  esac
done
case "$lane" in full | fast) ;; *) echo "no such lane '$lane': full or fast" >&2; exit 2 ;; esac
[ "${#asked[@]}" -gt 0 ] || { echo "no suite named: one or more of ${SUITES[*]}" >&2; exit 2; }
for suite in "${asked[@]}"; do
  case " ${SUITES[*]} " in *" $suite "*) ;; *) echo "no such suite '$suite': one of ${SUITES[*]}" >&2; exit 2 ;; esac
done
[ -n "$RESULTS" ] && [ -n "$cache" ] || { echo "--results and --cache each take a directory" >&2; exit 2; }
mkdir -p "$RESULTS" "$cache" || exit 2
RESULTS="$(cd "$RESULTS" && pwd)"
export RESULTS

pids="$RESULTS/mac-suite.pids"
echo "$$" > "$pids"
: > "$RESULTS/suites.txt"
created=()
lane_started=no
current=""

cleanup() {
  [ "$lane_started" = yes ] && scripts/ci-audio-lane.sh stop
  local udid
  for udid in ${created[@]+"${created[@]}"}; do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1
    xcrun simctl delete "$udid" >/dev/null 2>&1
  done
  rm -f "$pids"
}
trap cleanup EXIT
# Only the command this run is waiting on, by the pid recorded for it.
ended() {
  [ -n "$current" ] && kill "$current" 2>/dev/null
  echo "error: mac-suite.sh was ended by a signal." >&2
  exit 143
}
trap ended TERM INT HUP

say() { printf '\n==> %s\n' "$*"; }
err() { echo "error: $*" >&2; }

# run <log> <command>... — the command in the background under `wait`, so a signal reaches the
# trap at once, with everything it prints in the log as well.
run() {
  local log="$1" status
  shift
  "$@" > >(tee "$log") 2>&1 &
  current=$!
  echo "$current" >> "$pids"
  wait "$current"
  status=$?
  current=""
  return "$status"
}

# bounded <seconds> <command>... — the command, ended by SIGALRM past its bound: a hang is a
# failure with a log, minutes in. Only ever under `run`, whose background subshell this `exec`
# replaces, so the pid `run` records and a signal reaches is the command's own and not a shell
# left waiting on it.
bounded() {
  local seconds="$1"
  shift
  exec perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$seconds" "$@"
}

# new_simulator <label> <runtime> <name prefix> — a device of this run's own, of the type of the
# first available device of that runtime by name, its udid in $udid. Deleted when the run ends.
new_simulator() {
  local type
  type="$(xcrun simctl list devices available --json | jq -r --arg rt "$2" --arg p "$3" '
    [.devices[$rt] // [] | .[] | select(.name | startswith($p))]
    | sort_by(.name) | .[0] | if . then .deviceTypeIdentifier else empty end')"
  [ -n "$type" ] || { err "no $3 simulator for $2 on this Mac."; xcrun simctl list runtimes; return 1; }
  udid="$(xcrun simctl create "topo-validate-$1-$$" "$type" "$2")" || { err "could not create a $type simulator."; return 1; }
  created+=("$udid")
  echo "Simulator: $udid ($type, $2)"
}

# What every suite needs before its own work: the pinned toolchain, the XcodeGen projects
# generated from project.yml, so a file on disk the committed project does not list is still
# compiled, and the guest's framework every Topo scheme resolves.
prepare() {
  say "Toolchain"
  [ "$(uname -m)" = arm64 ] || { err "this Mac is $(uname -m), not arm64."; return 1; }
  local xcode
  xcode="$(xcodebuild -version | head -n 1)"
  [ "$xcode" = "Xcode $XCODE_VERSION" ] || { err "this Mac's selected Xcode is '$xcode', not Xcode $XCODE_VERSION; pick the Xcode it has on purpose."; return 1; }
  sw_vers
  xcodebuild -version
  swift --version
  xcodegen --version | grep -qx "Version: $XCODEGEN_VERSION" \
    || { err "xcodegen is '$(xcodegen --version 2>&1)', not Version: $XCODEGEN_VERSION."; return 1; }

  say "Generate Xcode projects (XcodeGen)"
  xcodegen generate --spec project.yml || return 1
  (cd Womble && xcodegen generate --spec project.yml) || return 1
  # Informational: what generation changed against the committed projects. Not a gate —
  # Womble's generation reorders resource IDs.
  git status --short -- '*.xcodeproj'

  # The guest's kernel: OpenMinis/ish-arm64 at its pin with Topo's patches, never committed.
  # The script keeps a framework whose inputs stamp matches.
  say "Build the guest's framework (scripts/build-ish.sh)"
  run "$RESULTS/build-ish.log" scripts/build-ish.sh || return 1
  # The memory brake's refresh and the DNS stub's port are what the patches add and the app
  # sets: a library without them is a kernel built from the fork unpatched.
  local slice symbols symbol
  for slice in Packages/TopoUserland/Frameworks/TopoIsh.xcframework/*/libTopoIsh.a; do
    symbols="$(nm -gU "$slice")" || return 1
    for symbol in ish_mem_refresh_hook ish_dns_sentinel_port topo_ish_set_dns_port; do
      grep -q " _$symbol\$" <<< "$symbols" || { err "$slice does not export $symbol."; return 1; }
    done
  done
}

# The app targets' own suite (TopoTests), hosted by the iOS app and covering the code the watch
# and TV builds share with the phone, and the userland package's two bundles.
suite_topo_unit() {
  local status=0 udid rootfs shell claude
  unit_steps() {
    say "The rootfs, bash and Claude Code for the userland suites"
    rootfs="$(scripts/fetch-pinned.sh alpine-minirootfs "$cache/rootfs")" || return 1
    shell="$(scripts/fetch-pinned.sh alpine-bash "$cache/alpine-bash")" || return 1
    claude="$(scripts/fetch-pinned.sh claude-code "$cache/claude-code")" || return 1
    new_simulator unit "$IOS_SIMULATOR_RUNTIME" iPhone || return 1

    say "xcodebuild build-for-testing (Topo)"
    run "$RESULTS/Topo-unit-build.log" xcodebuild build-for-testing \
      -project Topo.xcodeproj -scheme Topo \
      -destination "platform=iOS Simulator,id=$udid" || return 1

    # PhoneToolsTests runs the phone tools against the simulator's own EventKit and Contacts
    # stores, which answer only with access granted. Granted here, not by a prompt, since
    # nobody is there to answer one.
    say "Boot the simulator and grant calendar, reminders and contacts access"
    xcrun simctl boot "$udid" || return 1
    xcrun simctl bootstatus "$udid" -b >/dev/null || return 1
    local service
    for service in calendar reminders contacts; do
      xcrun simctl privacy "$udid" grant "$service" zone.hexagon.topo || return 1
    done

    # The cooperative pool pinned to one thread in the test runner, as for the package suites:
    # the guest's pipes and waits block, and a block that lands on the pool hangs here rather
    # than on a phone.
    say "xcodebuild test (Topo, unit and userland)"
    rm -rf "$RESULTS/Topo-unit.xcresult"
    run "$RESULTS/Topo-unit.log" bounded 2400 env \
      "TEST_RUNNER_TOPO_USERLAND_ROOTFS=$rootfs" "TEST_RUNNER_TOPO_USERLAND_SHELL=$shell" \
      "TEST_RUNNER_TOPO_USERLAND_CLAUDE=$claude" TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 \
      xcodebuild test-without-building \
      -project Topo.xcodeproj -scheme Topo \
      -destination "platform=iOS Simulator,id=$udid" \
      -skip-testing:TopoUITests \
      -resultBundlePath "$RESULTS/Topo-unit.xcresult"
  }
  unit_steps || status=1
  # The exit codes above say nothing about a target the scheme dropped; this reads what
  # actually ran, and after a failed step reports a missing result bundle as such.
  say "Require every test target ran and passed"
  scripts/ci-require-tests.sh xcresult "$RESULTS/Topo-unit.xcresult" TopoTests TopoUserlandTests TopoUserlandBrakeTests || status=1
  return "$status"
}

# The UI tests (TopoUITests), behind the input-capable audio lane on every lane: the press tests
# over the stub and loading ears need no model, but `MicrophonePressTests` asserts buffers and
# samples reached the tap, which only a host with an input delivers.
suite_topo_ui() {
  local status=0 udid models="" lane_status
  ui_steps() {
    echo "Lane: $lane"
    # BlackHole as this Mac's default input and output, and the fixture looping into it from
    # one long-lived feeder. It starts before the simulator boots, because a simulator's audio
    # binds to the coreaudiod it booted against and the lane restarts coreaudiod.
    say "Audio loopback for the microphone test"
    # Ours to stop from the moment `start` is called, not from its success: one that fails
    # after pinning the devices, or a signal while it is under way, leaves a feeder and the
    # Mac's defaults on BlackHole, and every later lane refused. A start that refuses (exit 3)
    # found another run's lane, which is not this run's to stop.
    lane_started=yes
    scripts/ci-audio-lane.sh start
    lane_status=$?
    if [ "$lane_status" = 3 ]; then
      lane_started=no
      err "another audio lane is running on this Mac (a sibling's --talk run or validation); this one was not started. Run again once it has stopped."
      return 1
    fi
    [ "$lane_status" = 0 ] || return 1

    new_simulator ui "$IOS_SIMULATOR_RUNTIME" iPhone || return 1
    xcrun simctl boot "$udid" || return 1

    # Parakeet's models, fetched from the manifest's pinned revisions and verified file by
    # file. The full lane only.
    if [ "$lane" = full ]; then
      say "The ear's models for the microphone test"
      scripts/fetch-ear-models.sh "$cache/ear-models" || return 1
      models="$cache/ear-models"
    fi

    say "xcodebuild build-for-testing (Topo)"
    run "$RESULTS/Topo-ui-build.log" xcodebuild build-for-testing \
      -project Topo.xcodeproj -scheme Topo \
      -destination "platform=iOS Simulator,id=$udid" || return 1

    # The microphone test counts the permission prompts the run raises, and holds that there
    # is exactly one and that it is the microphone's. That count is only exact on a simulator
    # that has answered nothing, so the app's grants are cleared first and the flag tells the
    # test so.
    say "Clear Topo's privacy grants on the simulator"
    xcrun simctl bootstatus "$udid" -b >/dev/null || return 1
    xcrun simctl privacy "$udid" reset all zone.hexagon.topo || return 1

    # A lane that has died fails here by name, before and after the suite, rather than only as
    # a silent tap inside the microphone test.
    say "Audio lane holds before the microphone test"
    scripts/ci-audio-lane.sh check before || return 1

    say "xcodebuild test (Topo, UI)"
    local select=(-only-testing:TopoUITests) ui_status=0
    if [ "$lane" = fast ]; then
      select+=("-skip-testing:$REAL_EAR_TEST")
      echo "Fast lane: $REAL_EAR_TEST is deselected."
    fi
    rm -rf "$RESULTS/Topo-ui.xcresult"
    # The lane and the reset are declared to the test runner, which then fails a hold refused
    # for want of an input and holds the prompt count exact.
    local runner=(TEST_RUNNER_TOPO_UITEST_AUDIO_INPUT=1 TEST_RUNNER_TOPO_UITEST_PRIVACY_RESET=1)
    [ -z "$models" ] || runner+=("TEST_RUNNER_TOPO_UITEST_EAR_MODELS=$models")
    run "$RESULTS/Topo-ui.log" bounded 3600 env "${runner[@]}" xcodebuild test-without-building \
      -project Topo.xcodeproj -scheme Topo \
      -destination "platform=iOS Simulator,id=$udid" \
      "${select[@]}" \
      -resultBundlePath "$RESULTS/Topo-ui.xcresult" || ui_status=1

    say "Audio lane holds after the microphone test"
    scripts/ci-audio-lane.sh check after || ui_status=1
    return "$ui_status"
  }
  ui_steps || status=1
  # This Mac's default input and output go back to what `start` found.
  if [ "$lane_started" = yes ]; then
    scripts/ci-audio-lane.sh stop || status=1
    lane_started=no
  fi
  # The target as a whole; and on the full lane the real-ear test by name: the target check
  # counts test cases, and a lane that meant to run Parakeet and did not would still pass it.
  say "Require every test target ran and passed"
  scripts/ci-require-tests.sh xcresult "$RESULTS/Topo-ui.xcresult" TopoUITests || status=1
  if [ "$lane" = full ]; then
    scripts/ci-require-tests.sh named "$RESULTS/Topo-ui.xcresult" "$REAL_EAR_TEST" || status=1
  fi
  return "$status"
}

# Everything that is not the Topo scheme's suite. Every step runs after an earlier one failed.
suite_others() {
  local status=0 udid test package

  # Each script's own test, against fakes: scripts/tests/<name>-test.sh says what it holds.
  # Named, not globbed, so a test that disappears fails here.
  for test in simulator-run perf-run review-verdict ci-select-lane ci-audio-lane ci-select-suites \
              suite-gate ci-require-tests check-built-plist maps-opens-nothing build-ish \
              model-manifest review-prompt review-cap janitor validate-and-push; do
    say "scripts/tests/$test-test.sh"
    if [ ! -x "scripts/tests/$test-test.sh" ]; then
      err "scripts/tests/$test-test.sh is missing."
      status=1
    else
      run "$RESULTS/script-$test.log" "scripts/tests/$test-test.sh" || { err "scripts/tests/$test-test.sh failed."; status=1; }
    fi
  done

  # The committed manifest is what scripts/model-manifest.sh writes from its pins today: every
  # file fetched and hashed (kept in build/models), every package checked against Alpine's
  # index and closed. A hand edit of models.json, or a pin the script and the manifest
  # disagree on, fails here.
  say "The manifest is the script's"
  run "$RESULTS/model-manifest.log" scripts/model-manifest.sh --check || status=1

  # Named, not globbed: a package that disappears fails here instead of leaving the loop with
  # one fewer iteration. The cooperative pool is pinned to one thread: a task's thread is one
  # of a handful the whole process shares, so anything that blocks one stops every other task
  # too. Pinned, that is a suite that hangs rather than one that is slow on a Mac with cores to
  # hide it, and the bound turns the hang into a failure with a log.
  for package in TopoAuth TopoCore TopoLink TopoMascot TopoProxy TopoTurn; do
    say "swift test ($package)"
    if [ ! -f "Packages/$package/Package.swift" ]; then
      err "Packages/$package/Package.swift is missing."
      status=1
    elif ! LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 run "$RESULTS/$package.log" bounded 600 \
           swift test --package-path "Packages/$package" --xunit-output "$RESULTS/$package.xml"; then
      err "swift test failed in $package."
      status=1
    elif ! scripts/ci-require-tests.sh xunit "$RESULTS/$package-swift-testing.xml"; then
      status=1
    fi
  done

  # Womble is an Xcode project, not a package, so it needs a simulator rather than
  # `swift test`. Its deployment target is iOS 12.
  say "xcodebuild test (Womble)"
  rm -rf "$RESULTS/Womble.xcresult"
  if new_simulator womble "$IOS_SIMULATOR_RUNTIME" iPhone; then
    run "$RESULTS/Womble.log" bounded 1200 xcodebuild test \
      -project Womble/Womble.xcodeproj -scheme Womble \
      -destination "platform=iOS Simulator,id=$udid" \
      -resultBundlePath "$RESULTS/Womble.xcresult" || status=1
  else
    status=1
  fi
  scripts/ci-require-tests.sh xcresult "$RESULTS/Womble.xcresult" WombleTests || status=1

  # The watch and TV builds are not covered by the suite's host, so they are built for their
  # own simulators here. The watch at its deployment target, watchOS 10.0: every path above it
  # is behind an availability check, and this is where one left out fails.
  say "xcodebuild build (TopoWatch, TopoTV)"
  run "$RESULTS/TopoWatch-build.log" xcodebuild build -project Topo.xcodeproj -scheme TopoWatch \
    -destination 'generic/platform=watchOS Simulator' -derivedDataPath build/watch || status=1
  # The complications are an extension embedded in the product, and the push a background mode
  # no setting generates: both read off the built app.
  scripts/check-built-plist.sh --watch build/watch/Build/Products/Debug-watchsimulator/TopoWatch.app || status=1
  run "$RESULTS/TopoTV-build.log" xcodebuild build -project Topo.xcodeproj -scheme TopoTV \
    -destination 'generic/platform=tvOS Simulator' || status=1

  # The watch's own suite (TopoWatchTests), hosted by the watch app on a watch simulator from
  # the pinned runtime, in the watch build's derived data. Booted and finished booting before
  # the run: a watch simulator xcodebuild boots itself can still be coming up when it installs
  # the host, which then fails to launch as an unknown application. Its own bound, so a hung
  # watch simulator fails here with a log.
  say "xcodebuild test (TopoWatch)"
  rm -rf "$RESULTS/TopoWatch.xcresult"
  if new_simulator watch "$WATCHOS_SIMULATOR_RUNTIME" "Apple Watch" && xcrun simctl bootstatus "$udid" -b >/dev/null; then
    run "$RESULTS/TopoWatch-test.log" bounded 900 xcodebuild test -project Topo.xcodeproj -scheme TopoWatch \
      -destination "platform=watchOS Simulator,id=$udid" \
      -derivedDataPath build/watch \
      -resultBundlePath "$RESULTS/TopoWatch.xcresult" || status=1
  else
    status=1
  fi
  scripts/ci-require-tests.sh xcresult "$RESULTS/TopoWatch.xcresult" TopoWatchTests || status=1

  # Compilation only, with signing off. The simulator builds never compile code excluded from
  # the simulator — the Pocket engine and its model calls in Apps/Client/Voice.swift sit behind
  # `!targetEnvironment(simulator)` — and nothing else builds TopoHub, which has no test target.
  # A Release build for any iOS device and a macOS build of the hub catch compile and link
  # errors in both. They do not prove the code runs on a GPU or a device, and they do not prove
  # distribution signing: no certificate, profile or entitlement is checked with
  # CODE_SIGNING_ALLOWED=NO.
  say "xcodebuild build (Topo Release for iOS devices, TopoHub), unsigned"
  run "$RESULTS/Topo-iOS-Release-build.log" xcodebuild build -project Topo.xcodeproj -scheme Topo \
    -configuration Release -destination 'generic/platform=iOS' \
    -derivedDataPath build/device \
    CODE_SIGNING_ALLOWED=NO CURRENT_PROJECT_VERSION=999 \
    || { err "Topo Release for iOS devices failed to build."; status=1; }
  # The device build is the one product this check has, so the Info.plist is read off it: a
  # background mode declared where Xcode drops it is a process iOS suspends, and a version key
  # a build setting cannot reach is every TestFlight upload carrying the same build number. The
  # build above is given 999, the way archive-upload.sh gives it a real one.
  scripts/check-built-plist.sh build/device/Build/Products/Release-iphoneos/Topo.app 999 \
    || { err "the built app's Info.plist is wrong."; status=1; }
  run "$RESULTS/TopoHub-build.log" xcodebuild build -project Topo.xcodeproj -scheme TopoHub \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
    || { err "TopoHub failed to build."; status=1; }
  return "$status"
}

overall=0
if prepare; then
  prepared=yes
else
  prepared=no
  err "the toolchain, the projects or the guest's framework could not be prepared; no suite ran."
fi
for suite in "${SUITES[@]}"; do
  case " ${asked[*]} " in *" $suite "*) ;; *) continue ;; esac
  say "Suite: $suite"
  started=$SECONDS
  if [ "$prepared" = yes ] && "suite_$suite"; then result=success; else result=failure; overall=1; fi
  echo "$suite=$result" >> "$RESULTS/suites.txt"
  say "Suite: $suite $result in $(((SECONDS - started) / 60)) min"
done
exit "$overall"
