#!/usr/bin/env bash
# Chooses which of the PR check's three Mac suites — `topo_unit`, `topo_ui` and `others`
# (scripts/mac-suite.sh) — a change needs, from the paths it touches. A suite left out is not run
# by scripts/validate-and-push.sh, and the `test` job asks for no status for it only because
# this said `false` for it.
#
#   SUITE_RULES="$rules" scripts/ci-select-suites.sh --git HEAD^1 HEAD
#   git diff --name-only HEAD^1 HEAD | SUITE_RULES="$rules" scripts/ci-select-suites.sh
#
# With `--git <base> <head>` it reads the changed paths itself, from `git diff --no-renames
# --name-only` (so a rename counts by both its old and its new path), and prints them to stderr;
# a diff that fails (a base the checkout does not hold, a shallow clone) is changed paths
# unknown, which selects every suite and says why. Without it, the paths come on stdin.
#
# SUITE_RULES is the rule list, one rule per line: a bash glob (`*` crosses `/`) and then the
# suites a path matching it needs — suite names, `all` or `none`. Blank lines and lines starting
# with `#` are ignored. A path takes the first rule it matches, and a path no rule matches needs
# every suite, so a new directory runs everything until a rule says otherwise. The list lives in
# .github/workflows/pr-validate.yaml, on the step that calls this, and
# scripts/tests/ci-select-suites-test.sh reads it from there.
#
# Writes `topo_unit=`, `topo_ui=` and `others=` (each `true` or `false`) and `reason=<one line>`
# to stdout, in $GITHUB_OUTPUT's form. It fails toward running, never toward skipping: no changed
# paths at all selects every suite, since an empty list is as likely a diff that could not be read
# as a change that touches nothing. An empty SUITE_RULES, or a rule naming no suite or one that
# does not exist, is a broken workflow and exits 2.
set -euo pipefail

jobs=(topo_unit topo_ui others)

all() {
  local job
  for job in "${jobs[@]}"; do echo "$job=true"; done
  echo "reason=$1"
  exit 0
}

globs=()
needs=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [ -z "$line" ] || [ "${line:0:1}" = "#" ] && continue
  read -r glob suites <<<"$line"
  [ -n "$suites" ] || { echo "::error::The SUITE_RULES line '$line' names no suite." >&2; exit 2; }
  for suite in $suites; do
    case " all none ${jobs[*]} " in
      *" $suite "*) ;;
      *) echo "::error::The SUITE_RULES line '$line' names '$suite', which is not all, none or one of ${jobs[*]}." >&2; exit 2 ;;
    esac
  done
  case " $suites " in
    *" all "* | *" none "*) [ "$suites" = all ] || [ "$suites" = none ] \
      || { echo "::error::The SUITE_RULES line '$line' mixes all or none with other suites." >&2; exit 2; } ;;
  esac
  [ "$suites" = all ] && suites="${jobs[*]}"
  [ "$suites" = none ] && suites=""
  globs+=("$glob")
  needs+=("$suites")
done <<< "${SUITE_RULES:-}"
[ "${#globs[@]}" -gt 0 ] || { echo "::error::SUITE_RULES is empty: there are no rules to select the suites by." >&2; exit 2; }

if [ "${1:-}" = --git ]; then
  [ "$#" -eq 3 ] || { echo "usage: $0 [--git <base> <head>]" >&2; exit 2; }
  # --no-renames: a rename is its source and its destination, and either may need a suite.
  if ! changed="$(git diff --no-renames --name-only "$2" "$3" 2>&1)"; then
    echo "The changed paths could not be read: $changed" >&2
    all "the changed paths are unknown (git diff $2 $3 failed: $(head -n 1 <<<"$changed")), so every suite runs"
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
[ "${#paths[@]}" -gt 0 ] || all "no changed paths were read, so every suite runs"

# Each suite with the first path that asked for it, which is the reason given for it: why[i] is
# jobs[i]'s. (Indexed, not associative: the test also runs under macOS's bash 3.2.)
why=("" "" "")
for path in "${paths[@]}"; do
  rule="no rule"
  wanted="${jobs[*]}"
  for i in "${!globs[@]}"; do
    # shellcheck disable=SC2053 # the pattern is a glob on purpose
    if [[ "$path" == ${globs[$i]} ]]; then
      rule="${globs[$i]}"
      wanted="${needs[$i]}"
      break
    fi
  done
  for j in "${!jobs[@]}"; do
    case " $wanted " in
      *" ${jobs[$j]} "*) [ -n "${why[$j]}" ] || why[j]="$path ($rule)" ;;
    esac
  done
done

for j in "${!jobs[@]}"; do
  if [ -n "${why[$j]}" ]; then echo "${jobs[$j]}=true"; else echo "${jobs[$j]}=false"; fi
done
# The reason names each path once, with the suites it brought in: `topo_unit, topo_ui for <path>`.
reason=""
for j in "${!jobs[@]}"; do
  [ -n "${why[$j]}" ] || continue
  named=""
  for k in "${!jobs[@]}"; do
    [ "${why[$k]}" = "${why[$j]}" ] || continue
    [ "$k" -ge "$j" ] || continue 2
    named="$named, ${jobs[$k]}"
  done
  reason="$reason; ${named#, } for ${why[$j]}"
done
if [ -z "$reason" ]; then
  echo "reason=none of the ${#paths[@]} changed paths needs a suite"
else
  echo "reason=${reason#; }"
fi
