#!/usr/bin/env bash
# The engineer's push, and the merge gate's evidence: runs the PR check's Mac suites on this Mac
# at the commit being pushed, pushes that commit, and posts each suite's result to it as a commit
# status, which is what pr-validate.yaml's `test` job requires in place of a hosted macOS run.
#
#   scripts/validate-and-push.sh [--no-push] [--suites "<suite>..."|all|none] [--lane fast|full]
#
# Run from the worktree whose HEAD is the commit to push, on its branch. In order:
#
#   1. Chooses the suites and the lane as the `select` job does, from the paths the commit
#      changes against its merge base with origin/main (fetched first), with
#      scripts/ci-select-suites.sh and scripts/ci-select-lane.sh over the SUITE_RULES and
#      VOICE_PATHS lists read out of the commit's own .github/workflows/pr-validate.yaml.
#      --suites and --lane override the choice, for a head whose `test` job names a status this
#      choice left out (the two read different diffs once main has moved under the branch).
#   2. Takes the Mac's one validation lock, waiting up to LOCK_WAIT seconds (three hours) for a
#      sibling's run: the audio lane is one per Mac, and two suites at once starve each other.
#   3. Checks the commit out, detached, in the Mac's validation worktree
#      (~/Library/Caches/topo-validate/checkout, a linked worktree of this repository) and runs
#      scripts/mac-suite.sh there, the commit's own copy. So what runs is the commit and nothing
#      else: uncommitted changes and untracked files in the engineer's worktree are not in it,
#      and the projects XcodeGen regenerates are not written over the engineer's. The path is
#      the same every run, so its DerivedData, the guest's framework and build/ stay warm.
#   4. Pushes the commit to its branch on origin, without force, only when every suite passed.
#      A red suite pushes nothing. --no-push never pushes.
#   5. Posts the statuses to the commit, once origin's branch is at it: `local/<suite>` as
#      `success` or `failure` for each suite run, and `local/real_ear` beside a `topo_ui` that
#      passed on the full lane. GitHub takes a status only for a commit it has, which is why the
#      push comes first; a commit that was already origin's head when the run began (a draft
#      pushed without this script) gets its statuses whatever the suites did. A suite the choice
#      left out gets none, and `test` asks for none.
#   6. Re-runs the `test` job of the commit's newest pull_request run when that run has
#      concluded with `test` red, which is a head validated after its push: `test` waited two
#      minutes for a status and gave up. Only that job (`gh run rerun --job`), and what depends
#      on it.
#
# Each status's description says pass or fail, the lane, the minutes and where the logs are:
# ~/Library/Logs/topo-validate/<sha>/ on this Mac, kept for the ten newest commits. It exits 0
# when every suite passed and the statuses are posted, 1 on a red suite, 2 on anything that
# stopped it earlier, and 143 when a signal ended it, its suite ended with it.
#
# A SIGKILL ends the script and not its suite, and the kernel drops the lock with the script.
# So the suite's pid is on record beside the lock ($cache/suite), and a run that finds that
# suite still going refuses to start beside it: two suites in the one checkout and the one
# logs directory would each answer for the other.
set -euo pipefail

cache="${TOPO_VALIDATE_CACHE:-$HOME/Library/Caches/topo-validate}"
logs_root="${TOPO_VALIDATE_LOGS:-$HOME/Library/Logs/topo-validate}"
repo_slug="${TOPO_VALIDATE_REPO:-samdu/topo}"
LOCK_WAIT="${LOCK_WAIT:-10800}"
KEEP_LOGS=10
POST_RETRY="${POST_RETRY:-3}"   # seconds before a status is posted again, times the try
SUITES=(topo_unit topo_ui others)

push=yes
suites_arg=""
lane_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --no-push) push=no; shift ;;
    --suites) suites_arg="${2:-}"; [ -n "$suites_arg" ] || { echo "--suites takes suite names, all or none" >&2; exit 2; }; shift 2 ;;
    --lane) lane_arg="${2:-}"; [ -n "$lane_arg" ] || { echo "--lane takes full or fast" >&2; exit 2; }; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 2 ;;
  esac
