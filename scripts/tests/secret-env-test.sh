#!/usr/bin/env bash
# scripts/secret-env.sh: which exported variables it takes for secrets, by name and in any case,
# which it leaves (one naming where a secret is kept, an unexported one, an ordinary one), and
# that a command started behind `scrubbed` has none of them and is the pid its caller recorded.
#
#   scripts/tests/secret-env-test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$here/lib.sh"

run() {  # run <code>: a clean shell with these variables exported, sourcing the helper first
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" CLAUDE_SETUP_TOKEN=a GH_TOKEN=b OP_SERVICE_ACCOUNT_TOKEN=c HONCHO_API_KEY=d \
    GOG_KEYRING_PASSWORD=e AWS_SECRET_ACCESS_KEY=f ASC_PRIVATE_KEY=g npm_config__authToken=h SOME_CREDENTIALS=i \
    API_PRIVATE_KEYS_DIR=/keys SSH_AUTH_SOCK=/sock TOKEN_FILE=/file DEVELOPER_DIR=/dev TEST_RUNNER_TOPO_X=1 \
    bash -c 'unexported_token=z; source "$1"; '"$1" _ "$here/../secret-env.sh" </dev/null
}

is "names: every secret-named variable, in any case, and only those" \
  "$(run 'secret_variables' | sort | tr '\n' ' ')" \
  "ASC_PRIVATE_KEY AWS_SECRET_ACCESS_KEY CLAUDE_SETUP_TOKEN GH_TOKEN GOG_KEYRING_PASSWORD HONCHO_API_KEY OP_SERVICE_ACCOUNT_TOKEN SOME_CREDENTIALS npm_config__authToken "
is "scrubbed: the command started behind it has none of them and keeps the rest" \
  "$(run '"${scrubbed[@]}" env' | cut -d= -f1 | grep -v -e '^PATH$' -e '^HOME$' -e '^PWD$' -e '^SHLVL$' -e '^_$' -e '^TMPDIR$' | sort | tr '\n' ' ')" \
  "API_PRIVATE_KEYS_DIR DEVELOPER_DIR SSH_AUTH_SOCK TEST_RUNNER_TOPO_X TOKEN_FILE "
# The pid a caller records for a command started behind `scrubbed` is the command's: env execs it.
is "scrubbed: the recorded pid is the command's own" \
  "$(run '"${scrubbed[@]}" bash -c "echo \$\$" > "$TMPDIR/secret-env-test.$$" & pid=$!; wait "$pid"; [ "$(cat "$TMPDIR/secret-env-test.$$")" = "$pid" ] && echo same; rm -f "$TMPDIR/secret-env-test.$$"')" same
is "drop_secrets: the shell keeps none of them and the rest, and its nocasematch setting" \
  "$(run 'drop_secrets; compgen -e | grep -v -e "^PATH$" -e "^HOME$" -e "^PWD$" -e "^SHLVL$" -e "^OLDPWD$" -e "^TMPDIR$" | sort | tr "\n" " "; shopt -q nocasematch && echo on || echo off')" \
  "API_PRIVATE_KEYS_DIR DEVELOPER_DIR SSH_AUTH_SOCK TEST_RUNNER_TOPO_X TOKEN_FILE off"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "all passed"
