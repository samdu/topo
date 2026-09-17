#!/usr/bin/env bash
# Fetches the voice's models (Pocket TTS) into a base directory, file by file from the pinned
# revision in Apps/Topo/Resources/models.json, and admits each only when its size and sha256
# match the manifest. A file already there and matching is kept, so a restored cache costs only
# the hashing. The directory is what `TOPO_DEBUG_VOICE` and the talk test's
# `TOPO_UITEST_VOICE_MODELS` take.
#
#   scripts/fetch-voice-models.sh <directory>
#
# The files land under `Models/pocket-tts/` beneath the directory, because FluidAudio's Pocket
# loader derives the pack's path from the base directory it is given and reads it from there and
# nowhere else. The app's own store puts them in the same place (`ModelStore.pocketHome`).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/Apps/Topo/Resources/models.json"
dest="${1:?usage: scripts/fetch-voice-models.sh <directory>}/Models/pocket-tts"
mkdir -p "$dest"

jq -r '.models[] | select(.id == "pocket-tts-coreml")
       | . as $m | .files[] | [$m.repo, $m.revision, .path, (.size|tostring), .sha256] | @tsv' "$manifest" |
while IFS=$'\t' read -r repo revision path size sha; do
  file="$dest/$path"
  if [ -f "$file" ] && [ "$(stat -f %z "$file")" = "$size" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
    continue
  fi
  mkdir -p "$(dirname "$file")"
  curl -fsSL --retry 3 -o "$file.part" "https://huggingface.co/$repo/resolve/$revision/$path"
  got_size="$(stat -f %z "$file.part")"
  got_sha="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
  if [ "$got_size" != "$size" ] || [ "$got_sha" != "$sha" ]; then
    echo "error: $path: $got_size bytes, sha256 $got_sha; the manifest says $size bytes, $sha" >&2
    rm -f "$file.part"
    exit 1
  fi
  mv "$file.part" "$file"
done
echo "voice models verified in $dest"
