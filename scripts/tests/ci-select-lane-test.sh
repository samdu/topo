#!/usr/bin/env bash
# Holds scripts/ci-select-lane.sh against the voice path as .github/workflows/pr-validate.yaml
# declares it (the `VOICE_PATHS` of the select job's `Choose the lane` step, read from the file
# rather than copied, so an entry dropped there is an entry this test no longer expects): a change
# outside the list selects the fast lane, a change to each entry on the list selects the full one,
# and every way the inputs can be missing selects full or fails, never fast.
#
#   scripts/tests/ci-select-lane-test.sh
#   WORKFLOW=/path/to/other/pr-validate.yaml scripts/tests/ci-select-lane-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../ci-select-lane.sh"
workflow="${WORKFLOW:-$here/../../.github/workflows/pr-validate.yaml}"
[ -f "$workflow" ] || { echo "no workflow at $workflow" >&2; exit 2; }

voice_paths="$(ruby -ryaml -e '
  w = YAML.load_file(ARGV[0])
  step = w.fetch("jobs").fetch("select").fetch("steps").find { |s| s["id"] == "lane" } or abort "no step with id lane in the select job"
  print step.fetch("env").fetch("VOICE_PATHS")
' "$workflow")" || exit 2

patterns=()
while IFS= read -r line; do
  [ -z "$line" ] || [ "${line:0:1}" = "#" ] || patterns+=("$line")
done <<< "$voice_paths"
[ "${#patterns[@]}" -gt 0 ] || { echo "the workflow's VOICE_PATHS is empty" >&2; exit 2; }

# The plan's minimum: a list that loses one of these is a voice path that lost its real ear.
required=(
  Apps/Client/VoiceInput.swift Apps/Client/Ear.swift Apps/Client/Vocabulary.swift
  Apps/Client/Composer.swift Apps/Client/ChatView.swift Apps/Client/ModelDownloads.swift
  Apps/Topo/Resources/models.json 'Tests/ClientUI/*' 'Tests/Fixtures/*'
  scripts/ci-audio-lane.sh project.yml .github/workflows/pr-validate.yaml
)

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

# select <expected lane> <case> <paths, one per line> — runs the script with the workflow's list.
select_lane() {
  local want="$1" name="$2" paths="$3" out status lane
  out="$(printf '%s' "$paths" | VOICE_PATHS="$voice_paths" "$script" 2>&1)" && status=0 || status=$?
  lane="$(sed -n 's/^lane=//p' <<<"$out")"
  if [ "$status" != 0 ] || [ "$lane" != "$want" ]; then
    fail "$name: wanted lane=$want, got exit $status: $out"
  elif ! grep -q '^reason=.' <<<"$out"; then
    fail "$name: no reason line: $out"
  else
    echo "ok   $name → $lane ($(sed -n 's/^reason=//p' <<<"$out"))"
  fi
}

for entry in "${required[@]}"; do
  printf '%s\n' "${patterns[@]}" | grep -qxF -- "$entry" || fail "the voice path has no entry $entry"
done

# A diff outside the list.
select_lane fast "outside the voice path" $'Apps/Client/SettingsView.swift\nPackages/TopoCore/Sources/TopoCore/Log.swift\ndocs/design.md\nCLAUDE.md\n'
select_lane fast "a neighbour of a listed file" $'Apps/Client/EarringView.swift\nTests/Client/EarTests.swift\n'

# Each entry, alone and beside paths outside the list. A glob is exercised with a file under it.
for pattern in "${patterns[@]}"; do
  example="${pattern//\*/Nested/Example.swift}"
  select_lane full "$pattern alone ($example)" "$example"$'\n'
  select_lane full "$pattern among others" $'docs/design.md\n'"$example"$'\nApps/Client/SettingsView.swift\n'
done

# Nothing read: the full lane, since an empty list is as likely a diff that failed.
select_lane full "no changed paths" ""

# No list: a broken workflow, which exits rather than choosing.
out="$(printf 'Apps/Client/Ear.swift\n' | VOICE_PATHS="" "$script" 2>&1)" && status=0 || status=$?
if [ "$status" = 2 ] && ! grep -q '^lane=' <<<"$out"; then
  echo "ok   an empty VOICE_PATHS exits 2 with no lane"
else
  fail "an empty VOICE_PATHS: exit $status: $out"
fi

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
