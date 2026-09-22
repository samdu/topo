#!/usr/bin/env bash
# Holds scripts/ci-select-lane.sh against the voice path as .github/workflows/pr-validate.yaml
# declares it (the `VOICE_PATHS` of the select job's `Choose the lane` step, read from the file
# rather than copied, so an entry dropped there is an entry this test no longer expects): a change
# outside the list selects the fast lane, a change to each entry on the list selects the full one,
# and every way the inputs can be missing selects full or fails, never fast. Then it runs the select
# step itself out of the workflow on a pull_request event in scratch repositories, a diff producer
# that fails among them.
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

# The select step itself, extracted from the workflow and run in scratch repositories. On a
# pull_request event a diff it can read chooses by the paths, both sides of a rename included, and a
# diff producer that fails — HEAD^1 missing, as in a checkout too shallow to hold the merge commit's
# parent — chooses full and says so, rather than killing the step and leaving the run with no lane.
# On a dispatch the inputs choose, and on the schedule the lane is full.
step_run="$(ruby -ryaml -e '
  w = YAML.load_file(ARGV[0])
  print w.fetch("jobs").fetch("select").fetch("steps").find { |s| s["id"] == "lane" }.fetch("run")
' "$workflow")" || exit 2
scratch="$(mktemp -d -t ci-select-lane-test)"
trap 'rm -rf "$scratch"' EXIT

# run_step <case> <repo> <expected lane> <expected reason pattern>
run_step() {
  local name="$1" repo="$2" want="$3" match="$4" out status lane reason
  : > "$scratch/output"
  out="$(cd "$repo" && EVENT="${STEP_EVENT:-pull_request}" DISPATCH_LANE="${STEP_LANE:-}" DISPATCH_FAIL="${STEP_FAIL:-}" VOICE_PATHS="$voice_paths" \
    RUNNER_TEMP="$scratch" GITHUB_OUTPUT="$scratch/output" GITHUB_STEP_SUMMARY="$scratch/summary" \
    bash -eo pipefail -c "$step_run" 2>&1)" && status=0 || status=$?
  lane="$(sed -n 's/^lane=//p' "$scratch/output")"
  reason="$(sed -n 's/^reason=//p' "$scratch/output")"
  if [ "$status" != 0 ] || [ "$lane" != "$want" ] || ! grep -q -- "$match" <<<"$reason"; then
    fail "step, $name: wanted lane=$want and a reason matching '$match', got exit $status, lane=$lane, reason=$reason: $out"
  else
    echo "ok   step, $name → $lane ($reason)"
  fi
}

# repo <dir> <path>... — a scratch repository whose last commit adds each path.
repo() {
  local dir="$1"; shift
  mkdir -p "$dir/scripts"
  cp "$script" "$dir/scripts/ci-select-lane.sh"
  # A branch of its own and no hooks: whatever hooks this machine installs are not the test's.
  git -C "$dir" init -q -b scratch
  git -C "$dir" config core.hooksPath /dev/null
  git -C "$dir" -c user.name=t -c user.email=t@t add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -qm base
  local path
  for path in "$@"; do mkdir -p "$dir/$(dirname "$path")"; echo x > "$dir/$path"; done
  if [ "$#" -gt 0 ]; then
    git -C "$dir" -c user.name=t -c user.email=t@t add -A
    git -C "$dir" -c user.name=t -c user.email=t@t commit -qm change
  fi
}

repo "$scratch/fast" docs/design.md
run_step "a diff outside the voice path" "$scratch/fast" fast "none of the 1 changed paths"
repo "$scratch/full" Apps/Client/Ear.swift
run_step "a diff on the voice path" "$scratch/full" full "Apps/Client/Ear.swift is on the voice path"
repo "$scratch/shallow"
run_step "a diff producer that fails (no HEAD^1)" "$scratch/shallow" full "changed paths are unknown"

# A rename off the voice path: `git diff` reports a rename by its destination alone unless told
# otherwise, and the source is the path on the list.
repo "$scratch/rename" Apps/Client/Ear.swift
mkdir -p "$scratch/rename/Apps/Client/Hearing"
git -C "$scratch/rename" mv Apps/Client/Ear.swift Apps/Client/Hearing/Ear.swift
git -C "$scratch/rename" -c user.name=t -c user.email=t@t commit -qm rename
run_step "a voice-path file renamed off the list" "$scratch/rename" full "Apps/Client/Ear.swift is on the voice path"

# The dispatch inputs. `fail=skip` means the fast lane's model-less setup with the real-ear test
# left selected, so it takes the fast lane whatever `lane` says, and says it overrode it.
STEP_EVENT=workflow_dispatch STEP_LANE=full STEP_FAIL=none run_step "dispatch lane=full" "$scratch/fast" full "asked for the full lane"
STEP_EVENT=workflow_dispatch STEP_LANE=fast-benchmark STEP_FAIL=none run_step "dispatch lane=fast-benchmark" "$scratch/fast" fast "benchmark run"
STEP_EVENT=workflow_dispatch STEP_LANE=full STEP_FAIL=skip run_step "dispatch lane=full fail=skip" "$scratch/fast" fast "fail=skip overrode lane=full"
STEP_EVENT=workflow_dispatch STEP_LANE=fast-benchmark STEP_FAIL=skip run_step "dispatch lane=fast-benchmark fail=skip" "$scratch/fast" fast "fail=skip"
STEP_EVENT=schedule run_step "the nightly" "$scratch/fast" full "nightly"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
