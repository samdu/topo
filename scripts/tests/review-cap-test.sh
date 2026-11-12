#!/usr/bin/env bash
# Holds scripts/review-cap.sh, and scripts/review-verdicts.sh under it, against a fake `gh` answering
# from a fixture of issue comments and the PR's labels. It holds that:
#   - two verdicts by github-actions[bot] carrying the codex marker is `capped=false`, and nothing
#     is posted;
#   - a comment by anyone else carrying the marker text, first line and all, is not a verdict: two
#     by the bot and one by a person is still `capped=false`;
#   - three by the bot is `capped=true`, and the cap comment is posted once, under its own marker and
#     never the codex one, at three, naming the PM's second chance;
#   - with the bot's cap comment at three already on the PR, three is `capped=true` and nothing is
#     posted, and a cap comment by anyone else does not count as said;
#   - with the `second-chance` label, three and four are `capped=false` and five is `capped=true`,
#     with a cap comment at five posted beside the one at three, saying the second chance is spent;
#     and six is capped too, so no grant reaches a sixth round;
#   - a cap comment that cannot be posted, comments that cannot be read, and labels that cannot be
#     read each exit nonzero with no `capped` line and an `::error::` on stderr, so the step fails
#     and nothing reads the cap.
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
# `gh api --paginate <endpoint>/comments --jq <expr>` answers from $FAKE_GH_PAGES, one JSON array per
# page, applying the expression to each page as gh does; `gh api <endpoint> --jq <expr>` for the
# issue itself answers an issue whose labels are $FAKE_GH_LABELS, comma-separated names.
# `gh api --method POST … -f body=<text>` appends the body to $FAKE_GH_POSTS as one JSON string.
# FAKE_GH_FAIL=1 fails every comment read, FAKE_GH_LABELS_FAIL=1 the issue read, and
# FAKE_GH_POST_FAIL=1 every post.
if [ "${2:-}" = --method ]; then
  [ -z "${FAKE_GH_POST_FAIL:-}" ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
  while [ "$#" -gt 0 ]; do
    case "$1" in -f) jq -nc --arg b "${2#body=}" '$b' >> "$FAKE_GH_POSTS"; shift 2 ;; *) shift ;; esac
  done
  echo '{"id": 99}'
  exit 0
fi
expr="" endpoint=""
while [ "$#" -gt 0 ]; do
  case "$1" in --jq) expr="$2"; shift 2 ;; repos/*) endpoint="$1"; shift ;; *) shift ;; esac
done
if [ "${endpoint%/comments}" = "$endpoint" ]; then
  [ -z "${FAKE_GH_LABELS_FAIL:-}" ] || { echo "HTTP 504: Gateway Timeout" >&2; exit 1; }
  jq -nc --arg l "${FAKE_GH_LABELS:-}" '{number: 7, labels: ($l | split(",") | map(select(. != "")) | map({name: .}))}' \
    | jq -r "$expr"
  exit 0
fi
[ -z "${FAKE_GH_FAIL:-}" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
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

# verdicts <file> <n> [comment json]... — a page of verdicts 1..n, then the comments given.
verdicts() { local f="$1" n="$2" i; shift 2; local all=(); for i in $(seq 1 "$n"); do all+=("$(verdict "$i")"); done; page "$f" "${all[@]}" "$@"; }
capsaid() { comment 'github-actions[bot]' "$CAP_MARKER
<!-- topo-review-cap-at: $1 -->
### Review cap reached"; }

verdicts "$work/two.json" 2
run two "$work/two.json"
expect two false 0

verdicts "$work/two-and-a-person.json" 2 "$(comment samdu "$MARKER
Quoting the marker by hand.")"
run two-and-a-person "$work/two-and-a-person.json"
expect two-and-a-person false 0

page "$work/three.json" "$(verdict 1)" "$(comment samdu "Pushed the fixes.")" "$(verdict 2)" "$(verdict 3)"
run three "$work/three.json"
expect three true 1
posted="$(jq -r . "$work/three.posts" 2>/dev/null)"
if [ "$(head -n 1 <<<"$posted")" = "$CAP_MARKER" ] && [ "$(sed -n 2p <<<"$posted")" = "<!-- topo-review-cap-at: 3 -->" ] \
  && ! grep -qF -- "$MARKER" <<<"$posted" && grep -q "3 Codex verdicts, and the cap is 3" <<<"$posted" \
  && grep -q "second-chance" <<<"$posted"; then
  pass "three: the cap comment opens with its own marker and the cap it was posted at, never the codex one, and names the count and the PM's ruling"
else
  fail "three: the cap comment is not as it should be: $posted"
fi

verdicts "$work/three-said.json" 3 "$(capsaid 3)"
run three-said "$work/three-said.json"
expect three-said true 0

verdicts "$work/three-said-by-a-person.json" 3 "$(comment samdu "$CAP_MARKER
<!-- topo-review-cap-at: 3 -->
not the bot")"
run three-said-by-a-person "$work/three-said-by-a-person.json"
expect three-said-by-a-person true 1

run granted-three "$work/three-said.json" FAKE_GH_LABELS=automerge,second-chance
expect granted-three false 0

verdicts "$work/granted-four.json" 4 "$(capsaid 3)"
run granted-four "$work/granted-four.json" FAKE_GH_LABELS=second-chance
expect granted-four false 0

verdicts "$work/granted-five.json" 5 "$(capsaid 3)"
run granted-five "$work/granted-five.json" FAKE_GH_LABELS=second-chance
expect granted-five true 1
posted="$(jq -r . "$work/granted-five.posts" 2>/dev/null)"
if [ "$(sed -n 2p <<<"$posted")" = "<!-- topo-review-cap-at: 5 -->" ] && grep -q "the cap is 5" <<<"$posted" \
  && grep -q "second chance is spent" <<<"$posted"; then
  pass "granted-five: the cap comment is posted again at five, and says the second chance is spent"
else
  fail "granted-five: the cap comment is not as it should be: $posted"
fi

verdicts "$work/granted-five-said.json" 5 "$(capsaid 3)" "$(capsaid 5)"
run granted-five-said "$work/granted-five-said.json" FAKE_GH_LABELS=second-chance
expect granted-five-said true 0

verdicts "$work/granted-six.json" 6 "$(capsaid 3)" "$(capsaid 5)"
run granted-six "$work/granted-six.json" FAKE_GH_LABELS=second-chance
expect granted-six true 0

run ungranted-five "$work/granted-five-said.json" FAKE_GH_LABELS=automerge
expect ungranted-five true 0

run post-fails "$work/three.json" FAKE_GH_POST_FAIL=1
expect_error post-fails "could not post the review-cap comment.*HTTP 403"

run read-fails "$work/three.json" FAKE_GH_FAIL=1
expect_error read-fails "could not read this PR's comments after 4 attempts.*HTTP 502"

run labels-fail "$work/two.json" FAKE_GH_LABELS_FAIL=1
expect_error labels-fail "could not read this PR's labels.*HTTP 504"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
