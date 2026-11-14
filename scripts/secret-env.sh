# Sourced, never run. The exported variables whose names say they hold a secret, and a way to
# start a command without them.
#
# xcodebuild writes its own environment into the build description it keeps under the derived
# data's XCBuildData, so whatever the shell exports reaches that folder: on buddybox that is
# CLAUDE_SETUP_TOKEN, GH_TOKEN, OP_SERVICE_ACCOUNT_TOKEN and more, exported to every shell. A
# script that runs a build starts it as `"${scrubbed[@]}" xcodebuild …`, or drops the variables
# from its own shell when it needs none of them (scripts/mac-suite.sh).
#
# A secret is a variable whose name holds TOKEN, SECRET, PASSWORD, PASSWD, PRIVATE_KEY, API_KEY or
# CREDENTIAL, in any case, and does not end in _DIR, _PATH, _FILE or _SOCK, which name where one
# is kept (API_PRIVATE_KEYS_DIR, which altool reads, stays). A value whose name says none of this
# is not found by it.
#
# Written with bash builtins alone (compgen, [[ ]]), so it works on a PATH with nothing on it.

secret_variables() {
  local name restore
  restore="$(shopt -p nocasematch)"
  shopt -s nocasematch
  for name in $(compgen -e); do
    if [[ "$name" =~ (TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE_KEY|API_KEY|CREDENTIAL) ]] \
      && ! [[ "$name" =~ _(DIR|PATH|FILE|SOCK)$ ]]; then
      printf '%s\n' "$name"
    fi
  done
  eval "$restore"
}

# `env` with an -u for each, as words to put in front of a command. env execs the command, so
# the pid a caller records for it is the command's own.
scrubbed=(env)
for secret_name in $(secret_variables); do scrubbed+=(-u "$secret_name"); done
unset secret_name

# Drops every such variable from the calling shell, for a script that needs none of them.
drop_secrets() {
  local name
  for name in $(secret_variables); do unset "$name"; done
}
