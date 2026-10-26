#!/usr/bin/env bash
# The PR check's Mac suites, run against the checkout this script is in. No hosted runner runs
# them: scripts/validate-and-push.sh runs this on buddybox at the commit being pushed and posts
# each suite's result to the PR as a commit status, which pr-validate.yaml's `test` job reads.
#
#   scripts/mac-suite.sh [--lane fast|full] [--results <dir>] [--cache <dir>] <suite>...
#   scripts/mac-suite.sh --check [--cache <dir>] <suite>...
#
# The suites, by the names scripts/ci-select-suites.sh selects them under:
#
#   topo_unit  the Topo scheme's test action less the UI tests: TopoTests, hosted by the iOS app,
#              and the userland package's two bundles, against the pinned rootfs, bash and
#              Claude Code.
#   topo_ui    TopoUITests behind the input-capable audio lane (scripts/ci-audio-lane.sh). The
#              full lane adds Parakeet's models and the test in which the real ear hears the
#              fixture; the fast lane deselects that test by name, so it neither runs nor skips.
#              It has two parts, each a suite by its own name with its own line in suites.txt
#              and its own result bundle: `topo_ui:quiet`, every UI test class but
#              MicrophonePressTests, with no audio lane, no display hold, no models and nothing
#              that opens a microphone or speaks (a tripwire reads the tests' source first,
#              `quiet_launches` below, and no test runs when it names a launch; after them the
#              app's data container on the part's simulator holds no fetched model,
#              `quiet_models`, or the part fails); and `topo_ui:mic`, that class alone behind
#              everything `topo_ui` has. One is all but the class and the other the class, so
#              no test is in neither.
#   others     the scripts' own tests, the committed manifest, the Swift packages, Womble, the
#              watch's suite, and the builds no suite hosts: the watch and TV for their own
#              simulators, a Release build for iOS devices, and the hub.
#   scripts    the scripts' own tests and nothing else: each runs against fakes, so the suite
#              boots no simulator, builds nothing and needs no toolchain prepared. It is what
#              a change to the harness alone needs, and `others` runs the same tests.
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
# lists this script's pid and then each command it is waiting on (the scripts' tests run at
# once in a process group of their own, so the subshell that leads it and each test):
# `kill $(head -1 <file>)` ends the run, which stops that command (every test still going and
# whatever it started), the audio lane it started and its simulators. A second
# signal while that is under way, or a SIGKILL, ends it with them left behind. The audio lane is
# one per Mac and `start` refuses a second, so two runs at once are the caller's to queue;
# validate-and-push.sh runs one suite a call, each under that suite's lock.
#
# --check runs nothing: it says whether a Mac other than buddybox can run the suites named, and exits 1 with an
# `error:` line for each thing it lacks: the pinned Xcode and XcodeGen, jq, a simulator of each
# pinned runtime the suites boot, the tools scripts/build-ish.sh builds the guest's framework
# with unless the one here is current, MIN_FREE_GB of disk under --cache (available as Finder
# counts it, purgeable space included), a lid that is open and, for `topo_unit` on a Mac
# whose disk is encrypted, this user's session on the screen and unlocked; of `scripts` alone
# it asks jq, node, a python3 that runs and the lid. It makes, builds and boots nothing. validate-and-push.sh asks it of a Mac other than buddybox before it runs
# a suite there, and `topo_ui` and `topo_ui:mic` are refused on any Mac they are asked of this way: the
# audio lane installs a driver and takes the Mac's default input and output. `topo_ui:quiet`
# is asked what `topo_unit` is.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root" || exit 2

# The toolchain the suite is held to, so a new Xcode or runtime on the Mac cannot silently
# change what it is compiled and run with. XcodeGen's is the version the committed projects are
# generated with.
XCODE_VERSION="27.0"
IOS_SIMULATOR_RUNTIME="com.apple.CoreSimulator.SimRuntime.iOS-27-0"
WATCHOS_SIMULATOR_RUNTIME="com.apple.CoreSimulator.SimRuntime.watchOS-27-0"
XCODEGEN_VERSION="2.46.0"
# The one test only the full lane runs: Parakeet hearing the fixture.
REAL_EAR_TEST="TopoUITests/MicrophonePressTests/testParakeetHearsTheFixtureThroughTheMicrophone"
SUITES=(topo_unit topo_ui others scripts)
# The class the audio lane exists for, and the order everything asked for runs in: the parts of
# `topo_ui` are suites by their own names.
MIC_CLASS="TopoUITests/MicrophonePressTests"
ORDER=(topo_unit topo_ui:quiet topo_ui topo_ui:mic others scripts)
# What --check asks of the disk: a runtime's simulators, a cold DerivedData and the pinned
# downloads are most of it, and a Mac somebody else is using is not left full.
MIN_FREE_GB=10
# Every test action runs without the diagnostics xcodebuild otherwise gathers after the last
# test: `simctl diagnose` of the simulator, which copies every crash report on the Mac and
# collects a log archive into the result bundle. Nothing reads them, they are 320 MB a run, and
# the archive's `log collect` stalls on this Mac often enough that three of seven UI runs
# waited the full 600 s xcodebuild allows it before giving up (`Failure collecting diagnostics
# from simulator: Timed out after 600.0 seconds`). What they held stays where it came from: a
# crash report in ~/Library/Logs/DiagnosticReports, the simulator's log in its own store until
# the run deletes the device. Each test's own log and attachments are still in the bundle.
NO_DIAGNOSE=(-collect-test-diagnostics never)

