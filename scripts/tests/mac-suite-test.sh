#!/usr/bin/env bash
# Holds scripts/mac-suite.sh's own control flow in a scratch tree: the real script beside fakes
# of every script it calls, with fake xcodebuild, xcodegen, swift, xcrun, nm and sw_vers ahead
# of the real ones on PATH. Each fake logs its call. A signal to this test is waited on until
# the scratch run it has going is over, and only then is the tree removed: a run outliving its
# fakes would find the real tools behind them.
#
# What it holds: the audio lane is stopped after a `start` that failed and after a signal while
# `start` was under way, and is left alone when `start` refused because another run's lane is
# up, and is started with this run's pid as its owner; a suite whose test run fails is
# `failure` in suites.txt with the suites after it still run; a toolchain off its pin runs no
# suite and fails each one asked for; a signal while the lane's start is refusing another run's
# lane leaves that lane alone; a signal ends the
# command the run is waiting on, a bounded one included; and --check makes, builds and boots
# nothing, passes a Mac that has what the suites named need, and names each thing one lacks:
# the pinned Xcode, a simulator of a pinned runtime, the tools the guest's framework is built
# with when the one there is not current, room on the disk, an open lid, and, for `topo_ui`,
# being buddybox; `scripts` runs each script's test and prepares, builds and boots nothing,
# and is asked by --check for jq, node, a python3 that runs and an open lid alone; the device
# build's directory is built over for the pins it was built from and made afresh for any
# other; the port 53 holder's socket, when there is one, is handed to the unit tests; and the display is held on under `topo_ui`, by a hold that waits on the script's own
# pid and is running from before its lane starts to after it stops: one that did not start or
# took no assertion starts no lane, one that ended before the tests runs none, and one that
# ended under the tests is red.
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
# The lane notes, at its start and its stop, whether the display's hold is running then.
fake "$tree/scripts/ci-audio-lane.sh" '
held() { kill -0 "$(cat "$CALLS.hold" 2>/dev/null)" 2>/dev/null && echo "display held at $1" >> "$CALLS"; }
case "$1" in
  start) held start; echo "lane owner: $(ps -o command= -p "${AUDIO_LANE_OWNER:-0}" 2>/dev/null)" >> "$CALLS"; [ "${HOLD_AT-}" != lane ] || { '"$hold"'; }; exit "${LANE_START:-0}" ;;
  stop) held stop; exit 0 ;;
  check) [ "${FAKE_HOLD-}" != ends ] || [ "$2" != after ] || kill "$(cat "$CALLS.hold")"
    [ "${FAKE_HOLD-}" != ends-before ] || [ "$2" != before ] || kill "$(cat "$CALLS.hold")"; exit 0 ;;
  *) exit 0 ;;
esac'
fake "$tree/scripts/build-ish.sh" 'exit 0'
fake "$tree/scripts/ci-require-tests.sh" '[ "$1" != "${REQUIRE_RED-}" ]'
fake "$tree/scripts/check-built-plist.sh" 'exit 0'
fake "$tree/scripts/fetch-pinned.sh" 'echo "$2"'
fake "$tree/scripts/fetch-ear-models.sh" 'exit 0'
fake "$tree/scripts/model-manifest.sh" 'exit 0'
fake "$work/bin/xcodebuild" '
case "$*" in
  -version) echo "Xcode ${FAKE_XCODE:-27.0}"; echo "Build version 1" ;;
  *test-without-building*-only-testing:TopoUITests*)
    echo "ui flags: input=${TEST_RUNNER_TOPO_UITEST_AUDIO_INPUT-} reset=${TEST_RUNNER_TOPO_UITEST_PRIVACY_RESET-} models=${TEST_RUNNER_TOPO_UITEST_EAR_MODELS-}" >> "$CALLS"
    exit "${UI_TEST:-0}" ;;
  *test-without-building*-skip-testing:TopoUITests*)
    echo "unit port53=${TEST_RUNNER_TOPO_PORT53_SOCKET-}" >> "$CALLS"
    exit 0 ;;
  *"-derivedDataPath build/device"*) [ ! -e build/device/built ] || echo "device-build over what was there" >> "$CALLS"; : > build/device/built ;;
  *) exit 0 ;;
