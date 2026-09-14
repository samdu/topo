#!/usr/bin/env bash
# Runs scripts/simulator-run.sh against a fake `xcrun` whose `simctl launch` plays one scripted
# console per case, and holds that the script exits non-zero on every way a run can fail and zero
# only on a turn that finished and was answered under this run's id. No simulator, no build, no
# token, no network: CLAUDE_SETUP_TOKEN is a placeholder and `op-item` is a fake that fails.
#
#   scripts/tests/simulator-run-test.sh
#   SCRIPT=/path/to/other/simulator-run.sh scripts/tests/simulator-run-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${SCRIPT:-$here/../simulator-run.sh}"
[ -f "$script" ] || { echo "no script at $script" >&2; exit 2; }

work="$(mktemp -d -t simulator-run-test)"
trap 'rm -rf "$work"' EXIT

# A tree shaped like the repo as far as the script looks: itself under scripts/, and a built app.
mkdir -p "$work/root/scripts" "$work/root/build/sim/Build/Products/Debug-iphonesimulator/Topo.app" "$work/bin"
cp "$script" "$work/root/scripts/simulator-run.sh"
chmod +x "$work/root/scripts/simulator-run.sh"

cat >"$work/bin/op-item" <<'EOF'
#!/bin/bash
echo "fake op-item: the test gives the token in the environment" >&2
exit 1
EOF

# `simctl launch` prints what FAKE_LAUNCH names. The run id the script handed the app arrives as
# SIMCTL_CHILD_TOPO_DEBUG_RUN, as it would reach the app itself. `exec sleep` is a launcher that,
# like the real `--console-pty` one, never exits on its own. The bare `reply:` lines name no turn
# and no run, so none of them may count as this run's answer.
cat >"$work/bin/xcrun" <<'EOF'
#!/bin/bash
[ "$1" = simctl ] || exit 1
run="${SIMCTL_CHILD_TOPO_DEBUG_RUN:-}"
say() { echo "[topo-debug] $*"; }
case "$2" in
  list) echo '{"devices":{"iOS":[{"name":"iPhone 17","udid":"FAKE-UDID"}]}}' ;;
  launch)
    case "$FAKE_LAUNCH" in
      exits-42) echo "launch failed"; exit 42 ;;
      stale-reply-exits-42) say "reply: stale unrelated reply"; exit 42 ;;
      dies-before-done) say "sending: hello"; exit 42 ;;
      reply-no-done) say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run $run: hi"; exec sleep 600 ;;
      silent) exec sleep 600 ;;
      error-then-done) say "sending: hello"; say "error: Claude answered 500."; say "reply: hi"
                       say "reply to phone/2 in run $run: hi"; say "done"; exec sleep 600 ;;
      other-run) say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run someone-else: hi"
                 say "done"; exec sleep 600 ;;
      no-reply) say "sending: hello"; say "reply: an older answer"; say "no reply to phone/2 in run $run"
                say "done"; exec sleep 600 ;;
      done-then-exits-1) say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run $run: hi"
                         say "done"; exit 1 ;;
      answered) say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run $run: hi"; say "done"
                exec sleep 600 ;;
      launched) exit 0 ;;
      *) echo "fake xcrun: no scenario '$FAKE_LAUNCH'" >&2; exit 99 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$work/bin/xcrun" "$work/bin/op-item"

failures=0

# case <name> <expected: pass|fail> <scenario> <max seconds> [script args...]
case_() {
  local name="$1" want="$2" scenario="$3" limit="$4"; shift 4
  local out="$work/$name.out" start status elapsed got
  start=$SECONDS
  PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT=6 FAKE_LAUNCH="$scenario" \
    "$work/root/scripts/simulator-run.sh" --no-build "$@" >"$out" 2>&1 </dev/null
  status=$?
  elapsed=$((SECONDS - start))
  if [ "$status" = 0 ]; then got=pass; else got=fail; fi
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: wanted the script to $want, it exited $status"
    sed 's/^/    | /' "$out"
    failures=$((failures + 1))
  elif [ "$elapsed" -gt "$limit" ]; then
    echo "FAIL $name: exited $status as wanted, but after ${elapsed}s (limit ${limit}s)"
    sed 's/^/    | /' "$out"
    failures=$((failures + 1))
  else
    echo "ok   $name: exited $status in ${elapsed}s — $(grep '^==>' "$out" | tail -1)"
  fi
}

case_ no-send-launcher-exits-nonzero       fail exits-42             5
case_ no-send-stale-reply-launcher-exits-42 fail stale-reply-exits-42 5
case_ send-stale-reply-launcher-exits-42   fail stale-reply-exits-42 5  --send "new message"
case_ send-launcher-dies-before-done       fail dies-before-done     5  --send hello
case_ send-reply-without-done              fail reply-no-done        12 --send hello
case_ send-times-out-silent                fail silent               12 --send hello
case_ send-done-with-error                 fail error-then-done      5  --send hello
case_ send-reply-to-another-run            fail other-run            5  --send hello
case_ send-no-reply-to-this-turn           fail no-reply             5  --send hello
case_ send-done-then-launcher-exits-1      fail done-then-exits-1    5  --send hello
case_ send-answered                        pass answered             5  --send hello
case_ no-send-launched                     pass launched             5

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed against $script"
  exit 1
fi
echo "all cases held against $script"
