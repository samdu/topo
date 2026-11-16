#!/usr/bin/env bash
# The Topo target's build phase for the voice's and the ear's bundles. With YES it puts each into
# the product's resources under its name — the voice's as scripts/phonon-bundles.sh fetched it
# (build/phonon/phonon-40m-en, or PHONON_BUNDLE), the ear's as scripts/ear-bundle.sh fetched it
# (build/ear/parakeet-ultra, or EAR_BUNDLE) — each as exactly the files its bundle.json
# names and bundle.json itself, refusing one whose files are not all there at the sizes it names;
# with anything else it removes a copy an earlier build left there, so a build that does not ask
# for the bundles never carries one.
#
#   scripts/embed-bundles.sh <the product's resources folder> <YES|NO>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
resources="${1:?usage: scripts/embed-bundles.sh <resources folder> <YES|NO>}"
embed="${2:?usage: scripts/embed-bundles.sh <resources folder> <YES|NO>}"

embed_one() {  # embed_one <name> <source> <what fetches it>
  local name="$1" source="$2" fetcher="$3" dest="$resources/$1"
  if [ "$embed" != YES ]; then
    rm -rf "$dest"
    return 0
  fi
  [ -f "$source/bundle.json" ] || { echo "error: embed-bundles: no bundle at $source ($fetcher fetches it)" >&2; exit 1; }
  local missing
  missing="$(cd "$source" && jq -r '.files[] | [.path, (.size|tostring)] | @tsv' bundle.json |
    while IFS=$'\t' read -r path size; do
      [ -f "$path" ] && [ "$(stat -f %z "$path")" = "$size" ] || echo "$path"
    done)"
  [ -z "$missing" ] || { echo "error: embed-bundles: $source lacks or has the wrong size of: $missing" >&2; exit 1; }
  mkdir -p "$resources"
  rm -rf "$dest"
  # Only what bundle.json names goes in, never a compile or a partial download left beside it.
  (cd "$source" && { echo bundle.json; jq -r '.files[].path' bundle.json; }) |
    rsync -a --files-from=- "$source/" "$dest/"
  echo "embed-bundles: $name in $dest"
}

embed_one phonon-40m-en "${PHONON_BUNDLE:-$root/build/phonon/phonon-40m-en}" scripts/phonon-bundles.sh
embed_one parakeet-ultra "${EAR_BUNDLE:-$root/build/ear/parakeet-ultra}" scripts/ear-bundle.sh
