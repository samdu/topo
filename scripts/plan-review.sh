#!/usr/bin/env bash
# Plan review: Codex (Astra) answers "should it be built this way?" over a
# plan the Topo PM wrote, before any code exists. docs/process.md, step 2.
#
#   scripts/plan-review.sh <plan.md> [context-dir]
#
# Runs on buddybox, where `codex` is logged in. The sandbox is read-only and
# rooted at the context dir: this checkout plus whatever the dir links in
# (the curated memory-wiki slice lives at ~/topo-plan-context on buddybox —
# design pages, not people pages; grow it when a review asks for something it
# did not have). Output is JSON on stdout: {red_lines, suggestions, summary}.
# Red lines are "do not build it this way" and go to Sam if the PM disagrees;
# suggestions the PM takes or leaves.
set -euo pipefail

plan="${1:?plan file}"
ctx="${2:-$HOME/topo-plan-context}"
model="${CODEX_PLAN_MODEL:-gpt-6-astra}"

schema="$(mktemp)"; out="$(mktemp)"; trap 'rm -f "$schema" "$out"' EXIT
cat > "$schema" <<'JSON'
{"type":"object","additionalProperties":false,
 "properties":{"red_lines":{"type":"array","items":{"type":"string"}},
               "suggestions":{"type":"array","items":{"type":"string"}},
               "summary":{"type":"string"}},
 "required":["red_lines","suggestions","summary"]}
JSON

{
  cat <<'PROMPT'
You are reviewing a plan for a change to Topo, before any code is written.
The question is whether it should be built this way — not whether the
feature is wanted (that is decided) and not the code (there is none yet).

Read CLAUDE.md and docs/design.md in the topo checkout first; they hold the
invariants and the decisions already taken. The other directories under
your working directory are background: the design reasoning and the coding
rules the project works to. Read what the plan touches.

Look for: a wheel reinvented where the stdlib, a platform framework or an
already-linked dependency does it; an indirect path where a direct one
exists; complexity the design does not ask for; a step that contradicts a
recorded decision; a proof section that cannot actually prove the claim
(a test that would pass with the behaviour wrong, a device-only property
claimed for the simulator).

Two classes of output, and the distinction matters:
- red_lines: do not build it this way. Each cites what it contradicts or
  what it should be instead. These are escalated if disagreed with, so
  only raise one you would defend.
- suggestions: would be better this way; take or leave.
summary is two or three sentences for the reader. Say plainly when the
plan is fine. Do not pad: an empty red_lines list is a valid answer and
the common one.

The plan follows.
----- BEGIN PLAN -----
PROMPT
  cat "$plan"
  echo "----- END PLAN -----"
} | codex exec \
    --model "$model" \
    --sandbox read-only \
    --skip-git-repo-check \
    --color never \
    --cd "$ctx" \
    --output-schema "$schema" \
    --output-last-message "$out" \
    - >/dev/null
cat "$out"
