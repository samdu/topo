#!/usr/bin/env bash
# scripts/check-built-plist.sh against hand-made products: one carrying everything passes, and one
# missing, or carrying an empty, usage string for each permission the phone's tools ask for fails,
# naming the key; so does one without the topo URL scheme or the widget extension. A product signed (ad hoc) without the HomeKit entitlement fails, one signed with
# it passes, and an unsigned one passes saying its entitlements were not read. macOS only
# (plutil, codesign).
#
#   scripts/tests/check-built-plist-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check="$here/check-built-plist.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

keys=(NSRemindersFullAccessUsageDescription NSCalendarsFullAccessUsageDescription
      NSContactsUsageDescription NSLocationWhenInUseUsageDescription NSHomeKitUsageDescription)

# A product with everything the check reads.
make_app() {
    local app="$1" usage
    mkdir -p "$app"
    plutil -create xml1 "$app/Info.plist"
    plutil -insert UIBackgroundModes -json '["remote-notification","audio"]' "$app/Info.plist"
    plutil -insert UIFileSharingEnabled -bool YES "$app/Info.plist"
    plutil -insert LSSupportsOpeningDocumentsInPlace -bool YES "$app/Info.plist"
    plutil -insert CFBundleVersion -string 7 "$app/Info.plist"
    for usage in "${keys[@]}"; do
        plutil -insert "$usage" -string "Topo uses this when you ask it to." "$app/Info.plist"
    done
    plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"zone.hexagon.topo","CFBundleURLSchemes":["topo"]}]' "$app/Info.plist"
    mkdir -p "$app/PlugIns/TopoWidgets.appex"
    plutil -create xml1 "$app/PlugIns/TopoWidgets.appex/Info.plist"
    printf '                    GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007\n' > "$app/LICENSE"
}

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

make_app "$work/whole/Topo.app"
"$check" "$work/whole/Topo.app" 7 >/dev/null 2>&1 || fail "a whole product was refused"

for key in "${keys[@]}"; do
    make_app "$work/no-$key/Topo.app"
    plutil -remove "$key" "$work/no-$key/Topo.app/Info.plist"
    if errors="$("$check" "$work/no-$key/Topo.app" 2>&1 >/dev/null)"; then
        fail "a product without $key passed"
    elif [[ "$errors" != *"$key"* ]]; then
        fail "the refusal of a product without $key does not name it: $errors"
    fi

    for blank in "" " " $'\t' $' \n\t'; do
        make_app "$work/blank-$key/Topo.app"
        plutil -replace "$key" -string "$blank" "$work/blank-$key/Topo.app/Info.plist"
        if "$check" "$work/blank-$key/Topo.app" >/dev/null 2>&1; then
            fail "a product with $key of only whitespace ($(printf %q "$blank")) passed"
        fi
        rm -rf "$work/blank-$key"
    done
done

make_app "$work/no-scheme/Topo.app"
plutil -remove CFBundleURLTypes "$work/no-scheme/Topo.app/Info.plist"
if errors="$("$check" "$work/no-scheme/Topo.app" 2>&1 >/dev/null)"; then
    fail "a product without the topo URL scheme passed"
elif [[ "$errors" != *"CFBundleURLTypes"* ]]; then
    fail "the refusal of a product without the topo URL scheme does not name it: $errors"
fi

make_app "$work/no-widgets/Topo.app"
rm -rf "$work/no-widgets/Topo.app/PlugIns"
if errors="$("$check" "$work/no-widgets/Topo.app" 2>&1 >/dev/null)"; then
    fail "a product without TopoWidgets.appex passed"
elif [[ "$errors" != *"TopoWidgets.appex"* ]]; then
    fail "the refusal of a product without TopoWidgets.appex does not name it: $errors"
fi

# Signed ad hoc, with and without the entitlement: codesign wants an executable to sign.
sign() {
    local app="$1" homekit="$2"
    cp /usr/bin/true "$app/Topo"
    plutil -insert CFBundleExecutable -string Topo "$app/Info.plist"
    local entitlements="$work/entitlements-$homekit.plist"
    # PlistBuddy, since plutil reads the dots of an entitlement's name as a key path.
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.icloud-services array" \
        -c "Add :com.apple.developer.icloud-services:0 string CloudKit" "$entitlements" >/dev/null
    if [ "$homekit" = yes ]; then
        /usr/libexec/PlistBuddy -c "Add :com.apple.developer.homekit bool true" "$entitlements" >/dev/null
    fi
    codesign --force --sign - --entitlements "$entitlements" "$app" 2>/dev/null
}