esac'
fake "$work/bin/xcodegen" 'case "$1" in --version) echo "Version: 2.46.0" ;; esac'
fake "$work/bin/swift" '[ "${HOLD_AT-}" != swift ] || [ "$1" != test ] || { '"$hold"'; }; exit 0'
fake "$work/bin/sw_vers" 'exit 0'
# The display's hold: it lives while the pid `-w` names does, as the real one, and says whether
# that pid is the script this run started (the script's pid is this one's parent's: the hold is
# started from the suite's own shell or a subshell of it). FAKE_HOLD=dies ends it at once, and
# FAKE_HOLD=unheld leaves it running with no assertion for `pmset` to list; FAKE_HOLD=ends is
# the lane's fake ending it once the tests have run, and FAKE_HOLD=ends-before just before them.
fake "$work/bin/caffeinate" '
[ "${FAKE_HOLD-}" != dies ] || exit 1
echo $$ > "$CALLS.hold"
at=$$
while [ "$at" -gt 1 ] && [ "$at" != "$3" ]; do at="$(ps -o ppid= -p "$at" | tr -d " ")"; done
case "$(ps -o args= -p "$3")" in *"scripts/mac-suite.sh "*) [ "$at" != "$3" ] || echo "hold waits on the script that started it" >> "$CALLS" ;; esac
while kill -0 "$3" 2>/dev/null; do perl -e "select(undef,undef,undef,0.1)"; done'
# As long as the real one's answer on a busy Mac: more after the hold's line than a pipe holds.
fake "$work/bin/pmset" '
echo "Assertion status system-wide:"
[ "${FAKE_HOLD-}" = unheld ] || echo "   pid $(cat "$CALLS.hold" 2>/dev/null)(caffeinate): [0x0] 00:00:01 PreventUserIdleDisplaySleep named: \"caffeinate command-line tool\""
for n in $(seq 20000); do echo "   pid $n(powerd): [0x0] 00:00:01 InternalPreventDisplaySleep named: \"one of many\""; done'
fake "$work/bin/xcode-select" '[ -z "${FAKE_NO_TOOLS-}" ]'
# The simulator's own record of the photos grant: the row as the suite leaves it, or as simctl does.
fake "$work/bin/sqlite3" 'case "$2" in select*) echo "${PHOTOS_GRANT:-2|2}" ;; esac'
fake "$work/bin/nm" 'for s in ish_mem_refresh_hook ish_dns_sentinel_port topo_ish_set_dns_port; do echo "0 T _$s"; done'
fake "$work/bin/osascript" 'echo "${FAKE_FREE:-60}"'
# As long as the real one's answer, the state near its head: a reader that stops early closes the pipe on it.
fake "$work/bin/fdesetup" 'echo "FileVault is ${FAKE_VAULT:-Off}."'
fake "$work/bin/ioreg" 'echo "    \"IOConsoleUsers\" = ({\"kCGSSessionOnConsoleKey\"=${FAKE_OTHER_CONSOLE:-No},\"kCGSSessionUserNameKey\"=\"another\"${FAKE_OTHER_UNLOCKED:-,\"CGSSessionScreenIsLocked\"=Yes}},{\"kCGSSessionOnConsoleKey\"=${FAKE_AWAY:-Yes},\"kCGSSessionUserNameKey\"=\"$(id -un)\"${FAKE_LOCKED:+,\"CGSSessionScreenIsLocked\"=Yes}})"; echo "    \"AppleClamshellState\" = ${FAKE_LID:-No}"; for _ in $(seq 400); do printf "%0100d\n" 0 || exit 141; done'
fake "$work/bin/brew" 'echo "${FAKE_BREW:-/nonexistent}"'
fake "$work/bin/xcrun" '
case "$1 $2" in
  "simctl list") [ -z "${FAKE_NO_RUNTIMES-}" ] || { echo "{\"devices\":{}}"; exit 0; }; echo "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[{\"name\":\"iPhone 1\",\"deviceTypeIdentifier\":\"type.iPhone\"}],\"com.apple.CoreSimulator.SimRuntime.watchOS-27-0\":[{\"name\":\"Apple Watch 1\",\"deviceTypeIdentifier\":\"type.Watch\"}]}}" ;;
  "simctl create") echo "UDID-$3" ;;
esac'
# The scripts' own tests are not this test's to run again: each is a fake that passes.
mkdir -p "$tree/scripts/tests"
for name in $(sed -n '/^ *for test in /,/; do$/p' "$root/scripts/mac-suite.sh" | tr -d '\\' | sed 's/^ *for test in//; s/; do$//'); do
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
  (cd "$tree" && TOPO_PORT53_HOLDER="${PORT53:-$work/no-holder}" PATH="$work/bin:$PATH" scripts/mac-suite.sh --lane "${LANE:-fast}" --results "$RESULTS_DIR" --cache "$work/cache" "$@") \
    > "$work/$name.log" 2>&1 && status=0 || status=$?
}
calls() { grep -c "^$1" "$CALLS"; }
results() { tr '\n' ' ' < "$RESULTS_DIR/suites.txt"; }

# Green: every suite, the lane started and stopped once, each simulator deleted.
suite green topo_unit topo_ui others
is "green: no port 53 holder here, none handed to the unit tests" "$(grep '^unit port53' "$CALLS")" "unit port53="
is "green: exits 0" "$status" 0
is "green: every suite a success" "$(results)" "topo_unit=success topo_ui=success others=success "
is "green: the lane is started once" "$(calls 'ci-audio-lane.sh start')" 1
is "green: and stopped" "$(calls 'ci-audio-lane.sh stop')" 1
is "green: the lane is started as this script's own (AUDIO_LANE_OWNER)" "$(grep -c '^lane owner: .*mac-suite\.sh' "$CALLS")" 1
is "green: the display is held on for this script's life, from before the lane starts" \
  "$(grep -E '^(caffeinate|ci-audio-lane.sh start)' "$CALLS" | sed 's/ -w [0-9]*$/ -w <pid>/' | tr '\n' '|')" "caffeinate -d -w <pid>|ci-audio-lane.sh start|"
is "green: the hold waits on the script's own pid" "$(calls 'hold waits on the script that started it')" 1
is "green: the hold is running when the lane starts and when it stops" "$(grep '^display held' "$CALLS" | tr '\n' '|')" "display held at start|display held at stop|"
hold_pid="$(cat "$CALLS.hold")"
for _ in $(seq 20); do kill -0 "$hold_pid" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
kill -0 "$hold_pid" 2>/dev/null && fail "green: the hold outlived the script" || ok "green: the hold ends with the script"
is "green: every simulator made is deleted" "$(calls 'xcrun simctl delete')" "$(calls 'xcrun simctl create')"
# Every test action, the four of them, runs without the simulator diagnostics xcodebuild
# gathers after the last test, whose log archive is the 600 s stall a run cannot end.
is "green: four test actions, each without xcodebuild's diagnostics" \
  "$(grep -cE '^xcodebuild test(-without-building)? ' "$CALLS"):$(grep -cE '^xcodebuild test(-without-building)? .* -collect-test-diagnostics never ' "$CALLS")" "4:4"

