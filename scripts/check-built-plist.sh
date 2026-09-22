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

[ "$status" -eq 0 ] && echo "$app declares UIBackgroundModes $modes, UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace, carries the GPL's text${build:+, CFBundleVersion $build}"
exit "$status"
