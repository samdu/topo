#!/usr/bin/env bash
# scripts/asc-pem.sh against a key made here: the .p8 as it is, the hex `security -w` prints for
# it, and the one line a password field makes of it each come out as the same PEM, which openssl
# reads as the same key; and what is not a key is refused with nothing on stdout.
#
#   scripts/tests/asc-pem-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pem="$here/../asc-pem.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/key.p8" 2>/dev/null \
    || { echo "FAIL: could not make a key to test with" >&2; exit 1; }
want="$(openssl pkey -in "$work/key.p8" -pubout 2>/dev/null)"

cp "$work/key.p8" "$work/as-given"
xxd -p "$work/key.p8" | tr -d '\n' > "$work/hex"
tr '\n' ' ' < "$work/key.p8" > "$work/one-line"
printf '\n\n' | cat - "$work/key.p8" > "$work/padded"
sed 's/$/\r/' "$work/key.p8" > "$work/crlf"

for shape in as-given hex one-line padded crlf; do
    if ! "$pem" < "$work/$shape" > "$work/$shape.out" 2> "$work/$shape.err"; then
        fail "the key $shape was refused: $(cat "$work/$shape.err")"
        continue
    fi
    cmp -s "$work/$shape.out" "$work/key.p8" || fail "the key $shape did not come out as the .p8 it was"
    [ "$(openssl pkey -in "$work/$shape.out" -pubout 2>/dev/null)" = "$want" ] || fail "the key $shape came out as another key, or none"
done

printf '' > "$work/empty"
printf 'THEKEYID' > "$work/an-id"
printf 'deadbeef' > "$work/other-hex"
printf -- '-----BEGIN PRIVATE KEY----- not base64! -----END PRIVATE KEY-----' > "$work/not-base64"
printf -- '-----BEGIN PRIVATE KEY-----\nAAAA\n' > "$work/no-end"
cat "$work/key.p8" "$work/key.p8" > "$work/two"
for shape in empty an-id other-hex not-base64 no-end two; do
    if out="$("$pem" < "$work/$shape" 2> "$work/$shape.err")"; then
        fail "$shape was taken as a key"
    elif [ -n "$out" ]; then
        fail "$shape was refused with something written to stdout"
    elif ! grep -q '^asc-pem: ' "$work/$shape.err"; then
        fail "the refusal of $shape does not say why: $(cat "$work/$shape.err")"
    fi
done

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed against $pem" >&2; exit 1; }
echo "asc-pem.sh: a .p8 as given, as the hex security prints, on one line, padded and with CRLF each comes out as the same PEM and the same key; an empty input, an id, other hex, a body that is not base64, a key with no END line and two keys are refused with nothing written"
