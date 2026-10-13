#!/usr/bin/env bash
# Holds scripts/validate-and-push.sh in scratch repositories with a bare `origin`, the real
# select scripts and workflow, a fake `gh` that logs every call, and a fake scripts/mac-suite.sh
# committed in the scratch repository, which records the commit, the checkout and the files it
# was run in, once a suite, and answers as the case says. No suite runs, nothing leaves the
# machine.
#
# What it holds: the suites and the lane are the ones the commit's paths select; the suite runs
# in the validation worktree at exactly the commit, without the worktree's uncommitted or
# untracked files; a green run pushes that commit and then posts `success` for each suite to that
# commit and no other, with `local/real_ear` only beside a green `topo_ui` on the full lane; a
# red suite pushes nothing and posts nothing, unless origin's branch was already at the commit,
# when it posts what happened; a suite that wrote no result is a failure; a push origin refuses
# and a status GitHub refuses post nothing more and exit 2; --no-push refuses a commit origin's
# branch is not at before any suite runs; a suite with two results is red; a description keeps
# the logs' path; a head run again keeps the earlier run's logs, five runs a commit; and the
# `test` job is re-run, by job, only when the commit's newest run has concluded with it red.
#
# And of two runs at once: each is in a checkout of its own and a third waits for one; a run
# whose first suite a sibling is running goes on with its next; one suite of a name runs at a
# time; a wait that runs out exits 2 with nothing pushed or posted, the suites already green
# included; a run of the script as it was, holding its one lock, holds a run off; a suite an
# earlier run left going keeps its checkout and its name, and is named with its pid; a process
# a suite leaves behind holds nothing; and a signal in a run's second suite ends that suite.
#
# And of another Mac, behind a fake `ssh` that runs what it is given in a scratch home: none is
# asked anything unless named; one named runs `topo_unit` and `others`, at the commit, and
# never `topo_ui` whole: its quiet part runs there and its microphone's part here, last, the
# two one status that is a success when both are, and whole here when the Mac is busy or
# loses the part; its name is in the status; a Mac that is not reached, says it cannot run
# the suite, loses it partway or passes it as the connection drops runs nothing more and the
# suite runs here; a busy one is left alone and the suite runs here; a suite red there is
# red; and a signal ends the suite there, or comes before it and starts none.
#
# And of the line for a slot: runs that wait have it in the order they began, whichever asks
# oftener or reached the line first; a run's ticket taken from under it is back under its own name; a ticket of a pid
# that is gone or another's, or one not whole, is removed and holds nobody, and a file that is
# no ticket is left; a run signalled in the line leaves no ticket; a run trying a busy Mac
# keeps its place, and is out of the line while its suite runs there. And of --hold: the
# command runs with the slot held and its own status, in any tree, a validation waiting
# meanwhile; nothing is pushed or posted; what it leaves behind holds nothing; a signal ends
# it; and one a SIGKILL left running is an orphan the next run starts nothing beside.
#
#   scripts/tests/validate-and-push-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../.."
work="$(mktemp -d -t validate-and-push-test)"
trap 'rm -rf "$work"' EXIT

# What a session running this may have set for its own run is not this test's: every case
# names what it means. A wait no case bounds is a minute, so a lock left held fails a case
# and does not hang the test.
unset TOPO_VALIDATE_SLOTS TOPO_VALIDATE_HOSTS TOPO_VALIDATE_REPO TOPO_VALIDATE_CACHE TOPO_VALIDATE_LOGS POST_RETRY \
  FAKE_DROP FAKE_CHECK_SLOW FAKE_SUITES FAKE_HOLD FAKE_HOLD_SUITE FAKE_LEAVE FAKE_CHECK FAKE_LOST_IN FAKE_UNREACHABLE FAKE_POST FAKE_RUN FAKE_TEST_JOB
export LOCK_WAIT=60 LOCK_POLL=1
# A Mac with a way into its login session is not asked for it by a fake suite.
export TOPO_VALIDATE_SESSION_RUN=

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }
g() { git -c user.name=t -c user.email=t@t "$@"; }

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
case "$*" in
  "api --silent -X POST repos/samdu/topo/statuses/"*)
    [ "${FAKE_POST:-ok}" = ok ] || exit 1
    # Held at the post for as long as FAKE_POST_HOLD is there, and saying so once.
    if [ -n "${FAKE_POST_HOLD-}" ]; then
      : > "$FAKE_POST_HOLD.reached"
      while [ -e "$FAKE_POST_HOLD" ]; do perl -e "select(undef,undef,undef,0.1)"; done
    fi
    # What origin's branch held as the status was posted: GitHub refuses one for a commit it lacks.
    git ls-remote "$FAKE_ORIGIN" refs/heads/topic | cut -f1 >> "$GH_CALLS.origin"
    ;;
  "api repos/samdu/topo/actions/workflows/pr-validate.yaml/runs?head_sha="*) printf '%s\n' "${FAKE_RUN-}" ;;
  "api repos/samdu/topo/actions/runs/99/jobs?"*) printf '%s\n' "${FAKE_TEST_JOB-}" ;;
  "run rerun --repo samdu/topo --job 4242") ;;
  *) echo "unexpected gh call: $*" >&2; exit 64 ;;
esac
GH
chmod +x "$work/bin/gh"
# ssh [-o option]... <host> <command> — the command, in that host's scratch home.
cat > "$work/bin/ssh" <<'SSH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
host="$1"; shift
echo "$host $*" >> "$SSH_CALLS"
[ "${FAKE_UNREACHABLE-}" != "$host" ] || exit 255
mkdir -p "$FAKE_HOSTS/$host"
cd "$FAKE_HOSTS/$host" || exit 255
# A connection that ends badly once the suite there has ended: what ran, and then ssh's own failure.
case "${FAKE_DROP-}:$*" in 1:"bash -s"*) HOME="$FAKE_HOSTS/$host" bash -c "$*"; exit 255 ;; esac
HOME="$FAKE_HOSTS/$host" exec bash -c "$*"
SSH
chmod +x "$work/bin/ssh"

# The fake suite: records where it ran, then writes FAKE_SUITES' lines (`topo_unit=failure …`;
# a suite it does not name succeeded) unless FAKE_SUITES is `died`.
fake_suite='#!/usr/bin/env bash
results=""; suites=(); check=no
while [ $# -gt 0 ]; do
  case "$1" in --check) check=yes; shift ;; --lane) lane="$2"; shift 2 ;; --results) results="$2"; shift 2 ;; --cache) shift 2 ;; *) suites+=("$1"); shift ;; esac
done
if [ "$check" = yes ]; then
  echo "check ${suites[*]}" >> "$FAKE_RECORD.checks"
  [ -z "${FAKE_CHECK_SLOW-}" ] || perl -e "select(undef,undef,undef,3)"
  [ -z "${FAKE_CHECK-}" ] || { echo "error: $FAKE_CHECK" >&2; exit 1; }
  exit 0
fi
echo $$ > "$results/mac-suite.pids"
: > "$results/suites.txt"   # as the suite itself starts its results afresh, each call
# A Mac that loses the suite partway: no result, in a checkout under the path named.
case "$(pwd -P)" in *"${FAKE_LOST_IN:-no such path}"*) exit 1 ;; esac
before="$(sed -n "s/^suites=//p" "$FAKE_RECORD" 2>/dev/null)"
{ echo "head=$(git rev-parse HEAD)"; echo "gitconfig=${GIT_CONFIG_GLOBAL-}"; echo "lane=$lane"; echo "suites=$before${before:+ }${suites[*]}"; echo "checkout=$(pwd -P)"; echo "files=$(ls | tr "\n" " ")"; echo "status=$(git status --porcelain | tr "\n" " ")"; } > "$FAKE_RECORD.new"
mv -f "$FAKE_RECORD.new" "$FAKE_RECORD"
[ "${FAKE_SUITES-}" != died ] || exit 1
# Left running after the suite, with whatever descriptors the suite was given.
[ -z "${FAKE_LEAVE-}" ] || { nohup perl -e "sleep 60" > /dev/null 2>&1 & echo $! > "$FAKE_LEAVE"; }
# Held in every suite, or in the one FAKE_HOLD_SUITE names, for as long as the marker has its
# pid, two minutes at most: a case that failed before its `release` does not hold the test.
if [ "${FAKE_SUITES-}" = held ] && case "${FAKE_HOLD_SUITE-}" in "" | "${suites[0]}") true ;; *) false ;; esac; then
  echo $$ > "$FAKE_HOLD"
  held=0
  while [ -s "$FAKE_HOLD" ] && [ "$held" -lt 1200 ]; do perl -e "select(undef,undef,undef,0.1)"; held=$((held + 1)); done
fi
if [ "${FAKE_SUITES-}" = twice ]; then
  for suite in "${suites[@]}"; do echo "$suite=failure" >> "$results/suites.txt"; echo "$suite=success" >> "$results/suites.txt"; done
  exit 1
fi
status=0
for suite in "${suites[@]}"; do
  case " ${FAKE_SUITES-} " in *" $suite=failure "*) echo "$suite=failure" >> "$results/suites.txt"; status=1 ;; *) echo "$suite=success" >> "$results/suites.txt" ;; esac
done
exit "$status"
'

