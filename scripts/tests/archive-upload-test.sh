#!/usr/bin/env bash
# scripts/archive-upload.sh against a fake xcodebuild, altool and keychain, in a repository made
# here: with a key, kept as the hex `security -w` prints, the archive and the export are each
# handed it as a .p8 openssl reads, altool finds it, and it is gone afterwards; with no key the
# archive runs without one and an upload is refused before anything is built; the archive resolves
# its packages into build/packages, kept for the pins they were resolved from and made afresh for
# any other; and no exported variable whose name says it holds a secret, the key's own among
# them, reaches either xcodebuild, which writes its environment into the build description. An
# upload is refused before anything is built unless, for each asset pack not uploaded with it, the
# bundle its script pins is the one Distribution/asset-packs.json records and App Store Connect's
# internal beta version is the recorded one, ready; the refusal names the flag to run with, and a
# pack uploaded with the build is recorded at the version App Store Connect lists after it.
#
#   scripts/tests/archive-upload-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
# A service account in the caller's environment is no part of any case: each that wants one sets it.
unset OP_SERVICE_ACCOUNT_TOKEN
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

tree="$work/tree"
mkdir -p "$tree/scripts" "$tree/Distribution" "$work/bin"
cp "$here/../archive-upload.sh" "$here/../asc-pem.sh" "$here/../check-built-assets.sh" "$here/../secret-env.sh" "$tree/scripts/"
# The bundle scripts: `pin` answers VOICE_PIN or EAR_PIN, the bundle the record names unless set.
cat > "$tree/scripts/phonon-bundles.sh" <<'FAKE'
#!/bin/sh
[ "$1" = pin ] && { echo "${VOICE_PIN:-voice-one}"; exit 0; }
echo "phonon-bundles.sh $*" >> "$CALLS"
FAKE
chmod +x "$tree/scripts/phonon-bundles.sh"
cat > "$tree/scripts/ear-bundle.sh" <<'FAKE'
#!/bin/sh
[ "$1" = pin ] && { echo "${EAR_PIN:-ear-one}"; exit 0; }
echo "ear-bundle.sh $*" >> "$CALLS"
FAKE
chmod +x "$tree/scripts/ear-bundle.sh"
for fake in build-ish.sh fetch-phonon.sh; do
  printf '#!/bin/sh\necho %s >> "$CALLS"\n' "$fake" > "$tree/scripts/$fake"
  chmod +x "$tree/scripts/$fake"
done
touch "$tree/Distribution/ExportOptions.plist"
record='{"parakeet-ultra":{"version":"1","bundle":"ear-one"},"phonon-40m-en":{"version":"1","bundle":"voice-one"}}'
printf '%s\n' "$record" > "$tree/Distribution/asset-packs.json"
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
# Whether its environment holds MARKER's value under any other name.
if [ -n "${MARKER-}" ] && env | grep -v '^MARKER=' | grep -qF "$MARKER"; then echo "xcodebuild secret in its environment" >> "$CALLS"; fi
# What package state a resolution would run against, and a state left behind as Xcode leaves one.
packages=""; previous=""
for argument in "$@"; do [ "$previous" = -clonedSourcePackagesDirPath ] && packages="$argument"; previous="$argument"; done
if [ -n "$packages" ]; then
  echo "packages: $([ -e "$packages/workspace-state.json" ] && echo kept || echo fresh) pins: $(jq -r '.pins[0].state.version' "$packages/Package.resolved" 2>/dev/null)" >> "$CALLS"
  touch "$packages/workspace-state.json"
fi
[ -z "$export" ] || { mkdir -p "$export"; touch "$export/Topo.ipa"; }
FAKE
# xcrun: App Store Connect's packs are $PACKS/<pack>, holding altool's listing as it prints it (no
# file is a pack with no version, which altool answers with nothing and exit 0, and `fail` a
# listing that fails); an upload of a pack moves its listing to <pack>.after where there is one.
cat > "$work/bin/xcrun" <<'FAKE'
#!/usr/bin/env bash
state=none
[ -z "${API_PRIVATE_KEYS_DIR:-}" ] || state="$(ls "$API_PRIVATE_KEYS_DIR")"
echo "xcrun [$state] $*" >> "$CALLS"
# Which key altool was given, by its public half, so a case can say whose key it was.
[ -z "${API_PRIVATE_KEYS_DIR:-}" ] || echo "xcrun key $(openssl pkey -in "$API_PRIVATE_KEYS_DIR"/*.p8 -pubout 2>/dev/null | shasum | cut -d' ' -f1)" >> "$CALLS"
pack="" next=""
for argument in "$@"; do
  [ "$next" = pack ] && pack="$argument"; next=""
  [ "$argument" = --asset-pack-identifier ] && next=pack