done
case "$lane_arg" in "" | full | fast) ;; *) echo "no such lane '$lane_arg': full or fast" >&2; exit 2 ;; esac

die() { echo "error: $*" >&2; exit 2; }
# When a pid began, as ps's lstart gives it in one zone and one locale whatever the caller's are,
# so two runs from two sessions read the same words. Empty for a pid that is not running.
began_of() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1" 2>/dev/null || true; }

top="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not in a git worktree."
cd "$top"
branch="$(git symbolic-ref --quiet --short HEAD)" || die "HEAD is detached; check out the branch the commit is pushed to."
[ "$branch" != main ] || die "this is main; a change lands as a PR from its own branch."
sha="$(git rev-parse HEAD)"
short="${sha:0:7}"
if [ -n "$(git status --porcelain)" ]; then
  echo "warning: this worktree has uncommitted changes or untracked files; they are not in $short, which is what is validated and pushed." >&2
fi

git fetch --quiet origin main || die "could not fetch origin/main to choose the suites against."
base="$(git merge-base origin/main "$sha")" || die "$short has no merge base with origin/main."

# Whether origin's branch is at the commit, read from origin and never a local ref.
remote_head() { git ls-remote origin "refs/heads/$branch" | cut -f1; }
already_pushed=no
[ "$(remote_head)" != "$sha" ] || already_pushed=yes
if [ "$push" = no ] && [ "$already_pushed" = no ]; then
  die "origin's $branch is not at $short, and --no-push posts only to a commit origin already has as the branch's head."
fi

# The lists `select` reads, out of the commit's own workflow.
workflow="$(git show "$sha:.github/workflows/pr-validate.yaml")" || die "$short has no .github/workflows/pr-validate.yaml."
list() {  # list <step id> <env name>
  ruby -ryaml -e '
    w = YAML.safe_load(STDIN.read, aliases: true)
    print w.fetch("jobs").fetch("select").fetch("steps").find { |s| s["id"] == ARGV[0] }.fetch("env").fetch(ARGV[1])
  ' "$1" "$2" <<<"$workflow"
}
rules="$(list suites SUITE_RULES)" || die "could not read SUITE_RULES from $short's workflow."
voice="$(list lane VOICE_PATHS)" || die "could not read VOICE_PATHS from $short's workflow."

selection="$(SUITE_RULES="$rules" scripts/ci-select-suites.sh --git "$base" "$sha" 2>/dev/null)" || die "scripts/ci-select-suites.sh failed."
lane="$(VOICE_PATHS="$voice" scripts/ci-select-lane.sh --git "$base" "$sha" 2>/dev/null | sed -n 's/^lane=//p')"
case "$lane" in full | fast) ;; *) die "scripts/ci-select-lane.sh gave no lane." ;; esac
chosen=()
for suite in "${SUITES[@]}"; do
  case "$(sed -n "s/^$suite=//p" <<<"$selection")" in
    true) chosen+=("$suite") ;;
    false) ;;
    *) die "scripts/ci-select-suites.sh said neither true nor false for $suite." ;;
  esac
done
echo "select: ${chosen[*]:-no suite} ($(sed -n 's/^reason=//p' <<<"$selection")); lane $lane"
case "$suites_arg" in
  "") ;;
  all) chosen=("${SUITES[@]}") ;;
  none) chosen=() ;;
  *)
    chosen=()
    for suite in $suites_arg; do
      case " ${SUITES[*]} " in *" $suite "*) chosen+=("$suite") ;; *) die "no such suite '$suite': one of ${SUITES[*]}, all or none." ;; esac
    done
    ;;
esac
[ -z "$lane_arg" ] || lane="$lane_arg"
[ -z "$suites_arg$lane_arg" ] || echo "asked for: ${chosen[*]:-no suite}; lane $lane"