# scratch <name> <changed path>... — origin with main, and a worktree on branch `topic` whose one
# commit adds the paths. Sets $repo, $sha.
scratch() {
  local name="$1" path; shift
  repo="$work/$name/repo"
  mkdir -p "$repo/scripts" "$repo/.github/workflows"
  cp "$root/scripts/validate-and-push.sh" "$root/scripts/ci-select-suites.sh" "$root/scripts/ci-select-lane.sh" "$repo/scripts/"
  cp "$root/.github/workflows/pr-validate.yaml" "$repo/.github/workflows/"
  printf '%s' "$fake_suite" > "$repo/scripts/mac-suite.sh"
  chmod +x "$repo/scripts/mac-suite.sh"
  git -C "$repo" init -q -b main
  git -C "$repo" config core.hooksPath /dev/null
  g -C "$repo" add -A && g -C "$repo" commit -qm base
  git init -q --bare "$work/$name/origin.git"
  git -C "$repo" remote add origin "$work/$name/origin.git"
  git -C "$repo" push -q origin main
  git -C "$repo" checkout -q -b topic
  for path in "$@"; do mkdir -p "$repo/$(dirname "$path")"; echo x > "$repo/$path"; done
  g -C "$repo" add -A && g -C "$repo" commit -qm change
  sha="$(git -C "$repo" rev-parse HEAD)"
  : > "$work/$name/gh.calls"
  : > "$work/$name/gh.calls.origin"
  : > "$work/$name/ssh.calls"
  export GH_CALLS="$work/$name/gh.calls" FAKE_ORIGIN="$work/$name/origin.git" FAKE_RECORD="$work/$name/record" \
    TOPO_VALIDATE_CACHE="$work/$name/cache" TOPO_VALIDATE_LOGS="$work/$name/logs" \
    SSH_CALLS="$work/$name/ssh.calls" FAKE_HOSTS="$work/$name/hosts"
}
# sibling <name> <branch> <changed path>... — a second worktree of $repo, on a branch of its own
# from main with one commit adding the paths: another session's, on the same Mac. Sets $other.
sibling() {
  local name="$1" branch="$2" path; shift 2
  other="$work/$name/$branch"
  git -C "$repo" worktree add -q -b "$branch" "$other" main
  for path in "$@"; do mkdir -p "$other/$(dirname "$path")"; echo x > "$other/$path"; done
  g -C "$other" add -A && g -C "$other" commit -qm change
}
# begin <directory> <record> <marker> [VAR=value...] — a run of the script there in the
# background, held in its suite (FAKE_HOLD_SUITE, or every one) until `release`. Its pid in $run.
begin() {
  local at="$1" record="$2" marker="$3"; shift 3
  : > "$marker"
  (cd "$at" && exec env PATH="$work/bin:$PATH" FAKE_SUITES=held FAKE_RECORD="$record" FAKE_HOLD="$marker" "$@" scripts/validate-and-push.sh > "$record.out" 2>&1) &
  run=$!
  for _ in $(seq 300); do [ -s "$marker" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
  [ -s "$marker" ] || fail "a run in $at never reached the suite it was to be held in: $(cat "$record.out")"
}
release() { : > "$1"; }
# validate [args] — runs the script in $repo; its output in $out, its exit in $status, and what
# its suites recorded in place of any earlier run's.
validate() {
  rm -f "$FAKE_RECORD"
  out="$(cd "$repo" && PATH="$work/bin:$PATH" scripts/validate-and-push.sh "$@" 2>&1)" && status=0 || status=$?
}
origin_head() { git -C "$repo" ls-remote origin refs/heads/topic | cut -f1; }
posted() { sed -n "s|^api --silent -X POST repos/samdu/topo/statuses/$sha -f context=\([^ ]*\) -f state=\([^ ]*\) .*|\1=\2|p" "$GH_CALLS" | tr '\n' ' '; }
posts_elsewhere() { grep 'statuses/' "$GH_CALLS" | grep -vc "statuses/$sha "; }
recorded() { sed -n "s/^$1=//p" "$FAKE_RECORD" 2>/dev/null; }
is() {  # is <case> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', wanted '$3': $out"; fi
}

# A documentation change: no suite, pushed, no status.
scratch docs docs/design.md
validate
is "docs: exits 0" "$status" 0
is "docs: pushed" "$(origin_head)" "$sha"
is "docs: no suite ran" "$(recorded head)" ""
is "docs: no gh call but the look for a red test job" "$(grep -vc 'actions/workflows' "$GH_CALLS")" 0

# An app change off the voice path: every suite, the fast lane, at the commit and nothing else.
scratch app Apps/Client/SettingsView.swift
echo dirty > "$repo/Apps/Client/SettingsView.swift"
echo stray > "$repo/Untracked.swift"
# Selectors edited and not committed, which would choose no suite and the fast lane for anything.
printf '#!/usr/bin/env bash\nprintf "topo_unit=false\\ntopo_ui=false\\nothers=false\\nreason=edited\\n"\n' > "$repo/scripts/ci-select-suites.sh"
printf '#!/usr/bin/env bash\necho lane=full\n' > "$repo/scripts/ci-select-lane.sh"
validate
is "app: exits 0" "$status" 0
is "app: the suite ran at the commit" "$(recorded head)" "$sha"
is "app: every suite, in order" "$(recorded suites)" "topo_unit topo_ui others"
is "app: the fast lane" "$(recorded lane)" fast
is "app: the validation worktree is clean" "$(recorded status)" ""
case " $(recorded files)" in *" Untracked.swift "*) fail "app: the untracked file reached the validation worktree" ;; *) ok "app: no untracked file from the engineer's worktree" ;; esac
is "app: the engineer's uncommitted change is left alone" "$(cat "$repo/Apps/Client/SettingsView.swift")" dirty
grep -q 'uncommitted changes or untracked files' <<<"$out" && ok "app: the uncommitted change is said" || fail "app: no warning: $out"
is "app: pushed the commit" "$(origin_head)" "$sha"
is "app: one success per suite, on the commit, and no real ear" "$(posted)" "local/topo_unit=success local/topo_ui=success local/others=success "
is "app: no status on another commit" "$(posts_elsewhere)" 0
is "app: no other Mac is asked anything" "$(wc -l < "$SSH_CALLS" | tr -d ' ')" 0
is "app: origin's branch was at the commit as each status was posted" "$(sort -u "$GH_CALLS.origin")" "$sha"
[ -d "$TOPO_VALIDATE_LOGS/$sha" ] && ok "app: the logs are kept under the commit" || fail "app: no $TOPO_VALIDATE_LOGS/$sha"
# A second commit reuses the worktree, at the new commit.
git -C "$repo" checkout -q -- Apps/Client/SettingsView.swift
echo y > "$repo/Apps/Client/Other.swift"; g -C "$repo" add Apps; g -C "$repo" commit -qm more
sha="$(git -C "$repo" rev-parse HEAD)"
validate
is "app, second commit: the suite ran at the new commit" "$(recorded head)" "$sha"
is "app, second commit: pushed" "$(origin_head)" "$sha"

# The voice path: the full lane, and the real ear's status beside a green topo_ui.
scratch voice Apps/Client/Ear.swift
validate
is "voice: the full lane" "$(recorded lane)" full
is "voice: the real ear is posted" "$(posted)" "local/topo_unit=success local/topo_ui=success local/real_ear=success local/others=success "
scratch voice-red Apps/Client/Ear.swift
git -C "$repo" push -q origin topic
FAKE_SUITES="topo_ui=failure" validate
is "voice, topo_ui red on a pushed head: exits 1" "$status" 1
is "voice, topo_ui red: failure for it, no real ear" "$(posted)" "local/topo_unit=success local/topo_ui=failure local/others=success "

# TopoLink: `others` alone.
scratch link Packages/TopoLink/Sources/TopoLink/Probe.swift
validate
is "link: others alone" "$(recorded suites)" others
is "link: one status" "$(posted)" "local/others=success "
# The harness alone: the scripts' tests, one status, and no other suite.
scratch harness scripts/janitor.py scripts/tests/janitor_test.py
validate
is "harness: exits 0" "$status" 0
is "harness: scripts alone" "$(recorded suites)" scripts
is "harness: one status" "$(posted)" "local/scripts=success "
is "harness: pushed" "$(origin_head)" "$sha"
scratch harness-red scripts/janitor.py
FAKE_SUITES="scripts=failure" validate
is "harness, red: exits 1" "$status" 1
is "harness, red: nothing pushed" "$(origin_head)" ""
# Beside a change `others` covers, `others` runs the scripts' tests: one suite, one status.
scratch harness-link scripts/janitor.py Packages/TopoLink/Package.swift
validate
is "harness beside TopoLink: others alone" "$(recorded suites)" others
is "harness beside TopoLink: one status" "$(posted)" "local/others=success "
validate --suites all
is "--suites all: the three that cover the product" "$(recorded suites)" "topo_unit topo_ui others"
validate --suites scripts
is "--suites scripts: the scripts' tests alone" "$(recorded suites)" scripts
# --suites and --lane override the choice.
scratch override Packages/TopoLink/Sources/TopoLink/Probe.swift
validate --suites "topo_ui others" --lane full
is "override: the suites asked for" "$(recorded suites)" "topo_ui others"
is "override: the lane asked for" "$(recorded lane)" full
validate --suites bogus
is "override: a suite that does not exist exits 2" "$status" 2

# A red suite on a commit origin does not have: nothing pushed, nothing posted.
scratch red Apps/Client/SettingsView.swift
FAKE_SUITES="others=failure" validate
is "red: exits 1" "$status" 1
is "red: nothing pushed" "$(origin_head)" ""
is "red: nothing posted" "$(grep -c 'statuses/' "$GH_CALLS")" 0
grep -q 'RED at .*: others' <<<"$out" && ok "red: names the suite" || fail "red: $out"
# A suite that died without a result is every suite red.
scratch died Apps/Client/SettingsView.swift
git -C "$repo" push -q origin topic
FAKE_SUITES=died validate
is "died: exits 1" "$status" 1
is "died: every suite failed" "$(posted)" "local/topo_unit=failure local/topo_ui=failure local/others=failure "

# --no-push: only for a commit origin's branch is at, decided before any suite runs.
scratch nopush Apps/Client/SettingsView.swift
validate --no-push
is "--no-push, origin behind: exits 2" "$status" 2
is "--no-push, origin behind: no suite ran" "$(recorded head)" ""
git -C "$repo" push -q origin topic
validate --no-push
is "--no-push, origin at the commit: exits 0" "$status" 0
is "--no-push, origin at the commit: posted" "$(posted)" "local/topo_unit=success local/topo_ui=success local/others=success "

# A push origin refuses (its branch moved on) posts nothing.
scratch refused Apps/Client/SettingsView.swift
git clone -q "$work/refused/origin.git" "$work/refused/other"
git -C "$work/refused/other" config core.hooksPath /dev/null
g -C "$work/refused/other" checkout -q -b topic && echo z > "$work/refused/other/z" && g -C "$work/refused/other" add -A \
  && g -C "$work/refused/other" commit -qm theirs && git -C "$work/refused/other" push -q origin topic
validate
is "refused push: exits 2" "$status" 2
is "refused push: nothing posted" "$(grep -c 'statuses/' "$GH_CALLS")" 0

# A status GitHub does not take: exit 2, and it says how to post again.
scratch nopost Packages/TopoLink/Package.swift
FAKE_POST=fail POST_RETRY=0 validate
is "refused status: exits 2" "$status" 2
grep -q 'run again with --no-push' <<<"$out" && ok "refused status: says how to post again" || fail "refused status: $out"

# The test job is re-run by job, and only when the newest run has concluded with it red.
scratch rerun Packages/TopoLink/Package.swift
FAKE_RUN="99 completed" FAKE_TEST_JOB=4242 validate
is "rerun: exits 0" "$status" 0
is "rerun: the test job, by job" "$(grep -c '^run rerun --repo samdu/topo --job 4242$' "$GH_CALLS")" 1
is "rerun: nothing else is re-run" "$(grep -c '^run rerun' "$GH_CALLS")" 1
for case in "99 in_progress|4242" "99 completed|" "|"; do
  scratch norerun Packages/TopoLink/Package.swift
  FAKE_RUN="${case%%|*}" FAKE_TEST_JOB="${case#*|}" validate
  is "no rerun for run '${case%%|*}', red test job '${case#*|}'" "$(grep -c '^run rerun' "$GH_CALLS")" 0
  rm -rf "$work/norerun"
