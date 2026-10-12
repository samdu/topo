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
#      changes against its merge base with origin/main (fetched first), with the commit's own
#      scripts/ci-select-suites.sh and scripts/ci-select-lane.sh over the SUITE_RULES and
#      VOICE_PATHS lists read out of the commit's own .github/workflows/pr-validate.yaml.
#      --suites and --lane override the choice, for a head whose `test` job names a status this
#      choice left out (the two read different diffs once main has moved under the branch).
#   2. Takes a slot, which is a checkout: one of TOPO_VALIDATE_SLOTS (two) directories under
#      ~/Library/Caches/topo-validate/slots, each with a lock held for the run and a validation
#      worktree of this repository, detached at the commit. So what runs is the commit and
#      nothing else: uncommitted changes and untracked files in the engineer's worktree are not
#      in it, and the projects XcodeGen regenerates are not written over the engineer's. A
#      slot's path never changes, so its DerivedData, the guest's framework and build/ stay
#      warm; two runs at once are in two slots.
#   3. Runs each suite under that suite's own lock (suite-<name>.lock beside the slots), one
#      call of scripts/mac-suite.sh a suite, the commit's own copy: the first of the suites
#      still to run whose lock is free, in the order topo_unit, topo_ui, others, so a run whose `topo_unit` is a
#      sibling's goes on with its `others`. One suite of a name runs on this Mac at a time (the
#      audio lane is one per Mac), and two runs overlap in two different suites. The waits for
#      a slot and for a suite are LOCK_WAIT seconds between them (three hours); nothing makes
#      them first come, first served.
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
# ~/Library/Logs/topo-validate/<sha>/ on this Mac, one directory per run inside it (named for
# when its suites began, UTC, once the slot was this run's), so a head run again after a red
# keeps the red run's logs. The ten newest commits are kept, and each one's five newest runs. It exits 0
# when every suite passed and the statuses are posted, 1 on a red suite, 2 on anything that
# stopped it earlier, and 143 when a signal ended it, its suite ended with it.
#
# A SIGKILL ends the script and not its suite, and the kernel drops the locks with the script.
# So the suite's pid and name are on record in its slot (slots/<n>/suite), and while that suite
# is still going no run takes the slot, whose checkout would be moved to another commit under
# it, and none starts a suite of its name.
#
# A branch that has not merged main runs the script as it was, which holds one lock
# ($cache/lock) for its whole run, in one checkout ($cache/checkout), and takes no suite's
# lock. A run here holds that lock shared, so the two kinds never overlap and runs of this
# script share it; a run of the script as it was waits for as long as any of these is going.
set -euo pipefail

cache="${TOPO_VALIDATE_CACHE:-$HOME/Library/Caches/topo-validate}"
logs_root="${TOPO_VALIDATE_LOGS:-$HOME/Library/Logs/topo-validate}"
repo_slug="${TOPO_VALIDATE_REPO:-samdu/topo}"
LOCK_WAIT="${LOCK_WAIT:-10800}"
LOCK_POLL="${LOCK_POLL:-5}"   # seconds between looks at a lock that is held
SLOTS="${TOPO_VALIDATE_SLOTS:-2}"
KEEP_LOGS=10
KEEP_RUNS=5
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
case "$SLOTS" in "" | *[!0-9]* | 0) echo "TOPO_VALIDATE_SLOTS is '$SLOTS': a count of checkouts, one or more" >&2; exit 2 ;; esac

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

# The selectors are the commit's own too, as `select` runs them: a copy edited and not committed
# in this worktree would choose here what the workflow does not.
selectors="$(mktemp -d -t topo-validate-select)" || die "could not make a directory for the commit's selectors."
trap 'rm -rf "$selectors"' EXIT
for selector in ci-select-suites.sh ci-select-lane.sh; do
  git show "$sha:scripts/$selector" > "$selectors/$selector" || die "$short has no scripts/$selector."
done
selection="$(SUITE_RULES="$rules" bash "$selectors/ci-select-suites.sh" --git "$base" "$sha" 2>/dev/null)" || die "scripts/ci-select-suites.sh failed."
lane="$(VOICE_PATHS="$voice" bash "$selectors/ci-select-lane.sh" --git "$base" "$sha" 2>/dev/null | sed -n 's/^lane=//p')"
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

commit_logs="$logs_root/$sha"
logs=""   # this run's own directory under the commit's, made once the slot is held
host="$(hostname -s)"
results=""   # `<suite>=success|failure` lines, as mac-suite.sh wrote them
took=""      # `<suite>=<minutes>` lines
minutes=0

