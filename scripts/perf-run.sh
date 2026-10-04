#!/bin/bash
# A timed run on a phone with nobody at it: installs a build, launches it cold with
# TOPO_PERF_SEND (Apps/Topo/PerfRun.swift), waits for the app to say the run is done, and copies
# its marks off the phone. The phone must be unlocked: devicectl refuses to launch on a locked one.
#
#   scripts/perf-run.sh [--device <id>] [--app <Topo.app>] [--build] [--gap <seconds>]
#                       [--timeout <seconds>] [--out <marks.txt>] "question" ["question" ...]
#
# --build makes the Release build first (build/dd, signed for TOPO_DEVELOPMENT_TEAM if set); --app installs that bundle; with neither the
# build already on the phone is the one timed. It exits 4 when a question got no reply. The marks land in --out (default
# build/perf/<UTC stamp>.txt), one `mark t=<epoch ms> <name>` a line, which is what
# experiments/topo-perf/parse.py reads.
set -euo pipefail
cd "$(dirname "$0")/.."

bundle=zone.hexagon.topo
device="${TOPO_PERF_DEVICE:-}"
app="" build=no gap=5 timeout=600 out=""
while [ $# -gt 0 ]; do
  case "$1" in
    --device) device="$2"; shift 2 ;;
    --app) app="$2"; shift 2 ;;
    --build) build=yes; shift ;;
    --gap) gap="$2"; shift 2 ;;
    --timeout) timeout="$2"; shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown option $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[ $# -gt 0 ] || { echo "no questions given" >&2; exit 2; }
[ -n "$device" ] || { echo "no device: pass --device or set TOPO_PERF_DEVICE (xcrun devicectl list devices)" >&2; exit 2; }

asked=$#
send="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")"
out="${out:-build/perf/$(date -u +%Y%m%dT%H%M%SZ).txt}"
mkdir -p "$(dirname "$out")"

if [ "$build" = yes ]; then
  echo "==> building Release"
  mkdir -p build
  xcodebuild -project Topo.xcodeproj -scheme Topo -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath build/dd build \
    -allowProvisioningUpdates -skipPackagePluginValidation -skipMacroValidation \
    ${TOPO_DEVELOPMENT_TEAM:+DEVELOPMENT_TEAM=$TOPO_DEVELOPMENT_TEAM} \
    > build/perf-build.log 2>&1 || { tail -30 build/perf-build.log >&2; exit 1; }
  app="build/dd/Build/Products/Release-iphoneos/Topo.app"
fi
if [ -n "$app" ]; then
  echo "==> installing $app"
  xcrun devicectl device install app --device "$device" "$app" --quiet
fi

# The marks file is started empty by the app at launch, so a file read back with this run's
# first question in it is this run's.
environment="$(python3 -c 'import json,sys; print(json.dumps({"TOPO_PERF_SEND": sys.argv[1], "TOPO_PERF_GAP": sys.argv[2]}))' "$send" "$gap")"
echo "==> launching"
if ! launched="$(xcrun devicectl device process launch --device "$device" --terminate-existing \
     --environment-variables "$environment" "$bundle" 2>&1)"; then
  case "$launched" in
    *Locked*) echo "the phone is locked: unlock it and run this again" >&2; exit 3 ;;
    *) echo "$launched" >&2; exit 1 ;;
  esac
fi

pulled="$(mktemp -d -t topo-perf)"
trap 'rm -rf "$pulled"' EXIT
deadline=$(( $(date +%s) + timeout ))
while :; do
  if xcrun devicectl device copy from --device "$device" --domain-type appDataContainer \
       --domain-identifier "$bundle" --source tmp/topo-perf.log --destination "$pulled/marks.txt" \
       --quiet 2>/dev/null; then
    cp "$pulled/marks.txt" "$out"
    if grep -q "perf.run.done" "$out"; then break; fi
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "the run did not finish in ${timeout}s; what it marked is in $out" >&2
    exit 1
  fi
  sleep 5
done
# The app's own count of the questions that got a reply: a run that lost one is not a run to
# read numbers off without knowing it.
answered="$(sed -n 's/.*perf\.run\.done answered=\([0-9]*\)\/.*/\1/p' "$out" | tail -1)"
echo "==> ${answered:-0} of $asked questions answered, marks in $out"
[ "${answered:-0}" = "$asked" ] || exit 4
