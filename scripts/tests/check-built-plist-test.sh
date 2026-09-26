#!/usr/bin/env bash
# scripts/check-built-plist.sh against hand-made products: one carrying everything passes, and one
# missing, or carrying an empty, usage string for each permission the phone's tools ask for fails,
# naming the key. macOS only (plutil).
#
#   scripts/tests/check-built-plist-test.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
check="$here/check-built-plist.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

keys=(NSRemindersFullAccessUsageDescription NSCalendarsFullAccessUsageDescription
      NSContactsUsageDescription NSLocationWhenInUseUsageDescription)

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

    make_app "$work/empty-$key/Topo.app"
    plutil -replace "$key" -string " " "$work/empty-$key/Topo.app/Info.plist"
    if "$check" "$work/empty-$key/Topo.app" >/dev/null 2>&1; then
        fail "a product with an empty $key passed"
    fi
done

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)" >&2
    exit 1
fi
echo "check-built-plist.sh: a whole product passes; each of the tools' usage strings missing or empty fails"
