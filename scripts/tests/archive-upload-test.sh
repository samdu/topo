#!/usr/bin/env bash
# scripts/archive-upload.sh against a fake xcodebuild, altool and keychain, in a repository made
# here: with a key, kept as the hex `security -w` prints, the archive and the export are each
# handed it as a .p8 openssl reads, altool finds it, and it is gone afterwards; with no key the
# archive runs without one and an upload is refused before anything is built; the archive resolves
# its packages into build/packages, kept for the pins they were resolved from and made afresh for
# any other.
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
cp "$here/../archive-upload.sh" "$here/../asc-pem.sh" "$here/../check-built-assets.sh" "$tree/scripts/"
cat > "$tree/scripts/phonon-bundles.sh" <<'FAKE'
#!/bin/sh
echo "phonon-bundles.sh $*" >> "$CALLS"
FAKE
chmod +x "$tree/scripts/phonon-bundles.sh"
for fake in build-ish.sh fetch-phonon.sh; do
  printf '#!/bin/sh\nexit 0\n' > "$tree/scripts/$fake"
  chmod +x "$tree/scripts/$fake"
done
touch "$tree/Distribution/ExportOptions.plist"
pins="$tree/Topo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
mkdir -p "$(dirname "$pins")"
pin() { printf '{"originHash":"%s","pins":[{"identity":"fluidaudio","state":{"version":"%s"}}],"version":3}\n' "${2:-aaa}" "$1"; }
pin one > "$pins"  # as Package.resolved is, JSON, here on one line
git -C "$tree" init -q -b scratch
git -C "$tree" config core.hooksPath /dev/null
git -C "$tree" -c user.name=test -c user.email=test@example.com add -A
git -C "$tree" -c user.name=test -c user.email=test@example.com commit -q -m tree
git -C "$tree" update-ref refs/remotes/origin/main HEAD

# xcodebuild: one line per call, and whether the key it was pointed at is a key as it runs.
cat > "$work/bin/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
line="$*" key="" next="" export="" archive=""
for argument in "$@"; do
  [ "$next" = key ] && key="$argument"
  [ "$next" = export ] && export="$argument"
  [ "$next" = archive ] && archive="$argument"
  next=""
  case "$argument" in -authenticationKeyPath) next=key ;; -exportPath) next=export ;; -archivePath) next=archive ;; esac
done
# An archive's app, carrying a stray voice bundle when STRAY_VOICE is set.
if [ "$1" = archive ] && [ -n "$archive" ]; then
  mkdir -p "$archive/Products/Applications/Topo.app"
  [ -z "${STRAY_VOICE-}" ] || mkdir -p "$archive/Products/Applications/Topo.app/phonon-40m-en"
fi
state=none
if [ -n "$key" ]; then
  if openssl pkey -in "$key" -noout 2>/dev/null; then state=key; else state=not-a-key; fi
fi
echo "xcodebuild [$state] $line" >> "$CALLS"
# What package state a resolution would run against, and a state left behind as Xcode leaves one.
packages=""; previous=""
for argument in "$@"; do [ "$previous" = -clonedSourcePackagesDirPath ] && packages="$argument"; previous="$argument"; done
if [ -n "$packages" ]; then
  echo "packages: $([ -e "$packages/workspace-state.json" ] && echo kept || echo fresh) pins: $(jq -r '.pins[0].state.version' "$packages/Package.resolved" 2>/dev/null)" >> "$CALLS"
  touch "$packages/workspace-state.json"
fi
[ -z "$export" ] || { mkdir -p "$export"; touch "$export/Topo.ipa"; }
FAKE
cat > "$work/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
state=none
[ -z "${API_PRIVATE_KEYS_DIR:-}" ] || state="$(ls "$API_PRIVATE_KEYS_DIR")"
echo "xcrun [$state] $*" >> "$CALLS"
FAKE
# The keychain: an item is a file under $KEYCHAIN named for its service, and with none set it
# holds nothing.
cat > "$work/bin/security" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = find-generic-password ] && [ "$2" = -s ] && [ "$4" = -w ] && [ -f "${KEYCHAIN:-/nowhere}/$3" ] || exit 44
cat "$KEYCHAIN/$3"
FAKE
chmod +x "$work/bin/xcodebuild" "$work/bin/xcrun" "$work/bin/security"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -out "$work/key.p8" 2>/dev/null \
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
grep '^xcodebuild \[key\] archive ' "$work/with" | grep -q -- "TOPO_SOURCE_COMMIT=$(git -C "$tree" rev-parse HEAD) TOPO_CHANNEL=testflight" \
    || fail "the archive was not told its commit and its channel: $(cat "$work/with")"
grep -q '^xcrun \[AuthKey_KEYID12345.p8\] altool --upload-app .* --apiKey KEYID12345 --apiIssuer an-issuer$' "$work/with" \
    || fail "altool was not given the key where it looks: $(cat "$work/with")"
[ -z "$(ls "$work/tmp")" ] || fail "the key outlived the run: $(ls "$work/tmp")"