done
case "$2" in
  --list-asset-pack-versions)
    [ "$(cat "$PACKS/$pack" 2>/dev/null)" = fail ] && { echo "ERROR: could not list" >&2; exit 1; }
    cat "$PACKS/$pack" 2>/dev/null; exit 0 ;;
  --upload-asset-pack)
    pack="$(basename "$3" .aar)"
    [ ! -f "$PACKS/$pack.after" ] || mv "$PACKS/$pack.after" "$PACKS/$pack" ;;
esac
FAKE
# The keychain: an item is a file under $KEYCHAIN named for its service, and with none set it
# holds nothing.
cat > "$work/bin/security" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = find-generic-password ] && [ "$2" = -s ] && [ "$4" = -w ] && [ -f "${KEYCHAIN:-/nowhere}/$3" ] || exit 44
cat "$KEYCHAIN/$3"
FAKE
# 1Password: a field is a file under $OPVAULT named for it, read only as the item
# `Topo App Store Connect` in Homelab; with none set it reads nothing.
cat > "$work/bin/op" <<'FAKE'
#!/usr/bin/env bash
case "$0" in */.local/shims/*) who=shim ;; *) who=path ;; esac
echo "$who op $*" >> "${OPCALLS:-/dev/null}"
case "$*" in "read op://Homelab/Topo App Store Connect/"*) ;; *) exit 1 ;; esac
f="${2##*/}"; [ -f "${OPVAULT:-/nowhere}/$f" ] || exit 1
cat "$OPVAULT/$f"
FAKE
chmod +x "$work/bin/xcodebuild" "$work/bin/xcrun" "$work/bin/security" "$work/bin/op"
# The script takes dotfiles' op shim where it is installed; the run's home has the fake as its shim.
mkdir -p "$work/home/.local/shims"
cp "$work/bin/op" "$work/home/.local/shims/op"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -out "$work/key.p8" 2>/dev/null \
    || { echo "FAIL: could not make a key to test with" >&2; exit 1; }
hex="$(xxd -p "$work/key.p8" | tr -d '\n')"

# listing <version> <state> [internal] [own state]: altool's listing of a pack whose highest
# version is <version>, its internal beta release in <state> and its own state [own state] (<state>
# unless named), with every version below it listed too, ready; its internal beta version is
# [internal], the highest unless named.
listing() {
  jq -n --arg v "$1" --arg s "$2" --arg i "${3:-$1}" --arg o "${4:-$2}" '{
    assetPack: { relationships: { internalBetaVersion: { data: { type: "backgroundAssetVersions", id: ("id-" + $i) } } } },
    assetPackVersions: [range(1; ($v | tonumber) + 1) | tostring | { assetPackVersionID: ("id-" + .), version: .,
      internalBetaReleaseState: (if . == $v then $s else "READY_FOR_TESTING" end), state: (if . == $v then $o else "READY_FOR_TESTING" end) }]
  }'
}
served() { # served: App Store Connect as the record has it, each pack's version 1 ready
  rm -rf "$work/packs"; mkdir -p "$work/packs"
  listing 1 READY_FOR_TESTING > "$work/packs/parakeet-ultra"
  listing 1 READY_FOR_TESTING > "$work/packs/phonon-40m-en"
}
served
run() { # run <calls file> <arguments...>, with the environment the caller set
    local calls="$1"; shift
    : > "$calls"
    CALLS="$calls" PACKS="$work/packs" HOME="$work/home" PATH="$work/bin:$PATH" BUILD=7 TMPDIR="$work/tmp" "$tree/scripts/archive-upload.sh" "$@" > "$work/out" 2>&1
}
mkdir -p "$work/tmp"

# With a key, uploading.
ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/with" --upload \
    || fail "an upload with a key failed: $(cat "$work/out")"
# The same, with secrets exported beside the key: neither the key nor they reach a build.
MARKER="$hex" CLAUDE_SETUP_TOKEN="$hex" GH_TOKEN="$hex" ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" \
    run "$work/secrets" --upload || fail "an upload with secrets exported failed: $(cat "$work/out")"
