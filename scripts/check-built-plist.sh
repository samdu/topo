#!/usr/bin/env bash
# The built app's Info.plist declares the background modes Topo needs, or iOS
# suspends the process: `remote-notification` for the silent push that wakes the
# primary, `audio` for a reply read aloud behind the lock. The setting they are
# declared by is not proof — `UIBackgroundModes` is not one of the keys Xcode
# generates from build settings, so a declaration in the wrong place reaches the
# project and no bundle. This reads the product.
#
# `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` are read the same way and for
# the same reason. They are what puts the memory's mirror folder in Files and lets an editor open
# it in place; neither is a key Xcode generates, and without them the app builds, runs and
# mirrors while the person can reach none of it.
#
# The version keys are read the same way and for the same reason: `CURRENT_PROJECT_VERSION` is
# passed on the command line for a TestFlight upload (docs/testflight.md), and a literal in the
# Info.plist would beat it silently, so every build would carry the same number.
#
# The usage strings of the permissions the phone's tools ask for are read the same way: iOS ends
# the process, uncatchably, when an app asks for Reminders, Calendars, Contacts, Location or
# HomeKit with no string saying why, and nothing shows it until the first call that asks.
#
# HomeKit needs the `com.apple.developer.homekit` entitlement besides, which is read off the
# signature of a signed product. An unsigned product (the PR check's device build) carries no
# entitlements to read, and the script says so rather than passing it as checked.
#
# `CFBundleURLTypes` is read the same way and for the same reason: the widgets open `topo://`,
# no setting generates the key, and without it a tap on a widget's link opens nothing. The
# widget extension is read off the product too: `PlugIns/TopoWidgets.appex`, the one the widgets
# are, embedded in the app.
#
# The GPL's text is read off the product too: the iSH fork linked into the app is GPL, and its
# holders' App Store waiver (LICENSE.IOS) stands only while the app carries the licence's text.
#
#   scripts/check-built-plist.sh <path to Topo.app> [expected CFBundleVersion]
set -euo pipefail

app="${1:?usage: check-built-plist.sh <Topo.app> [expected CFBundleVersion]}"
build="${2:-}"
plist="$app/Info.plist"

if [ ! -f "$plist" ]; then
    echo "no Info.plist in $app" >&2
    exit 1
fi

modes="$(plutil -extract UIBackgroundModes json -o - -- "$plist" 2>/dev/null || true)"
status=0
for mode in remote-notification audio; do
    case "$modes" in
        *"\"$mode\""*) ;;
        *)
            echo "$app/Info.plist does not declare the '$mode' background mode (UIBackgroundModes: ${modes:-absent})" >&2
            status=1
            ;;
    esac
done

for key in UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace; do
    value="$(plutil -extract "$key" raw -o - -- "$plist" 2>/dev/null || true)"
    if [ "$value" != "true" ] && [ "$value" != "1" ]; then
        echo "$app/Info.plist does not set $key ( ${value:-absent} ); the vault would not appear in Files" >&2
        status=1
    fi
done

for key in NSRemindersFullAccessUsageDescription NSCalendarsFullAccessUsageDescription \
           NSContactsUsageDescription NSLocationWhenInUseUsageDescription NSHomeKitUsageDescription; do
    value="$(plutil -extract "$key" raw -o - -- "$plist" 2>/dev/null || true)"
    if [ -z "${value//[[:space:]]/}" ]; then
        echo "$app/Info.plist has no $key; the first tool call that asks for it would end the app" >&2
        status=1
    fi
done

entitlements="entitlements not read: the product is unsigned"
if codesign -d "$app" >/dev/null 2>&1; then
    signed="$(mktemp)"
    codesign -d --entitlements - --xml "$app" > "$signed" 2>/dev/null || true
    # PlistBuddy, since plutil reads the dots of an entitlement's name as a key path.
    if [ "$(/usr/libexec/PlistBuddy -c "Print :com.apple.developer.homekit" "$signed" 2>/dev/null || true)" != "true" ]; then
        echo "$app is signed without the com.apple.developer.homekit entitlement; the first topo home call would fail" >&2
        status=1
    fi
    rm -f "$signed"
    entitlements="the HomeKit entitlement"
fi

schemes="$(plutil -extract CFBundleURLTypes json -o - -- "$plist" 2>/dev/null || true)"
case "$schemes" in
    *'"CFBundleURLSchemes":["topo"]'*) ;;
    *)
        echo "$app/Info.plist does not declare the topo URL scheme (CFBundleURLTypes: ${schemes:-absent}); a widget's link would open nothing" >&2
        status=1
        ;;
esac

if [ ! -f "$app/PlugIns/TopoWidgets.appex/Info.plist" ]; then
    echo "$app does not embed PlugIns/TopoWidgets.appex; there would be no widgets" >&2
    status=1
fi

if ! head -2 "$app/LICENSE" 2>/dev/null | grep -q "GNU GENERAL PUBLIC LICENSE" \
    || ! head -2 "$app/LICENSE" | grep -q "Version 3"; then
    echo "$app has no LICENSE carrying the GPL-3.0's text; the iSH fork's App Store waiver needs it" >&2
    status=1
fi

if [ -n "$build" ]; then
    got="$(plutil -extract CFBundleVersion raw -o - -- "$plist" 2>/dev/null || true)"
    if [ "$got" != "$build" ]; then
        echo "$app/Info.plist has CFBundleVersion '${got:-absent}', not the '$build' the build was given" >&2
        status=1
    fi
fi

[ "$status" -eq 0 ] && echo "$app declares UIBackgroundModes $modes, UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace, the tools' five usage strings, the topo URL scheme, $entitlements, embeds TopoWidgets.appex, carries the GPL's text${build:+, CFBundleVersion $build}"
exit "$status"
