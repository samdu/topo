#!/usr/bin/env bash
# Writes Apps/Topo/Resources/models.json: the pinned list of every file the phone downloads for
# its on-device models and its guest's rootfs, with sizes and sha256 digests: the models from the
# Hugging Face tree API at the revision pinned below, the rootfs from the URL pinned below. The app downloads exactly this list through its background session and
# admits a file only when its digest matches, so a bump of a model is a bump of a revision here
# and a re-run of this script.
#
#   scripts/model-manifest.sh            # regenerate the manifest
#   scripts/model-manifest.sh --check    # regenerate to a temp file and diff against the committed one
#
# A `.mlmodelc` bundle is a directory of several files on the Hub, so a model's entry is the
# flattened file list; the tree API is asked recursively and paged through its `link` header,
# which the voice's repository needs — it holds every language and every variant, well past the
# thousand entries one page carries. Every file is fetched into build/models/ (gitignored,
# reused on the next run) and hashed locally, because the tree API reports a digest only for LFS
# objects and these repos are on Xet storage, which reports none.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$root/Apps/Topo/Resources/models.json"
cache="$root/build/models"
check=no
[ "${1:-}" = "--check" ] && check=yes

# id | repo | revision | file selectors (a path, or a directory prefix ending in /)
#
# The paths are repository-relative and the app lays them out under the entry's directory
# exactly as they are here, because that is what each library's loader reads.
#
# Parakeet: the four bundles FluidAudio's v2 loader asks for and the vocabulary beside them,
# under the directory name FluidAudio derives for the repository (its loader appends that to
# the parent of the directory it is given); the repo's other bundles are older conversions the
# loader never reads. The CTC spotter: its two bundles, the vocabulary CtcModels reads and the
# tokenizer CtcTokenizer reads.
#
# Pocket TTS: the English v2.1 pack, and of it only what the `.ane` placement at fp16 loads —
# `ModelNames.PocketTTS.requiredModels(precision:placement:)` names the four bundles, and
# `PocketTtsConstantsLoader` the three files under `constants_bin/`, with `eponine.safetensors`
# the one stock speaker the voice asks for. Every other language, both other placements, the
# `.mlpackage` sources CoreML never loads, the `constants/` intermediates and the other
# twenty-four speakers stay on the Hub. `bos_before_voice.bin` is there so the loader finds its
# cache complete: absent, it reaches for the network to backfill that one file.
models="
parakeet-tdt-0.6b-v2|FluidInference/parakeet-tdt-0.6b-v2-coreml|ee09c569f73759e6d44c9bd16766f477b2b36d39|Preprocessor.mlmodelc/ Encoder.mlmodelc/ Decoder.mlmodelc/ JointDecision.mlmodelc/ parakeet_vocab.json
parakeet-ctc-110m-coreml|FluidInference/parakeet-ctc-110m-coreml|accdafd8cf8a2ff1cabe3c11e54416b405d409aa|MelSpectrogram.mlmodelc/ AudioEncoder.mlmodelc/ vocab.json tokenizer.json
pocket-tts-coreml|FluidInference/pocket-tts-coreml|91748676fe3c8b2eb3007b3125253bcd898202c3|v2.1/english/cond_prefill_ane.mlmodelc/ v2.1/english/flowlm_step_ane.mlmodelc/ v2.1/english/flow_decoder_fused.mlmodelc/ v2.1/english/mimi_decoder.mlmodelc/ v2.1/english/constants_bin/bos_emb.bin v2.1/english/constants_bin/bos_before_voice.bin v2.1/english/constants_bin/text_embed_table.bin v2.1/english/constants_bin/tokenizer.model v2.1/english/constants_bin/eponine.safetensors
"

# id | base URL | files: entries that are not on the Hub, fetched from the base URL plus each file
# name and checked against the digest their publisher lists beside them (`<file>.sha256`) as well
# as hashed here. The guest's rootfs: Alpine's aarch64 minirootfs, taken straight from Alpine's
# CDN, so Topo distributes none of it; the fakefs is made from it on the phone
# (Packages/TopoUserland).
direct="
alpine-minirootfs|https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/aarch64/|alpine-minirootfs-3.22.6-aarch64.tar.gz
"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

entries=()
while IFS='|' read -r id repo revision selectors; do
  [ -z "$id" ] && continue
  echo "== $repo @ $revision" >&2
  tree="$tmp/tree.json"
  # One page is a thousand entries; the `link` header carries the cursor for the next.
  : > "$tmp/pages.json"
  next="https://huggingface.co/api/models/$repo/tree/$revision?recursive=true"
  while [ -n "$next" ]; do
    curl -sSf -D "$tmp/headers" "$next" >> "$tmp/pages.json"
    next="$(sed -n 's/^[Ll]ink: <\(.*\)>; rel="next".*/\1/p' "$tmp/headers" | tr -d '\r')"
  done
  jq -s 'add' "$tmp/pages.json" > "$tree"
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

while IFS='|' read -r id base names; do
  [ -z "$id" ] && continue
  echo "== $base" >&2
  entry_files=()
  for name in $names; do
    local_file="$cache/direct/$id/$name"
    if [ ! -f "$local_file" ]; then
      mkdir -p "$(dirname "$local_file")"
      echo "   fetching $name" >&2
      curl -sSfL "$base$name" -o "$local_file"
    fi
    digest="$(shasum -a 256 "$local_file" | cut -d' ' -f1)"
    published="$(curl -sSfL "$base$name.sha256" | cut -d' ' -f1)"
    [ "$digest" = "$published" ] || { echo "$name: sha256 $digest, but $base$name.sha256 says $published" >&2; exit 1; }
    size="$(stat -f %z "$local_file")"
    entry_files+=("$(jq -cn --arg p "$name" --argjson s "$size" --arg d "$digest" '{path:$p,size:$s,sha256:$d}')")
  done
  entries+=("$(printf '%s\n' "${entry_files[@]}" | jq -cs --arg id "$id" --arg u "$base" '{id:$id,url:$u,files:.}')")
done <<< "$direct"

manifest="$(printf '%s\n' "${entries[@]}" | jq -s '{models:.}')"
if [ "$check" = yes ]; then
  diff <(jq . "$out") <(echo "$manifest" | jq .) && echo "manifest is current" >&2
else
  echo "$manifest" | jq . > "$out"
  echo "wrote $out" >&2
fi