[ "$(grep -c '^xcodebuild \[key\] ' "$work/secrets")" = 2 ] && ! grep -q '^xcodebuild secret' "$work/secrets" \
    || fail "a secret reached xcodebuild's environment, or it did not run: $(grep -c '^xcodebuild' "$work/secrets") calls"
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

# Over ssh the keychain answers empty with exit 0: with a service account, the key is 1Password's.
mkdir -p "$work/blank" "$work/vault"
for item in topo-asc-key-id topo-asc-issuer-id topo-asc-private-key; do : > "$work/blank/$item"; done
printf 'KEYID12345\n' > "$work/vault/key_id"
printf 'an-issuer\n' > "$work/vault/issuer_id"
cp "$work/key.p8" "$work/vault/private_key"
pub() { openssl pkey -in "$1" -pubout 2>/dev/null | shasum | cut -d' ' -f1; }
: > "$work/opcalls"
KEYCHAIN="$work/blank" OPVAULT="$work/vault" OPCALLS="$work/opcalls" OP_SERVICE_ACCOUNT_TOKEN=ops_fake run "$work/vaulted" --validate \
    || fail "a validation with 1Password's key failed: $(cat "$work/out")"
[ "$(grep -c '^shim op read ' "$work/opcalls")" = 3 ] && ! grep -q '^path op ' "$work/opcalls" \
    || fail "1Password was not asked through the shim, three times: $(cat "$work/opcalls")"
grep -qx "xcrun key $(pub "$work/key.p8")" "$work/vaulted" || fail "altool was not given 1Password's key: $(grep '^xcrun key' "$work/vaulted")"
[ "$(grep -c '^xcodebuild \[key\] ' "$work/vaulted")" = 2 ] || fail "the archive and the export were not each handed 1Password's key as a key: $(grep '^xcodebuild' "$work/vaulted")"
grep -q '^xcrun \[AuthKey_KEYID12345.p8\] altool --validate-app .* --apiKey KEYID12345 --apiIssuer an-issuer$' "$work/vaulted" \
    || fail "altool was not given 1Password's key: $(cat "$work/vaulted")"
[ -z "$(ls "$work/tmp")" ] || fail "1Password's key outlived the run: $(ls "$work/tmp")"
# Without a service account 1Password is not asked, and the empty keychain is no key.
: > "$work/opcalls"
if (unset OP_SERVICE_ACCOUNT_TOKEN; KEYCHAIN="$work/blank" OPVAULT="$work/vault" OPCALLS="$work/opcalls" run "$work/unvaulted" --validate); then
    fail "an empty keychain with no service account validated"
fi
[ ! -s "$work/opcalls" ] || fail "1Password was asked with no service account: $(cat "$work/opcalls")"
grep -q 'No App Store Connect API key' "$work/out" || fail "an empty keychain is not said as no key: $(cat "$work/out")"
# A key in part is said, and builds nothing.
rm "$work/vault/issuer_id"
if KEYCHAIN="$work/blank" OPVAULT="$work/vault" OP_SERVICE_ACCOUNT_TOKEN=ops_fake run "$work/partial"; then
    fail "a key in part was taken"
fi
[ ! -s "$work/partial" ] || fail "a key in part built something: $(cat "$work/partial")"
grep -q 'incomplete: the environment, the keychain and 1Password gave no issuer id' "$work/out" || fail "a key in part is not said: $(cat "$work/out")"
printf 'an-issuer\n' > "$work/vault/issuer_id"
# With no shim installed, 1Password is asked through the op on PATH.
mkdir -p "$work/home-bare"
: > "$work/opcalls"
KEYCHAIN="$work/blank" OPVAULT="$work/vault" OPCALLS="$work/opcalls" OP_SERVICE_ACCOUNT_TOKEN=ops_fake \
  CALLS="$work/bare" PACKS="$work/packs" HOME="$work/home-bare" PATH="$work/bin:$PATH" BUILD=7 TMPDIR="$work/tmp" "$tree/scripts/archive-upload.sh" --validate > "$work/out" 2>&1 \
    || fail "with no shim, a validation with 1Password's key failed: $(cat "$work/out")"
[ "$(grep -c '^path op read ' "$work/opcalls")" = 3 ] && ! grep -q '^shim op ' "$work/opcalls" \
    || fail "with no shim, 1Password was not asked through PATH's op: $(cat "$work/opcalls")"
