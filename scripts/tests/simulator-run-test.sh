#!/usr/bin/env bash
# Runs scripts/simulator-run.sh against a fake `xcrun` whose `simctl launch` plays one scripted
# console per case, and holds that the script exits non-zero on every way a run can fail and zero
# only on a turn that finished and was answered under this run's id. No simulator, no build, no
# token, no network: every exported variable whose name says it holds a secret is dropped before
# anything runs (scripts/secret-env.sh), so no fake's record of its environment holds a real one;
# CLAUDE_SETUP_TOKEN is a placeholder and `op-item` is a fake that fails, or with --sign-in gives a
# placeholder password the case then looks for everywhere it must not be.
# It holds that a run that used the device shuts it down as it ends, passing, failing or signalled,
# but not under another run or a run that leaves it up on purpose, and that a lapsed sign-in is
# renewed once and never past a sign-in that stopped.
# With --talk and a fake audio lane, it holds that a `start` that refuses is never followed by `stop`,
# and that `start` is given the script's own pid as the lane's owner.
#
#   scripts/tests/simulator-run-test.sh
#   SCRIPT=/path/to/other/simulator-run.sh scripts/tests/simulator-run-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="${SCRIPT:-$here/../simulator-run.sh}"
[ -f "$script" ] || { echo "no script at $script" >&2; exit 2; }

source "$here/../secret-env.sh"
drop_secrets

work="$(mktemp -d -t simulator-run-test)"
trap 'rm -rf "$work"' EXIT
# Where the script keeps the device's lock, its last use and a stopped sign-in: the work tree's,
# never the Mac's, so no case reads or writes what a real run left.
export TOPO_SIM_STATE="$work/simstate"

# A tree shaped like the repo as far as the script looks: itself and what it sources under
# scripts/, and a built app.
mkdir -p "$work/root/scripts" "$work/root/build/sim/Build/Products/Debug-iphonesimulator/Topo.app" "$work/bin"
cp "$script" "$work/root/scripts/simulator-run.sh"
cp "$(dirname "$script")/secret-env.sh" "$work/root/scripts/" 2>/dev/null || cp "$here/../secret-env.sh" "$work/root/scripts/"
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
    # The launcher's pid, for the test to hold that no run leaves one behind, and one line a launch.
    echo "$$" >"$FAKE_LAUNCHER_PID"
    echo "run=${SIMCTL_CHILD_TOPO_DEBUG_RUN:-} nonce=${SIMCTL_CHILD_TOPO_DEBUG_TOKEN_NONCE:-} port=${SIMCTL_CHILD_TOPO_DEBUG_TOKEN_PORT:-}" >>"${FAKE_LAUNCHES:-/dev/null}"
    # Another run's sign-in passing while this launch runs, once.
    if [ -n "${FAKE_LAUNCH_SIGNS:-}" ] && [ ! -e "$FAKE_LAUNCH_SIGNS.done" ]; then uuidgen >"$FAKE_LAUNCH_SIGNS"; touch "$FAKE_LAUNCH_SIGNS.done"; fi
    # What the launch carries, which is what the simulator's log records, and the token the app
    # reads at launch from the port and nonce it was handed, unless FAKE_APP_UNREAD says it never asks.
    [ -z "${FAKE_LAUNCH_ENV:-}" ] || { echo "$*"; env; } >"$FAKE_LAUNCH_ENV"
    [ -z "${FAKE_LAUNCH_PORT:-}" ] || echo "${SIMCTL_CHILD_TOPO_DEBUG_TOKEN_PORT:-}" >"$FAKE_LAUNCH_PORT"
    if [ -n "${SIMCTL_CHILD_TOPO_DEBUG_TOKEN_PORT:-}" ] && [ -z "${FAKE_APP_UNREAD:-}" ]; then
      /usr/bin/python3 -c '
import socket, sys
port, nonce, out = int(sys.argv[1]), sys.argv[2], sys.argv[3]
with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
    s.sendall(nonce.encode() + b"\n"); got = b""
    while chunk := s.recv(256): got += chunk
open(out, "wb").write(got)' "$SIMCTL_CHILD_TOPO_DEBUG_TOKEN_PORT" "${SIMCTL_CHILD_TOPO_DEBUG_TOKEN_NONCE:-}" "${FAKE_LAUNCH_GOT:-/dev/null}" || exit 65
    fi
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
      unavailable-then-answered)
        if [ "$(wc -l <"$FAKE_LAUNCHES" | tr -d ' ')" -lt 2 ]; then say "icloud: account temporarily unavailable"; say "done"; exec sleep 600; fi
        say "icloud: answered"; say "sending: hello"; say "mascot: turn began for phone/2, process 7, idle"
        say "mascot: turn gone for phone/2, idle"; say "reply to phone/2 in run $run from session S1, process 7: hi"
        say "records: iCloud"; say "done"; exec sleep 600 ;;
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
  # A boot of a device that is up fails, as simctl's does; FAKE_SIM_BOOTS=fresh is one that was down.
  boot) [ "${FAKE_SIM_BOOTS:-}" = fresh ] || exit 149 ;;
  # A log show prints lines, and with FAKE_LOG_FAILS fails having printed none.
  spawn) echo "a line of the device's log"; [ -z "${FAKE_LOG_FAILS:-}" ] || exit 1 ;;
  *) exit 0 ;;
esac
EOF

