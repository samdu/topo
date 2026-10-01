#!/usr/bin/env bash
# Holds scripts/review-cap.sh, and scripts/review-verdicts.sh under it, against a fake `gh` answering
# from a fixture of issue comments. It holds that:
#   - three verdicts by github-actions[bot] carrying the codex marker is `capped=false`, and nothing
#     is posted;
#   - a comment by anyone else carrying the marker text, first line and all, is not a verdict: three
#     by the bot and one by a person is still `capped=false`;
#   - four by the bot is `capped=true`, and the cap comment is posted once, under its own marker and
#     never the codex one;
#   - with the bot's cap comment already on the PR, four is `capped=true` and nothing is posted, and
#     a cap comment by anyone else does not count as said;
#   - a cap comment that cannot be posted, and comments that cannot be read, each exit nonzero with
#     no `capped` line and an `::error::` on stderr, so the step fails and nothing reads the cap.
#
#   scripts/tests/review-cap-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../review-cap.sh"

work="$(mktemp -d -t review-cap-test)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }

MARKER='<!-- agent-review: codex -->'
CAP_MARKER='<!-- topo-review-cap -->'

mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'SH'
#!/usr/bin/env bash
# `gh api --paginate <endpoint> --jq <expr>` answers from $FAKE_GH_PAGES, one JSON array per page,
# applying the expression to each page as gh does. `gh api --method POST … -f body=<text>` appends
# the body to $FAKE_GH_POSTS as one JSON string. FAKE_GH_FAIL=1 fails every read;
# FAKE_GH_POST_FAIL=1 fails every post.
if [ "${2:-}" = --method ]; then
  [ -z "${FAKE_GH_POST_FAIL:-}" ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
  while [ "$#" -gt 0 ]; do
    case "$1" in -f) jq -nc --arg b "${2#body=}" '$b' >> "$FAKE_GH_POSTS"; shift 2 ;; *) shift ;; esac
  done
  echo '{"id": 99}'
  exit 0
fi
[ -z "${FAKE_GH_FAIL:-}" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
expr=""
while [ "$#" -gt 0 ]; do
  case "$1" in --jq) expr="$2"; shift 2 ;; *) shift ;; esac
done
jq -r "$expr" < "$FAKE_GH_PAGES"
SH
chmod +x "$work/bin/gh"

# comment <login> <body> — one issue comment as the API returns it.
comment() { jq -nc --arg login "$1" --arg body "$2" '{id: 1, user: {login: $login}, body: $body}'; }
verdict() { comment 'github-actions[bot]' "$MARKER
<!-- agent-review-sha: $(printf '%040d' "$1") -->
### Codex review

Round $1."; }

# page <file> <comment json>... — one page of comments.
page() { local f="$1"; shift; { echo "["; local first=1 c; for c in "$@"; do [ "$first" = 1 ] || echo ","; first=0; echo "$c"; done; echo "]"; } > "$f"; }

# run <case> <pages> [VAR=value ...] — stdout, stderr, status and posts land in $work/<case>.*.
run() {
  local name="$1" pages="$2"; shift 2
  : > "$work/$name.posts"
  env PATH="$work/bin:$PATH" FAKE_GH_PAGES="$pages" FAKE_GH_POSTS="$work/$name.posts" \
    PR_NUMBER=7 GITHUB_REPOSITORY=samdu/topo REVIEW_GH_BACKOFF=0 "$@" \
    "$script" > "$work/$name.out" 2> "$work/$name.err"
  echo "$?" > "$work/$name.status"
}

# expect <case> <capped> <posts> — exited 0, printed exactly `capped=<capped>`, posted <posts> times.
expect() {
  local name="$1" capped="$2" posts="$3" got
  got="$(grep -c . "$work/$name.posts")"
  if [ "$(cat "$work/$name.status")" != 0 ]; then
    fail "$name: exited $(cat "$work/$name.status"): $(cat "$work/$name.err")"
  elif [ "$(cat "$work/$name.out")" != "capped=$capped" ]; then
    fail "$name: printed '$(cat "$work/$name.out")', not capped=$capped"
  elif [ "$got" != "$posts" ]; then
    fail "$name: posted $got cap comments, not $posts"
  else
    pass "$name: capped=$capped, $posts cap comment(s) posted"
  fi
}

# expect_error <case> <pattern> — exited nonzero, printed nothing, said why.
expect_error() {
  local name="$1" pattern="$2"
  if [ "$(cat "$work/$name.status")" = 0 ]; then
    fail "$name: exited 0"
  elif [ -s "$work/$name.out" ]; then
    fail "$name: printed '$(cat "$work/$name.out")' on a failure"
  elif ! grep -q -- "::error::.*$pattern" "$work/$name.err"; then
    fail "$name: stderr does not say why: $(cat "$work/$name.err")"
  else
    pass "$name: failed with no capped line, and said why"
  fi
}

page "$work/three.json" "$(verdict 1)" "$(verdict 2)" "$(verdict 3)"
run three "$work/three.json"
expect three false 0

page "$work/three-and-a-person.json" "$(verdict 1)" "$(verdict 2)" "$(verdict 3)" \
  "$(comment samdu "$MARKER
Quoting the marker by hand.")"
run three-and-a-person "$work/three-and-a-person.json"
expect three-and-a-person false 0

page "$work/four.json" "$(verdict 1)" "$(verdict 2)" "$(comment samdu "Pushed the fixes.")" "$(verdict 3)" "$(verdict 4)"
run four "$work/four.json"
expect four true 1
posted="$(jq -r . "$work/four.posts" 2>/dev/null)"
if [ "$(head -n 1 <<<"$posted")" = "$CAP_MARKER" ] && ! grep -qF -- "$MARKER" <<<"$posted" \
  && grep -q "4 Codex verdicts" <<<"$posted" && grep -q "Sam's word" <<<"$posted"; then
  pass "four: the cap comment opens with its own marker, never the codex one, and names the count and the way out"
else
  fail "four: the cap comment is not as it should be: $posted"
fi

page "$work/four-said.json" "$(verdict 1)" "$(verdict 2)" "$(verdict 3)" "$(verdict 4)" \
  "$(comment 'github-actions[bot]' "$CAP_MARKER
### Review cap reached")"
run four-said "$work/four-said.json"
expect four-said true 0

page "$work/four-said-by-a-person.json" "$(verdict 1)" "$(verdict 2)" "$(verdict 3)" "$(verdict 4)" \
  "$(comment samdu "$CAP_MARKER
not the bot")"
run four-said-by-a-person "$work/four-said-by-a-person.json"
expect four-said-by-a-person true 1

run post-fails "$work/four.json" FAKE_GH_POST_FAIL=1
expect_error post-fails "could not post the review-cap comment.*HTTP 403"

run read-fails "$work/four.json" FAKE_GH_FAIL=1
expect_error read-fails "could not read this PR's comments after 4 attempts.*HTTP 502"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
