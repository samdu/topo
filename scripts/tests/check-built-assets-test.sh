#!/usr/bin/env bash
# scripts/check-built-assets.sh and scripts/embed-bundles.sh against hand-made products: an app with
# no part of the voice's or the ear's bundle passes the plain check and fails `--embedded`; one with
# the bundles embed-bundles.sh put there passes `--embedded` and fails the plain check, and so
# does one with either bundle's folder alone, or with a model
# in any of Core ML's forms, a file by a weights format's extension or the pack's `.aar`, or a file
# over 4 MiB that is not a Mach-O; one whose bundle lacks a file or has one of the
# wrong size fails `--embedded`, naming it, as does one with the voice's bundle and not the ear's.
# embed-bundles.sh copies only what bundle.json names, with NO removes a copy a build left, and with
# YES refuses a source that lacks a file.
#
#   scripts/tests/check-built-assets-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check="$here/check-built-assets.sh"
embed="$here/embed-bundles.sh"
work="$(mktemp -d -t check-built-assets-test)"
trap 'rm -rf "$work"' EXIT
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
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

# The ear's, as ear-bundle.sh leaves one, with a stray partial download beside it.
ear="$work/parakeet-ultra-coreml"
mkdir -p "$ear/Encoder.mlmodelc/weights"
printf 'encoder' > "$ear/Encoder.mlmodelc/weights/weight.bin"
printf 'stray' > "$ear/Encoder.mlmodelc/weights/weight.bin.part"
cat > "$ear/bundle.json" <<JSON
{"built": 1, "files": [{"path": "Encoder.mlmodelc/weights/weight.bin", "size": 7, "sha256": "z"}]}
JSON
embeds() { PHONON_BUNDLE="$source" EAR_BUNDLE="$ear" "$embed" "$@"; }

plain="$work/plain/Topo.app"
mkdir -p "$plain"
passes "$plain"
refuses "does not carry phonon-40m-en/bundle.json" --embedded "$plain"

dev="$work/dev/Topo.app"
mkdir -p "$dev"
embeds "$dev" YES >/dev/null || fail "embed-bundles.sh YES refused whole bundles"
passes --embedded "$dev"
refuses "carries a model or weights" "$dev"
[ ! -e "$dev/parakeet-ultra-coreml/Encoder.mlmodelc/weights/weight.bin.part" ] || fail "embed-bundles.sh copied a file bundle.json does not name"
for name in phonon-40m-en parakeet-ultra-coreml; do
  alone="$work/alone-$name/Topo.app"
  mkdir -p "$alone" && cp -R "$dev/$name" "$alone/"
  refuses "$name" "$alone"
done
rm -rf "$work/alone-parakeet-ultra-coreml/Topo.app/parakeet-ultra-coreml"
refuses "does not carry parakeet-ultra-coreml/bundle.json" --embedded "$work/alone-phonon-40m-en/Topo.app"

embeds "$dev" NO || fail "embed-bundles.sh NO failed"
[ ! -e "$dev/phonon-40m-en" ] || fail "embed-bundles.sh NO left the voice in the product"
[ ! -e "$dev/parakeet-ultra-coreml" ] || fail "embed-bundles.sh NO left the ear in the product"
passes "$dev"

# Every form a model or its weights takes, under any name, in any bundle of the app.
stray="$work/stray/Topo.app"
for form in b.mlpackage b.mlmodelc; do
  mkdir -p "$stray/Elsewhere.bundle/$form"
  refuses "$form" "$stray"
  rm -rf "$stray/Elsewhere.bundle"
done
mkdir -p "$stray/Other.bundle"
for form in b.mlmodel someone.safetensors b.gguf b.onnx b.pt b.pth b.ckpt b.npz phonon-40m-en.aar; do
  printf 'v' > "$stray/Other.bundle/$form"
  refuses "$form" "$stray"
  rm "$stray/Other.bundle/$form"
done
passes "$stray"
# Weights renamed past every extension are caught by their size; code that size is not.
head -c 4194305 /dev/zero > "$stray/Other.bundle/data.bin"
refuses "data.bin" "$stray"
rm "$stray/Other.bundle/data.bin"
head -c 4194304 /dev/zero > "$stray/Other.bundle/data.bin"
passes "$stray"
{ printf '\xcf\xfa\xed\xfe'; head -c 8388608 /dev/zero; } > "$stray/Other.bundle/Other"
{ printf '\xca\xfe\xba\xbe'; head -c 8388608 /dev/zero; } > "$stray/Other.bundle/Universal"
passes "$stray"

short="$work/short/Topo.app"
mkdir -p "$short"
embeds "$short" YES >/dev/null
printf 'weight' > "$short/phonon-40m-en/a.mlpackage/Data/weight.bin"
refuses "a.mlpackage/Data/weight.bin" --embedded "$short"
rm "$short/phonon-40m-en/voices/Friendly Octopus.safetensors"
refuses "Friendly Octopus.safetensors" --embedded "$short"

rm "$source/voices/Friendly Octopus.safetensors"
if embeds "$work/refused/Topo.app" YES >/dev/null 2>&1; then
  fail "embed-bundles.sh YES took a bundle with a file missing"
fi

[ "$failures" = 0 ] && echo "check-built-assets.sh tells an install-page build from an App Store one, and embed-bundles.sh puts in or takes out the whole of each bundle" || { echo "$failures failure(s)"; exit 1; }