# The suite `--press-mic` runs: a pass, or with FAKE_XCODEBUILD=hangs one that never finishes and
# has a child of its own holding its output, as a build service outliving xcodebuild would. Its
# sleeps are /bin/sleep's, so a case's slow `sleep` slows the script alone.
cat >"$work/bin/xcodebuild" <<'EOF'
#!/bin/bash
echo "$*" >>"$FAKE_XCODEBUILD_CALLS"
[ -z "${FAKE_BUILD_ENV:-}" ] || env >>"$FAKE_BUILD_ENV"
# Another run's sign-in passing while the suite runs.
case " $* " in *" -only-testing:TopoUITests"*) [ -z "${FAKE_UI_SIGNS:-}" ] || uuidgen >"$FAKE_UI_SIGNS" ;; esac
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
  as="$TEST_RUNNER_TOPO_LEAKCHECK_ROUTE"; [ "${TEST_RUNNER_TOPO_LEAKCHECK_FAIL:-0}" != 1 ] || as=failing
  [ "${FAKE_LEAK_WRONG:-}" = "$as" ] || echo "[leak-check] $as typed the dummy whole"
  if [ -n "${FAKE_LEAK_UNREADABLE:-}" ] && [ "$as" = redacted ]; then
    if [ "$FAKE_LEAK_UNREADABLE" = folder ]; then
      mkdir -p "$bundle/Attachments"; echo x >"$bundle/Attachments/a"; chmod 000 "$bundle/Attachments"
    else
      echo x >"$bundle/attachment"; chmod 000 "$bundle/attachment"
    fi
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
  # Another run in the worktree starting, which begins the run's log afresh.
  [ -z "${FAKE_SIGNIN_TRUNCATES:-}" ] || : >"$FAKE_SIGNIN_TRUNCATES"
  # A sign-in still in Settings when the case signals the run.
  [ -z "${FAKE_SIGNIN_HANGS:-}" ] || { touch "$FAKE_SIGNIN_HANGS"; exec /bin/sleep 30; }
  # A sign-in that leaves a process of its own behind, as a build service outliving xcodebuild would.
  [ -z "${FAKE_SIGNIN_LEAVES:-}" ] || { /bin/sleep 20 </dev/null >/dev/null 2>&1 & }
  if [ -n "${FAKE_SIGNIN_STOPS:-}" ]; then echo "[sign-in] stopped: Settings asks for a verification code"; echo "** TEST FAILED **"; exit 65; fi
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
  # Typed as typeText would, the served password's first 18 characters in the output.
  [ -z "${FAKE_SIGNIN_LEAKS:-}" ] || echo "Type '$(sed -n 's/^right://p' "$FAKE_SIGNIN_GOT" | cut -c1-18)...' into \"password-field\""
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
# Outside the C locale it writes the day and month as a French locale would, which a reader that
# does not ask for C cannot parse.
cat >"$work/bin/ps" <<'EOF2'
#!/bin/bash
c() { if [ "${LC_ALL:-}" = C ]; then cat; else sed 's/^Sat/sam./; s/^Mon/lun./; s/^Wed/mer./; s/ Nov / nov. /'; fi; }
case "$*" in
  # The process list: launchd and what FAKE_PS_LIST adds, or with FAKE_PS_FAILS no list at all.
  "-axwwo pid=,ppid=,command=") [ -z "${FAKE_PS_FAILS:-}" ] || exit 1
                                echo "    1     0 /sbin/launchd"; [ -z "${FAKE_PS_LIST:-}" ] || printf '%s\n' "$FAKE_PS_LIST"
                                # The run itself and everything under it, as a real list shows them,
                                # which the run is to leave out of what is using the device.
                                /bin/ps -axwwo pid=,ppid=,command= | awk -v me="$$" '
                                  { pid[NR] = $1; ppid[NR] = $2; line[NR] = $0; at[$1] = NR }
                                  END {
                                    for (p = me; p in at; p = ppid[at[p]]) if (line[at[p]] ~ /simulator-run\.sh/ && line[at[p]] !~ /simulator-run-test\.sh/) top = p
                                    if (!top) exit
                                    mine[top] = 1
                                    do { grew = 0; for (i = 1; i <= NR; i++) if (!(pid[i] in mine) && (ppid[i] in mine)) { mine[pid[i]] = 1; grew = 1 } } while (grew)
                                    for (i = 1; i <= NR; i++) if (pid[i] in mine && pid[i] != me) print line[i]
                                  }' ;;
  "-o lstart= -p 501") echo "${FAKE_SIM_BOOTED} " | c ;;
  "-o lstart= -p 502") echo "${FAKE_AUDIO_STARTED:-Wed Nov 11 17:10:52 2026} " | c ;;
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
# Its test collects no diagnostics: they are the simulator's log archive, which records every
# launch's environment.
grep -- '-only-testing:TopoUITests' "$FAKE_XCODEBUILD_CALLS" | grep -q -- '-collect-test-diagnostics never' \
  || { echo "FAIL press-mic-no-diagnostics: the suite's test collects diagnostics"; failures=$((failures + 1)); }
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
  # The child is the recorded pid running that command: a token's listener may be recorded first.
  find_child() {
    local pid
    for pid in $(sed 1d "$sim/simulator-run.pids" 2>/dev/null); do
      [ "$(ps -o command= -p "$pid" 2>/dev/null)" = "$child" ] && { echo "$pid"; return; }
    done
  }
  until [ -n "$(find_child)" ] || [ "$waited" -ge $((10 + overhead)) ]; do
    sleep 1
    waited=$((waited + 1))
  done
  script_pid="$(sed -n 1p "$sim/simulator-run.pids" 2>/dev/null)"
  child_pid="$(find_child)"
  start=$SECONDS
  if [ -z "$script_pid" ] || [ -z "$child_pid" ]; then
    problem="the pids file did not name the script and '$child'"
    kill "$runner" 2>/dev/null
  elif [ "$script_pid" != "$runner" ]; then
    problem="the pids file's first line is $script_pid, and the script is $runner"
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
  FAKE_TALK_ENV="$work/talk.env" FAKE_TALK_GOT="$work/talk.got" FAKE_SIM_BOOTED="Sat Nov 14 13:32:28 2026" \
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
# rebooted is rebooted; a boot of either kind renews the sign-in before the test, and every run
# shuts the device down as it ends.
# reboot_case <name> <when the simulator booted, or empty> <simctl calls expected among boot/shutdown> [text]
reboot_case() {
  local name="$1" out="$work/$1.out" status calls
  : >"$work/simctl.calls"
  PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_TALK_TOKEN="$token" FAKE_LAUNCH=silent FAKE_LANE_START=0 \
    FAKE_TALK_ENV="$work/$1.env" FAKE_TALK_GOT="$work/$1.got" FAKE_SIMCTL_CALLS="$work/simctl.calls" FAKE_SIM_BOOTED="$2" \
    FAKE_APPLE_PASSWORD="fake-apple-$$" FAKE_SIGNIN_ENV="$work/$1.signin.env" FAKE_SIGNIN_GOT="$work/$1.signin.got" \
    FAKE_SIM_BOOTS=fresh FAKE_AUDIO_STARTED="Wed Nov 11 17:10:52 2026" LC_ALL=fr_FR.UTF-8 \
    "$work/root/scripts/simulator-run.sh" --no-build --talk >"$out" 2>&1 </dev/null
  status=$?
  calls="$(grep -xE 'boot|shutdown' "$work/simctl.calls" | tr '\n' ' ' | sed 's/ $//')"
  # A boot renews the sign-in, and only a boot does.
  local renewed=no
  grep -qx "TEST_RUNNER_TOPO_SIGNIN_RENEW=1" "$work/$1.signin.env" 2>/dev/null && renewed=yes
  rm -f "$work/$1.signin.env"
  if [ "$status" = 0 ] && [ "$calls" = "$3" ] && [ "$renewed" = "$4" ]; then
    echo "ok   $name: simctl was asked: ${calls:-neither boot nor shutdown}"
  else
    echo "FAIL $name: exit $status, wanted '$3' and a renewal: $4, simctl was asked '$calls', renewed: $renewed"
    sed 's/^/    | /' "$out" | grep -vF "$token"
    failures=$((failures + 1))
  fi
}
mkdir -p "$TOPO_SIM_STATE"; touch "$TOPO_SIM_STATE/FAKE-UDID.signed-in"
reboot_case talk-booted-since-audio  "Sat Nov 14 13:32:28 2026" "shutdown"               no
# The renewal's own boot finds the device up.
reboot_case talk-booted-before-audio "Mon Nov  9 09:05:01 2026" "shutdown boot boot shutdown" yes
reboot_case talk-shut-down           ""                         "boot boot shutdown"          yes
# A reboot under another run using the device is refused, and the device is left to it.
: >"$work/simctl.calls"
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_LANE_START=0 FAKE_LAUNCH=silent FAKE_SIMCTL_CALLS="$work/simctl.calls" \
  FAKE_SIM_BOOTED="Mon Nov  9 09:05:01 2026" FAKE_AUDIO_STARTED="Wed Nov 11 17:10:52 2026" \
  FAKE_PS_LIST="  999     1 /opt/homebrew/bin/bash scripts/simulator-run.sh --send hi" \
  "$work/root/scripts/simulator-run.sh" --no-build --talk >"$work/talk-reboot-in-use.out" 2>&1 </dev/null
