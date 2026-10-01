#!/usr/bin/env bash
# The review cap (docs/process.md, *The fix loop*): a PR carrying REVIEW_CAP Codex verdicts (4) is
# not reviewed again. Prints `capped=true` or `capped=false` on stdout, for $GITHUB_OUTPUT; the
# count is scripts/review-verdicts.sh's, the same one scripts/review-prompt.sh reads the round off.
#
#   PR_NUMBER=143 GITHUB_REPOSITORY=samdu/topo scripts/review-cap.sh >> "$GITHUB_OUTPUT"
#
# pr-validate.yaml runs it twice per run: in `review_cap`, before the reviewer is spent, and in
# `post_feedback`, immediately before the verdict is posted, since a run in flight when another
# posted its verdict counted before that one landed. At the cap it posts one comment saying so,
# under its own marker (`<!-- topo-review-cap -->`, never the codex one, so it is never counted as a
# verdict), unless the bot has already posted one on the PR. A count that cannot be read, or a cap
# comment that cannot be posted, exits 1 and prints nothing: the step fails and a rerun tries again,
# and no job reads a cap nobody was told about.
set -euo pipefail

: "${PR_NUMBER:?PR_NUMBER is the pull request number}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is owner/repo}"
CAP="${REVIEW_CAP:-4}"
CAP_MARKER='<!-- topo-review-cap -->'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "review-cap: $*" >&2; }

verdicts="$("$here/review-verdicts.sh")"
count="$(printf '%s' "$verdicts" | grep -c . || true)"
log "Codex verdicts on this PR: $count (cap $CAP)"
if [ "$count" -lt "$CAP" ]; then
  echo "capped=false"
  exit 0
fi

said="$("$here/review-verdicts.sh" "$CAP_MARKER")"
if [ -n "$said" ]; then
  log "the cap comment is already on the PR"
else
  body="$CAP_MARKER
### Review cap reached

This PR carries $count Codex verdicts, and the cap is $CAP (docs/process.md, *The fix loop*). Codex does not review it again, and \`review_gate\` holds the merge: it merges on Sam's word, or goes back to draft for a replan."
  if ! out="$(gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" -f body="$body" 2>&1 >/dev/null)"; then
    log "::error::could not post the review-cap comment; re-run the job: $(head -n 1 <<<"$out")"
    exit 1
  fi
  log "posted the cap comment"
fi
echo "capped=true"
