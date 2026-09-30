#!/usr/bin/env bash
# Holds .github/workflows/pr-validate.yaml's gate against the job list this test pins by name —
# the suite jobs select, topo_unit, topo_ui and others, and the gate and review jobs — rather than
# one discovered from the file: the workflow has exactly those jobs; `test` needs and reads in its
# SUITE_RESULTS exactly the suite jobs; `codex` needs and spells out
# `needs.<job>.result == 'success'` for exactly the fast jobs (select, topo_unit, others) and
# `codex_wait`, never `topo_ui` or `test`, so the review runs beside the UI tests; `codex_wait`
# needs the fast jobs and `review_cap` and runs only on its `false`; and `reviewer_ran` and
# `review_gate` need exactly the suite jobs, `test` and the review jobs before them, with
# reviewer_ran's SUITE_RESULTS naming exactly the suite jobs and `test`. The three selectable
# jobs (topo_unit, topo_ui, others) each need select and run only on its `true` for them; `test`
# and reviewer_ran read select's three outputs in SELECTED; and `codex` and `codex_wait` open with
# `!cancelled()` and take a fast job's `skipped` only beside select's `false` for it. Then
# it runs the two snippets that read those results — `test`'s `Require every suite job passed` and
# reviewer_ran's `Assert a verdict was produced and delivered` — with each job's result set in turn
# to every value other than `success` (failure, cancelled, skipped, and empty for `test`), and holds
# that each goes red naming the job, and that both pass only when every job succeeded or was
# skipped with select's `false` for it: a skip beside `true`, an empty output or no output at all
# (select failed), and a failure beside `false`, each stay red. reviewer_ran passes on the review
# cap whatever the suite did, since `test` holds a red suite and review_gate the cap, fails on a
# draft first, and fails naming review_cap when the count itself failed. That is the
# snippets' reading of a result string, not a cancelled run: a run that is cancelled skips `test`
# (`!cancelled()`) and concludes cancelled, and automerge merges only on the latest pull_request
# run concluding `completed success` (.github/workflows/automerge.yaml). So a suite job added without being wired into the gate, or a gate snippet
# that reads one job fewer, turns this red.
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

# The structural checks, and the two snippets written out for the runs below.
ruby -ryaml - "$workflow" "$work" <<'RUBY' || failures=$((failures + 1))
path, work = ARGV
jobs = YAML.load_file(path).fetch("jobs")
# The jobs by name, written out here rather than discovered, so a suite job deleted from the
# workflow is a difference and not a job that silently stops being checked.
suite = %w[select topo_unit topo_ui others]
review = %w[test review_cap codex_wait codex post_feedback reviewer_ran review_gate]
# What the reviewer waits on: the suite less the UI tests, which it runs beside.
fast = suite - %w[topo_ui]
# The jobs select may leave out.
selectable = suite - %w[select]
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
check.(needs.("test").sort == suite.sort, "test needs exactly the suite jobs (#{needs.('test').join(', ')})")
check.(needs.("codex").sort == (fast + %w[codex_wait]).sort, "codex needs exactly the fast jobs #{fast.join(', ')} and codex_wait (#{needs.('codex').join(', ')})")
check.(needs.("codex_wait").sort == (fast + %w[review_cap]).sort, "codex_wait needs exactly the fast jobs #{fast.join(', ')} and review_cap (#{needs.('codex_wait').join(', ')})")
%w[reviewer_ran review_gate].each do |job|
  capped = jobs.fetch(job).fetch("steps").map { |s| s.dig("env", "CAPPED") }.compact
  check.(capped == ["${{ needs.review_cap.outputs.capped == 'true' || needs.post_feedback.outputs.capped == 'true' }}"], "#{job} reads the cap from review_cap and from post_feedback's recount (#{capped.inspect})")
end
check.(jobs.fetch("codex_wait").fetch("if").include?("needs.review_cap.outputs.capped == 'false' &&"), "codex_wait runs only on review_cap's false")
check.(needs.("reviewer_ran").sort == (suite + %w[test review_cap codex post_feedback]).sort, "reviewer_ran needs exactly the suite jobs, test, review_cap, codex and post_feedback (#{needs.('reviewer_ran').join(', ')})")
check.(needs.("review_gate").sort == (suite + %w[reviewer_ran test review_cap codex post_feedback]).sort, "review_gate needs exactly the suite jobs, reviewer_ran, test, review_cap, codex and post_feedback (#{needs.('review_gate').join(', ')})")

selectable.each do |job|
  check.(needs.(job) == %w[select], "#{job} needs select (#{needs.(job).join(', ')})")
  check.(jobs.fetch(job)["if"] == "needs.select.outputs.#{job} == 'true'", "#{job} runs only on select's true for it (#{jobs.fetch(job)['if'].inspect})")
