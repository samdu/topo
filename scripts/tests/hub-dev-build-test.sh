#!/usr/bin/env bash
# scripts/hub-dev-build.sh against a fake xcodebuild, codesign, security and system_profiler, in a
# tree made here: it builds the TopoHub scheme in Release for this Mac with automatic signing for the team and
# provisioning updates, into derived data and packages under build/hub, with entitlements made from
# the committed file without the sandbox and with development push and container environment; no
# exported secret reaches xcodebuild; the app's path is printed when the product is signed by the
# team, entitled so and provisioned for this Mac, and each of those missing fails naming it; and
# nothing opens or launches the app.
#
#   scripts/tests/hub-dev-build-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

tree="$work/tree"
mkdir -p "$tree/scripts" "$tree/Apps/TopoHub" "$work/bin"
cp "$here/../hub-dev-build.sh" "$here/../secret-env.sh" "$tree/scripts/"
for fake in build-ish.sh fetch-phonon.sh; do
  printf '#!/bin/sh\necho %s >> "$CALLS"\n' "$fake" > "$tree/scripts/$fake"
  chmod +x "$tree/scripts/$fake"
done
cat > "$tree/Apps/TopoHub/TopoHub.entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.developer.icloud-container-identifiers</key>
	<array><string>iCloud.zone.hexagon.topo</string></array>
	<key>com.apple.developer.icloud-services</key>
	<array><string>CloudKit</string></array>
	<key>com.apple.security.app-sandbox</key>
	<true/>
</dict>
</plist>
PLIST
committed="$(cat "$tree/Apps/TopoHub/TopoHub.entitlements")"
pins="$tree/Topo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
mkdir -p "$(dirname "$pins")"
echo '{"originHash":"a","pins":[],"version":3}' > "$pins"

# xcodebuild: its arguments, a secret seen in its environment, and an app signed as SIGN says,
# entitled with the file it was pointed at less what DROP names.
cat > "$work/bin/xcodebuild" <<'FAKE'
#!/usr/bin/env bash
echo "xcodebuild $*" >> "$CALLS"
if [ -n "${MARKER-}" ] && env | grep -v '^MARKER=' | grep -qF "$MARKER"; then echo "secret in xcodebuild's environment" >> "$CALLS"; fi
derived="" entitlements="" previous=""
for argument in "$@"; do
  [ "$previous" = -derivedDataPath ] && derived="$argument"
  case "$argument" in CODE_SIGN_ENTITLEMENTS=*) entitlements="${argument#CODE_SIGN_ENTITLEMENTS=}" ;; esac
  previous="$argument"
done
app="$derived/Build/Products/Release/TopoHub.app"
rm -rf "$app"; mkdir -p "$app/Contents"
cp "$entitlements" "$app/entitlements"
[ -z "${DROP-}" ] || /usr/libexec/PlistBuddy -c "Delete :$DROP" "$app/entitlements" >/dev/null
[ -z "${SANDBOXED-}" ] || /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" "$app/entitlements" >/dev/null
[ -n "${UNPROVISIONED-}" ] || touch "$app/Contents/embedded.provisionprofile"
FAKE
cat > "$work/bin/codesign" <<'FAKE'
#!/usr/bin/env bash
app="${*: -1}"
case "$*" in
  *--entitlements*) cat "$app/entitlements" ;;
  *) echo "TeamIdentifier=${TEAM-4A5NSJ6Y3G}" >&2 ;;
esac
FAKE
cat > "$work/bin/security" <<'FAKE'
#!/usr/bin/env bash
[ -e "${*: -1}" ] || exit 1
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>ProvisionedDevices</key><array><string>%s</string></array></dict></plist>\n' "${LISTED-00006000-MAC}"
FAKE
cat > "$work/bin/system_profiler" <<'FAKE'
#!/bin/sh
echo "      Provisioning UDID: 00006000-MAC"
FAKE
for opener in open xcrun; do printf '#!/bin/sh\necho "%s $*" >> "$CALLS"\n' "$opener" > "$work/bin/$opener"; done
chmod +x "$work/bin/"*

