#!/usr/bin/env bash
# Archives Topo for the App Store and, when asked, sends it to TestFlight.
#
#   scripts/archive-upload.sh                 # archive and export, nothing leaves this Mac
#   scripts/archive-upload.sh --upload        # ... and upload to App Store Connect
#   scripts/archive-upload.sh --validate      # ... and ask App Store Connect whether it would take it
#   scripts/archive-upload.sh --upload --voice  # ... and the voice's asset pack before the build
#   BUILD=42 scripts/archive-upload.sh        # a build number of your choosing
#
# The archive needs a Distribution certificate and an App Store provisioning
# profile for the team in Distribution/ExportOptions.plist; Xcode makes both
# on its own the first time somebody signed into the account archives here.
# The upload needs an App Store Connect API key, and docs/testflight.md says
# where to get one.
#
# The voice's weights are never in the archive: they are the Apple-hosted asset
# pack `phonon-40m-en`, which App Store Connect keeps apart from the builds.
# `--voice` packages it (scripts/phonon-bundles.sh) and, with `--upload`, sends
# it as a new version of the pack before the build; it is wanted only when the
# bundle has changed, since a build uses the pack's current version.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

scheme=Topo
project=Topo.xcodeproj
out="$root/build"
archive="$out/$scheme.xcarchive"
export_options="$root/Distribution/ExportOptions.plist"

upload=no
validate=no
voice=no
apple_id=6826966978
for argument in "$@"; do
  case "$argument" in
    --upload) upload=yes ;;
    --validate) validate=yes ;;
    --voice) voice=yes ;;
    -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $argument" >&2; exit 2 ;;
  esac
done

# TestFlight only insists on one thing: the build number goes up. Seconds
# since 2026 is monotonic, short enough to read, and needs nothing kept
# between runs.
build="${BUILD:-$(( ($(date +%s) - 1767225600) / 60 ))}"
echo "==> build $build"

# The guest's kernel is built from the fork at its pin, never committed; the archive links it.
"$(dirname "${BASH_SOURCE[0]}")/build-ish.sh"
# The voice's compiled core, fetched by checksum and never committed; the archive links it.
"$(dirname "${BASH_SOURCE[0]}")/fetch-phonon.sh"

# The About screen names the commit this build is as its corresponding source, which is only
# true of a clean tree whose commit is on GitHub.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "the tree has uncommitted changes; a build shipped from it has no commit that is its source" >&2
  exit 1
fi
commit="$(git rev-parse HEAD)"
[ -n "$(git branch -r --contains "$commit")" ] \
  || { echo "$commit is on no remote branch; push it first, since the About screen points at it" >&2; exit 1; }

# The key: from the environment, the login keychain or 1Password, in that
# order, and in whatever shape it was kept (scripts/asc-pem.sh). Over ssh the
# keychain answers nothing and exits 0, so an empty answer is what sends the
# read on to the item `Topo App Store Connect` in the Homelab vault, asked
# only with a service account in the environment, since `op` on one never
# stops on a prompt. Nothing here writes
# it anywhere but a folder of its own, which is where altool looks and which
# is taken away on the way out. With it xcodebuild registers a new target's
# App ID and makes its profile with no Apple ID signed in to Xcode; without it
# the archive is whatever Xcode's own accounts allow, and there is no upload.
asc_part() { # asc_part <the environment's value> <keychain service> <1Password field>
  local got="$1"
  [ -n "$got" ] || got="$(security find-generic-password -s "$2" -w 2>/dev/null || true)"
  if [ -z "$got" ] && [ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]; then
    got="$(op read "op://Homelab/Topo App Store Connect/$3" 2>/dev/null || true)"
  fi
  printf '%s' "$got"
}
key_id="$(asc_part "${ASC_KEY_ID:-}" topo-asc-key-id key_id)"
issuer="$(asc_part "${ASC_ISSUER_ID:-}" topo-asc-issuer-id issuer_id)"
private_key="$(asc_part "${ASC_PRIVATE_KEY:-}" topo-asc-private-key private_key)"
# A key found in part is said, not taken for no key.
missing="$([ -n "$key_id" ] || printf ' key id')$([ -n "$issuer" ] || printf ' issuer id')$([ -n "$private_key" ] || printf ' private key')"
if [ -n "$key_id$issuer$private_key" ] && [ -n "$missing" ]; then
  echo "the App Store Connect API key is incomplete: the environment, the keychain and 1Password gave no$missing" >&2
  exit 1
