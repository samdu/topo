#!/usr/bin/env bash
# Tests .claude/hooks/ledger-recall.py against SessionStart inputs under a scratch HOME: on a
# compaction or a resume it prints the last 30 lines of ~/topo-plans/sprints/current/ledger.md,
# read through the `current` symlink, with a marker when there were more; on a fresh startup, with
# no ledger, or with an empty one it prints nothing; and it exits 0 every time.
set -uo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$root/.claude/hooks/ledger-recall.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok   $*"; }

# recall <source> — the hook's stdout for a session start of that source; its exit is checked.
recall() {
  local out status
  out="$(printf '{"hook_event_name": "SessionStart", "source": "%s"}' "$1" | HOME="$work/home" python3 "$hook")"
  status=$?
  [ "$status" = 0 ] || fail "source $1: exited $status"
  printf '%s' "$out"
}

mkdir -p "$work/home"
[ -z "$(recall compact)" ] && pass "no ledger: nothing printed" || fail "no ledger: printed something"

mkdir -p "$work/home/topo-plans/sprints/2026-11-11"
ln -s 2026-11-11 "$work/home/topo-plans/sprints/current"
: > "$work/home/topo-plans/sprints/2026-11-11/ledger.md"
[ -z "$(recall compact)" ] && pass "an empty ledger: nothing printed" || fail "an empty ledger: printed something"

{ echo "# Ledger, sprint 2026-11-11"; for i in $(seq 1 40); do echo "- 2026-11-11T20:$(printf '%02d' "$i")Z dispatched: line $i"; done; } \
  > "$work/home/topo-plans/sprints/2026-11-11/ledger.md"

[ -z "$(recall startup)" ] && pass "startup: nothing printed" || fail "startup: printed something"

for source in compact resume; do
  out="$(recall "$source")"
  if grep -qx -- "- 2026-11-11T20:40Z dispatched: line 40" <<<"$out" \
    && grep -qx -- "- 2026-11-11T20:11Z dispatched: line 11" <<<"$out" \
    && ! grep -q -- "line 10$" <<<"$out" && ! grep -q "# Ledger" <<<"$out" \
    && grep -qx "…" <<<"$out" && [ "$(grep -c "dispatched:" <<<"$out")" = 30 ]; then
    pass "$source: the last 30 lines, newest last, after a marker"
  else
    fail "$source: not the last 30 lines: $out"
  fi
done

# The newest sprint, not an older one: the symlink moved is the ledger read.
mkdir -p "$work/home/topo-plans/sprints/2026-11-20"
echo "- 2026-11-20T09:00Z dispatched: the next sprint's first" > "$work/home/topo-plans/sprints/2026-11-20/ledger.md"
ln -sfn 2026-11-20 "$work/home/topo-plans/sprints/current"
out="$(recall compact)"
if grep -q "the next sprint's first" <<<"$out" && ! grep -q "line 40" <<<"$out" && ! grep -qx "…" <<<"$out"; then
  pass "a moved symlink: the current sprint's ledger, whole when it is short"
else
  fail "a moved symlink: $out"
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