# The suite a slot has on record, as `<pid> <suite>`, while it is still running: one whose
# script was killed outright. A pid alone can be recycled, so it is held to when it began; a
# record with no start is of nothing live.
orphan_in() {  # orphan_in <directory holding a `suite` record>
  local pid began
  [ -s "$1/suite" ] || return 1
  pid="$(sed -n 1p "$1/suite")"
  began="$(sed -n 2p "$1/suite")"
  [ -n "$pid" ] && [ -n "$began" ] && [ "$(began_of "$pid")" = "$began" ] || return 1
  echo "$pid $(sed -n 3p "$1/suite")"
}
# One look's wait at something held, against the LOCK_WAIT seconds the run has for all of them;
# who holds it is said when the wait begins and every ten minutes after.
waited=0
say_at=0
waiting() {  # waiting <for what> <who holds it>
  [ "$waited" -lt "$LOCK_WAIT" ] || die "gave up after waiting $((LOCK_WAIT / 60)) min, the last of it for $1 ($2). Nothing is pushed or posted."
  if [ "$waited" -ge "$say_at" ]; then
    echo "Waiting for $1 ($2); up to $(((LOCK_WAIT - waited) / 60)) min more."
    say_at=$((waited + 600))
  fi
  sleep "$LOCK_POLL"
  waited=$((waited + LOCK_POLL))
}

