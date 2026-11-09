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

# The cache. The pin cannot be met offline, so these cases run a copy of the script pinned to
# the stand-in zip's own sha256.
pinned="$work/pinned"
mkdir -p "$pinned/scripts"
stand="$(shasum -a 256 "$work/core.zip" | cut -d' ' -f1)"
sed "s/^sha=.*/sha=$stand/" "$root/scripts/fetch-phonon.sh" > "$pinned/scripts/fetch-phonon.sh"
chmod +x "$pinned/scripts/fetch-phonon.sh"
cache="$work/cache"
if PHONON_CORE_URL="file://$work/core.zip" "$pinned/scripts/fetch-phonon.sh" "$cache" >"$work/out" 2>&1; then
  [ -f "$pinned/Packages/PhononTTS/Frameworks/PhononCore.xcframework/Info.plist" ] && ok "a fetched zip is installed" || fail "nothing installed: $(cat "$work/out")"
  [ "$(shasum -a 256 "$cache/$stand.zip" 2>/dev/null | cut -d' ' -f1)" = "$stand" ] && ok "and kept in the cache under its sha256" || fail "the cache holds: $(ls "$cache" 2>&1)"
  [ -z "$(ls "$cache" | grep -v "^$stand.zip\$")" ] && ok "with nothing else beside it" || fail "the cache also holds: $(ls "$cache")"
else
  fail "a zip at the pin is refused: $(cat "$work/out")"
fi

# A checkout made afresh, with the network gone: the cache's zip is what installs.
fresh="$work/fresh"
mkdir -p "$fresh/scripts" && cp "$pinned/scripts/fetch-phonon.sh" "$fresh/scripts/"
if PHONON_CORE_URL="file://$work/nothing-here.zip" "$fresh/scripts/fetch-phonon.sh" "$cache" >"$work/out" 2>&1; then
  [ -d "$fresh/Packages/PhononTTS/Frameworks/PhononCore.xcframework" ] && grep -q "from $cache" "$work/out" \
    && ok "a fresh checkout installs from the cache, fetching nothing" || fail "from the cache: $(cat "$work/out")"
else
  fail "a fresh checkout with the zip cached still fetched: $(cat "$work/out")"
fi

# A zip in the cache that is not the pin's is never installed; it is fetched again and replaced.
echo damaged > "$cache/$stand.zip"
rm -rf "$fresh/Packages"
if PHONON_CORE_URL="file://$work/nothing-here.zip" "$fresh/scripts/fetch-phonon.sh" "$cache" >"$work/out" 2>&1; then
  fail "a damaged zip in the cache is installed"
else
  [ ! -e "$fresh/Packages/PhononTTS/Frameworks/PhononCore.xcframework" ] && ok "a damaged zip in the cache is not installed" || fail "a damaged zip left a framework"
fi
if PHONON_CORE_URL="file://$work/core.zip" "$fresh/scripts/fetch-phonon.sh" "$cache" >/dev/null 2>&1 \
  && [ "$(shasum -a 256 "$cache/$stand.zip" | cut -d' ' -f1)" = "$stand" ]; then
  ok "and the next fetch replaces it"
else
  fail "a damaged zip in the cache is not replaced"
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