check=no
lane=fast
RESULTS="$root/build/validate"
PACKAGE_PINS=Topo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
cache="$HOME/Library/Caches/topo-validate"
asked=()
while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=yes; shift ;;
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
  case " ${ORDER[*]} " in *" $suite "*) ;; *) echo "no such suite '$suite': one of ${SUITES[*]}, or topo_ui:quiet or topo_ui:mic" >&2; exit 2 ;; esac
done
[ -n "$RESULTS" ] && [ -n "$cache" ] || { echo "--results and --cache each take a directory" >&2; exit 2; }

err() { echo "error: $*" >&2; }

# The pinned Xcode and XcodeGen, each an `error:` line when this Mac's is another.
pinned_tools() {
  local xcode status=0
  xcode="$(xcodebuild -version 2>/dev/null | head -n 1)"
  [ "$xcode" = "Xcode $XCODE_VERSION" ] || { err "this Mac's selected Xcode is '$xcode', not Xcode $XCODE_VERSION; pick the Xcode it has on purpose."; status=1; }
  xcodegen --version 2>/dev/null | grep -qx "Version: $XCODEGEN_VERSION" \
    || { err "xcodegen is '$(xcodegen --version 2>&1 | head -n 1)', not Version: $XCODEGEN_VERSION."; status=1; }
  return "$status"
}

# has_simulator <runtime> <name prefix> — whether this Mac has a device new_simulator can copy.
has_simulator() {
  xcrun simctl list devices available --json 2>/dev/null | jq -e --arg rt "$1" --arg p "$2" \
    '[.devices[$rt] // [] | .[] | select(.name | startswith($p))] | length > 0' >/dev/null 2>&1
}

# Whether anything asked for builds or boots: `scripts` alone does neither.
builds=no
for suite in "${asked[@]}"; do [ "$suite" = scripts ] || builds=yes; done

if [ "$check" = yes ]; then
  lacks=0
  command -v jq >/dev/null || { err "jq is not installed."; lacks=1; }
  # What the scripts' tests run under beside bash: review-prompt's runs a workflow step's
  # script under node, and the janitor's is python, which on a Mac with no developer tools is
  # a stub at /usr/bin that asks to install them.
  for suite in "${asked[@]}"; do
    case "$suite" in
      scripts | others)
        command -v node >/dev/null || { err "node is not installed, and the scripts' tests run one under it (brew install node)."; lacks=1; }
        # The stub is not run to find out: it answers with a dialog on the Mac's screen.
        python="$(command -v python3 || true)"
        if [ -z "$python" ]; then
          err "python3 is not installed, and the scripts' tests run one under it."; lacks=1
        elif [ "$python" = /usr/bin/python3 ] && ! xcode-select -p >/dev/null 2>&1; then
          err "python3 is the stub of a Mac with no developer tools, and the scripts' tests run one under it (xcode-select --install)."; lacks=1
        elif ! python3 -c 'import unittest' >/dev/null 2>&1; then
          err "python3 ($python) does not run, and the scripts' tests run one under it."; lacks=1
        fi
        break
        ;;
    esac
  done
fi
# The toolchain, the simulators, the guest's framework and the disk are what a suite that
# builds wants; the scripts' tests want none of them.
if [ "$check" = yes ] && [ "$builds" = yes ]; then
  [ "$(uname -m)" = arm64 ] || { err "this Mac is $(uname -m), not arm64."; lacks=1; }
  pinned_tools || lacks=1
  has_simulator "$IOS_SIMULATOR_RUNTIME" iPhone || { err "no iPhone simulator of $IOS_SIMULATOR_RUNTIME on this Mac."; lacks=1; }
  for suite in "${asked[@]}"; do
    case "$suite" in
      others) has_simulator "$WATCHOS_SIMULATOR_RUNTIME" "Apple Watch" || { err "no Apple Watch simulator of $WATCHOS_SIMULATOR_RUNTIME on this Mac."; lacks=1; } ;;
      topo_ui | topo_ui:mic) err "$suite runs on buddybox alone: its audio lane installs a driver and takes the Mac's default input and output."; lacks=1 ;;
    esac
  done
  stamp="Packages/TopoUserland/Frameworks/TopoIsh.xcframework/.inputs"
  if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$(scripts/build-ish.sh inputs 2>/dev/null)" ]; then
    brew_prefix="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
    for tool in meson ninja; do
      command -v "$tool" >/dev/null || { err "$tool is not installed, and the guest's framework here is not current (brew install meson ninja llvm lld)."; lacks=1; }
    done
    [ -x "$brew_prefix/opt/llvm/bin/clang" ] && [ -x "$brew_prefix/opt/lld/bin/ld.lld" ] \
      || { err "Homebrew's llvm and lld are not installed, and the guest's framework here is not current (brew install llvm lld)."; lacks=1; }
  fi
  mkdir -p "$cache" || exit 2
  # What the disk has for a write that matters, the figure Finder shows: `df` leaves out what
  # macOS purges as the room is wanted, which on a laptop is most of it.
  free="$(osascript -l JavaScript -e 'ObjC.import("Foundation"); function run(argv) { var value = $(); $.NSURL.fileURLWithPath(argv[0]).getResourceValueForKeyError(value, "NSURLVolumeAvailableCapacityForImportantUsageKey", null); return Math.floor(ObjC.unwrap(value) / 1e9); }' "$cache" 2>/dev/null)"
  case "$free" in
    "" | *[!0-9]*) err "could not read the disk's available space under $cache."; lacks=1 ;;
    *) [ "$free" -ge "$MIN_FREE_GB" ] || { err "$free GB available under $cache, purgeable space included (Finder's figure), and a suite wants $MIN_FREE_GB."; lacks=1; } ;;
  esac