status=$?
if [ "$status" = 1 ] && ! grep -qx 'shutdown\|boot' "$work/simctl.calls" && grep -q "these runs are using it" "$work/talk-reboot-in-use.out"; then
  echo "ok   talk-reboot-in-use: refused, and neither shut down nor booted"
else
  echo "FAIL talk-reboot-in-use: exit $status, simctl: $(tr '\n' ' ' <"$work/simctl.calls")"
  sed 's/^/    | /' "$work/talk-reboot-in-use.out" | grep -vF "$token"; failures=$((failures + 1))
fi
# A stop standing refuses --talk's reboot before it takes the device down.
echo stopped >"$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"; : >"$work/simctl.calls"
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_LANE_START=0 FAKE_LAUNCH=silent FAKE_SIMCTL_CALLS="$work/simctl.calls" \
  FAKE_SIM_BOOTED="Mon Nov  9 09:05:01 2026" FAKE_AUDIO_STARTED="Wed Nov 11 17:10:52 2026" \
  "$work/root/scripts/simulator-run.sh" --no-build --talk >"$work/talk-reboot-stopped.out" 2>&1 </dev/null
status=$?
if [ "$status" = 1 ] && ! grep -qx 'shutdown\|boot' "$work/simctl.calls" && grep -q "types no password" "$work/talk-reboot-stopped.out"; then
  echo "ok   talk-reboot-stopped: refused before the reboot, and the device neither shut down nor booted"
else
  echo "FAIL talk-reboot-stopped: exit $status, simctl: $(tr '\n' ' ' <"$work/simctl.calls")"
  sed 's/^/    | /' "$work/talk-reboot-stopped.out" | grep -vF "$token"; failures=$((failures + 1))
fi
rm -f "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
# A stop recorded while --talk waits for the lock is read under it, before the reboot's shutdown.
: >"$work/simctl.calls"; rm -f "$work/talk-reboot-stop-waited.out"
lockf "$TOPO_SIM_STATE/mutex" sh -c "for _ in \$(seq 600); do grep -q 'rebooting the simulator' '$work/talk-reboot-stop-waited.out' 2>/dev/null && break; /bin/sleep 0.1; done; echo refused >'$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped'" &
holder=$!
for _ in $(seq 50); do lockf -s -t 0 "$TOPO_SIM_STATE/mutex" true 2>/dev/null || break; /bin/sleep 0.1; done
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_LANE_START=0 FAKE_LAUNCH=silent FAKE_SIMCTL_CALLS="$work/simctl.calls" \
  FAKE_SIM_BOOTED="Mon Nov  9 09:05:01 2026" FAKE_AUDIO_STARTED="Wed Nov 11 17:10:52 2026" \
  "$work/root/scripts/simulator-run.sh" --no-build --talk >"$work/talk-reboot-stop-waited.out" 2>&1 </dev/null
status=$?
wait "$holder"
if [ "$status" = 1 ] && ! grep -qx 'shutdown\|boot' "$work/simctl.calls" && grep -q "types no password" "$work/talk-reboot-stop-waited.out"; then
  echo "ok   talk-reboot-stop-waited: a stop made while the reboot waited for the lock refused it, and the device neither shut down nor booted"
else
  echo "FAIL talk-reboot-stop-waited: exit $status, simctl: $(tr '\n' ' ' <"$work/simctl.calls")"
  sed 's/^/    | /' "$work/talk-reboot-stop-waited.out" | grep -vF "$token"; failures=$((failures + 1))
fi
rm -f "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
# A device with no sign-in recorded since its last --erase is not signed in for the first time.
rm -f "$TOPO_SIM_STATE/FAKE-UDID.signed-in"
reboot_case talk-never-signed-in     ""                         "boot shutdown"               no
grep -q "no sign-in recorded" "$work/talk-never-signed-in.out" \
  || { echo "FAIL talk-never-signed-in: the run does not say it renews nothing"; failures=$((failures + 1)); }

# A talk test that passes without the app having read the token (the app ran on some other
# login) fails the run.
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_TALK_TOKEN="$token" FAKE_LAUNCH=silent FAKE_LANE_START=0 \
  FAKE_TALK_ENV="$work/talk-unread.env" FAKE_TALK_GOT="$work/talk-unread.got" FAKE_TALK_UNREAD=1 FAKE_SIM_BOOTED="Sat Nov 14 13:32:28 2026" \
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
secret="Fk9xQa7p-$$-Lm2wZr4t"  # no word a log line holds, which an 8-character count would find
: >"$FAKE_XCODEBUILD_CALLS"
PATH="$work/bin:$PATH" FAKE_APPLE_PASSWORD="$secret" FAKE_SIGNIN_ENV="$work/signin.env" FAKE_SIGNIN_GOT="$work/signin.got" \
  GH_TOKEN="fake-gh-signin-$$" "$work/root/scripts/simulator-run.sh" --no-build --sign-in >"$work/signin.out" 2>&1 </dev/null
