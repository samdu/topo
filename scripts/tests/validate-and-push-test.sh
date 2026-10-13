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
#   scripts/tests/validate-and-push-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../.."
work="$(mktemp -d -t validate-and-push-test)"
trap 'rm -rf "$work"' EXIT

# What a session running this may have set for its own run is not this test's: every case
# names what it means. A wait no case bounds is a minute, so a lock left held fails a case
# and does not hang the test.
unset TOPO_VALIDATE_SLOTS TOPO_VALIDATE_REPO TOPO_VALIDATE_CACHE TOPO_VALIDATE_LOGS POST_RETRY \
  FAKE_SUITES FAKE_HOLD FAKE_HOLD_SUITE FAKE_LEAVE FAKE_POST FAKE_RUN FAKE_TEST_JOB
export LOCK_WAIT=60 LOCK_POLL=1

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

# The fake suite: records where it ran, then writes FAKE_SUITES' lines (`topo_unit=failure …`;
# a suite it does not name succeeded) unless FAKE_SUITES is `died`.
fake_suite='#!/usr/bin/env bash
results=""; suites=()
while [ $# -gt 0 ]; do
  case "$1" in --lane) lane="$2"; shift 2 ;; --results) results="$2"; shift 2 ;; --cache) shift 2 ;; *) suites+=("$1"); shift ;; esac
done
: > "$results/suites.txt"   # as the suite itself starts its results afresh, each call
before="$(sed -n "s/^suites=//p" "$FAKE_RECORD" 2>/dev/null)"
{ echo "head=$(git rev-parse HEAD)"; echo "lane=$lane"; echo "suites=$before${before:+ }${suites[*]}"; echo "checkout=$(pwd -P)"; echo "files=$(ls | tr "\n" " ")"; echo "status=$(git status --porcelain | tr "\n" " ")"; } > "$FAKE_RECORD.new"
mv -f "$FAKE_RECORD.new" "$FAKE_RECORD"
[ "${FAKE_SUITES-}" != died ] || exit 1
# Left running after the suite, with whatever descriptors the suite was given.
[ -z "${FAKE_LEAVE-}" ] || { nohup perl -e "sleep 60" > /dev/null 2>&1 & echo $! > "$FAKE_LEAVE"; }
# Held in every suite, or in the one FAKE_HOLD_SUITE names, for as long as the marker has its pid.
if [ "${FAKE_SUITES-}" = held ] && case "${FAKE_HOLD_SUITE-}" in "" | "${suites[0]}") true ;; *) false ;; esac; then
  echo $$ > "$FAKE_HOLD"
  while [ -s "$FAKE_HOLD" ]; do perl -e "select(undef,undef,undef,0.1)"; done
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
  export GH_CALLS="$work/$name/gh.calls" FAKE_ORIGIN="$work/$name/origin.git" FAKE_RECORD="$work/$name/record" \
    TOPO_VALIDATE_CACHE="$work/$name/cache" TOPO_VALIDATE_LOGS="$work/$name/logs"
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
# A run still going keeps its logs however many runs of its commit have begun since.
scratch sameprune Apps/Client/SettingsView.swift
begin "$repo" "$work/sameprune/first" "$work/sameprune/first.hold" FAKE_HOLD_SUITE=topo_unit
first=$run
live="$(ls -1 "$TOPO_VALIDATE_LOGS/$sha")"
for n in 1 2 3 4 5; do mkdir -p "$TOPO_VALIDATE_LOGS/$sha/2999010${n}T000000Z-1"; done
out="$(cd "$repo" && PATH="$work/bin:$PATH" FAKE_RECORD="$work/sameprune/second" scripts/validate-and-push.sh --suites others 2>&1)" && status=0 || status=$?
is "a sixth run of a commit beside a live one: exits 0" "$status" 0
[ -d "$TOPO_VALIDATE_LOGS/$sha/$live" ] && ok "a sixth run of a commit beside a live one: the live run's logs are kept" || fail "a sixth run of a commit removed the logs of one still going"
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
echo $$ > "$TOPO_VALIDATE_LOGS/10000000/20200101T000000Z-1/running"
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

# main is never pushed from here, and a detached HEAD has no branch to push to.
scratch main docs/design.md
git -C "$repo" checkout -q main
validate
is "on main: exits 2" "$status" 2
git -C "$repo" checkout -q --detach topic
validate
is "detached: exits 2" "$status" 2

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