fi
if [ "$check" = yes ]; then
  # A laptop with its lid shut sleeps whatever holds it awake; a Mac with no lid has no such key.
  # Read whole and then looked at: a reader that stops at the first match ends ioreg on a
  # closed pipe, which under pipefail is a failed pipeline, and that would read as open.
  lid="$(ioreg -r -k AppleClamshellState -d 4 2>/dev/null || true)"
  case "$lid" in *'"AppleClamshellState" = Yes'*) err "this Mac's lid is closed."; lacks=1 ;; esac
  # A Mac whose disk is encrypted gives no file complete protection while its screen is
  # locked, and the app asks that of files in the simulator's home, under TopoTests and under
  # the UI tests alike.
  case " ${asked[*]} " in
    *" topo_unit "* | *" topo_ui:quiet "*)
      # The session of the user the suite runs as, by name: open when it is the one on the
      # screen and not locked. Another user's, or the login window's, is not this one's.
      sessions="$(ioreg -n Root -d1 2>/dev/null | tr '}' '\n' || true)"
      mine="$(grep -F "\"kCGSSessionUserNameKey\"=\"$(id -un)\"" <<<"$sessions" || true)"
      vault="$(fdesetup status 2>/dev/null || true)"
      case "$mine" in
        *'"CGSSessionScreenIsLocked"=Yes'*) open=no ;;
        *'"kCGSSessionOnConsoleKey"=Yes'*) open=yes ;;
        *) open=no ;;
      esac
      if [ "$open" = no ]; then
        case "$vault" in *"FileVault is On"*) err "this Mac's disk is encrypted and the session of $(id -un) is locked, or is not the one on the screen: no file can be given complete protection until it is unlocked, and topo_unit and topo_ui:quiet ask for that."; lacks=1 ;; esac
      fi
      ;;
  esac
  [ "$lacks" = 0 ] && echo "this Mac can run ${asked[*]}."
  exit "$lacks"
fi

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
  # A signal that landed while the lane's start was under way runs this before the start's
  # status was read: it is on record beside the results, and a refusal (3) is another run's lane.
  if [ "$lane_started" = starting ]; then
    [ "$(cat "$RESULTS/lane-start.status" 2>/dev/null)" = 3 ] || lane_started=yes
  fi
  [ "$lane_started" = yes ] && scripts/ci-audio-lane.sh stop
  local udid
  for udid in ${created[@]+"${created[@]}"}; do
    xcrun simctl shutdown "$udid" >/dev/null 2>&1
    xcrun simctl delete "$udid" >/dev/null 2>&1
  done
  rm -f "$pids"
}
trap cleanup EXIT
# Only the command this run is waiting on, by the pid recorded for it, and the scripts' tests'
# process group. That group is found on the job table bash keeps, which has a job from the
# moment the command that started it completes and drops it once it has ended, never on a list
# of pids: the one job that leads a process group of its own (the tests' subshell, started under
# job control) is signalled as a group, so the tests and whatever they started end with it. A
# pid or a group id a job that has ended held, which the Mac may have given to another process
# since, is on no list this reads. The line says which groups were signalled.
ended() {
  local p signalled=""
  [ -n "$current" ] && kill "$current" 2>/dev/null
  for p in $(jobs -pr); do
    [ "$(ps -o pgid= -p "$p" 2>/dev/null | tr -d ' ')" = "$p" ] || continue
    kill -- "-$p" 2>/dev/null && signalled="$signalled $p"
  done
  echo "error: mac-suite.sh was ended by a signal${signalled:+; it signalled process group$signalled}." >&2
  exit 143
}
trap ended TERM INT HUP