status=$?
got="$(cat "$work/signin.got" 2>/dev/null)"
leaks="$(grep -lF -e "$secret" -e "fake-gh-signin-$$" "$FAKE_XCODEBUILD_CALLS" "$work/signin.env" "$work/signin.out" "$work/root/build/sim/simulator-run.log" 2>/dev/null)"
if [ "$status" = 0 ] && [ "$got" = "$(printf 'wrong:\nright:%s\nagain:refused' "$secret")" ] && [ -z "$leaks" ] \
   && grep -q "TEST_RUNNER_TOPO_SIGNIN_ACCOUNT=buddy.durose@icloud.com" "$work/signin.env" \
   && grep -q -- '-collect-test-diagnostics never' "$FAKE_XCODEBUILD_CALLS"; then
  echo "ok   sign-in-password-once: the nonce's first request alone got the password, which no argument, environment or output carries"
else
  echo "FAIL sign-in-password-once: exit $status, the listener gave: $(printf %s "$got" | tr "\n" "|"), the password is in: ${leaks:-nothing}, xcodebuild was called with: $(tr "\n" "|" < "$FAKE_XCODEBUILD_CALLS")"
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
printf '#!/bin/sh\necho "a line of the Mac log"\n[ -z "$FAKE_LOG_FAILS" ] || exit 1\n' >"$work/bin/log"; chmod +x "$work/bin/log"
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
leak_case leak-check-failing-run-typed-wrong 1 FAKE_LEAK_WRONG=failing
leak_case leak-check-unreadable-attachment 1 FAKE_LEAK_UNREADABLE=1
leak_case leak-check-unreadable-folder 1 FAKE_LEAK_UNREADABLE=folder
leak_case leak-check-log-unread 1 FAKE_LOG_FAILS=1
# A sign-in whose run left any 8 characters of the password fails and names where, not what.
: >"$FAKE_XCODEBUILD_CALLS"
PATH="$work/bin:$PATH" FAKE_APPLE_PASSWORD="$secret" FAKE_SIGNIN_LEAKS=1 FAKE_SIGNIN_ENV="$work/leaks.env" FAKE_SIGNIN_GOT="$work/leaks.got" \
  "$work/root/scripts/simulator-run.sh" --no-build --sign-in >"$work/signin-leaks.out" 2>&1 </dev/null
status=$?
if [ "$status" = 1 ] && grep -q "the password is in what this run left, by count: password .*simulator-run.log: [1-9]" "$work/signin-leaks.out" \
   && [ "$(grep -cE "the password is in|password's characters" "$work/sign-in-renews-when-asked.out")" = 1 ] \
   && grep -q "no 8 of the password's characters are in the run's log, and the run wrote no bundle" "$work/sign-in-renews-when-asked.out"; then
  echo "ok   sign-in-counts-the-password: a run that left it fails, one that did not says so"
else
  echo "FAIL sign-in-counts-the-password: exit $status"; sed 's/^/    | /' "$work/signin-leaks.out"; failures=$((failures + 1))
fi
# A password past ASCII is counted by its characters, and its leaked prefix found, rather than the
# count failing on a byte split inside a character.
wide="abcdefgé12345678Zq-$$"
PATH="$work/bin:$PATH" FAKE_APPLE_PASSWORD="$wide" FAKE_SIGNIN_LEAKS=1 FAKE_SIGNIN_ENV="$work/wide.env" FAKE_SIGNIN_GOT="$work/wide.got" \
  "$work/root/scripts/simulator-run.sh" --no-build --sign-in >"$work/signin-wide.out" 2>&1 </dev/null
status=$?
if [ "$status" = 1 ] && grep -q "the password is in what this run left, by count: password .*simulator-run.log: [1-9]" "$work/signin-wide.out"; then
  echo "ok   sign-in-counts-a-wide-password: its leaked prefix is found"
else
  echo "FAIL sign-in-counts-a-wide-password: exit $status"; sed 's/^/    | /' "$work/signin-wide.out" | grep -vF "$wide"; failures=$((failures + 1))
fi
# A resume takes no code, since it types nothing.
: >"$FAKE_XCODEBUILD_CALLS"
PATH="$work/bin:$PATH" SIGNIN_CODE=123456 "$work/root/scripts/simulator-run.sh" --no-build --sign-in --resume >"$work/resume-code.out" 2>&1 </dev/null
status=$?
if [ "$status" = 2 ] && [ ! -s "$FAKE_XCODEBUILD_CALLS" ]; then
  echo "ok   refused: --sign-in --resume with SIGNIN_CODE exits 2"
else
  echo "FAIL refused: --sign-in --resume with SIGNIN_CODE exited $status"; failures=$((failures + 1))
fi
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

# A signed-in launch, built first: the token is served once to the app, which reads it with the
# launch's nonce, and is in none of the launch's arguments or environment (which the simulator's
# log records), xcodebuild's arguments or environment (which the build description records), the
# run's output or its log; and no variable whose name says it holds a secret reaches xcodebuild.
for fake in build-ish.sh fetch-phonon.sh; do printf '#!/bin/sh\nexit 0\n' > "$work/root/scripts/$fake"; chmod +x "$work/root/scripts/$fake"; done
token="fake-claude-token-launch-$$"
others="fake-gh-$$ fake-op-$$ fake-key-$$"
: >"$FAKE_XCODEBUILD_CALLS"; : >"$work/launch.build-env"; rm -f "$work/launch.got"
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" GH_TOKEN="fake-gh-$$" OP_SERVICE_ACCOUNT_TOKEN="fake-op-$$" \
  SOME_API_KEY="fake-key-$$" FAKE_LAUNCH=launched FAKE_LAUNCH_ENV="$work/launch.env" FAKE_LAUNCH_GOT="$work/launch.got" \
  FAKE_BUILD_ENV="$work/launch.build-env" "$work/root/scripts/simulator-run.sh" --press-mic >"$work/launch.out" 2>&1 </dev/null
status=$?
got="$(cat "$work/launch.got" 2>/dev/null)"
leaks="$(grep -lF "$token" "$FAKE_XCODEBUILD_CALLS" "$work/launch.build-env" "$work/launch.env" "$work/launch.out" "$work/root/build/sim/simulator-run.log" 2>/dev/null)"
for other in $others; do
  leaks="$leaks$(grep -lF "$other" "$FAKE_XCODEBUILD_CALLS" "$work/launch.build-env" 2>/dev/null)"
done
if [ "$status" = 0 ] && [ "$got" = "$token" ] && [ -z "$leaks" ] && [ -s "$work/launch.build-env" ] \
   && grep -q '^SIMCTL_CHILD_TOPO_DEBUG_TOKEN_PORT=[0-9]' "$work/launch.env" \
   && [ "$(grep -c -e ' build$' -e '-only-testing:TopoUITests' "$FAKE_XCODEBUILD_CALLS")" = 2 ]; then
  echo "ok   launch-token-served: the app got the token from the launch's nonce, and no secret is in the build's or the launch's environment"
else
  echo "FAIL launch-token-served: exit $status, the app read $([ "$got" = "$token" ] && echo the token || echo "something else"), a secret is in: ${leaks:-nothing}"
  sed 's/^/    | /' "$work/launch.out" | grep -vF "$token"
  failures=$((failures + 1))
fi

# The same of an attached launch with a turn to wait for.
token="fake-claude-token-send-$$"
rm -f "$work/send.got"
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_LAUNCH=answered FAKE_LAUNCH_ENV="$work/send.env" \
  FAKE_LAUNCH_GOT="$work/send.got" TIMEOUT=30 "$work/root/scripts/simulator-run.sh" --no-build --send hello >"$work/send.out" 2>&1 </dev/null
status=$?
got="$(cat "$work/send.got" 2>/dev/null)"
leaks="$(grep -lF "$token" "$work/send.env" "$work/send.out" "$work/root/build/sim/simulator-run.log" 2>/dev/null)"
if [ "$status" = 0 ] && [ "$got" = "$token" ] && [ -z "$leaks" ]; then
  echo "ok   send-token-served: the app got the token from the launch's nonce, and the launch does not carry it"
else
  echo "FAIL send-token-served: exit $status, the app read $([ "$got" = "$token" ] && echo the token || echo "something else"), the token is in: ${leaks:-nothing}"
  sed 's/^/    | /' "$work/send.out" | grep -vF "$token"
  failures=$((failures + 1))
fi

# A run whose app never asked for the token (it ran on some other login) fails, saying so.
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_LAUNCH=answered FAKE_APP_UNREAD=1 TIMEOUT=30 \
  "$work/root/scripts/simulator-run.sh" --no-build --send hello >"$work/send-unread.out" 2>&1 </dev/null
status=$?
if [ "$status" != 0 ] && grep -q "the app never read the served token" "$work/send-unread.out"; then
  echo "ok   send-token-unread: a turn answered with the token never read exits $status and says so"
else
  echo "FAIL send-token-unread: exit $status"
  sed 's/^/    | /' "$work/send-unread.out" | grep -vF "$token"
  failures=$((failures + 1))
fi

# A detached launch whose app never asks fails within TIMEOUT, saying so, and leaves nothing
# listening on the port it was handed.
rm -f "$work/unread.port"
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_LAUNCH=launched FAKE_APP_UNREAD=1 FAKE_LAUNCH_PORT="$work/unread.port" TIMEOUT=3 \
  "$work/root/scripts/simulator-run.sh" --no-build >"$work/launch-unread.out" 2>&1 </dev/null
status=$?
port="$(cat "$work/unread.port" 2>/dev/null)"
if [ "$status" != 0 ] && grep -q "the app never read the served token" "$work/launch-unread.out" && [ -n "$port" ] \
   && ! /usr/bin/python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=2)' "$port" 2>/dev/null; then
  echo "ok   launch-token-unread: a detached launch never read exits $status, says so, and its listener is gone"
