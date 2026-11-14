#!/usr/bin/env bash
# Runs scripts/simulator-run.sh against a fake `xcrun` whose `simctl launch` plays one scripted
# console per case, and holds that the script exits non-zero on every way a run can fail and zero
# only on a turn that finished and was answered under this run's id. No simulator, no build, no
# token, no network: CLAUDE_SETUP_TOKEN is a placeholder and `op-item` is a fake that fails, or
# with --sign-in gives a placeholder password the case then looks for everywhere it must not be.
# With --talk and a fake audio lane, it holds that a `start` that refuses is never followed by `stop`,
# and that `start` is given the script's own pid as the lane's owner.
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
if [ "$*" = "get Buddy Apple ID password" ] && [ -n "${FAKE_APPLE_PASSWORD:-}" ]; then
  printf '%s\n' "$FAKE_APPLE_PASSWORD"; exit 0
fi
echo "fake op-item: the test gives the token in the environment" >&2
exit 1
EOF

# `simctl launch` prints what FAKE_LAUNCH names. The run id the script handed the app arrives as
# SIMCTL_CHILD_TOPO_DEBUG_RUN, as it would reach the app itself. `exec sleep` is a launcher that,
# like the real `--console-pty` one, never exits on its own. The bare `reply:` lines name no turn
# and no run, so none of them may count as this run's answer. `launched` is a launch with nothing
# to wait for: detached it returns once the app is up, as the real one does; attached it fails at
# once, since a real attached launcher would never return and the case would only be slower.
cat >"$work/bin/xcrun" <<'EOF'
#!/bin/bash
[ "$1" = simctl ] || exit 1
run="${SIMCTL_CHILD_TOPO_DEBUG_RUN:-}"
echo "$2" >>"${FAKE_SIMCTL_CALLS:-/dev/null}"
say() { echo "[topo-debug] $*"; }
case "$2" in
  list) if [ -n "${FAKE_SIM_LIST:-}" ]; then echo "$FAKE_SIM_LIST"
        else echo '{"devices":{"iOS":[{"name":"iPhone 17","udid":"FAKE-UDID"}]}}'; fi ;;
  launch)
    # The launcher's pid, for the test to hold that no run leaves one behind.
    echo "$$" >"$FAKE_LAUNCHER_PID"
    case "$FAKE_LAUNCH" in
      exits-42) echo "launch failed"; exit 42 ;;
      stale-reply-exits-42) say "reply: stale unrelated reply"; exit 42 ;;
      dies-before-done) say "icloud: answered"; say "sending: hello"; exit 42 ;;
      reply-no-done) say "icloud: answered"; say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run $run from session S1, process 7: hi"; exec sleep 600 ;;
      silent) exec sleep 600 ;;
      error-then-done) say "icloud: answered"; say "sending: hello"; say "error: Claude answered 500."; say "reply: hi"
                       say "reply to phone/2 in run $run from session S1, process 7: hi"; say "done"; exec sleep 600 ;;
      other-run) say "icloud: answered"; say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run someone-else from session S1, process 7: hi"
                 say "done"; exec sleep 600 ;;
      no-reply) say "icloud: answered"; say "sending: hello"; say "reply: an older answer"; say "no reply to phone/2 in run $run"
                say "done"; exec sleep 600 ;;
      done-then-exits-1) say "icloud: answered"; say "sending: hello"; say "reply: hi"; say "reply to phone/2 in run $run from session S1, process 7: hi"
                         say "done"; exit 1 ;;
      answered) say "icloud: answered"; say "sending: hello"; say "mascot: turn began for phone/2, process 7, idle"; say "mascot: thinking"
                say "mascot: turn gone for phone/2, idle"; say "reply: hi"; say "reply to phone/2 in run $run from session S1, process 7: hi"
                say "records: iCloud"; say "done"; exec sleep 600 ;;
      answered-on-the-phone) say "icloud: answered"; say "sending: hello"; say "mascot: turn began for phone/2, process 7, idle"
                             say "mascot: turn gone for phone/2, idle"; say "reply to phone/2 in run $run from session S1, process 7: hi"
                             say "records: on this phone (no iCloud account when Topo was first opened), protection none"; say "done"; exec sleep 600 ;;
      no-account) say "icloud: no account"; say "done"; exec sleep 600 ;;
      unavailable) say "icloud: account temporarily unavailable"; say "done"; exec sleep 600 ;;
      lapsed) say "icloud: no answer within 30 s"; say "done"; exec sleep 600 ;;
      refused) say "icloud: refused (CKError 9)"; exec sleep 600 ;;
      answered-by-nobody) say "icloud: answered"; say "sending: hello"; say "mascot: turn began for phone/2, process 7, idle"; say "mascot: turn gone for phone/2, idle"
                          say "reply to phone/2 in run $run from session none, process none: hi"; say "done"; exec sleep 600 ;;
      answered-other-mascot) say "icloud: answered"; say "sending: hello"; say "mascot: turn began for phone/1, process 7, idle"
                             say "mascot: turn gone for phone/1, idle"; say "mascot: turn began for phone/12, process 7, idle"
                             say "mascot: turn gone for phone/12, idle"
                             say "reply to phone/2 in run $run from session S1, process 7: hi"; say "done"; exec sleep 600 ;;
      answered-heard) say "icloud: answered"; say "sending under N1 in run $run: hello"; say "mascot: turn began for heard:N1, process 7, thinking"
                      say "mascot: turn gone for heard:N1, idle"
                      say "reply to phone/2 in run $run from session S1, process 7: hi"; say "records: iCloud"; say "done"; exec sleep 600 ;;
      answered-heard-other) say "icloud: answered"; say "sending under N12 in run someone-else: hello"; say "sending under N1 in run $run: hello"
                            say "mascot: turn began for heard:N12, process 7, thinking"; say "mascot: turn gone for heard:N12, idle"
                            say "mascot: turn began for none, process 7, thinking"; say "mascot: turn gone for none, idle"
                            say "reply to phone/2 in run $run from session S1, process 7: hi"; say "done"; exec sleep 600 ;;
      answered-no-mascot) say "icloud: answered"; say "sending: hello"; say "reply to phone/2 in run $run from session S1, process 7: hi"
                          say "done"; exec sleep 600 ;;
      answered-old-format) say "icloud: answered"; say "sending: hello"; say "mascot: turn began for phone/2, process 7, idle"; say "mascot: turn gone for phone/2, idle"
                           say "reply to phone/2 in run $run: hi"; say "done"; exec sleep 600 ;;
      launched) case " $* " in *" --console-pty "*) echo "attached with nothing to wait for" >&2; exit 3 ;; esac; exit 0 ;;
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
                      say "guest turn 1 sent: a"; say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                      say "guest turn 1 answered in 9.10 s: ok"; say "guest turn 2 sent: b"
                      say "guest turn 2 model: claude-haiku-5-5, session S1, process 7"
                      say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-glued-stderr) say "guest turn 1 sent: a"; printf 'E5RT encountered an STL exception. msg = MILCompilerForANE error.'
                          say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                          printf 'E5RT: Failed to load program.'; say "guest turn 1 answered in 9.10 s: ok"; say "guest turn done"
                          exec sleep 600 ;;
      guest-one-failed) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                        say "guest turn 1 failed in 12.00 s: the process ended mid-turn"
                        say "guest turn 2 model: claude-haiku-5-5, session S1, process 7"
                        say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-abandoned) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                       say "guest turn 1 abandoned after 15.00 s"; say "guest turn 2 model: claude-haiku-5-5, session S1, process 7"
                       say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-two-processes) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                           say "guest turn 1 answered in 9.10 s: ok"
                           say "guest turn 2 model: claude-haiku-5-5, session S1, process 12"
                           say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-two-sessions) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                          say "guest turn 1 answered in 9.10 s: ok"
                          say "guest turn 2 model: claude-haiku-5-5, session S2, process 7"
                          say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-no-process) say "guest turn 1 model: claude-haiku-5-5, session S1"
                        say "guest turn 1 answered in 9.10 s: ok"
                        say "guest turn 2 model: claude-haiku-5-5, session S1"
                        say "guest turn 2 answered in 1.20 s: yes"; say "guest turn done"; exec sleep 600 ;;
      guest-bash) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                  say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: topo-42"
                  say "guest turn 1 answered in 6.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-no-call) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                          say "guest turn 1 answered in 2.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-failed) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                         say "guest turn 1 tool: Bash"
                         say "guest turn 1 tool result: Bash: error: No suitable shell found. topo-42"
                         say "guest turn 1 answered in 4.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-other-output) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                               say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: topo-41"
                               say "guest turn 1 answered in 4.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-other-tool) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                             say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: error: no shell"
                             say "guest turn 1 tool: Read"; say "guest turn 1 tool result: Read: ok: topo-42"
                             say "guest turn 1 answered in 4.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-reply-silent) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                               say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: topo-42"
                               say "guest turn 1 answered in 4.00 s: done"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-ok-only-in-prefix) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                                    say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: wrong output"
                                    say "guest turn 1 answered in 4.00 s: ok"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-in-reply-prefix-only) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                                       say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: answered"
                                       say "guest turn 1 answered in 4.00 s: done"; say "guest turn done"; exec sleep 600 ;;
      guest-bash-result-echoed-in-sent) say "guest turn 1 sent: [topo-debug] guest turn 1 tool result: Bash: ok: topo-42"
                                        say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                                        say "guest turn 1 tool: Bash"; say "guest turn 1 tool result: Bash: ok: wrong output"
                                        say "guest turn 1 answered in 4.00 s: topo-42"; say "guest turn done"; exec sleep 600 ;;
      guest-error) say "guest turn error: Claude Code did not start"; say "guest turn done"; exec sleep 600 ;;
      guest-opus) say "guest turn 1 model: claude-opus-5, session S1, process 7"; say "guest turn 1 answered in 3.00 s: ok"
                  say "guest turn 2 model: claude-opus-5, session S1, process 7"; say "guest turn 2 answered in 1.00 s: ok"
                  say "guest turn done"; exec sleep 600 ;;
      guest-one-short) say "guest turn 1 model: claude-haiku-5-5, session S1, process 7"
                       say "guest turn 1 answered in 3.00 s: ok"; say "guest turn done"; exec sleep 600 ;;
      *) echo "fake xcrun: no scenario '$FAKE_LAUNCH'" >&2; exit 99 ;;
    esac ;;
  *) exit 0 ;;