# The device build's directory is kept for the pins it was built from, and no others.
pins="$tree/Topo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
mkdir -p "$(dirname "$pins")" && echo "pins: one" > "$pins"
rm -rf "$tree/build/device"
suite device-first others
is "a first device build: exits 0" "$status" 0
is "a first device build: the pins it was built from are in it" "$(cat "$tree/build/device/Package.resolved" 2>/dev/null)" "pins: one"
suite device-same others
is "the same pins: built over what was there" "$(calls 'device-build over what was there')" 1
echo "pins: two" > "$pins"
suite device-moved others
is "pins that moved: exits 0" "$status" 0
is "pins that moved: built in a directory made afresh" "$(calls 'device-build over what was there')" 0
is "pins that moved: the new ones are in it" "$(cat "$tree/build/device/Package.resolved")" "pins: two"
rm -f "$tree/build/device/Package.resolved"
suite device-unknown others
is "a directory that says no pins: made afresh" "$(calls 'device-build over what was there')" 0
rm -f "$pins"
suite device-no-pins others
is "no pins in the tree: made afresh every time" "$(calls 'device-build over what was there')" 0
is "no pins in the tree: the build still runs" "$(calls 'xcodebuild build -project Topo.xcodeproj -scheme Topo -configuration Release')" 1
echo "pins: one" > "$pins"

# The quiet part of topo_ui: every UI class but the microphone's, with no lane, no hold, no
# models, no grants cleared and neither flag, in results of its own, which are held to have
# the target and not that class.
ui_tests() { grep '^xcodebuild test-without-building' "$CALLS"; }
# The tests' source the quiet part reads: a class that launches as it must, and the
# microphone's, which launches with the real ear and is not read.
ui_source() {  # ui_source <lines of the quiet class's second launch>
  rm -rf "$tree/Tests/ClientUI"; mkdir -p "$tree/Tests/ClientUI"
  printf '%s\n' 'final class MicrophonePressTests: XCTestCase {' '    class func setUpOnce() {}' 'let app = XCUIApplication()' 'app.launch()' '}' ${MIC_SOURCE+"$MIC_SOURCE"} \
    > "$tree/Tests/ClientUI/MicrophonePressTests.swift"
  printf '%s\n' 'let app = XCUIApplication()' 'app.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"' \
    'app.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"' 'addTeardownBlock {' "$@" '}' 'app.launch()' \
    > "$tree/Tests/ClientUI/QuietTests.swift"
}
both=('let clean = XCUIApplication()' 'clean.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"' 'clean.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"' 'clean.launch()')
ui_source "${both[@]}"
ear=TopoUITests/MicrophonePressTests/testParakeetHearsTheFixtureThroughTheMicrophone
LANE=full suite quiet topo_ui:quiet
is "the quiet part: exits 0" "$status" 0
is "the quiet part: a result of its own name" "$(results)" "topo_ui:quiet=success "
is "the quiet part: no lane" "$(calls ci-audio-lane.sh)" 0
is "the quiet part: no hold on the display" "$(calls caffeinate)" 0
is "the quiet part: no models, on the full lane too" "$(calls fetch-ear-models.sh)" 0
is "the quiet part: no grants cleared" "$(calls 'xcrun simctl privacy')" 0
is "the quiet part: one run of the tests" "$(ui_tests | wc -l | tr -d ' ')" 1
case "$(ui_tests)" in *" -only-testing:TopoUITests -skip-testing:TopoUITests/MicrophonePressTests -resultBundlePath $RESULTS_DIR/Topo-ui-quiet.xcresult") ok "the quiet part: the target less the microphone's class, and nothing else left out" ;; *) fail "the quiet part: $(ui_tests)" ;; esac
is "the quiet part: neither flag, and no models" "$(grep '^ui flags' "$CALLS")" "ui flags: input= reset= models="
is "the quiet part: the target is required of its results" "$(calls "ci-require-tests.sh xcresult $RESULTS_DIR/Topo-ui-quiet.xcresult TopoUITests\$")" 1
is "the quiet part: the microphone's class is required out of them" "$(calls "ci-require-tests.sh absent $RESULTS_DIR/Topo-ui-quiet.xcresult TopoUITests/MicrophonePressTests\$")" 1
is "the quiet part: nothing is required by name" "$(calls 'ci-require-tests.sh named')" 0
is "the quiet part: its simulator is deleted" "$(calls 'xcrun simctl delete')" "$(calls 'xcrun simctl create')"
REQUIRE_RED=absent suite quiet-has-mic topo_ui:quiet
is "the quiet part with the microphone's class in its results: a failure" "$status:$(results)" "1:topo_ui:quiet=failure "
UI_TEST=1 suite quiet-red topo_ui:quiet
is "the quiet part red: a failure" "$status:$(results)" "1:topo_ui:quiet=failure "
# A launch in a quiet class that makes the real ear or voice: no test is run, and it is named.
loud() {  # loud <case> <named> <lines of the second launch…>
  local case="$1" named="$2"; shift 2
  ui_source "$@"
  suite "quiet-$case" topo_ui:quiet
  is "the quiet part, $case: a failure, and no test run" "$status:$(results):$(ui_tests | wc -l | tr -d ' ')" "1:topo_ui:quiet=failure :0"
  case "$(cat "$work/quiet-$case.log")" in *"$named"*) ok "the quiet part, $case: the launch is named" ;; *) fail "the quiet part, $case: not named: $(tail -3 "$work/quiet-$case.log")" ;; esac
}
loud no-ear "QuietTests.swift:7: clean.launch()" 'let clean = XCUIApplication()' 'clean.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading"' 'clean.launch()'
loud no-voice "QuietTests.swift:7: clean.launch()" 'let clean = XCUIApplication()' 'clean.launchEnvironment["TOPO_DEBUG_EAR"] = "loading"' 'clean.launch()'
loud anothers-ear "QuietTests.swift:6: clean.launch()" 'let clean = XCUIApplication()' 'clean.launch()'
loud not-made-here "QuietTests.swift:5: other.launch()" 'other.launch()'
# What the source says of the environment at the launch is its last word, not its first.
loud ear-removed "QuietTests.swift:9: clean.launch()" "${both[@]:0:3}" 'clean.launchEnvironment.removeValue(forKey: "TOPO_DEBUG_EAR")' 'clean.launch()'
loud voice-removed "QuietTests.swift:9: clean.launch()" "${both[@]:0:3}" 'clean.launchEnvironment.removeValue(forKey: "TOPO_DEBUG_VOICE")' 'clean.launch()'
loud ear-set-again "QuietTests.swift:9: clean.launch()" "${both[@]:0:3}" 'clean.launchEnvironment["TOPO_DEBUG_EAR"] = "stub"' 'clean.launch()'
loud voice-set-again "QuietTests.swift:9: clean.launch()" "${both[@]:0:3}" 'clean.launchEnvironment["TOPO_DEBUG_VOICE"] = "loading" + suffix' 'clean.launch()'
loud ear-set-in-a-branch "QuietTests.swift:8: clean.launch()" 'let clean = XCUIApplication()' 'if quiet { clean.launchEnvironment["TOPO_DEBUG_EAR"] = "loading" }' "${both[2]}" 'clean.launch()'
loud replaced "QuietTests.swift:9: clean.launch()" "${both[@]:0:3}" 'clean.launchEnvironment = [:]' 'clean.launch()'
loud merged-over "QuietTests.swift:9: clean.launch()" "${both[@]:0:3}" 'clean.launchEnvironment.merge(given) { _, new in new }' 'clean.launch()'
loud key-not-literal "QuietTests.swift:9: clean.launch()" "${both[@]:0:3}" 'clean.launchEnvironment[key] = "stub"' 'clean.launch()'
# A merge ahead of the two, another key removed or set after them: the two still stand.
ui_source 'let clean = XCUIApplication()' 'clean.launchEnvironment.merge(given) { _, new in new }' "${both[@]:1:2}" \
  'clean.launchEnvironment.removeValue(forKey: "TOPO_DEBUG_TUNING")' 'if soft { clean.launchEnvironment["TOPO_DEBUG_SOFTWARE_KEYBOARD"] = "1" }' 'clean.launch()'
