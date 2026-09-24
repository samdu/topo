#!/usr/bin/env bash
# Runs the review path's own shell out of .github/workflows/pr-validate.yaml — the `codex` job's
# `Sanitise the verdict` step and `review_gate`'s `Enforce the review verdict` step, extracted by
# step name rather than copied, so a break in the workflow's snippets turns this red — against
# fake verdicts carrying a fake secret's value. It holds that no secret value survives into the
# file that is uploaded, that sanitising changes nothing the gate decides, and that every way the
# file can be absent or unusable fails closed. No network, no runner, no real secret: every value
# here is invented.
#
#   scripts/tests/review-verdict-test.sh
#   WORKFLOW=/path/to/other/pr-validate.yaml scripts/tests/review-verdict-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workflow="${WORKFLOW:-$here/../../.github/workflows/pr-validate.yaml}"
[ -f "$workflow" ] || { echo "no workflow at $workflow" >&2; exit 2; }

work="$(mktemp -d -t review-verdict-test)"
trap 'rm -rf "$work"' EXIT

# The values the fake secrets hold. Invented strings, long enough that nothing else in a verdict
# can contain one by accident.
FAKE_AUTH='fake-codex-auth-7f3a9c11'
FAKE_TS_SECRET='fake-tailscale-secret-2b4d8e60'

# extract <step name> — the dedented body of that step's `run: |` block, by indentation.
extract() {
  python3 - "$workflow" "$1" <<'PY'
import sys

path, name = sys.argv[1:3]
lines = open(path).read().split("\n")

start = indent = None
for i, line in enumerate(lines):
    if line.strip() == "- name: " + name:
        start, indent = i, len(line) - len(line.lstrip())
        break
if start is None:
    sys.exit("no step named %r in %s" % (name, path))

body = []
for line in lines[start + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) <= indent:
        break
    body.append(line)

run = run_indent = None
for j, line in enumerate(body):
    if line.strip() == "run: |":
        run, run_indent = j, len(line) - len(line.lstrip())
        break
if run is None:
    sys.exit("step %r has no `run: |` block" % name)

out = []
for line in body[run + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) <= run_indent:
        break
    out.append(line[run_indent + 2:] if line.strip() else "")
sys.stdout.write("\n".join(out).rstrip() + "\n")
PY
}

extract "Sanitise the verdict" > "$work/sanitise.sh" || exit 2
extract "Enforce the review verdict" > "$work/gate.sh" || exit 2
[ -s "$work/sanitise.sh" ] && [ -s "$work/gate.sh" ] || { echo "extracted an empty snippet" >&2; exit 2; }

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }

# sanitise <case> <scoped file> — runs the sanitise snippet with the fake secrets in the
# environment, leaving the verdict at $work/<case>/verdict.json and has_verdict in $has_verdict.
sanitise() {
  local name="$1" scoped="$2"
  rm -rf "${work:?}/$name"
  CODEX_AUTH_JSON="$FAKE_AUTH" \
  TS_OAUTH_CLIENT_ID='' \
  TS_OAUTH_SECRET="$FAKE_TS_SECRET" \
  GITHUB_TOKEN='' \
  SCOPED_PATH="$scoped" \
  VERDICT_OUT="$work/$name/verdict.json" \
  GITHUB_OUTPUT="$work/$name.output" \
    bash "$work/sanitise.sh" > "$work/$name.log" 2>&1
  local status=$?
  if [ "$status" != 0 ]; then
    fail "$name: the sanitise step exited $status"
    sed 's/^/    | /' "$work/$name.log"
    return 1
  fi
  has_verdict="$(sed -n 's/^has_verdict=//p' "$work/$name.output" | tail -1)"
  return 0
}

# read_outputs <file> — parses a GITHUB_OUTPUT file the way the runner does: `name=value` on
# one line, or `name<<DELIM` opening a block that runs to the line that is exactly DELIM, and
# nothing else. Leaves the values in $gate_state and $gate_summary; fails on a line the runner
# would refuse (which is how `summary=` with a newline in it, or a block whose delimiter the
# summary itself contains, failed the step on the runner).
read_outputs() {
  local file="$1" line delim
  gate_state="" gate_summary=""
  exec 3< "$file"
  while IFS= read -r line <&3; do
    case "$line" in
      state=*) gate_state="${line#state=}" ;;
      summary\<\<*)
        delim="${line#summary<<}"
        gate_summary=""
        while IFS= read -r line <&3; do
          [ "$line" = "$delim" ] && break
          gate_summary="${gate_summary}${line}"$'\n'
        done
        [ "$line" = "$delim" ] || { exec 3<&-; echo "unterminated summary block" >&2; return 1; }
        gate_summary="${gate_summary%$'\n'}"
        ;;
      *) exec 3<&-; echo "line the runner would refuse: $line" >&2; return 1 ;;
    esac
  done
  exec 3<&-
}

