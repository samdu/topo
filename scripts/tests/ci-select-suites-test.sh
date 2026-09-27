#!/usr/bin/env bash
# Holds scripts/ci-select-suites.sh against the rules as .github/workflows/pr-validate.yaml declares
# them (the `SUITE_RULES` of the select job's `Choose the suites` step), against a list of the rules
# this test writes out for itself: the two lists are equal line for line and in order, since the
# first match wins, so a rule deleted, added or moved in the workflow fails here rather than
# silently changing what runs. Then each rule is exercised with a path under it, and the cases
# that matter by name — a documentation change runs nothing, a hub, watch, TV, Womble or TopoLink
# change runs `others` alone, a change to the app, a package the app links, the tests, the
# project, a guest patch, the workflow or its scripts runs all three, a path no rule names runs all
# three — and every way the inputs can be missing runs all three or fails, never fewer. Then it
# runs the select step itself out of the workflow on a pull_request event in scratch repositories,
# a diff producer that fails among them, and on the other events.
#
#   scripts/tests/ci-select-suites-test.sh
#   WORKFLOW=/path/to/other/pr-validate.yaml scripts/tests/ci-select-suites-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../ci-select-suites.sh"
workflow="${WORKFLOW:-$here/../../.github/workflows/pr-validate.yaml}"
[ -f "$workflow" ] || { echo "no workflow at $workflow" >&2; exit 2; }

rules="$(ruby -ryaml -e '
  w = YAML.load_file(ARGV[0])
  step = w.fetch("jobs").fetch("select").fetch("steps").find { |s| s["id"] == "suites" } or abort "no step with id suites in the select job"
  print step.fetch("env").fetch("SUITE_RULES")
' "$workflow")" || exit 2

# The rules as this test expects them, in order, written out here rather than read from the
# workflow, so a rule changed there is a difference here and not a rule that silently stops being
# tested.
expected=(
  '.github/workflows/pr-validate.yaml all'
  '.github/actions/* all'
  '.github/* none'
  'Apps/TopoHub/* others'
  'Apps/TopoTV/* others'
  'Apps/TopoWatch/* others'
  'Apps/* all'
  'Packages/TopoLink/* others'
  'Packages/* all'
  'Tests/* all'
  'Womble/* others'
  'docs/* none'
  '*.md none'
  '.claude/* none'
  'Distribution/* none'
  'scripts/archive-upload.sh none'
  'scripts/plan-review.sh none'
)

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

declared=()
while IFS= read -r line; do
  line="$(tr -s ' \t' ' ' <<<"$line" | sed 's/^ //; s/ $//')"
  [ -z "$line" ] || [ "${line:0:1}" = "#" ] || declared+=("$line")
done <<< "$rules"
if [ "$(printf '%s\n' "${declared[@]}")" = "$(printf '%s\n' "${expected[@]}")" ]; then
  echo "ok   the workflow's SUITE_RULES are the ${#expected[@]} rules this test expects, in order"
else
  fail "the workflow's SUITE_RULES differ from this test's: $(diff <(printf '%s\n' "${expected[@]}") <(printf '%s\n' "${declared[@]}"))"
fi

# selects <topo_unit> <topo_ui> <others> <case> <paths, one per line> — runs the script with the
# workflow's rules. Each flag is `true` or `false`.
selects() {
  local unit="$1" ui="$2" others="$3" name="$4" paths="$5" out status got
  out="$(printf '%s' "$paths" | SUITE_RULES="$rules" "$script" 2>&1)" && status=0 || status=$?
  got="$(sed -n 's/^topo_unit=//p' <<<"$out") $(sed -n 's/^topo_ui=//p' <<<"$out") $(sed -n 's/^others=//p' <<<"$out")"
  if [ "$status" != 0 ] || [ "$got" != "$unit $ui $others" ]; then
    fail "$name: wanted topo_unit topo_ui others = $unit $ui $others, got exit $status: $out"
  elif ! grep -q '^reason=.' <<<"$out"; then
    fail "$name: no reason line: $out"
  else
    echo "ok   $name → $got ($(sed -n 's/^reason=//p' <<<"$out"))"
  fi
}