make_app "$work/signed/Topo.app"
sign "$work/signed/Topo.app" yes
if ! out="$("$check" "$work/signed/Topo.app" 2>&1)"; then
    fail "a product signed with the HomeKit entitlement was refused: $out"
elif [[ "$out" != *"the HomeKit entitlement"* ]]; then
    fail "a signed product's pass does not say the entitlement was read: $out"
fi

make_app "$work/no-homekit/Topo.app"
sign "$work/no-homekit/Topo.app" no
if errors="$("$check" "$work/no-homekit/Topo.app" 2>&1 >/dev/null)"; then
    fail "a product signed without the HomeKit entitlement passed"
elif [[ "$errors" != *"com.apple.developer.homekit"* ]]; then
    fail "the refusal of a product signed without the HomeKit entitlement does not name it: $errors"
fi

out="$("$check" "$work/whole/Topo.app" 2>&1)"
[[ "$out" == *"entitlements not read: the product is unsigned"* ]] \
    || fail "an unsigned product's pass does not say its entitlements were not read: $out"

# The watch app: whole, it passes; without the widget extension, with one that is not WidgetKit's,
# or without the push's background mode, it fails.
make_watch() {
    local watch="$1"
    mkdir -p "$watch/PlugIns/TopoWatchWidgets.appex"
    plutil -create xml1 "$watch/Info.plist"
    plutil -insert WKBackgroundModes -json '["remote-notification"]' "$watch/Info.plist"
    plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"zone.hexagon.topo.watch","CFBundleURLSchemes":["topo"]}]' "$watch/Info.plist"
    plutil -create xml1 "$watch/PlugIns/TopoWatchWidgets.appex/Info.plist"
    plutil -insert NSExtension -json '{"NSExtensionPointIdentifier":"com.apple.widgetkit-extension"}' \
        "$watch/PlugIns/TopoWatchWidgets.appex/Info.plist"
}
make_watch "$work/watch-whole/TopoWatch.app"
"$check" --watch "$work/watch-whole/TopoWatch.app" >/dev/null 2>&1 || fail "a whole watch product was refused"
make_watch "$work/watch-no-appex/TopoWatch.app"
rm -rf "$work/watch-no-appex/TopoWatch.app/PlugIns"
if errors="$("$check" --watch "$work/watch-no-appex/TopoWatch.app" 2>&1 >/dev/null)"; then
    fail "a watch product without TopoWatchWidgets.appex passed"
elif [[ "$errors" != *TopoWatchWidgets.appex* ]]; then
    fail "the refusal of a watch product without its widgets does not name them: $errors"
fi
make_watch "$work/watch-not-widgets/TopoWatch.app"
plutil -replace NSExtension -json '{"NSExtensionPointIdentifier":"com.apple.intents-service"}' \
    "$work/watch-not-widgets/TopoWatch.app/PlugIns/TopoWatchWidgets.appex/Info.plist"
"$check" --watch "$work/watch-not-widgets/TopoWatch.app" >/dev/null 2>&1 && fail "a watch product whose extension is not WidgetKit's passed"
make_watch "$work/watch-no-mode/TopoWatch.app"
plutil -remove WKBackgroundModes "$work/watch-no-mode/TopoWatch.app/Info.plist"
if errors="$("$check" --watch "$work/watch-no-mode/TopoWatch.app" 2>&1 >/dev/null)"; then
    fail "a watch product without the remote-notification background mode passed"
elif [[ "$errors" != *remote-notification* ]]; then
    fail "the refusal of a watch product without its background mode does not name it: $errors"
fi

make_watch "$work/watch-no-scheme/TopoWatch.app"
plutil -remove CFBundleURLTypes "$work/watch-no-scheme/TopoWatch.app/Info.plist"
if errors="$("$check" --watch "$work/watch-no-scheme/TopoWatch.app" 2>&1 >/dev/null)"; then
    fail "a watch product without the topo URL scheme passed"
elif [[ "$errors" != *"URL scheme"* ]]; then
    fail "the refusal of a watch product without the topo URL scheme does not name it: $errors"
fi

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)" >&2
    exit 1
fi

echo "check-built-plist.sh: a whole product passes; each of the tools' usage strings missing, empty or only whitespace fails; a product without the topo URL scheme or without TopoWidgets.appex fails; a product signed without the HomeKit entitlement fails, and an unsigned one says its entitlements were not read; a watch product without TopoWatchWidgets.appex as a WidgetKit extension, the remote-notification background mode or the topo URL scheme, fails"