say() { printf '\n==> %s\n' "$*"; }

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
  pinned_tools || return 1
  sw_vers
  xcodebuild -version
  swift --version

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

    # PhoneToolsTests and PhotosToolTests run the phone tools against the simulator's own
    # EventKit, Contacts and Photos stores, which answer only with access granted. Granted here,
    # not by a prompt, since nobody is there to answer one.
    say "Boot the simulator and grant calendar, reminders, contacts and photos access"
    xcrun simctl boot "$udid" || return 1
    xcrun simctl bootstatus "$udid" -b >/dev/null || return 1
    local service
    for service in calendar reminders contacts photos; do
      xcrun simctl privacy "$udid" grant "$service" zone.hexagon.topo || return 1
    done
    # The photos grant is full access only at the permission's second version: a row at the
    # first reads as leave to add only, and a read of the library would put the prompt up.
    # simctl of the pinned Xcode writes the second, so the simulator is booted once; the row is
    # read where the simulator keeps it, and one at any other version fails here by name.
    local tcc="$HOME/Library/Developer/CoreSimulator/Devices/$udid/data/Library/TCC/TCC.db"
    [ "$(sqlite3 "$tcc" "select auth_value, auth_version from access where client='zone.hexagon.topo' and service='kTCCServicePhotos'")" = "2|2" ] \
      || { err "the simulator's photos grant is not full access (auth_value|auth_version 2|2 in $tcc)."; return 1; }

    # The cooperative pool pinned to one thread in the test runner, as for the package suites:
    # the guest's pipes and waits block, and a block that lands on the pool hangs here rather
    # than on a phone.
    # GuestDNSTests' stub stands on port 53, which a VM's DNS proxy holds while one runs here; a
    # Mac that runs VMs keeps the port from its login (dotfiles tools/port53-holder) and lends it.
    # A socket left by a holder that died refuses the connection, and the stub binds the port itself.
    say "xcodebuild test (Topo, unit and userland)"
    local port53=() holder="${TOPO_PORT53_HOLDER:-$HOME/Library/Caches/port53-holder/socket}"
    [ -S "$holder" ] && port53=("TEST_RUNNER_TOPO_PORT53_SOCKET=$holder")
    rm -rf "$RESULTS/Topo-unit.xcresult"
    run "$RESULTS/Topo-unit.log" bounded 2400 env ${port53[@]+"${port53[@]}"} \
      "TEST_RUNNER_TOPO_USERLAND_ROOTFS=$rootfs" "TEST_RUNNER_TOPO_USERLAND_SHELL=$shell" \
      "TEST_RUNNER_TOPO_USERLAND_CLAUDE=$claude" TEST_RUNNER_LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 \
      xcodebuild test-without-building \
      -project Topo.xcodeproj -scheme Topo \
      -destination "platform=iOS Simulator,id=$udid" \
      "${NO_DIAGNOSE[@]}" \
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
# Whether the display's hold stands: its `caffeinate` running, and the assertion it takes among
# the ones the system counts. Asked for three seconds, since the assertion follows the start.
display_hold=""
display_held() {
  local n held
  for n in $(seq 30); do
    kill -0 "$display_hold" 2>/dev/null || return 1
    # Read whole and then searched: a search that stops at its first match ends `pmset` with a
    # signal while it still has lines to write, and under pipefail that reads as no match.
    held="$(pmset -g assertions 2>/dev/null)"
    ! grep -q "pid $display_hold(caffeinate).*PreventUserIdleDisplaySleep" <<<"$held" || return 0
    perl -e 'select(undef,undef,undef,0.1)'
  done
  return 1
}
# A tripwire ahead of the quiet part's tests, which reads the UI tests' source and nothing
# else, each line with its comments taken out first (`//` to the line's end and `/* … */`,
# nested and across lines, outside a string literal on the line). In each file but the
# microphone's it follows every `let <name> = XCUIApplication()` and `let <name> =
# TopoLaunch.app()` (which sets neither key) line by line, the last write winning, and names a
# `<name>.launch()` reached when both `TOPO_DEBUG_EAR` and `TOPO_DEBUG_VOICE` are not, by that
# line, set to "loading" on that name, in a statement that ends its line with that word: never
# set, set to something else since, removed (`removeValue`), or the dictionary replaced or
# merged over since. It names a launch on a name the file did not make that way. The quiet part
# leaves out the microphone's class and this leaves out its file, so it names any other class
# declared in that file, with its attributes and modifiers ahead of it on its line
# (`@MainActor final class`). It is false when it names anything, or finds no launch at all. It
# does not see what the source does not say on those lines: an environment changed through a
# helper the application is handed to, a loop, or a key that is not a literal is not caught.
# What the part's tests fetched is `quiet_models`, after them.
QUIET_TESTS=Tests/ClientUI
# The awk both readers start with. `code` is each line with its comments taken out, a string
# literal's contents kept: a small lexer whose state runs across lines, so a string is read
# before a comment mark is (plain `"…"` with its `\` escapes, multiline `"""…"""`, and raw
# `#"…"#` and `#"""…"""#` with any number of `#`, each with its interpolations `\(…)`, read as
# code to their closing parenthesis), and a block comment nests and spans lines. A string that
# is not multiline ends with its line. `declared` is a line past its leading attributes, their
# arguments read to the parenthesis that closes them outside a string literal.
SOURCE_CODE_AWK='
function rep(s, n,   r) { r = ""; while (n-- > 0) r = r s; return r }
function code(line,   out, i, n, c, k, q, w) {
  out = ""; n = length(line)
  for (i = 1; i <= n; i++) {
    c = substr(line, i, 1)
    if (depth > 0) {
      if (substr(line, i, 2) == "/*") { depth++; i++ } else if (substr(line, i, 2) == "*/") { depth--; i++; if (depth == 0) out = out " " }
      continue
    }
    if (sp && kind[sp] == "s") {
      k = hash[sp]; q = ml[sp] ? "\"\"\"" : "\""; w = length(q) + k
      if (c == "\\" && substr(line, i + 1, k) == rep("#", k)) {
        out = out substr(line, i, k + 2)
        if (substr(line, i + k + 1, 1) == "(") { sp++; kind[sp] = "i"; paren[sp] = 0 }
        i += k + 1; continue
      }
      if (substr(line, i, w) == q rep("#", k)) { out = out substr(line, i, w); i += w - 1; sp--; continue }
      out = out c; continue
    }
    if (sp && kind[sp] == "i") {
      if (c == "(") paren[sp]++
      else if (c == ")") { if (paren[sp] == 0) { sp--; out = out c; continue } paren[sp]-- }
    }
    if (substr(line, i, 2) == "//") break
    if (substr(line, i, 2) == "/*") { depth = 1; i++; continue }
    for (k = 0; substr(line, i + k, 1) == "#"; k++) ;
    if (substr(line, i + k, 1) == "\"") {
      sp++; kind[sp] = "s"; hash[sp] = k; ml[sp] = (substr(line, i + k, 3) == "\"\"\"")
      w = k + (ml[sp] ? 3 : 1); out = out substr(line, i, w); i += w - 1; continue
    }
    out = out c
  }
  while (sp > 0 && !(kind[sp] == "s" && ml[sp])) sp--
  return out
}
function declared(line,   i, n, c, d, q) {
  n = length(line); i = 1
  while (1) {
    while (i <= n && substr(line, i, 1) ~ /[ \t]/) i++
    if (substr(line, i, 1) != "@") break
    for (i++; i <= n && substr(line, i, 1) ~ /[A-Za-z0-9_.]/; i++) ;
    if (substr(line, i, 1) != "(") continue
    for (d = 0; i <= n; i++) {
      c = substr(line, i, 1)
      if (q) { if (c == "\\") i++; else if (c == "\"") q = 0; continue }
      if (c == "\"") q = 1; else if (c == "(") d++; else if (c == ")" && --d == 0) { i++; break }
    }
  }
  return substr(line, i)
}
{ $0 = code($0) }
'
quiet_launches() {
  local file found=0 bad=0 out mic="${MIC_CLASS##*/}"
  for file in "$QUIET_TESTS"/*.swift; do
    [ -f "$file" ] || continue
    case "$file" in
      */"$mic.swift")
        out="$(awk -v file="$file" -v mic="$mic" "$SOURCE_CODE_AWK"'
          { rest = declared($0) }
          match(rest, /^((final|private|fileprivate|public|internal|package|open|nonisolated)[ \t]+)*class[ \t]+[A-Za-z_][A-Za-z0-9_]*/) {
            name = substr(rest, RSTART, RLENGTH); sub(/.*class[ \t]+/, "", name)
            if (name != mic && name != "func" && name != "var" && name != "let") print file ":" NR ": class " name ", which the quiet part runs and this does not read"
          }' "$file")"
        [ -z "$out" ] || { echo "$out"; bad=1; }
        continue ;;
    esac
    out="$(awk -v file="$file" "$SOURCE_CODE_AWK"'
      match($0, /let [A-Za-z_][A-Za-z0-9_]* = (XCUIApplication|TopoLaunch\.app)\(\)/) {
        name = substr($0, RSTART + 4, RLENGTH - 4); sub(/ = .*/, "", name); made[name] = 1; ear[name] = 0; voice[name] = 0
      }
      {
        line = $0
        while (match(line, /[A-Za-z_][A-Za-z0-9_]*\.launchEnvironment/)) {
          name = substr(line, RSTART, RLENGTH); sub(/\..*/, "", name); rest = substr(line, RSTART + RLENGTH); line = rest
          if (match(rest, /^\["TOPO_DEBUG_EAR"\] = /)) ear[name] = (substr(rest, RLENGTH + 1) ~ /^"loading"[ \t]*$/)
          else if (match(rest, /^\["TOPO_DEBUG_VOICE"\] = /)) voice[name] = (substr(rest, RLENGTH + 1) ~ /^"loading"[ \t]*$/)
          else if (rest ~ /^\["[A-Za-z0-9_]*"\] = /) continue
          else if (rest ~ /^\.removeValue\(forKey: "TOPO_DEBUG_EAR"\)/) ear[name] = 0
          else if (rest ~ /^\.removeValue\(forKey: "TOPO_DEBUG_VOICE"\)/) voice[name] = 0
          else if (rest ~ /^\.removeValue\(forKey: "[A-Za-z0-9_]*"\)/) continue
          else { ear[name] = 0; voice[name] = 0 }
        }
      }
      match($0, /[A-Za-z_][A-Za-z0-9_]*\.launch\(\)/) {
        name = substr($0, RSTART, RLENGTH); sub(/\..*/, "", name); n++
        if (!made[name] || !ear[name] || !voice[name]) print file ":" NR ": " name ".launch()"
      }
      END { print "launches " n + 0 }' "$file")"
    found=$((found + $(sed -n 's/^launches //p' <<<"$out")))
    out="$(grep -v '^launches ' <<<"$out")"
    [ -z "$out" ] || { echo "$out"; bad=1; }
  done
  [ "$found" -gt 0 ] || { echo "no launch of the app was found under $QUIET_TESTS"; bad=1; }
  return "$bad"
}
# quiet_models <udid> — the proof the quiet part fetched no model: the app's data container on
# that simulator, read after the part's tests and before the run deletes the simulator, holds no
# file under the ear's or the voice's homes (`ModelStore.directory(for:)`, in Application
# Support: `Models/parakeet-tdt-0.6b-v2`, the voice's `Models/pocket-tts`, FluidAudio's own
# `FluidAudio/Models` where the spotter lives, and `Models/pocket-tts-coreml` and
# `Models/parakeet-ctc-110m-coreml`, where a set made before its home sits until `rehome`
# moves it). The rest of `Models/` is the guest's (its rootfs, bash, Claude Code), which the
# quiet part fetches. Each file found is named; no folder, or folders with no file in them,
# is nothing fetched. A container, a folder on the way to a home or a folder in one that cannot
# be read is a failure, named, since nothing was proved there.
quiet_models() {
  local container home at part parts files found="" unread="" status=0
  container="$(xcrun simctl get_app_container "$1" zone.hexagon.topo data 2>/dev/null)" && [ -d "$container" ] \
    || { err "topo_ui:quiet: the app's data container on $1 could not be read, so nothing shows the part fetched no model."; return 1; }
  for home in Models/parakeet-tdt-0.6b-v2 Models/parakeet-ctc-110m-coreml Models/pocket-tts Models/pocket-tts-coreml FluidAudio/Models; do
    # Down to the home a folder at a time: a folder that cannot be listed or entered is unread,
    # and only a name missing from one that can be is no home.
    IFS=/ read -ra parts <<<"Library/Application Support/$home"
    at="$container"
    for part in "${parts[@]}"; do
      [ -r "$at" ] && [ -x "$at" ] || { unread+="  ${at#"$container/"}: cannot be listed or entered"$'\n'; at=""; break; }
      [ -e "$at/$part" ] || [ -L "$at/$part" ] || { at=""; break; }
      at="$at/$part"
    done
    [ -n "$at" ] || continue
    if files="$(cd "$container" && find "${at#"$container/"}" ! -type d 2>"$RESULTS/quiet-models.err")"; then
      [ -z "$files" ] || found+="$(sed 's/^/  /' <<<"$files")"$'\n'
    else
      unread+="$(sed 's/^/  /' "$RESULTS/quiet-models.err")"$'\n'
      [ -z "$files" ] || found+="$(sed 's/^/  /' <<<"$files")"$'\n'
    fi
  done
  rm -f "$RESULTS/quiet-models.err"
  if [ -n "$found" ]; then
    err "topo_ui:quiet fetched models its launches hold loading (TOPO_DEBUG_EAR, TOPO_DEBUG_VOICE); in the app's data container on $1:"
    printf '%s' "$found" >&2; status=1
  fi
  if [ -n "$unread" ]; then
    err "topo_ui:quiet: part of the app's data container on $1 could not be read, so nothing shows the part fetched no model there:"
    printf '%s' "$unread" >&2; status=1
  fi
  [ "$status" = 1 ] || echo "No ear or voice model in the app's data container."
  return "$status"
}
# suite_topo_ui <whole|quiet|mic>
suite_topo_ui() {
  local part="$1" status=0 udid models="" lane_status name=Topo-ui
  local label=""
  [ "$part" = whole ] || { name="Topo-ui-$part"; label=", $part"; }
  ui_steps() {
    echo "Lane: $lane"
    if [ "$part" = quiet ]; then
      local loud
      loud="$(quiet_launches)" || { err "the UI tests' source does not show every launch outside ${MIC_CLASS##*/} leaving the ear and the voice loading (TOPO_DEBUG_EAR, TOPO_DEBUG_VOICE), and the quiet part has no lane for the real ones. No test was run."; echo "$loud" >&2; return 1; }
    fi
    if [ "$part" != quiet ]; then
      # BlackHole as this Mac's default input and output, and the fixture looping into it from
      # one long-lived feeder. It starts before the simulator boots, because a simulator's audio
      # binds to the coreaudiod it booted against and the lane restarts coreaudiod.
      say "Audio loopback for the microphone test"
      # The display is kept on for as long as this script lives: when it sleeps the loopback's
      # input goes silent and stays so until the lane is started again, and the microphone test
      # hears nothing. No lane is started without the hold, no test is started once it has ended,
      # and a suite whose tests it ended under is red.
      caffeinate -d -w $$ &
      display_hold=$!
      display_held || { err "the display could not be held on: \`caffeinate -d\` (pid $display_hold) is not running with its hold among \`pmset -g assertions\`. No audio lane was started."; return 1; }
      # Ours to stop from the moment `start` is called, not from its success: one that fails
      # after pinning the devices, or a signal while it is under way, leaves a feeder and the
      # Mac's defaults on BlackHole, and every later lane refused. A start that refuses (exit 3)
      # found another run's lane, which is not this run's to stop.
      # The start and the note of how it ended are one command to this shell, so a signal's trap
      # cannot run between them.
      rm -f "$RESULTS/lane-start.status"
      lane_started=starting
      (scripts/ci-audio-lane.sh start; echo $? > "$RESULTS/lane-start.status")
      lane_status="$(cat "$RESULTS/lane-start.status" 2>/dev/null || echo 1)"
      if [ "$lane_status" = 3 ]; then
        lane_started=no
        err "another audio lane is running on this Mac (a sibling's --talk run or validation); this one was not started. Run again once it has stopped."
        return 1
      fi
      lane_started=yes
      [ "$lane_status" = 0 ] || return 1
    fi

    new_simulator ui "$IOS_SIMULATOR_RUNTIME" iPhone || return 1
    xcrun simctl boot "$udid" || return 1

    # Parakeet's models, fetched from the manifest's pinned revisions and verified file by
    # file. The full lane only.
    if [ "$lane" = full ] && [ "$part" != quiet ]; then
      say "The ear's models for the microphone test"
      scripts/fetch-ear-models.sh "$cache/ear-models" || return 1
      models="$cache/ear-models"
    fi

    say "xcodebuild build-for-testing (Topo)"
    run "$RESULTS/$name-build.log" xcodebuild build-for-testing \
      -project Topo.xcodeproj -scheme Topo \
      -destination "platform=iOS Simulator,id=$udid" || return 1

    # The microphone test counts the permission prompts the run raises, and holds that there
    # is exactly one and that it is the microphone's. That count is only exact on a simulator
    # that has answered nothing, so the app's grants are cleared first and the flag tells the
    # test so.
    xcrun simctl bootstatus "$udid" -b >/dev/null || return 1
    if [ "$part" != quiet ]; then
      say "Clear Topo's privacy grants on the simulator"
      xcrun simctl privacy "$udid" reset all zone.hexagon.topo || return 1

      # A lane that has died fails here by name, before and after the suite, rather than only as
      # a silent tap inside the microphone test.
      say "Audio lane holds before the microphone test"
      scripts/ci-audio-lane.sh check before || return 1
      # The hold is one process from before the lane to after the tests, so the same pid still
      # holding after the tests held throughout; asked here too, so no test starts under one
      # that ended while the simulator booted and the app built.
      display_held || { err "the display's hold (\`caffeinate -d\`, pid $display_hold) ended before the tests began, so the display could sleep and silence the loopback. No test was run."; return 1; }
    fi

    say "xcodebuild test (Topo, UI${label})"
    local select=(-only-testing:TopoUITests) ui_status=0
    case "$part" in
      quiet) select+=("-skip-testing:$MIC_CLASS") ;;
      mic) select=("-only-testing:$MIC_CLASS") ;;
    esac
    if [ "$lane" = fast ] && [ "$part" != quiet ]; then
      select+=("-skip-testing:$REAL_EAR_TEST")
      echo "Fast lane: $REAL_EAR_TEST is deselected."
    fi
    rm -rf "$RESULTS/$name.xcresult"
    # The lane and the reset are declared to the test runner, which then fails a hold refused
    # for want of an input and holds the prompt count exact.
    # The quiet part declares neither: nothing in it holds the microphone or counts a prompt.
    local runner=()
    [ "$part" = quiet ] || runner=(TEST_RUNNER_TOPO_UITEST_AUDIO_INPUT=1 TEST_RUNNER_TOPO_UITEST_PRIVACY_RESET=1)
    [ -z "$models" ] || runner+=("TEST_RUNNER_TOPO_UITEST_EAR_MODELS=$models")
    run "$RESULTS/$name.log" bounded 3600 env ${runner[@]+"${runner[@]}"} xcodebuild test-without-building \
      -project Topo.xcodeproj -scheme Topo \
      -destination "platform=iOS Simulator,id=$udid" \
      "${NO_DIAGNOSE[@]}" \
      "${select[@]}" \
      -resultBundlePath "$RESULTS/$name.xcresult" || ui_status=1
    if [ "$part" = quiet ]; then
      say "No ear or voice model fetched (the app's data container)"
      quiet_models "$udid" || ui_status=1
      return "$ui_status"
    fi

    say "Audio lane holds after the microphone test"
    scripts/ci-audio-lane.sh check after || ui_status=1
    display_held || { err "the display's hold (\`caffeinate -d\`, pid $display_hold) ended under the tests, so the display could sleep and silence the loopback."; ui_status=1; }
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
  scripts/ci-require-tests.sh xcresult "$RESULTS/$name.xcresult" TopoUITests || status=1
  # The parts are all but one class and that class: it is in the microphone part's results,
  # passed, and not in the quiet part's.
  case "$part" in
    quiet) scripts/ci-require-tests.sh absent "$RESULTS/$name.xcresult" "$MIC_CLASS" || status=1 ;;
    mic) scripts/ci-require-tests.sh named "$RESULTS/$name.xcresult" "$MIC_CLASS" || status=1 ;;
  esac
  if [ "$lane" = full ] && [ "$part" != quiet ]; then
    scripts/ci-require-tests.sh named "$RESULTS/$name.xcresult" "$REAL_EAR_TEST" || status=1
  fi
  return "$status"
}