esac
EOF

# The suite `--press-mic` runs: a pass, or with FAKE_XCODEBUILD=hangs one that never finishes and
# has a child of its own holding its output, as a build service outliving xcodebuild would. Its
# sleeps are /bin/sleep's, so a case's slow `sleep` slows the script alone.
cat >"$work/bin/xcodebuild" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE_XCODEBUILD_CALLS"
# The leak check's test: it reads the dummy as the real one does, and records it as XCTest's
# typeText does (its first 18 characters in the output and the bundle) for the control, and for
# the redacted route only when FAKE_LEAK_REDACTED says the route leaks.
case " $* " in *" -only-testing:TopoSimulatorSignInTests/LeakCheckTests "*)
  dummy="$(/usr/bin/python3 -c '
import socket, sys
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5) as s:
    s.sendall(sys.argv[2].encode() + b"\n"); got = b""
    while chunk := s.recv(256): got += chunk
sys.stdout.write(got.decode())' "$TEST_RUNNER_TOPO_SIGNIN_PORT" "$TEST_RUNNER_TOPO_SIGNIN_NONCE")" || exit 65
  bundle="$(printf '%s\n' "$@" | grep -A1 -x -- -resultBundlePath | tail -1)"
  mkdir -p "$bundle"
  if [ "$TEST_RUNNER_TOPO_LEAKCHECK_ROUTE" = typeText ] || [ -n "${FAKE_LEAK_REDACTED:-}" ]; then
    [ "${FAKE_LEAK_SINK:-both}" = bundle ] || echo "t = Type '${dummy:0:18}...' into SecureTextField"
    [ "${FAKE_LEAK_SINK:-both}" = output ] || echo "Type '${dummy:0:18}...'" >"$bundle/database.sqlite3"
  fi
  if [ "${TEST_RUNNER_TOPO_LEAKCHECK_FAIL:-0}" = 1 ]; then
    echo "error: failing after the dummy, as a stopped sign-in does"
    [ -z "${FAKE_LEAK_RECORDS:-}" ] || printf '\0\0\0\x20ftypmp42' >"$bundle/recording"
    echo "** TEST FAILED **"; exit 65
  fi
  echo "** TEST SUCCEEDED **"; exit 0 ;;