logs="$logs_root/$sha"
host="$(hostname -s)"
results=""   # `<suite>=success|failure` lines, as mac-suite.sh wrote them
minutes=0

if [ "${#chosen[@]}" -gt 0 ]; then
  mkdir -p "$cache" "$logs_root"
  # One validation at a time on this Mac. The kernel drops the lock when this script dies.
  exec 8> "$cache/lock"
  if ! lockf -s -t 0 8; then
    echo "Another validation holds this Mac ($(cat "$cache/holder" 2>/dev/null || echo unknown)); waiting up to $((LOCK_WAIT / 60)) min."
    lockf -s -t "$LOCK_WAIT" 8 || die "another validation still holds this Mac after $((LOCK_WAIT / 60)) min ($(cat "$cache/holder" 2>/dev/null || echo unknown))."
  fi
  # A suite whose script was killed outright is still running with the lock free. A pid alone
  # can be recycled, so it is held to when it began; a record with no start is of nothing live.
  if [ -s "$cache/suite" ]; then
    orphan="$(sed -n 1p "$cache/suite")"
    began="$(sed -n 2p "$cache/suite")"
    if [ -n "$orphan" ] && [ -n "$began" ] && [ "$(began_of "$orphan")" = "$began" ]; then
      die "the suite of an earlier validation is still running without its script (pid $orphan; $(cat "$cache/holder" 2>/dev/null || echo unknown)). End it with \`kill $orphan\`, which stops its lane and deletes its simulators, and run again."
    fi
  fi
  echo "$branch $short, pid $$, since $(date '+%H:%M')" > "$cache/holder"

  checkout="$cache/checkout"
  if [ ! -e "$checkout/.git" ]; then
    git worktree prune
    git worktree add --quiet --detach "$checkout" "$sha" || die "could not make the validation worktree at $checkout."
  fi
  [ "$(git -C "$checkout" rev-parse --git-common-dir)" -ef "$(git rev-parse --git-common-dir)" ] \
    || die "$checkout is a worktree of another repository."
  # Tracked files as the commit has them, and nothing untracked but what .gitignore names:
  # build/, DerivedData and the guest's framework are the warm cache.
  git -C "$checkout" checkout --quiet --force --detach "$sha" || die "could not check $short out in $checkout."
  git -C "$checkout" clean --quiet -fd
  [ "$(git -C "$checkout" rev-parse HEAD)" = "$sha" ] || die "$checkout is not at $short."

  rm -rf "$logs"
  mkdir -p "$logs"
  echo "Running ${chosen[*]} (lane $lane) at $short in $checkout; logs in $logs"
  started=$SECONDS
  # 8>&-: nothing the suite leaves running holds the lock. `exec`, so the pid is the suite's
  # own and a signal to this script ends it by that pid.
  (cd "$checkout" && exec scripts/mac-suite.sh --lane "$lane" --results "$logs" --cache "$cache" "${chosen[@]}") \
    > "$logs/mac-suite.log" 2>&1 8>&- &
  suite_pid=$!
  # Written whole or not at all, and only for a suite that is running: one that could not start
  # has no start to record, and its failure is reported below like any other.
  began="$(began_of "$suite_pid")"
  if [ -n "$began" ]; then
    printf '%s\n%s\n' "$suite_pid" "$began" > "$cache/suite.$$" && mv -f "$cache/suite.$$" "$cache/suite"
  else
    rm -f "$cache/suite"
  fi
  trap 'kill "$suite_pid" 2>/dev/null; wait "$suite_pid" 2>/dev/null; exit 143' TERM INT HUP
  suite_status=0
  wait "$suite_pid" || suite_status=$?
  trap - TERM INT HUP
  rm -f "$cache/suite"
  minutes=$(((SECONDS - started) / 60))
  results="$(cat "$logs/suites.txt" 2>/dev/null || true)"
  # Every suite asked for has a line, or it failed: a run that died early wrote none.
  for suite in "${chosen[@]}"; do
    grep -q "^$suite=\(success\|failure\)$" <<<"$results" || results="$results"$'\n'"$suite=failure"
  done
  [ "$suite_status" = 0 ] || grep -q '=failure$' <<<"$results" || die "scripts/mac-suite.sh exited $suite_status with no suite red; see $logs/mac-suite.log."
  exec 8>&-
  # The ten newest commits' logs are kept.
  ls -1t "$logs_root" | tail -n "+$((KEEP_LOGS + 1))" | while IFS= read -r old; do
    case "$old" in *[!0-9a-f]* | "") ;; *) rm -rf "${logs_root:?}/$old" ;; esac
  done
