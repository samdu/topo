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
#   2. Takes a slot, which is a checkout: one of TOPO_VALIDATE_SLOTS directories under
#      ~/Library/Caches/topo-validate/slots, each with a lock held for the run and a validation
#      worktree of this repository, detached at the commit. There is one unless more are
#      asked for, so one run's suite is on this Mac at a time and a second run waits: buddybox
#      shares its memory with the house's voice assistant, and one suite's simulators are
#      what it has room for. So what runs is the commit and
#      nothing else: uncommitted changes and untracked files in the engineer's worktree are not
#      in it, and the projects XcodeGen regenerates are not written over the engineer's. A
#      slot's path never changes, so its DerivedData, the guest's framework and build/ stay
#      warm; with TOPO_VALIDATE_SLOTS=2 two runs at once are in two slots.
#   3. Runs each suite under that suite's own lock (suite-<name>.lock beside the slots), one
#      call of scripts/mac-suite.sh a suite, the commit's own copy: the first of the suites
#      still to run whose lock is free, in the order they were chosen or asked for, so a run
#      whose `topo_unit` is a sibling's goes on with its next. One suite of a name runs on
#      this Mac at a time (the audio lane is one per Mac), and with more slots than one two
#      runs overlap in two different suites. The waits for a slot, for a suite and for a run of the script as it
#      was are LOCK_WAIT seconds between them (three hours); nothing makes them first come,
#      first served.
#      With another Mac named (TOPO_VALIDATE_HOSTS="thicc-boi", or a line of
#      ~/Library/Caches/topo-validate/hosts while the variable is not set, which is what
#      scripts/validate-host.sh writes; neither by default)
#      `topo_unit` and `others` go there first, over ssh, and here only when it is busy or
#      cannot be used: the commit is pushed to a repository of the Mac's own
#      (~/Library/Caches/topo-validate/repo.git there), checked out in its one validation
#      worktree under its own lock, the commit's `scripts/mac-suite.sh --check` asked whether
#      the Mac can run the suite, and the suite run in its login session, held awake, its
#      results copied into this run's logs. `topo_ui` runs here whatever is named: the audio
#      lane is buddybox's. A Mac that is not reached, lacks something or loses the suite partway
#      is said, runs nothing more of this validation, and is never a red suite: the suite
#      runs here. A pass counts only when the connection outlived it. A red result the Mac
#      wrote is red, as this Mac's would be, whatever there made it so.
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
# when the run began, UTC), so a head run again after a red
# keeps the red run's logs. The ten newest commits are kept, and each one's five newest runs. It exits 0
# when every suite passed and the statuses are posted, 1 on a red suite, 2 on anything that
# stopped it earlier, and 143 when a signal ended it, its suite ended with it (one on another
# Mac while that Mac answers; within about a minute and a half, the signal is heard anyway).
#
# A SIGKILL ends the script and not its suite, and the kernel drops the locks with the script.
# So the suite's pid and name are on record in its slot (slots/<n>/suite), and while that suite
# is still going no run takes the slot, whose checkout would be moved to another commit under
# it, and none starts a suite of its name.
#
# A branch that has not merged main runs the script as it was, which holds one lock
# ($cache/lock) for its whole run, in one checkout ($cache/checkout), and takes no suite's
# lock. A run here holds that lock shared, so the two kinds never overlap and runs of this
# script share it; a run of the script as it was waits for as long as any of these is going,
# a suite one of them left behind included.
set -euo pipefail

cache="${TOPO_VALIDATE_CACHE:-$HOME/Library/Caches/topo-validate}"
logs_root="${TOPO_VALIDATE_LOGS:-$HOME/Library/Logs/topo-validate}"
repo_slug="${TOPO_VALIDATE_REPO:-samdu/topo}"
LOCK_WAIT="${LOCK_WAIT:-10800}"
LOCK_POLL="${LOCK_POLL:-5}"   # seconds between looks at a lock that is held
SLOTS="${TOPO_VALIDATE_SLOTS:-1}"
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
      case " ${chosen[*]-} " in *" $suite "*) continue ;; esac
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
waiting() {  # waiting <for what> <who holds it> [seconds already waited, in place of the wait]
  [ "$waited" -lt "$LOCK_WAIT" ] || die "gave up after waiting $((LOCK_WAIT / 60)) min, the last of it for $1 ($2). Nothing is pushed or posted."
  if [ "$waited" -ge "$say_at" ]; then
    echo "Waiting for $1 ($2); up to $(((LOCK_WAIT - waited) / 60)) min more."
    say_at=$((waited + 600))
  fi
  [ -n "${3-}" ] || sleep "$LOCK_POLL"
  waited=$((waited + ${3:-$LOCK_POLL}))
}

