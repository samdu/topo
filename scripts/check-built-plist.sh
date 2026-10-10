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
# the process, uncatchably, when an app asks for Reminders, Calendars, Contacts, Location,
# HomeKit or Photos with no string saying why, and nothing shows it until the first call that asks.
# `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` is read beside them: without it a limited
# photo library puts the system's sheet for choosing more up at a tool's call.
#
# `NSLocalNetworkUsageDescription` is one of them: a control's request to a device on the home
# network is what asks for local network access. `NSAllowsArbitraryLoads` under
# `NSAppTransportSecurity` is read the same way as the URL scheme below: no setting generates it,
# and without it a control's request to a plain `http` URL fails at every press.
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
# With `--watch`, it reads the watch app instead: `PlugIns/TopoWatchWidgets.appex` embedded, a
# WidgetKit extension, since the complications are nothing without it; and `WKBackgroundModes`
# declaring `remote-notification`, which no setting generates, for the `Surface` push that wakes
# the watch to fetch the slots; and the topo URL scheme, which a whole watch widget's tap opens.
#
#   scripts/check-built-plist.sh <path to Topo.app> [expected CFBundleVersion]
#   scripts/check-built-plist.sh --watch <path to TopoWatch.app>
set -euo pipefail

if [ "${1:-}" = --watch ]; then
    watch="${2:?usage: check-built-plist.sh --watch <TopoWatch.app>}"
    status=0
    extension="$watch/PlugIns/TopoWatchWidgets.appex/Info.plist"
    point="$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - -- "$extension" 2>/dev/null || true)"
    if [ "$point" != com.apple.widgetkit-extension ]; then
        echo "$watch does not embed PlugIns/TopoWatchWidgets.appex as a WidgetKit extension (${point:-no extension}); there would be no complications" >&2
        status=1
    fi
    modes="$(plutil -extract WKBackgroundModes json -o - -- "$watch/Info.plist" 2>/dev/null || true)"
    case "$modes" in
        *'"remote-notification"'*) ;;
        *)
            echo "$watch/Info.plist does not declare the 'remote-notification' background mode (WKBackgroundModes: ${modes:-absent})" >&2
            status=1
            ;;
    esac
    schemes="$(plutil -extract CFBundleURLTypes json -o - -- "$watch/Info.plist" 2>/dev/null || true)"
    case "$schemes" in
        *'"CFBundleURLSchemes":["topo"]'*) ;;
        *)
            echo "$watch/Info.plist does not declare the topo URL scheme (CFBundleURLTypes: ${schemes:-absent}); a watch widget's tap would open nothing" >&2
            status=1
            ;;
    esac
    [ "$status" -eq 0 ] && echo "$watch embeds TopoWatchWidgets.appex, declares WKBackgroundModes $modes and the topo URL scheme"
    exit "$status"
fi

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

key=PHPhotoLibraryPreventAutomaticLimitedAccessAlert
value="$(plutil -extract "$key" raw -o - -- "$plist" 2>/dev/null || true)"
if [ "$value" != "true" ] && [ "$value" != "1" ]; then
    echo "$app/Info.plist does not set $key ( ${value:-absent} ); a limited photo library would put the system's sheet up at a tool's call" >&2
    status=1
fi

for key in NSRemindersFullAccessUsageDescription NSCalendarsFullAccessUsageDescription \
           NSContactsUsageDescription NSLocationWhenInUseUsageDescription NSHomeKitUsageDescription \
           NSLocalNetworkUsageDescription NSPhotoLibraryUsageDescription NSPhotoLibraryAddUsageDescription; do
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

loads="$(plutil -extract NSAppTransportSecurity.NSAllowsArbitraryLoads raw -o - -- "$plist" 2>/dev/null || true)"
if [ "$loads" != "true" ] && [ "$loads" != "1" ]; then
    echo "$app/Info.plist does not set NSAppTransportSecurity's NSAllowsArbitraryLoads ( ${loads:-absent} ); a control's request to an http URL would fail" >&2
    status=1
fi

if [ ! -f "$app/PlugIns/TopoWidgets.appex/Info.plist" ]; then
    echo "$app does not embed PlugIns/TopoWidgets.appex; there would be no widgets" >&2
    status=1
fi

# The screen share's broadcast extension: one that takes sample buffers, with a program and a
# principal class, and, where the product is signed, the app group its stills are kept in.
broadcast="$app/PlugIns/TopoBroadcast.appex"
point="$(plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - -- "$broadcast/Info.plist" 2>/dev/null || true)"
if [ "$point" != "com.apple.broadcast-services-upload" ]; then
    echo "$app does not embed PlugIns/TopoBroadcast.appex as a broadcast upload extension (${point:-no extension}); the screen could not be shared with Topo" >&2
    status=1
else
    mode="$(plutil -extract NSExtension.RPBroadcastProcessMode raw -o - -- "$broadcast/Info.plist" 2>/dev/null || true)"
    if [ "$mode" != "RPBroadcastProcessModeSampleBuffer" ]; then
        echo "TopoBroadcast.appex's RPBroadcastProcessMode is '${mode:-absent}', not RPBroadcastProcessModeSampleBuffer; it would be handed no frames" >&2
        status=1
    fi
    program="$(plutil -extract CFBundleExecutable raw -o - -- "$broadcast/Info.plist" 2>/dev/null || true)"
    if [ -z "$program" ] || [ ! -x "$broadcast/$program" ]; then
        echo "TopoBroadcast.appex has no executable named by its CFBundleExecutable ('${program:-absent}'); a share would not start" >&2
        status=1
    fi
    principal="$(plutil -extract NSExtension.NSExtensionPrincipalClass raw -o - -- "$broadcast/Info.plist" 2>/dev/null || true)"
    if [ -z "$principal" ]; then
        echo "TopoBroadcast.appex names no NSExtensionPrincipalClass; a share would have no handler" >&2
        status=1
    fi
    if codesign -d "$broadcast" >/dev/null 2>&1; then
        granted="$(mktemp)"
        codesign -d --entitlements - --xml "$broadcast" > "$granted" 2>/dev/null || true
        if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" "$granted" 2>/dev/null \
            | grep -qx '[[:space:]]*group\.zone\.hexagon\.topo'; then
            echo "TopoBroadcast.appex is signed without the group.zone.hexagon.topo app group; it would refuse every share as signed out" >&2
            status=1
        fi
        rm -f "$granted"
    fi
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

[ "$status" -eq 0 ] && echo "$app declares UIBackgroundModes $modes, UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace, the tools' eight usage strings, the topo URL scheme, NSAllowsArbitraryLoads, $entitlements, embeds TopoWidgets.appex, carries the GPL's text${build:+, CFBundleVersion $build}"
exit "$status"
