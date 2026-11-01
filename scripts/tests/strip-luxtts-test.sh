#!/usr/bin/env bash
# scripts/strip-luxtts.sh against hand-made bundles: an unsigned one loses its luxtts_ files and
# keeps the rest, at any depth; one signed (ad hoc) loses them and is signed again, so its seal
# verifies, as is one whose seal an earlier run left broken; one with signing off is not signed;
# one with nothing to strip is left as it is; and a bundle that is not there fails, since that is
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

make_bundle "$work/deep/FluidAudio_FluidAudio.bundle"
mkdir -p "$work/deep/FluidAudio_FluidAudio.bundle/nested"
printf lexicon > "$work/deep/FluidAudio_FluidAudio.bundle/nested/luxtts_more.tsv"
ln -s nowhere "$work/deep/FluidAudio_FluidAudio.bundle/luxtts_dangling"
CODE_SIGNING_ALLOWED=NO "$strip" "$work/deep/FluidAudio_FluidAudio.bundle" >/dev/null || fail "a bundle with nested files was refused"
[ -z "$(find "$work/deep/FluidAudio_FluidAudio.bundle" -name 'luxtts_*' -print)" ] \
    || fail "a nested luxtts_ file or a dangling link stayed"

# A seal broken on an earlier run, with nothing left to remove, is signed again.
make_bundle "$work/broken/FluidAudio_FluidAudio.bundle"
codesign --sign - "$work/broken/FluidAudio_FluidAudio.bundle" 2>/dev/null
rm "$work/broken/FluidAudio_FluidAudio.bundle"/luxtts_en_us_lexicon.tsv.zz "$work/broken/FluidAudio_FluidAudio.bundle"/luxtts_en_us_g2p_aux.json
EXPANDED_CODE_SIGN_IDENTITY=- "$strip" "$work/broken/FluidAudio_FluidAudio.bundle" >/dev/null 2>&1 || fail "a broken seal was refused"
codesign --verify --strict "$work/broken/FluidAudio_FluidAudio.bundle" 2>/dev/null \
    || fail "a seal broken before the run, with nothing to remove, was not signed again"

# The identity is the build's: one the keychain lacks fails the strip rather than signing ad hoc.
make_bundle "$work/identity/FluidAudio_FluidAudio.bundle"
codesign --sign - "$work/identity/FluidAudio_FluidAudio.bundle" 2>/dev/null
if EXPANDED_CODE_SIGN_IDENTITY=0000000000000000000000000000000000000000 "$strip" "$work/identity/FluidAudio_FluidAudio.bundle" >/dev/null 2>&1; then
    fail "the strip signed with an identity other than the one it was given"
fi

# With signing off the build signs nothing, and neither does the strip.
make_bundle "$work/nosign/FluidAudio_FluidAudio.bundle"
codesign --sign - "$work/nosign/FluidAudio_FluidAudio.bundle" 2>/dev/null
CODE_SIGNING_ALLOWED=NO "$strip" "$work/nosign/FluidAudio_FluidAudio.bundle" >/dev/null 2>&1 || fail "a bundle with signing off was refused"
if codesign --verify --strict "$work/nosign/FluidAudio_FluidAudio.bundle" 2>/dev/null; then
    fail "the strip signed a bundle with CODE_SIGNING_ALLOWED=NO"
fi

if "$strip" "$work/absent/FluidAudio_FluidAudio.bundle" >/dev/null 2>&1; then
    fail "a bundle that is not there passed"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)" >&2
    exit 1
fi

echo "strip-luxtts.sh: an unsigned bundle loses its luxtts_ files and nothing else and stays unsigned; a signed one loses them and its seal verifies; one with nothing to strip passes; nested files and dangling links go; a broken seal is signed again; nothing is signed with signing off; a missing bundle fails"
