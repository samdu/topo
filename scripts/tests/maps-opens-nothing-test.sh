#!/usr/bin/env bash
# Holds that no file of `topo maps` (Apps/Topo/Tools/Maps*.swift) holds any of the words below:
# the ways to open Maps or a URL, and the map views. It reads for those words and nothing else, so
# a way out of the app spelt otherwise passes it. The check is first held against fixtures of its
# own, so a word it stopped finding fails here rather than passing every file.
#
# One file is let one word: MapsLink.swift writes the link an answer carries for the person to
# tap, so it may name `maps.apple.com`, and nothing else on the list. Every other file is held to
# the whole list, that word included.
#
#   scripts/tests/maps-opens-nothing-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$here/../.."
work="$(mktemp -d -t maps-opens-nothing-test)"
trap 'rm -rf "$work"' EXIT

words=(openInMaps openMaps UIApplication 'UIApplication.shared.open' openURL 'maps://' 'maps.apple.com' MKMapView MKLookAroundScene)
# The file that writes the link, and the one word it is let.
link_file="MapsLink.swift"
link_word="maps.apple.com"

# found <file...>: prints every line holding one of the words, and succeeds when there is one. A
# file named $link_file is read for every word but $link_word. A file that cannot be read is said
# as found, so it fails the check rather than passing it.
found() {
  local status=1 file
  for file in "$@"; do
    if found_in "$file"; then status=0; fi
  done
  return "$status"
}

found_in() {
  local arguments=() word status
  for word in "${words[@]}"; do
    if [ "$(basename "$1")" = "$link_file" ] && [ "$word" = "$link_word" ]; then continue; fi
    arguments+=(-e "$word")
  done
  set -- "$1"
  grep -HnF "${arguments[@]}" -- "$@" && status=0 || status=$?
  if [ "$status" -gt 1 ]; then
    echo "grep could not read: $*"
    return 0
  fi
  return "$status"
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
if ! found "$work/absent.swift" > /dev/null 2>&1; then
  echo "FAIL: a file that cannot be read was passed"
  failures=$((failures + 1))
fi

# The link's file may hold its one word and no other; a file of any other name may not hold it,
# alone or beside the link's file.
printf 'components.host = "%s"\n' "$link_word" > "$work/$link_file"
if found "$work/$link_file" > /dev/null; then
  echo "FAIL: $link_file holding only $link_word was refused"
  failures=$((failures + 1))
fi
for word in "${words[@]}"; do
  [ "$word" = "$link_word" ] && continue
  printf 'components.host = "%s"\n    item.%s(launchOptions: nil)\n' "$link_word" "$word" > "$work/$link_file"
  if ! found "$work/$link_file" > /dev/null; then
    echo "FAIL: $link_file holding $word was passed"
    failures=$((failures + 1))
  fi
done
printf 'components.host = "%s"\n' "$link_word" > "$work/$link_file"
printf 'let host = "%s"\n' "$link_word" > "$work/MapsTool.swift"
if ! found "$work/MapsTool.swift" > /dev/null; then
  echo "FAIL: a file other than $link_file holding $link_word was passed"
  failures=$((failures + 1))
fi
if ! found "$work/$link_file" "$work/MapsTool.swift" > /dev/null; then
  echo "FAIL: $link_word in another file was passed beside $link_file"
  failures=$((failures + 1))
fi
if ! found "$work/absent.swift" "$work/$link_file" > /dev/null 2>&1; then
  echo "FAIL: a file that cannot be read was passed beside $link_file"
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
