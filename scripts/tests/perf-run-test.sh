#!/bin/bash
# scripts/perf-run.sh refuses what it could never count, before it reaches a phone.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail=0
expect() { # <status> <args...>
  local want="$1"; shift
  env -u TOPO_PERF_DEVICE scripts/perf-run.sh "$@" >/dev/null 2>&1
  local got=$?
  [ "$got" = "$want" ] || { echo "FAIL: perf-run.sh $* exited $got, wanted $want"; fail=1; }
}
expect 2 --device none
expect 2 --device none '' 'hello'
expect 2 --device none '   '
expect 2 'hello'
# A --fresh that cannot put Topo back reaches no phone: xcrun is a stand-in that records every
# call, and none may be made.
record="$(mktemp -d "${TMPDIR:-/tmp}/perf-run-record.XXXXXX")"
printf '#!/bin/bash\necho "$*" >> "%s/calls"\n' "$record" > "$record/xcrun"
chmod +x "$record/xcrun"
mkdir -p "$record/Other.app"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>' > "$record/Other.app/Info.plist"
for app in /nonexistent/Topo.app "$record" "$record/Other.app"; do
  PATH="$record:$PATH" expect 2 --device none --fresh --app "$app" 'hello'
done
PATH="$record:$PATH" expect 2 --device none --fresh 'hello'
[ ! -s "$record/calls" ] || { echo "FAIL: a refused --fresh reached the phone: $(cat "$record/calls")"; fail=1; }

# With a Topo bundle, what --fresh does turns on the phone's answer. The stand-in answers the
# installed-apps query from FAKE_APPS (a file's contents, or a failure for "fail"), fails the
# delete when FAKE_UNINSTALL=fail, and refuses every launch, so a run ends there.
if command -v plutil >/dev/null; then
  mkdir -p "$record/Topo.app"
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>zone.hexagon.topo</string></dict></plist>' > "$record/Topo.app/Info.plist"
  cat > "$record/xcrun" <<FAKE
#!/bin/bash
echo "\$*" >> "$record/calls"
case "\$*" in
  *"info apps"*)
    [ "\$FAKE_APPS" = fail ] && exit 1
    while [ \$# -gt 0 ]; do [ "\$1" = --json-output ] && out="\$2"; shift; done
    cat "\$FAKE_APPS" > "\$out" ;;
  *uninstall*) [ "\$FAKE_UNINSTALL" = fail ] && exit 1 ;;
  *"process launch"*) echo refused >&2; exit 1 ;;
esac
exit 0
FAKE
  chmod +x "$record/xcrun"
  printf '{"result":{"apps":[{"bundleIdentifier":"zone.hexagon.topo"}]}}' > "$record/installed.json"
  printf '{"result":{"apps":[]}}' > "$record/absent.json"
  printf '{}' > "$record/shapeless.json"
  : > "$record/empty.json"
  fresh() { # <want status> <apps> <uninstall> <calls that must appear, |-separated> <calls that must not>
    : > "$record/calls"
    FAKE_APPS="$2" FAKE_UNINSTALL="$3" PATH="$record:$PATH" env -u TOPO_PERF_DEVICE \
      scripts/perf-run.sh --device fake --fresh --app "$record/Topo.app" --timeout 5 'hello' >/dev/null 2>&1
    local got=$?
    [ "$got" = "$1" ] || { echo "FAIL: --fresh with $2/$3 exited $got, wanted $1"; fail=1; }
    local IFS='|'
    for call in $4; do grep -q "$call" "$record/calls" || { echo "FAIL: --fresh with $2/$3 made no '$call' call"; fail=1; }; done
    for call in $5; do ! grep -q "$call" "$record/calls" || { echo "FAIL: --fresh with $2/$3 made a '$call' call"; fail=1; }; done
  }
  fresh 1 "$record/installed.json" ok "uninstall|device install app" ""
  fresh 1 "$record/installed.json" fail "uninstall" "device install app"
  fresh 1 "$record/absent.json" ok "device install app" "uninstall"
  for answer in "$record/shapeless.json" "$record/empty.json" fail; do
    fresh 1 "$answer" ok "info apps" "uninstall|device install app"
  done
else
  echo "perf-run-test: no plutil, so the --fresh cases with a Topo bundle were not run"
fi
rm -rf "$record"

# A copy that brings back the last run's finished file is not taken for this run's: the script
# waits for a file whose first mark is this launch's. xcrun is a stand-in that serves a stale
# file on the first copy and this run's on the second.
fake="$(mktemp -d -t perf-run-test)"
trap 'rm -rf "$fake"' EXIT
cat > "$fake/xcrun" <<'FAKE'
#!/bin/bash
case "$*" in
  *"copy from"*)
    while [ $# -gt 0 ]; do [ "$1" = --destination ] && to="$2"; shift; done
    n=$(( $(cat "$FAKE_DIR/copies" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_DIR/copies"
    if [ "$n" = 1 ]; then
      printf 'mark t=1000 app.init.begin\nmark t=2000 perf.run.done answered=1/1\n' > "$to"
    else
      now=$(python3 -c 'import time; print(int(time.time() * 1000))')
      printf 'mark t=%s app.init.begin\nmark t=%s perf.run.done answered=0/1\n' "$now" "$now" > "$to"
    fi ;;
esac
FAKE
chmod +x "$fake/xcrun"
FAKE_DIR="$fake" PATH="$fake:$PATH" scripts/perf-run.sh --device fake --timeout 60 --out "$fake/marks.txt" 'hello' >/dev/null 2>&1
got=$?
[ "$got" = 4 ] || { echo "FAIL: a stale marks file was taken for this run's (exit $got, wanted 4)"; fail=1; }
[ "$(cat "$fake/copies" 2>/dev/null)" = 2 ] || { echo "FAIL: the stale file ended the wait"; fail=1; }

[ "$fail" = 0 ] && echo "perf-run-test: ok"
exit "$fail"