done
# A red suite re-runs nothing: the test job would only go red again.
scratch redrerun Packages/TopoLink/Package.swift
git -C "$repo" push -q origin topic
FAKE_SUITES="others=failure" FAKE_RUN="99 completed" FAKE_TEST_JOB=4242 validate
is "red suite: no rerun" "$(grep -c '^run rerun' "$GH_CALLS")" 0

# A head run again after a red: each run has its own logs under the commit, and the red run's
# are still there. Past five runs of a commit the oldest go.
runs() { ls -1 "$TOPO_VALIDATE_LOGS/$sha" | grep -cE '^[0-9]{8}T[0-9]{6}Z-[0-9]+$'; }
is "the red run: one run's logs under the commit" "$(runs)" 1
red_run="$(ls -1 "$TOPO_VALIDATE_LOGS/$sha" | grep -E '^[0-9]{8}T[0-9]{6}Z-[0-9]+$')"
validate
is "run again: exits 0" "$status" 0
is "run again: two runs' logs under the commit" "$(runs)" 2
is "run again: the red run's result is kept" "$(cat "$TOPO_VALIDATE_LOGS/$sha/$red_run/suites.txt" 2>/dev/null)" "others=failure"
[ -f "$TOPO_VALIDATE_LOGS/$sha/$red_run/mac-suite.log" ] && ok "run again: the red run's log is kept" || fail "run again: the red run's mac-suite.log is gone"
# What is not a run is left where it is, and earlier runs made to look newer than the one in
# hand do not have it removed in their place.
for _ in 1 2 3; do validate; done
echo kept > "$TOPO_VALIDATE_LOGS/$sha/notes.txt"
touch -t 203001010000 "$TOPO_VALIDATE_LOGS/$sha"/*Z-*
FAKE_SUITES="others=failure" validate
is "a sixth run, red: exits 1" "$status" 1
case "$out" in *"No such file"*) fail "a sixth run, red: its own logs were removed: $out" ;; *) ok "a sixth run, red: its own logs are there to read" ;; esac
is "a sixth run: five kept" "$(runs)" 5
[ ! -e "$TOPO_VALIDATE_LOGS/$sha/$red_run" ] && ok "a sixth run: the oldest is gone" || fail "a sixth run: the oldest run is still there"
is "a sixth run: a file that is not a run is left" "$(cat "$TOPO_VALIDATE_LOGS/$sha/notes.txt" 2>/dev/null)" kept

# Runs a signal ended are counted like any other: seven of them leave five.
scratch signalled Packages/TopoLink/Package.swift
git -C "$repo" push -q origin topic
export FAKE_HOLD="$work/signalled/hold" LOCK_POLL=1
for _ in 1 2 3 4 5 6 7; do
  : > "$FAKE_HOLD"
  (cd "$repo" && PATH="$work/bin:$PATH" FAKE_SUITES=held exec scripts/validate-and-push.sh --no-push) > "$work/signalled/out" 2>&1 &
  held=$!
  for _ in $(seq 300); do [ -s "$FAKE_HOLD" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
  [ -s "$FAKE_HOLD" ] || fail "signalled runs: a run's suite never started"
  kill -TERM "$held"; wait "$held" 2>/dev/null
done
unset FAKE_HOLD
is "seven runs ended by a signal: five kept" "$(runs)" 5
own="$(sed -n 's/^RED at .* Logs: \(.*\)\/mac-suite.log$/\1/p' <<<"$out")"
is "a sixth run: the logs it names hold its own result" "$(cat "$own/suites.txt" 2>/dev/null)" "others=failure"

# A run of the script as it was holds its one lock for the whole of it: a run here waits on
# that, then gives up, with no suite run.
scratch locked Apps/Client/SettingsView.swift
mkdir -p "$TOPO_VALIDATE_CACHE"
lockf -k "$TOPO_VALIDATE_CACHE/lock" sh -c "echo \$\$ > '$work/locked/held'; exec sleep 60" &
holder=$!
for _ in $(seq 100); do [ -s "$work/locked/held" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
[ -s "$work/locked/held" ] || fail "locked: the holder never took the lock"
LOCK_WAIT=1 validate
is "locked: exits 2" "$status" 2
is "locked: no suite ran" "$(recorded head)" ""
is "locked: nothing pushed" "$(origin_head)" ""
kill "$(cat "$work/locked/held")" "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
validate
is "the lock free again: exits 0" "$status" 0
TOPO_VALIDATE_SLOTS=0 validate
is "no slots at all: exits 2" "$status" 2

# One checkout unless more are asked for: a second run waits for the first whatever its
# suites are, so one suite's simulators are booted on this Mac at a time.
scratch single Apps/Client/SettingsView.swift
sibling single theirs Packages/TopoLink/Package.swift
begin "$repo" "$work/single/first" "$work/single/first.hold" FAKE_HOLD_SUITE=topo_unit
first=$run
out="$(cd "$other" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/single/second" LOCK_WAIT=2 scripts/validate-and-push.sh 2>&1)" && status=0 || status=$?
is "one checkout by default: a second run exits 2" "$status" 2
case "$out" in *"Waiting for a checkout"*) ok "one checkout by default: it waited for the checkout" ;; *) fail "one checkout by default: $out" ;; esac
[ ! -e "$work/single/second" ] && ok "one checkout by default: the second run started no suite" || fail "one checkout by default: a second suite ran beside the first"
[ ! -e "$TOPO_VALIDATE_CACHE/slots/2" ] && ok "one checkout by default: no second checkout" || fail "one checkout by default: a second slot was made"
release "$work/single/first.hold"
wait "$first"; is "one checkout by default: the first run exits 0" "$?" 0
out="$(cd "$other" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/single/second" scripts/validate-and-push.sh 2>&1)" && status=0 || status=$?
is "one checkout by default: the second run, the first done, exits 0" "$status" 0

# Two checkouts from here on, as an afternoon with room would ask for.
export TOPO_VALIDATE_SLOTS=2
# Two runs at once. The first is held in topo_unit, in the first checkout. The second, another
# branch's whose paths need `others` alone, runs it in a checkout of its own and is pushed and
# posted while the first is still in its suite.
scratch overlap Apps/Client/SettingsView.swift
sibling overlap theirs Packages/TopoLink/Package.swift
begin "$repo" "$work/overlap/first" "$work/overlap/first.hold" FAKE_HOLD_SUITE=topo_unit
first=$run
out="$(cd "$other" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/overlap/second" LOCK_WAIT=5 scripts/validate-and-push.sh 2>&1)" && status=0 || status=$?
is "overlap: the second run exits 0 with the first in its suite" "$status" 0
lockf -s -t 0 "$TOPO_VALIDATE_CACHE/lock" true && fail "overlap: the lock of the script as it was is free while a suite runs" || ok "overlap: a run of the script as it was is held off while a suite runs"
kill -0 "$(cat "$work/overlap/first.hold")" 2>/dev/null && ok "overlap: the first run's suite is still going" || fail "overlap: the first run's suite ended"
is "overlap: the first run is in the first checkout" "$(sed -n 's/^checkout=//p' "$work/overlap/first")" "$(cd "$TOPO_VALIDATE_CACHE/slots/1/checkout" && pwd -P)"
is "overlap: the second in a checkout of its own" "$(sed -n 's/^checkout=//p' "$work/overlap/second")" "$(cd "$TOPO_VALIDATE_CACHE/slots/2/checkout" 2>/dev/null && pwd -P)"
is "overlap: the second ran its commit" "$(sed -n 's/^head=//p' "$work/overlap/second")" "$(git -C "$other" rev-parse HEAD)"
is "overlap: the second is pushed" "$(git -C "$repo" ls-remote origin refs/heads/theirs | cut -f1)" "$(git -C "$other" rev-parse HEAD)"
is "overlap: the second is posted" "$(grep -c "statuses/$(git -C "$other" rev-parse HEAD) -f context=local/others -f state=success" "$GH_CALLS")" 1
# A second run of `others` while one is going waits for it, and a third run for a checkout.
begin "$other" "$work/overlap/second" "$work/overlap/second.hold" FAKE_HOLD_SUITE=others
second=$run
sibling overlap third Packages/TopoLink/Package.swift
out="$(cd "$other" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/overlap/third.record" LOCK_WAIT=2 scripts/validate-and-push.sh 2>&1)" && status=0 || status=$?
is "two checkouts held: a third run exits 2" "$status" 2
case "$out" in *"Waiting for a checkout (slot 1: topic "*"; slot 2: theirs "*) ok "two checkouts held: it says who holds them" ;; *) fail "two checkouts held: $out" ;; esac
[ ! -e "$work/overlap/third.record" ] && ok "two checkouts held: no suite of the third ran" || fail "two checkouts held: a suite ran"
out="$(cd "$other" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/overlap/third.record" LOCK_WAIT=2 TOPO_VALIDATE_SLOTS=3 scripts/validate-and-push.sh 2>&1)" && status=0 || status=$?
is "others held by a sibling: a run that needs it exits 2" "$status" 2
case "$out" in *"Waiting for a suite (others: theirs "*) ok "others held by a sibling: it says who holds it" ;; *) fail "others held by a sibling: $out" ;; esac
[ ! -e "$work/overlap/third.record" ] && ok "others held by a sibling: it did not run beside it" || fail "others held by a sibling: a second ran beside it"
is "others held by a sibling: nothing pushed" "$(git -C "$repo" ls-remote origin refs/heads/third | cut -f1)" ""
# The first run goes on past the suite its sibling holds, and comes back to it.
release "$work/overlap/first.hold"
for _ in $(seq 100); do grep -q '^suites=topo_unit topo_ui$' "$work/overlap/first" && break; perl -e 'select(undef,undef,undef,0.1)'; done
is "others held by a sibling: the first run has run its other two" "$(sed -n 's/^suites=//p' "$work/overlap/first")" "topo_unit topo_ui"
kill -0 "$first" 2>/dev/null && ok "others held by a sibling: the first run waits for it" || fail "others held by a sibling: the first run ended: $(cat "$work/overlap/first.out")"
# Between two of its suites the first run still has its checkout, and a signal still ends it.
out="$(cd "$other" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/overlap/third.record" LOCK_WAIT=2 scripts/validate-and-push.sh 2>&1)" && status=0 || status=$?
is "a run waiting between its suites: a third run exits 2" "$status" 2
case "$out" in *"Waiting for a checkout (slot 1: topic "*) ok "a run waiting between its suites: it still holds its checkout" ;; *) fail "a run waiting between its suites: $out" ;; esac
(cd "$other" && exec env PATH="$work/bin:$PATH" FAKE_RECORD="$work/overlap/third.record" TOPO_VALIDATE_SLOTS=3 scripts/validate-and-push.sh > "$work/overlap/third.out" 2>&1) &
third=$!
for _ in $(seq 100); do grep -q 'Waiting for a suite' "$work/overlap/third.out" && break; perl -e 'select(undef,undef,undef,0.1)'; done
kill -TERM "$third"; wait "$third"
is "a signal to a run waiting for a suite: exits 143" "$?" 143
release "$work/overlap/second.hold"
wait "$second"; is "the second run, released: exits 0" "$?" 0
wait "$first"; is "the first run, its sibling done: exits 0" "$?" 0
is "the first run: every suite, others last" "$(sed -n 's/^suites=//p' "$work/overlap/first")" "topo_unit topo_ui others"
is "the first run: pushed" "$(origin_head)" "$sha"
is "the first run: one success per suite" "$(posted)" "local/topo_unit=success local/topo_ui=success local/others=success "
is "the first run: its logs name every suite" "$(cat "$TOPO_VALIDATE_LOGS/$sha"/*/suites.txt | tr '\n' ' ')" "topo_unit=success topo_ui=success others=success "

