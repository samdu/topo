#!/usr/bin/env bash
# Holds scripts/phonon-bundles.sh to its pin, offline, against a file URL standing in for the
# repository: a bundle.json that is not the pinned one is refused, nothing of it kept and no file
# it lists fetched, and the refusal names the digests. No token is asked for of a file URL. Past
# an admitted bundle.json, every file it lists is fetched, and one not at the size or the sha256
# it names is refused and not kept.
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

# A bundle.json the pin admits: the script itself, copied with its pin moved to this fixture's,
# so every file it lists is fetched and held to the size and sha256 it names.
admitted="$work/admitted"
mkdir -p "$admitted/repo/voices" "$admitted/scripts"
printf 'the octopus' > "$admitted/repo/voices/Friendly Octopus.safetensors"
printf 'host weights' > "$admitted/repo/host.safetensors"
digest() { shasum -a 256 "$1" | cut -d' ' -f1; }
manifest() {  # manifest <voice size> <voice sha256>
  cat > "$admitted/repo/bundle.json" <<JSON
{"built": 1, "files": [
  {"path": "voices/Friendly Octopus.safetensors", "size": $1, "sha256": "$2"},
  {"path": "host.safetensors", "size": 12, "sha256": "$(digest "$admitted/repo/host.safetensors")"}]}
JSON
  sed -e "s/^manifest_sha=.*/manifest_sha=$(digest "$admitted/repo/bundle.json")/" \
      -e "s/^manifest_size=.*/manifest_size=$(stat -f %z "$admitted/repo/bundle.json")/" \
      "$root/scripts/phonon-bundles.sh" > "$admitted/scripts/phonon-bundles.sh"
  chmod +x "$admitted/scripts/phonon-bundles.sh"
}
fetches() {  # fetches <out>: runs the pinned copy against the fixture
  HF_TOKEN= PHONON_REPO_URL="file://$admitted/repo" PATH="/usr/bin:/bin:/opt/homebrew/bin" \
    "$admitted/scripts/phonon-bundles.sh" "$1" >"$work/log" 2>&1
}
voice_sha="$(digest "$admitted/repo/voices/Friendly Octopus.safetensors")"

manifest 11 "$voice_sha"
if fetches "$work/whole"; then
  [ "$(cat "$work/whole/phonon-40m-en/voices/Friendly Octopus.safetensors" 2>/dev/null)" = "the octopus" ] \
    || fail "an admitted bundle.json's voice was not fetched: $(cat "$work/log")"
  [ "$(cat "$work/whole/phonon-40m-en/host.safetensors" 2>/dev/null)" = "host weights" ] \
    || fail "an admitted bundle.json's host weights were not fetched: $(cat "$work/log")"
else
  fail "a whole bundle at its pin was refused: $(cat "$work/log")"
fi

# A payload not at the size its bundle.json names, and one at the size but not the digest.
manifest 12 "$voice_sha"
if fetches "$work/size"; then fail "a payload of the wrong size was admitted"
else grep -q "voices/Friendly Octopus.safetensors is 11 bytes" "$work/log" || fail "the size refusal does not name the file: $(cat "$work/log")"; fi
[ ! -e "$work/size/phonon-40m-en/voices/Friendly Octopus.safetensors" ] || fail "a payload of the wrong size was kept"

manifest 11 "$(printf '%064d' 0)"
if fetches "$work/digest"; then fail "a payload with the wrong digest was admitted"
else grep -q "the pin says 11 bytes, $(printf '%064d' 0)" "$work/log" || fail "the digest refusal does not name the pin: $(cat "$work/log")"; fi
[ ! -e "$work/digest/phonon-40m-en/voices/Friendly Octopus.safetensors" ] || fail "a payload with the wrong digest was kept"
[ -z "$(find "$work/size" "$work/digest" -name '*.part' 2>/dev/null)" ] || fail "a refused payload's partial download was left behind"

[ "$failures" = 0 ] && echo "phonon-bundles.sh admits no bundle.json but its pin, and no file it lists but at its size and digest" || { echo "$failures failure(s)"; exit 1; }
