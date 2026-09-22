#!/usr/bin/env bash
# Fetches the guest's rootfs — the alpine-minirootfs entry of Apps/Topo/Resources/models.json —
# into a directory and admits it only when its size and sha256 match the manifest. A file already
# there and matching is kept, so a restored cache costs only the hashing. Prints the tarball's
# path, which is what the userland suite takes as TEST_RUNNER_TOPO_USERLAND_ROOTFS.
#
#   scripts/fetch-rootfs.sh <directory>
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/Apps/Topo/Resources/models.json"
dest="${1:?usage: scripts/fetch-rootfs.sh <directory>}"
mkdir -p "$dest"

IFS=$'\t' read -r base path size sha < <(jq -r '.models[] | select(.id == "alpine-minirootfs")
  | .url as $u | .files[0] | [$u, .path, (.size|tostring), .sha256] | @tsv' "$manifest")
[ -n "${path:-}" ] || { echo "error: no alpine-minirootfs entry in $manifest" >&2; exit 1; }
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