esac
# The sign-in's test: what it was started with, and what the listener hands a request with a
# wrong nonce and then with the run's own.
case " $* " in *" TopoSimulatorSignIn "*)
  env | grep -v "^FAKE_APPLE_PASSWORD=" >"$FAKE_SIGNIN_ENV"  # the test's own copy is not the script's
  [ -z "${FAKE_SIGNIN_SAYS:-}" ] || echo "$FAKE_SIGNIN_SAYS"
  [ -n "${TEST_RUNNER_TOPO_SIGNIN_PORT:-}" ] || exit 0  # a resume serves nothing to ask
  /usr/bin/python3 -c '
import socket, sys
port, nonce, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
def ask(word):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
        s.sendall(word.encode() + b"\n"); got = b""
        while chunk := s.recv(256): got += chunk
        return got
import time
wrong = ask("not-the-nonce")
right = ask(nonce)
# Once answered the listener is gone: no later request with the nonce is given a byte, and one
# soon finds nobody there at all.
again = b"answered"
for _ in range(20):
    try:
        got = ask(nonce)
    except OSError:
        again = b"refused"; break
    if got:
        again = b"given again:" + got; break
    time.sleep(0.1)
open(out, "wb").write(b"wrong:" + wrong + b"\nright:" + right + b"\nagain:" + again)' \
    "${TEST_RUNNER_TOPO_SIGNIN_PORT:-0}" "${TEST_RUNNER_TOPO_SIGNIN_NONCE:-}" "$FAKE_SIGNIN_GOT" || exit 65
  ;;
esac
# The talk's build and test: what each was started with, and what the app the test launches
# would read from the port and nonce the runner hands it.
case " $* " in *" TopoTalk "*)
  env | grep -v "^FAKE_TALK_TOKEN=" >>"$FAKE_TALK_ENV"  # the test's own copy is not the script's
  ;;
esac
case " $* " in *" test-without-building "*" TopoTalk "*)
  [ -n "${FAKE_TALK_UNREAD:-}" ] || /usr/bin/python3 -c '
import socket, sys
port, nonce, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
    s.sendall(nonce.encode() + b"\n"); got = b""
    while chunk := s.recv(256): got += chunk
open(out, "wb").write(got)' "${TEST_RUNNER_TOPO_DEBUG_TOKEN_PORT:-0}" "${TEST_RUNNER_TOPO_DEBUG_TOKEN_NONCE:-}" "$FAKE_TALK_GOT" || exit 65
  ;;
esac
if [ "${FAKE_XCODEBUILD:-}" = hangs ]; then
  /bin/sleep 30 &
  exec -a sleep /bin/sleep 31
fi
echo "** TEST SUCCEEDED **"
EOF
# When the simulator and coreaudiod started, as `ps -o lstart=` gives it: FAKE_SIM_BOOTED
# (none: the simulator is shut down) and FAKE_AUDIO_STARTED. Pids 501 and 502 stand for them.
cat >"$work/bin/pgrep" <<'EOF2'
#!/bin/bash
case "$*" in
  "-x coreaudiod") echo 502 ;;
  *"/Devices/"*"/launchd_bootstrap.plist") [ -z "${FAKE_SIM_BOOTED:-}" ] || echo 501 ;;
  *) exit 1 ;;
esac
EOF2
cat >"$work/bin/ps" <<'EOF2'
#!/bin/bash
case "$*" in
  "-o lstart= -p 501") echo "${FAKE_SIM_BOOTED} " ;;
  "-o lstart= -p 502") echo "${FAKE_AUDIO_STARTED:-Wed Nov 11 17:10:52 2026} " ;;
  *) exit 1 ;;
esac
EOF2
chmod +x "$work/bin/xcrun" "$work/bin/op-item" "$work/bin/xcodebuild" "$work/bin/pgrep" "$work/bin/ps"

failures=0
export FAKE_LAUNCHER_PID="$work/launcher.pid" FAKE_XCODEBUILD_CALLS="$work/xcodebuild.calls"

# What a case waits is counted in the script's looks, not read off the clock: the script waits
# for its markers by looking once a second (`sleep 1` in wait_for, and no other `sleep 1` in it or
# its fakes), so a `sleep` ahead of the real one on its path notes each look. A loaded Mac makes a
# look take longer, never makes there be more of them.
mkdir -p "$work/looks"
printf '#!/bin/sh
[ "$*" != 1 ] || echo look >> "$LOOKS"
exec /bin/sleep "$@"
' >"$work/looks/sleep"
chmod +x "$work/looks/sleep"
patience=30

