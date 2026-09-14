#!/usr/bin/env bash
# Writes Apps/Topo/Resources/models.json: the pinned list of every file the phone downloads for
# its on-device models, with sizes and sha256 digests, from the Hugging Face tree API at the
# revision pinned below. The app downloads exactly this list through its background session and
# admits a file only when its digest matches, so a bump of a model is a bump of a revision here
# and a re-run of this script.
#
#   scripts/model-manifest.sh            # regenerate the manifest
#   scripts/model-manifest.sh --check    # regenerate to a temp file and diff against the committed one
#
# A `.mlmodelc` bundle is a directory of several files on the Hub, so a model's entry is the
# flattened file list; the tree API is asked recursively. Every file is fetched into
# build/models/ (gitignored, reused on the next run) and hashed locally, because the tree API
# reports a digest only for LFS objects and these repos are on Xet storage, which reports none.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/Apps/Topo/Resources/models.json"
cache="$root/build/models"
check=no
[ "${1:-}" = "--check" ] && check=yes

# id | repo | revision | file selectors (a path, or a directory prefix ending in /)
#
# Parakeet: the four bundles FluidAudio's v2 loader asks for and the vocabulary beside them,
# under the directory name FluidAudio derives for the repository (its loader appends that to
# the parent of the directory it is given); the repo's other bundles are older conversions the
# loader never reads. The CTC spotter: its
# two bundles, the vocabulary CtcModels reads and the tokenizer CtcTokenizer reads. Pocket TTS:
# the config, the weights, the SentencePiece tokenizer its conditioner reads beside them, and
# the one stock speaker the voice uses (`embeddings/eponine.safetensors`); the other seven
# speakers and the tokenizer files the port never opens are left on the Hub.
models="
parakeet-tdt-0.6b-v2|FluidInference/parakeet-tdt-0.6b-v2-coreml|ee09c569f73759e6d44c9bd16766f477b2b36d39|Preprocessor.mlmodelc/ Encoder.mlmodelc/ Decoder.mlmodelc/ JointDecision.mlmodelc/ parakeet_vocab.json
parakeet-ctc-110m-coreml|FluidInference/parakeet-ctc-110m-coreml|accdafd8cf8a2ff1cabe3c11e54416b405d409aa|MelSpectrogram.mlmodelc/ AudioEncoder.mlmodelc/ vocab.json tokenizer.json
pocket-tts|mlx-community/pocket-tts|cbf71d5f6657bbc3f4bc02f85ee408261225bec7|config.json model.safetensors tokenizer.json embeddings/eponine.safetensors
"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

entries=()
while IFS='|' read -r id repo revision selectors; do
  [ -z "$id" ] && continue
  echo "== $repo @ $revision" >&2
  tree="$tmp/tree.json"
  curl -sSf "https://huggingface.co/api/models/$repo/tree/$revision?recursive=true" > "$tree"
  files=()
  for selector in $selectors; do
    if [[ "$selector" == */ ]]; then
      mapfile -t matched < <(jq -r --arg p "$selector" '.[] | select(.type=="file" and (.path|startswith($p))) | .path' "$tree")
    else
      mapfile -t matched < <(jq -r --arg p "$selector" '.[] | select(.type=="file" and .path==$p) | .path' "$tree")
    fi
    [ "${#matched[@]}" -gt 0 ] || { echo "nothing in $repo matches $selector" >&2; exit 1; }
    files+=("${matched[@]}")
  done
  entry_files=()
  total=0
  for path in "${files[@]}"; do
    size="$(jq -r --arg p "$path" '.[] | select(.path==$p) | .size' "$tree")"
    local_file="$cache/$repo/$revision/$path"
    if [ ! -f "$local_file" ] || [ "$(stat -f %z "$local_file")" != "$size" ]; then
      mkdir -p "$(dirname "$local_file")"
      echo "   fetching $path ($size bytes)" >&2
      curl -sSfL "https://huggingface.co/$repo/resolve/$revision/$path" -o "$local_file"
      [ "$(stat -f %z "$local_file")" = "$size" ] || { echo "$path: got $(stat -f %z "$local_file") bytes, tree says $size" >&2; exit 1; }
    fi
    digest="$(shasum -a 256 "$local_file" | cut -d' ' -f1)"
    entry_files+=("$(jq -cn --arg p "$path" --argjson s "$size" --arg d "$digest" '{path:$p,size:$s,sha256:$d}')")
    total=$((total + size))
  done
  echo "   $id: ${#files[@]} files, $total bytes ($((total / 1048576)) MiB)" >&2
  entries+=("$(printf '%s\n' "${entry_files[@]}" | jq -cs --arg id "$id" --arg r "$repo" --arg v "$revision" '{id:$id,repo:$r,revision:$v,files:.}')")
done <<< "$models"

manifest="$(printf '%s\n' "${entries[@]}" | jq -s '{models:.}')"
if [ "$check" = yes ]; then
  diff <(jq . "$out") <(echo "$manifest" | jq .) && echo "manifest is current" >&2
else
  echo "$manifest" | jq . > "$out"
  echo "wrote $out" >&2
fi
