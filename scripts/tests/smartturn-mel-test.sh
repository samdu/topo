#!/usr/bin/env bash
# scripts/smartturn-mel.py against what is committed: the filterbank it writes from the vendored
# reference is the bundled `smartturn-mel.bin` byte for byte, and the reference features it writes
# for the test signal are `Tests/Fixtures/smartturn-mel-chirp.bin` byte for byte, so both binaries
# are ones anyone can make again. A filterbank that differs in one byte fails. Needs uv; numpy
# comes from uv's cache or its index.
#
#   scripts/tests/smartturn-mel-test.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

"$root/scripts/smartturn-mel.py" --out "$work/mel.bin" 2>/dev/null || fail "the filterbank was not written"
cmp -s "$work/mel.bin" "$root/Apps/Topo/Resources/smartturn-mel.bin" \
    || fail "the bundled filterbank is not what the vendored reference makes"
[ "$(stat -f %z "$work/mel.bin" 2>/dev/null)" = 64320 ] || fail "the filterbank is not [80][201] float32"

"$root/scripts/smartturn-mel.py" --fixture "$work/chirp.bin" 2>/dev/null || fail "the fixture was not written"
cmp -s "$work/chirp.bin" "$root/Tests/Fixtures/smartturn-mel-chirp.bin" \
    || fail "the mel fixture is not what the vendored reference makes of the test signal"

# The comparison can fail: a filterbank one byte off is not the bundled one.
cp "$root/Apps/Topo/Resources/smartturn-mel.bin" "$work/off.bin"
printf '\x01' | dd of="$work/off.bin" bs=1 seek=4 conv=notrunc 2>/dev/null
! cmp -s "$work/off.bin" "$work/mel.bin" || fail "a filterbank one byte off compared equal"

[ "$failures" = 0 ] || { echo "$failures failure(s)" >&2; exit 1; }
echo "smartturn-mel: the filterbank and the fixture regenerate bit for bit"
