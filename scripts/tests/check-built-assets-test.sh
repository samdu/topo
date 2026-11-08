#!/usr/bin/env bash
# scripts/check-built-assets.sh and scripts/embed-voice.sh against hand-made products: an app with
# no part of the voice's bundle passes the plain check and fails `--embedded`; one with the bundle
# embed-voice.sh put there passes `--embedded` and fails the plain check, as does one with a stray
# Core ML package or voice file under any name; one whose bundle lacks a file or has one of the
# wrong size fails `--embedded`, naming it. embed-voice.sh with NO removes a copy a build left,
# and with YES refuses a source that lacks a file.
#
#   scripts/tests/check-built-assets-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check="$here/check-built-assets.sh"
embed="$here/embed-voice.sh"
work="$(mktemp -d -t check-built-assets-test)"
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
passes() { "$check" "$@" >/dev/null 2>&1 || fail "refused: $*"; }
refuses() {  # refuses <words the refusal says> <args…>
  local want="$1" errors; shift
  if errors="$("$check" "$@" 2>&1 >/dev/null)"; then fail "passed: $*"
  elif [[ "$errors" != *"$want"* ]]; then fail "the refusal of $* does not say '$want': $errors"; fi
}

# A bundle as phonon-bundles.sh leaves one.
source="$work/phonon-40m-en"
mkdir -p "$source/a.mlpackage/Data" "$source/voices"
printf 'weights' > "$source/a.mlpackage/Data/weight.bin"
printf 'voice' > "$source/voices/Friendly Octopus.safetensors"
cat > "$source/bundle.json" <<JSON
{"built": 1, "files": [
  {"path": "a.mlpackage/Data/weight.bin", "size": 7, "sha256": "x"},
  {"path": "voices/Friendly Octopus.safetensors", "size": 5, "sha256": "y"}]}
JSON

plain="$work/plain/Topo.app"
mkdir -p "$plain"
passes "$plain"
refuses "does not carry phonon-40m-en/bundle.json" --embedded "$plain"

dev="$work/dev/Topo.app"
mkdir -p "$dev"
PHONON_BUNDLE="$source" "$embed" "$dev" YES >/dev/null || fail "embed-voice.sh YES refused a whole bundle"
passes --embedded "$dev"
refuses "carries the voice's bundle" "$dev"

PHONON_BUNDLE="$source" "$embed" "$dev" NO || fail "embed-voice.sh NO failed"
[ ! -e "$dev/phonon-40m-en" ] || fail "embed-voice.sh NO left the bundle in the product"
passes "$dev"

stray="$work/stray/Topo.app"
mkdir -p "$stray/Elsewhere.bundle/b.mlpackage" "$stray/Other.bundle"
refuses "b.mlpackage" "$stray"
rm -rf "$stray/Elsewhere.bundle"; printf 'v' > "$stray/Other.bundle/someone.safetensors"
refuses "someone.safetensors" "$stray"

short="$work/short/Topo.app"
mkdir -p "$short"
PHONON_BUNDLE="$source" "$embed" "$short" YES >/dev/null
printf 'weight' > "$short/phonon-40m-en/a.mlpackage/Data/weight.bin"
refuses "a.mlpackage/Data/weight.bin" --embedded "$short"
rm "$short/phonon-40m-en/voices/Friendly Octopus.safetensors"
refuses "Friendly Octopus.safetensors" --embedded "$short"

rm "$source/voices/Friendly Octopus.safetensors"
if PHONON_BUNDLE="$source" "$embed" "$work/refused/Topo.app" YES >/dev/null 2>&1; then
  fail "embed-voice.sh YES took a bundle with a file missing"
fi

[ "$failures" = 0 ] && echo "check-built-assets.sh tells an install-page build from an App Store one, and embed-voice.sh puts in or takes out the whole bundle" || { echo "$failures failure(s)"; exit 1; }
