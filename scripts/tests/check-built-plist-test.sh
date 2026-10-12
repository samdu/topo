#!/usr/bin/env bash
# scripts/check-built-plist.sh against hand-made products: one carrying everything passes, and one
# missing, or carrying an empty, usage string for each permission the phone's tools ask for fails,
# naming the key; so does one without the topo URL scheme, the key that keeps the limited photo library's sheet down, NSAllowsArbitraryLoads, the widget extension, the broadcast extension as one that takes sample buffers and has a program and a principal class, or the share extension with its program, its principal class and its rule of four things, one of each; nor one whose share extension is signed without the app group. A product signed (ad hoc) without the HomeKit entitlement fails, one signed with
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
      NSContactsUsageDescription NSLocationWhenInUseUsageDescription NSHomeKitUsageDescription
      NSLocalNetworkUsageDescription NSPhotoLibraryUsageDescription NSPhotoLibraryAddUsageDescription)

# A product with everything the check reads.
make_app() {
    local app="$1" usage
    mkdir -p "$app"
    plutil -create xml1 "$app/Info.plist"
    plutil -insert UIBackgroundModes -json '["remote-notification","audio"]' "$app/Info.plist"
    plutil -insert UIFileSharingEnabled -bool YES "$app/Info.plist"
    plutil -insert LSSupportsOpeningDocumentsInPlace -bool YES "$app/Info.plist"
    plutil -insert PHPhotoLibraryPreventAutomaticLimitedAccessAlert -bool YES "$app/Info.plist"
    plutil -insert CFBundleVersion -string 7 "$app/Info.plist"
    for usage in "${keys[@]}"; do
        plutil -insert "$usage" -string "Topo uses this when you ask it to." "$app/Info.plist"
    done
    plutil -insert NSAppTransportSecurity -json '{"NSAllowsArbitraryLoads":true}' "$app/Info.plist"
    plutil -insert CFBundleURLTypes -json '[{"CFBundleURLName":"zone.hexagon.topo","CFBundleURLSchemes":["topo"]}]' "$app/Info.plist"
    mkdir -p "$app/PlugIns/TopoWidgets.appex"
    plutil -create xml1 "$app/PlugIns/TopoWidgets.appex/Info.plist"
    mkdir -p "$app/PlugIns/TopoBroadcast.appex"
    plutil -create xml1 "$app/PlugIns/TopoBroadcast.appex/Info.plist"
    # A program with no signature: a copy of a system one carries Apple's.
    cp /usr/bin/true "$app/PlugIns/TopoBroadcast.appex/TopoBroadcast"
    codesign --remove-signature "$app/PlugIns/TopoBroadcast.appex/TopoBroadcast"
    plutil -insert CFBundleExecutable -string TopoBroadcast "$app/PlugIns/TopoBroadcast.appex/Info.plist"
    plutil -insert CFBundleIdentifier -string zone.hexagon.topo.broadcast "$app/PlugIns/TopoBroadcast.appex/Info.plist"
    plutil -insert NSExtension -json '{"NSExtensionPointIdentifier":"com.apple.broadcast-services-upload","NSExtensionPrincipalClass":"TopoBroadcast.SampleHandler","RPBroadcastProcessMode":"RPBroadcastProcessModeSampleBuffer"}' "$app/PlugIns/TopoBroadcast.appex/Info.plist"
    mkdir -p "$app/PlugIns/TopoShare.appex"
    plutil -create xml1 "$app/PlugIns/TopoShare.appex/Info.plist"
    # A program with no signature: a copy of a system one carries Apple's.
    cp /usr/bin/true "$app/PlugIns/TopoShare.appex/TopoShare"
    codesign --remove-signature "$app/PlugIns/TopoShare.appex/TopoShare"
    plutil -insert CFBundleExecutable -string TopoShare "$app/PlugIns/TopoShare.appex/Info.plist"
    plutil -insert CFBundleIdentifier -string zone.hexagon.topo.share "$app/PlugIns/TopoShare.appex/Info.plist"
    plutil -insert NSExtension -json '{"NSExtensionPointIdentifier":"com.apple.share-services","NSExtensionPrincipalClass":"TopoShare.ShareViewController","NSExtensionAttributes":{"NSExtensionActivationRule":{"NSExtensionActivationSupportsText":true,"NSExtensionActivationSupportsWebURLWithMaxCount":1,"NSExtensionActivationSupportsImageWithMaxCount":1,"NSExtensionActivationSupportsFileWithMaxCount":1}}}' "$app/PlugIns/TopoShare.appex/Info.plist"
    mkdir -p "$app/Metadata.appintents"
    printf '%s' '{"actions":{"AskTopoIntent":{"identifier":"AskTopoIntent","openAppWhenRun":true,"authenticationPolicy":1},"FollowUpIntent":{"identifier":"FollowUpIntent","openAppWhenRun":false,"authenticationPolicy":1},"QuickTaskIntent":{"identifier":"QuickTaskIntent","openAppWhenRun":false,"authenticationPolicy":1}},"autoShortcuts":[{"actionIdentifier":"AskTopoIntent"},{"actionIdentifier":"FollowUpIntent"},{"actionIdentifier":"QuickTaskIntent"}]}' \
        > "$app/Metadata.appintents/extract.actionsdata"
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

make_app "$work/no-alert/Topo.app"
plutil -remove PHPhotoLibraryPreventAutomaticLimitedAccessAlert "$work/no-alert/Topo.app/Info.plist"
if errors="$("$check" "$work/no-alert/Topo.app" 2>&1 >/dev/null)"; then
    fail "a product that lets the limited library's sheet come up passed"
elif [[ "$errors" != *"PHPhotoLibraryPreventAutomaticLimitedAccessAlert"* ]]; then
    fail "the refusal of a product that lets the limited library's sheet come up does not name the key: $errors"
fi

make_app "$work/no-scheme/Topo.app"
plutil -remove CFBundleURLTypes "$work/no-scheme/Topo.app/Info.plist"
if errors="$("$check" "$work/no-scheme/Topo.app" 2>&1 >/dev/null)"; then
    fail "a product without the topo URL scheme passed"
elif [[ "$errors" != *"CFBundleURLTypes"* ]]; then
    fail "the refusal of a product without the topo URL scheme does not name it: $errors"
fi

make_app "$work/no-loads/Topo.app"
plutil -remove NSAppTransportSecurity "$work/no-loads/Topo.app/Info.plist"
if errors="$("$check" "$work/no-loads/Topo.app" 2>&1 >/dev/null)"; then
    fail "a product without NSAllowsArbitraryLoads passed"
elif [[ "$errors" != *"NSAllowsArbitraryLoads"* ]]; then
    fail "the refusal of a product without NSAllowsArbitraryLoads does not name it: $errors"
fi

make_app "$work/no-widgets/Topo.app"
rm -rf "$work/no-widgets/Topo.app/PlugIns"
if errors="$("$check" "$work/no-widgets/Topo.app" 2>&1 >/dev/null)"; then
    fail "a product without TopoWidgets.appex passed"
elif [[ "$errors" != *"TopoWidgets.appex"* ]]; then
    fail "the refusal of a product without TopoWidgets.appex does not name it: $errors"
fi

# The broadcast extension: absent, of another kind, handed no sample buffers, or with no program
# or no class to handle a share.
bplist="PlugIns/TopoBroadcast.appex/Info.plist"
make_app "$work/no-broadcast/Topo.app"
rm -r "$work/no-broadcast/Topo.app/PlugIns/TopoBroadcast.appex"
make_app "$work/broadcast-kind/Topo.app"
plutil -replace NSExtension.NSExtensionPointIdentifier -string com.apple.broadcast-services-setupui "$work/broadcast-kind/Topo.app/$bplist"
make_app "$work/broadcast-mode/Topo.app"
plutil -replace NSExtension.RPBroadcastProcessMode -string RPBroadcastProcessModeMP4Clip "$work/broadcast-mode/Topo.app/$bplist"
make_app "$work/broadcast-no-program/Topo.app"
rm "$work/broadcast-no-program/Topo.app/PlugIns/TopoBroadcast.appex/TopoBroadcast"
make_app "$work/broadcast-no-principal/Topo.app"
plutil -remove NSExtension.NSExtensionPrincipalClass "$work/broadcast-no-principal/Topo.app/$bplist"
for case in no-broadcast broadcast-kind broadcast-mode broadcast-no-program broadcast-no-principal; do
    if errors="$("$check" "$work/$case/Topo.app" 2>&1 >/dev/null)"; then
        fail "a product whose broadcast extension is wrong ($case) passed"
    elif [[ "$errors" != *"TopoBroadcast.appex"* ]]; then
        fail "the refusal of $case does not name TopoBroadcast.appex: $errors"
    fi
done

make_app "$work/no-share/Topo.app"
rm -rf "$work/no-share/Topo.app/PlugIns/TopoShare.appex"
if errors="$("$check" "$work/no-share/Topo.app" 2>&1 >/dev/null)"; then
    fail "a product without TopoShare.appex passed"
elif [[ "$errors" != *"TopoShare.appex"* ]]; then
    fail "the refusal of a product without TopoShare.appex does not name it: $errors"
fi

# A share extension that takes everything, by a predicate or by a key the four do not name, or
# more than one of a thing.
rule="NSExtension.NSExtensionAttributes.NSExtensionActivationRule"
make_app "$work/share-predicate/Topo.app"
plutil -replace "$rule" -string TRUEPREDICATE "$work/share-predicate/Topo.app/PlugIns/TopoShare.appex/Info.plist"
make_app "$work/share-more/Topo.app"
plutil -insert "$rule.NSExtensionActivationSupportsMovieWithMaxCount" -integer 1 "$work/share-more/Topo.app/PlugIns/TopoShare.appex/Info.plist"
cases="share-predicate share-more share-no-text share-no-program share-no-principal"
# A plist with no program beside it, or no class to make the sheet from.
make_app "$work/share-no-program/Topo.app"
rm "$work/share-no-program/Topo.app/PlugIns/TopoShare.appex/TopoShare"
make_app "$work/share-no-principal/Topo.app"
plutil -remove NSExtension.NSExtensionPrincipalClass "$work/share-no-principal/Topo.app/PlugIns/TopoShare.appex/Info.plist"
make_app "$work/share-no-text/Topo.app"
plutil -replace "$rule.NSExtensionActivationSupportsText" -bool NO "$work/share-no-text/Topo.app/PlugIns/TopoShare.appex/Info.plist"
for thing in File Image WebURL; do
    for count in 0 2 10; do
        make_app "$work/share-$thing-$count/Topo.app"
        plutil -replace "$rule.NSExtensionActivationSupports${thing}WithMaxCount" -integer "$count" "$work/share-$thing-$count/Topo.app/PlugIns/TopoShare.appex/Info.plist"
        cases="$cases share-$thing-$count"
    done
done
for case in $cases; do
    if errors="$("$check" "$work/$case/Topo.app" 2>&1 >/dev/null)"; then
        fail "a product whose share extension's rule is wrong ($case) passed"
    elif [[ "$errors" != *"TopoShare.appex"* ]]; then
        fail "the refusal of $case does not name TopoShare.appex: $errors"
    fi
done

# The Shortcuts actions: metadata the build did not make, one that leaves an action out, one whose
# Ask does not open Topo or whose Follow up does, one that runs on a locked phone, and App
# Shortcuts that are short or name one action twice.
make_app "$work/no-intents/Topo.app"
rm -r "$work/no-intents/Topo.app/Metadata.appintents"
intents() {
    local name="$1" from="$2" to="$3"
    make_app "$work/$name/Topo.app"
    sed -i '' "s|$from|$to|" "$work/$name/Topo.app/Metadata.appintents/extract.actionsdata"
    cmp -s "$work/whole/Topo.app/Metadata.appintents/extract.actionsdata" "$work/$name/Topo.app/Metadata.appintents/extract.actionsdata" \
        && fail "the case $name changed nothing"
    cases="$cases $name"
}
cases="no-intents"
intents intent-short '"FollowUpIntent":{[^}]*},' ''
intents ask-stays '"identifier":"AskTopoIntent","openAppWhenRun":true' '"identifier":"AskTopoIntent","openAppWhenRun":false'
intents follow-up-opens '"identifier":"FollowUpIntent","openAppWhenRun":false' '"identifier":"FollowUpIntent","openAppWhenRun":true'
intents task-locked '"identifier":"QuickTaskIntent","openAppWhenRun":false,"authenticationPolicy":1' '"identifier":"QuickTaskIntent","openAppWhenRun":false,"authenticationPolicy":0'
intents shortcut-short ',{"actionIdentifier":"QuickTaskIntent"}' ''
intents shortcut-twice '{"actionIdentifier":"FollowUpIntent"}' '{"actionIdentifier":"AskTopoIntent"}'
for case in $cases; do
    if errors="$("$check" "$work/$case/Topo.app" 2>&1 >/dev/null)"; then
        fail "a product whose App Intents metadata is wrong ($case) passed"
    elif [[ "$errors" != *"App Intents metadata"* ]]; then
        fail "the refusal of $case does not name the App Intents metadata: $errors"
    fi
done

# Signed ad hoc, with and without the entitlement: codesign wants an executable to sign.
sign() {
    local app="$1" homekit="$2" group="${3:-yes}"
    # Inside out: the app's signature seals the extension's.
    local granted="$work/entitlements-share-$group.plist"
    rm -f "$granted"
    /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups array" "$granted" >/dev/null
    if [ "$group" = yes ]; then
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.application-groups:0 string group.zone.hexagon.topo" "$granted" >/dev/null
    fi
    codesign --force --sign - --entitlements "$granted" "$app/PlugIns/TopoShare.appex" 2>/dev/null
    codesign --force --sign - --entitlements "$granted" "$app/PlugIns/TopoBroadcast.appex" 2>/dev/null
    cp /usr/bin/true "$app/Topo"
    plutil -insert CFBundleExecutable -string Topo "$app/Info.plist"
    local entitlements="$work/entitlements-$homekit.plist"
    rm -f "$entitlements"
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

make_app "$work/no-group/Topo.app"
sign "$work/no-group/Topo.app" yes no
if errors="$("$check" "$work/no-group/Topo.app" 2>&1 >/dev/null)"; then
    fail "a product whose share extension is signed without the app group passed"
elif [[ "$errors" != *"group.zone.hexagon.topo"* ]]; then
    fail "the refusal of a share extension signed without the app group does not name it: $errors"
elif [[ "$errors" != *"TopoBroadcast.appex is signed without"* ]]; then
    fail "the refusal of a broadcast extension signed without the app group does not name it: $errors"
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

echo "check-built-plist.sh: a whole product passes; each of the tools' usage strings missing, empty or only whitespace fails; a product without the topo URL scheme, NSAllowsArbitraryLoads, TopoWidgets.appex, TopoBroadcast.appex or TopoShare.appex fails, as does a broadcast extension of another kind, handed no sample buffers, with no program or principal class, or signed without the app group, as does a share extension whose rule is a predicate, names a fifth thing, does not take text or takes none or more than one of a thing, has no program or no principal class, or is signed without the app group; a product whose App Intents metadata is missing, leaves out one of the three Shortcuts actions, has Ask not opening Topo or Follow up opening it, lets one run on a locked phone, or does not offer exactly one App Shortcut for each fails; a product signed without the HomeKit entitlement fails, and an unsigned one says its entitlements were not read; a watch product without TopoWatchWidgets.appex as a WidgetKit extension, the remote-notification background mode or the topo URL scheme, fails"
