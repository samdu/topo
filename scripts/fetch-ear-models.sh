#!/usr/bin/env bash
# Fetches the ear's models (Fluid Speech Mini, the recogniser every simulator here runs, since
# each is iOS 18 or later, and the CTC spotter), or the ones named of those, Parakeet v2 (the
# recogniser on iOS 17), Silero's voice detector and Smart Turn (the open microphone's judge of a
# finished turn), into a directory, file by file from the pinned revisions in
# Apps/Topo/Resources/models.json, and admits each only when its size and sha256 match the
# manifest. A file the manifest renames is fetched from its `from` and laid at its `path`. A file already there and
# matching is kept, so a restored cache costs only the hashing. The directory is what
# `TOPO_DEBUG_EAR` and the UI test's `TOPO_UITEST_EAR_MODELS` take, and, with the detector and
# Smart Turn named, the unit suite's `TOPO_UNIT_EAR_MODELS`, which `SileroLoadTests` and
# `SmartTurnRealTests` read. Those two are fetched only when named: the unit suite and the
# microphone's part can run at once, and two fetches of one file into one cache collide on its
# `.part`.
#
#   scripts/fetch-ear-models.sh <directory> [<id>...]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/Apps/Topo/Resources/models.json"
dest="${1:?usage: scripts/fetch-ear-models.sh <directory> [<id>...]}"
shift
mkdir -p "$dest"
ear='["fluid-speech-mini-coreml", "parakeet-ctc-110m-coreml"]'
if [ "$#" -gt 0 ]; then
  wanted="$(jq -cn '$ARGS.positional' --args "$@")"
  bad="$(jq -rn --argjson w "$wanted" --argjson e "$ear" '$w - $e - ["parakeet-tdt-0.6b-v2", "silero-vad-coreml", "smart-turn-v3"] | join(" ")')"
  [ -z "$bad" ] || { echo "error: not one of the ear's models: $bad" >&2; exit 1; }
else
  wanted="$ear"
fi

jq -r --argjson wanted "$wanted" '.models[] | select(.id as $id | $wanted | index($id))
       | . as $m | .files[] | [$m.id, $m.repo, $m.revision, .path, (.from // .path), (.size|tostring), .sha256] | @tsv' "$manifest" |
while IFS=$'\t' read -r id repo revision path from size sha; do
  file="$dest/$id/$path"
  if [ -f "$file" ] && [ "$(stat -f %z "$file")" = "$size" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
    continue
  fi
  mkdir -p "$(dirname "$file")"
  curl -fsSL --retry 3 -o "$file.part" "https://huggingface.co/$repo/resolve/$revision/$from"
  got_size="$(stat -f %z "$file.part")"
  got_sha="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
  if [ "$got_size" != "$size" ] || [ "$got_sha" != "$sha" ]; then
    echo "error: $id/$path: $got_size bytes, sha256 $got_sha; the manifest says $size bytes, $sha" >&2
    rm -f "$file.part"
    exit 1
  fi
  mv "$file.part" "$file"
done
echo "ear models ($(jq -rn --argjson w "$wanted" '$w | join(", ")')) verified in $dest"