# Each script's own test, against fakes: scripts/tests/<name>-test.sh says what it holds.
# Named, not globbed, so a test that disappears fails here. Every one runs after an earlier
# one failed. They run at once and the suite waits for them all: each runs in a scratch
# directory of its own, four of them take between one and a half and three minutes apiece (a
# bound exercised in real time, a fake that sleeps to be killed) and the rest seconds, so the
# wall is the slowest test rather than the sum. The slow four are named first and so start
# first. Each writes its own log, printed whole under its heading once it has ended, in the
# order named, so the suite's log carries every test's output in a batch at the end rather
# than live; a missing test's heading and error are printed as the start loop reaches it.
# The tests are started and waited for by a subshell that is a process group of its own (job
# control is on while it is started, which is what puts a background job in one, and off in a
# subshell, so what it starts stays in its group) and that the tests and whatever they start
# belong to, so that the signal that ends the suite ends them all: a test killed alone leaves
# the command it was waiting on running. The subshell lives until it has waited for every test,
# so while any of them runs the group's leader is a running job of this script's, which is
# what `ended` signals by: there is no list a test has to reach before a signal can end it.
suite_scripts() {
  local status=0 group
  set -m
  (
    status=0
    names=()
    started=()
    for test in ci-audio-lane validate-and-push janitor simulator-run perf-run review-verdict ci-select-lane ci-select-suites asc-pem archive-upload \
                suite-gate ci-require-tests check-built-plist maps-opens-nothing build-ish \
                model-manifest review-prompt review-cap validate-host mac-suite agent-simulator; do
      if [ ! -x "scripts/tests/$test-test.sh" ]; then
        say "scripts/tests/$test-test.sh"
        err "scripts/tests/$test-test.sh is missing."
        status=1
        continue
      fi
      "scripts/tests/$test-test.sh" > "$RESULTS/script-$test.log" 2>&1 &
      echo "$!" >> "$pids"
      names+=("$test")
      started+=("$!")
    done
    for i in ${names[@]+"${!names[@]}"}; do
      say "scripts/tests/${names[$i]}-test.sh"
      if wait "${started[$i]}"; then passed=yes; else passed=no; fi
      cat "$RESULTS/script-${names[$i]}.log"
      [ "$passed" = yes ] || { err "scripts/tests/${names[$i]}-test.sh failed."; status=1; }
    done
    exit "$status"
  ) &
  group=$!
  set +m
  echo "$group" >> "$pids"
  wait "$group" || status=1
  return "$status"
}