# The other Macs a suite may run on, off unless named: TOPO_VALIDATE_HOSTS, or the lines of
# $cache/hosts when that is not set at all, each an ssh alias.
if [ -n "${TOPO_VALIDATE_HOSTS+set}" ]; then
  hosts="$TOPO_VALIDATE_HOSTS"
else
  hosts="$(sed -e 's/#.*//' "$cache/hosts" 2>/dev/null | tr '\n' ' ' || true)"
fi
set -f   # a name is never a pattern over this directory
hosts="$(echo $hosts)"
for name in $hosts; do
  case "$name" in *[!A-Za-z0-9._-]* | -*) die "'$name' is not a host: TOPO_VALIDATE_HOSTS and $cache/hosts name ssh aliases." ;; esac
done
set +f
ran_on=""   # `<suite>=<host>` lines, for a suite that ran on another Mac
# Every connection gives up on a Mac that stops answering within a minute, so one that fell
# asleep is found out and not waited on; and each is a connection of its own, since one
# carried by a shared master (ControlMaster) is the master's to give up on, which it does
# not.
ssh_options="-o BatchMode=yes -o ControlPath=none -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
ssh_to() { ssh $ssh_options "$@"; }
# What a host is asked to do, as `bash -s -- <sha> <lane> <suite> <run>` there: under that
# Mac's own lock, the commit checked out in its one validation worktree, mac-suite.sh asked
# whether the Mac can run the suite, and then the suite, in the login session where there is a
# way into it and held awake, its display too, so that it does not lock for idleness under
# the suite. It exits 75 when the Mac is busy, 76 when it cannot run the
# suite, each before anything ran, and otherwise as the suite did. Its pid is in the run's
# host.pid from the moment it has the lock, and a TERM to that pid ends whatever it has
# started: nothing more if the suite is not yet running, and otherwise the suite, by the pid
# its mac-suite.pids leads with (the way into the session is root's, and takes no signal from
# here). The suite has no git configuration of that Mac's person: the tests commit in
# scratch repositories, and a laptop that signs its owner's commits would ask a key of them
# for each. TOPO_VALIDATE_SESSION_RUN in that Mac's environment names another way into the
# session, or none when it is empty.
on_host='
sha="$1" lane="$2" suite="$3" run="$4"
cache="$HOME/Library/Caches/topo-validate"
results="$cache/logs/$run"
refuse() { echo "error: $1 on $(hostname -s)." >&2; exit 76; }
exec 9>> "$cache/lock"
lockf -s -t 0 9 || { echo "error: another validation is running on $(hostname -s)." >&2; exit 75; }
rm -rf "$results"
mkdir -p "$results" || refuse "could not make $results"
child=""
stop() {
  trap "" TERM INT HUP
  if [ -n "$child" ]; then
    for _ in $(seq 80); do
      [ ! -s "$results/mac-suite.pids" ] || break
      ps -p "$child" > /dev/null || break
      sleep 0.5
    done
    [ ! -s "$results/mac-suite.pids" ] || kill "$(head -n 1 "$results/mac-suite.pids")" 2>/dev/null
    wait "$child" 2>/dev/null
  fi
  exit 143
}
trap stop TERM INT HUP
echo $$ > "$results/host.pid"
checkout="$cache/checkout"
if [ ! -e "$checkout/.git" ]; then
  git --git-dir="$cache/repo.git" worktree prune 9>&-
  git --git-dir="$cache/repo.git" worktree add --quiet --detach "$checkout" "$sha" 9>&- || refuse "could not make a worktree at $checkout"
fi
git -C "$checkout" checkout --quiet --force --detach "$sha" 9>&- && git -C "$checkout" clean --quiet -fd 9>&- \
  || refuse "could not check $sha out in $checkout"
[ "$(git -C "$checkout" rev-parse HEAD)" = "$sha" ] || refuse "$checkout is not at $sha"
git --git-dir="$cache/repo.git" update-ref -d "refs/validate/$sha" 9>&-
cd "$checkout" || refuse "could not enter $checkout"
scripts/mac-suite.sh --check --cache "$cache" "$suite" 9>&- || exit 76
ls -1t "$cache/logs" 2>/dev/null | tail -n +6 | while IFS= read -r old; do rm -rf "${cache:?}/logs/$old"; done
command="cd \"$checkout\" && exec env GIT_CONFIG_GLOBAL=/dev/null scripts/mac-suite.sh --lane $lane --results \"$results\" --cache \"$cache\" $suite"
session="${TOPO_VALIDATE_SESSION_RUN-/usr/local/libexec/gui-session-run}"
if [ -n "$session" ] && [ -x "$session" ]; then
  sudo -n "$session" /usr/bin/caffeinate -di /bin/bash -lc "$command" 9>&- &