# Each rule with a path under it, alone: the suites it names.
for rule in "${expected[@]}"; do
  glob="${rule% *}"; want="${rule##* }"
  example="${glob//\*/Nested/Example.swift}"
  case "$want" in
    all) selects true true true "$glob alone ($example)" "$example"$'\n' ;;
    none) selects false false false "$glob alone ($example)" "$example"$'\n' ;;
    others) selects false false true "$glob alone ($example)" "$example"$'\n' ;;
    *) fail "no case for the rule '$rule'" ;;
  esac
done

# Nothing: documentation, the other workflows, tooling no suite covers.
selects false false false "documentation and root markdown" $'docs/design.md\nREADME.md\nCLAUDE.md\nDesign/README.md\n'
selects false false false "the automerge workflow" $'.github/workflows/automerge.yaml\n'
selects false false false "agent hooks and TestFlight tooling" $'.claude/hooks/pm-guard.py\nscripts/plan-review.sh\nscripts/archive-upload.sh\nDistribution/ExportOptions.plist\n'

# `others` alone: what only the hub, watch, TV, Womble and TopoLink compile.
selects false false true "TopoLink" $'Packages/TopoLink/Sources/TopoLink/Probe.swift\ndocs/pairing.md\n'
selects false false true "the hub, the watch and the TV" $'Apps/TopoHub/HubApp.swift\nApps/TopoWatch/WatchApp.swift\nApps/TopoTV/TVApp.swift\n'
selects false false true "Womble, its README and its web page included" $'Womble/Sources/App/AppDelegate.swift\nWomble/README.md\nWomble/Web/index.html\n'

# Everything: the app, what it links, the tests, the project, and the CI itself.
selects true true true "the app's client code" $'Apps/Client/SettingsView.swift\n'
selects true true true "the shared code" $'Apps/Shared/LookDocument.swift\n'
selects true true true "the iOS target's glue" $'Apps/Topo/TopoApp.swift\n'
selects true true true "a markdown file the app bundles" $'Apps/Topo/Resources/skill.md\n'
for package in TopoAuth TopoCore TopoMascot TopoProxy TopoTurn TopoUserland; do
  selects true true true "$package, which the app links" "Packages/$package/Sources/$package/File.swift"$'\n'
done
selects true true true "the unit tests" $'Tests/Client/LookToolTests.swift\n'
selects true true true "the UI tests" $'Tests/ClientUI/MicrophonePressTests.swift\n'
selects true true true "the project" $'project.yml\n'
selects true true true "the generated project" $'Topo.xcodeproj/project.pbxproj\n'
selects true true true "the resolved packages" $'Topo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved\n'
selects true true true "a guest patch" $'patches/ish/0004-guest-mount-real-refused.patch\n'
selects true true true "the bundled licences" $'THIRD-PARTY\nLICENSE\n'
selects true true true "the icon the targets bundle" $'Design/topo-mark.svg\n'
selects true true true "this workflow" $'.github/workflows/pr-validate.yaml\n'
selects true true true "the prepare action" $'.github/actions/prepare/action.yml\n'
selects true true true "a CI script" $'scripts/ci-select-suites.sh\n'
selects true true true "a script's test" $'scripts/tests/suite-gate-test.sh\n'
selects true true true "a build script" $'scripts/build-ish.sh\n'
selects true true true "a path no rule names" $'Somewhere/New.swift\n'

# A union: each path's suites.
selects false false true "TopoLink beside documentation" $'docs/design.md\nPackages/TopoLink/Package.swift\n'
selects true true true "Womble beside the app" $'Womble/Sources/App/AppDelegate.swift\nApps/Client/Ear.swift\n'

# Nothing read: every suite, since an empty list is as likely a diff that failed.
selects true true true "no changed paths" ""

