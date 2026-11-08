#!/usr/bin/env bash
# Holds scripts/fetch-phonon.sh to its pin: a zip whose sha256 is not the pin's is refused and
# leaves nothing behind, and a framework stamped with the pin is kept without a fetch. Runs the
# script in a scratch tree, against file URLs, offline.
#
#   scripts/tests/fetch-phonon-test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d -t fetch-phonon-test)"
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }

tree="$work/tree"
mkdir -p "$tree/scripts" "$work/zip/PhononCore.xcframework"
cp "$root/scripts/fetch-phonon.sh" "$tree/scripts/"
echo stand-in > "$work/zip/PhononCore.xcframework/Info.plist"
(cd "$work/zip" && ditto -c -k --keepParent PhononCore.xcframework "$work/core.zip")
dest="$tree/Packages/PhononTTS/Frameworks"

if PHONON_CORE_URL="file://$work/core.zip" "$tree/scripts/fetch-phonon.sh" >"$work/out" 2>&1; then
  fail "a zip that is not the pin's is admitted"
else
  grep -q "the pin is" "$work/out" && ok "a zip that is not the pin's is refused, saying so" || fail "the refusal says why: $(cat "$work/out")"
fi
[ ! -e "$dest/PhononCore.xcframework" ] && ok "a refused zip leaves no framework" || fail "a refused zip left a framework"

sha="$(sed -n 's/^sha=//p' "$tree/scripts/fetch-phonon.sh")"
mkdir -p "$dest/PhononCore.xcframework"
echo "$sha" > "$dest/.fetched"
if PHONON_CORE_URL="file://$work/nothing-here.zip" "$tree/scripts/fetch-phonon.sh" >"$work/out" 2>&1; then
  grep -q "is current" "$work/out" && ok "a framework stamped with the pin is kept, nothing fetched" || fail "kept: $(cat "$work/out")"
else
  fail "a framework stamped with the pin is fetched again: $(cat "$work/out")"
fi

echo other > "$dest/.fetched"
if PHONON_CORE_URL="file://$work/core.zip" "$tree/scripts/fetch-phonon.sh" >/dev/null 2>&1; then
  fail "a framework stamped with another pin is kept over a zip that is not the pin's"
else
  ok "a framework stamped with another pin is fetched again, and the wrong zip refused"
fi

# The vendored package is ptts's `Phonon.swift` alone: its player plays through an engine and a
# session of its own, beside the audio session the app's every path goes through, and its model
# downloader fetches from the network at runtime.
sources="$(cd "$root/Packages/PhononTTS/Sources/PhononTTS" && ls)"
[ "$sources" = Phonon.swift ] && ok "the package carries Phonon.swift and nothing else" || fail "the package carries: $sources"
# Code, not comments: the vendored file's own documentation names them.
named="$(git -C "$root" grep -n -E 'PhononPlayer|PhononModels' -- Apps Packages | grep -v -E '^[^:]+:[0-9]+:[[:space:]]*//' || true)"
[ -z "$named" ] && ok "no code in the app uses PhononPlayer or PhononModels" || fail "used in the app: $named"

[ "$failures" = 0 ] && echo "fetch-phonon.sh admits only its pin" || { echo "$failures failure(s)"; exit 1; }
