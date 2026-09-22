#!/usr/bin/env bash
# Chooses the PR check's lane from the paths a change touches: `full` when any of them is on the
# voice path, `fast` otherwise. The full lane is the fast one plus the real ear: Parakeet's models
# and the UI test in which Parakeet hears the fixture through the microphone. The input-capable
# audio lane and the press tests over the stub and loading ears run in both.
#
#   VOICE_PATHS="$patterns" scripts/ci-select-lane.sh --git HEAD^1 HEAD
#   git diff --name-only HEAD^1 HEAD | VOICE_PATHS="$patterns" scripts/ci-select-lane.sh
#
# With `--git <base> <head>` it reads the changed paths itself, from `git diff --no-renames
# --name-only` (so a rename counts by both its old and its new path), and
# prints them to stderr; a diff that fails (a base the checkout does not hold, a shallow clone)
# is changed paths unknown, which selects full and says why. Without it, the paths come on stdin.
#
# VOICE_PATHS is the path list, one bash glob per line (`*` crosses `/`, so `Tests/ClientUI/*`
# is everything under it); blank lines and lines starting with `#` are ignored. The list lives in
# .github/workflows/pr-validate.yaml, on the step that calls this, and
# scripts/tests/ci-select-lane-test.sh reads it from there.
#
# Writes `lane=<full|fast>` and `reason=<one line>` to stdout, in $GITHUB_OUTPUT's form. It fails
# toward the full lane, never the fast one: no changed paths at all selects full, since an empty
# list is as likely a diff that could not be read as a change that touches nothing. An empty
# VOICE_PATHS is a broken workflow and exits 2.
set -euo pipefail

patterns=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] || [ "${line:0:1}" = "#" ] || patterns+=("$line")
done <<< "${VOICE_PATHS:-}"
[ "${#patterns[@]}" -gt 0 ] || { echo "::error::VOICE_PATHS is empty: there is no voice path to select a lane against." >&2; exit 2; }

if [ "${1:-}" = --git ]; then
  [ "$#" -eq 3 ] || { echo "usage: $0 [--git <base> <head>]" >&2; exit 2; }
  # --no-renames: a rename is its source and its destination, and either may be on the list.
  if ! changed="$(git diff --no-renames --name-only "$2" "$3" 2>&1)"; then
    echo "The changed paths could not be read: $changed" >&2
    echo "lane=full"
    echo "reason=the changed paths are unknown (git diff $2 $3 failed: $(head -n 1 <<<"$changed")), so the lane is full"
    exit 0
  fi
  echo "Changed paths:" >&2
  sed 's/^/  /' <<<"$changed" >&2
else
  changed="$(cat)"
fi

paths=()
while IFS= read -r path; do
  [ -z "$path" ] || paths+=("$path")
done <<< "$changed"

if [ "${#paths[@]}" -eq 0 ]; then
  echo "lane=full"
  echo "reason=no changed paths were read, so the lane falls back to full"
  exit 0
fi

for path in "${paths[@]}"; do
  for pattern in "${patterns[@]}"; do
    # shellcheck disable=SC2053 # the pattern is a glob on purpose
    if [[ "$path" == $pattern ]]; then
      echo "lane=full"
      echo "reason=$path is on the voice path ($pattern)"
      exit 0
    fi
  done
done

echo "lane=fast"
echo "reason=none of the ${#paths[@]} changed paths is on the voice path"
