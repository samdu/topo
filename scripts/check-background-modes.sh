#!/usr/bin/env bash
# The built app's Info.plist declares the background modes Topo needs, or iOS
# suspends the process: `remote-notification` for the silent push that wakes the
# primary, `audio` for a reply read aloud behind the lock. The setting they are
# declared by is not proof — `UIBackgroundModes` is not one of the keys Xcode
# generates from build settings, so a declaration in the wrong place reaches the
# project and no bundle. This reads the product.
#
#   scripts/check-background-modes.sh <path to Topo.app>
set -euo pipefail

app="${1:?usage: check-background-modes.sh <Topo.app>}"
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

[ "$status" -eq 0 ] && echo "$app declares UIBackgroundModes $modes"
exit "$status"
