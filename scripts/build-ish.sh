#!/usr/bin/env bash
# Builds the guest's kernel and emulator — OpenMinis/ish-arm64 at the pin below, with Topo's
# patches from patches/ish/ — into Packages/TopoUserland/Frameworks/TopoIsh.xcframework, which
# the TopoUserland package links. Two slices, the iOS device and the arm64 simulator, and no
# macOS one: the guest's tests run on the simulator. Nothing it makes is committed; this script
# and its inputs are what the repository carries.
#
#   scripts/build-ish.sh                     # build, or say the framework is already current
#   scripts/build-ish.sh verify <checkout>   # only the source checks, on an existing checkout
#   scripts/build-ish.sh verify-options <meson build dir>
#   scripts/build-ish.sh inputs              # the digest the framework is keyed on (CI's cache key)
#
# What it refuses to build, each a failure with the reason:
#   - a checkout whose HEAD is not the pin;
#   - a patch that does not apply (`git apply --check`), so a pin bump with a stale patch stops
#     here rather than building the fork without it;
#   - a meson configuration whose guest_arch, kernel and engine are not arm64, ish and asbestos;
#   - a populated deps/linux or deps/libapps: the Linux-kernel build and the terminal are GPL code
#     iSH's App Store waiver (LICENSE.IOS) does not cover, so neither submodule is ever fetched;
#   - a library that does not export `ish_mem_refresh_hook`, the brake patch's symbol.
#
# The fork's libish, libish_emu and libfakefs come from its own meson build, cross-compiled per
# slice. libarchive (deps/libarchive, BSD) is compiled here with the fork's deps/config.h less
# libxml2, whose digests are the system's (libSystem) and which links no crypto library. The fork's importer
# (tools/fakefs.c) and Topo's glue (Packages/TopoUserland/Guest) are compiled against the fork's
# headers, and everything is archived into one static library per slice with the glue's header
# as the module's only interface.
#
# Needs meson, ninja and Homebrew's llvm and lld (the guest's VDSO is an aarch64 ELF, which
# Apple's toolchain does not link): `brew install meson ninja llvm lld`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pin=e1d579480fba88e8f0428e3cf23811bcdd05421f
repo="${ISH_REPO:-https://github.com/OpenMinis/ish-arm64.git}"
patches_dir="$root/patches/ish"
glue="$root/Packages/TopoUserland/Guest"
out="$root/Packages/TopoUserland/Frameworks/TopoIsh.xcframework"
work="${ISH_WORK:-$root/build/ish}"
source_dir="$work/src"
min_ios=17.0
meson_options=(-Dguest_arch=arm64 -Dkernel=ish -Dengine=asbestos)

fail() { echo "build-ish: $*" >&2; exit 1; }