# Each part from the first source that has it: the key id from the environment, the issuer
# from the keychain, the private key from 1Password alone; and 1Password, holding its own
# key id and issuer, is asked only for the part the others lack.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -out "$work/other.p8" 2>/dev/null
mkdir -p "$work/mixed-keychain" "$work/mixed-vault"
printf 'kc-issuer\n' > "$work/mixed-keychain/topo-asc-issuer-id"
printf 'KEYCHAINID\n' > "$work/mixed-keychain/topo-asc-key-id"
printf 'VAULTID000\n' > "$work/mixed-vault/key_id"
printf 'vault-issuer\n' > "$work/mixed-vault/issuer_id"
cp "$work/other.p8" "$work/mixed-vault/private_key"
: > "$work/opcalls"
ASC_KEY_ID=ENVKEYID00 KEYCHAIN="$work/mixed-keychain" OPVAULT="$work/mixed-vault" OPCALLS="$work/opcalls" OP_SERVICE_ACCOUNT_TOKEN=ops_fake run "$work/mixed" --validate \
    || fail "a key from three sources failed: $(cat "$work/out")"
grep -q '^xcrun \[AuthKey_ENVKEYID00.p8\] altool --validate-app .* --apiKey ENVKEYID00 --apiIssuer kc-issuer$' "$work/mixed" \
    || fail "the environment's key id and the keychain's issuer did not win: $(grep '^xcrun' "$work/mixed")"
grep -qx "xcrun key $(pub "$work/other.p8")" "$work/mixed" || fail "altool was not given 1Password's private key: $(grep '^xcrun key' "$work/mixed")"
[ "$(cat "$work/opcalls")" = "shim op read op://Homelab/Topo App Store Connect/private_key" ] \
    || fail "1Password was asked for more than the part the others lack: $(cat "$work/opcalls")"

# Each part with a value in all three sources: the environment's wins, and 1Password is not
# asked. Then without the environment's: the keychain's wins over 1Password's.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -pkeyopt ec_param_enc:named_curve -out "$work/kc.p8" 2>/dev/null
mkdir -p "$work/all-keychain" "$work/all-vault"
printf 'KEYCHAINID\n' > "$work/all-keychain/topo-asc-key-id"
printf 'kc-issuer\n' > "$work/all-keychain/topo-asc-issuer-id"
xxd -p "$work/kc.p8" | tr -d '\n' > "$work/all-keychain/topo-asc-private-key"
printf 'VAULTID000\n' > "$work/all-vault/key_id"
printf 'vault-issuer\n' > "$work/all-vault/issuer_id"
cp "$work/other.p8" "$work/all-vault/private_key"
: > "$work/opcalls"
ASC_KEY_ID=ENVKEYID00 ASC_ISSUER_ID=env-issuer ASC_PRIVATE_KEY="$hex" KEYCHAIN="$work/all-keychain" OPVAULT="$work/all-vault" OPCALLS="$work/opcalls" OP_SERVICE_ACCOUNT_TOKEN=ops_fake \
  run "$work/all-env" --validate || fail "every part from three sources failed: $(cat "$work/out")"
grep -q '^xcrun \[AuthKey_ENVKEYID00.p8\] altool --validate-app .* --apiKey ENVKEYID00 --apiIssuer env-issuer$' "$work/all-env" \
    || fail "the environment's issuer did not win over the keychain's and 1Password's: $(grep '^xcrun' "$work/all-env")"
grep -qx "xcrun key $(pub "$work/key.p8")" "$work/all-env" || fail "the environment's private key did not win over the keychain's and 1Password's: $(grep '^xcrun key' "$work/all-env")"
[ ! -s "$work/opcalls" ] || fail "1Password was asked with every part in the environment: $(cat "$work/opcalls")"
: > "$work/opcalls"
KEYCHAIN="$work/all-keychain" OPVAULT="$work/all-vault" OPCALLS="$work/opcalls" OP_SERVICE_ACCOUNT_TOKEN=ops_fake \
  run "$work/all-kc" --validate || fail "every part from the keychain and 1Password failed: $(cat "$work/out")"
grep -q '^xcrun \[AuthKey_KEYCHAINID.p8\] altool --validate-app .* --apiKey KEYCHAINID --apiIssuer kc-issuer$' "$work/all-kc" \
    || fail "the keychain's issuer did not win over 1Password's: $(grep '^xcrun' "$work/all-kc")"
grep -qx "xcrun key $(pub "$work/kc.p8")" "$work/all-kc" || fail "the keychain's private key did not win over 1Password's: $(grep '^xcrun key' "$work/all-kc")"
[ ! -s "$work/opcalls" ] || fail "1Password was asked with every part in the keychain: $(cat "$work/opcalls")"

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