else
  echo "FAIL launch-token-unread: exit $status, port '${port}'"
  sed 's/^/    | /' "$work/launch-unread.out" | grep -vF "$token"
  failures=$((failures + 1))
fi

# A guest command alone is launched with no token and no port, so the app is not signed out.
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN="$token" FAKE_LAUNCH=userland-fetched FAKE_LAUNCH_ENV="$work/userland.env" TIMEOUT=30 \
  "$work/root/scripts/simulator-run.sh" --no-build --userland "echo hi" >"$work/userland.out" 2>&1 </dev/null
status=$?
if [ "$status" = 0 ] && ! grep -q 'TOKEN' "$work/userland.env"; then
  echo "ok   userland-no-token: the guest command's launch names no token and no port"
else
  echo "FAIL userland-no-token: exit $status, the launch carried: $(grep -o '^[A-Z_]*TOKEN[A-Z_]*' "$work/userland.env" | tr '\n' ' ')"
  failures=$((failures + 1))
fi

# The device as a run leaves it. A run that used it shuts it down as it ends, passing or failing,
# unless another run is using it (a simulator-run.sh, or an xcodebuild or simctl naming the udid;
# a process that only mentions the script is none) or the run is one that leaves it up on purpose:
# a launch to drive by hand, a sign-in, a sign-in that stopped. A lapsed sign-in is renewed once
# and the app launched again; a renewal that stopped is never tried again until a --sign-in passes.
# sim_case <name> <pass|fail> <shut down: yes|no> <text the output carries, or ""> <sign-ins> [VAR=value ...] -- <args>
sim_case() {
  local name="$1" want="$2" shut="$3" text="$4" signins="$5"; shift 5
  local envs=() out="$work/$name.out" status got downs ran
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  : >"$work/simctl.calls"; : >"$FAKE_XCODEBUILD_CALLS"; : >"$work/$name.launches"
  env PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT=30 FAKE_SIMCTL_CALLS="$work/simctl.calls" \
    FAKE_APPLE_PASSWORD="fake-apple-$$" FAKE_SIGNIN_ENV="$work/$name.signin.env" FAKE_SIGNIN_GOT="$work/$name.signin.got" \
    FAKE_LAUNCHES="$work/$name.launches" "${envs[@]}" "$work/root/scripts/simulator-run.sh" --no-build "$@" >"$out" 2>&1 </dev/null
  status=$?
  if [ "$status" = 0 ]; then got=pass; else got=fail; fi
  # As case_ holds: whatever way a run ends, it leaves no launcher running and no pids file.
  if [ -s "$FAKE_LAUNCHER_PID" ] && kill -0 "$(cat "$FAKE_LAUNCHER_PID")" 2>/dev/null; then
    kill "$(cat "$FAKE_LAUNCHER_PID")"; got="left its launcher running"
  elif [ -e "$work/root/build/sim/simulator-run.pids" ]; then
    rm -f "$work/root/build/sim/simulator-run.pids"; got="left its pids file behind"
  fi
  rm -f "$FAKE_LAUNCHER_PID"
  downs="$(grep -cx shutdown "$work/simctl.calls")"
  ran="$(grep -c ' TopoSimulatorSignIn ' "$FAKE_XCODEBUILD_CALLS")"
  local wanted=0; [ "$shut" = no ] || wanted=1
  if [ "$got" = "$want" ] && [ "$downs" = "$wanted" ] \
     && [ "$ran" = "$signins" ] && { [ -z "$text" ] || grep -Fq -- "$text" "$out"; }; then
    echo "ok   $name: exited $status, shut down: $shut, sign-ins: $ran"
  else
    echo "FAIL $name: exited $status (wanted $want), shutdowns $downs (wanted $shut), sign-ins $ran (wanted $signins)${text:+, wanted the text \"$text\"}"
    sed 's/^/    | /' "$out"
    failures=$((failures + 1))
  fi
}
# What earlier cases' sign-ins left (a stop among them) is not these cases'.
rm -f "$TOPO_SIM_STATE"/FAKE-UDID.*
sim_case sim-send-answered-shuts      pass yes "" 0 FAKE_LAUNCH=answered -- --send hello
sim_case sim-send-failed-shuts        fail yes "" 0 FAKE_LAUNCH=no-reply -- --send hello
sim_case sim-userland-shuts           pass yes "" 0 FAKE_LAUNCH=userland-fetched -- --userland "echo hi"
sim_case sim-sibling-run-keeps        pass no "left booted for the runs using it" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  999     1 /opt/homebrew/bin/bash scripts/simulator-run.sh --send hi" -- --send hello
sim_case sim-sibling-xcodebuild-keeps pass no "left booted for the runs using it" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  998     1 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild test -destination platform=iOS Simulator,id=FAKE-UDID" -- --send hello
sim_case sim-mention-is-no-run        pass yes "" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  997     1 claude --name x Task: mend scripts/simulator-run.sh on FAKE-UDID" -- --send hello
sim_case sim-mention-first-is-no-run  pass yes "" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  996     1 claude scripts/simulator-run.sh FAKE-UDID" -- --send hello
sim_case sim-shell-options-keep       pass no "left booted for the runs using it" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  995     1 /bin/bash -e -o pipefail scripts/simulator-run.sh --send hi" -- --send hello
sim_case sim-command-string-is-no-run pass yes "" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  991     1 /bin/bash -lc cd ~/github/topo && echo scripts/simulator-run.sh" -- --send hello
sim_case sim-rcfile-run-keeps         pass no "left booted for the runs using it" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  990     1 bash --rcfile /tmp/bashrc scripts/simulator-run.sh --send hi" -- --send hello
sim_case sim-clustered-option-keeps   pass no "left booted for the runs using it" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  989     1 /bin/bash -eo pipefail scripts/simulator-run.sh --send hi" -- --send hello
sim_case sim-env-unset-run-keeps      pass no "left booted for the runs using it" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  988     1 env -u DEVICE bash -- scripts/simulator-run.sh" -- --send hello
sim_case sim-env-run-keeps            pass no "left booted for the runs using it" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  994     1 /usr/bin/env DEVICE=x bash scripts/simulator-run.sh" -- --send hello
sim_case sim-destination-field-keeps  pass no "left booted for the runs using it" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  993     1 xcodebuild test -destination platform=iOS Simulator,id=FAKE-UDID,OS=latest" -- --send hello
sim_case sim-other-destination-shuts  pass yes "" 0 FAKE_LAUNCH=answered \
  "FAKE_PS_LIST=  992     1 xcodebuild test -destination platform=iOS Simulator,id=FAKE-UDID-2,OS=latest" -- --send hello
