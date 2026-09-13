#!/usr/bin/env bash
# Fails unless the named tests actually ran and every one of them passed.
#
#   scripts/ci-require-tests.sh xcresult <bundle.xcresult> <TestTarget>...
#   scripts/ci-require-tests.sh xunit <package-swift-testing.xml>
#
# A green `xcodebuild test` or `swift test` does not say a test ran: a scheme
# whose test action lost a target, a package whose tests were all deleted, and
# a project that was never regenerated all exit 0. So the merge gate reads the
# results instead of the exit code.
#
# xcresult: each named test target must appear in the result bundle as a test
# bundle node with at least one test case, and every test case in it must have
# passed — a skipped test or an expected failure fails here too, because either
# is a test that did not prove what it names. A bundle that is absent (the
# build failed before testing) fails.
#
# One skip is allowed, and only one: the test named in ALLOWED_SKIP_TARGET and
# ALLOWED_SKIP_TEST, when its result is Skipped and its skip message starts
# with "missing coverage:". Apple's on-device speech recogniser cannot run in
# an iOS simulator (its en-US asset is a device-personalised cryptex; the
# recogniser fails with kLSRErrorDomain 300), so on the hosted runner that test
# can only name the gap. A failure of that test, or a skip with any other
# message, keeps its normal verdict, and a skip of any other test still fails.
# Every run that checks that target writes a "Missing coverage" section to the
# job summary and a warning annotation, saying what the test reported, so the
# hole stays visible on green runs. A second allowed skip is Sam's decision,
# not a change to make here.
#
# xunit: the Swift Testing report that `swift test --xunit-output <f>.xml`
# writes as `<f>-swift-testing.xml` must count at least one test and no
# failures, errors or skips.
set -euo pipefail

readonly ALLOWED_SKIP_TARGET="TopoUITests"
readonly ALLOWED_SKIP_TEST="MicrophonePressTests/testAPressOnTheFallbackDeliversAudioToTheRecogniser()"

fail() { echo "::error::$*"; exit 1; }

# The job summary entry and the run-page annotation for the allowed skip.
missing_coverage() {
  local line="$ALLOWED_SKIP_TARGET/$ALLOWED_SKIP_TEST: $1"
  echo "::warning title=Missing coverage::$line"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '## Missing coverage\n\n- `%s/%s`: %s\n' "$ALLOWED_SKIP_TARGET" "$ALLOWED_SKIP_TEST" "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

mode="${1:-}"
case "$mode" in
  xcresult)
    [ "$#" -ge 3 ] || fail "usage: $0 xcresult <bundle.xcresult> <TestTarget>..."
    bundle="$2"; shift 2
    checks_allowed_target=0
    for target in "$@"; do [ "$target" = "$ALLOWED_SKIP_TARGET" ] && checks_allowed_target=1; done
    if [ ! -d "$bundle" ]; then
      [ "$checks_allowed_target" = 1 ] && missing_coverage "no result bundle, so it did not run at all."
      fail "$bundle does not exist: the tests never produced a result bundle."
    fi
    tests="$(xcrun xcresulttool get test-results tests --path "$bundle" --format json)" \
      || fail "xcresulttool could not read $bundle."
    status=0
    for target in "$@"; do
      counts="$(jq -c --arg t "$target" --arg at "$ALLOWED_SKIP_TARGET" --arg aid "$ALLOWED_SKIP_TEST" '
        def message: [.children[]? | select(.nodeType == "Failure Message") | .name][0] // ""
                     | sub("^Test skipped - "; "");
        [.testNodes[] | .. | objects
          | select((.nodeType // "") | endswith("test bundle")) | select(.name == $t)]
        | if length == 0 then null else
            [.[] | .. | objects | select(.nodeType == "Test Case")]
            | (map(select($t == $at and .nodeIdentifier == $aid))[0]) as $named
            | ($named != null and $named.result == "Skipped"
               and ($named | message | startswith("missing coverage:"))) as $allowed
            | {total: length,
               named: (if $t == $at then
                         (if $named == null then {present: false}
                          else {present: true, result: $named.result, message: ($named | message), allowed: $allowed} end)
                       else null end),
               notPassed: map(select(.result != "Passed")
                              | select(($allowed and .nodeIdentifier == $aid) | not)
                              | .result)
                          | group_by(.) | map({(.[0]): length}) | add}
          end' <<<"$tests")"
      if [ "$target" = "$ALLOWED_SKIP_TARGET" ]; then
        named="$(jq -c '.named // {present: false}' <<<"$counts")"
        if [ "$(jq '.present' <<<"$named")" != true ]; then
          missing_coverage "not in the results, so it did not run."
        elif [ "$(jq '.allowed' <<<"$named")" = true ]; then
          missing_coverage "skipped — $(jq -r '.message' <<<"$named")"
        else
          if [ "$(jq -r '.result' <<<"$named")" = Passed ]; then
            missing_coverage "ran and passed; nothing is missing on this run."
          else
            missing_coverage "result $(jq -r '.result' <<<"$named")$(jq -r 'if .message != "" then " — " + .message else "" end' <<<"$named"). Not the allowed missing-coverage skip, so judged like any other test."
          fi
        fi
      fi
      if [ "$counts" = null ]; then
        echo "::error::$target is not in $(basename "$bundle"): its tests did not run."
        status=1
      elif [ "$(jq '.total' <<<"$counts")" -eq 0 ]; then
        echo "::error::$target ran no test cases."
        status=1
      elif [ "$(jq '.notPassed' <<<"$counts")" != null ]; then
        echo "::error::$target did not pass every test: $(jq -c '.notPassed' <<<"$counts") of $(jq '.total' <<<"$counts")."
        status=1
      else
        echo "$target: $(jq '.total' <<<"$counts") test cases, all passed$([ "$(jq '.named.allowed // false' <<<"$counts")" = true ] && echo " except the one allowed missing-coverage skip")."
      fi
    done
    exit "$status"
    ;;
  xunit)
    [ "$#" -eq 2 ] || fail "usage: $0 xunit <package-swift-testing.xml>"
    report="$2"
    [ -f "$report" ] || fail "$report does not exist: Swift Testing wrote no report."
    sum() { xmllint --xpath "sum(//testsuite/@$1)" "$report"; }
    total="$(sum tests)"; failures="$(sum failures)"; errors="$(sum errors)"; skipped="$(sum skipped)"
    [ "$total" -gt 0 ] || fail "$report counts no tests: the package's suite ran nothing."
    [ "$failures" -eq 0 ] && [ "$errors" -eq 0 ] && [ "$skipped" -eq 0 ] \
      || fail "$report: $total tests, $failures failures, $errors errors, $skipped skipped."
    echo "$(basename "$report"): $total tests, all passed."
    ;;
  *)
    fail "usage: $0 xcresult <bundle.xcresult> <TestTarget>... | xunit <report.xml>"
    ;;
esac