end
check.(jobs.fetch("select").fetch("outputs").values_at(*selectable) == selectable.map { |j| "${{ steps.suites.outputs.#{j} }}" }, "select outputs each selectable job from its suites step")
# SELECTED is `job=${{ needs.select.outputs.job }}` for exactly the selectable jobs.
selected_ok = lambda do |job, name|
  sel = step.(job, name).fetch("env").fetch("SELECTED", "")
  want = selectable.map { |j| "#{j}=${{ needs.select.outputs.#{j} }}" }
  check.(sel.split.join(" ") == want.join(" "), "#{job}'s SELECTED reads select's output for exactly #{selectable.join(', ')} (#{sel.strip})")
end
selected_ok.("test", "Require every suite job passed")
selected_ok.("reviewer_ran", "Assert a verdict was produced and delivered")
%w[codex codex_wait].each do |job|
  cif = jobs.fetch(job).fetch("if")
  (fast - %w[select]).each do |f|
    alt = "(needs.#{f}.result == 'success' || (needs.#{f}.result == 'skipped' && needs.select.outputs.#{f} == 'false'))"
    check.(cif.include?(alt), "#{job}'s if takes #{f} skipped only beside select's false for it")
  end
  check.(cif.scan(/'skipped'/).size == (fast - %w[select]).size, "#{job}'s if reads skipped for nothing else")
  # Without a status function the implicit success() skips the job beside a skipped prerequisite.
  check.(cif.start_with?("!cancelled() &&"), "#{job}'s if opens with !cancelled(), so a skipped fast job does not skip it")
end

gate = step.("test", "Require every suite job passed")
pairs = names_in.(gate.fetch("env").fetch("SUITE_RESULTS"))
check.(pairs.map(&:first).sort == suite.sort, "test's SUITE_RESULTS names exactly the suite jobs")
pairs.each { |job, read| check.(job == read, "test's SUITE_RESULTS reads #{job} from its own result") }

cif = jobs.fetch("codex").fetch("if")
read = cif.scan(/needs\.(\w+)\.result == 'success'/).flatten
check.(read.sort == (fast + %w[codex_wait]).sort, "codex's if reads exactly the fast jobs and codex_wait (#{read.join(', ')})")
(fast + %w[codex_wait]).each do |job|
  check.(cif.include?("needs.#{job}.result == 'success'"), "codex's if spells out needs.#{job}.result == 'success'")
end
(suite + ["test"]).each do |job|
  check.(needs.("reviewer_ran").include?(job), "reviewer_ran needs #{job}")
  check.(needs.("review_gate").include?(job), "review_gate needs #{job}")
end

ran = step.("reviewer_ran", "Assert a verdict was produced and delivered")
rpairs = names_in.(ran.fetch("env").fetch("SUITE_RESULTS"))
check.(rpairs.map(&:first).sort == (suite + ["test"]).sort, "reviewer_ran's SUITE_RESULTS names the suite jobs and test")
rpairs.each { |job, read| check.(job == read, "reviewer_ran's SUITE_RESULTS reads #{job} from its own result") }

File.write(File.join(work, "gate.sh"), gate.fetch("run"))
File.write(File.join(work, "ran.sh"), ran.fetch("run"))
File.write(File.join(work, "suite.txt"), suite.join("\n") + "\n")
exit(bad.zero? ? 0 : 1)
RUBY

[ -s "$work/gate.sh" ] && [ -s "$work/ran.sh" ] || { echo "the snippets were not extracted" >&2; exit 2; }
suite=()
while IFS= read -r job; do suite+=("$job"); done < "$work/suite.txt"