if [ "${#chosen[@]}" -gt 0 ]; then
  mkdir -p "$cache/slots" "$logs_root"
  trap 'exit 143' TERM INT HUP
  # A slot: its lock on descriptor 7 for the run, dropped by the kernel when this script dies.
  # One with an orphan in its checkout is not taken; with nothing but orphans there is nothing
  # to wait for.
  slot=""
  while [ -z "$slot" ]; do
    held="" orphans=""
    for n in $(seq "$SLOTS"); do
      mkdir -p "$cache/slots/$n"
      exec 7>> "$cache/slots/$n/lock"
      if ! lockf -s -t 0 7; then
        held="$held; slot $n: $(cat "$cache/slots/$n/holder" 2>/dev/null || echo unknown)"
      elif orphan="$(orphan_in "$cache/slots/$n")"; then
        orphans="$orphans; slot $n: ${orphan#* } of an earlier validation is still running without its script, pid ${orphan%% *}, end it with \`kill ${orphan%% *}\`"
      else
        slot="$n"
        break
      fi
      exec 7>&-
    done
    [ -n "$slot" ] || [ -n "$held" ] || die "no checkout is free${orphans#;}. That stops its lane and deletes its simulators; then run again."
    [ -n "$slot" ] || { both="$held$orphans"; waiting "a checkout" "${both#; }"; }
  done
  slot_dir="$cache/slots/$slot"
  echo "$branch $short, pid $$, since $(date '+%H:%M')" > "$slot_dir/holder"

  # The lock a run of the script as it was holds whole, held here shared, on descriptor 8: such
  # a run and this one are never going at once, and neither is a suite one left behind it.
  exec 8>> "$cache/lock"
  say_at="$waited"
  until perl -MFcntl=:flock -e 'open(my $lock, ">&=", 8) or exit 2; exit(flock($lock, LOCK_SH | LOCK_NB) ? 0 : 1)'; do
    waiting "a run of the script as it was before slots" "$(cat "$cache/holder" 2>/dev/null || echo unknown)"
  done
  if orphan="$(orphan_in "$cache")"; then
    die "the suite of an earlier validation is still running without its script (pid ${orphan%% *}; $(cat "$cache/holder" 2>/dev/null || echo unknown)). End it with \`kill ${orphan%% *}\`, which stops its lane and deletes its simulators, and run again."
  fi
  echo "$branch $short, pid $$, slot $slot, since $(date '+%H:%M')" > "$cache/holder"

  checkout="$slot_dir/checkout"
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

  # This run's logs, beside the four newest of the commit's earlier runs: by name, which is
  # when each began, so the run in hand is never one of those removed, and before the suites,
  # so a run a signal ends is counted by the next. Only what is named as a run is touched.
  mkdir -p "$commit_logs"
  ls -1 "$commit_logs" | { grep -E '^[0-9]{8}T[0-9]{6}Z-[0-9]+$' || true; } | sort -t- -k1,1r -k2,2nr | tail -n "+$KEEP_RUNS" | while IFS= read -r old; do
    rm -rf "${commit_logs:?}/$old"
  done
  logs="$commit_logs/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir "$logs" || die "could not make $logs."
  echo "Running ${chosen[*]} (lane $lane) at $short in $checkout; logs in $logs"
  started=$SECONDS

  remaining=" ${chosen[*]} "
  while [ "$remaining" != " " ]; do
    # The first suite still to run that no sibling is running, its lock on descriptor 6. A
    # suite a killed script left going holds its name as a lock would.
    suite="" held=""
    for candidate in $remaining; do
      exec 6>> "$cache/suite-$candidate.lock"
      if ! lockf -s -t 0 6; then
        held="$held; $candidate: $(cat "$cache/suite-$candidate.holder" 2>/dev/null || echo unknown)"
      else
        # Free, and on record as running in some slot: its script is gone.
        orphan=""
        for dir in "$cache"/slots/*/; do
          if found="$(orphan_in "$dir")" && [ "${found#* }" = "$candidate" ]; then orphan="${found%% *}"; fi
        done
        if [ -z "$orphan" ]; then
          suite="$candidate"
          break
        fi
        held="$held; $candidate: still running without its script, pid $orphan, end it with \`kill $orphan\`"
      fi
      exec 6>&-
    done
    if [ -z "$suite" ]; then
      waiting "a suite" "${held#; }"
      continue
    fi
    say_at="$waited"
    echo "$branch $short, pid $$, slot $slot, since $(date '+%H:%M')" > "$cache/suite-$suite.holder"
    echo "$suite: began $(date '+%H:%M')"
    suite_started=$SECONDS
    # The descriptors closed: nothing the suite leaves running holds a lock. `exec`, so the pid
    # is the suite's own and a signal to this script ends it by that pid.
    (cd "$checkout" && exec scripts/mac-suite.sh --lane "$lane" --results "$logs" --cache "$cache" "$suite") \
      >> "$logs/mac-suite.log" 2>&1 6>&- 7>&- 8>&- &
    suite_pid=$!
    # Written whole or not at all, and only for a suite that is running: one that could not
    # start has no start to record, and its failure is reported below like any other.
    began="$(began_of "$suite_pid")"
    if [ -n "$began" ]; then
      printf '%s\n%s\n%s\n' "$suite_pid" "$began" "$suite" > "$slot_dir/suite.$$" && mv -f "$slot_dir/suite.$$" "$slot_dir/suite"
    else
      rm -f "$slot_dir/suite"
    fi
    # `|| true`: under `set -e` the wait's own status, the signal's, would end the trap there.
    trap 'kill "$suite_pid" 2>/dev/null || true; wait "$suite_pid" 2>/dev/null || true; rm -f "$slot_dir/suite"; exit 143' TERM INT HUP
    suite_status=0
    wait "$suite_pid" || suite_status=$?
    trap 'exit 143' TERM INT HUP
    rm -f "$slot_dir/suite"
    exec 6>&-
    # mac-suite.sh starts its suites.txt afresh each call. The suite has a line, or it failed:
    # a call that died early wrote none.
    said="$(grep "^$suite=" "$logs/suites.txt" 2>/dev/null || true)"
    grep -q "^$suite=\(success\|failure\)$" <<<"$said" || said="$suite=failure"
    [ "$suite_status" = 0 ] || grep -q '=failure$' <<<"$said" || die "scripts/mac-suite.sh exited $suite_status with $suite not red; see $logs/mac-suite.log."
    results="$results$said"$'\n'
    took="$took$suite=$(((SECONDS - suite_started) / 60))"$'\n'
    echo "$suite: $(grep -q '=failure$' <<<"$said" && echo failure || echo success) in $(((SECONDS - suite_started) / 60)) min"
    remaining="${remaining/ $suite / }"
  done
  trap - TERM INT HUP
  exec 6>&- 7>&- 8>&-
  minutes=$(((SECONDS - started) / 60))
  # Every suite's result in the one file, as each call left its own.
  printf '%s' "$results" > "$logs/suites.txt"
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
  local try said="$3 logs $where"
  # GitHub keeps 140 characters. A path too long for them keeps its end, which is the commit.
  if [ "${#said}" -gt 140 ]; then
    said="logs $where"
    [ "${#said}" -le 140 ] || said="logs ...${where: -132}"
  fi
  for try in 1 2 3; do
    if gh api --silent -X POST "repos/$repo_slug/statuses/$sha" \
         -f context="$1" -f state="$2" -f description="$said" >/dev/null; then
      echo "posted $1: $2"
      return 0
    fi
    sleep $((try * POST_RETRY))
  done
  die "could not post $1 to $short; run again with --no-push once GitHub answers."
}
# The logs as a description names them: the commit's directory and not the run's inside it,
# which under the default root would take the description past the 140 characters.
where="~${commit_logs#"$HOME"}"
[ "$where" != "~$commit_logs" ] || where="$commit_logs"
for suite in ${chosen[@]+"${chosen[@]}"}; do
  # Red by any line that says so, as `red` above is read: never the last word of several.
  if grep -q "^$suite=failure$" <<<"$results" || ! grep -q "^$suite=success$" <<<"$results"; then
    state=failure said=failed
  else
    state=success said=passed
  fi
  post "local/$suite" "$state" "$suite $said, $lane lane, $(sed -n "s/^$suite=//p" <<<"$took") min on $host;"
  if [ "$suite" = topo_ui ] && [ "$lane" = full ] && [ "$state" = success ]; then
    post local/real_ear success "Parakeet heard the fixture on $host;"
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
