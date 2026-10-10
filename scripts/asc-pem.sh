#!/usr/bin/env bash
# An App Store Connect API key (.p8) on stdin, in whatever shape it was kept, as a PEM on stdout.
#
#   security find-generic-password -s topo-asc-private-key -w | scripts/asc-pem.sh > AuthKey_ID.p8
#
# Three shapes come in: the .p8 as Apple gave it; hex, which is how `security -w` prints a secret
# that holds newlines; and one line with spaces where the newlines were, which is what a .p8
# pasted into a one-line password field becomes. xcodebuild and altool take only the first.
# Anything that is not a key in one of those shapes is refused, with nothing written.
set -euo pipefail

python3 -c '
import re, sys, textwrap

text = sys.stdin.read().strip()
if re.fullmatch(r"(?:[0-9a-fA-F]{2})+", text):
    try:
        text = bytes.fromhex(text).decode()
    except UnicodeDecodeError:
        sys.exit("asc-pem: the key is hex that is not text")
if text.count("-----BEGIN PRIVATE KEY-----") != 1 or text.count("-----END PRIVATE KEY-----") != 1:
    sys.exit("asc-pem: not a private key: no BEGIN PRIVATE KEY and END PRIVATE KEY lines")
inside = text.split("-----BEGIN PRIVATE KEY-----")[1].split("-----END PRIVATE KEY-----")[0]
body = re.sub(r"\s", "", inside)
if not body or len(body) % 4 or not re.fullmatch(r"[A-Za-z0-9+/]+={0,2}", body):
    sys.exit("asc-pem: not a private key: what is between the lines is not base64")
print("-----BEGIN PRIVATE KEY-----", *textwrap.wrap(body, 64), "-----END PRIVATE KEY-----", sep="\n")
'