# A process a suite leaves running holds no lock: the next run takes the same checkout and
# the same suite at once.
scratch left Packages/TopoLink/Package.swift
FAKE_LEAVE="$work/left/pid" validate
is "a process left behind: its run exits 0" "$status" 0
left="$(cat "$work/left/pid" 2>/dev/null)"
kill -0 "$left" 2>/dev/null && ok "a process left behind: it is still running" || fail "a process left behind: it is not running"
lockf -s -t 0 "$TOPO_VALIDATE_CACHE/lock" true && ok "a process left behind: the lock of the script as it was is free" || fail "a process left behind: it holds the lock of the script as it was"
echo y > "$repo/more"; g -C "$repo" add -A; g -C "$repo" commit -qm more; sha="$(git -C "$repo" rev-parse HEAD)"
LOCK_WAIT=0 validate
is "a process left behind: the next run waits for nothing" "$status" 0
is "a process left behind: the next run has the first checkout" "$(recorded checkout)" "$(cd "$TOPO_VALIDATE_CACHE/slots/1/checkout" && pwd -P)"
kill "$left" 2>/dev/null

# A signal in a run's second suite ends that suite and the run, and leaves nothing on record.
scratch second-suite Apps/Client/SettingsView.swift
begin "$repo" "$work/second-suite/record" "$work/second-suite/hold" FAKE_HOLD_SUITE=topo_ui
held="$(cat "$work/second-suite/hold")"
kill -TERM "$run"; wait "$run"
is "a signal in the second suite: exits 143" "$?" 143
kill -0 "$held" 2>/dev/null && fail "a signal in the second suite: the suite is still running" || ok "a signal in the second suite: the suite is ended"
is "a signal in the second suite: no suite on record" "$(ls "$TOPO_VALIDATE_CACHE"/slots/*/suite 2>/dev/null)" ""
is "a signal in the second suite: nothing pushed" "$(origin_head)" ""
validate
is "the run after the signal: exits 0" "$status" 0

# A suite whose script was killed outright is still running with its locks free. With one
# checkout the next run refuses to start beside it, from a session in another time zone and
# locale as from this one. With two it takes the other, runs the suites the orphan is not in,
# and waits for that one; and it runs whole once the orphan has gone. The record is the
# script's own, of the suite it started.
scratch orphan Apps/Client/SettingsView.swift
begin "$repo" "$work/orphan/first" "$work/orphan/hold" FAKE_HOLD_SUITE=topo_unit
orphan="$(cat "$work/orphan/hold" 2>/dev/null)"
kill -KILL "$run"; wait "$run" 2>/dev/null
# The script as it was knows nothing of slots: its one lock is still held while the orphan lives.
free() { lockf -s -t 0 "$TOPO_VALIDATE_CACHE/lock" true 2>/dev/null; }
freed() { for _ in $(seq 50); do free && return 0; perl -e 'select(undef,undef,undef,0.1)'; done; return 1; }
free && fail "orphan suite: the lock of the script as it was is free beside it" || ok "orphan suite: a run of the script as it was is held off while it lives"
# Held by what started the suite, so from before the suite began.
keeper="$(ps -o ppid= -p "$orphan" | tr -d ' ')"
[ "$keeper" != 1 ] && [ "$keeper" != "$run" ] && ok "orphan suite: what started it outlives the script" || fail "orphan suite: the suite's parent is $keeper"
TOPO_VALIDATE_SLOTS=1 validate
is "orphan suite, one checkout: exits 2" "$status" 2
is "orphan suite, one checkout: no suite ran" "$(recorded head)" ""
is "orphan suite, one checkout: nothing pushed" "$(origin_head)" ""
case "$out" in *"kill $orphan"*) ok "orphan suite, one checkout: names the pid to end" ;; *) fail "orphan suite: does not name pid $orphan: $out" ;; esac
TZ=Asia/Tokyo LC_ALL=en_GB.UTF-8 TOPO_VALIDATE_SLOTS=1 validate
is "orphan suite, from another zone and locale: exits 2" "$status" 2
LOCK_WAIT=2 validate
is "orphan suite, two checkouts: exits 2 once the wait for its suite runs out" "$status" 2
is "orphan suite, two checkouts: the other two suites ran" "$(recorded suites)" "topo_ui others"
is "orphan suite, two checkouts: in the other checkout" "$(recorded checkout)" "$(cd "$TOPO_VALIDATE_CACHE/slots/2/checkout" && pwd -P)"
case "$out" in *"topo_unit: still running without its script, pid $orphan, end it with \`kill $orphan\`"*) ok "orphan suite, two checkouts: names the suite and the pid to end" ;; *) fail "orphan suite, two checkouts: $out" ;; esac
is "orphan suite, two checkouts: nothing pushed, two suites green" "$(origin_head)" ""
is "orphan suite, two checkouts: nothing posted" "$(grep -c 'statuses/' "$GH_CALLS")" 0
release "$work/orphan/hold"
for _ in $(seq 100); do kill -0 "$orphan" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
validate
is "orphan gone: exits 0" "$status" 0
is "orphan gone: in the first checkout again" "$(recorded checkout)" "$(cd "$TOPO_VALIDATE_CACHE/slots/1/checkout" && pwd -P)"
is "orphan gone: pushed" "$(origin_head)" "$sha"
freed && ok "orphan gone: the lock of the script as it was is free" || fail "orphan gone: the lock of the script as it was is still held"
# Two suites left behind by two killed runs: the lock is held until the last of them has gone.
scratch orphans Apps/Client/SettingsView.swift
sibling orphans theirs Packages/TopoLink/Package.swift
begin "$repo" "$work/orphans/first" "$work/orphans/first.hold" FAKE_HOLD_SUITE=topo_unit
first=$run
begin "$other" "$work/orphans/second" "$work/orphans/second.hold"
kill -KILL "$first" "$run"; wait "$first" "$run" 2>/dev/null
one="$(cat "$work/orphans/first.hold")"; two="$(cat "$work/orphans/second.hold")"
release "$work/orphans/first.hold"
for _ in $(seq 100); do kill -0 "$one" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
perl -e 'select(undef,undef,undef,2.5)'
free && fail "two orphan suites: the lock of the script as it was is free with one still going" || ok "two orphan suites: the lock is held while the second lives"
release "$work/orphans/second.hold"
for _ in $(seq 100); do kill -0 "$two" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
freed && ok "two orphan suites: free once both have gone" || fail "two orphan suites: the lock is still held with both gone"
# Whoever reads a killed script's output is not kept reading by the suite it left going.
scratch reader Apps/Client/SettingsView.swift
mkfifo "$work/reader/pipe"; : > "$work/reader/hold"
cat "$work/reader/pipe" > "$work/reader/out" & reader=$!
(cd "$repo" && exec env PATH="$work/bin:$PATH" FAKE_SUITES=held FAKE_RECORD="$work/reader/first" FAKE_HOLD="$work/reader/hold" scripts/validate-and-push.sh > "$work/reader/pipe" 2>&1) &
run=$!
for _ in $(seq 300); do [ -s "$work/reader/hold" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
left="$(cat "$work/reader/hold")"
kill -KILL "$run"; wait "$run" 2>/dev/null
for _ in $(seq 30); do kill -0 "$reader" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
kill -0 "$left" 2>/dev/null && ok "a killed script's reader: its suite is still going" || fail "a killed script's reader: the suite is not going"
kill -0 "$reader" 2>/dev/null && fail "a killed script's reader: still reading, three seconds on" || ok "a killed script's reader: done reading at once"
kill "$reader" 2>/dev/null; release "$work/reader/hold"
for _ in $(seq 100); do kill -0 "$left" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
# A run still going keeps its logs however many runs of its commit have begun since.
scratch sameprune Apps/Client/SettingsView.swift
begin "$repo" "$work/sameprune/first" "$work/sameprune/first.hold" FAKE_HOLD_SUITE=topo_unit
first=$run
live="$(ls -1 "$TOPO_VALIDATE_LOGS/$sha")"
for n in 1 2 3 4 5; do mkdir -p "$TOPO_VALIDATE_LOGS/$sha/2999010${n}T000000Z-1"; done
out="$(cd "$repo" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/sameprune/second" scripts/validate-and-push.sh --suites others 2>&1)" && status=0 || status=$?
is "a sixth run of a commit beside a live one: exits 0" "$status" 0
[ -d "$TOPO_VALIDATE_LOGS/$sha/$live" ] && ok "a sixth run of a commit beside a live one: the live run's logs are kept" || fail "a sixth run of a commit removed the logs of one still going"
# And while it pushes and posts, its suites over: held at its first status.
: > "$work/sameprune/post.hold"
(cd "$repo" && exec env PATH="$work/bin:$PATH" FAKE_RECORD="$work/sameprune/third" FAKE_POST_HOLD="$work/sameprune/post.hold" scripts/validate-and-push.sh --suites others > "$work/sameprune/third.out" 2>&1) &
third=$!
for _ in $(seq 300); do [ -e "$work/sameprune/post.hold.reached" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
[ -e "$work/sameprune/post.hold.reached" ] || fail "a run held at its status never reached it: $(cat "$work/sameprune/third.out")"
posting="$(ls -1 "$TOPO_VALIDATE_LOGS/$sha" | grep -- "-$third\$")"
for n in 1 2 3 4 5; do mkdir -p "$TOPO_VALIDATE_LOGS/$sha/2999020${n}T000000Z-1"; done
out="$(cd "$repo" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/sameprune/fourth" scripts/validate-and-push.sh --suites others 2>&1)" && status=0 || status=$?
[ -n "$posting" ] && [ -d "$TOPO_VALIDATE_LOGS/$sha/$posting" ] && ok "a later run of a commit beside one still posting: its logs are kept" || fail "a later run of a commit removed the logs of one still posting ('$posting')"
rm -f "$work/sameprune/post.hold"; wait "$third" 2>/dev/null
[ ! -e "$TOPO_VALIDATE_LOGS/$sha/$posting/running" ] && ok "a run that is over leaves no mark on its logs" || fail "a finished run's mark is still on its logs"
# A mark whose pid is by now another process's keeps nothing.
mkdir -p "$TOPO_VALIDATE_LOGS/$sha/20000101T000000Z-1"
printf '%s\n%s\n' "$$" "Sat Jan  1 00:00:00 2000" > "$TOPO_VALIDATE_LOGS/$sha/20000101T000000Z-1/running"
out="$(cd "$repo" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/sameprune/fifth" scripts/validate-and-push.sh --suites others 2>&1)" && status=0 || status=$?
[ ! -d "$TOPO_VALIDATE_LOGS/$sha/20000101T000000Z-1" ] && ok "a mark whose pid is another process's by now keeps no logs" || fail "a stale mark under a live pid kept its logs"
release "$work/sameprune/first.hold"; wait "$first" 2>/dev/null
# In its turn among runs of the script as it was: behind one that was waiting before it, and
# ahead of one that came after.
scratch turn Packages/TopoLink/Package.swift
mkdir -p "$TOPO_VALIDATE_CACHE"
lockf -k "$TOPO_VALIDATE_CACHE/lock" sh -c "echo \$\$ > '$work/turn/held'; exec sleep 60" &
holder=$!
for _ in $(seq 100); do [ -s "$work/turn/held" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
: > "$work/turn/order"
lockf -k "$TOPO_VALIDATE_CACHE/lock" sh -c "echo before >> '$work/turn/order'; sleep 1" &
before=$!
perl -e 'select(undef,undef,undef,0.5)'
: > "$work/turn/hold"
(cd "$repo" && exec env PATH="$work/bin:$PATH" FAKE_SUITES=held FAKE_HOLD="$work/turn/hold" scripts/validate-and-push.sh > "$work/turn/out" 2>&1) &
run=$!
for _ in $(seq 200); do grep -q 'Waiting for a run of the script as it was' "$work/turn/out" 2>/dev/null && break; perl -e 'select(undef,undef,undef,0.1)'; done
perl -e 'select(undef,undef,undef,0.5)'
lockf -k "$TOPO_VALIDATE_CACHE/lock" sh -c "echo after >> '$work/turn/order'; sleep 1" &
after=$!
perl -e 'select(undef,undef,undef,0.5)'
kill "$(cat "$work/turn/held")" "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
for _ in $(seq 300); do [ -s "$work/turn/hold" ] && break; grep -q after "$work/turn/order" && break; perl -e 'select(undef,undef,undef,0.1)'; done
[ -s "$work/turn/hold" ] && ok "in its turn: the run's suite began" || fail "in its turn: the run's suite never began: $(cat "$work/turn/out")"
is "in its turn: after the run that waited before it, ahead of the one that came after" "$(tr '\n' ' ' < "$work/turn/order")" "before "
release "$work/turn/hold"
wait "$run"; is "in its turn: exits 0" "$?" 0
wait "$before" "$after" 2>/dev/null
is "in its turn: the later run of the script as it was went last" "$(tr '\n' ' ' < "$work/turn/order")" "before after "
# One allowance for every wait: what a checkout took of it is not there for a suite.
scratch budget Packages/TopoLink/Package.swift
mkdir -p "$TOPO_VALIDATE_CACHE/slots/1"
lockf -k "$TOPO_VALIDATE_CACHE/slots/1/lock" sleep 6 &
slot_holder=$!
lockf -k "$TOPO_VALIDATE_CACHE/suite-others.lock" sh -c "echo \$\$ > '$work/budget/held'; exec sleep 60" &
holder=$!
for _ in $(seq 100); do [ -s "$work/budget/held" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
began=$SECONDS
LOCK_WAIT=10 TOPO_VALIDATE_SLOTS=1 validate
is "one allowance: exits 2" "$status" 2
case "$out" in *"Waiting for a checkout"*"Waiting for a suite"*"gave up after waiting"*) ok "one allowance: it waited for a checkout, then a suite, then gave up" ;; *) fail "one allowance: $out" ;; esac
[ $((SECONDS - began)) -lt 14 ] && ok "one allowance: within the ten seconds and not six and ten" || fail "one allowance: gave up after $((SECONDS - began)) s"
kill "$(cat "$work/budget/held")" "$holder" "$slot_holder" 2>/dev/null; wait "$holder" "$slot_holder" 2>/dev/null
# A commit whose logs a run is still writing keeps them, however many commits have run since.
for n in 1 2 3 4 5 6 7 8 9 a b c; do
  mkdir -p "$TOPO_VALIDATE_LOGS/${n}0000000/20200101T000000Z-1"
  touch -t 202001010000 "$TOPO_VALIDATE_LOGS/${n}0000000"
