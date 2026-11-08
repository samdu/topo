#!/usr/bin/env bash
# Fetches the voice's bundle — Phonon 40m English exported to Core ML with Friendly Octopus as its
# one voice (docs/voice.md) — from its private Hugging Face repository at the pinned revision into
# a directory (build/phonon by default), as `phonon-40m-en/`. `bundle.json` is admitted only at the
# pinned sha256, and every file it lists only at the size and sha256 it names, so the whole bundle
# is pinned by one digest. A file already there and matching is kept.
#
#   scripts/phonon-bundles.sh [directory]
#   scripts/phonon-bundles.sh package [directory]   # ... and the asset pack for App Store Connect
#
# The repository is Sam's and private (the weights are CC BY-NC 4.0 and the voice is his), read
# with his token: HF_TOKEN, or 1Password's `op` when it is not set. What this makes is what the
# install page's builds embed (scripts/embed-voice.sh), what the talk lane's simulator loads
# (TOPO_DEBUG_VOICE) and what `package` turns into the Apple-hosted pack with `xcrun ba-package`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo=samthehugenerd/phonon-topo
revision=6412faefe4882879bbe1528ab39996ac50f4250a
name=phonon-40m-en
manifest_sha=51a609c3c856affd94d866997457fe7fcf755171ea19ce16ace00a7fa375f5f0
token_ref='op://Homelab/opqt7nwkxvoau6hxuwpjx47rpe/user access token'
base="${PHONON_REPO_URL:-https://huggingface.co/$repo/resolve/$revision/$name}"

package=no
if [ "${1-}" = package ]; then package=yes; shift; fi
out="${1:-$root/build/phonon}"
dest="$out/$name"
mkdir -p "$dest"

token="${HF_TOKEN-}"
if [ -z "$token" ] && [ "${base#file:}" = "$base" ]; then
  token="$(op read "$token_ref")" || { echo "error: phonon-bundles: no HF_TOKEN, and op could not read $token_ref" >&2; exit 1; }
fi

matches() {  # matches <file> <size> <sha256>
  [ -f "$1" ] && [ "$(stat -f %z "$1")" = "$2" ] && [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$3" ]
}
fetch() {  # fetch <path> <size> <sha256>
  local file="$dest/$1"
  matches "$file" "$2" "$3" && return 0
  mkdir -p "$(dirname "$file")"
  local url="$base/$(jq -rn --arg p "$1" '$p | @uri' | sed 's/%2F/\//g')"
  curl -fsSL --retry 3 ${token:+-H "Authorization: Bearer $token"} -o "$file.part" "$url"
  if ! matches "$file.part" "$2" "$3"; then
    echo "error: phonon-bundles: $1 is $(stat -f %z "$file.part") bytes, sha256 $(shasum -a 256 "$file.part" | cut -d' ' -f1); the pin says $2 bytes, $3" >&2
    rm -f "$file.part"
    exit 1
  fi
  mv "$file.part" "$file"
}

fetch bundle.json "$(stat -f %z "$dest/bundle.json" 2>/dev/null || echo 2945)" "$manifest_sha"
jq -r '.files[] | [.path, (.size|tostring), .sha256] | @tsv' "$dest/bundle.json" |
while IFS=$'\t' read -r path size sha; do fetch "$path" "$size" "$sha"; done
echo "phonon-bundles: $name verified in $dest"

[ "$package" = yes ] || exit 0
# The pack: its id, the essential policy at first installation alone (an update's new version is
# fetched at the first launch after it, so an update never fetches weights the store already has),
# and the bundle's folder, whose path in the pack is the path the app reads each file at. Only
# the files bundle.json names and bundle.json itself go in, never a compile left beside them.
manifest="$out/$name-manifest.json"
jq -n --arg name "$name" --slurpfile b "$dest/bundle.json" '{
  assetPackID: $name,
  downloadPolicy: { essential: { installationEventTypes: ["firstInstallation"] } },
  fileSelectors: ([{ file: ($name + "/bundle.json") }] + [$b[0].files[] | { file: ($name + "/" + .path) }]),
  platforms: ["iOS"]
}' > "$manifest"
rm -f "$out/$name.aar"
(cd "$out" && xcrun ba-package package "$manifest" --output-path "$out/$name.aar" --quiet)
echo "phonon-bundles: $out/$name.aar"