# case <name> <expected: pass|fail> <scenario> <quick|slow> [script args...]
# A `quick` case has nothing to wait out: it runs with a timeout of $patience looks and ends
# before its last, so one that waited the timeout out instead is caught by the count. A `slow`
# case waits out the script's own timeout, `wait`, and takes exactly that many looks.
case_() {
  local name="$1" want="$2" scenario="$3" kind="$4"; shift 4
  local out="$work/$name.out" status got left="" timeout looks
  if [ "$kind" = slow ]; then timeout="$wait"; else timeout="$patience"; fi
  rm -f "$FAKE_LAUNCHER_PID"
  : >"$work/$name.looks"
  LOOKS="$work/$name.looks" PATH="$work/looks:$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT="$timeout" \
    FAKE_LAUNCH="$scenario" "$work/root/scripts/simulator-run.sh" --no-build "$@" >"$out" 2>&1 </dev/null
  status=$?
  looks="$(wc -l <"$work/$name.looks" | tr -d ' ')"
  if [ "$status" = 0 ]; then got=pass; else got=fail; fi
  # Whatever way a run ends, it leaves no launcher running and no pids file.
  if [ -s "$FAKE_LAUNCHER_PID" ] && kill -0 "$(cat "$FAKE_LAUNCHER_PID")" 2>/dev/null; then
    left="its launcher running"
    kill "$(cat "$FAKE_LAUNCHER_PID")"
  elif [ -e "$work/root/build/sim/simulator-run.pids" ]; then
    left="its pids file behind"
    rm -f "$work/root/build/sim/simulator-run.pids"
  fi
  if [ -n "$left" ]; then
    echo "FAIL $name: the script exited $status and left $left"
    sed 's/^/    | /' "$out"
    failures=$((failures + 1))
  elif [ "$got" != "$want" ]; then
    echo "FAIL $name: wanted the script to $want, it exited $status"
    sed 's/^/    | /' "$out"
    failures=$((failures + 1))
  elif [ "$kind" = quick ] && [ "$looks" -ge "$timeout" ]; then
    echo "FAIL $name: exited $status as wanted, but only after waiting out its timeout ($looks looks)"
    sed 's/^/    | /' "$out"
    failures=$((failures + 1))
  elif [ "$kind" = slow ] && [ "$looks" != "$timeout" ]; then
    echo "FAIL $name: exited $status as wanted, after $looks looks, not its timeout's $timeout"
    sed 's/^/    | /' "$out"
    failures=$((failures + 1))
  else
    echo "ok   $name: exited $status after $looks looks — $(grep '^==>' "$out" | tail -1)"
  fi
}

# One untimed run first. The first case to exec the script, python3 (the device lookup), uuidgen
# and the fakes on a fresh runner pays for loading them, which has taken from 0 s to 9 s on the
# same script with the same scenario; the limits below are about what the script waits for, not
# about a cold disk.
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT=6 FAKE_LAUNCH=exits-42 \
  "$work/root/scripts/simulator-run.sh" --no-build >/dev/null 2>&1 </dev/null

# A second, warm run of the same scenario is what this machine takes to run the script through to
# its exit with nothing to wait for. The ended cases' limits are that plus what the case itself
# may take, so a loaded runner moves them with it: `quick` for a run that has nothing to wait out;
# and `wait` is the timeout of the cases that wait it out.
start=$SECONDS
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT=6 FAKE_LAUNCH=exits-42 \
  "$work/root/scripts/simulator-run.sh" --no-build >/dev/null 2>&1 </dev/null
overhead=$((SECONDS - start))
quick=$((5 + overhead))
wait=$((quick + 1))

case_ no-send-launcher-exits-nonzero       fail exits-42             quick
case_ no-send-stale-reply-launcher-exits-42 fail stale-reply-exits-42 quick
case_ send-stale-reply-launcher-exits-42   fail stale-reply-exits-42 quick  --send "new message"
case_ send-launcher-dies-before-done       fail dies-before-done     quick  --send hello
case_ send-reply-without-done              fail reply-no-done        slow --send hello
case_ send-times-out-silent                fail silent               slow --send hello
case_ send-done-with-error                 fail error-then-done      quick  --send hello
case_ send-reply-to-another-run            fail other-run            quick  --send hello
case_ send-no-reply-to-this-turn           fail no-reply             quick  --send hello
case_ send-done-then-launcher-exits-1      fail done-then-exits-1    quick  --send hello
case_ send-answered                        pass answered             quick  --send hello
case_ send-answered-on-the-phone           fail answered-on-the-phone quick --send hello
case_ send-no-icloud-account               fail no-account           quick  --send hello
case_ send-icloud-lapsed                   fail lapsed               quick  --send hello
case_ send-icloud-refused                  fail refused              quick  --send hello
case_ send-icloud-unavailable              fail unavailable          quick  --send hello
# Signed in with CloudKit refusing the account is a sign-in a restart ended, which only a
# sign-out and sign-in mend: the failure says so and names --renew.
grep -Fq "DEVICE=FAKE-UDID scripts/simulator-run.sh --sign-in --renew" "$work/send-icloud-unavailable.out" \
  && grep -Fq "a restart of the simulator ends it, and so does a change of the account's password" "$work/send-icloud-unavailable.out" \
  || { echo "FAIL send-icloud-unavailable: the failure does not name the restart and --renew"; sed 's/^/    | /' "$work/send-icloud-unavailable.out"; failures=$((failures + 1)); }
# A device with no account or a lapsed one is named, with the sign-in that mends it.
for c in send-no-icloud-account send-icloud-lapsed send-icloud-refused; do
  grep -Fq "DEVICE=FAKE-UDID scripts/simulator-run.sh --sign-in" "$work/$c.out" \
    || { echo "FAIL $c: the failure does not name the sign-in"; sed 's/^/    | /' "$work/$c.out"; failures=$((failures + 1)); }
