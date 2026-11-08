#!/usr/bin/env bash
# Reads the built app for the voice's bundle, which only the install page's builds carry
# (`TOPO_EMBED_VOICES=YES`, scripts/embed-voice.sh): an App Store or TestFlight build gets it as an
# Apple-hosted asset pack instead, and the weights in the app would ship them twice and outside
# the pack. The build setting is not proof, so this reads the product.
#
#   scripts/check-built-assets.sh <path to Topo.app>              # carries no part of the bundle
#   scripts/check-built-assets.sh --embedded <path to Topo.app>   # carries the whole bundle
#
# Without `--embedded`, any `phonon-40m-en` folder, Core ML package or `.safetensors` file anywhere
# in the app is a failure, so a bundle copied under another name is caught as well. With it, the
# app's `phonon-40m-en/bundle.json` has to be there and every file it lists at the size it names.
set -euo pipefail

embedded=no
if [ "${1-}" = --embedded ]; then embedded=yes; shift; fi
app="${1:?usage: check-built-assets.sh [--embedded] <Topo.app>}"
[ -d "$app" ] || { echo "$app is not a built app" >&2; exit 1; }
name=phonon-40m-en

if [ "$embedded" = no ]; then
  found="$(find "$app" \( -name "$name" -o -name '*.mlpackage' -o -name '*.safetensors' \) -print 2>/dev/null | head -5)"
  if [ -n "$found" ]; then
    echo "$app carries the voice's bundle, which only an install-page build may: $(echo "$found" | tr '\n' ' ')" >&2
    exit 1
  fi
  echo "$app carries no part of the voice's bundle"
  exit 0
fi

bundle="$app/$name"
[ -f "$bundle/bundle.json" ] || { echo "$app does not carry $name/bundle.json; this build has no voice" >&2; exit 1; }
missing="$(cd "$bundle" && jq -r '.files[] | [.path, (.size|tostring)] | @tsv' bundle.json |
  while IFS=$'\t' read -r path size; do
    [ -f "$path" ] && [ "$(stat -f %z "$path")" = "$size" ] || echo "$path"
  done)"
if [ -n "$missing" ]; then
  echo "$app's $name lacks or has the wrong size of: $(echo "$missing" | tr '\n' ' ')" >&2
  exit 1
fi
echo "$app carries the whole of $name"