fi

auth=()
if [ -n "$key_id" ] && [ -n "$issuer" ] && [ -n "$private_key" ]; then
  keys="$(mktemp -d)"
  trap 'rm -rf "$keys"' EXIT
  ( umask 077; printf '%s' "$private_key" | scripts/asc-pem.sh > "$keys/AuthKey_$key_id.p8" ) \
    || { echo "the App Store Connect API key is not a .p8 in any shape scripts/asc-pem.sh reads" >&2; exit 1; }
  export API_PRIVATE_KEYS_DIR="$keys"
  auth=(-authenticationKeyPath "$keys/AuthKey_$key_id.p8" -authenticationKeyID "$key_id" -authenticationKeyIssuerID "$issuer")
elif [ "$upload" = yes ] || [ "$validate" = yes ]; then
  cat >&2 <<'MISSING'
No App Store Connect API key.

Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY (the .p8's contents), or
put them in the login keychain as topo-asc-key-id, topo-asc-issuer-id and
topo-asc-private-key. Over ssh the keychain answers nothing: there, set
OP_SERVICE_ACCOUNT_TOKEN and the key is read from 1Password's item
"Topo App Store Connect" (Homelab). docs/testflight.md says how to make one.
MISSING
  exit 1
fi

# The packages resolve into build/packages, kept for the pins they were resolved from and made
# afresh for any other, never into the derived data Xcode shares between builds: Xcode 27.2
# carries the package traits of the last resolution into the next, so a state that last saw one
# version of a package refuses or misbuilds another (docs/testing.md). The pins are compared
# as JSON without the originHash field a resolution rewrites (a copy that is missing, empty or not
# JSON names no pins), and the copy goes before the tree, so a removal cut short is finished by
# the next run.
pins=Topo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
packages="$out/packages"
pins_now="$(jq -cS 'del(.originHash)' "$pins" 2>/dev/null)" && pins_kept="$(jq -cS 'del(.originHash)' "$packages/Package.resolved" 2>/dev/null)" \
  && [ -n "$pins_now" ] && [ "$pins_now" = "$pins_kept" ] \
  || { rm -f "$packages/Package.resolved"; rm -rf "$packages"; }
mkdir -p "$packages"
cp "$pins" "$packages/Package.resolved" 2>/dev/null || true

rm -rf "$archive"
xcodebuild archive \
  -project "$project" \
  -scheme "$scheme" \
  -clonedSourcePackagesDirPath "$packages" \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"} \
  CURRENT_PROJECT_VERSION="$build" \
  TOPO_SOURCE_COMMIT="$commit" \
  TOPO_CHANNEL=testflight

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$export_options" \
  -exportPath "$out/export" \
  -allowProvisioningUpdates ${auth[@]+"${auth[@]}"}

# The weights reach a TestFlight or App Store install as the asset pack and never in the app
# (docs/voice.md); the product is the proof, not the build setting.
scripts/check-built-assets.sh "$archive/Products/Applications/$scheme.app"

ipa="$(/usr/bin/find "$out/export" -maxdepth 1 -name '*.ipa' -print -quit)"
[ -n "$ipa" ] || { echo "no .ipa in $out/export" >&2; exit 1; }
echo "==> $ipa"

if [ "$voice" = yes ]; then
  echo "==> packaging the voice's asset pack"
  scripts/phonon-bundles.sh package "$out/phonon"
fi

[ "$upload" = yes ] || [ "$validate" = yes ] || exit 0

if [ "$validate" = yes ]; then
  echo "==> validating"
  xcrun altool --validate-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
fi

if [ "$upload" = yes ] && [ "$voice" = yes ]; then
  echo "==> uploading the voice's asset pack"
  xcrun altool --upload-asset-pack "$out/phonon/phonon-40m-en.aar" --apple-id "$apple_id" --wait \
    --apiKey "$key_id" --apiIssuer "$issuer"
fi

if [ "$upload" = yes ]; then
  echo "==> uploading"
  xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
  echo "==> uploaded. It appears in TestFlight once App Store Connect has processed it."
fi
