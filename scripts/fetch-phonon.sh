#!/usr/bin/env bash
# Fetches PhononCore.xcframework, the compiled core of Gradium's ptts at the tag below, into
# Packages/PhononTTS/Frameworks/, which the PhononTTS package links. The zip is admitted only when
# its sha256 is the pin's (the checksum the tag's own Package.swift names), and a framework
# already there from the same zip is kept. Nothing it fetches is committed. SwiftPM's own binary
# download of the same URL stalls on the validation's Macs, which is why the package names a path
# and this script fetches it.
#
#   scripts/fetch-phonon.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tag=v0.6.0
sha=1c7e5a77d4f051f064eebe73b39ff1025ee41e1263503d14cabdd927d90514aa
url="${PHONON_CORE_URL:-https://github.com/gradium-ai/xn-ptts/releases/download/$tag/PhononCore.xcframework.zip}"
dest="$root/Packages/PhononTTS/Frameworks"
stamp="$dest/.fetched"

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$sha" ] && [ -d "$dest/PhononCore.xcframework" ]; then
  echo "fetch-phonon: PhononCore $tag is current"
  exit 0
fi

work="$(mktemp -d -t fetch-phonon)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 -o "$work/core.zip" "$url"
got="$(shasum -a 256 "$work/core.zip" | cut -d' ' -f1)"
if [ "$got" != "$sha" ]; then
  echo "fetch-phonon: $url has sha256 $got; the pin is $sha" >&2
  exit 1
fi
ditto -x -k "$work/core.zip" "$work/out"
[ -d "$work/out/PhononCore.xcframework" ] || { echo "fetch-phonon: the zip holds no PhononCore.xcframework" >&2; exit 1; }
rm -rf "$dest"
mkdir -p "$dest"
mv "$work/out/PhononCore.xcframework" "$dest/"
echo "$sha" > "$stamp"
echo "fetch-phonon: PhononCore $tag in $dest"
