#!/usr/bin/env bash
# The Topo target's build phase for the voice's bundle. With YES it puts the bundle
# scripts/phonon-bundles.sh fetched (build/phonon/phonon-40m-en, or PHONON_BUNDLE) into the
# product's resources as `phonon-40m-en`, refusing one whose files are not all there at the sizes
# its bundle.json names; with anything else it removes a copy an earlier build left there, so a
# build that does not ask for the bundle never carries one.
#
#   scripts/embed-voice.sh <the product's resources folder> <YES|NO>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resources="${1:?usage: scripts/embed-voice.sh <resources folder> <YES|NO>}"
embed="${2:?usage: scripts/embed-voice.sh <resources folder> <YES|NO>}"
name=phonon-40m-en
source="${PHONON_BUNDLE:-$root/build/phonon/$name}"
dest="$resources/$name"

if [ "$embed" != YES ]; then
  rm -rf "$dest"
  exit 0
fi

[ -f "$source/bundle.json" ] || { echo "error: embed-voice: no bundle at $source (scripts/phonon-bundles.sh fetches it)" >&2; exit 1; }
missing="$(cd "$source" && jq -r '.files[] | [.path, (.size|tostring)] | @tsv' bundle.json |
  while IFS=$'\t' read -r path size; do
    [ -f "$path" ] && [ "$(stat -f %z "$path")" = "$size" ] || echo "$path"
  done)"
[ -z "$missing" ] || { echo "error: embed-voice: $source lacks or has the wrong size of: $missing" >&2; exit 1; }
mkdir -p "$resources"
rsync -a --delete --exclude '*.mlmodelc' "$source/" "$dest/"
echo "embed-voice: $name in $dest"
