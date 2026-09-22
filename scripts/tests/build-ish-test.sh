#!/usr/bin/env bash
# Holds scripts/build-ish.sh's refusals red: a checkout that is not the pin, a patch that does not
# apply, a populated GPL submodule, and a meson configuration that is not arm64/ish/asbestos each
# fail, and the same checks pass on the real thing — so a failure here is the check, not a broken
# fixture.
#
# The patch and submodule cases need the fork at the pin. The build's own checkout (build/ish/src,
# or ISH_WORK/src) is copied when it is there; otherwise the pin is fetched, shallow, into the
# test's own directory.
#
#   scripts/tests/build-ish-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
script="$root/scripts/build-ish.sh"
pin="$(sed -n 's/^pin=//p' "$script")"
[ -n "$pin" ] || { echo "no pin in $script" >&2; exit 2; }

work="$(mktemp -d -t build-ish-test)"
trap 'rm -rf "$work"' EXIT
failures=0

expect() {
  local want="$1" name="$2" match="$3"; shift 3
  local out status
  out="$("$@" 2>&1)" && status=0 || status=$?
  if [ "$want" = fail ] && [ "$status" = 0 ]; then
    echo "FAIL $name: exited 0"; echo "$out" | sed 's/^/    /'; failures=$((failures + 1)); return
  fi
  if [ "$want" = pass ] && [ "$status" != 0 ]; then
    echo "FAIL $name: exited $status"; echo "$out" | sed 's/^/    /'; failures=$((failures + 1)); return
  fi
  if [ -n "$match" ] && ! grep -q -- "$match" <<< "$out"; then
    echo "FAIL $name: no '$match' in the output"; echo "$out" | sed 's/^/    /'; failures=$((failures + 1)); return
  fi
  echo "ok   $name"
}

# A checkout of some other commit, on a branch of its own and with no hooks: whatever hooks this
# machine runs on a commit are not the test's.
git init -q -b fixture "$work/other"
git -C "$work/other" -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t commit -q --allow-empty -m other
expect fail "a checkout that is not the pin" "not the pin" "$script" verify "$work/other"

# The fork at the pin, clean.
source="${ISH_WORK:-$root/build/ish}/src"
fork="$work/fork"
if [ -d "$source/.git" ] && git -C "$source" cat-file -e "$pin^{commit}" 2>/dev/null; then
  git clone -q --no-checkout "$source" "$fork"
  git -C "$fork" -c advice.detachedHead=false checkout -q "$pin"
else
  git init -q "$fork"
  git -C "$fork" fetch -q --depth 1 https://github.com/OpenMinis/ish-arm64.git "$pin" \
    || { echo "cannot fetch the pin" >&2; exit 2; }
  git -C "$fork" -c advice.detachedHead=false checkout -q FETCH_HEAD
fi
expect pass "the pin itself verifies" "takes every patch" "$script" verify "$fork"

# The brake's own lines changed under the patch: what a new pin that moved kernel/mmap.c is.
sed -i '' 's/dead sampler fails closed/the sampler is dead/' "$fork/kernel/mmap.c"
expect fail "a patch that does not apply" "0001-memory-brake-refresh.patch does not apply" "$script" verify "$fork"
git -C "$fork" checkout -q -- kernel/mmap.c

# The Linux-kernel build's source, present.
mkdir -p "$fork/deps/linux" && touch "$fork/deps/linux/Makefile"
expect fail "a populated deps/linux" "deps/linux is populated" "$script" verify "$fork"
rm -rf "$fork/deps/linux"/*

# meson's configuration read back, through a fake meson that answers what FAKE_OPTIONS says.
mkdir -p "$work/bin"
cat > "$work/bin/meson" <<'EOF'
#!/bin/bash
[ "$1 $2" = "introspect --buildoptions" ] || exit 1
echo "$FAKE_OPTIONS"
EOF
chmod +x "$work/bin/meson"
options() { printf '[{"name":"guest_arch","value":"%s"},{"name":"kernel","value":"%s"},{"name":"engine","value":"%s"}]' "$@"; }
PATH="$work/bin:$PATH" FAKE_OPTIONS="$(options arm64 ish asbestos)" \
  expect pass "arm64, ish, asbestos" "arm64, ish, asbestos" "$script" verify-options "$work"
PATH="$work/bin:$PATH" FAKE_OPTIONS="$(options arm64 linux asbestos)" \
  expect fail "the Linux kernel" "kernel=linux, not ish" "$script" verify-options "$work"
PATH="$work/bin:$PATH" FAKE_OPTIONS="$(options x86 ish asbestos)" \
  expect fail "an x86 guest" "guest_arch=x86, not arm64" "$script" verify-options "$work"
PATH="$work/bin:$PATH" FAKE_OPTIONS="$(options arm64 ish unicorn)" \
  expect fail "the Unicorn engine" "engine=unicorn, not asbestos" "$script" verify-options "$work"

[ "$failures" = 0 ] && echo "build-ish.sh refuses what it should" || { echo "$failures failure(s)"; exit 1; }
