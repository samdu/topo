#!/usr/bin/env bash
# scripts/strip-luxtts.sh against hand-made bundles: an unsigned one loses its luxtts_ files and
# keeps the rest; one signed (ad hoc) loses them and is signed again, so its seal verifies; one
# with nothing to strip is left as it is; and a bundle that is not there fails, since that is
# FluidAudio's resources moving with the lexicon still in the product. macOS only (codesign).
#
#   scripts/tests/strip-luxtts-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
strip="$here/strip-luxtts.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

make_bundle() {
    local bundle="$1"
    mkdir -p "$bundle"
    plutil -create xml1 "$bundle/Info.plist"
    plutil -insert CFBundleIdentifier -string FluidAudio.FluidAudio.resources "$bundle/Info.plist"
    printf lexicon > "$bundle/luxtts_en_us_lexicon.tsv.zz"
    printf '{}' > "$bundle/luxtts_en_us_g2p_aux.json"
    printf kept > "$bundle/other.json"
}

make_bundle "$work/plain/FluidAudio_FluidAudio.bundle"
CODE_SIGNING_ALLOWED=NO "$strip" "$work/plain/FluidAudio_FluidAudio.bundle" >/dev/null \
    || fail "an unsigned bundle was refused"
[ ! -e "$work/plain/FluidAudio_FluidAudio.bundle/luxtts_en_us_lexicon.tsv.zz" ] \
    && [ ! -e "$work/plain/FluidAudio_FluidAudio.bundle/luxtts_en_us_g2p_aux.json" ] \
    || fail "an unsigned bundle kept a luxtts_ file"
[ -f "$work/plain/FluidAudio_FluidAudio.bundle/other.json" ] || fail "the strip took a file that is not LuxTTS's"
[ ! -d "$work/plain/FluidAudio_FluidAudio.bundle/_CodeSignature" ] || fail "an unsigned bundle was signed"

make_bundle "$work/signed/FluidAudio_FluidAudio.bundle"
codesign --sign - "$work/signed/FluidAudio_FluidAudio.bundle" 2>/dev/null
codesign --verify --strict "$work/signed/FluidAudio_FluidAudio.bundle" 2>/dev/null || fail "the fixture's own signature does not verify"
EXPANDED_CODE_SIGN_IDENTITY=- "$strip" "$work/signed/FluidAudio_FluidAudio.bundle" >/dev/null 2>&1 \
    || fail "a signed bundle was refused"
[ ! -e "$work/signed/FluidAudio_FluidAudio.bundle/luxtts_en_us_lexicon.tsv.zz" ] || fail "a signed bundle kept the lexicon"
codesign --verify --strict "$work/signed/FluidAudio_FluidAudio.bundle" 2>/dev/null \
    || fail "a signed bundle's seal does not verify after the strip"

"$strip" "$work/signed/FluidAudio_FluidAudio.bundle" >/dev/null 2>&1 || fail "a bundle with nothing to strip was refused"

if "$strip" "$work/absent/FluidAudio_FluidAudio.bundle" >/dev/null 2>&1; then
    fail "a bundle that is not there passed"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)" >&2
    exit 1
fi

echo "strip-luxtts.sh: an unsigned bundle loses its luxtts_ files and nothing else and stays unsigned; a signed one loses them and its seal verifies; one with nothing to strip passes; a missing bundle fails"
