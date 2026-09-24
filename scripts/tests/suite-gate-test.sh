#!/usr/bin/env bash
# Holds .github/workflows/pr-validate.yaml's gate against the job list this test pins by name —
# the suite jobs select, topo_unit, topo_ui and others, and the gate and review jobs — rather than
# one discovered from the file: the workflow has exactly those jobs; `test` needs and reads in its
# SUITE_RESULTS exactly the suite jobs; `codex` needs and spells out
# `needs.<job>.result == 'success'` for exactly the fast jobs (select, topo_unit, others), never
# `topo_ui` or `test`, so the review runs beside the UI tests; and `reviewer_ran` and
# `review_gate` need exactly the suite jobs, `test` and the review jobs before them, with
# reviewer_ran's SUITE_RESULTS naming exactly the suite jobs and `test`. Then
# it runs the two snippets that read those results — `test`'s `Require every suite job passed` and
# reviewer_ran's `Assert a verdict was produced and delivered` — with each job's result set in turn
# to every value other than `success` (failure, cancelled, skipped, and empty for `test`), and holds
# that each goes red naming the job, and that both pass only when every job succeeded. That is the
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
review = %w[test codex post_feedback reviewer_ran review_gate]
# What the reviewer waits on: the suite less the UI tests, which it runs beside.
fast = suite - %w[topo_ui]
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
check.(needs.("codex").sort == fast.sort, "codex needs exactly the fast jobs #{fast.join(', ')} (#{needs.('codex').join(', ')})")
check.(needs.("reviewer_ran").sort == (suite + %w[test codex post_feedback]).sort, "reviewer_ran needs exactly the suite jobs, test, codex and post_feedback (#{needs.('reviewer_ran').join(', ')})")
check.(needs.("review_gate").sort == (suite + %w[reviewer_ran test codex post_feedback]).sort, "review_gate needs exactly the suite jobs, reviewer_ran, test, codex and post_feedback (#{needs.('review_gate').join(', ')})")

gate = step.("test", "Require every suite job passed")
pairs = names_in.(gate.fetch("env").fetch("SUITE_RESULTS"))
check.(pairs.map(&:first).sort == suite.sort, "test's SUITE_RESULTS names exactly the suite jobs")
pairs.each { |job, read| check.(job == read, "test's SUITE_RESULTS reads #{job} from its own result") }

cif = jobs.fetch("codex").fetch("if")
read = cif.scan(/needs\.(\w+)\.result == 'success'/).flatten
check.(read.sort == fast.sort, "codex's if reads exactly the fast jobs (#{read.join(', ')})")
fast.each do |job|
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

SUITE_RESULTS="$(results none success)" expect pass "test: every suite job succeeded" "" "$work/gate.sh"
for job in "${suite[@]}"; do
  for result in failure cancelled skipped ""; do
    SUITE_RESULTS="$(results "$job" "$result")" \
      expect fail "test: $job result=${result:-empty}" "$job did not pass" "$work/gate.sh"
  done
done

export IS_DRAFT=false CODEX_RESULT=success FEEDBACK_RESULT=success
SUITE_RESULTS="$(results none success test)" expect pass "reviewer_ran: every suite job succeeded" "" "$work/ran.sh"
for job in "${suite[@]}" test; do
  for result in failure cancelled skipped; do
    SUITE_RESULTS="$(results "$job" "$result" test)" \
      expect fail "reviewer_ran: $job result=$result" "the suite did not pass.* $job ($result)" "$work/ran.sh"
  done
done

if [ "$failures" -ne 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