# With the key in the keychain, as hex, and nothing in the environment, validating.
mkdir -p "$work/keychain"
printf 'KEYID12345\n' > "$work/keychain/topo-asc-key-id"
printf 'an-issuer\n' > "$work/keychain/topo-asc-issuer-id"
printf '%s\n' "$hex" > "$work/keychain/topo-asc-private-key"
KEYCHAIN="$work/keychain" run "$work/kept" --validate || fail "a validation with the keychain's key failed: $(cat "$work/out")"
[ "$(grep -c -- '^xcodebuild \[key\] .* -authenticationKeyPath .*/AuthKey_KEYID12345.p8 -authenticationKeyID KEYID12345 -authenticationKeyIssuerID an-issuer' "$work/kept")" = 2 ] \
    || fail "the archive and the export were not each handed the keychain's key: $(cat "$work/kept")"
grep -q '^xcrun \[AuthKey_KEYID12345.p8\] altool --validate-app .* --apiKey KEYID12345 --apiIssuer an-issuer$' "$work/kept" \
    || fail "altool was not asked to validate with the keychain's key: $(cat "$work/kept")"
grep -q -- '--upload-app' "$work/kept" && fail "a validation uploaded"
[ -z "$(ls "$work/tmp")" ] || fail "the keychain's key outlived the run: $(ls "$work/tmp")"

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
if run "$work/unasked" --validate; then fail "a validation with no key was not refused"; fi
[ ! -s "$work/unasked" ] || fail "a validation with no key built something first: $(cat "$work/unasked")"
grep -q 'No App Store Connect API key' "$work/out" || fail "the refusal of a validation does not say there is no key: $(cat "$work/out")"

# The packages resolve into build/packages, kept for the pins they were resolved from, under
# whatever originHash, and made afresh for any other.
rm -rf "$tree/build/packages"
run "$work/packages-first" || fail "an archive failed: $(cat "$work/out")"
grep '^xcodebuild \[none\] archive ' "$work/packages-first" | grep -q -- "-clonedSourcePackagesDirPath $tree/build/packages " \
    || fail "the archive does not resolve into build/packages: $(cat "$work/packages-first")"
grep -qx 'packages: fresh pins: one' "$work/packages-first" || fail "a first archive did not resolve against a fresh state naming its pins: $(cat "$work/packages-first")"
sed -i '' 's/"aaa"/"bbb"/' "$tree/build/packages/Package.resolved"
run "$work/packages-same" || fail "an archive failed: $(cat "$work/out")"
grep -qx 'packages: kept pins: one' "$work/packages-same" || fail "the same pins under another originHash did not keep the state: $(cat "$work/packages-same")"
pin two > "$pins"
git -C "$tree" -c user.name=test -c user.email=test@example.com commit -q -am pins
git -C "$tree" update-ref refs/remotes/origin/main HEAD
run "$work/packages-moved" || fail "an archive failed: $(cat "$work/out")"
grep -qx 'packages: fresh pins: two' "$work/packages-moved" || fail "pins that moved did not make the state afresh: $(cat "$work/packages-moved")"

# The voice: no pack unless asked; asked, it is packaged and uploaded before the build.
grep -q 'phonon-bundles.sh\|upload-asset-pack' "$work/with" && fail "an upload not asked for the voice touched its pack: $(cat "$work/with")"
ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/voice" --upload --voice \
    || fail "an upload with the voice failed: $(cat "$work/out")"
order="$(grep -oE '^(phonon-bundles.sh package|xcrun \[[^]]*\] altool --upload-asset-pack|xcrun \[[^]]*\] altool --upload-app)' "$work/voice" | sed 's/\[[^]]*\] //')"
[ "$order" = "$(printf 'phonon-bundles.sh package\nxcrun altool --upload-asset-pack\nxcrun altool --upload-app')" ] \
    || fail "the voice's pack was not packaged, then uploaded, then the build: $(cat "$work/voice")"
grep -q -- '--upload-asset-pack .*/phonon/phonon-40m-en.aar --apple-id 6826966978 --wait --apiKey KEYID12345 --apiIssuer an-issuer$' "$work/voice" \
    || fail "the pack was not uploaded to Topo's record with the key: $(cat "$work/voice")"

# An archive carrying the voice's bundle is refused before anything is uploaded.
if STRAY_VOICE=1 ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/stray" --upload; then
    fail "an archive carrying the voice's bundle was uploaded"
fi
grep -q -- 'altool' "$work/stray" && fail "an archive carrying the voice's bundle reached altool: $(cat "$work/stray")"
grep -q "carries the voice's bundle" "$work/out" || fail "the refusal does not say the archive carries the bundle: $(cat "$work/out")"

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed" >&2; exit 1; }
echo "archive-upload.sh: an archive carrying the voice's bundle is refused; --voice packages the voice's pack and uploads it before the build; with a key kept as hex, in the environment or the keychain, the archive, the export and altool each get it as a .p8 that is a key, and it is gone after; what is not a key builds nothing; with none the archive runs plain and an upload or a validation is refused before anything is built; the packages resolve into build/packages, kept for the pins they were resolved from"