done
case_ send-answered-by-no-resident         fail answered-by-nobody   quick  --send hello
case_ send-answered-mascot-silent          fail answered-no-mascot   quick  --send hello
case_ send-answered-mascot-other-turn      fail answered-other-mascot quick --send hello
case_ send-answered-heard-ahead            pass answered-heard       quick  --send hello
case_ send-answered-heard-other-nonce      fail answered-heard-other quick --send hello
case_ send-answered-no-provenance          fail answered-old-format  quick  --send hello
case_ no-send-launched                     pass launched             quick
case_ press-mic-no-send-exits              pass launched             quick --press-mic
# The suite ran, and before the launch: its line is in the run's output above the launch's.
if ! grep -q -- '-only-testing:TopoUITests' "$FAKE_XCODEBUILD_CALLS" 2>/dev/null \
  || [ "$(grep -n -m1 'TEST SUCCEEDED' "$work/press-mic-no-send-exits.out" | cut -d: -f1)" -ge \
       "$(grep -n -m1 '==> launching' "$work/press-mic-no-send-exits.out" | cut -d: -f1)" ] 2>/dev/null; then
  echo "FAIL press-mic-no-send-exits: the suite did not run before the launch"
  failures=$((failures + 1))
fi
case_ userland-ran                         pass userland-fetched     quick  --userland "echo hi" --expect hi
case_ userland-fetched-as-expected         pass userland-fetched     quick  --userland "echo hi" --expect-rootfs fetched
case_ userland-reused-as-expected          pass userland-reused      quick  --userland "echo hi" --expect-rootfs reused
case_ userland-fetched-when-reuse-expected fail userland-fetched     quick  --userland "echo hi" --expect-rootfs reused
case_ userland-reused-when-fetch-expected  fail userland-reused      quick  --userland "echo hi" --expect-rootfs fetched
case_ userland-error                       fail userland-error       quick  --userland "echo hi"
case_ userland-exit-nonzero                fail userland-exit-1      quick  --userland "echo hi"
case_ userland-other-output                fail userland-other-output quick --userland "echo hi" --expect hi
case_ userland-launcher-dies               fail userland-dies        quick  --userland "echo hi"
case_ userland-times-out-silent            fail silent               slow --userland "echo hi"
case_ userland-claude-fetched-as-expected  pass userland-fetched     quick  --userland "claude --version" --expect-claude fetched
case_ userland-claude-reused-as-expected   pass userland-reused      quick  --userland "claude --version" --expect-claude reused
case_ userland-claude-fetched-not-reused   fail userland-fetched     quick  --userland "claude --version" --expect-claude reused
case_ userland-claude-reused-not-fetched   fail userland-reused      quick  --userland "claude --version" --expect-claude fetched
case_ userland-claude-not-mounted          fail userland-unmounted   quick  --userland "echo hi"
case_ guest-turns-answered                 pass guest-answered       quick  --guest-turn "a || b"
case_ guest-turn-stderr-glued-on           pass guest-glued-stderr   quick  --guest-turn "a"
case_ guest-turn-failed                    fail guest-one-failed     quick  --guest-turn "a || b"
case_ guest-turn-abandoned                 fail guest-abandoned      quick  --guest-turn "a || b"
case_ guest-turns-two-processes           fail guest-two-processes  quick  --guest-turn "a || b"
case_ guest-turns-two-sessions            fail guest-two-sessions   quick  --guest-turn "a || b"
case_ guest-turns-no-process-named        fail guest-no-process     quick  --guest-turn "a || b"
case_ guest-turn-error                     fail guest-error          quick  --guest-turn "a || b"
case_ guest-turns-not-on-haiku             fail guest-opus           quick  --guest-turn "a || b"
case_ guest-turn-missing                   fail guest-one-short      quick  --guest-turn "a || b"
case_ guest-turn-ran-bash                  pass guest-bash           quick  --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-no-call              fail guest-bash-no-call   quick  --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-failed               fail guest-bash-failed    quick  --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-other-output         fail guest-bash-other-output quick --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-output-from-another  fail guest-bash-other-tool quick  --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-reply-without-it     fail guest-bash-reply-silent quick --guest-turn "a" --expect-bash topo-42
case_ guest-turn-bash-ok-only-in-prefix    fail guest-bash-ok-only-in-prefix quick --guest-turn "a" --expect-bash ok
case_ guest-turn-bash-reply-prefix-only    fail guest-bash-in-reply-prefix-only quick --guest-turn "a" --expect-bash answered
case_ guest-turn-bash-result-echoed-in-sent fail guest-bash-result-echoed-in-sent quick --guest-turn "a" --expect-bash topo-42
case_ guest-turns-times-out-silent         fail silent               slow --guest-turn "a || b"

