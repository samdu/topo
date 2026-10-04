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
# and no run, so none of them may count as this run's answer. `launched` is the real launcher's
# two behaviours: attached to the console it never exits, detached it returns once the app is up.
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
      reply-no-done) say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run $run from session S1, process 7: hi"; exec sleep 600 ;;
      silent) exec sleep 600 ;;
      error-then-done) say "sending: hello"; say "error: Claude answered 500."; say "reply: hi"
                       say "reply to phone/2 in run $run from session S1, process 7: hi"; say "done"; exec sleep 600 ;;
      other-run) say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run someone-else from session S1, process 7: hi"
                 say "done"; exec sleep 600 ;;
      no-reply) say "sending: hello"; say "reply: an older answer"; say "no reply to phone/2 in run $run"
                say "done"; exec sleep 600 ;;
      done-then-exits-1) say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run $run from session S1, process 7: hi"
                         say "done"; exit 1 ;;
      answered) say "sending: hello"; say "mascot: turn began for phone/2, process 7, idle"; say "mascot: thinking"
                say "mascot: turn gone for phone/2, idle"; say "reply: hi"; say "reply to phone/2 in run $run from session S1, process 7: hi"
                say "done"; exec sleep 600 ;;
      answered-by-nobody) say "sending: hello"; say "mascot: turn began for phone/2, process 7, idle"; say "mascot: turn gone for phone/2, idle"
                          say "reply to phone/2 in run $run from session none, process none: hi"; say "done"; exec sleep 600 ;;
      answered-other-mascot) say "sending: hello"; say "mascot: turn began for phone/1, process 7, idle"
                             say "mascot: turn gone for phone/1, idle"; say "mascot: turn began for phone/12, process 7, idle"
                             say "mascot: turn gone for phone/12, idle"
                             say "reply to phone/2 in run $run from session S1, process 7: hi"; say "done"; exec sleep 600 ;;
      answered-no-mascot) say "sending: hello"; say "reply to phone/2 in run $run from session S1, process 7: hi"
                          say "done"; exec sleep 600 ;;
      answered-old-format) say "sending: hello"; say "mascot: turn began for phone/2, process 7, idle"; say "mascot: turn gone for phone/2, idle"
                           say "reply to phone/2 in run $run: hi"; say "done"; exec sleep 600 ;;
      launched) case " $* " in *" --console-pty "*) exec sleep 30 ;; esac; exit 0 ;;
      userland-fetched) say "userland: downloading"; say "userland: rootfs fetched and imported"
                        say "userland: claude code 2.1.278 fetched"; say "userland: booted"
                        say "userland: claude code 2.1.278 verified in 310 ms, mounted at /usr/local/bin/claude"
                        say "guest: hi"; say "guest exit: 0"; say "userland done"; exec sleep 600 ;;
      userland-reused) say "userland: ready"; say "userland: rootfs reused: nothing fetched, nothing imported"
                       say "userland: claude code 2.1.278 reused: nothing fetched, nothing copied"; say "userland: booted"
                       say "userland: claude code 2.1.278 verified in 290 ms, mounted at /usr/local/bin/claude"
                       say "guest: hi"; say "guest exit: 0"; say "userland done"; exec sleep 600 ;;
      userland-unmounted) say "userland: rootfs reused: nothing fetched, nothing imported"
                          say "userland: claude code 2.1.278 reused: nothing fetched, nothing copied"; say "userland: booted"
                          say "guest: hi"; say "guest exit: 0"; say "userland done"; exec sleep 600 ;;
      userland-error) say "userland: ready"; say "userland error: the kernel refused to boot (-2)"; say "userland done"
                      exec sleep 600 ;;
      userland-exit-1) say "userland: booted"
                       say "userland: claude code 2.1.278 verified in 290 ms, mounted at /usr/local/bin/claude"
                       say "guest: hi"; say "guest exit: 1"; say "userland done"; exec sleep 600 ;;
      userland-other-output) say "userland: booted"
                             say "userland: claude code 2.1.278 verified in 290 ms, mounted at /usr/local/bin/claude"
                             say "guest: hi there"; say "guest exit: 0"; say "userland done"; exec sleep 600 ;;
      userland-dies) say "userland: booted"; exit 42 ;;
      guest-answered) say "userland: booted"; say "guest: starting Claude Code, a fresh session"
                      say "guest turn 1 sent: a"; say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                      say "guest turn 1 answered in 9.10 s: ok"; say "guest turn 2 sent: b"
                      say "guest turn 2 model: claude-haiku-4-5-20251001, session S1, process 7"
                      say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-one-failed) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                        say "guest turn 1 failed in 12.00 s: the process ended mid-turn"
                        say "guest turn 2 model: claude-haiku-4-5-20251001, session S1, process 7"
                        say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-abandoned) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                       say "guest turn 1 abandoned after 15.00 s"; say "guest turn 2 model: claude-haiku-4-5-20251001, session S1, process 7"
                       say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-two-processes) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                           say "guest turn 1 answered in 9.10 s: ok"
                           say "guest turn 2 model: claude-haiku-4-5-20251001, session S1, process 12"
                           say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-two-sessions) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                          say "guest turn 1 answered in 9.10 s: ok"
                          say "guest turn 2 model: claude-haiku-4-5-20251001, session S2, process 7"
                          say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-no-process) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1"
                        say "guest turn 1 answered in 9.10 s: ok"
                        say "guest turn 2 model: claude-haiku-4-5-20251001, session S1"
                        say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-bash) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                  say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: topo-42"
                  say "guest turn 1 answered in 6.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-no-call) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                          say "guest turn 1 answered in 2.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-failed) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                         say "guest turn 1 tool: Bash"
                         say "guest turn 1 tool result: Bash: error: No suitable shell found. topo-42"
                         say "guest turn 1 answered in 4.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-other-output) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                               say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: topo-41"
                               say "guest turn 1 answered in 4.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-other-tool) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                             say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: error: no shell"
                             say "guest turn 1 tool: Read"; say "guest turn 1 tool result: Read: ok: topo-42"
                             say "guest turn 1 answered in 4.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-reply-silent) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                               say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: topo-42"
                               say "guest turn 1 answered in 4.00 s: done"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-ok-only-in-prefix) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                                    say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: wrong output"
                                    say "guest turn 1 answered in 4.00 s: ok"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-in-reply-prefix-only) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                                       say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: answered"
                                       say "guest turn 1 answered in 4.00 s: done"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-result-echoed-in-sent) say "guest turn 1 sent: [topo-debug] guest turn 1 tool result: Bash: ok: topo-42"
                                        say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                                        say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: wrong output"
                                        say "guest turn 1 answered in 4.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-error) say "guest turn error: Claude Code did not start"; say "guest turn done"; exec sleep 600 ;;
      guest-opus) say "guest turn 1 model: claude-opus-5, session S1, process 7"; say "guest turn 1 answered in 3.00 s: ok"
                  say "guest turn 2 model: claude-opus-5, session S1, process 7"; say "guest turn 2 answered in 1.00 s: ok"
                  say "guest turn done"; exec sleep 600 ;;
      guest-one-short) say "guest turn 1 model: claude-haiku-4-5-20251001, session S1, process 7"
                       say "guest turn 1 answered in 3.00 s: ok"; say "guest turn done"; exec sleep 600 ;;
      *) echo "fake xcrun: no scenario '$FAKE_LAUNCH'" >&2; exit 99 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF

