#!/usr/bin/env bash
# Builds TopoHub signed for development, in Release, and prints the path of the built app.
#
#   scripts/hub-dev-build.sh
#
# The project builds the hub unsigned in practice, with the committed entitlements: sandboxed,
# and with no iCloud on an unsigned product, so it runs against the in-memory database. This build
# is the hub that runs the mind on a Mac (topo-mac): signed by the team's Apple Development
# identity with automatic signing, reaching the CloudKit container's development environment,
# which is the one a development-signed phone uses. Release, because Debug pins the model to
# Haiku. It is built, never launched: with its switch on, a signed hub takes the primary lease in the real records.
#
# Its entitlements are made here, in build/hub, from Apps/TopoHub/TopoHub.entitlements (so the
# containers are the project's own): without the app sandbox, since the mind's `claude` process
# reads the person's files, with the Mac's push entitlement in development, which CloudKit's
# silent pushes need, and with the container environment named rather than left to the default.
#
# Provisioning is xcodebuild's own (-allowProvisioningUpdates), through the Apple ID signed in to
# Xcode; a Mac development profile with iCloud and push lists the Macs it runs on, so this Mac is
# registered with the team if it is not already (-allowProvisioningDeviceRegistration). The
# destination is this Mac and not generic/platform=macOS, because a generic destination names no
# device to register, and a team with no Mac registered gets no profile. It needs the login
# keychain, so run it from a GUI-session shell, not a bare ssh one.
#
# Derived data and packages are under build/hub; the packages are kept for the pins they were
# resolved from and made afresh for any other, as scripts/archive-upload.sh keeps them. The product
# is checked before its path is printed: signed by the team, the entitlements above, and a profile
# that lists this Mac, without which the app is killed at launch.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# xcodebuild writes its environment into the build description: secrets are kept out of it.
source "$root/scripts/secret-env.sh"

case "${1-}" in
  "") ;;
  -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

team=4A5NSJ6Y3G
out="$root/build/hub"
derived="$out/DerivedData"
app="$derived/Build/Products/Release/TopoHub.app"
entitlements="$out/TopoHub.entitlements"
mkdir -p "$out"

# Every scheme resolves the packages whose frameworks these make, the hub's included.
"$root/scripts/build-ish.sh"
"$root/scripts/fetch-phonon.sh"

plist() { /usr/libexec/PlistBuddy "$@"; }
cp Apps/TopoHub/TopoHub.entitlements "$entitlements"
plist -c 'Delete :com.apple.security.app-sandbox' "$entitlements" 2>/dev/null || true
plist -c 'Add :com.apple.developer.aps-environment string development' "$entitlements"
plist -c 'Add :com.apple.developer.icloud-container-environment string Development' "$entitlements"

# Package state per pin, as scripts/archive-upload.sh keeps it (docs/testing.md).
pins=Topo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
packages="$out/packages"
pins_now="$(jq -cS 'del(.originHash)' "$pins" 2>/dev/null)" && pins_kept="$(jq -cS 'del(.originHash)' "$packages/Package.resolved" 2>/dev/null)" \
  && [ -n "$pins_now" ] && [ "$pins_now" = "$pins_kept" ] \
  || { rm -f "$packages/Package.resolved"; rm -rf "$packages"; }
mkdir -p "$packages"
cp "$pins" "$packages/Package.resolved" 2>/dev/null || true

"${scrubbed[@]}" xcodebuild build \
  -project Topo.xcodeproj \
  -scheme TopoHub \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived" \
  -clonedSourcePackagesDirPath "$packages" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  CODE_SIGN_STYLE=Automatic \
  DEVELOPMENT_TEAM="$team" \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_ENTITLEMENTS="$entitlements"

# The product is the proof, not the settings.
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }
signed="$(codesign -dv "$app" 2>&1)"
grep -qx "TeamIdentifier=$team" <<<"$signed" || { echo "$app is not signed by team $team" >&2; exit 1; }
built="$out/built.entitlements"
codesign -d --entitlements - --xml "$app" 2>/dev/null > "$built"
entitled() { plist -c "Print :$1" "$built" 2>/dev/null; }  # keys hold dots, which plutil reads as a path
[ "$(entitled com.apple.developer.aps-environment)" = development ] || { echo "$app has no development push entitlement" >&2; exit 1; }
[ "$(entitled com.apple.developer.icloud-container-environment)" = Development ] || { echo "$app is not entitled to the development container environment" >&2; exit 1; }
[ -z "$(entitled com.apple.security.app-sandbox)" ] || { echo "$app is sandboxed" >&2; exit 1; }
entitled com.apple.developer.icloud-container-identifiers | grep -qx '    iCloud.zone.hexagon.topo' \
  || { echo "$app is not entitled to iCloud.zone.hexagon.topo" >&2; exit 1; }
profile="$out/embedded.plist"
security cms -D -i "$app/Contents/embedded.provisionprofile" > "$profile" 2>/dev/null \
  || { echo "$app has no provisioning profile that reads" >&2; exit 1; }
mac="$(system_profiler SPHardwareDataType | awk -F': ' '/Provisioning UDID/ {print $2}')"
[ -n "$mac" ] && plist -c "Print :ProvisionedDevices" "$profile" | grep -qx "    $mac" \
  || { echo "the profile in $app does not list this Mac ($mac): it would be killed at launch" >&2; exit 1; }

echo "$app"
