#!/usr/bin/env bash
# Fetches the ear's bundle — Parakeet Ultra as FluidInference's Core ML build (docs/voice.md) —
# from its Hugging Face repository at the revision scripts/ear-bundle.json pins, into a directory
# (build/ear by default), as `parakeet-ultra/`. Every file is admitted only at the size and
# sha256 the pin names, and the pin itself is written beside them as the bundle's `bundle.json`,
# which is what the app's store checks the copy against. A file already there and matching is kept.
#
#   scripts/ear-bundle.sh [directory]
#   scripts/ear-bundle.sh package [directory]   # ... and the asset pack for App Store Connect
#
# What this makes is what the install page's builds embed (scripts/embed-bundles.sh), what a debug
# launch's `TOPO_DEBUG_EAR` folder holds beside the spotter (scripts/fetch-ear-models.sh) and what
# `package` turns into the Apple-hosted pack with `xcrun ba-package`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# EAR_BUNDLE_PIN and EAR_REPO_URL stand a fixture's pin and repository in for the test.
pin="${EAR_BUNDLE_PIN:-$root/scripts/ear-bundle.json}"
name=parakeet-ultra
repo="$(jq -r .repo "$pin")"
revision="$(jq -r .revision "$pin")"
base="${EAR_REPO_URL:-https://huggingface.co/$repo/resolve/$revision}"

package=no
if [ "${1-}" = package ]; then package=yes; shift; fi
out="${1:-$root/build/ear}"
dest="$out/$name"
mkdir -p "$dest"

matches() {  # matches <file> <size> <sha256>
  [ -f "$1" ] && [ "$(stat -f %z "$1")" = "$2" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$3" ]
}
fetch() {  # fetch <path> <size> <sha256>
  local file="$dest/$1"
  matches "$file" "$2" "$3" && return 0
  mkdir -p "$(dirname "$file")"
  local url="$base/$(jq -rn --arg p "$1" '$p | @uri' | sed 's/%2F/\//g')"
  curl -fsSL --retry 3 -o "$file.part" "$url"
  if ! matches "$file.part" "$2" "$3"; then
    echo "error: ear-bundle: $1 is $(stat -f %z "$file.part") bytes, sha256 $(shasum -a 256 "$file.part" | cut -d' ' -f1); the pin says $2 bytes, $3" >&2
    rm -f "$file.part"
    exit 1
  fi
  mv "$file.part" "$file"
}

jq -r '.files[] | [.path, (.size|tostring), .sha256] | @tsv' "$pin" |
while IFS=$'\t' read -r path size sha; do fetch "$path" "$size" "$sha"; done
cp "$pin" "$dest/bundle.json"
echo "ear-bundle: $name verified in $dest"

[ "$package" = yes ] || exit 0
# The pack: its id, the essential policy at first installation alone (an update's new version is
# fetched by the app at the first launch after it, and the ear hears with what the phone already
# has meanwhile), and the bundle's folder, whose path in the pack is the path the app reads each
# file at. Only the files bundle.json names and bundle.json itself go in.
manifest="$out/$name-manifest.json"
jq -n --arg name "$name" --slurpfile b "$dest/bundle.json" '{
  assetPackID: $name,
  downloadPolicy: { essential: { installationEventTypes: ["firstInstallation"] } },
  fileSelectors: ([{ file: ($name + "/bundle.json") }] + [$b[0].files[] | { file: ($name + "/" + .path) }]),
  platforms: ["iOS"]
}' > "$manifest"
rm -f "$out/$name.aar"
(cd "$out" && xcrun ba-package package "$manifest" --output-path "$out/$name.aar" --quiet)
echo "ear-bundle: $out/$name.aar"