fi

red="$(sed -n 's/=failure$//p' <<<"$results" | tr '\n' ' ')"
red="${red% }"
if [ -n "$red" ]; then
  echo "RED at $short: $red. Logs: $logs/mac-suite.log"
  sed -n '/^error: /p' "$logs/mac-suite.log" | tail -n 20
else
  echo "Every suite asked for passed at $short (${chosen[*]:-none needed}) in $minutes min."
fi

if [ -z "$red" ] && [ "$push" = yes ] && [ "$already_pushed" = no ]; then
  git push origin "$sha:refs/heads/$branch" || die "the push of $short to $branch was refused; nothing is posted."
fi
if [ "$(remote_head)" != "$sha" ]; then
  [ -z "$red" ] || { echo "Nothing was pushed and no status posted: origin's $branch is not at $short."; exit 1; }
  die "origin's $branch is not at $short after the push; nothing is posted."
fi

# post <context> <state> <description> — three tries, since a status that never lands is a
# green run the gate cannot see.
post() {
  local try
  for try in 1 2 3; do
    if gh api --silent -X POST "repos/$repo_slug/statuses/$sha" \
         -f context="$1" -f state="$2" -f description="${3:0:140}" >/dev/null; then
      echo "posted $1: $2"
      return 0
    fi
    sleep $((try * POST_RETRY))
  done
  die "could not post $1 to $short; run again with --no-push once GitHub answers."
}
# The logs as a description names them, short enough that the 140 characters keep the path.
where="~${logs#"$HOME"}"
[ "$where" != "~$logs" ] || where="$logs"
for suite in ${chosen[@]+"${chosen[@]}"}; do
  # Red by any line that says so, as `red` above is read: never the last word of several.
  if grep -q "^$suite=failure$" <<<"$results" || ! grep -q "^$suite=success$" <<<"$results"; then
    state=failure said=failed
  else
    state=success said=passed
  fi
  post "local/$suite" "$state" "$suite $said, $lane lane, $minutes min on $host; logs $where"
  if [ "$suite" = topo_ui ] && [ "$lane" = full ] && [ "$state" = success ]; then
    post local/real_ear success "Parakeet heard the fixture on $host; logs $where"
  fi
done

# A head validated after its push: `test` gave up waiting before these statuses existed.
rerun_test() {
  local run job
  run="$(gh api "repos/$repo_slug/actions/workflows/pr-validate.yaml/runs?head_sha=$sha&event=pull_request&per_page=100" \
    --jq '[.workflow_runs[]] | sort_by(.created_at, .id) | last | select(. != null) | "\(.id) \(.status)"')" || return 0
  [ -n "$run" ] && [ "${run#* }" = completed ] || return 0
  job="$(gh api "repos/$repo_slug/actions/runs/${run%% *}/jobs?filter=latest&per_page=100" \
    --jq '.jobs[] | select(.name == "test" and .conclusion == "failure") | .id')" || return 0
  [ -n "$job" ] || return 0
  if gh run rerun --repo "$repo_slug" --job "$job"; then
    echo "re-ran the test job of run ${run%% *}, which had given up waiting for these statuses."
  else
    echo "warning: could not re-run the test job of run ${run%% *}; re-run it by hand (gh run rerun --job $job)." >&2
  fi
}
[ -n "$red" ] || rerun_test

[ -z "$red" ] || exit 1