else
  /usr/bin/caffeinate -di /bin/bash -lc "$command" 9>&- &
fi
child=$!
status=0
wait "$child" || status=$?
exit "$status"
'

# run_on <host> <suite> — the suite on that Mac, its result gathered like one run here. It
# returns 0 with a result, 1 when the Mac is busy, and 2 when it cannot be used: not reached,
# lacking something, or lost partway. Only a suite that ran to a result there has one: a Mac
# that fell asleep is not a red suite, and the suite is still to run.
run_on() {
  local at="$1" suite="$2" run="$short-$$-$2" status=0 began said
  local there="Library/Caches/topo-validate"
  ssh_to "$at" "mkdir -p $there/logs && { [ -d $there/repo.git ] || git init --quiet --bare $there/repo.git; }" \
    || { echo "$at: not reached; it runs nothing of this validation."; return 2; }
  GIT_SSH_COMMAND="ssh $ssh_options" git push --quiet "$at:$there/repo.git" "+$sha:refs/validate/$sha" \
    || { echo "$at: would not take $short; it runs nothing of this validation."; return 2; }
  echo "$suite: began $(date '+%H:%M') on $at"
  suite_started=$SECONDS
  # Ended there by the pid the host's script left in host.pid, waited for a few seconds in
  # case the signal came before it; then this end of the connection, a minute later at most,
  # so a Mac that no longer answers does not hold the signal up.
  suite_pid=""
  trap 'ssh_to "$at" "for _ in 1 2 3 4 5 6 7 8 9 10; do [ ! -s $there/logs/$run/host.pid ] || break; sleep 0.5; done; kill \$(cat $there/logs/$run/host.pid)" 2>/dev/null || true
        if [ -n "$suite_pid" ]; then
          for _ in $(seq 60); do kill -0 "$suite_pid" 2>/dev/null || break; sleep 1; done
          kill "$suite_pid" 2>/dev/null || true; wait "$suite_pid" 2>/dev/null || true
        fi
        exit 143' TERM INT HUP
  ssh_to "$at" bash -s -- "$sha" "$lane" "$suite" "$run" <<<"$on_host" >> "$logs/mac-suite.log" 2>&1 6>&- 7>&- 8>&- &
  suite_pid=$!
  wait "$suite_pid" || status=$?
  trap 'exit 143' TERM INT HUP
  case "$status" in
    75) echo "$suite: $at is busy with another validation."; return 1 ;;
    76) echo "$suite: $at cannot run it and runs nothing of this validation:"; sed -n '/^error: /p' "$logs/mac-suite.log" | tail -n 12; return 2 ;;
  esac
  mkdir -p "$logs/$at"
  if ! rsync -a --exclude '*.xcresult' -e "ssh $ssh_options" "$at:$there/logs/$run/" "$logs/$at/" 2>/dev/null; then
    echo "$suite: $at ran it and its results could not be copied back; it runs nothing more of this validation."
    return 2
  fi
  # Its own line, from this run's directory there, and a connection that ended as the suite
  # did: a pass the connection did not outlive is no result, and the suite is still to run.
  said="$(grep "^$suite=\(success\|failure\)$" "$logs/$at/suites.txt" 2>/dev/null || true)"
  if [ -z "$said" ] || { [ "$status" != 0 ] && ! grep -q '=failure$' <<<"$said"; }; then
    echo "$suite: $at ended it with no result (ssh exited $status); it runs nothing more of this validation."
    return 2
  fi
  results="$results$said"$'\n'
  took="$took$suite=$(((SECONDS - suite_started) / 60))"$'\n'
  ran_on="$ran_on$suite=$at"$'\n'
  echo "$suite: $(grep -q '=failure$' <<<"$said" && echo failure || echo success) in $(((SECONDS - suite_started) / 60)) min on $at"
}

