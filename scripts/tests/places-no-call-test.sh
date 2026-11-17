#!/usr/bin/env bash
# Holds that no Swift file of the app, its extensions or its packages (Apps/, Packages/) names a
# way of placing a CallKit call: the provider that reports one and the actions and controller that
# ask for one. Topo places no call — a wait behind the lock is carried by the audio it plays and
# records (docs/voice.md) — and the product declares no `voip` mode (scripts/check-built-plist.sh).
# `CXCallObserver`, which only reads whether the person is on a call of their own, is let through.
# It reads for the words below and nothing else, so a call placed under another spelling passes it.
# The check is first held against fixtures of its own, so a word it stopped finding fails here
# rather than passing every file.
#
#   scripts/tests/places-no-call-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../.."
work="$(mktemp -d -t places-no-call-test)"
trap 'rm -rf "$work"' EXIT

words=(CXProvider CXCallController CXStartCallAction CXTransaction CXCallUpdate CXEndCallAction CXSetMutedCallAction PKPushRegistry)

# found <file...>: prints every line holding one of the words, and succeeds when there is one. A
# file that cannot be read is said as found, so it fails the check rather than passing it.
found() {
  local arguments=() word status
  for word in "${words[@]}"; do arguments+=(-e "$word"); done
  grep -HnF "${arguments[@]}" -- "$@" && status=0 || status=$?
  if [ "$status" -gt 1 ]; then
    echo "grep could not read: $*"
    return 0
  fi
  return "$status"
}

failures=0

for word in "${words[@]}"; do
  printf 'import CallKit\nlet observer = CXCallObserver()\nlet thing = %s()\n' "$word" > "$work/fixture.swift"
  if ! found "$work/fixture.swift" > /dev/null; then
    echo "FAIL: a fixture holding $word was passed"
    failures=$((failures + 1))
  fi
done
printf 'import CallKit\nlet calls = CXCallObserver()\nlet busy = calls.calls.contains { !$0.hasEnded }\n' > "$work/clean.swift"
if found "$work/clean.swift" > /dev/null; then
  echo "FAIL: a fixture naming only CXCallObserver was refused"
  failures=$((failures + 1))
fi
if ! found "$work/absent.swift" > /dev/null 2>&1; then
  echo "FAIL: a file that cannot be read was passed"
  failures=$((failures + 1))
fi

# The app's own files. No file at all is a failure: a check of nothing passes everything.
files=()
while IFS= read -r -d '' file; do files+=("$file"); done \
  < <(command find "$root/Apps" "$root/Packages" -name '*.swift' -not -path '*/.build/*' -print0)
if [ "${#files[@]}" -eq 0 ]; then
  echo "FAIL: no Swift file under Apps/ or Packages/ to check"
  failures=$((failures + 1))
elif lines="$(found "${files[@]}")"; then
  echo "FAIL: the app names a way of placing a call:"
  echo "$lines"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "places-no-call-test: $failures failed"
  exit 1
fi
echo "places-no-call-test: ok (${#files[@]} file(s), ${#words[@]} words)"