# The voice: no pack unless asked; asked, it is packaged and uploaded before the build, and
# recorded at the version App Store Connect lists after it.
grep -q 'phonon-bundles.sh\|upload-asset-pack' "$work/with" && fail "an upload not asked for the voice touched its pack: $(cat "$work/with")"
listing 2 READY_FOR_TESTING > "$work/packs/phonon-40m-en.after"
VOICE_PIN=voice-two ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/voice" --upload --voice \
    || fail "an upload with the voice failed: $(cat "$work/out")"
order="$(grep -oE '^(phonon-bundles.sh package|xcrun \[[^]]*\] altool --upload-asset-pack|xcrun \[[^]]*\] altool --upload-app)' "$work/voice" | sed 's/\[[^]]*\] //')"
[ "$order" = "$(printf 'phonon-bundles.sh package\nxcrun altool --upload-asset-pack\nxcrun altool --upload-app')" ] \
    || fail "the voice's pack was not packaged, then uploaded, then the build: $(cat "$work/voice")"
grep -q -- '--upload-asset-pack .*/phonon/phonon-40m-en.aar --apple-id 6826966978 --wait --apiKey KEYID12345 --apiIssuer an-issuer$' "$work/voice" \
    || fail "the pack was not uploaded to Topo's record with the key: $(cat "$work/voice")"
[ "$(jq -c '.["phonon-40m-en"]' "$tree/Distribution/asset-packs.json")" = '{"version":"2","bundle":"voice-two"}' ] \
    || fail "the voice's upload was not recorded at App Store Connect's new version: $(cat "$tree/Distribution/asset-packs.json")"
grep -q 'phonon-40m-en: version 2 recorded in Distribution/asset-packs.json; commit it' "$work/out" || fail "the voice's record is not said: $(cat "$work/out")"
grep -q -- '--list-asset-pack-versions .*--asset-pack-identifier parakeet-ultra' "$work/voice" || fail "an upload with the voice did not check the ear's pack: $(cat "$work/voice")"
git -C "$tree" checkout -q Distribution/asset-packs.json; served

# The ear: no pack unless asked; asked, it is packaged and uploaded before the build, whatever
# the record says of its pin, and recorded at the version App Store Connect lists after it.
grep -q 'ear-bundle.sh' "$work/with" "$work/voice" && fail "an upload not asked for the ear touched its pack"
listing 2 READY_FOR_TESTING > "$work/packs/parakeet-ultra.after"
EAR_PIN=ear-two ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/ear" --upload --ear \
    || fail "an upload with the ear failed: $(cat "$work/out")"
order="$(grep -oE '^(ear-bundle.sh package|phonon-bundles.sh package|xcrun \[[^]]*\] altool --upload-asset-pack|xcrun \[[^]]*\] altool --upload-app)' "$work/ear" | sed 's/\[[^]]*\] //')"
[ "$order" = "$(printf 'ear-bundle.sh package\nxcrun altool --upload-asset-pack\nxcrun altool --upload-app')" ] \
    || fail "the ear's pack was not packaged, then uploaded, then the build: $(cat "$work/ear")"
grep -q -- '--upload-asset-pack .*/ear/parakeet-ultra.aar --apple-id 6826966978 --wait --apiKey KEYID12345 --apiIssuer an-issuer$' "$work/ear" \
    || fail "the ear's pack was not uploaded to Topo's record with the key: $(cat "$work/ear")"
[ "$(jq -c '.["parakeet-ultra"]' "$tree/Distribution/asset-packs.json")" = '{"version":"2","bundle":"ear-two"}' ] \
    || fail "the ear's upload was not recorded at App Store Connect's new version: $(cat "$tree/Distribution/asset-packs.json")"
[ "$(jq -c '.["phonon-40m-en"]' "$tree/Distribution/asset-packs.json")" = '{"version":"1","bundle":"voice-one"}' ] \
    || fail "the ear's upload changed the voice's record: $(cat "$tree/Distribution/asset-packs.json")"
git -C "$tree" checkout -q Distribution/asset-packs.json; served
# A pack whose new version App Store Connect does not serve after its upload is not recorded,
# and the build is not uploaded.
listing 2 PROCESSING > "$work/packs/parakeet-ultra.after"
if EAR_PIN=ear-two ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/ear-unready" --upload --ear; then
    fail "an upload whose new ear pack is not ready went on"