# The suite `--press-mic` runs: a pass, or with FAKE_XCODEBUILD=hangs one that never finishes and
# has a child of its own holding its output, as a build service outliving xcodebuild would.
cat >"$work/bin/xcodebuild" <<'EOF'
#!/bin/bash
if [ "${FAKE_XCODEBUILD:-}" = hangs ]; then
  sleep 30 &
  exec sleep 31
fi
echo "** TEST SUCCEEDED **"
EOF
chmod +x "$work/bin/xcrun" "$work/bin/op-item" "$work/bin/xcodebuild"

failures=0

# case <name> <expected: pass|fail> <scenario> <max seconds> [script args...]
case_() {
  local name="$1" want="$2" scenario="$3" limit="$4"; shift 4
  local out="$work/$name.out" start status elapsed got
  start=$SECONDS
  PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT="$wait" FAKE_LAUNCH="$scenario" \
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

# One untimed run first. The first case to exec the script, python3 (the device lookup), uuidgen
# and the fakes on a fresh runner pays for loading them, which has taken from 0 s to 9 s on the
# same script with the same scenario; the limits below are about what the script waits for, not
# about a cold disk.
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT=6 FAKE_LAUNCH=exits-42 \
  "$work/root/scripts/simulator-run.sh" --no-build >/dev/null 2>&1 </dev/null

# A second, warm run of the same scenario is what this machine takes to run the script through to
# its exit with nothing to wait for. Every limit is that plus what the case itself may take, so a
# loaded runner moves the limits with it: `quick` for a run that has nothing to wait out, `slow`
# for one that waits out the script's own timeout, `wait`, which stays above `quick` so a run
# that should have ended at once and instead timed out is over its limit.
start=$SECONDS
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT=6 FAKE_LAUNCH=exits-42 \
  "$work/root/scripts/simulator-run.sh" --no-build >/dev/null 2>&1 </dev/null
overhead=$((SECONDS - start))
quick=$((5 + overhead))
wait=$((quick + 1))
slow=$((2 * wait))

case_ no-send-launcher-exits-nonzero       fail exits-42             "$quick"
case_ no-send-stale-reply-launcher-exits-42 fail stale-reply-exits-42 "$quick"
case_ send-stale-reply-launcher-exits-42   fail stale-reply-exits-42 "$quick"  --send "new message"
case_ send-launcher-dies-before-done       fail dies-before-done     "$quick"  --send hello
case_ send-reply-without-done              fail reply-no-done        "$slow" --send hello
case_ send-times-out-silent                fail silent               "$slow" --send hello
case_ send-done-with-error                 fail error-then-done      "$quick"  --send hello
case_ send-reply-to-another-run            fail other-run            "$quick"  --send hello
case_ send-no-reply-to-this-turn           fail no-reply             "$quick"  --send hello
case_ send-done-then-launcher-exits-1      fail done-then-exits-1    "$quick"  --send hello
case_ send-answered                        pass answered             "$quick"  --send hello
case_ send-answered-by-no-resident         fail answered-by-nobody   "$quick"  --send hello
case_ send-answered-mascot-silent          fail answered-no-mascot   "$quick"  --send hello
case_ send-answered-mascot-other-turn      fail answered-other-mascot "$quick" --send hello
case_ send-answered-no-provenance          fail answered-old-format  "$quick"  --send hello
case_ no-send-launched                     pass launched             "$quick"
case_ press-mic-no-send-exits              pass launched             "$quick" --press-mic
case_ userland-ran                         pass userland-fetched     "$quick"  --userland "echo hi" --expect hi
case_ userland-fetched-as-expected         pass userland-fetched     "$quick"  --userland "echo hi" --expect-rootfs fetched
case_ userland-reused-as-expected          pass userland-reused      "$quick"  --userland "echo hi" --expect-rootfs reused
case_ userland-fetched-when-reuse-expected fail userland-fetched     "$quick"  --userland "echo hi" --expect-rootfs reused
case_ userland-reused-when-fetch-expected  fail userland-reused      "$quick"  --userland "echo hi" --expect-rootfs fetched
case_ userland-error                       fail userland-error       "$quick"  --userland "echo hi"
case_ userland-exit-nonzero                fail userland-exit-1      "$quick"  --userland "echo hi"
case_ userland-other-output                fail userland-other-output "$quick" --userland "echo hi" --expect hi
case_ userland-launcher-dies               fail userland-dies        "$quick"  --userland "echo hi"
case_ userland-times-out-silent            fail silent               "$slow" --userland "echo hi"
case_ userland-claude-fetched-as-expected  pass userland-fetched     "$quick"  --userland "claude --version" --expect-claude fetched
case_ userland-claude-reused-as-expected   pass userland-reused      "$quick"  --userland "claude --version" --expect-claude reused
case_ userland-claude-fetched-not-reused   fail userland-fetched     "$quick"  --userland "claude --version" --expect-claude reused
case_ userland-claude-reused-not-fetched   fail userland-reused      "$quick"  --userland "claude --version" --expect-claude fetched
case_ userland-claude-not-mounted          fail userland-unmounted   "$quick"  --userland "echo hi"
case_ guest-turns-answered                 pass guest-answered       "$quick"  --guest-turn "a || b"
case_ guest-turn-failed                    fail guest-one-failed     "$quick"  --guest-turn "a || b"
case_ guest-turn-abandoned                 fail guest-abandoned      "$quick"  --guest-turn "a || b"
case_ guest-turns-two-processes           fail guest-two-processes  "$quick"  --guest-turn "a || b"
case_ guest-turns-two-sessions            fail guest-two-sessions   "$quick"  --guest-turn "a || b"
case_ guest-turns-no-process-named        fail guest-no-process     "$quick"  --guest-turn "a || b"
case_ guest-turn-error                     fail guest-error          "$quick"  --guest-turn "a || b"
case_ guest-turns-not-on-haiku             fail guest-opus           "$quick"  --guest-turn "a || b"
case_ guest-turn-missing                   fail guest-one-short      "$quick"  --guest-turn "a || b"
case_ guest-turn-ran-bash                  pass guest-bash           "$quick"  --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-no-call              fail guest-bash-no-call   "$quick"  --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-failed               fail guest-bash-failed    "$quick"  --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-other-output         fail guest-bash-other-output "$quick" --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-output-from-another  fail guest-bash-other-tool "$quick"  --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-reply-without-it     fail guest-bash-reply-silent "$quick" --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-ok-only-in-prefix    fail guest-bash-ok-only-in-prefix "$quick" --guest-turn "a" --expect-bash ok
case_ guest-turn-bash-reply-prefix-only    fail guest-bash-in-reply-prefix-only "$quick" --guest-turn "a" --expect-bash answered
case_ guest-turn-bash-result-echoed-in-sent fail guest-bash-result-echoed-in-sent "$quick" --guest-turn "a" --expect-bash topo-42
case_ guest-turns-times-out-silent         fail silent               "$slow" --guest-turn "a || b"

# The pids file names what a run started and the script ends exactly those. A run left waiting
# is ended by SIGTERM to its first pid, the script's own, and takes its second, the child it was
# waiting on, with it, within the `quick` limit; the log is the run's whole output, kept after it.
#
# ended <name> <the child's command> <whole log: yes|no> [script args...]
ended() {
  local name="$1" child="$2" whole="$3"; shift 3
  local sim="$work/root/build/sim" out="$work/$name.out" runner waited=0 script_pid child_pid problem="" start status
  PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT=60 FAKE_LAUNCH=silent FAKE_XCODEBUILD=hangs \
    "$work/root/scripts/simulator-run.sh" --no-build "$@" >"$out" 2>&1 </dev/null &
  runner=$!
  until [ "$(cat "$sim/simulator-run.pids" 2>/dev/null | wc -l)" -ge 2 ] || [ "$waited" -ge $((10 + overhead)) ]; do
    sleep 1
    waited=$((waited + 1))
  done
  script_pid="$(sed -n 1p "$sim/simulator-run.pids" 2>/dev/null)"
  child_pid="$(sed -n 2p "$sim/simulator-run.pids" 2>/dev/null)"
  start=$SECONDS
  if [ -z "$script_pid" ] || [ -z "$child_pid" ]; then
    problem="the pids file did not name the script and its child"
    kill "$runner" 2>/dev/null
  elif [ "$script_pid" != "$runner" ]; then
    problem="the pids file's first line is $script_pid, and the script is $runner"
    kill "$runner" 2>/dev/null
  elif [ "$(ps -o command= -p "$child_pid")" != "$child" ]; then
    problem="the pids file's second line is not '$child'"
    kill "$runner" 2>/dev/null
  else
    kill "$script_pid"
  fi
  wait "$runner"; status=$?
  if [ -z "$problem" ]; then
    if [ "$status" != 143 ]; then problem="the script exited $status on SIGTERM, not 143"
    elif [ $((SECONDS - start)) -gt "$quick" ]; then problem="the script took $((SECONDS - start))s to end (limit ${quick}s)"
    elif kill -0 "$child_pid" 2>/dev/null; then problem="'$child' outlived the script"; kill "$child_pid"
    elif [ -e "$sim/simulator-run.pids" ]; then problem="the pids file outlived the run"
    elif ! grep -Fxq "==> pids: $sim/simulator-run.pids" "$out"; then problem="the run did not print where its pids are"
    elif ! grep -Fxq "==> log: $sim/simulator-run.log" "$out"; then problem="the run did not print where its log is"
    elif [ "$whole" = yes ] && ! cmp -s "$out" "$sim/simulator-run.log"; then problem="the log is not what the run printed"
    fi
  fi
  if [ -n "$problem" ]; then
    echo "FAIL $name: $problem"
    sed 's/^/    | /' "$out"
    failures=$((failures + 1))
  else
    echo "ok   $name: SIGTERM to the script's recorded pid ended it and '$child'"
  fi
}

ended ended-waiting-on-the-launcher "sleep 600" yes --send hello
# The suite's own child still holds the run's output when the script ends, so the script's exit is
# what is held here and not that the log is whole yet.
ended ended-during-the-suite        "sleep 31"  no  --press-mic

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed against $script"
  exit 1
fi
echo "all cases held against $script"
