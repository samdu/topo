#!/usr/bin/env bash
# Fetches one single-file entry of Apps/Topo/Resources/models.json — the guest's rootfs
# (`alpine-minirootfs`) or Claude Code (`claude-code`) — into a directory from the entry's own
# `url`, and admits it only when its size and sha256 match the manifest. A file already there and
# matching is kept, so a restored cache or a runner's home costs only the hashing. Prints the
# file's path, which is what the userland suite takes as TEST_RUNNER_TOPO_USERLAND_ROOTFS or
# TEST_RUNNER_TOPO_USERLAND_CLAUDE.
#
#   scripts/fetch-pinned.sh <id> <directory>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/Apps/Topo/Resources/models.json"
id="${1:?usage: scripts/fetch-pinned.sh <id> <directory>}"
dest="${2:?usage: scripts/fetch-pinned.sh <id> <directory>}"
mkdir -p "$dest"

IFS=$'\t' read -r base path size sha < <(jq -r --arg id "$id" '.models[] | select(.id == $id and .url != null)
  | select(.files | length == 1) | .url as $u | .files[0] | [$u, .path, (.size|tostring), .sha256] | @tsv' "$manifest") || true
[ -n "${path:-}" ] || { echo "error: no single-file $id entry with a url in $manifest" >&2; exit 1; }
file="$dest/$path"
if [ -f "$file" ] && [ "$(stat -f %z "$file")" = "$size" ] && [ "$(shasum -a 256 "$file" | cut -d' ' -f1)" = "$sha" ]; then
  echo "$file"
  exit 0
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
echo "$file"
