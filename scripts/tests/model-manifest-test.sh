#!/usr/bin/env bash
# Holds scripts/model-manifest.sh's dependency check for the guest's Alpine packages against small
# hand-written indexes, offline (`--closure`): a set is closed only when every dependency is
# provided at a version that meets its constraint, and a failure names the package and the
# requirement.
#
#   scripts/tests/model-manifest-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../model-manifest.sh"
work="$(mktemp -d -t model-manifest-test)"
trap 'rm -rf "$work"' EXIT

# The minirootfs as far as the check reads it: musl and BusyBox's /bin/sh.
cat > "$work/installed" <<'IDX'
P:musl
V:1.2.5-r12
p:so:libc.musl-aarch64.so.1=1

P:busybox-binsh
V:1.37.0-r20
p:/bin/sh cmd:sh=1.37.0-r20

IDX

# An index shaped like v3.22's for the four packages; BASH_DEPS and NCURSES_DEPS vary per case.
index() {
  cat <<IDX
P:bash
V:5.2.37-r0
S:499996
D:${BASH_DEPS}
p:cmd:bash=5.2.37-r0

P:readline
V:8.2.13-r1
S:123568
D:so:libc.musl-aarch64.so.1 so:libncursesw.so.6
p:so:libreadline.so.8=8.2

P:libncursesw
V:6.5_p20250503-r0
S:161279
D:${NCURSES_DEPS}
p:so:libncursesw.so.6=6.5

P:ncurses-terminfo-base
V:6.5_p20250503-r0
S:21749

IDX
}

pinned=(bash-5.2.37-r0 readline-8.2.13-r1 libncursesw-6.5_p20250503-r0 ncurses-terminfo-base-6.5_p20250503-r0)
failures=0

# case_ <name> <pass|fail> <bash deps> <ncurses deps> [text the failure must name] [packages...]
case_() {
  local name="$1" want="$2" bash_deps="$3" ncurses_deps="$4" names="${5:-}" got status; shift 5
  local packages=("$@")
  [ ${#packages[@]} -gt 0 ] || packages=("${pinned[@]}")
  BASH_DEPS="$bash_deps" NCURSES_DEPS="$ncurses_deps" index > "$work/APKINDEX"
  "$script" --closure "$work/APKINDEX" "$work/installed" "${packages[@]}" > "$work/out" 2>&1
  status=$?
  [ "$status" = 0 ] && got=pass || got=fail
  if [ "$got" != "$want" ]; then
    echo "FAIL $name: wanted $want, the check exited $status"; sed 's/^/    | /' "$work/out"; failures=$((failures + 1))
  elif [ "$want" = fail ] && [ -n "$names" ] && ! grep -Fq -- "$names" "$work/out"; then
    echo "FAIL $name: failed without naming '$names'"; sed 's/^/    | /' "$work/out"; failures=$((failures + 1))
  else
    echo "ok   $name: $(tail -1 "$work/out")"
  fi
}

base="/bin/sh so:libc.musl-aarch64.so.1 so:libreadline.so.8"
nc="ncurses-terminfo-base=6.5_p20250503-r0 so:libc.musl-aarch64.so.1"
case_ the-pinned-set-is-closed         pass "$base" "$nc" ""
case_ readline-at-least-8              pass "$base readline>=8" "$nc" ""
case_ readline-at-least-9              fail "$base readline>=9" "$nc" "bash requires readline>=9, but readline is 8.2.13-r1"
case_ readline-below-8.2.13-r1         fail "$base readline<8.2.13-r1" "$nc" "bash requires readline<8.2.13-r1"
case_ readline-below-8.2.13-r2         pass "$base readline<8.2.13-r2" "$nc" ""
case_ a-provided-so-at-its-version     pass "$base so:libreadline.so.8>=8.2" "$nc" ""
case_ a-provided-so-too-new            fail "$base so:libreadline.so.8>8.2" "$nc" "bash requires so:libreadline.so.8>8.2, but so:libreadline.so.8 is 8.2"
case_ an-exact-release-that-differs    fail "$base" "ncurses-terminfo-base=6.5_p20250503-r1 so:libc.musl-aarch64.so.1" \
                                            "libncursesw requires ncurses-terminfo-base=6.5_p20250503-r1"
case_ a-fuzzy-match                    pass "$base readline~8.2" "$nc" ""
case_ a-fuzzy-miss                     fail "$base readline~8.3" "$nc" "bash requires readline~8.3"
case_ a-versioned-need-of-an-unversioned-provide fail "$base /bin/sh>=1" "$nc" "bash requires /bin/sh>=1"
case_ from-the-minirootfs-at-its-version pass "$base so:libc.musl-aarch64.so.1>=1" "$nc" ""
case_ nothing-provides-it              fail "$base so:libfoo.so.1" "$nc" "nothing pinned or in the minirootfs provides so:libfoo.so.1"
case_ readline-left-out                fail "$base" "$nc" "bash requires so:libreadline.so.8" \
                                            bash-5.2.37-r0 libncursesw-6.5_p20250503-r0 ncurses-terminfo-base-6.5_p20250503-r0
case_ a-conflict-is-not-a-need         pass "$base !bash-completion" "$nc" ""

if [ "$failures" -gt 0 ]; then
  echo "$failures case(s) failed against $script"
  exit 1
fi
echo "all cases held against $script"