suite quiet-last-word-stands topo_ui:quiet
is "the quiet part, a merge ahead of the two and other keys after: runs" "$status:$(results)" "0:topo_ui:quiet=success "
# The quiet part leaves out the microphone's class and the reading its file: another class there is named.
MIC_SOURCE='final class OtherTests: XCTestCase {}' loud class-in-the-microphones-file "MicrophonePressTests.swift:6: class OtherTests" "${both[@]}"
ui_source "${both[@]}"; rm "$tree/Tests/ClientUI/QuietTests.swift"
suite quiet-no-source topo_ui:quiet
is "the quiet part with no launch to read: a failure, and no test run" "$status:$(results):$(ui_tests | wc -l | tr -d ' ')" "1:topo_ui:quiet=failure :0"
# The microphone's part and the whole suite are not held to it: the lane is theirs.
ui_source 'let clean = XCUIApplication()' 'clean.launch()'
suite mic-loud-source topo_ui:mic
is "the microphone's part over a launch with the real ear: runs" "$status:$(results)" "0:topo_ui:mic=success "
suite whole-loud-source topo_ui
is "topo_ui whole over one: runs" "$status:$(results)" "0:topo_ui=success "
ui_source "${both[@]}"

# The microphone part: that class alone, behind everything topo_ui has.
suite mic topo_ui:mic
is "the microphone part: exits 0" "$status" 0
is "the microphone part: a result of its own name" "$(results)" "topo_ui:mic=success "
is "the microphone part: the hold, then the lane" "$(grep -E '^(caffeinate|ci-audio-lane.sh start)' "$CALLS" | sed 's/ -w [0-9]*$/ -w <pid>/' | tr '\n' '|')" "caffeinate -d -w <pid>|ci-audio-lane.sh start|"
is "the microphone part: the lane is checked before and after, and stopped" "$(grep -c '^ci-audio-lane.sh check' "$CALLS"):$(calls 'ci-audio-lane.sh stop')" "2:1"
is "the microphone part: the grants are cleared" "$(calls 'xcrun simctl privacy')" 1
case "$(ui_tests)" in *" -only-testing:TopoUITests/MicrophonePressTests -skip-testing:$ear -resultBundlePath $RESULTS_DIR/Topo-ui-mic.xcresult") ok "the microphone part: its class alone, the real ear left out on the fast lane" ;; *) fail "the microphone part: $(ui_tests)" ;; esac
is "the microphone part: both flags" "$(grep '^ui flags' "$CALLS")" "ui flags: input=1 reset=1 models="
is "the microphone part: the target and the class are required of its results" "$(calls "ci-require-tests.sh xcresult $RESULTS_DIR/Topo-ui-mic.xcresult TopoUITests\$"):$(calls "ci-require-tests.sh named $RESULTS_DIR/Topo-ui-mic.xcresult TopoUITests/MicrophonePressTests\$")" "1:1"
is "the microphone part: nothing is required out" "$(calls 'ci-require-tests.sh absent')" 0
REQUIRE_RED=named suite mic-absent topo_ui:mic
is "the microphone part without its class in its results: a failure" "$status:$(results)" "1:topo_ui:mic=failure "
LANE=full suite mic-full topo_ui:mic
case "$(ui_tests)" in *" -only-testing:TopoUITests/MicrophonePressTests -resultBundlePath $RESULTS_DIR/Topo-ui-mic.xcresult") ok "the microphone part, full lane: its class whole" ;; *) fail "the microphone part, full lane: $(ui_tests)" ;; esac
is "the microphone part, full lane: the models" "$(grep '^ui flags' "$CALLS")" "ui flags: input=1 reset=1 models=$work/cache/ear-models"
is "the microphone part, full lane: the real ear is required by name" "$(calls "ci-require-tests.sh named $RESULTS_DIR/Topo-ui-mic.xcresult $ear\$")" 1

