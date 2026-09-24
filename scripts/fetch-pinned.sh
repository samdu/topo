#!/usr/bin/env bash
# Fetches one entry of Apps/Topo/Resources/models.json that carries its own `url` — the guest's
# rootfs (`alpine-minirootfs`), bash and its packages (`alpine-bash`) or Claude Code
# (`claude-code`) — into a directory from the entry's `url`, and admits each file only when its
# size and sha256 match the manifest. A file already there and matching is kept, so a restored
# cache or a runner's home costs only the hashing. Prints the file's path for a single-file entry
# and the directory for an entry of several files, which is what the userland suite takes as
# TEST_RUNNER_TOPO_USERLAND_ROOTFS, TEST_RUNNER_TOPO_USERLAND_CLAUDE or
# TEST_RUNNER_TOPO_USERLAND_SHELL.
#
#   scripts/fetch-pinned.sh <id> <directory>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/Apps/Topo/Resources/models.json"
id="${1:?usage: scripts/fetch-pinned.sh <id> <directory>}"
dest="${2:?usage: scripts/fetch-pinned.sh <id> <directory>}"
mkdir -p "$dest"

entries="$(jq -r --arg id "$id" '.models[] | select(.id == $id and .url != null)
  | .url as $u | .files[] | [$u, .path, (.size|tostring), .sha256] | @tsv' "$manifest")"
[ -n "$entries" ] || { echo "error: no $id entry with a url in $manifest" >&2; exit 1; }

count=0
file=""
while IFS=$'\t' read -r base path size sha; do
  count=$((count + 1))
  file="$dest/$path"
  if [ -f "$file" ] && [ "$(stat -f %z "$file")" = "$size" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
    continue
  fi
  curl -fsSL --retry 3 -o "$file.part" "$base$path"
  got_size="$(stat -f %z "$file.part")"
  got_sha="$(shasum -a 256 "$file.part" | cut -d' ' -f1)"
  if [ "$got_size" != "$size" ] || [ "$got_sha" != "$sha" ]; then
    echo "error: $path: $got_size bytes, sha256 $got_sha; the manifest says $size bytes, $sha" >&2
    rm -f "$file.part"
    exit 1
  fi
  mv "$file.part" "$file"
done <<< "$entries"

if [ "$count" = 1 ]; then echo "$file"; else echo "$dest"; fi