# A broken rule list exits 2 with no selection.
broken() {
  local name="$1" list="$2" out status
  out="$(printf 'docs/design.md\n' | SUITE_RULES="$list" "$script" 2>&1)" && status=0 || status=$?
  if [ "$status" = 2 ] && ! grep -q '=true\|=false' <<<"$out"; then
    echo "ok   $name exits 2 with no selection"
  else
    fail "$name: exit $status: $out"
  fi
}
broken "an empty SUITE_RULES" ""
broken "a rule naming no suite" $'docs/*\n'
broken "a rule naming a job that does not exist" $'docs/* topo_docs\n'
broken "a rule mixing all with a job" $'docs/* all others\n'

# The select step itself, extracted from the workflow and run in scratch repositories.
step_run="$(ruby -ryaml -e '
  w = YAML.load_file(ARGV[0])
  print w.fetch("jobs").fetch("select").fetch("steps").find { |s| s["id"] == "suites" }.fetch("run")
' "$workflow")" || exit 2
scratch="$(mktemp -d -t ci-select-suites-test)"
trap 'rm -rf "$scratch"' EXIT

# run_step <case> <repo> <expected "unit ui others"> <expected reason pattern>
run_step() {
  local name="$1" repo="$2" want="$3" match="$4" out status got reason
  : > "$scratch/output"
  out="$(cd "$repo" && EVENT="${STEP_EVENT:-pull_request}" SUITE_RULES="$rules" \
    RUNNER_TEMP="$scratch" GITHUB_OUTPUT="$scratch/output" GITHUB_STEP_SUMMARY="$scratch/summary" \
    bash -eo pipefail -c "$step_run" 2>&1)" && status=0 || status=$?
  got="$(sed -n 's/^topo_unit=//p' "$scratch/output") $(sed -n 's/^topo_ui=//p' "$scratch/output") $(sed -n 's/^others=//p' "$scratch/output")"
  reason="$(sed -n 's/^reason=//p' "$scratch/output")"
  if [ "$status" != 0 ] || [ "$got" != "$want" ] || ! grep -q -- "$match" <<<"$reason"; then
    fail "step, $name: wanted $want and a reason matching '$match', got exit $status, $got, reason=$reason: $out"
  elif ! grep -q "Suites: " <<<"$out"; then
    fail "step, $name: no Suites notice in the log: $out"
  else
    echo "ok   step, $name → $got ($reason)"
  fi
}

# repo <dir> <path>... — a scratch repository whose last commit adds each path.
repo() {
  local dir="$1"; shift
  mkdir -p "$dir/scripts"
  cp "$script" "$dir/scripts/ci-select-suites.sh"
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

repo "$scratch/docs" docs/design.md README.md
run_step "a documentation change" "$scratch/docs" "false false false" "none of the 2 changed paths needs a suite"
repo "$scratch/link" Packages/TopoLink/Sources/TopoLink/Probe.swift
run_step "a TopoLink change" "$scratch/link" "false false true" "others for Packages/TopoLink/Sources/TopoLink/Probe.swift"
repo "$scratch/app" Apps/Client/Ear.swift
run_step "an app change" "$scratch/app" "true true true" "topo_unit, topo_ui, others for Apps/Client/Ear.swift"
repo "$scratch/shallow"
run_step "a diff producer that fails (no HEAD^1)" "$scratch/shallow" "true true true" "changed paths are unknown"

# A rename out of the app: the source is the path that needs the suites.
repo "$scratch/rename" Apps/Client/Ear.swift
mkdir -p "$scratch/rename/docs"
git -C "$scratch/rename" mv Apps/Client/Ear.swift docs/Ear.swift
git -C "$scratch/rename" -c user.name=t -c user.email=t@t commit -qm rename
run_step "an app file renamed into docs" "$scratch/rename" "true true true" "Apps/Client/Ear.swift"

STEP_EVENT=schedule run_step "the nightly" "$scratch/docs" "true true true" "outside a pull request (schedule)"
STEP_EVENT=workflow_dispatch run_step "a dispatch" "$scratch/docs" "true true true" "outside a pull request (workflow_dispatch)"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
