# What the tests under scripts/tests share, sourced by a path relative to the test itself:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# It is not a test: the suite runs each test it names as `scripts/tests/<name>-test.sh`, which this is not.
# `fail` counts into `failures`, which the test reads at its end, and prints to stdout as `ok`
# does; a test whose failures go to stderr keeps its own.

failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
ok() { echo "ok   $*"; }
is() {  # is <case> <got> <want>
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', wanted '$3'"; fi
}

# until_true <command…> — runs the command every 0.1 s until it succeeds, for up to 10 s.
until_true() { local n; for n in $(seq 100); do "$@" && return 0; perl -e 'select(undef,undef,undef,0.1)'; done; return 1; }

# repo <script> <dir> <path>... — a scratch repository holding <script> at scripts/<its name>,
# whose last commit adds each path.
repo() {
  local script="$1" dir="$2"; shift 2
  mkdir -p "$dir/scripts"
  cp "$script" "$dir/scripts/$(basename "$script")"
  # A branch of its own and no hooks: whatever hooks this machine installs are not the test's.
  git -C "$dir" init -q -b scratch
  git -C "$dir" config core.hooksPath /dev/null
  git -C "$dir" -c user.name=t -c user.email=t@t add -A
  git -C "$dir" -c user.name=t -c user.email=t@t commit -qm base
  local path
  for path in "$@"; do mkdir -p "$dir/$(dirname "$path")"; echo x > "$dir/$path"; done
  if [ "$#" -gt 0 ]; then
    git -C "$dir" -c user.name=t -c user.email=t@t add -A
    git -C "$dir" -c user.name=t -c user.email=t@t commit -qm change
  fi
}
