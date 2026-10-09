#!/usr/bin/env bash
# Holds scripts/validate-and-push.sh in scratch repositories with a bare `origin`, the real
# select scripts and workflow, a fake `gh` that logs every call, and a fake scripts/mac-suite.sh
# committed in the scratch repository, which records the commit and the files it was run in and
# answers as the case says. No suite runs, nothing leaves the machine.
#
# What it holds: the suites and the lane are the ones the commit's paths select; the suite runs
# in the validation worktree at exactly the commit, without the worktree's uncommitted or
# untracked files; a green run pushes that commit and then posts `success` for each suite to that
# commit and no other, with `local/real_ear` only beside a green `topo_ui` on the full lane; a
# red suite pushes nothing and posts nothing, unless origin's branch was already at the commit,
# when it posts what happened; a suite that wrote no result is a failure; a push origin refuses
# and a status GitHub refuses post nothing more and exit 2; --no-push refuses a commit origin's
# branch is not at before any suite runs; a held lock is waited on and then given up on; a suite an earlier
# run left going is not started beside; a suite with two results is red; a description keeps the
# logs' path; a head run again keeps the earlier run's logs, five runs a commit; and the
# `test` job is re-run, by job, only when the commit's newest run has concluded with it red.
#
#   scripts/tests/validate-and-push-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../.."
work="$(mktemp -d -t validate-and-push-test)"
trap 'rm -rf "$work"' EXIT

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
{ echo "head=$(git rev-parse HEAD)"; echo "lane=$lane"; echo "suites=${suites[*]}"; echo "files=$(ls | tr "\n" " ")"; echo "status=$(git status --porcelain | tr "\n" " ")"; } > "$FAKE_RECORD"
[ "${FAKE_SUITES-}" != died ] || exit 1
if [ "${FAKE_SUITES-}" = held ]; then
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
# validate [args] — runs the script in $repo; its output in $out, its exit in $status.
validate() {
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
export FAKE_HOLD="$work/signalled/hold"
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

# Another validation holds the Mac: waited on, then given up on, with no suite run.
scratch locked Apps/Client/SettingsView.swift
mkdir -p "$TOPO_VALIDATE_CACHE"
lockf -k "$TOPO_VALIDATE_CACHE/lock" sh -c "echo \$\$ > '$work/locked/held'; exec sleep 60" &
holder=$!
for _ in $(seq 100); do [ -s "$work/locked/held" ] && break; sleep 0.1; done
[ -s "$work/locked/held" ] || fail "locked: the holder never took the lock"
LOCK_WAIT=1 validate
is "locked: exits 2" "$status" 2
is "locked: no suite ran" "$(recorded head)" ""
is "locked: nothing pushed" "$(origin_head)" ""
kill "$(cat "$work/locked/held")" "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# A suite whose script was killed outright is still running with the lock free: the next run
# refuses to start beside it, from a session in another time zone and locale as from this one,
# and runs once it has gone. The record is the script's own, of the suite it started.
scratch orphan Apps/Client/SettingsView.swift
export FAKE_HOLD="$work/orphan/hold"
(cd "$repo" && PATH="$work/bin:$PATH" FAKE_SUITES=held exec scripts/validate-and-push.sh) > "$work/orphan/first.out" 2>&1 &
first=$!
for _ in $(seq 300); do [ -s "$FAKE_HOLD" ] && break; perl -e 'select(undef,undef,undef,0.1)'; done
orphan="$(cat "$FAKE_HOLD" 2>/dev/null)"
[ -n "$orphan" ] || fail "orphan suite: the first run's suite never started"
kill -KILL "$first"; wait "$first" 2>/dev/null
rm -f "$FAKE_RECORD"
validate
is "orphan suite: exits 2" "$status" 2
is "orphan suite: no suite ran" "$(recorded head)" ""
is "orphan suite: nothing pushed" "$(origin_head)" ""
case "$out" in *"kill $orphan"*) ok "orphan suite: names the pid to end" ;; *) fail "orphan suite: does not name pid $orphan: $out" ;; esac
TZ=Asia/Tokyo LC_ALL=en_GB.UTF-8 validate
is "orphan suite, from another zone and locale: exits 2" "$status" 2
: > "$FAKE_HOLD"
for _ in $(seq 100); do kill -0 "$orphan" 2>/dev/null || break; perl -e 'select(undef,undef,undef,0.1)'; done
validate
is "orphan gone: exits 0" "$status" 0
is "orphan gone: pushed" "$(origin_head)" "$sha"
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
[ ! -e "$TOPO_VALIDATE_CACHE/suite" ] && ok "a finished run leaves no suite on record" || fail "a finished run left $TOPO_VALIDATE_CACHE/suite"

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
