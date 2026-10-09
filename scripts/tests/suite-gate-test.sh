#!/usr/bin/env bash
# Holds .github/workflows/pr-validate.yaml's gate against the job list this test pins by name
# rather than one discovered from the file: the workflow has exactly `select`, `test` and the
# review jobs, every one on ubuntu-latest, and is started by a pull_request alone. `test` needs
# `select`, may read commit statuses and nothing else, and reads the PR's head commit, select's
# result, its three suite outputs and its lane; `codex_wait` and `codex` need `select` and `test`
# and spell out `needs.<job>.result == 'success'` for both, so a suite that did not pass on the
# Mac spends no reviewer round; `codex_wait` runs only on review_cap's `false`, for the cap and
# for `draft`, which `review_cap` reads from the API and no job takes from the event; and
# `reviewer_ran` and `review_gate` need `select`, `test` and the review jobs before them.
#
# Then it runs `test`'s step against a fake `gh` that answers the head's combined status: green
# only when every suite select said `true` for has a `success` status under `local/<suite>`, and
# `local/real_ear` beside `topo_ui` on any lane but `fast`; red at once on a `failure` or
# `error`; red after its wait on a status that is missing or `pending`, or a read that fails; a
# suite select said `false` for needs none; an output that is neither, a select that did not
# pass and a head that is not a commit are red without a read; and the status is asked of the
# head it was given, never another commit. And reviewer_ran's `Assert a verdict was produced and
# delivered`, with `select` and `test` each set in turn to every value other than `success`:
# each goes red naming the job. reviewer_ran passes on the review cap whatever `test` did, since
# `test` holds a red suite and review_gate the cap, fails on a draft first, and fails naming
# review_cap when the count itself failed. That is the snippets' reading of a result string, not
# a cancelled run: a run that is cancelled skips `test` (`!cancelled()`) and concludes cancelled,
# and automerge merges only on the latest pull_request run concluding `completed success`
# (.github/workflows/automerge.yaml).
#
#   scripts/tests/suite-gate-test.sh
#   WORKFLOW=/path/to/other/pr-validate.yaml scripts/tests/suite-gate-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="${WORKFLOW:-$here/../../.github/workflows/pr-validate.yaml}"
[ -f "$workflow" ] || { echo "no workflow at $workflow" >&2; exit 2; }

work="$(mktemp -d -t suite-gate-test)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

# The structural checks, and the snippets written out for the runs below.
ruby -ryaml - "$workflow" "$work" <<'RUBY' || failures=$((failures + 1))
path, work = ARGV
workflow = YAML.load_file(path)
jobs = workflow.fetch("jobs")
# The jobs by name, written out here rather than discovered, so a job deleted from the workflow
# is a difference and not a job that silently stops being checked.
suite = %w[select test]
review = %w[review_cap codex_wait codex post_feedback reviewer_ran review_gate]
# The suites select chooses among, which run on the Mac and reach `test` as statuses.
selectable = %w[topo_unit topo_ui others]
bad = 0
check = lambda do |ok, msg|
  if ok then puts "ok   #{msg}" else puts "FAIL #{msg}"; bad += 1 end
end
needs = ->(job) { Array(jobs.fetch(job)["needs"]) }
step = lambda do |job, name|
  jobs.fetch(job).fetch("steps").find { |s| s["name"] == name } or abort "no step #{name.inspect} in #{job}"