# The two parts in one call: quiet first, each its own result; and the whole suite is as it was.
suite parts topo_ui:mic topo_ui:quiet
is "both parts: quiet, then the microphone's" "$status:$(results)" "0:topo_ui:quiet=success topo_ui:mic=success "
is "both parts: one lane" "$(calls 'ci-audio-lane.sh start')" 1
suite whole topo_ui
case "$(ui_tests)" in *" -only-testing:TopoUITests -skip-testing:$ear -resultBundlePath $RESULTS_DIR/Topo-ui.xcresult") ok "topo_ui whole: the target in one run" ;; *) fail "topo_ui whole: $(ui_tests)" ;; esac
is "topo_ui whole: one result, under its own name" "$(results)" "topo_ui=success "
is "topo_ui whole: nothing is required out or by class" "$(calls 'ci-require-tests.sh absent'):$(calls 'ci-require-tests.sh named')" "0:0"
suite no-part topo_ui:loud
is "a part that is none: exits 2 and runs nothing" "$status:$(wc -l < "$CALLS" | tr -d ' ')" "2:0"

# No lane, no hold: the display is this Mac's own business under the other suites.
suite no-lane topo_unit others
is "no UI suite: the display is not held" "$(calls caffeinate)" 0

# A hold that did not start, or took no assertion: no lane, and red by name.
for broken in dies unheld; do
  FAKE_HOLD=$broken suite "hold-$broken" topo_ui
  is "a hold that $broken: exits 1" "$status" 1
  is "a hold that $broken: topo_ui is a failure" "$(results)" "topo_ui=failure "
  is "a hold that $broken: no lane is started" "$(calls 'ci-audio-lane.sh start')" 0
  grep -q 'the display could not be held on' "$work/hold-$broken.log" && ok "a hold that $broken: it is said" || fail "a hold that $broken: $(tail -3 "$work/hold-$broken.log")"
done
# One that ended under the tests: red, the lane stopped.
FAKE_HOLD=ends suite hold-ends topo_ui
is "a hold that ended under the tests: exits 1" "$status" 1
is "a hold that ended under the tests: topo_ui is a failure" "$(results)" "topo_ui=failure "
is "a hold that ended under the tests: the lane is stopped" "$(calls 'ci-audio-lane.sh stop')" 1
grep -q "the display's hold .* ended under the tests" "$work/hold-ends.log" && ok "a hold that ended under the tests: it is said" || fail "a hold that ended under the tests: $(tail -3 "$work/hold-ends.log")"
# One that ended after the lane started and before the tests: no test is run.
FAKE_HOLD=ends-before suite hold-ends-before topo_ui
is "a hold that ended before the tests: exits 1" "$status" 1
is "a hold that ended before the tests: topo_ui is a failure" "$(results)" "topo_ui=failure "
is "a hold that ended before the tests: no test is run" "$(calls 'xcodebuild test-without-building')" 0
is "a hold that ended before the tests: the lane is stopped" "$(calls 'ci-audio-lane.sh stop')" 1
grep -q "the display's hold .* ended before the tests began" "$work/hold-ends-before.log" && ok "a hold that ended before the tests: it is said" || fail "a hold that ended before the tests: $(tail -3 "$work/hold-ends-before.log")"

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

# The unit suite's simulator is booted once, the grants made on it as it first comes up, and
# shut down only as the run ends and deletes it.
suite unit-boot topo_unit
is "unit suite: exits 0" "$status" 0
is "unit suite: its simulator is booted once" "$(calls 'xcrun simctl boot ')" 1
is "unit suite: and shut down once, as the run deletes it" "$(calls 'xcrun simctl shutdown')" 1
is "unit suite: the shutdown is after the tests" "$(grep -E '^xcrun simctl shutdown|^xcodebuild test-without-building' "$CALLS" | cut -d' ' -f1-3 | tr '\n' '|')" "xcodebuild test-without-building -project|xcrun simctl shutdown|"

# A photos grant that is not full access would put a prompt up under the tests: no test runs.
PHOTOS_GRANT="2|1" suite photos-grant topo_unit
is "photos grant not full access: exits 1" "$status" 1
is "photos grant not full access: topo_unit is a failure" "$(results)" "topo_unit=failure "
is "photos grant not full access: no test ran" "$(calls 'xcodebuild test-without-building')" 0

# The scripts' tests alone: each of them, and nothing generated, built, booted or prepared,
# on a Mac whose toolchain is off its pin as on any other. `others` runs the same tests.
tests_named="$(ls "$tree/scripts/tests" | wc -l | tr -d ' ')"
FAKE_XCODE=99.0 suite scripts-alone scripts
is "scripts alone: exits 0" "$status" 0
is "scripts alone: a success" "$(results)" "scripts=success "
# The list is the directory: a test added to scripts/tests and to no list is run by nothing.
is "every test in scripts/tests is one the suite names" \
  "$(cd "$root/scripts/tests" && ls ./*-test.sh | sed 's|^\./||; s|-test\.sh$||' | sort | tr '\n' ' ')" \
  "$(sed -n '/^ *for test in /,/; do$/p' "$root/scripts/mac-suite.sh" | tr -d '\\' | sed 's/^ *for test in//; s/; do$//' | tr -s ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')"
is "scripts alone: every script's test ran" "$(grep -c -- '-test.sh' "$CALLS")" "$tests_named"
is "scripts alone: nothing generated, built, booted or prepared" "$(grep -cE '^(xcodegen|xcodebuild|xcrun|swift|build-ish\.sh|ci-audio-lane\.sh|model-manifest\.sh) ' "$CALLS")" 0
is "others: every script's test runs there too" "$(grep -c -- '-test.sh' "$work/green.calls")" "$tests_named"
fake "$tree/scripts/tests/janitor-test.sh" 'exit 1'
suite scripts-red scripts
is "a script's test red: exits 1" "$status" 1
is "a script's test red: scripts is a failure" "$(results)" "scripts=failure "
is "a script's test red: the others still ran" "$(grep -c -- '-test.sh' "$CALLS")" "$tests_named"
suite others-red others
is "a script's test red: others is a failure too" "$(results)" "others=failure "
fake "$tree/scripts/tests/janitor-test.sh" 'exit 0'
rm -f "$tree/scripts/tests/review-cap-test.sh"
suite scripts-missing scripts
is "a script's test missing: scripts is a failure" "$(results)" "scripts=failure "
fake "$tree/scripts/tests/review-cap-test.sh" 'exit 0'

