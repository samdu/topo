#!/usr/bin/env bash
# Prints the bodies of this PR's issue comments posted by `github-actions[bot]` that begin with a
# marker, one JSON string per line, oldest first. The marker is the first argument, and the codex
# marker (`<!-- agent-review: codex -->`) when none is given, so with no argument the lines are the
# PR's Codex verdicts: scripts/review-prompt.sh reads the round and the previous verdict off them,
# and scripts/review-cap.sh the count the cap is judged on. A comment by anyone else is never
# counted, whatever it quotes.
#
#   PR_NUMBER=143 GITHUB_REPOSITORY=samdu/topo scripts/review-verdicts.sh [marker]
#
# Read through `gh api`, tried REVIEW_GH_ATTEMPTS times (4) with a linear backoff of
# REVIEW_GH_BACKOFF seconds (5, then 10, then 15). A `gh` that still fails exits 1 with an
# `::error::` and prints nothing, because a guessed count is a review under the wrong rule.
set -euo pipefail

: "${PR_NUMBER:?PR_NUMBER is the pull request number}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is owner/repo}"
MARKER="${1:-<!-- agent-review: codex -->}"
GH_ATTEMPTS="${REVIEW_GH_ATTEMPTS:-4}"
GH_BACKOFF="${REVIEW_GH_BACKOFF:-5}"

log() { echo "review-verdicts: $*" >&2; }

err="$(mktemp)"
trap 'rm -f "$err"' EXIT
attempt=1
until bodies="$(gh api --paginate "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" \
    --jq ".[] | select(.user.login == \"github-actions[bot]\" and (.body | startswith(\"$MARKER\"))) | .body | @json" 2>"$err")"; do
  if [ "$attempt" -ge "$GH_ATTEMPTS" ]; then
    log "::error::could not read this PR's comments after $GH_ATTEMPTS attempts, so the review count is unknown; re-run the job: $(head -n 1 "$err")"
    exit 1
  fi
  log "could not read this PR's comments (attempt $attempt of $GH_ATTEMPTS), retrying in $(( GH_BACKOFF * attempt ))s: $(head -n 1 "$err")"
  sleep "$(( GH_BACKOFF * attempt ))"
  attempt=$(( attempt + 1 ))
done
[ -z "$bodies" ] || printf '%s\n' "$bodies"
