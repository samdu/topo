#!/usr/bin/env bash
# Archives Topo for the App Store and, when asked, sends it to TestFlight.
#
#   scripts/archive-upload.sh                 # archive and export, nothing leaves this Mac
#   scripts/archive-upload.sh --upload        # ... and upload to App Store Connect
#   scripts/archive-upload.sh --validate      # ... and ask App Store Connect whether it would take it
#   BUILD=42 scripts/archive-upload.sh        # a build number of your choosing
#
# The archive needs a Distribution certificate and an App Store provisioning
# profile for the team in Distribution/ExportOptions.plist; Xcode makes both
# on its own the first time somebody signed into the account archives here.
# The upload needs an App Store Connect API key, and docs/testflight.md says
# where to get one.
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
for argument in "$@"; do
  case "$argument" in
    --upload) upload=yes ;;
    --validate) validate=yes ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $argument" >&2; exit 2 ;;
  esac
done

# TestFlight only insists on one thing: the build number goes up. Seconds
# since 2026 is monotonic, short enough to read, and needs nothing kept
# between runs.
build="${BUILD:-$(( ($(date +%s) - 1767225600) / 60 ))}"
echo "==> build $build"

rm -rf "$archive"
xcodebuild archive \
  -project "$project" \
  -scheme "$scheme" \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION="$build"

xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportOptionsPlist "$export_options" \
  -exportPath "$out/export" \
  -allowProvisioningUpdates

ipa="$(/usr/bin/find "$out/export" -maxdepth 1 -name '*.ipa' -print -quit)"
[ -n "$ipa" ] || { echo "no .ipa in $out/export" >&2; exit 1; }
echo "==> $ipa"

[ "$upload" = yes ] || [ "$validate" = yes ] || exit 0

# The key: from the environment, or from the login keychain, in that order.
# Nothing here writes it anywhere; the .p8 is put where altool looks and
# taken away again on the way out.
key_id="${ASC_KEY_ID:-$(security find-generic-password -s topo-asc-key-id -w 2>/dev/null || true)}"
issuer="${ASC_ISSUER_ID:-$(security find-generic-password -s topo-asc-issuer-id -w 2>/dev/null || true)}"
private_key="${ASC_PRIVATE_KEY:-$(security find-generic-password -s topo-asc-private-key -w 2>/dev/null || true)}"

if [ -z "$key_id" ] || [ -z "$issuer" ] || [ -z "$private_key" ]; then
  cat >&2 <<'MISSING'
No App Store Connect API key.

Set ASC_KEY_ID, ASC_ISSUER_ID and ASC_PRIVATE_KEY (the .p8's contents), or
put them in the login keychain as topo-asc-key-id, topo-asc-issuer-id and
topo-asc-private-key. docs/testflight.md says how to make one.
MISSING
  exit 1
fi

keys="$(mktemp -d)"
trap 'rm -rf "$keys"' EXIT
printf '%s\n' "$private_key" > "$keys/AuthKey_$key_id.p8"
chmod 600 "$keys/AuthKey_$key_id.p8"
export API_PRIVATE_KEYS_DIR="$keys"

if [ "$validate" = yes ]; then
  echo "==> validating"
  xcrun altool --validate-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
fi

if [ "$upload" = yes ]; then
  echo "==> uploading"
  xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"
  echo "==> uploaded. It appears in TestFlight once App Store Connect has processed it."
fi
