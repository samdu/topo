#!/usr/bin/env bash
# scripts/archive-upload.sh against a fake xcodebuild, altool and keychain, in a repository made
# here: with a key, kept as the hex `security -w` prints, the archive and the export are each
# handed it as a .p8 openssl reads, altool finds it, and it is gone afterwards; with no key the
# archive runs without one and an upload is refused before anything is built.
#
#   scripts/tests/archive-upload-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

tree="$work/tree"
mkdir -p "$tree/scripts" "$tree/Distribution" "$work/bin"
cp "$here/../archive-upload.sh" "$here/../asc-pem.sh" "$tree/scripts/"
printf '#!/bin/sh\nexit 0\n' > "$tree/scripts/build-ish.sh"
chmod +x "$tree/scripts/build-ish.sh"
touch "$tree/Distribution/ExportOptions.plist"
git -C "$tree" init -q -b scratch
git -C "$tree" config core.hooksPath /dev/null
git -C "$tree" -c user.name=test -c user.email=test@example.com add -A
git -C "$tree" -c user.name=test -c user.email=test@example.com commit -q -m tree
git -C "$tree" update-ref refs/remotes/origin/main HEAD

# xcodebuild: one line per call, and whether the key it was pointed at is a key as it runs.
cat > "$work/bin/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
line="$*" key="" next="" export=""
for argument in "$@"; do
  [ "$next" = key ] && key="$argument"
  [ "$next" = export ] && export="$argument"
  next=""
  case "$argument" in -authenticationKeyPath) next=key ;; -exportPath) next=export ;; esac
done
state=none
if [ -n "$key" ]; then
  if openssl pkey -in "$key" -noout 2>/dev/null; then state=key; else state=not-a-key; fi
fi
echo "xcodebuild [$state] $line" >> "$CALLS"
[ -z "$export" ] || { mkdir -p "$export"; touch "$export/Topo.ipa"; }
FAKE
cat > "$work/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
state=none
[ -z "${API_PRIVATE_KEYS_DIR:-}" ] || state="$(ls "$API_PRIVATE_KEYS_DIR")"
echo "xcrun [$state] $*" >> "$CALLS"
FAKE
# The keychain holds nothing: what the test gives is all there is.
printf '#!/bin/sh\nexit 44\n' > "$work/bin/security"
chmod +x "$work/bin/xcodebuild" "$work/bin/xcrun" "$work/bin/security"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/key.p8" 2>/dev/null \
    || { echo "FAIL: could not make a key to test with" >&2; exit 1; }
hex="$(xxd -p "$work/key.p8" | tr -d '\n')"

run() { # run <calls file> <arguments...>, with the environment the caller set
    local calls="$1"; shift
    : > "$calls"
    CALLS="$calls" PATH="$work/bin:$PATH" BUILD=7 TMPDIR="$work/tmp" "$tree/scripts/archive-upload.sh" "$@" > "$work/out" 2>&1
}
mkdir -p "$work/tmp"

# With a key, uploading.
ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/with" --upload \
    || fail "an upload with a key failed: $(cat "$work/out")"
[ "$(grep -c '^xcodebuild \[key\] ' "$work/with")" = 2 ] || fail "the archive and the export were not each handed a key: $(cat "$work/with")"
for call in 'xcodebuild \[key\] archive ' 'xcodebuild \[key\] -exportArchive '; do
    grep "^$call" "$work/with" | grep -q -- '-allowProvisioningUpdates -authenticationKeyPath .*/AuthKey_KEYID12345.p8 -authenticationKeyID KEYID12345 -authenticationKeyIssuerID an-issuer' \
        || fail "no key, id and issuer on: $call"
done
grep -q '^xcrun \[AuthKey_KEYID12345.p8\] altool --upload-app .* --apiKey KEYID12345 --apiIssuer an-issuer$' "$work/with" \
    || fail "altool was not given the key where it looks: $(cat "$work/with")"
[ -z "$(ls "$work/tmp")" ] || fail "the key outlived the run: $(ls "$work/tmp")"

# A key that is no key stops it before anything is built.
if ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY=deadbeef run "$work/bad"; then
    fail "what is not a key was taken as one"
fi
[ ! -s "$work/bad" ] || fail "something was built with what is not a key: $(cat "$work/bad")"
[ -z "$(ls "$work/tmp")" ] || fail "what is not a key outlived the run: $(ls "$work/tmp")"

# With no key: an archive on Xcode's own accounts, and no upload.
run "$work/without" || fail "an archive with no key failed: $(cat "$work/out")"
[ "$(grep -c '^xcodebuild \[none\] ' "$work/without")" = 2 ] || fail "an archive with no key was not two plain calls: $(cat "$work/without")"
grep -q -- '-authenticationKey' "$work/without" && fail "an archive with no key named one"
if run "$work/refused" --upload; then fail "an upload with no key was not refused"; fi
[ ! -s "$work/refused" ] || fail "an upload with no key built something first: $(cat "$work/refused")"
grep -q 'No App Store Connect API key' "$work/out" || fail "the refusal does not say there is no key: $(cat "$work/out")"

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed" >&2; exit 1; }
echo "archive-upload.sh: with a key kept as hex the archive, the export and altool each get it as a .p8 that is a key, and it is gone after; what is not a key builds nothing; with none the archive runs plain and an upload is refused before anything is built"
