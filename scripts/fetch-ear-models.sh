#!/usr/bin/env bash
# Fetches the ear's models (Parakeet and the CTC spotter) into a directory, file by file from
# the pinned revisions in Apps/Topo/Resources/models.json, and admits each only when its size
# and sha256 match the manifest. A file already there and matching is kept, so a restored cache
# costs only the hashing. The directory is what `TOPO_DEBUG_EAR` and the UI test's
# `TOPO_UITEST_EAR_MODELS` take.
#
#   scripts/fetch-ear-models.sh <directory>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/Apps/Topo/Resources/models.json"
dest="${1:?usage: scripts/fetch-ear-models.sh <directory>}"
mkdir -p "$dest"

jq -r '.models[] | select(.id == "parakeet-tdt-0.6b-v2" or .id == "parakeet-ctc-110m-coreml")
       | . as $m | .files[] | [$m.id, $m.repo, $m.revision, .path, (.size|tostring), .sha256] | @tsv' "$manifest" |
while IFS=$'\t' read -r id repo revision path size sha; do
  file="$dest/$id/$path"
  if [ -f "$file" ] && [ "$(stat -f %z "$file")" = "$size" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
    continue
  fi
  mkdir -p "$(dirname "$file")"
  curl -fsSL --retry 3 -o "$file.part" "https://huggingface.co/$repo/resolve/$revision/$path"
  got_size="$(stat -f %z "$file.part")"
  got_sha="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
  if [ "$got_size" != "$size" ] || [ "$got_sha" != "$sha" ]; then
    echo "error: $id/$path: $got_size bytes, sha256 $got_sha; the manifest says $size bytes, $sha" >&2
    rm -f "$file.part"
    exit 1
  fi
  mv "$file.part" "$file"
done
echo "ear models verified in $dest"