# results <failed job> <result> [extra job] — the SUITE_RESULTS string with one job set to <result>.
results() {
  local bad="$1" result="$2" out="" job
  shift 2
  for job in "${suite[@]}" "$@"; do
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

# Every suite selected unless a case says otherwise.
export SELECTED="topo_unit=true topo_ui=true others=true" SUITES_REASON="the reason"
SUITE_RESULTS="$(results none success)" expect pass "test: every suite job succeeded" "" "$work/gate.sh"
for job in "${suite[@]}"; do
  for result in failure cancelled skipped ""; do
    SUITE_RESULTS="$(results "$job" "$result")" \
      expect fail "test: $job result=${result:-empty}" "$job did not pass" "$work/gate.sh"
  done
done

export IS_DRAFT=false CAP_RESULT=success CAPPED=false CODEX_RESULT=success FEEDBACK_RESULT=success
SUITE_RESULTS="$(results none success test)" expect pass "reviewer_ran: every suite job succeeded" "" "$work/ran.sh"
for job in "${suite[@]}" test; do
  for result in failure cancelled skipped; do
    SUITE_RESULTS="$(results "$job" "$result" test)" \
      expect fail "reviewer_ran: $job result=$result" "the suite did not pass.* $job ($result)" "$work/ran.sh"
  done
done
# A red suite says whether a verdict was posted anyway: topo_ui runs beside the reviewer.
SUITE_RESULTS="$(results topo_ui failure test)" \
  expect fail "reviewer_ran: red suite, verdict posted" "its verdict is posted on the PR" "$work/ran.sh"
for feedback in skipped failure cancelled; do
  SUITE_RESULTS="$(results topo_ui failure test)" FEEDBACK_RESULT="$feedback" \
    expect fail "reviewer_ran: red suite, post_feedback $feedback" "no review verdict was posted.*post_feedback: $feedback" "$work/ran.sh"
done

# The review cap: reviewer_ran passes, beside a red suite too, since `test` holds that; a draft is
# still a draft; a count that failed is no verdict, named as review_cap's.
CAPPED=true SUITE_RESULTS="$(results none success test)" \
  expect pass "reviewer_ran: review cap reached" "review cap is reached" "$work/ran.sh"
CAPPED=true CODEX_RESULT=skipped FEEDBACK_RESULT=skipped SUITE_RESULTS="$(results topo_ui failure test)" \
  expect pass "reviewer_ran: review cap reached beside a red suite" "review cap is reached" "$work/ran.sh"
IS_DRAFT=true CAPPED=true SUITE_RESULTS="$(results none success test)" \
  expect fail "reviewer_ran: a capped draft is a draft" "this PR is a draft" "$work/ran.sh"
for cap in failure cancelled; do
  CAP_RESULT="$cap" CAPPED="" CODEX_RESULT=skipped FEEDBACK_RESULT=skipped SUITE_RESULTS="$(results none success test)" \
    expect fail "reviewer_ran: review_cap $cap" "(review_cap: $cap)" "$work/ran.sh"
done

# Left out by select: a skip beside `false` passes both snippets, and nothing else does.
for job in topo_unit topo_ui others; do
  off="${SELECTED/$job=true/$job=false}"
  SELECTED="$off" SUITE_RESULTS="$(results "$job" skipped)" \
    expect pass "test: $job skipped beside select's false" "$job: skipped by selection (the reason)" "$work/gate.sh"
  SELECTED="$off" SUITE_RESULTS="$(results "$job" skipped test)" \
    expect pass "reviewer_ran: $job skipped beside select's false" "The reviewer ran" "$work/ran.sh"
  for result in failure cancelled ""; do
    SELECTED="$off" SUITE_RESULTS="$(results "$job" "$result")" \
      expect fail "test: $job result=${result:-empty} beside select's false" "$job did not pass" "$work/gate.sh"
  done
  SELECTED="$off" SUITE_RESULTS="$(results "$job" failure test)" \
    expect fail "reviewer_ran: $job failure beside select's false" "the suite did not pass.* $job (failure)" "$work/ran.sh"
  for sel in "${SELECTED/$job=true/$job=}" "" "${SELECTED/$job=true/$job=False}"; do
    SELECTED="$sel" SUITE_RESULTS="$(results "$job" skipped)" \
      expect fail "test: $job skipped with SELECTED='$sel'" "$job did not pass" "$work/gate.sh"
    SELECTED="$sel" SUITE_RESULTS="$(results "$job" skipped test)" \
      expect fail "reviewer_ran: $job skipped with SELECTED='$sel'" "the suite did not pass.* $job (skipped)" "$work/ran.sh"
  done
done
# Every suite left out, as for a documentation change: both pass.
SELECTED="topo_unit=false topo_ui=false others=false" \
  SUITE_RESULTS="select=success topo_unit=skipped topo_ui=skipped others=skipped" \
  expect pass "test: every suite skipped beside select's false" "" "$work/gate.sh"
SELECTED="topo_unit=false topo_ui=false others=false" \
  SUITE_RESULTS="select=success topo_unit=skipped topo_ui=skipped others=skipped test=success" \
  expect pass "reviewer_ran: every suite skipped beside select's false" "" "$work/ran.sh"
# select's own skip is never read as a selection, whatever SELECTED says.
SELECTED="select=false topo_unit=false topo_ui=false others=false" SUITE_RESULTS="$(results select skipped test)" \
  expect fail "reviewer_ran: select skipped" "the suite did not pass.* select (skipped)" "$work/ran.sh"
SELECTED="select=false topo_unit=false topo_ui=false others=false" SUITE_RESULTS="$(results select skipped)" \
  expect fail "test: select skipped" "select did not pass" "$work/gate.sh"

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
