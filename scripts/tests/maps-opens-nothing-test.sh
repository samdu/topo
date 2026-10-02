#!/usr/bin/env bash
# Holds that `topo maps` opens no other app and draws no map: no file of it
# (Apps/Topo/Tools/Maps*.swift) names a way to open Maps, to open a URL, or a map view. The check
# is first held against fixtures of its own, so a word it stopped finding fails here rather than
# passing every file.
#
#   scripts/tests/maps-opens-nothing-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../.."
work="$(mktemp -d -t maps-opens-nothing-test)"
trap 'rm -rf "$work"' EXIT

words=(openInMaps openMaps UIApplication 'maps://' 'maps.apple.com' MKMapView MKLookAroundScene)

# found <file...>: prints every line holding one of the words, and succeeds when there is one.
found() {
  local arguments=() word
  for word in "${words[@]}"; do arguments+=(-e "$word"); done
  grep -nF "${arguments[@]}" -- "$@"
}

failures=0

# Each word alone in a file is found; a file with none of them is not.
for word in "${words[@]}"; do
  printf 'let request = MKDirections.Request()\n    item.%s(launchOptions: nil)\n' "$word" > "$work/fixture.swift"
  if ! found "$work/fixture.swift" > /dev/null; then
    echo "FAIL: a fixture holding $word was passed"
    failures=$((failures + 1))
  fi
done
printf 'import MapKit\nlet search = MKLocalSearch(request: request)\nlet directions = MKDirections(request: route)\n' > "$work/clean.swift"
if found "$work/clean.swift" > /dev/null; then
  echo "FAIL: a fixture holding none of the words was refused"
  failures=$((failures + 1))
fi

# The tool's own files. No file at all is a failure: a check of nothing passes everything.
shopt -s nullglob
files=("$root"/Apps/Topo/Tools/Maps*.swift)
shopt -u nullglob
if [ "${#files[@]}" -eq 0 ]; then
  echo "FAIL: no Apps/Topo/Tools/Maps*.swift to check"
  failures=$((failures + 1))
elif lines="$(found "${files[@]}")"; then
  echo "FAIL: topo maps names a way out of the app:"
  echo "$lines"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "maps-opens-nothing-test: $failures failed"
  exit 1
fi
echo "maps-opens-nothing-test: ok (${#files[@]} file(s), ${#words[@]} words)"