fi
grep -q -- '--upload-app' "$work/ear-unready" && fail "the build was uploaded beside an ear pack that is not ready: $(cat "$work/ear-unready")"
git -C "$tree" diff --quiet -- Distribution/asset-packs.json || fail "an ear pack that is not ready was recorded"
grep -q 'after its upload App Store Connect serves version 2 (PROCESSING)' "$work/out" || fail "the unready pack is not said: $(cat "$work/out")"
served
# after <case> <what the refusal says> [.after listing]: an ear upload App Store Connect does not
# answer with a new served version is not recorded, the build is not uploaded, and the refusal
# says the pack went up.
after() {
  local name="$1" says="$2"
  if EAR_PIN=ear-two ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/$name" --upload --ear; then
    fail "$name: the upload went on"
  fi
  grep -q -- '--upload-asset-pack' "$work/$name" || fail "$name: the pack was not uploaded: $(cat "$work/$name")"
  grep -q -- '--upload-app' "$work/$name" && fail "$name: the build was uploaded: $(cat "$work/$name")"
  git -C "$tree" diff --quiet -- Distribution/asset-packs.json || fail "$name: the pack was recorded: $(cat "$tree/Distribution/asset-packs.json")"
  grep -q -- "$says" "$work/out" || fail "$name: the refusal does not say '$says': $(cat "$work/out")"
  grep -q 'The pack was uploaded and the build was not' "$work/out" || fail "$name: the refusal does not say the pack went up: $(cat "$work/out")"
  grep -q 'Nothing was built' "$work/out" && fail "$name: the refusal says nothing was built: $(cat "$work/out")"
  git -C "$tree" checkout -q Distribution/asset-packs.json; served
}
after ear-unchanged 'serves version 1 (READY_FOR_TESTING), a version listed before the upload, its highest is 1, and 0 version(s) are new'
listing 2 READY_FOR_TESTING 1 > "$work/packs/parakeet-ultra.after"
after ear-not-served 'serves version 1 (READY_FOR_TESTING), a version listed before the upload, its highest is 2, and 1 version(s) are new'
listing 3 READY_FOR_TESTING 2 > "$work/packs/parakeet-ultra.after"
after ear-overtaken 'serves version 2 (READY_FOR_TESTING), a new one, its highest is 3, and 2 version(s) are new'
# A pack's first upload, with no version listed before it, is recorded at the version it made.
rm "$work/packs/parakeet-ultra"
listing 1 READY_FOR_TESTING > "$work/packs/parakeet-ultra.after"
EAR_PIN=ear-two ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/ear-first" --upload --ear \
    || fail "a pack's first upload was refused: $(cat "$work/out")"
[ "$(jq -c '.["parakeet-ultra"]' "$tree/Distribution/asset-packs.json")" = '{"version":"1","bundle":"ear-two"}' ] \
    || fail "a pack's first upload was not recorded at version 1: $(cat "$tree/Distribution/asset-packs.json")"
grep -q -- '--upload-app' "$work/ear-first" || fail "a pack's first upload did not upload the build: $(cat "$work/ear-first")"
git -C "$tree" checkout -q Distribution/asset-packs.json; served
# Another upload landing between the listings, served and highest, is not taken for this one's.
listing 3 READY_FOR_TESTING > "$work/packs/parakeet-ultra.after"
after ear-raced 'serves version 3 (READY_FOR_TESTING), a new one, its highest is 3, and 2 version(s) are new'
echo fail > "$work/packs/parakeet-ultra.after"
after ear-unread-after "parakeet-ultra: App Store Connect's versions of the pack could not be read: ERROR: could not list"
ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/ear-local" --ear \
    || fail "packaging the ear failed: $(cat "$work/out")"
grep -q 'altool' "$work/ear-local" && fail "--ear without --upload reached altool: $(cat "$work/ear-local")"

# --validate alone asks App Store Connect nothing of the packs.
grep -q -- '--list-asset-pack-versions' "$work/kept" && fail "a validation listed the packs: $(cat "$work/kept")"
grep -q -- '--list-asset-pack-versions .*--asset-pack-identifier parakeet-ultra' "$work/with" \
  && grep -q -- '--list-asset-pack-versions .*--asset-pack-identifier phonon-40m-en' "$work/with" \
  || fail "an upload did not check both packs: $(cat "$work/with")"

