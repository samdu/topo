#!/usr/bin/env bash
# The review cap (docs/process.md, *The fix loop*): a PR carrying REVIEW_CAP Codex verdicts (3) is
# not reviewed again, or REVIEW_CAP + 2 (5) once it carries the `second-chance` label, the PM's one
# grant of two more rounds. The label is read whole as present or absent, so the cap is one of those
# two numbers and no grant after the first adds a round. Prints `capped=true` or `capped=false` on
# stdout, for $GITHUB_OUTPUT; the count is scripts/review-verdicts.sh's, the same one
# scripts/review-prompt.sh reads the round off.
#
#   PR_NUMBER=143 GITHUB_REPOSITORY=samdu/topo scripts/review-cap.sh >> "$GITHUB_OUTPUT"
#
# pr-validate.yaml runs it twice per run: in `review_cap`, before the reviewer is spent, and in
# `post_feedback`, immediately before the verdict is posted, since a run in flight when another
# posted its verdict counted before that one landed. At the cap it posts one comment saying so,
# under its own marker (`<!-- topo-review-cap -->`, never the codex one, so it is never counted as a
# verdict) with the cap it was posted at on its second line (`<!-- topo-review-cap-at: N -->`),
# unless the bot has already posted one at that cap: a PR capped at three and granted its second
# chance is told again at five. A count or a label that cannot be read, or a cap comment that
# cannot be posted, exits 1 and prints nothing: the step fails and a rerun tries again, and no job
# reads a cap nobody was told about.
set -euo pipefail

: "${PR_NUMBER:?PR_NUMBER is the pull request number}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is owner/repo}"
BASE="${REVIEW_CAP:-3}"
SECOND_CHANCE_LABEL=second-chance
CAP_MARKER='<!-- topo-review-cap -->'
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "review-cap: $*" >&2; }

if ! granted="$(gh api "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER" \
    --jq "[.labels[].name] | index(\"$SECOND_CHANCE_LABEL\") != null" 2>&1)"; then
  log "::error::could not read this PR's labels, so the cap is unknown; re-run the job: $(head -n 1 <<<"$granted")"
  exit 1
fi
case "$granted" in
  true) CAP=$(( BASE + 2 )) ;;
  false) CAP="$BASE" ;;
  *) log "::error::could not read this PR's labels (answered: ${granted:-nothing}), so the cap is unknown; re-run the job"; exit 1 ;;
esac

verdicts="$("$here/review-verdicts.sh")"
count="$(printf '%s' "$verdicts" | grep -c . || true)"
log "Codex verdicts on this PR: $count (cap $CAP$([ "$granted" = true ] && echo ", with its second chance"))"
if [ "$count" -lt "$CAP" ]; then
  echo "capped=false"
  exit 0
fi

notices="$("$here/review-verdicts.sh" "$CAP_MARKER")"
said="$(printf '%s' "$notices" | grep -cF -- "<!-- topo-review-cap-at: $CAP -->" || true)"
if [ "$said" -gt 0 ]; then
  log "the cap comment at $CAP is already on the PR"
else
  if [ "$granted" = true ]; then
    way="Its second chance is spent: what the PM rules next is a decision card for Sam."
  else
    way="The engineer stops and tells the PM, who rules: two more rounds once (the \`$SECOND_CHANCE_LABEL\` label), a merge as it stands with the findings filed, or a decision card for Sam."
  fi
  body="$CAP_MARKER
<!-- topo-review-cap-at: $CAP -->
### Review cap reached

This PR carries $count Codex verdicts, and the cap is $CAP (docs/process.md, *The fix loop*). Codex does not review it again, and \`review_gate\` holds the merge. $way"
  if ! out="$(gh api --method POST "repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" -f body="$body" 2>&1 >/dev/null)"; then
    log "::error::could not post the review-cap comment; re-run the job: $(head -n 1 <<<"$out")"
    exit 1
  fi
  log "posted the cap comment"
fi
echo "capped=true"