# The tests run at once: two of them each wait, bounded, for the other to have started; run
# one after the other, the first would end before the second began and never see it. Each
# fake says a line of its own, and the suite's log has every one under its heading, in the
# order named: a suite that dropped a test's output, or printed it under another heading,
# would fail here.
mkdir -p "$work/meet"
named="$(sed -n '/^ *for test in /,/; do$/p' "$root/scripts/mac-suite.sh" | tr -d '\\' | sed 's/^ *for test in//; s/; do$//' | tr -s ' ' '\n' | sed '/^$/d')"
for name in $named; do fake "$tree/scripts/tests/$name-test.sh" "echo 'out of $name'; exit 0"; done
fake "$tree/scripts/tests/review-cap-test.sh" "echo 'out of review-cap'; touch '$work/meet/review-cap'; for _ in \$(seq 50); do [ -e '$work/meet/review-prompt' ] && exit 0; perl -e 'select(undef,undef,undef,0.1)'; done; exit 1"
fake "$tree/scripts/tests/review-prompt-test.sh" "echo 'out of review-prompt'; touch '$work/meet/review-prompt'; for _ in \$(seq 50); do [ -e '$work/meet/review-cap' ] && exit 0; perl -e 'select(undef,undef,undef,0.1)'; done; exit 1"
suite scripts-at-once scripts
is "the tests run at once: two that wait for each other both pass" "$status:$(results)" "0:scripts=success "
is "the tests run at once: a log of its own for each" "$(ls "$RESULTS_DIR"/script-*.log | wc -l | tr -d ' ')" "$tests_named"
is "the tests run at once: every test's line is in the suite's log under its heading, in the order named" \
  "$(grep -E '^==> scripts/tests/.*-test.sh$|^out of ' "$work/scripts-at-once.log" | tr '\n' '|')" \
  "$(for name in $named; do printf '==> scripts/tests/%s-test.sh|out of %s|' "$name" "$name"; done)"
for name in $named; do fake "$tree/scripts/tests/$name-test.sh" 'exit 0'; done

# A signal while the tests run ends every one still going and what it started: one fake is
# waiting on a child of its own, which a signal to the fake alone would leave running. The
# tests are in one process group of their own, led by a subshell of the run, and what the run
# signals it finds on bash's job table and says in the line it ends with: the one group, and
# no test by its pid, so the pid of a test that has ended, which the Mac may have given to
# another process since, is signalled by nothing.
mkdir -p "$work/sleepers"
fake "$tree/scripts/tests/janitor-test.sh" "sh -c \"echo \\\$\\\$ > '$work/sleepers/janitor.child'; exec sleep 60\" & echo \$\$ > '$work/sleepers/janitor'; wait"
fake "$tree/scripts/tests/validate-host-test.sh" "echo \$\$ > '$work/sleepers/validate-host'; exec sleep 60"
export CALLS="$work/scripts-signal.calls" RESULTS_DIR="$work/scripts-signal.results"
: > "$CALLS"
(cd "$tree" && PATH="$work/bin:$PATH" exec scripts/mac-suite.sh --lane fast --results "$RESULTS_DIR" --cache "$work/cache" scripts) \
  > "$work/scripts-signal.log" 2>&1 &