# An upload without a pack's flag is refused before anything is built, naming what to run, where:
# refused <case> <pattern the refusal says> [VAR=value...]
refused() {
  local name="$1" says="$2"; shift 2
  : > "$work/$name"
  if env "$@" ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" CALLS="$work/$name" PACKS="$work/packs" HOME="$work/home" PATH="$work/bin:$PATH" BUILD=7 TMPDIR="$work/tmp" \
      "$tree/scripts/archive-upload.sh" --upload > "$work/out" 2>&1; then
    fail "$name: the upload was not refused"
  fi
  grep -q '^xcodebuild\|upload-\|build-ish\|fetch-phonon' "$work/$name" && fail "$name: something was built or uploaded: $(cat "$work/$name")"
  grep -q -- "$says" "$work/out" || fail "$name: the refusal does not say '$says': $(cat "$work/out")"
  [ -z "$(ls "$work/tmp")" ] || fail "$name: the key outlived the refusal: $(ls "$work/tmp")"
}
refused ear-moved 'parakeet-ultra: the bundle scripts/ear-bundle.sh pins (ear-two) is not the one' EAR_PIN=ear-two
grep -q 'Run instead: scripts/archive-upload.sh --validate --upload --ear$' "$work/out" || fail "a moved ear pin does not name --ear: $(cat "$work/out")"
refused voice-moved 'phonon-40m-en: the bundle scripts/phonon-bundles.sh pins (voice-two) is not the one' VOICE_PIN=voice-two
grep -q 'Run instead: scripts/archive-upload.sh --validate --upload --voice$' "$work/out" || fail "a moved voice pin does not name --voice: $(cat "$work/out")"
rm "$work/packs/parakeet-ultra"
refused ear-none 'parakeet-ultra: App Store Connect has no version of the pack'
grep -q 'Run instead: scripts/archive-upload.sh --validate --upload --ear$' "$work/out" || fail "a pack with no version does not name --ear: $(cat "$work/out")"
listing 2 READY_FOR_TESTING > "$work/packs/parakeet-ultra"
refused ear-ahead 'parakeet-ultra: App Store Connect serves version 2 (the highest is 2) and Distribution/asset-packs.json records version 1'
listing 1 PROCESSING > "$work/packs/parakeet-ultra"
refused ear-unready 'parakeet-ultra: version 1 on App Store Connect is PROCESSING, not READY_FOR_TESTING'
echo fail > "$work/packs/parakeet-ultra"
refused ear-unread "parakeet-ultra: App Store Connect's versions of the pack could not be read"
echo 'not json' > "$work/packs/parakeet-ultra"
refused ear-garbled "parakeet-ultra: App Store Connect's listing of the pack is not one document naming an internal beta version"
# A whole listing followed by damage is not one document.
{ listing 1 READY_FOR_TESTING; echo 'not json'; } > "$work/packs/parakeet-ultra"
refused ear-trailing "parakeet-ultra: App Store Connect's listing of the pack is not one document naming an internal beta version"
# Two whole listings are not one.
{ listing 1 READY_FOR_TESTING; listing 1 READY_FOR_TESTING; } > "$work/packs/parakeet-ultra"
refused ear-twice "parakeet-ultra: App Store Connect's listing of the pack is not one document naming an internal beta version"
# A listing with no internal beta version, whose versions carry no ids, names none.
printf '{"assetPackVersions":[{"version":"1","internalBetaReleaseState":"READY_FOR_TESTING","state":"READY_FOR_TESTING"}]}\n' > "$work/packs/parakeet-ultra"
refused ear-no-ids "parakeet-ultra: App Store Connect's listing of the pack is not one document naming an internal beta version"
listing 1 FAILED > "$work/packs/parakeet-ultra"
refused ear-failed 'parakeet-ultra: version 1 on App Store Connect FAILED'
grep -q 'Run instead: scripts/archive-upload.sh --validate --upload --ear$' "$work/out" || fail "a FAILED version does not name --ear: $(cat "$work/out")"
served
# Readiness is the internal beta release's; the version's own state is not read.
listing 1 READY_FOR_TESTING 1 WAITING_FOR_REVIEW > "$work/packs/parakeet-ultra"
ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/ear-in-review" --upload \
    || fail "an ear pack ready for internal testing under another state of its own was refused: $(cat "$work/out")"
listing 1 PROCESSING 1 READY_FOR_TESTING > "$work/packs/parakeet-ultra"
refused ear-internal-unready 'parakeet-ultra: version 1 on App Store Connect is PROCESSING, not READY_FOR_TESTING'
# The internal beta version is the one judged, whatever the highest is.
listing 2 READY_FOR_TESTING 1 > "$work/packs/parakeet-ultra"
ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/ear-behind" --upload \
    || fail "an ear pack served at the recorded version beside a higher one was refused: $(cat "$work/out")"
