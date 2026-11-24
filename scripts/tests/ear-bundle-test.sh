#!/usr/bin/env bash
# Holds scripts/ear-bundle.sh to its pin, offline, against a file URL standing in for the
# repository: every file the pin names is fetched and written with the pin beside it as the
# bundle's bundle.json, whose digest `pin` prints; one not at the size or the sha256 the pin names is refused and not kept,
# and no bundle.json is written for a bundle that was refused. The committed pin names the
# Parakeet Ultra files FluidAudio loads for `.ultra` and nothing else.
#
#   scripts/tests/ear-bundle-test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d -t ear-bundle-test)"
trap 'rm -rf "$work"' EXIT
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

repo="$work/repo"
mkdir -p "$repo/Encoder.mlmodelc/weights"
printf 'encoder' > "$repo/Encoder.mlmodelc/weights/weight.bin"
printf 'vocab' > "$repo/parakeet_vocab.json"
digest() { shasum -a 256 "$1" | cut -d' ' -f1; }
pin() {  # pin <encoder size> <encoder sha256>
  cat > "$work/pin.json" <<JSON
{"repo": "fixture", "revision": "0", "built": 1, "files": [
  {"path": "Encoder.mlmodelc/weights/weight.bin", "size": $1, "sha256": "$2"},
  {"path": "parakeet_vocab.json", "size": 5, "sha256": "$(digest "$repo/parakeet_vocab.json")"}]}
JSON
}
fetches() {  # fetches <out>
  EAR_BUNDLE_PIN="$work/pin.json" EAR_REPO_URL="file://$repo" PATH="/usr/bin:/bin:/opt/homebrew/bin" \
    "$root/scripts/ear-bundle.sh" "$1" >"$work/log" 2>&1
}
encoder_sha="$(digest "$repo/Encoder.mlmodelc/weights/weight.bin")"

pin 7 "$encoder_sha"
if fetches "$work/whole"; then
  [ "$(cat "$work/whole/parakeet-ultra/Encoder.mlmodelc/weights/weight.bin" 2>/dev/null)" = encoder ] \
    || fail "a pinned file was not fetched: $(cat "$work/log")"
  cmp -s "$work/pin.json" "$work/whole/parakeet-ultra/bundle.json" || fail "the bundle's bundle.json is not the pin"
  [ "$(EAR_BUNDLE_PIN="$work/pin.json" "$root/scripts/ear-bundle.sh" pin)" = "$(digest "$work/whole/parakeet-ultra/bundle.json")" ] \
    || fail "pin does not print the digest of the bundle.json the bundle carries"
else
  fail "a whole bundle at its pin was refused: $(cat "$work/log")"
fi

pin 8 "$encoder_sha"
if fetches "$work/size"; then fail "a file of the wrong size was admitted"
else grep -q "Encoder.mlmodelc/weights/weight.bin is 7 bytes" "$work/log" || fail "the size refusal does not name the file: $(cat "$work/log")"; fi
[ ! -e "$work/size/parakeet-ultra/Encoder.mlmodelc/weights/weight.bin" ] || fail "a file of the wrong size was kept"
[ ! -e "$work/size/parakeet-ultra/bundle.json" ] || fail "a refused bundle was given a bundle.json"

pin 7 "$(printf '%064d' 0)"
if fetches "$work/digest"; then fail "a file with the wrong digest was admitted"
else grep -q "the pin says 7 bytes, $(printf '%064d' 0)" "$work/log" || fail "the digest refusal does not name the pin: $(cat "$work/log")"; fi
[ ! -e "$work/digest/parakeet-ultra/Encoder.mlmodelc/weights/weight.bin" ] || fail "a file with the wrong digest was kept"
[ -z "$(find "$work/size" "$work/digest" -name '*.part' 2>/dev/null)" ] || fail "a refused file's partial download was left behind"

# The committed pin: FluidAudio's `.ultra` contract (requiredModelsV3 and the vocabulary), at
# the revision Daphne's ear ran, and every entry a whole digest.
committed="$root/scripts/ear-bundle.json"
[ "$(jq -r .revision "$committed")" = 95eaa59a39d4394f047a4dc5cce480388a60d1b6 ] || fail "the pin is not at the revision Daphne's ear ran"
[ "$(jq -r '[.files[].path | split("/")[0]] | unique | join(" ")' "$committed")" = \
  "Decoder.mlmodelc Encoder.mlmodelc JointDecisionv3.mlmodelc Preprocessor.mlmodelc parakeet_vocab.json" ] \
  || fail "the pin names other than Ultra's four models and its vocabulary"
# Every file of the 18 FluidAudio loads, by its whole path: a model missing its weights is a
# bundle that cannot load, whatever its other entries.
inventory="$(printf '%s\n' \
  Decoder.mlmodelc/analytics/coremldata.bin Decoder.mlmodelc/coremldata.bin Decoder.mlmodelc/model.mil Decoder.mlmodelc/weights/weight.bin \
  Encoder.mlmodelc/analytics/coremldata.bin Encoder.mlmodelc/coremldata.bin Encoder.mlmodelc/model.mil Encoder.mlmodelc/weights/weight.bin \
  JointDecisionv3.mlmodelc/analytics/coremldata.bin JointDecisionv3.mlmodelc/coremldata.bin JointDecisionv3.mlmodelc/model.mil JointDecisionv3.mlmodelc/weights/weight.bin \
  Preprocessor.mlmodelc/analytics/coremldata.bin Preprocessor.mlmodelc/coremldata.bin Preprocessor.mlmodelc/metadata.json Preprocessor.mlmodelc/model.mil Preprocessor.mlmodelc/weights/weight.bin \
  parakeet_vocab.json)"
[ "$(jq -r '.files[].path' "$committed" | sort)" = "$inventory" ] || fail "the pin is not the 18 files Ultra loads, path for path"
[ "$(jq '[.files[] | select((.sha256 | test("^[0-9a-f]{64}$")) and .size > 0)] | length' "$committed")" = \
  "$(jq '.files | length' "$committed")" ] || fail "a pinned file has no whole digest or no size"

[ "$failures" = 0 ] && echo "ear-bundle.sh admits no file but at its pin's size and digest, pin names the bundle.json it writes, and its pin is Ultra's" || { echo "$failures failure(s)"; exit 1; }
