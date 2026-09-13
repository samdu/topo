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
# xunit: the Swift Testing report that `swift test --xunit-output <f>.xml`
# writes as `<f>-swift-testing.xml` must count at least one test and no
# failures, errors or skips.
set -euo pipefail

fail() { echo "::error::$*"; exit 1; }

mode="${1:-}"
case "$mode" in
  xcresult)
    [ "$#" -ge 3 ] || fail "usage: $0 xcresult <bundle.xcresult> <TestTarget>..."
    bundle="$2"; shift 2
    [ -d "$bundle" ] || fail "$bundle does not exist: the tests never produced a result bundle."
    tests="$(xcrun xcresulttool get test-results tests --path "$bundle" --format json)" \
      || fail "xcresulttool could not read $bundle."
    status=0
    for target in "$@"; do
      counts="$(jq -c --arg t "$target" '
        [.testNodes[] | .. | objects
          | select((.nodeType // "") | endswith("test bundle")) | select(.name == $t)]
        | if length == 0 then null else
            [.[] | .. | objects | select(.nodeType == "Test Case") | .result]
            | {total: length, notPassed: map(select(. != "Passed")) | group_by(.) | map({(.[0]): length}) | add}
          end' <<<"$tests")"
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
        echo "$target: $(jq '.total' <<<"$counts") test cases, all passed."
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