served
printf '{"phonon-40m-en":{"version":"1","bundle":"voice-one"}}\n' > "$tree/Distribution/asset-packs.json"
git -C "$tree" -c user.name=test -c user.email=test@example.com commit -q -am 'no ear record'
git -C "$tree" update-ref refs/remotes/origin/main HEAD
refused ear-unrecorded 'parakeet-ultra: the bundle scripts/ear-bundle.sh pins (ear-one) is not the one Distribution/asset-packs.json records as uploaded from'
# A record that is not JSON is said as that, before anything is built, with both packs' flags too.
printf 'not json {\n' > "$tree/Distribution/asset-packs.json"
git -C "$tree" -c user.name=test -c user.email=test@example.com commit -q -am 'garbled record'
git -C "$tree" update-ref refs/remotes/origin/main HEAD
refused record-garbled 'Distribution/asset-packs.json is missing or not one JSON object of objects'
: > "$work/record-both"
if ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/record-both" --upload --ear --voice; then
    fail "an upload of both packs over a garbled record went on"
fi
grep -q '^xcodebuild\|upload-\|build-ish' "$work/record-both" && fail "an upload of both packs over a garbled record built something: $(cat "$work/record-both")"
grep -q 'Distribution/asset-packs.json is missing or not one JSON object of objects' "$work/out" || fail "a garbled record with both flags is not said: $(cat "$work/out")"
# Two documents are not one record, with both packs' flags too.
printf '{}\n{}\n' > "$tree/Distribution/asset-packs.json"
git -C "$tree" -c user.name=test -c user.email=test@example.com commit -q -am 'two records'
git -C "$tree" update-ref refs/remotes/origin/main HEAD
: > "$work/record-two"
if ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/record-two" --upload --ear --voice; then
    fail "an upload of both packs over a record of two documents went on"
fi
grep -q '^xcodebuild\|upload-\|build-ish' "$work/record-two" && fail "an upload over a record of two documents built something: $(cat "$work/record-two")"
grep -q 'Distribution/asset-packs.json is missing or not one JSON object of objects' "$work/out" || fail "a record of two documents is not said: $(cat "$work/out")"
# A pack's entry that is not an object is no record.
printf '{"parakeet-ultra":1,"phonon-40m-en":{"version":"1","bundle":"voice-one"}}\n' > "$tree/Distribution/asset-packs.json"
git -C "$tree" -c user.name=test -c user.email=test@example.com commit -q -am 'entry not an object'
git -C "$tree" update-ref refs/remotes/origin/main HEAD
refused record-entry 'Distribution/asset-packs.json is missing or not one JSON object of objects'
printf '%s\n' "$record" > "$tree/Distribution/asset-packs.json"
git -C "$tree" -c user.name=test -c user.email=test@example.com commit -q -am 'record'
git -C "$tree" update-ref refs/remotes/origin/main HEAD

# An archive carrying the voice's bundle is refused before anything is uploaded.
if STRAY_VOICE=1 ASC_KEY_ID=KEYID12345 ASC_ISSUER_ID=an-issuer ASC_PRIVATE_KEY="$hex" run "$work/stray" --upload; then
    fail "an archive carrying the voice's bundle was uploaded"
fi
grep -q -- 'altool --\(validate\|upload\)' "$work/stray" && fail "an archive carrying the voice's bundle reached altool: $(cat "$work/stray")"
grep -q "carries a model or weights" "$work/out" || fail "the refusal does not say the archive carries the bundle: $(cat "$work/out")"

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed" >&2; exit 1; }
echo "archive-upload.sh: an upload is refused before anything is built, naming the flag to run with, unless each pack not uploaded with it is served by App Store Connect at the version recorded for the bundle its script pins, and ready; a pack uploaded with the build is recorded at the version listed after it, and one not ready stops the build's upload; an archive carrying the voice's bundle is refused; --voice packages the voice's pack and uploads it before the build, and --ear the ear's; with a key kept as hex, in the environment or the keychain, or in 1Password where the keychain answers empty, the archive, the export and altool each get it as a .p8 that is a key, and it is gone after; what is not a key builds nothing; with none the archive runs plain and an upload or a validation is refused before anything is built; the packages resolve into build/packages, kept for the pins they were resolved from"