# A slot, if one is free: its lock on descriptor 7 for the rest of the run, dropped by the
# kernel when this script dies. One with an orphan in its checkout is not taken. Then the lock
# a run of the script as it was holds whole, held here shared, on descriptor 8: such a run and
# a suite of this one here are never going at once, and neither is a suite one left behind it.
slot=""
slot_held=""
take_slot() {
  local n orphan held="" orphans=""
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
  if [ -z "$slot" ]; then
    [ -n "$held" ] || die "no checkout is free${orphans#;}. That stops its lane and deletes its simulators; then run again."
    slot_held="$held$orphans"
    slot_held="${slot_held#; }"
    return 0
  fi
  slot_dir="$cache/slots/$slot"
  echo "$branch $short, pid $$, since $(date '+%H:%M')" > "$slot_dir/holder"

  exec 8>> "$cache/lock"
  # Waited for as that run's siblings wait for it: asleep on the lock in one request for all
  # the time this run has left, since a request made again goes to the back of those waiting
  # and a queue of them would always get there first. In the background, so a signal to this
  # script is heard at once.
  if ! perl -MFcntl=:flock -e 'open(my $lock, ">&=", 8) or exit 2; exit(flock($lock, LOCK_SH | LOCK_NB) ? 0 : 1)'; then
    local left=$((LOCK_WAIT - waited)) asked=$SECONDS got=0 lock_pid
    local whose="a run of the script as it was before slots ($(cat "$cache/holder" 2>/dev/null || echo unknown))"
    [ "$left" -ge 1 ] || die "gave up after waiting $((LOCK_WAIT / 60)) min, the last of it for $whose. Nothing is pushed or posted."
    echo "Waiting for $whose and any waiting ahead; up to $((left / 60)) min more."
    perl -MFcntl=:flock -e 'open(my $lock, ">&=", 8) or exit 2; local $SIG{ALRM} = sub { exit 1 }; alarm shift; exit(flock($lock, LOCK_SH) ? 0 : 1)' "$left" 6>&- 7>&- &
    lock_pid=$!
    trap 'kill "$lock_pid" 2>/dev/null || true; exit 143' TERM INT HUP
    wait "$lock_pid" || got=$?
    trap 'exit 143' TERM INT HUP
    waited=$((waited + SECONDS - asked))
    [ "$got" = 0 ] || die "gave up after waiting $((LOCK_WAIT / 60)) min, the last of it for $whose. Nothing is pushed or posted."
  fi
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
  echo "Slot $slot: $short in $checkout"
  say_at="$waited"
}

# run_here <suite> — the suite in this run's checkout, its lock already on descriptor 6.
run_here() {
  local suite="$1" suite_status=0 began said
  echo "$branch $short, pid $$, slot $slot, since $(date '+%H:%M')" > "$cache/suite-$suite.holder"
  echo "$suite: began $(date '+%H:%M')"
  suite_started=$SECONDS
  # The descriptors closed: nothing the suite leaves running holds a lock. `exec`, so the pid
  # is the suite's own and a signal to this script ends it by that pid.
  # The trap before the suite it ends, so no signal finds a suite started and nothing to end
  # it. `|| true`: under `set -e` the wait's own status, the signal's, would end the trap there.
  suite_pid="" keeper=""
  trap '[ -z "$suite_pid" ] || kill "$suite_pid" 2>/dev/null || true; [ -z "$suite_pid" ] || wait "$suite_pid" 2>/dev/null || true; [ -z "$keeper" ] || kill "$keeper" 2>/dev/null || true; rm -f "$slot_dir/suite"; exit 143' TERM INT HUP
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
  # The old lock stays held, shared, for as long as the suite lives, by a keeper that
  # outlives this script: the script as it was knows nothing of slots, and the lock is the
  # one thing that keeps a run of it from starting beside a suite a killed run of this one
  # left going. The keeper has that lock's descriptor and no other, looks each second, and
  # goes when the suite has; it holds a pid to when it began, as the record does. A suite
  # this script saw end has no need of it.
  if [ -n "$began" ]; then
    (while [ "$(began_of "$suite_pid")" = "$began" ]; do sleep 1 8>&-; done) > /dev/null 2>&1 6>&- 7>&- &
    keeper=$!
  fi
  wait "$suite_pid" || suite_status=$?
  trap 'exit 143' TERM INT HUP
  [ -z "$keeper" ] || kill "$keeper" 2>/dev/null || true
  rm -f "$slot_dir/suite"
  # mac-suite.sh starts its suites.txt afresh each call. The suite has a line, or it failed:
  # a call that died early wrote none.
  said="$(grep "^$suite=" "$logs/suites.txt" 2>/dev/null || true)"
  grep -q "^$suite=\(success\|failure\)$" <<<"$said" || said="$suite=failure"
  [ "$suite_status" = 0 ] || grep -q '=failure$' <<<"$said" || die "scripts/mac-suite.sh exited $suite_status with $suite not red; see $logs/mac-suite.log."
  results="$results$said"$'\n'
  took="$took$suite=$(((SECONDS - suite_started) / 60))"$'\n'
  echo "$suite: $(grep -q '=failure$' <<<"$said" && echo failure || echo success) in $(((SECONDS - suite_started) / 60)) min"
}