sim_case sim-unread-processes-keep    pass no "the process list could not be read" 0 FAKE_LAUNCH=answered FAKE_PS_FAILS=1 -- --send hello
touch "$TOPO_SIM_STATE/FAKE-UDID.signed-in"
sim_case sim-hand-launch-keeps        pass no "driven by hand" 0 FAKE_LAUNCH=launched --
sim_case sim-hand-launch-renews       pass no "driven by hand" 1 FAKE_LAUNCH=launched FAKE_SIM_BOOTS=fresh --
sim_case sim-guest-turn-renews        pass yes "renewing it" 1 FAKE_LAUNCH=guest-answered FAKE_SIM_BOOTS=fresh -- --guest-turn "a || b"
sim_case sim-userland-renews-none     pass yes "" 0 FAKE_LAUNCH=userland-fetched FAKE_SIM_BOOTS=fresh -- --userland "echo hi"
sim_case sim-sign-in-keeps            pass no "signed in for the runs after this one" 1 FAKE_LAUNCH=silent -- --sign-in
rm -f "$TOPO_SIM_STATE/renewals.log"
touch -t "$(date -v-3H +%Y%m%d%H%M)" "$TOPO_SIM_STATE/FAKE-UDID.last-use"
sim_case sim-renews-and-relaunches    pass yes "renewing it" 1 FAKE_LAUNCH=unavailable-then-answered -- --send hello
launches="$work/sim-renews-and-relaunches.launches"
first="$(sed -n 1p "$launches")" second="$(sed -n 2p "$launches")"
if [ "$(wc -l <"$launches" | tr -d ' ')" = 2 ] \
   && [ "${first%% *}" != "${second%% *}" ] && [ "$(echo "$first" | cut -d' ' -f2)" != "$(echo "$second" | cut -d' ' -f2)" ] \
   && [ -n "$(echo "$second" | sed -n 's/.*port=\([0-9][0-9]*\)$/\1/p')" ] \
   && grep -qx "TEST_RUNNER_TOPO_SIGNIN_RENEW=1" "$work/sim-renews-and-relaunches.signin.env" \
   && [ "$(wc -l <"$TOPO_SIM_STATE/renewals.log" | tr -d ' ')" = 1 ] \
   && grep -Eqx "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z FAKE-UDID CloudKit answered account temporarily unavailable \(.*/root\)" "$TOPO_SIM_STATE/renewals.log" \
   && [ -n "$(find "$TOPO_SIM_STATE/FAKE-UDID.last-use" -mmin -5)" ]; then
  echo "ok   sim-renewal-is-a-renew: launched twice, under two run ids, nonces and listeners, around one --renew sign-in logged with its reason, and the last use advanced"
else
  echo "FAIL sim-renewal-is-a-renew: launches: $(tr '\n' '|' <"$launches"), $(grep RENEW "$work/sim-renews-and-relaunches.signin.env"), renewals: $(cat "$TOPO_SIM_STATE/renewals.log" 2>/dev/null), last use: $(stat -f %Sm "$TOPO_SIM_STATE/FAKE-UDID.last-use")"
  failures=$((failures + 1))
fi
sim_case sim-still-unavailable-fails  fail yes "DEVICE=FAKE-UDID scripts/simulator-run.sh --sign-in --renew" 1 FAKE_LAUNCH=unavailable -- --send hello
sim_case sim-renewal-stops            fail no "SIGNIN_CODE=<code> DEVICE=FAKE-UDID scripts/simulator-run.sh --sign-in" 1 \
  FAKE_LAUNCH=unavailable FAKE_SIGNIN_STOPS=1 -- --send hello