inputs_digest() {
  {
    echo "$pin"
    printf '%s\n' "${meson_options[@]}"
    cat "${BASH_SOURCE[0]}"
    for f in "$patches_dir"/*.patch; do echo "$f"; cat "$f"; done
    (cd "$glue" && find . -type f | LC_ALL=C sort | while read -r f; do echo "$f"; cat "$f"; done)
  } | shasum -a 256 | cut -d' ' -f1
}

# The checkout is the pin, carries no GPL submodule the waiver does not cover, and takes every
# patch. Run on a clean tree, before the patches are applied.
verify_source() {
  local dir="$1" head
  head="$(git -C "$dir" rev-parse HEAD 2>/dev/null)" || fail "$dir is not a git checkout"
  [ "$head" = "$pin" ] || fail "$dir is at $head, not the pin $pin"
  local sub
  for sub in deps/linux deps/libapps; do
    if [ -d "$dir/$sub" ] && [ -n "$(ls -A "$dir/$sub" 2>/dev/null)" ]; then
      fail "$sub is populated in $dir; it is never fetched (GPL outside iSH's App Store waiver)"
    fi
  done
  local patch found=no
  for patch in "$patches_dir"/*.patch; do
    [ -f "$patch" ] || continue
    found=yes
    git -C "$dir" apply --check "$patch" 2>/dev/null || fail "$(basename "$patch") does not apply to $pin"
  done
  [ "$found" = yes ] || fail "no patches in $patches_dir"
}

# The configuration meson actually took, read back rather than assumed from the command line.
verify_options() {
  local build="$1" json
  json="$(meson introspect --buildoptions "$build")" || fail "meson cannot read $build"
  local name want got
  for pair in guest_arch=arm64 kernel=ish engine=asbestos; do
    name="${pair%%=*}"; want="${pair#*=}"
    got="$(/usr/bin/python3 -c 'import json,sys; n=sys.argv[1]; print(next((str(o["value"]) for o in json.load(sys.stdin) if o["name"]==n), ""))' "$name" <<< "$json")"
    [ "$got" = "$want" ] || fail "$build is configured with $name=${got:-unset}, not $want"
  done
}

case "${1:-}" in
  verify) verify_source "${2:?a checkout}"; echo "build-ish: $2 is the pin and takes every patch"; exit 0 ;;
  verify-options) verify_options "${2:?a meson build directory}"; echo "build-ish: $2 is arm64, ish, asbestos"; exit 0 ;;
  inputs) inputs_digest; exit 0 ;;
  "") ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

digest="$(inputs_digest)"
stamp="$out/.inputs"
if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$digest" ]; then
  echo "build-ish: $out is current ($digest)"
  exit 0
fi

for tool in meson ninja; do
  command -v "$tool" >/dev/null || fail "$tool is not installed (brew install meson ninja llvm lld)"
done
brew_prefix="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
[ -x "$brew_prefix/opt/llvm/bin/clang" ] && [ -x "$brew_prefix/opt/lld/bin/ld.lld" ] \
  || fail "Homebrew's llvm and lld are needed for the guest's VDSO (brew install llvm lld)"
export PATH="$brew_prefix/opt/lld/bin:$brew_prefix/opt/llvm/bin:$PATH"

# The source: the pin, fetched alone, then reset and cleaned so nothing from an earlier build or
# an earlier pin survives into this one.
mkdir -p "$work"
if [ ! -d "$source_dir/.git" ]; then
  git init -q "$source_dir"
fi
if ! git -C "$source_dir" cat-file -e "$pin^{commit}" 2>/dev/null; then
  echo "==> fetching $pin from $repo"
  git -C "$source_dir" fetch -q --depth 1 "$repo" "$pin" || fail "cannot fetch $pin from $repo"
fi
git -C "$source_dir" -c advice.detachedHead=false checkout -q --force --detach "$pin"
git -C "$source_dir" reset -q --hard "$pin"
git -C "$source_dir" clean -qfdx -e deps/libarchive
verify_source "$source_dir"
# libarchive only; deps/linux and deps/libapps are never initialised.
git -C "$source_dir" submodule update -q --init --depth 1 deps/libarchive
for patch in "$patches_dir"/*.patch; do
  echo "==> applying $(basename "$patch")"
  git -C "$source_dir" apply "$patch"
done

libarchive_sources=()
while IFS= read -r f; do libarchive_sources+=("$f"); done < <(
  cd "$source_dir/deps/libarchive/libarchive" && ls *.c | grep -v -E '_windows\.c$|^test' | LC_ALL=C sort)

rm -rf "$work/slices"
# The headers sit in a directory named after the module: Xcode copies every static framework's
# headers into one include/ directory, where two top-level module.modulemap files collide.
mkdir -p "$work/slices/headers/TopoIsh"
libraries=()
for slice in iphoneos iphonesimulator; do
  case "$slice" in
    iphoneos) target="arm64-apple-ios$min_ios" ;;
    iphonesimulator) target="arm64-apple-ios$min_ios-simulator" ;;
  esac
  sdk="$(xcrun --sdk "$slice" --show-sdk-path)"
  cc=(xcrun --sdk "$slice" clang -target "$target" -isysroot "$sdk")
  dir="$work/slices/$slice"
  mkdir -p "$dir/obj/archive" "$dir/obj/glue"
  cat > "$dir/cross.txt" <<EOF
[binaries]
c = ['xcrun', '--sdk', '$slice', 'clang']
ar = ['xcrun', '--sdk', '$slice', 'ar']
strip = ['xcrun', '--sdk', '$slice', 'strip']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-target', '$target', '-isysroot', '$sdk']
c_link_args = ['-target', '$target', '-isysroot', '$sdk']

[properties]
needs_exe_wrapper = true
EOF
  echo "==> meson ($slice)"
  meson setup "$dir/meson" "$source_dir" --cross-file "$dir/cross.txt" \
    --buildtype=debugoptimized "${meson_options[@]}" >/dev/null
  verify_options "$dir/meson"
  ninja -C "$dir/meson" libish.a libish_emu.a libfakefs.a >/dev/null

  echo "==> libarchive ($slice)"
  # The fork's config, less libxml2: only the xar format uses it, and nothing here reads or writes
  # xar, so it is built as the stub libarchive makes without it rather than pulling libxml2 in.
  mkdir -p "$dir/config"
  grep -v -E 'define HAVE_LIBXML_XML(READER|WRITER)_H' "$source_dir/deps/config.h" > "$dir/config/config.h"
  for f in "${libarchive_sources[@]}"; do
    "${cc[@]}" -O2 -g -DHAVE_CONFIG_H -w -I"$dir/config" -I"$source_dir/deps/libarchive/libarchive" \
      -c "$source_dir/deps/libarchive/libarchive/$f" -o "$dir/obj/archive/${f%.c}.o"
  done

  echo "==> importer and glue ($slice)"
  includes=(-I"$source_dir" -I"$dir/meson" -I"$source_dir/vdso/arm64" -I"$source_dir/deps/libarchive/libarchive" -I"$glue/include")
  defines=(-DGUEST_ARM64=1 -DENGINE_ASBESTOS=1 -DLOG_HANDLER_DPRINTF=1 -std=gnu11)
  "${cc[@]}" -O2 -g -w "${defines[@]}" "${includes[@]}" -c "$source_dir/tools/fakefs.c" -o "$dir/obj/glue/fakefs.o"
  "${cc[@]}" -O2 -g -Wall -Wno-unused-parameter "${defines[@]}" "${includes[@]}" -c "$glue/topo_ish.c" -o "$dir/obj/glue/topo_ish.o"
  # The vault's filesystem is Objective-C: NSFileCoordinator has no C interface.
  "${cc[@]}" -O2 -g -Wall -Wno-unused-parameter -fobjc-arc "${defines[@]}" "${includes[@]}" -c "$glue/topo_vaultfs.m" -o "$dir/obj/glue/topo_vaultfs.o"

  libtool -static -no_warning_for_no_symbols -o "$dir/libTopoIsh.a" \
    "$dir/meson/libish.a" "$dir/meson/libish_emu.a" "$dir/meson/libfakefs.a" \
    "$dir"/obj/archive/*.o "$dir"/obj/glue/*.o
  # Read whole before matching: `grep -q` closing the pipe early fails `nm` under pipefail.
  symbols="$(nm -gU "$dir/libTopoIsh.a" 2>/dev/null)"
  grep -q ' _ish_mem_refresh_hook$' <<< "$symbols" \
    || fail "$slice: the library does not export ish_mem_refresh_hook; the brake patch is not in it"
  libraries+=(-library "$dir/libTopoIsh.a" -headers "$work/slices/headers")
done

# The module's one interface is the glue's header.
cp "$glue/include/topo_ish.h" "$work/slices/headers/TopoIsh/"
cat > "$work/slices/headers/TopoIsh/module.modulemap" <<'EOF'
module TopoIsh {
    header "topo_ish.h"
    link "sqlite3"
    link "z"
    link "iconv"
    link "bz2"
    export *
}
EOF

rm -rf "$out"
mkdir -p "$(dirname "$out")"
xcodebuild -create-xcframework "${libraries[@]}" -output "$out" >/dev/null
echo "$digest" > "$stamp"
echo "build-ish: $out ($digest)"