if [ "${#chosen[@]}" -gt 0 ]; then
  mkdir -p "$cache/slots" "$logs_root"
  trap 'exit 143' TERM INT HUP
  # This run's logs, beside the four newest of the commit's earlier runs: by name, which is
  # when each began, so the run in hand is never one of those removed, and before the suites,
  # so a run a signal ends is counted by the next. Only what is named as a run is touched.
  mkdir -p "$commit_logs"
  ls -1 "$commit_logs" | { grep -E '^[0-9]{8}T[0-9]{6}Z-[0-9]+$' || true; } | sort -t- -k1,1r -k2,2nr | tail -n "+$KEEP_RUNS" | while IFS= read -r old; do
    # One a run is still writing, in another slot, is kept however many have begun since.
    [ ! -s "$commit_logs/$old/running" ] || ! kill -0 "$(cat "$commit_logs/$old/running")" 2>/dev/null || continue
    rm -rf "${commit_logs:?}/$old"
  done
  logs="$commit_logs/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  mkdir "$logs" || die "could not make $logs."
  echo "$$" > "$logs/running"
  echo "Running ${chosen[*]} (lane $lane) at $short${hosts:+, here or on $hosts}; logs in $logs"
  started=$SECONDS

  remaining=" ${chosen[*]} "
  hosts_at=0   # when a host found busy is asked again
  while [ "$remaining" != " " ]; do
    suite=""
    # Another Mac first, when any is named: the first that is free takes the first suite still
    # to run that may leave this one.
    if [ -n "$hosts" ] && [ "$SECONDS" -ge "$hosts_at" ]; then
      for candidate in $remaining; do
        [ "$candidate" != topo_ui ] || continue
        for at in $hosts; do
          outcome=0
          run_on "$at" "$candidate" || outcome=$?
          case "$outcome" in
            0) suite="$candidate"; break 2 ;;
            1) hosts_at=$((SECONDS + 60)) ;;
            *) hosts=" $hosts "; hosts="${hosts/ $at / }"; hosts="$(echo $hosts)" ;;
          esac
        done
        break
      done
    fi
    # Then here: the first suite still to run that no sibling is running, its lock on
    # descriptor 6. A suite a killed script left going holds its name as a lock would.
    held=""
    if [ -z "$suite" ]; then
      [ -n "$slot" ] || take_slot
      [ -n "$slot" ] || held="; $slot_held"
    fi
    if [ -z "$suite" ] && [ -n "$slot" ]; then
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
            run_here "$suite"
            exec 6>&-
            break
          fi
          held="$held; $candidate: still running without its script, pid $orphan, end it with \`kill $orphan\`"
        fi
        exec 6>&-
      done
    fi
    if [ -z "$suite" ]; then
      if [ -n "$slot" ]; then waiting "a suite" "${held#; }"; else waiting "a checkout" "${held#; }"; fi
      continue
    fi
    say_at="$waited"
    remaining="${remaining/ $suite / }"
  done
  trap - TERM INT HUP
  exec 6>&- 7>&- 8>&-
  minutes=$(((SECONDS - started) / 60))
  # Every suite's result in the one file, as each call left its own.
  printf '%s' "$results" > "$logs/suites.txt"
  rm -f "$logs/running"
  # The ten newest commits' logs are kept, and those of any commit a run is still writing: a
  # sibling's run, begun before ten other commits went through the other slot.
  ls -1t "$logs_root" | tail -n "+$((KEEP_LOGS + 1))" | while IFS= read -r old; do
    case "$old" in *[!0-9a-f]* | "") continue ;; esac
    for mark in "$logs_root/$old"/*/running; do
      [ ! -s "$mark" ] || ! kill -0 "$(cat "$mark")" 2>/dev/null || continue 2
    done
    rm -rf "${logs_root:?}/$old"
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
  on="$(sed -n "s/^$suite=//p" <<<"$ran_on")"
  post "local/$suite" "$state" "$suite $said, $lane lane, $(sed -n "s/^$suite=//p" <<<"$took") min on ${on:-$host};"
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
