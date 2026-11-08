#!/usr/bin/env bash
# Holds scripts/phonon-bundles.sh to its pin, offline, against a file URL standing in for the
# repository: a bundle.json that is not the pinned one is refused, nothing of it kept and no file
# it lists fetched, and the refusal names the digests. No token is asked for of a file URL.
#
#   scripts/tests/phonon-bundles-test.sh
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d -t phonon-bundles-test)"
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

repo="$work/repo"
mkdir -p "$repo/voices"
printf 'voice' > "$repo/voices/Friendly Octopus.safetensors"
cat > "$repo/bundle.json" <<JSON
{"built": 1, "files": [{"path": "voices/Friendly Octopus.safetensors", "size": 5,
  "sha256": "$(shasum -a 256 "$repo/voices/Friendly Octopus.safetensors" | cut -d' ' -f1)"}]}
JSON

if HF_TOKEN= PHONON_REPO_URL="file://$repo" PATH="/usr/bin:/bin:/opt/homebrew/bin" \
     "$root/scripts/phonon-bundles.sh" "$work/out" >"$work/log" 2>&1; then
  fail "a bundle.json that is not the pin's was admitted"
else
  grep -q "the pin says" "$work/log" || fail "the refusal does not name the pin: $(cat "$work/log")"
  grep -q "op could not read" "$work/log" && fail "a file URL asked 1Password for a token"
fi
[ ! -e "$work/out/phonon-40m-en/bundle.json" ] || fail "the refused bundle.json was kept"
[ -z "$(find "$work/out" -name '*.part' 2>/dev/null)" ] || fail "a partial download was left behind"
[ ! -e "$work/out/phonon-40m-en/voices" ] || fail "a file the refused bundle.json lists was fetched"

[ "$failures" = 0 ] && echo "phonon-bundles.sh admits no bundle.json but its pin" || { echo "$failures failure(s)"; exit 1; }
