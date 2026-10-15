#!/usr/bin/env bash
# Holds scripts/ci-require-tests.sh's xcresult, named and absent modes against a fake `xcrun` that answers
# `xcresulttool get test-results tests` with a result tree written here: a skipped test fails
# both, a test that is absent fails `named`, a target that is absent fails `xcresult`, and a
# bundle whose every test passed passes both. So the fast lane, which deselects the real-ear
# test rather than letting it skip, still fails on a skip anywhere, and the full lane's check by
# name fails when the test did not run. `absent` fails on any test case of the suite named, and
# on a bundle that is not there or cannot be read.
#
#   scripts/tests/ci-require-tests-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../ci-require-tests.sh"
work="$(mktemp -d -t ci-require-tests-test)"
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat > "$work/bin/xcrun" <<'SH'
#!/usr/bin/env bash
# xcrun xcresulttool get test-results tests --path <bundle> --format json
[ "$1 $2 $3 $4" = "xcresulttool get test-results tests" ] || { echo "fake xcrun: unexpected $*" >&2; exit 64; }
cat "$6/tests.json"
SH
chmod +x "$work/bin/xcrun"

# bundle <name> <parakeet result> <stub result> — a result tree with TopoUITests holding two
# MicrophonePressTests cases; a result of "absent" leaves the case out.
bundle() {
  local dir="$work/$1.xcresult" cases=""
  mkdir -p "$dir"
  [ "$2" = absent ] || cases="{\"nodeType\":\"Test Case\",\"name\":\"testParakeetHearsTheFixtureThroughTheMicrophone()\",\"nodeIdentifier\":\"MicrophonePressTests/testParakeetHearsTheFixtureThroughTheMicrophone()\",\"result\":\"$2\"},"
  cases="$cases{\"nodeType\":\"Test Case\",\"name\":\"testAPressOnTheStubEarDeliversAudioToTheSink()\",\"nodeIdentifier\":\"MicrophonePressTests/testAPressOnTheStubEarDeliversAudioToTheSink()\",\"result\":\"$3\"}"
  cat > "$dir/tests.json" <<JSON
{"testNodes":[{"nodeType":"Test Plan","name":"Topo","children":[
  {"nodeType":"UI test bundle","name":"TopoUITests","children":[
    {"nodeType":"Test Suite","name":"MicrophonePressTests","children":[$cases]}]}]}]}
JSON
  echo "$dir"
}

failures=0
expect() {
  local want="$1" name="$2" match="$3" out status
  shift 3
  out="$(PATH="$work/bin:$PATH" "$script" "$@" 2>&1)" && status=0 || status=$?
  if [ "$want" = pass ] && [ "$status" != 0 ]; then echo "FAIL $name: exited $status: $out"; failures=$((failures + 1)); return; fi
  if [ "$want" = fail ] && [ "$status" = 0 ]; then echo "FAIL $name: exited 0: $out"; failures=$((failures + 1)); return; fi
  if [ -n "$match" ] && ! grep -q -- "$match" <<<"$out"; then echo "FAIL $name: no '$match' in: $out"; failures=$((failures + 1)); return; fi
  echo "ok   $name"
}

ear=TopoUITests/MicrophonePressTests/testParakeetHearsTheFixtureThroughTheMicrophone

green="$(bundle green Passed Passed)"
expect pass "xcresult: every test passed" "2 test cases, all passed" xcresult "$green" TopoUITests
expect pass "named: the real-ear test passed" "1 test cases, all passed" named "$green" "$ear"
expect pass "named: a whole suite passed" "2 test cases, all passed" named "$green" TopoUITests/MicrophonePressTests

skipped="$(bundle skipped Skipped Passed)"
expect fail "xcresult: the real-ear test skipped" '"Skipped":1' xcresult "$skipped" TopoUITests
expect fail "named: the real-ear test skipped" "did not pass" named "$skipped" "$ear"

other="$(bundle other absent Skipped)"
expect fail "xcresult: another test skipped, the real ear deselected" '"Skipped":1' xcresult "$other" TopoUITests

fast="$(bundle fast absent Passed)"
expect pass "xcresult: the real ear deselected, the rest passed" "1 test cases, all passed" xcresult "$fast" TopoUITests
expect fail "named: the real-ear test deselected is a test that did not run" "did not run" named "$fast" "$ear"

failed="$(bundle failed Failed Passed)"
expect fail "named: the real-ear test failed" "did not pass" named "$failed" "$ear"

expect fail "xcresult: a target that is absent" "did not run" xcresult "$green" TopoTests
expect fail "named: a target that is absent" "did not run" named "$green" TopoTests/MicrophonePressTests
expect fail "named: a bundle that is absent" "does not exist" named "$work/none.xcresult" "$ear"
expect fail "named: a name with no suite" "is not Target/Suite" named "$green" TopoUITests

# absent: the suite a run was meant to leave out has no test case in the bundle, passed or not.
expect fail "absent: a suite that ran" "meant to be left out" absent "$green" TopoUITests/MicrophonePressTests
expect fail "absent: a suite one of whose tests ran" "1 test cases" absent "$fast" TopoUITests/MicrophonePressTests
expect fail "absent: a suite that ran and failed" "meant to be left out" absent "$failed" TopoUITests/MicrophonePressTests
expect pass "absent: a suite that is not there" "not in green.xcresult" absent "$green" TopoUITests/DraftRowTests
expect pass "absent: a suite of another target" "not in" absent "$green" TopoTests/MicrophonePressTests
expect fail "absent: a bundle that is absent" "does not exist" absent "$work/none.xcresult" TopoUITests/MicrophonePressTests
expect fail "absent: a name with no suite" "is not Target/Suite" absent "$green" TopoUITests
expect fail "absent: a single test's name" "is not Target/Suite" absent "$green" "$ear"
mkdir -p "$work/unread.xcresult"
expect fail "absent: a bundle that cannot be read" "could not read" absent "$work/unread.xcresult" TopoUITests/MicrophonePressTests

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