done
printf '%s\n%s\n' "$$" "$(LC_ALL=C TZ=UTC ps -o lstart= -p $$)" > "$TOPO_VALIDATE_LOGS/10000000/20200101T000000Z-1/running"
touch -t 201901010000 "$TOPO_VALIDATE_LOGS/10000000"   # the oldest of them: the first the prune would take
echo x > "$repo/x"; g -C "$repo" add -A; g -C "$repo" commit -qm x; sha="$(git -C "$repo" rev-parse HEAD)"
validate
[ -d "$TOPO_VALIDATE_LOGS/10000000" ] && ok "old logs a run is still writing are kept" || fail "the logs of a run in flight were removed"
[ "$(ls -1 "$TOPO_VALIDATE_LOGS" | grep -c '0000000$')" -lt 12 ] && ok "old logs nobody is writing go" || fail "no old logs were removed"
# The suite a run of the script as it was left going, on record beside its one lock.
perl -e 'sleep 60' & stray=$!
printf '%s\n%s\n' "$stray" "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$stray")" > "$TOPO_VALIDATE_CACHE/suite"
echo z > "$repo/z"; g -C "$repo" add -A; g -C "$repo" commit -qm z; sha="$(git -C "$repo" rev-parse HEAD)"
validate
is "an orphan of the script as it was: exits 2" "$status" 2
is "an orphan of the script as it was: no suite ran" "$(recorded head)" ""
case "$out" in *"kill $stray"*) ok "an orphan of the script as it was: names the pid to end" ;; *) fail "an orphan of the script as it was: $out" ;; esac
kill "$stray" 2>/dev/null; wait "$stray" 2>/dev/null
rm -f "$TOPO_VALIDATE_CACHE/suite"
unset FAKE_HOLD

# A suite that cannot start is a red run like any other, and holds no later run off the Mac.
scratch unstartable Apps/Client/SettingsView.swift
chmod -x "$repo/scripts/mac-suite.sh"
g -C "$repo" commit -qam "the suite cannot be run"
sha="$(git -C "$repo" rev-parse HEAD)"
validate
is "a suite that cannot start: exits 1" "$status" 1
is "a suite that cannot start: nothing pushed" "$(origin_head)" ""
case "$out" in *"RED at"*) ok "a suite that cannot start: reported red" ;; *) fail "a suite that cannot start: not reported red: $out" ;; esac
chmod +x "$repo/scripts/mac-suite.sh"
g -C "$repo" commit -qam "the suite can be run"
sha="$(git -C "$repo" rev-parse HEAD)"
validate
is "the run after it: exits 0" "$status" 0
is "the run after it: pushed" "$(origin_head)" "$sha"
is "a finished run leaves no suite on record" "$(ls "$TOPO_VALIDATE_CACHE"/slots/*/suite 2>/dev/null)" ""

# Two words for one suite, a failure and then a success: red, and posted as red.
scratch twice Packages/TopoLink/Package.swift
git -C "$repo" push -q origin topic
FAKE_SUITES="twice" validate
is "two results for a suite: exits 1" "$status" 1
is "two results for a suite: posted as failure" "$(posted)" "local/others=failure "

# A description keeps the whole path of the logs inside GitHub's 140 characters.
scratch describe Apps/Client/Ear.swift
mkdir -p "$work/describe/home"
HOME="$work/describe/home" TOPO_VALIDATE_LOGS="$work/describe/home/Library/Logs/topo-validate" validate
long="$(sed -n 's/.* -f description=//p' "$GH_CALLS" | awk '{ if (length($0) > 140) n++ } END { print n + 0 }')"
is "descriptions: none over 140 characters" "$long" 0
is "descriptions: each says what ran" "$(grep -c "description=.* lane, 0 min on .*; logs \|description=Parakeet heard the fixture on .*; logs " "$GH_CALLS")" 4
is "descriptions: each names the commit's logs" "$(grep -c "description=.*logs ~/Library/Logs/topo-validate/$sha\$" "$GH_CALLS")" 4
# A logs root too long for the 140 characters: the description is the path, or its end.
for long in "$work/describe/$(printf 'l%.0s' $(seq 40))" "$work/describe/$(printf 'l%.0s' $(seq 120))"; do
  scratch describe-long Apps/Client/Ear.swift
  TOPO_VALIDATE_LOGS="$long" validate
  is "a long logs root (${#long}): exits 0" "$status" 0
  is "a long logs root (${#long}): none over 140 characters" "$(sed -n 's/.* -f description=//p' "$GH_CALLS" | awk '{ if (length($0) > 140) n++ } END { print n + 0 }')" 0
  is "a long logs root (${#long}): each ends in the commit" "$(grep -c "description=logs .*/$sha\$" "$GH_CALLS")" 4
  rm -rf "$work/describe-long"
done