run() { # run <case> [VAR=value...]: the script's stdout in $work/out, stderr in $work/err, calls in $work/calls
  local name="$1"; shift
  rm -f "$work/calls"; touch "$work/calls"
  env "$@" PATH="$work/bin:$PATH" CALLS="$work/calls" "$tree/scripts/hub-dev-build.sh" > "$work/out" 2> "$work/err"
}

app="$tree/build/hub/DerivedData/Build/Products/Release/TopoHub.app"

export MARKER=hunter2-in-the-environment
if run good GH_TOKEN="$MARKER"; then ok "a good product passes"; else fail "a good product failed: $(cat "$work/err")"; fi
is "the app's path is printed" "$(cat "$work/out")" "$app"
call="$(grep '^xcodebuild' "$work/calls")"
for want in "build " "-scheme TopoHub" "-configuration Release" "-destination platform=macOS,arch=arm64" "-derivedDataPath $tree/build/hub/DerivedData" \
            "-clonedSourcePackagesDirPath $tree/build/hub/packages" "-allowProvisioningUpdates" \
            "-allowProvisioningDeviceRegistration" "CODE_SIGN_STYLE=Automatic" "DEVELOPMENT_TEAM=4A5NSJ6Y3G" \
            "CODE_SIGN_ENTITLEMENTS=$tree/build/hub/TopoHub.entitlements"; do
  case "$call" in *"$want"*) ok "xcodebuild is given $want" ;; *) fail "xcodebuild was not given $want: $call" ;; esac
done
grep -q "secret in xcodebuild's environment" "$work/calls" && fail "a secret reached xcodebuild" || ok "no secret reaches xcodebuild"
grep -q '^build-ish.sh$' "$work/calls" && grep -q '^fetch-phonon.sh$' "$work/calls" && ok "the frameworks are made first" || fail "the frameworks were not made"
grep -qE '^(open|xcrun)' "$work/calls" && fail "something opened or launched the app: $(cat "$work/calls")" || ok "nothing opens or launches the app"
made="$tree/build/hub/TopoHub.entitlements"
is "the sandbox is off" "$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$made" 2>/dev/null)" ""
is "push is development" "$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.aps-environment" "$made" 2>/dev/null)" development
is "the container environment is development" "$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-environment" "$made" 2>/dev/null)" Development
is "the containers are the committed file's" "$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.icloud-container-identifiers:0" "$made" 2>/dev/null)" iCloud.zone.hexagon.topo
is "the committed entitlements are untouched" "$(cat "$tree/Apps/TopoHub/TopoHub.entitlements")" "$committed"
[ -e "$tree/build/hub/packages/Package.resolved" ] && ok "the pins are kept beside the packages" || fail "no pins beside the packages"

refused() { # refused <case> <what stderr says> VAR=value...
  local name="$1" says="$2"; shift 2
  if run "$name" "$@"; then fail "$name passed"; else
    grep -q "$says" "$work/err" && ok "$name fails" || fail "$name failed without saying '$says': $(cat "$work/err")"
    [ -z "$(cat "$work/out")" ] && ok "$name prints no path" || fail "$name printed $(cat "$work/out")"
  fi
}
refused "another team" "not signed by team" TEAM=XXXXXXXXXX
refused "no push" "no development push" DROP=com.apple.developer.aps-environment
refused "the development environment unnamed" "development container environment" DROP=com.apple.developer.icloud-container-environment
refused "a sandboxed product" "is sandboxed" SANDBOXED=1
refused "no container" "not entitled to iCloud.zone.hexagon.topo" DROP=com.apple.developer.icloud-container-identifiers
refused "no profile" "no provisioning profile" UNPROVISIONED=1
refused "a profile without this Mac" "does not list this Mac" LISTED=00006000-OTHER

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