pid=$!
running=$pid
for _ in $(seq 100); do [ -s "$work/sleepers/janitor" ] && [ -s "$work/sleepers/janitor.child" ] && [ -s "$work/sleepers/validate-host" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
leaders="$(cat "$work/sleepers/janitor" "$work/sleepers/validate-host" 2>/dev/null | tr '\n' ' ')"
child="$(cat "$work/sleepers/janitor.child" 2>/dev/null)"
is "signal during the tests: both tests are on the pids file" \
  "$(for p in $leaders; do grep -cx "$p" "$RESULTS_DIR/mac-suite.pids" 2>/dev/null; done | tr '\n' ' ')" "1 1 "
group="$(ps -o pgid= -p "${leaders%% *}" 2>/dev/null | tr -d ' ')"
is "signal during the tests: the tests are in a group of their own, led by a subshell of the run that is on the pids file" \
  "$(ps -o ppid= -p "$group" 2>/dev/null | tr -d ' '):$(grep -cx "$group" "$RESULTS_DIR/mac-suite.pids" 2>/dev/null)" "$pid:1"
is "signal during the tests: both tests and the child are in that group" "$(for p in $leaders $child; do ps -o pgid= -p "$p" 2>/dev/null | tr -d ' '; done | sort -u | tr '\n' ' ')" "$group "
kill -TERM "$pid"
for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
wait "$pid"; status=$?
running=""
is "signal during the tests: exits 143" "$status" 143
for _ in $(seq 30); do alive=0; for p in $leaders $child; do kill -0 "$p" 2>/dev/null && alive=1; done; [ "$alive" = 0 ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
left=""; for p in $leaders $child; do kill -0 "$p" 2>/dev/null && { left="$left $p"; kill "$p" 2>/dev/null; }; done
[ -z "$left" ] && ok "signal during the tests: every test still going, and the child one was waiting on, ended with the run" || fail "signal during the tests: pids$left outlived the run"
is "signal during the tests: the run signalled the tests' group and nothing else" \
  "$(sed -n 's/^error: mac-suite.sh was ended by a signal; it signalled process group \(.*\)\.$/\1/p' "$work/scripts-signal.log")" "$group"
fake "$tree/scripts/tests/janitor-test.sh" 'exit 0'
fake "$tree/scripts/tests/validate-host-test.sh" 'exit 0'

# A signal that lands as soon as the first test has started, while the subshell may still be
# starting the rest and before the run has waited on anything, ends the run and everything of
# the tests' group: the first test named sends the run its signal as its first act, then sleeps.
# Where the signal lands between the subshell's start and the run's wait for it is not chosen
# here; what holds is that there is no step after the start a signal can precede, so the group
# is signalled wherever it lands.
mkdir -p "$work/early"
fake "$tree/scripts/tests/ci-audio-lane-test.sh" "echo \$\$ > '$work/early/first'; kill -TERM \"\$(sed -n 1p '$work/scripts-early.results/mac-suite.pids')\"; exec sleep 60"
export CALLS="$work/scripts-early.calls" RESULTS_DIR="$work/scripts-early.results"
: > "$CALLS"
(cd "$tree" && PATH="$work/bin:$PATH" exec scripts/mac-suite.sh --lane fast --results "$RESULTS_DIR" --cache "$work/cache" scripts) \
  > "$work/scripts-early.log" 2>&1 &
pid=$!
running=$pid
for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
wait "$pid"; status=$?
running=""
is "signal as the tests start: exits 143" "$status" 143
first="$(cat "$work/early/first" 2>/dev/null)"
group="$(sed -n 's/^error: mac-suite.sh was ended by a signal; it signalled process group \(.*\)\.$/\1/p' "$work/scripts-early.log")"
is "signal as the tests start: the run signalled one process group" "$(echo "$group" | wc -w | tr -d ' ')" 1
for _ in $(seq 30); do [ -z "$(pgrep -g "${group:-0}" 2>/dev/null)" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
left="$(pgrep -g "${group:-0}" 2>/dev/null | tr '\n' ' ')"
[ -n "$group" ] && [ -z "$left" ] && ! kill -0 "$first" 2>/dev/null \
  && ok "signal as the tests start: nothing of the tests' group, the first test included, outlived the run" \
  || { fail "signal as the tests start: pids $left$(kill -0 "$first" 2>/dev/null && echo " $first") outlived the run"; for p in $left; do kill "$p" 2>/dev/null; done; kill "$first" 2>/dev/null; }
fake "$tree/scripts/tests/ci-audio-lane-test.sh" 'exit 0'

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

# --check: a Mac with everything, the guest's framework current, is passed with nothing run.
check() {  # check <case> [suite...] — its exit in $status, what it said in $said
  local name="$1"; shift
  export CALLS="$work/$name.calls"
  : > "$CALLS"
  said="$(cd "$tree" && PATH="$work/bin:${BARE_PATH:-$PATH}" scripts/mac-suite.sh --check --cache "$work/cache" "$@" 2>&1)" && status=0 || status=$?
}
names() { case "$said" in *"error: "*"$2"*) ok "$1" ;; *) fail "$1: $said" ;; esac; }
mkdir -p "$tree/Packages/TopoUserland/Frameworks/TopoIsh.xcframework"
fake "$tree/scripts/build-ish.sh" '[ "${1-}" != inputs ] || echo digest'
echo digest > "$tree/Packages/TopoUserland/Frameworks/TopoIsh.xcframework/.inputs"
check can topo_unit others
is "check: a Mac with everything exits 0" "$status" 0
is "check: nothing is generated, built, booted or made" "$(grep -cE '^(xcodegen generate|xcodebuild (build|test)|xcrun simctl (create|boot)|build-ish.sh$|ci-audio-lane)' "$CALLS")" 0
[ ! -e "$work/can.results" ] && ok "check: no results are written" || fail "check: results were written"
FAKE_XCODE=26.4 check xcode others
is "check, another Xcode: exits 1" "$status" 1
names "check, another Xcode: named" "selected Xcode is 'Xcode 26.4'"
FAKE_NO_RUNTIMES=1 FAKE_FREE=9 check runtimes others
names "check, no pinned runtime and a full disk: the disk is named too" "9 GB available"
is "check, no pinned runtime: exits 1" "$status" 1
names "check, no pinned runtime: the phone's is named" "no iPhone simulator of com.apple.CoreSimulator.SimRuntime.iOS-27-0"
names "check, no pinned runtime: the watch's is named for others" "no Apple Watch simulator of com.apple.CoreSimulator.SimRuntime.watchOS-27-0"
FAKE_NO_RUNTIMES=1 check runtimes-unit topo_unit
case "$said" in *"Apple Watch"*) fail "check, topo_unit alone: the watch's runtime is asked for: $said" ;; *) ok "check, topo_unit alone: the watch's runtime is not asked for" ;; esac
FAKE_FREE=9 check disk topo_unit
is "check, a full disk: exits 1" "$status" 1
names "check, a full disk: named" "9 GB available"
FAKE_LID=Yes check lid topo_unit
is "check, the lid closed: exits 1" "$status" 1
names "check, the lid closed: named" "lid is closed"
FAKE_LOCKED=1 FAKE_VAULT=On check locked topo_unit
is "check, locked and encrypted: exits 1" "$status" 1
names "check, locked and encrypted: named" "is locked, or is not the one on the screen"
FAKE_AWAY=No FAKE_OTHER_CONSOLE=Yes FAKE_OTHER_UNLOCKED= FAKE_VAULT=On check away topo_unit
is "check, encrypted and another user's session on the screen: exits 1" "$status" 1
FAKE_LOCKED=1 FAKE_VAULT=On check locked-others others
is "check, locked and encrypted, others: exits 0" "$status" 0
FAKE_LOCKED=1 check locked-plain topo_unit
is "check, locked and not encrypted: exits 0" "$status" 0
# `scripts` alone asks a Mac for jq, node, python3 and an open lid, whatever else it lacks.
FAKE_XCODE=26.4 FAKE_NO_RUNTIMES=1 FAKE_FREE=1 FAKE_LOCKED=1 FAKE_VAULT=On check scripts-bare scripts
is "check, scripts alone on a Mac with no toolchain, runtime or room: exits 0" "$status" 0
is "check, scripts alone: nothing asked of Xcode, simctl or the disk" "$(grep -cE '^(xcodebuild|xcodegen|xcrun|osascript)' "$CALLS")" 0
# A Mac with what macOS has and nothing installed: no node, and a python3 that is a stub.
mkdir -p "$work/stock" && for tool in bash env dirname basename cat grep sed tr uname id git; do ln -sf "$(command -v "$tool")" "$work/stock/$tool"; done
ln -sf "$(command -v jq)" "$work/stock/jq"
BARE_PATH="$work/stock:/usr/bin:/bin" FAKE_NO_TOOLS=1 check scripts-stock scripts
is "check, scripts alone, no node and no developer tools: exits 1" "$status" 1
names "check, scripts alone, no node: named" "node is not installed"
names "check, scripts alone, python3 a stub: named" "python3 is the stub"
BARE_PATH="$work/stock:/usr/bin:/bin" FAKE_NO_TOOLS=1 check others-stock others
names "check, others, no node: named" "node is not installed"
names "check, others, python3 a stub: named" "python3 is the stub"
BARE_PATH="$work/stock:/usr/bin:/bin" FAKE_NO_TOOLS=1 check unit-stock topo_unit
case "$said" in *"node is not"* | *"python3 is the stub"*) fail "check, topo_unit alone: asked for what the scripts' tests run under: $said" ;; *) ok "check, topo_unit alone: not asked for what the scripts' tests run under" ;; esac
BARE_PATH="$work/stock:/usr/bin:/bin" check scripts-tools scripts
names "check, scripts alone, developer tools and no node: node is named" "node is not installed"
case "$said" in *"python3 is the stub"*) fail "check, developer tools there: python3 refused: $said" ;; *) ok "check, developer tools there: python3 is taken" ;; esac
# without <tool> — a directory of everything macOS has but that, and node, in $work/no-<tool>.
without() {
  local tool
  mkdir -p "$work/no-$1"
  for tool in /usr/bin/* /bin/*; do [ "$(basename "$tool")" = "$1" ] || ln -sf "$tool" "$work/no-$1/"; done
  ln -sf "$(command -v node)" "$work/no-$1/node"
}
# A Mac with no python3, and one whose python3 does not run: each refused, for either suite.
without python3
for asked_suite in scripts others; do
  BARE_PATH="$work/no-python3" check "no-python-$asked_suite" "$asked_suite"
  is "check, $asked_suite, no python3: exits 1" "$status" 1
  names "check, $asked_suite, no python3: named" "python3 is not installed"
  mkdir -p "$work/broken" && printf '#!/bin/sh\nexit 1\n' > "$work/broken/python3" && chmod +x "$work/broken/python3"
  BARE_PATH="$work/broken:$work/no-python3" check "broken-python-$asked_suite" "$asked_suite"
  is "check, $asked_suite, a python3 that exits 1: exits 1" "$status" 1
  names "check, $asked_suite, a python3 that exits 1: named" "does not run"
done
# A Mac with no jq.
without jq
BARE_PATH="$work/no-jq" check scripts-no-jq scripts
is "check, scripts alone, no jq: exits 1" "$status" 1
names "check, scripts alone, no jq: named" "jq is not installed"
case "$said" in *"node is not"*) fail "check, no jq: node there and refused: $said" ;; *) ok "check, no jq: nothing else is named" ;; esac
FAKE_LID=Yes check scripts-lid scripts
is "check, scripts alone, the lid closed: exits 1" "$status" 1
FAKE_XCODE=26.4 check scripts-beside scripts others
is "check, scripts beside others on another Xcode: exits 1" "$status" 1
FAKE_VAULT=On check unlocked topo_unit
is "check, encrypted and unlocked, another session locked: exits 0" "$status" 0
check ui topo_ui
is "check, topo_ui: exits 1" "$status" 1
names "check, topo_ui: named" "topo_ui runs on buddybox alone"
check ui-mic topo_ui:mic
is "check, the microphone part: exits 1" "$status" 1
names "check, the microphone part: named" "topo_ui:mic runs on buddybox alone"
# The quiet part is asked what topo_unit is, the unlocked session too.
check ui-quiet topo_ui:quiet
is "check, the quiet part: exits 0" "$status:$said" "0:this Mac can run topo_ui:quiet."
FAKE_LOCKED=1 FAKE_VAULT=On check ui-quiet-locked topo_ui:quiet
is "check, the quiet part, encrypted and locked: exits 1" "$status" 1
names "check, the quiet part, encrypted and locked: named" "is locked"
FAKE_XCODE=26.4 FAKE_NO_RUNTIMES=1 FAKE_FREE=1 check ui-quiet-bare topo_ui:quiet
names "check, the quiet part: the Xcode is asked" "selected Xcode"
names "check, the quiet part: the simulator is asked" "no iPhone simulator"
names "check, the quiet part: the room is asked" "GB available"
# The framework there is of other inputs: the tools that build it are asked for.
echo other > "$tree/Packages/TopoUserland/Frameworks/TopoIsh.xcframework/.inputs"
PATH="$work/bin:/usr/bin:/bin" check tools topo_unit
is "check, a stale framework and no tools: exits 1" "$status" 1
names "check, a stale framework and no tools: meson is named" "meson is not installed"
names "check, a stale framework and no tools: llvm and lld are named" "llvm and lld are not installed"
fake "$tree/scripts/build-ish.sh" 'exit 0'

# A Mac's port 53 holder: its socket's path is handed to the unit tests, and a plain file at
# that path is not a socket.
python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$work/holder.sock"
PORT53="$work/holder.sock" suite holder topo_unit
is "holder: its socket is handed to the unit tests" "$(grep '^unit port53' "$CALLS")" "unit port53=$work/holder.sock"
: > "$work/not-a-socket"
PORT53="$work/not-a-socket" suite holder-file topo_unit
is "holder: a file that is not a socket is not handed on" "$(grep '^unit port53' "$CALLS")" "unit port53="

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
