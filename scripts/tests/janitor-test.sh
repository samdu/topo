#!/usr/bin/env bash
# scripts/janitor.py's decisions over scripted readings, and one whole pass
# against a fake gh, git, tmux, curl and claude: the merge is pinned to the
# head the green run was read for, a run with no verdict has one reviewer job
# rerun once per head, the
# install page is republished from origin/main, a merged branch's worktree is
# swept, an issue is triaged by one allowed gh call or none, a device box is
# ticked on its build issue's results counted by respondent, and an
# undelivered report is kept. No network, no repository, no session.
#
#   scripts/tests/janitor-test.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -m unittest -v "$here/janitor_test.py"