# Everything that is not the Topo scheme's suite. Every step runs after an earlier one failed.
suite_others() {
  local status=0 udid package

  suite_scripts || status=1

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
  # `swift test`. Its deployment target is iOS 15.
  say "xcodebuild test (Womble)"
  rm -rf "$RESULTS/Womble.xcresult"
  if new_simulator womble "$IOS_SIMULATOR_RUNTIME" iPhone; then
    run "$RESULTS/Womble.log" bounded 1200 xcodebuild test \
      -project Womble/Womble.xcodeproj -scheme Womble \
      -destination "platform=iOS Simulator,id=$udid" \
      "${NO_DIAGNOSE[@]}" \
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
      "${NO_DIAGNOSE[@]}" \
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
  # The device build's derived data outlives the commit that made it, and what it keeps of a
  # package is wrong once the pins move: a Swift module scan still names the headers of the
  # version before, and a package whose headers moved fails the build. So it is kept only for
  # the pins it was built from, a copy of which is in it, and is made afresh for any other.
  cmp -s "$PACKAGE_PINS" build/device/Package.resolved || rm -rf build/device
  mkdir -p build/device
  cp "$PACKAGE_PINS" build/device/Package.resolved 2>/dev/null || true
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
if [ "$builds" = no ]; then
  prepared=yes
elif prepare; then
  prepared=yes
else
  prepared=no
  err "the toolchain, the projects or the guest's framework could not be prepared; no suite ran."
fi
for suite in "${ORDER[@]}"; do
  case " ${asked[*]} " in *" $suite "*) ;; *) continue ;; esac
  say "Suite: $suite"
  started=$SECONDS
  case "$suite" in
    topo_ui) call=(suite_topo_ui whole) ;;
    topo_ui:*) call=(suite_topo_ui "${suite#topo_ui:}") ;;
    *) call=("suite_$suite") ;;
  esac
  if [ "$prepared" = yes ] && "${call[@]}"; then result=success; else result=failure; overall=1; fi
  echo "$suite=$result" >> "$RESULTS/suites.txt"
  say "Suite: $suite $result in $(((SECONDS - started) / 60)) min"
done
exit "$overall"