sim_case sim-no-renewal-past-a-stop   fail no "so this run types no password" 0 FAKE_LAUNCH=unavailable -- --send hello
sim_case sim-stop-keeps-the-device    pass no "a sign-in on it stopped" 0 FAKE_LAUNCH=userland-fetched -- --userland "echo hi"
# A stop older than the half hour keeps nothing up, and still refuses a renewal.
touch -t "$(date -v-2H +%Y%m%d%H%M)" "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
sim_case sim-old-stop-shuts           pass yes "" 0 FAKE_LAUNCH=userland-fetched -- --userland "echo hi"
sim_case sim-old-stop-still-refuses   fail yes "so this run types no password" 0 FAKE_LAUNCH=unavailable -- --send hello
sim_case sim-sign-in-clears-the-stop  pass no "" 1 FAKE_LAUNCH=silent -- --sign-in
[ ! -e "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped" ] \
  && sim_case sim-renews-after-the-stop pass yes "renewing it" 1 FAKE_LAUNCH=unavailable-then-answered -- --send hello \
  || { echo "FAIL sim-sign-in-clears-the-stop: the stop still stands"; failures=$((failures + 1)); }

# A renewal waits for another run's sign-in on the device and, when that one passed, types nothing.
rm -f "$TOPO_SIM_STATE"/FAKE-UDID.sign-in-stopped
# The holder lets go once the run says it is waiting, and not by the clock (a minute at most).
rm -f "$work/sim-renewal-waits-its-turn.out"
lockf "$TOPO_SIM_STATE/FAKE-UDID.renewing" sh -c "for _ in \$(seq 600); do grep -q 'another run is signing' '$work/sim-renewal-waits-its-turn.out' 2>/dev/null && break; /bin/sleep 0.1; done; touch '$TOPO_SIM_STATE/FAKE-UDID.signed-in'" &
holder=$!
for _ in $(seq 50); do lockf -s -t 0 "$TOPO_SIM_STATE/FAKE-UDID.renewing" true 2>/dev/null || break; /bin/sleep 0.1; done
sim_case sim-renewal-waits-its-turn   pass yes "another run's sign-in has renewed it" 0 FAKE_LAUNCH=unavailable-then-answered -- --send hello
wait "$holder"
# A --sign-in that waited for another run's sign-in types nothing over what that one left.
for outcome in passed stopped; do
  rm -f "$TOPO_SIM_STATE"/FAKE-UDID.sign-in-stopped "$work/sim-sign-in-waited-$outcome.out"
  if [ "$outcome" = passed ]; then left="uuidgen >'$TOPO_SIM_STATE/FAKE-UDID.signed-in'"; else left="echo refused >'$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped'"; fi
  lockf "$TOPO_SIM_STATE/FAKE-UDID.renewing" sh -c "for _ in \$(seq 600); do grep -q 'another run is signing' '$work/sim-sign-in-waited-$outcome.out' 2>/dev/null && break; /bin/sleep 0.1; done; $left" &
  holder=$!
  for _ in $(seq 50); do lockf -s -t 0 "$TOPO_SIM_STATE/FAKE-UDID.renewing" true 2>/dev/null || break; /bin/sleep 0.1; done
  if [ "$outcome" = passed ]; then
    sim_case sim-sign-in-waited-passed  pass no "this run types nothing" 0 FAKE_LAUNCH=silent -- --sign-in
  else
    sim_case sim-sign-in-waited-stopped fail no "Read why it stopped" 0 FAKE_LAUNCH=silent -- --sign-in
  fi
  wait "$holder"
done
rm -f "$TOPO_SIM_STATE"/FAKE-UDID.sign-in-stopped
# A sign-in that passed after this run launched, before its renewal took the lock, is seen.
rm -f "$TOPO_SIM_STATE"/FAKE-UDID.sign-in-stopped "$work/launch-signs.done"
sim_case sim-renewal-sees-a-sign-in-since-launch pass yes "another run's sign-in has renewed it" 0 \
  FAKE_LAUNCH=unavailable-then-answered "FAKE_LAUNCH_SIGNS=$TOPO_SIM_STATE/FAKE-UDID.signed-in" -- --send hello
# A --sign-in behind one that found the device signed in already and put an old stop back reads
# that stop as the one it was, not a new one, and signs in.
echo "stopped long ago" >"$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
touch -t "$(date -v-2H +%Y%m%d%H%M)" "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
rm -f "$work/sim-sign-in-behind-a-put-back.out"
stop="$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
lockf "$TOPO_SIM_STATE/FAKE-UDID.renewing" sh -c "ln '$stop' '$stop.prior'; echo begun >'$stop.new'; mv -f '$stop.new' '$stop'; for _ in \$(seq 600); do grep -q 'another run is signing' '$work/sim-sign-in-behind-a-put-back.out' 2>/dev/null && break; /bin/sleep 0.1; done; mv -f '$stop.prior' '$stop'" &
holder=$!
for _ in $(seq 50); do lockf -s -t 0 "$TOPO_SIM_STATE/FAKE-UDID.renewing" true 2>/dev/null || break; /bin/sleep 0.1; done
sim_case sim-sign-in-behind-a-put-back pass no "" 1 FAKE_LAUNCH=silent -- --sign-in
wait "$holder"
rm -f "$TOPO_SIM_STATE"/FAKE-UDID.sign-in-stopped*
# A --sign-in waiting on one a signal ends finds that one's record as it began, and types nothing.
rm -f "$TOPO_SIM_STATE"/FAKE-UDID.sign-in-stopped* "$work/sim-sign-in-behind-a-signal.out"
lockf "$TOPO_SIM_STATE/FAKE-UDID.renewing" sh -c "echo '2026-11-26T00:00:00Z in x: begun and not seen to finish; see y' >'$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped'; for _ in \$(seq 600); do grep -q 'another run is signing' '$work/sim-sign-in-behind-a-signal.out' 2>/dev/null && break; /bin/sleep 0.1; done" &
holder=$!
for _ in $(seq 50); do lockf -s -t 0 "$TOPO_SIM_STATE/FAKE-UDID.renewing" true 2>/dev/null || break; /bin/sleep 0.1; done
sim_case sim-sign-in-behind-a-signal fail no "Read why it stopped" 0 FAKE_LAUNCH=silent -- --sign-in
wait "$holder"
rm -f "$TOPO_SIM_STATE"/FAKE-UDID.sign-in-stopped*
# A --press-mic that boots learns of the lapse at that boot; a sign-in passing during its suite is seen.
touch "$TOPO_SIM_STATE/FAKE-UDID.signed-in"
sim_case sim-press-mic-sees-a-sign-in pass no "another run's sign-in has renewed it" 0 FAKE_LAUNCH=launched FAKE_SIM_BOOTS=fresh \
  "FAKE_UI_SIGNS=$TOPO_SIM_STATE/FAKE-UDID.signed-in" -- --press-mic