# gate <case> <has_verdict> <verdict file> <expected: pass|block> [summary] — runs the gate
# snippet as review_gate does after a successful reviewer job, leaving its state in $gate_state,
# and holds the recorded summary to the fifth argument when one is given.
gate() {
  local name="$1" flag="$2" file="$3" want="$4" got
  PRECHECK_RESULT=success CODEX_RESULT=success HAS_VERDICT="$flag" VERDICT_FILE="$file" \
  GITHUB_OUTPUT="$work/$name.gate-output" \
    bash "$work/gate.sh" > "$work/$name.gate.log" 2>&1
  local status=$?
  if ! read_outputs "$work/$name.gate-output" 2> "$work/$name.outputs.err"; then
    fail "$name: the gate wrote an output file the runner would refuse: $(cat "$work/$name.outputs.err")"
    sed 's/^/    | /' "$work/$name.gate-output"
    return 1
  fi
  if [ "$status" = 0 ]; then got=pass; else got=block; fi
  if [ "$got" != "$want" ]; then
    fail "$name: wanted the gate to $want, it exited $status ($got)"
    sed 's/^/    | /' "$work/$name.gate.log"
    return 1
  fi
  if [ "$gate_state" != "$want" ]; then
    fail "$name: the gate exited as wanted but recorded state=$gate_state for the status pane"
    return 1
  fi
  if [ $# -ge 5 ] && [ "$gate_summary" != "$5" ]; then
    fail "$name: the gate recorded a summary other than the verdict's"
    printf '    | wanted: %q\n    | got:    %q\n' "$5" "$gate_summary"
    return 1
  fi
  echo "ok   $name: gate $got"
  return 0
}

# A blocking verdict whose summary, kept finding and demoted finding each quote a secret's value,
# as a reviewer told about the status pane and reading the runner's environment could.
cat > "$work/blocking-scoped.json" <<EOF
{"blocking": true, "codex_blocking": true,
 "summary": "The run logs in with $FAKE_AUTH, which the diff prints.",
 "findings": ["Apps/Client/Ear.swift:12 leaks $FAKE_TS_SECRET on every press.",
              "Apps/Client/Voice.swift:40 drops the last sentence."],
 "demoted": ["scripts/old.sh:3 still holds $FAKE_AUTH."]}
EOF

# The same shape, not blocking, with a secret's value in the summary only.
cat > "$work/passing-scoped.json" <<EOF
{"blocking": false, "codex_blocking": false,
 "summary": "Nothing blocking. The status feed is reached with $FAKE_TS_SECRET.",
 "findings": [], "demoted": []}
EOF

# A reviewer that answered in prose: not a verdict at all, and it quotes a secret too.
printf 'I could not read the diff. The login was %s.\n' "$FAKE_AUTH" > "$work/prose-scoped.json"

if sanitise blocking "$work/blocking-scoped.json"; then
  out="$work/blocking/verdict.json"
  if grep -qF "$FAKE_AUTH" "$out" || grep -qF "$FAKE_TS_SECRET" "$out"; then
    fail "blocking-sanitised: a secret's value survived into the uploaded file"
  elif ! jq -e . "$out" >/dev/null 2>&1; then
    fail "blocking-sanitised: the sanitised verdict is not valid JSON"
  elif [ "$(jq -r '[.summary, .findings[], .demoted[]] | map(select(contains("***"))) | length' "$out")" != 3 ]; then
    fail "blocking-sanitised: expected the three text fields that quoted a secret to carry ***"
  elif [ "$(jq -r '.blocking, .codex_blocking, (.findings | length), (.demoted | length)' "$out" | tr '\n' ' ')" != "true true 2 1 " ]; then
    fail "blocking-sanitised: the structural fields changed: $(jq -c '{blocking, codex_blocking, findings, demoted}' "$out")"
  elif [ "$has_verdict" != true ]; then
    fail "blocking-sanitised: has_verdict=$has_verdict for a verdict that is valid JSON"
  else
    echo "ok   blocking-sanitised: no secret value, valid JSON, blocking and the finding split unchanged"
  fi
  gate blocking-gate-sanitised true "$out" block
  # The same decision on what the scoping step wrote, so sanitising is not what makes it block.
  gate blocking-gate-unsanitised true "$work/blocking-scoped.json" block
fi

if sanitise passing "$work/passing-scoped.json"; then
  out="$work/passing/verdict.json"
  if grep -qF "$FAKE_TS_SECRET" "$out"; then
    fail "passing-sanitised: a secret's value survived into the uploaded file"
  elif [ "$(jq -r '.blocking' "$out")" != false ] || [ "$has_verdict" != true ]; then
    fail "passing-sanitised: blocking=$(jq -r '.blocking' "$out") has_verdict=$has_verdict"
  else
    echo "ok   passing-sanitised: no secret value, still not blocking"
  fi
  gate passing-gate-sanitised true "$out" pass
  gate passing-gate-unsanitised true "$work/passing-scoped.json" pass
fi

if sanitise prose "$work/prose-scoped.json"; then
  out="$work/prose/verdict.json"
  if grep -qF "$FAKE_AUTH" "$out"; then
    fail "prose-sanitised: a secret's value survived into a verdict that was not JSON"
  elif [ "$has_verdict" != false ]; then
    fail "prose-sanitised: has_verdict=$has_verdict for an answer that is not a verdict"
  else
    echo "ok   prose-sanitised: no secret value, has_verdict false"
  fi
fi

# A re-review's summary is several lines (its list of earlier findings), and one of them is the
# very line a fixed block delimiter would be, so the recorded summary has to survive both intact.
multiline=$'Nothing blocking.\nTOPO_SUMMARY_EOF\n1. Ear.swift:12 — closed by 0a38fbb.\n2. Voice.swift:40 — moot.'
jq -n --arg s "$multiline" '{blocking: false, codex_blocking: false, summary: $s, findings: [], demoted: []}' > "$work/multiline.json"
gate multiline-summary true "$work/multiline.json" pass "$multiline"

# has_verdict true and no file: the artifact never arrived, which is no verdict, not a pass.
gate no-file true "$work/absent/verdict.json" block
# has_verdict true and an empty file: the same.
: > "$work/empty.json"
gate empty-file true "$work/empty.json" block
# has_verdict false: the gate downloads nothing and fails closed, as an empty output does.
gate no-flag false "$work/blocking/verdict.json" block

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed against $workflow"
  exit 1
fi
echo "all cases held against $workflow"