end
# SUITE_RESULTS is `job=${{ needs.job.result }}` pairs; anything else in it is a reading error.
PAIR = /(\w+)=(\$\{\{\s*needs\.(\w+)\.result\s*\}\})/
names_in = lambda do |results|
  rest = results.gsub(PAIR, "").strip
  check.(rest.empty?, "SUITE_RESULTS holds nothing but job=${{ needs.job.result }} pairs#{rest.empty? ? '' : " (left over: #{rest})"}")
  results.scan(PAIR).map { |job, _expr, read| [job, read] }
end

check.(jobs.keys.sort == (suite + review).sort, "the workflow's jobs are exactly #{(suite + review).join(', ')} (it has #{jobs.keys.join(', ')})")
# A macOS runner bills at ten times a Linux one: no job here is on one, and nothing but a
# pull_request starts a run.
hosts = jobs.map { |name, j| [name, j["runs-on"]] }.reject { |_, on| on == "ubuntu-latest" }
check.(hosts.empty?, "every job runs on ubuntu-latest#{hosts.empty? ? '' : " (not: #{hosts.map { |n, on| "#{n} on #{on}" }.join(', ')})"}")
triggers = workflow.fetch(true) { workflow.fetch("on") }
check.(triggers.keys == %w[pull_request], "only a pull_request starts a run (#{triggers.keys.join(', ')})")
conc = workflow.fetch("concurrency")
check.(conc["cancel-in-progress"] == true && conc["group"] == "pr-validate-${{ github.event.pull_request.number }}", "one run per PR, a superseded one cancelled (#{conc.inspect})")

check.(needs.("test") == %w[select], "test needs select (#{needs.('test').join(', ')})")
check.(jobs.fetch("test")["if"] == "${{ !cancelled() }}", "test runs unless the run is cancelled, a failed select included")
check.(jobs.fetch("test")["permissions"] == { "statuses" => "read" }, "test may read commit statuses and nothing else (#{jobs.fetch('test')['permissions'].inspect})")
gate = step.("test", "Require every suite passed on the Mac")
genv = gate.fetch("env")
check.(genv["HEAD_SHA"] == "${{ github.event.pull_request.head.sha }}", "test reads the PR's head commit, never the merge commit (#{genv['HEAD_SHA']})")
check.(genv["SELECT_RESULT"] == "${{ needs.select.result }}", "test reads select's result")
check.(genv["LANE"] == "${{ needs.select.outputs.lane }}", "test reads select's lane")
check.(genv.fetch("SELECTED", "").split.join(" ") == selectable.map { |j| "#{j}=${{ needs.select.outputs.#{j} }}" }.join(" "), "test's SELECTED reads select's output for exactly #{selectable.join(', ')}")
check.(jobs.fetch("select").fetch("outputs").values_at(*selectable) == selectable.map { |j| "${{ steps.suites.outputs.#{j} }}" }, "select outputs each suite from its suites step")
check.(jobs.fetch("select").fetch("outputs")["lane"] == "${{ steps.lane.outputs.lane }}", "select outputs the lane from its lane step")

check.(needs.("codex").sort == (suite + %w[codex_wait]).sort, "codex needs exactly #{suite.join(', ')} and codex_wait (#{needs.('codex').join(', ')})")
check.(needs.("codex_wait").sort == (suite + %w[review_cap]).sort, "codex_wait needs exactly #{suite.join(', ')} and review_cap (#{needs.('codex_wait').join(', ')})")
%w[reviewer_ran review_gate].each do |job|
  capped = jobs.fetch(job).fetch("steps").map { |s| s.dig("env", "CAPPED") }.compact
  check.(capped == ["${{ needs.review_cap.outputs.capped == 'true' || needs.post_feedback.outputs.capped == 'true' }}"], "#{job} reads the cap from review_cap and from post_feedback's recount (#{capped.inspect})")
end
check.(jobs.fetch("codex_wait").fetch("if").include?("needs.review_cap.outputs.capped == 'false' &&"), "codex_wait runs only on review_cap's false")
# Draft is review_cap's reading of the API as the run starts, never the event's: the run that
# survives a push and a ready a second apart can be the one whose payload still says draft.
cap = jobs.fetch("review_cap")
check.(cap.fetch("outputs")["draft"] == "${{ steps.draft.outputs.draft }}", "review_cap hands on the draft state its own step read")
check.(!cap.fetch("if").include?("draft"), "review_cap runs on a draft too, to read that it is one")
check.(cap.fetch("steps").first["id"] == "draft" && cap.fetch("steps").first.fetch("run").include?('gh api "repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER" --jq .draft'), "review_cap's first step reads draft from the API")
check.(cap.fetch("steps").drop(1).all? { |s| s["if"] == "steps.draft.outputs.draft == 'false'" }, "review_cap counts nothing on a draft")
check.(jobs.fetch("codex_wait").fetch("if").include?("needs.review_cap.outputs.draft == 'false' &&"), "codex_wait runs only on review_cap's draft false")
check.(jobs.fetch("codex").fetch("if").include?("needs.codex_wait.result == 'success' &&"), "codex runs only behind codex_wait, which holds a draft")
check.(jobs.fetch("post_feedback").fetch("if").start_with?("${{ !cancelled() && ") && jobs.fetch("post_feedback").fetch("if").include?("needs.codex.outputs.has_verdict == 'true'"), "post_feedback posts whenever codex gave a verdict")
payload = jobs.select { |_, j| [j["if"], *Array(j["steps"]).flat_map { |s| [s["if"], *(s["env"] || {}).values] }].compact.any? { |v| v.to_s.include?("pull_request.draft") } }.keys
check.(payload == %w[reviewer_ran], "only reviewer_ran reads the event's draft, as the fallback for a fork (#{payload.join(', ')})")
check.(step.("reviewer_ran", "Assert a verdict was produced and delivered").fetch("env")["IS_DRAFT"] == "${{ needs.review_cap.result == 'skipped' && github.event.pull_request.draft || needs.review_cap.outputs.draft }}", "reviewer_ran reads review_cap's draft, and the event's only where review_cap was skipped")
check.(needs.("reviewer_ran").sort == (suite + %w[review_cap codex post_feedback]).sort, "reviewer_ran needs exactly #{suite.join(', ')}, review_cap, codex and post_feedback (#{needs.('reviewer_ran').join(', ')})")
check.(needs.("review_gate").sort == (suite + %w[reviewer_ran review_cap codex post_feedback]).sort, "review_gate needs exactly #{suite.join(', ')}, reviewer_ran, review_cap, codex and post_feedback (#{needs.('review_gate').join(', ')})")

# The reviewer waits on a green `test`, spelled out: `!cancelled()` stands in for the implicit
# success(), so a result left unread would let a red suite spend a round.
{ "codex" => suite + %w[codex_wait], "codex_wait" => suite }.each do |job, waits|
  cif = jobs.fetch(job).fetch("if")
  read = cif.scan(/needs\.(\w+)\.result == 'success'/).flatten
  check.(read.sort == waits.sort, "#{job}'s if reads exactly #{waits.join(', ')} as success (#{read.join(', ')})")
  check.(!cif.include?("'skipped'"), "#{job}'s if takes no skipped job for a pass")
  check.(cif.start_with?("!cancelled() &&"), "#{job}'s if opens with !cancelled()")
end

ran = step.("reviewer_ran", "Assert a verdict was produced and delivered")
rpairs = names_in.(ran.fetch("env").fetch("SUITE_RESULTS"))
check.(rpairs.map(&:first).sort == suite.sort, "reviewer_ran's SUITE_RESULTS names exactly #{suite.join(', ')}")
rpairs.each { |job, read| check.(job == read, "reviewer_ran's SUITE_RESULTS reads #{job} from its own result") }

File.write(File.join(work, "gate.sh"), gate.fetch("run"))
File.write(File.join(work, "ran.sh"), ran.fetch("run"))
# review_cap's draft step, with the one expression in it set as the runner would.
File.write(File.join(work, "draft.sh"), cap.fetch("steps").first.fetch("run").gsub("${{ github.event.pull_request.draft }}", "true"))
File.write(File.join(work, "suite.txt"), suite.join("\n") + "\n")
exit(bad.zero? ? 0 : 1)
RUBY

[ -s "$work/gate.sh" ] && [ -s "$work/ran.sh" ] || { echo "the snippets were not extracted" >&2; exit 2; }
# The step's wait between reads, cut to a second, so a case that waits when it should not is a
# failure in seconds.
grep -q 'sleep 15$' "$work/gate.sh" || { echo "test's step no longer sleeps 15 between reads" >&2; exit 2; }
sed -e 's/sleep 15$/sleep 1/' "$work/gate.sh" > "$work/gate-quick.sh" && mv "$work/gate-quick.sh" "$work/gate.sh"
suite=()
while IFS= read -r job; do suite+=("$job"); done < "$work/suite.txt"

# results <failed job> <result> — the SUITE_RESULTS string with one job set to <result>.
results() {
  local bad="$1" result="$2" out="" job
  for job in "${suite[@]}"; do
    if [ "$job" = "$bad" ]; then out="$out $job=$result"; else out="$out $job=success"; fi
  done
  echo "${out# }"
}

# expect <want: pass|fail> <case> <match> <script> — runs a snippet with the environment given.
expect() {
  local want="$1" name="$2" match="$3" script="$4" out status
  out="$(bash -eo pipefail "$script" 2>&1)" && status=0 || status=$?
  if [ "$want" = pass ] && [ "$status" != 0 ]; then fail "$name: exited $status: $out"; return; fi
  if [ "$want" = fail ] && [ "$status" = 0 ]; then fail "$name: exited 0: $out"; return; fi
  if [ -n "$match" ] && ! grep -q -- "$match" <<<"$out"; then fail "$name: no '$match' in: $out"; return; fi
  echo "ok   $name"
}

# `test`'s step. The fake gh answers one call, the combined status of the head it is given, with
# FAKE_STATUSES as `context state` lines, and logs every call; anything else is exit 64.
mkdir -p "$work/gh"
cat > "$work/gh/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
[ "$1 $2" = "api repos/samdu/topo/commits/$FAKE_HEAD/status?per_page=100" ] || { echo "unexpected: $*" >&2; exit 64; }
[ "${FAKE_STATUSES-}" != fail ] || exit 1
printf '%s' "${FAKE_STATUSES-}"
GH
chmod +x "$work/gh/gh"
head_sha=0123456789abcdef0123456789abcdef01234567
all=$'local/topo_unit success\nlocal/topo_ui success\nlocal/others success\n'
# gate <want> <case> <match> — STATUS_WAIT is 0 unless a case sets it: one read, then the verdict.
gate() {
  : > "$work/gh.calls"
  PATH="$work/gh:$PATH" GH_CALLS="$work/gh.calls" GITHUB_REPOSITORY=samdu/topo GH_TOKEN=x \
    FAKE_HEAD="${FAKE_HEAD:-$head_sha}" HEAD_SHA="${HEAD_SHA-$head_sha}" SELECT_RESULT="${SELECT_RESULT-success}" \
    SELECTED="${SELECTED-topo_unit=true topo_ui=true others=true}" LANE="${LANE-fast}" SUITES_REASON="the reason" \
    STATUS_WAIT="${STATUS_WAIT:-0}" expect "$1" "test: $2" "$3" "$work/gate.sh"
}
unread() {  # the case before it made no call at all
  [ ! -s "$work/gh.calls" ] && echo "ok   test: $1 reads no status" || fail "test: $1 read a status: $(cat "$work/gh.calls")"
}

FAKE_STATUSES="$all" gate pass "every suite's status is success" "local/others: success on $head_sha"
for context in local/topo_unit local/topo_ui local/others; do
  for state in failure error; do
    FAKE_STATUSES="${all/$context success/$context $state}" STATUS_WAIT=4 \
      gate fail "$context is $state, red at once" "did not pass on the Mac.* $context ($state)"
    [ "$(wc -l < "$work/gh.calls")" -eq 1 ] && echo "ok   test: $context $state is not waited on" || fail "test: $context $state was read $(wc -l < "$work/gh.calls") times"
  done
  FAKE_STATUSES="${all/$context success/$context pending}" gate fail "$context is pending past the wait" "No passing status.* $context (pending)"
  FAKE_STATUSES="${all/$context success$'\n'/}" gate fail "$context has no status" "No passing status.* $context (no status)"
  # A status for another suite, or one whose name only begins the same, is not this suite's.
  FAKE_STATUSES="${all/$context success/${context}_old success}" gate fail "$context is not answered by ${context}_old" "$context (no status)"
done
FAKE_STATUSES="" gate fail "no status at all" "Run scripts/validate-and-push.sh"
FAKE_STATUSES=fail gate fail "a read that fails" "No passing status"
# The newest status of a context is the first the API lists; a later line is not read over it.
FAKE_STATUSES=$'local/topo_unit failure\nlocal/topo_unit success\nlocal/topo_ui success\nlocal/others success\n' \
  gate fail "the first status of a context is the one read" "local/topo_unit (failure)"

# The real ear: required beside topo_ui on any lane but fast.
for lane in full "" Fast; do
  LANE="$lane" FAKE_STATUSES="$all" gate fail "lane '${lane:-empty}' without the real ear's status" "local/real_ear (no status)"
  LANE="$lane" FAKE_STATUSES="${all}local/real_ear success"$'\n' gate pass "lane '${lane:-empty}' with the real ear's status" "local/real_ear: success"
done
LANE=full SELECTED="topo_unit=false topo_ui=false others=true" FAKE_STATUSES=$'local/others success\n' \
  gate pass "the full lane with topo_ui left out needs no real ear" ""

# Left out by select: no status is needed for it, and a status that is there and red is not read.
for suite_name in topo_unit topo_ui others; do
  off="topo_unit=true topo_ui=true others=true"; off="${off/$suite_name=true/$suite_name=false}"
  SELECTED="$off" FAKE_STATUSES="${all/local\/$suite_name success$'\n'/}" gate pass "$suite_name left out by select needs no status" "$suite_name: not needed by this PR's paths (the reason)"
  for sel in "${off/$suite_name=false/$suite_name=}" "${off/$suite_name=false/}" "${off/$suite_name=false/$suite_name=False}"; do
    SELECTED="$sel" FAKE_STATUSES="$all" gate fail "$suite_name with SELECTED='$sel'" "neither true nor false for $suite_name"
    unread "$suite_name with SELECTED='$sel'"
  done
done
SELECTED="topo_unit=false topo_ui=false others=false" FAKE_STATUSES=fail gate pass "every suite left out, as for a documentation change" "No suite is needed"
unread "every suite left out"

for result in failure cancelled skipped ""; do
  SELECT_RESULT="$result" FAKE_STATUSES="$all" gate fail "select result=${result:-empty}" "select did not pass"
  unread "select result=${result:-empty}"
done
for sha in "" "refs/pull/7/merge" "0123 4567"; do
  HEAD_SHA="$sha" FAKE_STATUSES="$all" gate fail "a head of '${sha:-nothing}'" "No PR head commit"
  unread "a head of '${sha:-nothing}'"
done
# The statuses are asked of the head it was given: another commit's are an unexpected call.
FAKE_HEAD=ffffffffffffffffffffffffffffffffffffffff FAKE_STATUSES="$all" gate fail "another commit's statuses are not this head's" "No passing status"
# A status that lands while it waits is read: the second read answers.
cat > "$work/gh/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_CALLS"
[ "$(wc -l < "$GH_CALLS")" -ge 2 ] && printf '%s' "$FAKE_STATUSES"
exit 0
GH
FAKE_STATUSES="$all" STATUS_WAIT=60 gate pass "a status posted while it waits" "local/topo_unit: success"
[ "$(wc -l < "$work/gh.calls")" -eq 2 ] && echo "ok   test: it read twice" || fail "test: it read $(wc -l < "$work/gh.calls") times"

export IS_DRAFT=false CAP_RESULT=success CAPPED=false CODEX_RESULT=success FEEDBACK_RESULT=success
SUITE_RESULTS="$(results none success)" expect pass "reviewer_ran: select and test succeeded" "The reviewer ran" "$work/ran.sh"
for job in "${suite[@]}"; do
  for result in failure cancelled skipped; do
    SUITE_RESULTS="$(results "$job" "$result")" CODEX_RESULT=skipped FEEDBACK_RESULT=skipped \
      expect fail "reviewer_ran: $job result=$result" "the suite did not pass.* $job ($result)" "$work/ran.sh"
  done
done

# The review cap: reviewer_ran passes, beside a red suite too, since `test` holds that; a draft is
# still a draft; a count that failed is no verdict, named as review_cap's.
CAPPED=true SUITE_RESULTS="$(results none success)" \
  expect pass "reviewer_ran: review cap reached" "review cap is reached" "$work/ran.sh"
CAPPED=true CODEX_RESULT=skipped FEEDBACK_RESULT=skipped SUITE_RESULTS="$(results test failure)" \
  expect pass "reviewer_ran: review cap reached beside a red suite" "review cap is reached" "$work/ran.sh"
IS_DRAFT=true CAPPED=true SUITE_RESULTS="$(results none success)" \
  expect fail "reviewer_ran: a capped draft is a draft" "this PR is a draft" "$work/ran.sh"
for cap in failure cancelled; do
  CAP_RESULT="$cap" CAPPED="" CODEX_RESULT=skipped FEEDBACK_RESULT=skipped SUITE_RESULTS="$(results none success)" \
    expect fail "reviewer_ran: review_cap $cap" "(review_cap: $cap)" "$work/ran.sh"
  # A review_cap that failed did not read the draft state: whatever IS_DRAFT holds, it is said as
  # the failed read it is, never as a draft.
  for draft in true ""; do
    IS_DRAFT="$draft" CAP_RESULT="$cap" CAPPED="" CODEX_RESULT=skipped FEEDBACK_RESULT=skipped SUITE_RESULTS="$(results none success)" \
      expect fail "reviewer_ran: review_cap $cap beside IS_DRAFT=${draft:-empty} is the failed read" "could not be read.*(review_cap: $cap)" "$work/ran.sh"
  done
done
for codex in failure cancelled skipped; do
  CODEX_RESULT="$codex" FEEDBACK_RESULT=skipped SUITE_RESULTS="$(results none success)" \
    expect fail "reviewer_ran: codex $codex beside a green suite" "the reviewer job did not complete (result: $codex)" "$work/ran.sh"
done

# review_cap's draft step writes what the API said, the event having said `true`, and fails on
# anything else, a `gh` that fails included.
mkdir -p "$work/bin"
printf '%s\n' '#!/usr/bin/env bash' '[ "$*" = "api repos/samdu/topo/pulls/7 --jq .draft" ] || { echo "unexpected: $*" >&2; exit 64; }' \
  '[ "$FAKE_DRAFT" = fail ] && exit 1' 'printf "%s\n" "$FAKE_DRAFT"' > "$work/bin/gh"
chmod +x "$work/bin/gh"
draft_step() {  # draft_step <what gh answers> — prints the step's GITHUB_OUTPUT, returns its status
  : > "$work/draft.out"
  PATH="$work/bin:$PATH" FAKE_DRAFT="$1" GITHUB_REPOSITORY=samdu/topo PR_NUMBER=7 GITHUB_OUTPUT="$work/draft.out" \
    bash "$work/draft.sh" >/dev/null 2>&1
  local status=$?
  cat "$work/draft.out"
  return "$status"
}
for said in true false; do
  if out="$(draft_step "$said")" && [ "$out" = "draft=$said" ]; then echo "ok   review_cap: the API's $said is the draft output"
  else fail "review_cap: the API said $said and the step wrote '$out'"; fi
done
for said in "" null "true false" fail; do
  out="$(draft_step "$said")"; status=$?
  if [ "$status" != 0 ] && [ -z "$out" ]; then echo "ok   review_cap: an API answer of '${said:-nothing}' fails the step and writes no output"
  else fail "review_cap: an API answer of '${said:-nothing}' exited $status and wrote '$out'"; fi
done

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