# A boot the sign-in cannot make under the lock types nothing and puts the records back.
echo "stopped earlier" >"$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
lockf "$TOPO_SIM_STATE/mutex" /bin/sleep 5 &
holder=$!
for _ in $(seq 50); do lockf -s -t 0 "$TOPO_SIM_STATE/mutex" true 2>/dev/null || break; /bin/sleep 0.1; done
sim_case sim-sign-in-unbooted-types-nothing fail no "nothing was typed" 0 FAKE_LAUNCH=silent TOPO_SIM_LOCK_WAIT=1 -- --sign-in
wait "$holder"
if [ "$(cat "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped" 2>/dev/null)" = "stopped earlier" ]; then
  echo "ok   sim-sign-in-unbooted-keeps-the-stop: the stop that stood is back"
else
  echo "FAIL sim-sign-in-unbooted-keeps-the-stop: stop '$(cat "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped" 2>/dev/null)'"; failures=$((failures + 1))
fi
rm -f "$TOPO_SIM_STATE"/FAKE-UDID.sign-in-stopped*
# What a sign-in leaves running holds no sign-in lock: the next renewal finds it free.
rm -f "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
sim_case sim-sign-in-lock-not-inherited pass no "" 1 FAKE_LAUNCH=silent FAKE_SIGNIN_LEAVES=1 -- --sign-in
if lockf -s -t 0 "$TOPO_SIM_STATE/FAKE-UDID.renewing" true; then
  echo "ok   sim-sign-in-lock-free-after: a process the sign-in left behind does not hold the lock"
else
  echo "FAIL sim-sign-in-lock-free-after: the sign-in lock is still held after the run"; failures=$((failures + 1))
fi
# A sign-in that finds the device signed in already types nothing, and so mends no stop.
echo "stopped earlier" >"$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"; rm -f "$TOPO_SIM_STATE/FAKE-UDID.signed-in"
touch -t "$(date -v-2H +%Y%m%d%H%M)" "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
stop_time="$(stat -f %m "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped")"
FAKE_SIGNIN_SAYS="[sign-in] already signed in as buddy.durose@icloud.com, and nothing asks for the password" \
  FAKE_SIGNIN_TRUNCATES="$work/root/build/sim/simulator-run.log" \
  sim_case sim-already-signed-in-mends-nothing pass no "" 1 FAKE_LAUNCH=silent -- --sign-in
if [ "$(cat "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped" 2>/dev/null)" = "stopped earlier" ] && [ ! -e "$TOPO_SIM_STATE/FAKE-UDID.signed-in" ] \
   && [ "$(stat -f %m "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped")" = "$stop_time" ] && [ ! -e "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped.prior" ]; then
  echo "ok   sim-already-signed-in-keeps-the-stop: the earlier stop stands, with its time, and no sign-in is recorded"
else
  echo "FAIL sim-already-signed-in-keeps-the-stop: stop '$(cat "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped" 2>/dev/null)', signed-in: $(ls "$TOPO_SIM_STATE")"
  failures=$((failures + 1))
fi
rm -f "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
# A sign-in a signal ends mid-Settings leaves a stop: no shutdown under its screen, no renewal after.
: >"$work/simctl.calls"; rm -f "$work/signin-hangs"
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder FAKE_APPLE_PASSWORD="fake-apple-$$" FAKE_SIGNIN_ENV="$work/hang.env" \
  FAKE_SIGNIN_GOT="$work/hang.got" FAKE_SIGNIN_HANGS="$work/signin-hangs" FAKE_SIMCTL_CALLS="$work/simctl.calls" \
  "$work/root/scripts/simulator-run.sh" --no-build --sign-in >"$work/signin-term.out" 2>&1 </dev/null &
signer=$!
for _ in $(seq 100); do [ -e "$work/signin-hangs" ] && break; /bin/sleep 0.1; done
kill -TERM "$signer"; wait "$signer"; status=$?
if [ "$status" = 143 ] && [ -e "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped" ] && ! grep -qx shutdown "$work/simctl.calls"; then
  echo "ok   sim-sign-in-signalled: exit 143, the unfinished sign-in recorded as a stop, the device left up"
else
  echo "FAIL sim-sign-in-signalled: exit $status, stop: $(cat "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped" 2>/dev/null), simctl: $(tr '\n' ' ' <"$work/simctl.calls")"
  sed 's/^/    | /' "$work/signin-term.out"; failures=$((failures + 1))
fi
sim_case sim-no-renewal-after-signal  fail no "so this run types no password" 0 FAKE_LAUNCH=unavailable -- --send hello

# --erase forgets the device's sign-in and any stop.
touch "$TOPO_SIM_STATE/FAKE-UDID.signed-in" "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped"
PATH="$work/bin:$PATH" "$work/root/scripts/simulator-run.sh" --erase >"$work/erase.out" 2>&1 </dev/null
if [ ! -e "$TOPO_SIM_STATE/FAKE-UDID.signed-in" ] && [ ! -e "$TOPO_SIM_STATE/FAKE-UDID.sign-in-stopped" ]; then
  echo "ok   sim-erase-forgets: the sign-in and the stop are gone with the device's data"
else
  echo "FAIL sim-erase-forgets: $(ls "$TOPO_SIM_STATE")"; failures=$((failures + 1))
fi

# A run ended by a signal shuts the device down too.
: >"$work/simctl.calls"; : >"$work/term.launches"
PATH="$work/bin:$PATH" CLAUDE_SETUP_TOKEN=placeholder TIMEOUT=60 FAKE_LAUNCH=silent FAKE_SIMCTL_CALLS="$work/simctl.calls" \
  FAKE_LAUNCHES="$work/term.launches" "$work/root/scripts/simulator-run.sh" --no-build --send hello >"$work/term.out" 2>&1 </dev/null &
termed=$!
for _ in $(seq 100); do [ -s "$work/term.launches" ] && break; /bin/sleep 0.1; done
/bin/sleep 0.5
kill -TERM "$termed"; wait "$termed"; status=$?
if [ "$status" = 143 ] && [ "$(grep -cx shutdown "$work/simctl.calls")" = 1 ]; then
  echo "ok   sim-terminated-shuts: a TERM mid-turn exits 143 and shuts the device down"
else
  echo "FAIL sim-terminated-shuts: exit $status, simctl: $(tr '\n' ' ' <"$work/simctl.calls")"
  sed 's/^/    | /' "$work/term.out"; failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed against $script"
  exit 1
fi
echo "all cases held against $script"