# The pids file names what a run started and the script ends exactly those. A run left waiting
# is ended by SIGTERM to its first pid, the script's own, and takes its second, the child it was
# waiting on, with it, within the `quick` limit; the log is the run's whole output, kept after it.
# On a slow Mac, where every `sleep` the script starts takes half a second longer, it still ends
# within `quick`, the same load-relative limit as every case: its wait for tee is bounded by the
# clock and grows by one slow poll, not by twenty.
#
# ended <name> <the child's command> <whole log: yes|no> <slow: yes|no> [script args...]
ended() {
  local name="$1" child="$2" whole="$3" slow="$4"; shift 4
  local sim="$work/root/build/sim" out="$work/$name.out" runner waited=0 script_pid child_pid problem="" start status
  local path="$work/bin:$PATH"
  [ "$slow" = no ] || path="$work/slow:$path"
  PATH="$path" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT=60 FAKE_LAUNCH=silent FAKE_XCODEBUILD=hangs \
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

mkdir -p "$work/slow"
printf '#!/bin/sh\n/bin/sleep 0.5\nexec /bin/sleep "$@"\n' >"$work/slow/sleep"
chmod +x "$work/slow/sleep"

ended ended-waiting-on-the-launcher "sleep 600" yes no --send hello
# The suite's own child still holds the run's output when the script ends, so the script's exit is
# what is held here and not that the log is whole yet.
ended ended-during-the-suite        "sleep 31"  no  no  --press-mic
ended ended-during-the-suite-slowly "sleep 31"  no  yes --press-mic

# --talk and the audio lane, against fakes of the lane, the two model fetches and the results'
# check. The lane's fake
# writes what it was called with to a file. A start that refuses (exit 3) found another run's
# lane: the script exits 3 and never calls stop. A start that fails any other way is this run's
# to stop.
for fake in fetch-ear-models.sh phonon-bundles.sh ci-require-tests.sh; do printf '#!/bin/sh\nexit 0\n' > "$work/root/scripts/$fake"; done
cat >"$work/root/scripts/ci-audio-lane.sh" <<EOF
#!/bin/sh
echo "\$1" >> "$work/lane-calls"
[ "\$1" != start ] || echo "\${AUDIO_LANE_OWNER-}:\$PPID" > "$work/lane-owner"
[ "\$1" != start ] || exit "\$FAKE_LANE_START"
EOF
chmod +x "$work/root/scripts/"*.sh

# talk_case <name> <start's exit> <the lane calls expected, space-separated>
talk_case() {
  local name="$1" start_exit="$2" want="$3" out="$work/$1.out" status calls
  rm -f "$work/lane-calls"
  PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder FAKE_LAUNCH=silent FAKE_LANE_START="$start_exit" \
    "$work/root/scripts/simulator-run.sh" --no-build --talk >"$out" 2>&1 </dev/null
  status=$?
  calls="$(tr '\n' ' ' < "$work/lane-calls" | sed 's/ $//')"
  if [ "$status" = "$start_exit" ] && [ "$calls" = "$want" ]; then
    echo "ok   $name: exited $status, the lane was called with: $calls"
  else
    echo "FAIL $name: wanted exit $start_exit and the lane calls '$want'; got exit $status and '$calls'"
    sed 's/^/    | /' "$out"
    failures=$((failures + 1))
  fi
}
talk_case talk-start-refused-leaves-the-lane 3 "start"
talk_case talk-start-failed-stops-the-lane   1 "start stop"
# The lane --talk starts is on record as the run's own, so a later start stops it once the run
# has ended without stopping it (scripts/tests/ci-audio-lane-test.sh holds that half).
IFS=: read -r owner parent < "$work/lane-owner"
if [ -n "$owner" ] && [ "$owner" = "$parent" ]; then
  echo "ok   talk-lane-has-an-owner: start was given AUDIO_LANE_OWNER=$owner, the script's own pid"
else
  echo "FAIL talk-lane-has-an-owner: start was given AUDIO_LANE_OWNER='$owner'; the script's pid was $parent"
  failures=$((failures + 1))
fi

# A --talk that reaches its test: the token is served once to the request with the run's nonce,
# and is in none of xcodebuild's arguments, its environment or the run's output, since the result
# bundle records the runner's environment and the app's launch environment whole, and the build
# description xcodebuild's own; and the test collects no diagnostics, which are the simulator's log.
token="fake-claude-token-$$"
: >"$FAKE_XCODEBUILD_CALLS"; : >"$work/talk.env"
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_TALK_TOKEN="$token" FAKE_LAUNCH=silent FAKE_LANE_START=0 \
  FAKE_TALK_ENV="$work/talk.env" FAKE_TALK_GOT="$work/talk.got" \
  "$work/root/scripts/simulator-run.sh" --no-build --talk >"$work/talk.out" 2>&1 </dev/null
status=$?
got="$(cat "$work/talk.got" 2>/dev/null)"
leaks="$(grep -lF "$token" "$FAKE_XCODEBUILD_CALLS" "$work/talk.env" "$work/talk.out" "$work/root/build/sim/simulator-run.log" 2>/dev/null)"
if [ "$status" = 0 ] && [ "$got" = "$token" ] && [ -z "$leaks" ] && [ "$(cut -d" " -f1 "$FAKE_XCODEBUILD_CALLS" | tr "\n" " ")" = "build-for-testing test-without-building " ] \
   && grep -q "^test-without-building .*-collect-test-diagnostics never" "$FAKE_XCODEBUILD_CALLS"; then
  echo "ok   talk-token-served: the test's app got the token from the run's nonce, and no argument, environment or output carries it"
else
  echo "FAIL talk-token-served: exit $status, the app read $([ "$got" = "$token" ] && echo the token || echo "something else"), the token is in: ${leaks:-nothing}, xcodebuild was called with: $(tr "\n" "|" < "$FAKE_XCODEBUILD_CALLS")"
  sed 's/^/    | /' "$work/talk.out" | grep -vF "$token"
  failures=$((failures + 1))
fi

# --talk reboots the simulator only when it booted before coreaudiod started, since a reboot ends
# its iCloud sign-in: one booted since hears the lane as it is, one shut down is booted, and one
# rebooted says the sign-in is gone and names --renew.
# reboot_case <name> <when the simulator booted, or empty> <simctl calls expected among boot/shutdown> [text]
reboot_case() {
  local name="$1" out="$work/$1.out" status calls
  : >"$work/simctl.calls"
  PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_TALK_TOKEN="$token" FAKE_LAUNCH=silent FAKE_LANE_START=0 \
    FAKE_TALK_ENV="$work/$1.env" FAKE_TALK_GOT="$work/$1.got" FAKE_SIMCTL_CALLS="$work/simctl.calls" FAKE_SIM_BOOTED="$2" \
    FAKE_AUDIO_STARTED="Wed Nov 11 17:10:52 2026" "$work/root/scripts/simulator-run.sh" --no-build --talk >"$out" 2>&1 </dev/null
  status=$?
  calls="$(grep -xE 'boot|shutdown' "$work/simctl.calls" | tr '\n' ' ' | sed 's/ $//')"
  if [ "$status" = 0 ] && [ "$calls" = "$3" ] && { [ -z "${4:-}" ] || grep -Fq "$4" "$out"; }; then
    echo "ok   $name: simctl was asked: ${calls:-neither boot nor shutdown}"
  else
    echo "FAIL $name: exit $status, wanted '$3'${4:+ and \"$4\"}, simctl was asked '$calls'"
    sed 's/^/    | /' "$out" | grep -vF "$token"
    failures=$((failures + 1))
  fi
}
reboot_case talk-booted-since-audio  "Sat Nov 14 13:32:28 2026" ""
reboot_case talk-booted-before-audio "Mon Nov  9 09:05:01 2026" "shutdown boot" "scripts/simulator-run.sh --sign-in --renew"
reboot_case talk-shut-down           ""                         "boot"

# A talk test that passes without the app having read the token (the app ran on some other
# login) fails the run.
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_TALK_TOKEN="$token" FAKE_LAUNCH=silent FAKE_LANE_START=0 \
  FAKE_TALK_ENV="$work/talk-unread.env" FAKE_TALK_GOT="$work/talk-unread.got" FAKE_TALK_UNREAD=1 \
  "$work/root/scripts/simulator-run.sh" --no-build --talk >"$work/talk-unread.out" 2>&1 </dev/null
status=$?
if [ "$status" != 0 ] && grep -q "the app never read the served token" "$work/talk-unread.out"; then
  echo "ok   talk-token-unread: a test that passed with the token never read exits $status and says so"
else
  echo "FAIL talk-token-unread: exit $status"
  sed 's/^/    | /' "$work/talk-unread.out" | grep -vF "$token"
  failures=$((failures + 1))
fi

# --sign-in, against a fake vault and a fake test that asks the listener for the password: the
# listener hands nothing to a request without the run's nonce and the password to one with it,
# and the password is in none of the test runner's arguments, its environment or the run's output.
secret="fake-apple-password-$$"
: >"$FAKE_XCODEBUILD_CALLS"
PATH="$work/bin:$PATH" FAKE_APPLE_PASSWORD="$secret" FAKE_SIGNIN_ENV="$work/signin.env" FAKE_SIGNIN_GOT="$work/signin.got" \
  "$work/root/scripts/simulator-run.sh" --no-build --sign-in >"$work/signin.out" 2>&1 </dev/null
status=$?
got="$(cat "$work/signin.got" 2>/dev/null)"
leaks="$(grep -lF "$secret" "$FAKE_XCODEBUILD_CALLS" "$work/signin.env" "$work/signin.out" "$work/root/build/sim/simulator-run.log" 2>/dev/null)"
if [ "$status" = 0 ] && [ "$got" = "$(printf 'wrong:\nright:%s\nagain:refused' "$secret")" ] && [ -z "$leaks" ] \
   && grep -q "TEST_RUNNER_TOPO_SIGNIN_ACCOUNT=buddy.durose@icloud.com" "$work/signin.env"; then
  echo "ok   sign-in-password-once: the nonce's first request alone got the password, which no argument, environment or output carries"
else
  echo "FAIL sign-in-password-once: exit $status, the listener gave: $(printf %s "$got" | tr "\n" "|"), the password is in: ${leaks:-nothing}"
  sed 's/^/    | /' "$work/signin.out"
  failures=$((failures + 1))
fi
# The sign-in's test collects no diagnostics, which are the simulator's log archive, and is told
# to renew only when asked; --renew is refused without --sign-in.
renew_case() {
  local name="$1" want="$2"; shift 2
  : >"$FAKE_XCODEBUILD_CALLS"
  PATH="$work/bin:$PATH" FAKE_APPLE_PASSWORD="$secret" FAKE_SIGNIN_ENV="$work/$name.env" FAKE_SIGNIN_GOT="$work/$name.got" \
    "$work/root/scripts/simulator-run.sh" --no-build "$@" >"$work/$name.out" 2>&1 </dev/null
  local status=$?
  if [ "$status" = 0 ] && grep -qx "TEST_RUNNER_TOPO_SIGNIN_RENEW=$want" "$work/$name.env" \
     && grep -q "^test .*-collect-test-diagnostics never" "$FAKE_XCODEBUILD_CALLS"; then
    echo "ok   $name: the test was told TOPO_SIGNIN_RENEW=$want and collects no diagnostics"
  else
    echo "FAIL $name: exit $status, wanted TOPO_SIGNIN_RENEW=$want; the test got: $(grep RENEW "$work/$name.env" 2>/dev/null), xcodebuild: $(cat "$FAKE_XCODEBUILD_CALLS")"
    sed 's/^/    | /' "$work/$name.out"
    failures=$((failures + 1))
  fi
}
renew_case sign-in-renews-when-asked 1 --sign-in --renew
FAKE_SIGNIN_SAYS="[sign-in] already signed in as buddy.durose@icloud.com, and nothing asks for the password" \
  renew_case sign-in-keeps-the-account 0 --sign-in
grep -Fq "scripts/simulator-run.sh --sign-in --renew" "$work/sign-in-keeps-the-account.out" \
  || { echo "FAIL sign-in-names-renew: an already-signed-in device's line does not name --renew"; failures=$((failures + 1)); }
: >"$FAKE_XCODEBUILD_CALLS"
PATH="$work/bin:$PATH" "$work/root/scripts/simulator-run.sh" --no-build --renew >"$work/renew-alone.out" 2>&1 </dev/null
status=$?
if [ "$status" = 2 ] && [ ! -s "$FAKE_XCODEBUILD_CALLS" ]; then
  echo "ok   renew-without-sign-in: refused with exit 2"
else
  echo "FAIL renew-without-sign-in: exit $status"; failures=$((failures + 1))
fi
# A resume reads no vault item (the fake one fails) and serves nothing, and its test runs only
# the sign-in's suite; --resume is refused with --renew, and --leak-check with --sign-in.
: >"$FAKE_XCODEBUILD_CALLS"
PATH="$work/bin:$PATH" FAKE_SIGNIN_ENV="$work/resume.env" \
  "$work/root/scripts/simulator-run.sh" --no-build --sign-in --resume >"$work/resume.out" 2>&1 </dev/null
status=$?
if [ "$status" = 0 ] && grep -qx "TEST_RUNNER_TOPO_SIGNIN_RESUME=1" "$work/resume.env" \
   && grep -qx "TEST_RUNNER_TOPO_SIGNIN_PORT=" "$work/resume.env" \
   && grep -q -- "-only-testing:TopoSimulatorSignInTests/SimulatorSignInTests " "$FAKE_XCODEBUILD_CALLS"; then
  echo "ok   sign-in-resume: no password read or served, the test told to resume"
else
  echo "FAIL sign-in-resume: exit $status; the test got: $(grep -E 'RESUME|PORT' "$work/resume.env" 2>/dev/null | tr '\n' ' '), xcodebuild: $(cat "$FAKE_XCODEBUILD_CALLS")"
  sed 's/^/    | /' "$work/resume.out"
  failures=$((failures + 1))
fi
for refused in "--sign-in --resume --renew" "--sign-in --leak-check"; do
  : >"$FAKE_XCODEBUILD_CALLS"
  # shellcheck disable=SC2086
  PATH="$work/bin:$PATH" "$work/root/scripts/simulator-run.sh" --no-build $refused >"$work/refused.out" 2>&1 </dev/null
  status=$?
  if [ "$status" = 2 ] && [ ! -s "$FAKE_XCODEBUILD_CALLS" ]; then
    echo "ok   refused: $refused exits 2"
  else
    echo "FAIL refused: $refused exited $status"; failures=$((failures + 1))
  fi
done
# The leak check passes only when the control's dummy is found in the output and the bundle, the
# redacted one nowhere, and a failing run's bundle holds no screen recording; a control the count
# cannot see fails it as a leak does.
printf '#!/bin/sh\nexit 0\n' >"$work/bin/log"; chmod +x "$work/bin/log"
leak_case() {
  local name="$1" want="$2"; shift 2
  : >"$FAKE_XCODEBUILD_CALLS"
  env PATH="$work/bin:$PATH" "$@" "$work/root/scripts/simulator-run.sh" --no-build --leak-check >"$work/$name.out" 2>&1 </dev/null
  local status=$?
  if [ "$status" = "$want" ] && [ "$(grep -c -- '-only-testing:TopoSimulatorSignInTests/LeakCheckTests' "$FAKE_XCODEBUILD_CALLS")" = 3 ] \
     && ! grep -q "TopoLeakCheck" <(ls "$work/root/build/sim"); then
    echo "ok   $name: exit $status, every route run, no bundle kept"
  else
    echo "FAIL $name: exit $status, wanted $want"; sed 's/^/    | /' "$work/$name.out"; failures=$((failures + 1))
  fi
}
leak_case leak-check-clean 0 FAKE_LEAK=none
leak_case leak-check-redacted-leaks 1 FAKE_LEAK_REDACTED=1
leak_case leak-check-control-unseen-in-bundle 1 FAKE_LEAK_SINK=output
leak_case leak-check-control-unseen-in-output 1 FAKE_LEAK_SINK=bundle
leak_case leak-check-failing-run-recorded 1 FAKE_LEAK_RECORDS=1
# A vault that gives no password stops the run before any test starts.
: >"$FAKE_XCODEBUILD_CALLS"
PATH="$work/bin:$PATH" "$work/root/scripts/simulator-run.sh" --no-build --sign-in >"$work/signin-none.out" 2>&1 </dev/null
status=$?
if [ "$status" != 0 ] && [ ! -s "$FAKE_XCODEBUILD_CALLS" ]; then
  echo "ok   sign-in-no-password: exited $status, no test started"
else
  echo "FAIL sign-in-no-password: exit $status, xcodebuild was called with: $(cat "$FAKE_XCODEBUILD_CALLS")"
  failures=$((failures + 1))
fi

# A name resolves to its device on the newest runtime, compared by every part of the version.
: >"$FAKE_XCODEBUILD_CALLS"
list='{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2-1":[{"name":"iPhone 17","udid":"AAA-NEWER"}],"com.apple.CoreSimulator.SimRuntime.iOS-27-2":[{"name":"iPhone 17","udid":"ZZZ-OLDER"}],"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"name":"iPhone 17","udid":"ZZZ-OLDEST"}]}}'
PATH="$work/bin:$PATH" FAKE_SIM_LIST="$list" FAKE_APPLE_PASSWORD="$secret" FAKE_SIGNIN_ENV="$work/runtime.env" \
  FAKE_SIGNIN_GOT="$work/runtime.got" "$work/root/scripts/simulator-run.sh" --no-build --sign-in >"$work/runtime.out" 2>&1 </dev/null
if grep -q "id=AAA-NEWER" "$FAKE_XCODEBUILD_CALLS"; then
  echo "ok   newest-runtime: iPhone 17 is the device on iOS 27.2.1, not 27.2's"
else
  echo "FAIL newest-runtime: xcodebuild was called with: $(cat "$FAKE_XCODEBUILD_CALLS")"
  failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed against $script"
  exit 1
fi
echo "all cases held against $script"
