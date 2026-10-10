#!/usr/bin/env bash
# An App Store Connect API key (.p8) on stdin, in whatever shape it was kept, as a PEM on stdout.
#
#   security find-generic-password -s topo-asc-private-key -w | scripts/asc-pem.sh > AuthKey_ID.p8
#
# Three shapes come in: the .p8 as Apple gave it; hex, which is how `security -w` prints a secret
# that holds newlines; and one line with spaces where the newlines were, which is what a .p8
# pasted into a one-line password field becomes. xcodebuild and altool take only the first.
# Anything that is not one P-256 private key in one of those shapes, and nothing else, is refused
# with nothing written.
set -euo pipefail

pem="$(python3 -c '
import re, sys, textwrap

text = sys.stdin.read().strip()
if re.fullmatch(r"(?:[0-9a-fA-F]{2})+", text):
    try:
        text = bytes.fromhex(text).decode().strip()
    except UnicodeDecodeError:
        sys.exit("asc-pem: the key is hex that is not text")
whole = re.fullmatch(r"-----BEGIN PRIVATE KEY-----(.*)-----END PRIVATE KEY-----", text, re.S)
if not whole or "-----" in whole[1]:
    sys.exit("asc-pem: not a private key: it is not one BEGIN PRIVATE KEY line, a body and one END PRIVATE KEY line, with nothing before, between or after")
body = re.sub(r"\s", "", whole[1])
if not body or len(body) % 4 or not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", body):
    sys.exit("asc-pem: not a private key: what is between the lines is not base64")
print("-----BEGIN PRIVATE KEY-----", *textwrap.wrap(body, 64), "-----END PRIVATE KEY-----", sep="\n")
')"

# Base64 between the lines is not yet a key: openssl says whether it is one, and of the curve
# App Store Connect signs with, by its name, since secp256k1 is 256 bits too.
printf '%s\n' "$pem" | openssl pkey -noout -text 2>/dev/null | grep -q '^ASN1 OID: prime256v1$' \
    || { echo "asc-pem: not a private key: what is between the lines is not a P-256 key" >&2; exit 1; }
printf '%s\n' "$pem"
