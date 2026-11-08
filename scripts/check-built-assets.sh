#!/usr/bin/env bash
# Reads the built app for the voice's bundle, which only the install page's builds carry
# (`TOPO_EMBED_VOICES=YES`, scripts/embed-voice.sh): an App Store or TestFlight build gets it as an
# Apple-hosted asset pack instead, and the weights in the app would ship them twice and outside
# the pack. The build setting is not proof, so this reads the product.
#
#   scripts/check-built-assets.sh <path to Topo.app>              # carries no part of the bundle
#   scripts/check-built-assets.sh --embedded <path to Topo.app>   # carries the whole bundle
#
# Without `--embedded`, any of these anywhere in the app is a failure: a `phonon-40m-en` folder; a
# model in any of Core ML's forms (`.mlpackage`, `.mlmodel`, `.mlmodelc`, the compiled one Xcode
# makes of the other two); weights by their own extensions (`.safetensors`, `.gguf`, `.onnx`,
# `.pt`, `.pth`, `.ckpt`, `.npz`) or the `.aar` the pack is shipped as; and any file larger than
# 4 MiB that is not code (a Mach-O), which is renamed weights; the largest resource the app has
# otherwise, its asset catalogue, is under 2 MiB. With it, the app's `phonon-40m-en/bundle.json`
# has to be there and every file it lists at the size it names.
set -euo pipefail

embedded=no
if [ "${1-}" = --embedded ]; then embedded=yes; shift; fi
app="${1:?usage: check-built-assets.sh [--embedded] <Topo.app>}"
[ -d "$app" ] || { echo "$app is not a built app" >&2; exit 1; }
name=phonon-40m-en

if [ "$embedded" = no ]; then
  found="$(find "$app" \( -name "$name" -o -name '*.mlpackage' -o -name '*.mlmodel' -o -name '*.mlmodelc' \
    -o -name '*.safetensors' -o -name '*.gguf' -o -name '*.onnx' -o -name '*.pt' -o -name '*.pth' \
    -o -name '*.ckpt' -o -name '*.npz' -o -name '*.aar' \) -prune -print 2>/dev/null)"
  # A Mach-O's magic, thin or universal, in either byte order.
  is_code() { [[ "$(head -c 4 "$1" | xxd -p)" =~ ^(cffaedfe|cefaedfe|feedfacf|feedface|cafebabe|bebafeca)$ ]]; }
  large="$(find "$app" -type f -size +4096k -print 2>/dev/null | while IFS= read -r file; do
    is_code "$file" || echo "$file"
  done)"
  found="$(printf '%s\n%s\n' "$found" "$large" | sed '/^$/d')"
  if [ -n "$found" ]; then
    echo "$app carries a model or weights, which only an install-page build may: $(echo "$found" | head -5 | tr '\n' ' ')" >&2
    exit 1
  fi
  echo "$app carries no model and no weights"
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