# Another Mac, named: `topo_unit`, `others` and the quiet part of `topo_ui` run there at the
# commit, the microphone's part here and last, and each status says where.
there() { (cd "$FAKE_HOSTS/$1/Library/Caches/topo-validate/checkout" 2>/dev/null && pwd -P); }
said_on() { sed -n "s|.*context=local/$1 .* min on \([^;]*\);.*|\1|p" "$GH_CALLS"; }
# The logs under the home's own root, so a description has room for more than their path.
scratch host Apps/Client/SettingsView.swift
mkdir -p "$work/host/home"
TOPO_VALIDATE_LOGS="$work/host/home/Library/Logs/topo-validate"
HOME="$work/host/home" TOPO_VALIDATE_HOSTS=laptop validate
is "a host named: exits 0" "$status" 0
is "a host named: what it may run, then the microphone's part of topo_ui" "$(recorded suites)" "topo_unit topo_ui:quiet others topo_ui:mic"
is "a host named: it was asked whether it can run each" "$(tr '\n' ' ' < "$FAKE_RECORD.checks")" "check topo_unit check topo_ui:quiet check others "
is "a host named: the microphone's part ran here" "$(recorded checkout)" "$(cd "$TOPO_VALIDATE_CACHE/slots/1/checkout" && pwd -P)"
is "a host named: its checkout is at the commit" "$(git -C "$(there laptop)" rev-parse HEAD 2>/dev/null)" "$sha"
is "a host named: pushed" "$(origin_head)" "$sha"
is "a host named: one success per suite" "$(posted)" "local/topo_unit=success local/topo_ui=success local/others=success "
is "a host named: topo_unit's status names it" "$(said_on topo_unit)" laptop
is "a host named: others' status names it" "$(said_on others)" laptop
is "a host named: topo_ui's one status names both Macs, the quiet part's first" "$(sed -n 's|.*context=local/topo_ui .*description=\(topo_ui [^;]*\);.*|\1|p' "$GH_CALLS")" "topo_ui passed, fast lane, 0 min on laptop + 0 on $(hostname -s)"
is "a host named: neither part is asked of the Mac as topo_ui, nor the microphone's at all" "$(grep -c '^laptop bash -s .* topo_ui\(:mic\)\{0,1\} ' "$SSH_CALLS")" 0
[ -f "$TOPO_VALIDATE_LOGS/$sha"/*/laptop/suites.txt ] && ok "a host named: its results are in the run's logs" || fail "a host named: no results from it in the logs"
# The full lane: the real ear rides on the two parts' one success.
scratch host-ear Apps/Client/SettingsView.swift
TOPO_VALIDATE_HOSTS=laptop validate --suites topo_ui --lane full
is "a host named, the full lane: topo_ui and the real ear" "$status:$(posted)" "0:local/topo_ui=success local/real_ear=success "
is "a host named, the full lane: both parts on that lane" "$(recorded suites):$(recorded lane)" "topo_ui:quiet topo_ui:mic:full"
# A red part is a red topo_ui, whichever, and the other still runs; nothing is said of the real ear.
for part in quiet mic; do
  scratch host-part-red Apps/Client/SettingsView.swift
  git -C "$repo" push -q origin topic
  FAKE_SUITES="topo_ui:$part=failure" TOPO_VALIDATE_HOSTS=laptop validate --suites topo_ui --lane full
  is "the $part part red: exits 1" "$status" 1
  is "the $part part red: both parts ran" "$(recorded suites)" "topo_ui:quiet topo_ui:mic"
  is "the $part part red: one failure, for topo_ui, and no real ear" "$(posted)" "local/topo_ui=failure "
  case "$out" in *"RED at "*": topo_ui:$part."*) ok "the $part part red: named" ;; *) fail "the $part part red: $out" ;; esac
  rm -rf "$work/host-part-red"
done
# A part with no result is no pass.
scratch host-part-died Apps/Client/SettingsView.swift
git -C "$repo" push -q origin topic
FAKE_SUITES=died TOPO_VALIDATE_HOSTS=laptop validate --suites topo_ui
is "the parts with no result: a failure" "$status:$(posted)" "1:local/topo_ui=failure "
# The slot here is not taken while the quiet part is on the other Mac, and the microphone's
# part holds topo_ui's name here, as the suite whole does.
scratch host-order Apps/Client/SettingsView.swift
begin "$repo" "$work/host-order/record" "$work/host-order/hold" TOPO_VALIDATE_HOSTS=laptop FAKE_HOLD_SUITE=topo_ui:quiet
is "the quiet part on a host: it is what is running" "$(sed -n 's/^suites=//p' "$work/host-order/record")" "topo_unit topo_ui:quiet"
[ ! -e "$TOPO_VALIDATE_CACHE/slots/1/holder" ] && ok "the quiet part on a host: no slot is held here meanwhile" || fail "the quiet part on a host: a slot is held here: $(cat "$TOPO_VALIDATE_CACHE/slots/1/holder")"
release "$work/host-order/hold"; wait "$run"
is "the quiet part on a host: the run exits 0" "$?" 0
scratch host-mic Apps/Client/SettingsView.swift
begin "$repo" "$work/host-mic/record" "$work/host-mic/hold" TOPO_VALIDATE_HOSTS=laptop FAKE_HOLD_SUITE=topo_ui:mic
is "the microphone's part: last of the run" "$(sed -n 's/^suites=//p' "$work/host-mic/record")" "topo_unit topo_ui:quiet others topo_ui:mic"
is "the microphone's part: topo_ui's name is held here under it" "$(lockf -s -t 0 "$TOPO_VALIDATE_CACHE/suite-topo_ui.lock" echo free 2>/dev/null || echo held)" held
is "the microphone's part: no name of its own" "$(ls "$TOPO_VALIDATE_CACHE" | grep -c 'topo_ui:')" 0
release "$work/host-mic/hold"; wait "$run"
is "the microphone's part: the run exits 0" "$?" 0
# The Mac busy, or losing the quiet part: topo_ui runs here whole, in one call, as with none named.
scratch host-ui-busy Apps/Client/SettingsView.swift
mkdir -p "$FAKE_HOSTS/laptop/Library/Caches/topo-validate"
lockf -k "$FAKE_HOSTS/laptop/Library/Caches/topo-validate/lock" sh -c "echo \$\$ > '$work/host-ui-busy/held'; exec sleep 60" &
holder=$!
for _ in $(seq 100); do [ -s "$work/host-ui-busy/held" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
TOPO_VALIDATE_HOSTS=laptop validate
is "a host busy, topo_ui: whole here, in its place" "$status:$(recorded suites)" "0:topo_unit topo_ui others"
is "a host busy, topo_ui: one success per suite" "$(posted)" "local/topo_unit=success local/topo_ui=success local/others=success "
kill "$(cat "$work/host-ui-busy/held")" "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
scratch host-ui-lost Apps/Client/SettingsView.swift
FAKE_LOST_IN=/hosts/laptop/ TOPO_VALIDATE_HOSTS=laptop validate --suites topo_ui
is "a host that lost the quiet part: topo_ui whole here" "$status:$(recorded suites)" "0:topo_ui"
is "a host that lost the quiet part: one success" "$(posted)" "local/topo_ui=success "
is "a host that lost the quiet part: asked once" "$(grep -c '^laptop bash -s' "$SSH_CALLS")" 1
# With no Mac named, topo_ui is one call.
scratch host-none Apps/Client/SettingsView.swift
validate --suites topo_ui
is "no host named: topo_ui whole" "$status:$(recorded suites)" "0:topo_ui"
# A suite that needs nothing here takes no checkout here.
scratch host-alone Packages/TopoLink/Package.swift
TOPO_VALIDATE_HOSTS=laptop validate
is "others alone on a host: exits 0" "$status" 0
is "others alone on a host: ran there" "$(recorded checkout)" "$(there laptop)"
is "others alone on a host: with none of its person's git configuration" "$(recorded gitconfig)" /dev/null
[ ! -e "$TOPO_VALIDATE_CACHE/slots/1/checkout" ] && ok "others alone on a host: no checkout here" || fail "others alone on a host: a checkout was made here"
scratch host-harness scripts/janitor.py
TOPO_VALIDATE_HOSTS=laptop validate
is "scripts alone on a host: exits 0" "$status" 0
is "scripts alone on a host: ran there" "$(recorded checkout)" "$(there laptop)"
is "scripts alone on a host: its status" "$(posted)" "local/scripts=success "
# Named in the file, and not when the variable is set, to nothing included.
mkdir -p "$TOPO_VALIDATE_CACHE"; printf '# an afternoon\nlaptop\n' > "$TOPO_VALIDATE_CACHE/hosts"
echo y > "$repo/Packages/TopoLink/y"; g -C "$repo" add -A; g -C "$repo" commit -qm y; sha="$(git -C "$repo" rev-parse HEAD)"
validate
is "a host in the file: ran there" "$(recorded checkout)" "$(there laptop)"
is "a host in the file: its checkout moved to this commit" "$(recorded head)" "$sha"
echo z > "$repo/Packages/TopoLink/z"; g -C "$repo" add -A; g -C "$repo" commit -qm z; sha="$(git -C "$repo" rev-parse HEAD)"
TOPO_VALIDATE_HOSTS= validate
is "the variable set to nothing: ran here" "$(recorded checkout)" "$(cd "$TOPO_VALIDATE_CACHE/slots/1/checkout" && pwd -P)"
TOPO_VALIDATE_HOSTS="lap;top" validate
is "a name that is not a host: exits 2" "$status" 2
TOPO_VALIDATE_HOSTS="*" validate
is "a pattern is not a host: exits 2" "$status" 2
is "a pattern is not a host: nothing here is asked as one" "$(grep -vc '^laptop ' "$SSH_CALLS")" 0
# A red suite there is red: nothing pushed.
scratch host-red Packages/TopoLink/Package.swift
FAKE_SUITES="others=failure" TOPO_VALIDATE_HOSTS=laptop validate
is "red on a host: exits 1" "$status" 1
is "red on a host: nothing pushed" "$(origin_head)" ""
# A Mac that cannot be used runs nothing, is asked once, and the suite runs here.
for case in "not reached|FAKE_UNREACHABLE=laptop" "cannot run it|FAKE_CHECK=no iPhone simulator" "no result|FAKE_LOST_IN=/hosts/laptop/"; do
  scratch host-unusable Packages/TopoLink/Package.swift Womble/x
  mkdir -p "$work/host-unusable/home"
  TOPO_VALIDATE_LOGS="$work/host-unusable/home/Library/Logs/topo-validate"
  out="$(cd "$repo" && env PATH="$work/bin:$PATH" HOME="$work/host-unusable/home" "${case#*|}" TOPO_VALIDATE_HOSTS=laptop scripts/validate-and-push.sh --suites "topo_unit others" 2>&1)" && status=0 || status=$?
  is "a host ${case%%|*}: exits 0" "$status" 0
  is "a host ${case%%|*}: both suites ran" "$(recorded suites)" "topo_unit others"
  is "a host ${case%%|*}: the suite ran here" "$(recorded checkout)" "$(cd "$TOPO_VALIDATE_CACHE/slots/1/checkout" && pwd -P)"
  is "a host ${case%%|*}: the status names this Mac" "$(said_on others)" "$(hostname -s)"
  case "$out" in *"laptop"*"${case%%|*}"*) ok "a host ${case%%|*}: it is said" ;; *) fail "a host ${case%%|*}: $out" ;; esac
  is "a host ${case%%|*}: asked to run a suite at most once" "$(grep -c '^laptop bash -s' "$SSH_CALLS")" "$([ "${case%%|*}" = "not reached" ] && echo 0 || echo 1)"
  rm -rf "$work/host-unusable"
done
# A pass the connection did not outlive is no result: the suite runs here, and is not red.
scratch host-drop Packages/TopoLink/Package.swift
FAKE_DROP=1 TOPO_VALIDATE_HOSTS=laptop validate
is "a host that passed as the connection dropped: exits 0" "$status" 0
is "a host that passed as the connection dropped: the suite ran here" "$(recorded checkout)" "$(cd "$TOPO_VALIDATE_CACHE/slots/1/checkout" && pwd -P)"
is "a host that passed as the connection dropped: one success" "$(posted)" "local/others=success "
case "$out" in *"laptop ended it with no result"*) ok "a host that passed as the connection dropped: it is said" ;; *) fail "a dropped connection: $out" ;; esac
# A Mac busy with another validation: the suite runs here and not beside it.
scratch host-busy Packages/TopoLink/Package.swift
mkdir -p "$FAKE_HOSTS/laptop/Library/Caches/topo-validate"
lockf -k "$FAKE_HOSTS/laptop/Library/Caches/topo-validate/lock" sh -c "echo \$\$ > '$work/host-busy/held'; exec sleep 60" &
holder=$!
for _ in $(seq 100); do [ -s "$work/host-busy/held" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
TOPO_VALIDATE_HOSTS=laptop validate
is "a host busy: exits 0" "$status" 0
[ -n "$(recorded checkout)" ] && ok "a host busy: the suite ran" || fail "a host busy: the suite ran nowhere"
is "a host busy: the suite ran here" "$(recorded checkout)" "$(cd "$TOPO_VALIDATE_CACHE/slots/1/checkout" && pwd -P)"
[ ! -e "$FAKE_HOSTS/laptop/Library/Caches/topo-validate/checkout" ] && ok "a host busy: its checkout was not touched" || fail "a host busy: its checkout was made under the other run"
kill "$(cat "$work/host-busy/held")" "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
# A signal ends the suite there.
scratch host-signal Packages/TopoLink/Package.swift
begin "$repo" "$work/host-signal/record" "$work/host-signal/hold" TOPO_VALIDATE_HOSTS=laptop
held="$(cat "$work/host-signal/hold")"
kill -TERM "$run"; wait "$run"
is "a signal with a suite on a host: exits 143" "$?" 143
for _ in $(seq 50); do kill -0 "$held" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
kill -0 "$held" 2>/dev/null && fail "a signal with a suite on a host: the suite is still running there" || ok "a signal with a suite on a host: the suite is ended there"
is "a signal with a suite on a host: nothing pushed" "$(origin_head)" ""
release "$work/host-signal/hold"
is "a signal with a suite on a host: its lock is free" "$(lockf -s -t 0 "$FAKE_HOSTS/laptop/Library/Caches/topo-validate/lock" echo free 2>&1)" free
# And one that comes before the suite there has begun starts none.
scratch host-early Packages/TopoLink/Package.swift
(cd "$repo" && exec env PATH="$work/bin:$PATH" FAKE_CHECK_SLOW=1 FAKE_SUITES=held FAKE_HOLD="$work/host-early/hold" TOPO_VALIDATE_HOSTS=laptop scripts/validate-and-push.sh > "$work/host-early/out" 2>&1) &
run=$!
for _ in $(seq 100); do [ -s "$FAKE_RECORD.checks" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
[ -s "$FAKE_RECORD.checks" ] || fail "a signal before the suite on a host: the host was never asked"
kill -TERM "$run"; wait "$run"
is "a signal before the suite on a host: exits 143" "$?" 143
perl -e 'select(undef,undef,undef,1)'
is "a signal before the suite on a host: no suite began there" "$(recorded suites)$(cat "$work/host-early/hold" 2>/dev/null)" ""
is "a signal before the suite on a host: its lock is free" "$(lockf -s -t 0 "$FAKE_HOSTS/laptop/Library/Caches/topo-validate/lock" echo free 2>&1)" free

# main is never pushed from here, and a detached HEAD has no branch to push to.
scratch main docs/design.md
git -C "$repo" checkout -q main
validate
is "on main: exits 2" "$status" 2
git -C "$repo" checkout -q --detach topic
validate
is "detached: exits 2" "$status" 2


# The line for the one checkout. A run that waits is in it, and the checkout goes to whoever
# has waited longest: the second run here looks five times as often as the first, and would
# have the checkout nearly every time were it only a matter of who asks first.
export TOPO_VALIDATE_SLOTS=1
tickets() { ls -1 "$TOPO_VALIDATE_CACHE/queue" 2>/dev/null | grep -E '^[0-9]{16}-[0-9]{7}$' | LC_ALL=C sort | tr '\n' ' '; }
ticket_of() { tickets | tr ' ' '\n' | grep -- "-0*$1\$" || true; }
until_true() { local n; for n in $(seq 100); do "$@" && return 0; perl -e 'select(undef,undef,undef,0.1)'; done; return 1; }
has_ticket() { [ -n "$(ticket_of "$1")" ]; }
no_ticket() { [ -z "$(ticket_of "$1")" ]; }
reached() { [ -s "$1" ]; }
# waiter <directory> <name> [VAR=value...] — a run there in the background that will be held
# in its suite once it has one; its pid in $run, its marker $work/line/<name>.hold.
waiter() {
  local at="$1" name="$2"; shift 2
  : > "$work/line/$name.hold"
  (cd "$at" && exec env PATH="$work/bin:$PATH" FAKE_SUITES=held FAKE_RECORD="$work/line/$name" FAKE_HOLD="$work/line/$name.hold" "$@" scripts/validate-and-push.sh > "$work/line/$name.out" 2>&1) &
  run=$!
}
scratch line Apps/Client/SettingsView.swift
sibling line theirs Packages/TopoLink/Package.swift
theirs="$other"
sibling line later Packages/TopoLink/Package.swift
later="$other"
begin "$repo" "$work/line/first" "$work/line/first.hold" FAKE_HOLD_SUITE=topo_unit
first=$run
is "the first run, nobody waiting: it took no place in the line" "$(tickets)" ""
clock() { perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.0f", clock_gettime(CLOCK_MONOTONIC) * 1e6'; }
clock_before="$(clock)"
waiter "$theirs" a LOCK_POLL=5; a=$run
until_true has_ticket "$a" || fail "the line: a run that waits has no ticket: $(cat "$work/line/a.out")"
a_ticket="$(ticket_of "$a")"
# Its place is by the clock that is never set, not the time of day, which can be put back.
a_at="$((10#${a_ticket%%-*}))"
[ "$a_at" -ge "$clock_before" ] && [ "$a_at" -le "$(clock)" ] && ok "the line: a ticket is named by the clock that counts from this Mac's start" || fail "the line: the ticket $a_ticket is not between $clock_before and $(clock)"
waiter "$later" b LOCK_POLL=1; b=$run
until_true has_ticket "$b" || fail "the line: a second run that waits has no ticket: $(cat "$work/line/b.out")"
is "the line: in the order they came" "$(tickets)" "$a_ticket $(ticket_of "$b") "
case "$(cat "$work/line/b.out")" in *"Waiting for a checkout (1 ahead in the line, the first theirs "*) ok "the line: the second says who is ahead" ;; *) fail "the line: $(cat "$work/line/b.out")" ;; esac
# A run whose ticket was taken for dead puts it back, under its own name.
rm -f "$TOPO_VALIDATE_CACHE/queue/$a_ticket"
until_true has_ticket "$a" || fail "a ticket removed under a live run: not put back"
is "a ticket removed under a live run: back under its own name" "$(ticket_of "$a")" "$a_ticket"
release "$work/line/first.hold"; wait "$first" 2>/dev/null
until_true reached "$work/line/a.hold" || fail "the line: the run that came first never had the checkout: $(cat "$work/line/a.out")"
[ ! -s "$work/line/b.hold" ] && ok "the line: the run that came first has the checkout, the later one waits" || fail "the line: the later run took the checkout first"
is "the line: the one with the checkout is out of it" "$(tickets)" "$(ticket_of "$b") "
release "$work/line/a.hold"; wait "$a"; is "the line: the first to come exits 0" "$?" 0
until_true reached "$work/line/b.hold" || fail "the line: the later run never had the checkout: $(cat "$work/line/b.out")"
release "$work/line/b.hold"; wait "$b"; is "the line: the later run exits 0" "$?" 0
is "the line: empty when all are done" "$(tickets)" ""

# What is in the line and is not a run that waits holds nobody: a ticket of a pid that is
# gone, one of a pid that began at another time, one of no length and one of one line are
# each removed; a file of another name is left; and a ticket of a live process ahead is
# waited behind, by name, until that process ends.
q="$TOPO_VALIDATE_CACHE/queue"
began() { LC_ALL=C TZ=UTC ps -o lstart= -p "$1"; }
sleep 30 & gone=$!; gone_began="$(began "$gone")"; kill "$gone"; wait "$gone" 2>/dev/null
sleep 30 & alive=$!
printf '%s\n%s\n%s\n' "$gone" "$gone_began" "ended 0000001" > "$q/0000000000000001-0000001"
printf '%s\n%s\n%s\n' "$alive" "Thu Jan  1 00:00:00 1970" "another 0000002" > "$q/0000000000000002-0000002"
: > "$q/0000000000000003-0000003"
echo "$alive" > "$q/0000000000000004-0000004"
echo keep > "$q/notes"; echo keep > "$q/.new.99999"; echo keep > "$q/0000000000000005-5"
LOCK_WAIT=0 validate
is "dead tickets ahead: the run waits for nothing" "$status" 0
is "dead tickets ahead: each is removed" "$(tickets)" ""
is "dead tickets ahead: what is not a ticket is left" "$(ls -A "$q" | LC_ALL=C sort | tr '\n' ' ')" ".new.99999 0000000000000005-5 notes "
printf '%s\n%s\n%s\n' "$alive" "$(began "$alive")" "ahead 0000006" > "$q/0000000000000006-0000006"
LOCK_WAIT=2 validate
is "a live ticket ahead: exits 2" "$status" 2
case "$out" in *"Waiting for a checkout (1 ahead in the line, the first ahead 0000006, pid "*")"*) ok "a live ticket ahead: it is waited behind, by name" ;; *) fail "a live ticket ahead: $out" ;; esac
is "a live ticket ahead: no suite ran" "$(recorded suites)" ""
is "a wait that ran out: the run's own ticket is gone, the one ahead left" "$(tickets)" "0000000000000006-0000006 "
# A signal while in the line.
waiter "$theirs" term; term=$run
until_true has_ticket "$term" || fail "a signal in the line: the run never took a place: $(cat "$work/line/term.out")"
kill -TERM "$term"; wait "$term"; is "a signal in the line: exits 143" "$?" 143
is "a signal in the line: its ticket is gone" "$(ticket_of "$term")" ""
kill "$alive"; wait "$alive" 2>/dev/null
LOCK_WAIT=0 validate
is "the process ahead ended: the run waits for nothing" "$status" 0
is "the process ahead ended: its ticket is removed" "$(tickets)" ""

# With another Mac named and busy, a run waits here in the line and asks the Mac again: it is
# out of the line for each asking and back under its own name, so a run that came later does
# not pass it. Once the Mac takes its suite it is out of the line for as long as that runs,
# and the run behind has the checkout.
scratch away Apps/Client/SettingsView.swift
sibling away theirs Packages/TopoLink/Package.swift
theirs="$other"
sibling away later Packages/TopoLink/Package.swift
later="$other"
mkdir -p "$work/line" "$FAKE_HOSTS/laptop/Library/Caches/topo-validate"
lockf -k "$FAKE_HOSTS/laptop/Library/Caches/topo-validate/lock" sh -c "echo \$\$ > '$work/away/held'; exec sleep 120" &
holder=$!
until_true reached "$work/away/held"
begin "$repo" "$work/away/first" "$work/away/first.hold" FAKE_HOLD_SUITE=topo_unit TOPO_VALIDATE_HOSTS=
first=$run
waiter "$theirs" away-a TOPO_VALIDATE_HOSTS=laptop HOST_RETRY=1 LOCK_POLL=1; a=$run
until_true has_ticket "$a" || fail "a busy Mac: the run took no place here: $(cat "$work/line/away-a.out")"
a_ticket="$(ticket_of "$a")"
waiter "$later" away-b TOPO_VALIDATE_HOSTS= LOCK_POLL=1; b=$run
until_true has_ticket "$b" || fail "a busy Mac: the later run took no place: $(cat "$work/line/away-b.out")"
asked="$(grep -c '^laptop bash -s' "$SSH_CALLS")"
asked_again() { [ "$(grep -c '^laptop bash -s' "$SSH_CALLS")" -ge "$((asked + 3))" ]; }
until_true asked_again || fail "a busy Mac: it was not asked again"
until_true has_ticket "$a"
is "a busy Mac asked again and again: the run keeps its place" "$(tickets)" "$a_ticket $(ticket_of "$b") "
kill "$(cat "$work/away/held")" "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
until_true reached "$work/line/away-a.hold" || fail "the Mac free: the run's suite never started there: $(cat "$work/line/away-a.out")"
until_true no_ticket "$a" && ok "a suite running on another Mac: its run is out of the line here" || fail "a suite running on another Mac: its run is still in the line here"
release "$work/away/first.hold"; wait "$first" 2>/dev/null
until_true reached "$work/line/away-b.hold" || fail "a suite running on another Mac: the run behind never had the checkout: $(cat "$work/line/away-b.out")"
kill -0 "$(cat "$work/line/away-a.hold")" 2>/dev/null && ok "a suite running on another Mac: the run behind has the checkout meanwhile" || fail "a suite running on another Mac: it had ended"
release "$work/line/away-a.hold"; release "$work/line/away-b.hold"
wait "$a"; is "a suite on another Mac: its run exits 0" "$?" 0
wait "$b"; is "a suite on another Mac: the run behind exits 0" "$?" 0
is "the line: empty when all are done" "$(tickets)" ""

# A run's place is when it began, not when it reached the line: one that began first and was
# slow to get there (its first `git` takes two seconds) is ahead of one that began after it
# and was waiting already.
mkdir -p "$work/slowbin"
printf '#!/usr/bin/env bash\n[ -e "%s" ] || { : > "%s"; perl -e "select(undef,undef,undef,2)"; }\nexec "%s" "$@"\n' "$work/line/slowed" "$work/line/slowed" "$(command -v git)" > "$work/slowbin/git"
chmod +x "$work/slowbin/git"
waiter "$repo" slow-first FAKE_HOLD_SUITE=topo_unit TOPO_VALIDATE_HOSTS=; first=$run
until_true reached "$work/line/slow-first.hold" || fail "began first: the holder never started: $(cat "$work/line/slow-first.out")"
waiter "$theirs" slow-a PATH="$work/slowbin:$work/bin:$PATH" LOCK_POLL=1 TOPO_VALIDATE_HOSTS=; a=$run
perl -e 'select(undef,undef,undef,0.3)'
waiter "$later" slow-b LOCK_POLL=1 TOPO_VALIDATE_HOSTS=; b=$run
until_true has_ticket "$b" || fail "began first: the later run took no place: $(cat "$work/line/slow-b.out")"
[ -z "$(ticket_of "$a")" ] && ok "began first: the later run is in the line before it" || fail "began first: the slow run was in the line already"
until_true has_ticket "$a" || fail "began first: the slow run took no place: $(cat "$work/line/slow-a.out")"
is "began first, reached the line second: ahead" "$(tickets)" "$(ticket_of "$a") $(ticket_of "$b") "
release "$work/line/slow-first.hold"; wait "$first" 2>/dev/null
until_true reached "$work/line/slow-a.hold" && [ ! -s "$work/line/slow-b.hold" ] && ok "began first: it has the checkout first" || fail "began first: the later run took the checkout: $(cat "$work/line/slow-a.out")"
release "$work/line/slow-a.hold"; wait "$a" 2>/dev/null
until_true reached "$work/line/slow-b.hold" || fail "began first: the later run never had the checkout"
release "$work/line/slow-b.hold"; wait "$b" 2>/dev/null

# By hand: a command with the checkout held, in the line as a validation is. It asks nothing
# of where it is run from, has the command's output and exit, starts no suite and posts and
# pushes nothing; a validation meanwhile waits; what the command leaves running holds
# nothing; a signal ends the command; and a command a SIGKILL of the script left running is
# found by the next run, which starts nothing beside it.
scratch hold Packages/TopoLink/Package.swift
held_out="$(cd "$work" && PATH="$work/bin:$PATH" "$repo/scripts/validate-and-push.sh" --hold -- sh -c 'echo said; exit 7' 2>/dev/null)" && status=0 || status=$?
is "a hold, from no worktree at all: the command's exit" "$status" 7
is "a hold: the command's output" "$held_out" "said"
is "a hold: nothing posted" "$(grep -c . "$GH_CALLS")" 0
[ ! -e "$TOPO_VALIDATE_CACHE/slots/1/checkout" ] && ok "a hold: no checkout is made" || fail "a hold: a checkout was made"
(cd "$repo" && PATH="$work/bin:$PATH" scripts/validate-and-push.sh --hold) > /dev/null 2>&1 && status=0 || status=$?
is "a hold with no command: exits 2" "$status" 2
: > "$work/hold/marker"
(cd "$work" && PATH="$work/bin:$PATH" exec "$repo/scripts/validate-and-push.sh" --hold -- sh -c "echo \$\$ > '$work/hold/marker'; while [ -s '$work/hold/marker' ]; do sleep 0.1; done") > "$work/hold/out" 2>&1 &
holding=$!
until_true reached "$work/hold/marker" || fail "a hold: its command never started: $(cat "$work/hold/out")"
LOCK_WAIT=2 validate
is "a hold standing: a validation exits 2" "$status" 2
case "$out" in *"Waiting for a checkout (slot 1: by hand sh, pid $holding,"*) ok "a hold standing: the validation waits for it, by name" ;; *) fail "a hold standing: $out" ;; esac
is "a hold standing: no suite ran" "$(recorded suites)" ""
held_pid="$(cat "$work/hold/marker")"
kill -TERM "$holding"; wait "$holding"; is "a signal to a hold: exits 143" "$?" 143
until_true eval "! kill -0 $held_pid 2>/dev/null" && ok "a signal to a hold: its command is ended" || fail "a signal to a hold: its command is still running"
LOCK_WAIT=0 validate
is "a hold ended: the next validation waits for nothing" "$status" 0
(cd "$work" && PATH="$work/bin:$PATH" "$repo/scripts/validate-and-push.sh" --hold -- sh -c "sleep 30 & echo \$! > '$work/hold/left'") > /dev/null 2>&1
left="$(cat "$work/hold/left")"
kill -0 "$left" 2>/dev/null && ok "a hold whose command left a process: it is still running" || fail "a hold: the process left behind is gone"
LOCK_WAIT=0 validate
is "a hold whose command left a process: the checkout is free" "$status" 0
kill "$left" 2>/dev/null
: > "$work/hold/marker"
(cd "$work" && PATH="$work/bin:$PATH" exec "$repo/scripts/validate-and-push.sh" --hold -- sh -c "echo \$\$ > '$work/hold/marker'; exec sleep 60") > "$work/hold/out" 2>&1 &
holding=$!
until_true reached "$work/hold/marker" || fail "a hold: its command never started: $(cat "$work/hold/out")"
held_pid="$(cat "$work/hold/marker")"
until_true test -s "$TOPO_VALIDATE_CACHE/slots/1/suite"
kill -KILL "$holding"; wait "$holding" 2>/dev/null
LOCK_WAIT=2 validate
is "a hold killed outright, its command still running: the next validation exits 2" "$status" 2
case "$out" in *"hold of an earlier validation is still running without its script, pid $held_pid"*) ok "a hold killed outright: its command is named as what is left" ;; *) fail "a hold killed outright: $out" ;; esac
is "a hold killed outright: no suite ran beside its command" "$(recorded suites)" ""
is "a run that died for an orphan: no ticket of it is left" "$(tickets)" ""
kill "$held_pid" 2>/dev/null
until_true eval "! kill -0 $held_pid 2>/dev/null"
LOCK_WAIT=5 validate
is "the command left behind ended: the next validation runs" "$status" 0
# From a worktree no validation would run in, detached and dirty: the command runs, and the
# tree, origin and the commit's statuses are as they were.
git -C "$repo" checkout -q --detach
echo dirt >> "$repo/scripts/ci-select-lane.sh"; echo x > "$repo/untracked"
tree() { git -C "$repo" status --porcelain; git -C "$repo" rev-parse HEAD; cat "$repo/scripts/ci-select-lane.sh" "$repo/untracked" | shasum; }
tree_before="$(tree)" origin_before="$(git -C "$work/hold/origin.git" for-each-ref)" posted_before="$(grep -c . "$GH_CALLS")"
(cd "$repo" && PATH="$work/bin:$PATH" scripts/validate-and-push.sh --hold -- sh -c "echo ran > '$work/hold/detached.ran'; exit 3") > "$work/hold/detached.out" 2>&1 && status=0 || status=$?
is "a hold from a detached, dirty worktree: the command's exit" "$status" 3
is "a hold from a detached, dirty worktree: the command ran" "$(cat "$work/hold/detached.ran" 2>/dev/null)" "ran"
is "a hold from a detached, dirty worktree: the tree is as it was, its files' contents too" "$(tree)" "$tree_before"
is "a hold from a detached, dirty worktree: origin is as it was" "$(git -C "$work/hold/origin.git" for-each-ref)" "$origin_before"
is "a hold from a detached, dirty worktree: nothing posted" "$(grep -c . "$GH_CALLS")" "$posted_before"
(cd "$repo" && PATH="$work/bin:$PATH" scripts/validate-and-push.sh) > "$work/hold/detached.out" 2>&1 && status=0 || status=$?
is "a validation from that worktree: refused" "$status" 2

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
