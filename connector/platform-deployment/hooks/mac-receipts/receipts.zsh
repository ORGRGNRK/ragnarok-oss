# Mac receipts, zsh side. Sourced from ~/.zshenv (every zsh). Safe for non-interactive shells:
# no output, never reads stdin, never touches fds 3-5 (Grok Bot's runner uses them), never
# changes an exit code. The write happens in a detached background node process.
#
#  - Grok Bot (non-interactive `zsh -c` runner, marked by SAND_AGENT/CURSOR_AGENT and the runner
#    script): one receipt per command at shell exit, Actor "Grok Bot", session = conversation id.
#  - Other AI CLIs that run `zsh -c` with a known env marker (Codex, Gemini CLI, Aider, ...).
#  - Interactive Terminal: preexec/precmd, Actor "human-terminal" (an AI typing into Terminal.app
#    cannot be told apart from the operator; set RAGNAROK_RECEIPTS_TERMINAL=0 to stop logging these).
#  - Claude Code's own shells (CLAUDECODE=1) are skipped here: its PostToolUse hook covers them.
# Off switch: touch ~/.ragnarok/receipts.off
[[ -n ${RAGNAROK_RCPT_INTERNAL-} || -e $HOME/.ragnarok/receipts.off ]] && return 0
# Resolve tools and the adjacent receipt script on the current host.
typeset -g _RCPT_NODE=${RAGNAROK_RCPT_NODE:-${commands[node]-}}
typeset -g _RCPT_JS=${RAGNAROK_RCPT_JS:-${${(%):-%x}:A:h}/receipt.mjs}
[[ -x $_RCPT_NODE && -r $_RCPT_JS ]] || return 0

# _rcpt_send actor session source exit cwd command
_rcpt_send() {
  [[ -e $HOME/.ragnarok/receipts.off ]] && return 0
  ( RAGNAROK_RCPT_INTERNAL=1 "$_RCPT_NODE" "$_RCPT_JS" zsh "$@" </dev/null >/dev/null 2>&1 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &! ) >/dev/null 2>&1
  return 0
}

if [[ -o interactive ]]; then
  [[ ${RAGNAROK_RECEIPTS_TERMINAL-1} == 0 || -n ${CLAUDECODE-} ]] && return 0
  typeset -g _RCPT_ACTOR=human-terminal _RCPT_CMD=
  [[ -n ${SAND_AGENT-}${CURSOR_AGENT-} ]] && _RCPT_ACTOR='Grok Bot'
  _rcpt_preexec() { _RCPT_CMD=$1 }
  _rcpt_precmd() {
    local e=$?
    [[ -z $_RCPT_CMD ]] && return 0
    _rcpt_send "$_RCPT_ACTOR" "${TERM_SESSION_ID:-${TTY:-tty}}" zsh-interactive "$e" "$PWD" "$_RCPT_CMD"
    _RCPT_CMD=
    return 0
  }
  typeset -ga preexec_functions precmd_functions
  preexec_functions+=(_rcpt_preexec)
  precmd_functions+=(_rcpt_precmd)
  return 0
fi

[[ -n ${ZSH_EXECUTION_STRING-} && -z ${CLAUDECODE-} ]] || return 0

if [[ -n ${SAND_AGENT-}${CURSOR_AGENT-} ]]; then
  # Only the runner's own top-level shell; a `zsh -c` nested inside a Grok Bot command is part of
  # that command's receipt already.
  [[ $ZSH_EXECUTION_STRING == *__cursor_command* || $ZSH_EXECUTION_STRING == *COMMAND_EXIT_CODE* ]] || return 0
  _rcpt_exit_grokbot() { # $1 = exit status, $2 = the command the runner evaluated
    _rcpt_send 'Grok Bot' "${CURSOR_CONVERSATION_ID:-${CURSOR_REQUEST_ID:-unknown}}" zsh-exit "${COMMAND_EXIT_CODE:-$1}" "$PWD" "$2"
  }
  # A string EXIT trap set here runs in the main shell's context, so "$1" is the runner's command.
  trap '_rcpt_exit_grokbot "$?" "$1"' EXIT
  return 0
fi

typeset -g _RCPT_ACTOR=
if [[ -n ${CODEX_SANDBOX-}${CODEX_THREAD_ID-}${CODEX_MANAGED_BY_NPM-}${CODEX_HOME-} ]]; then _RCPT_ACTOR=Codex
elif [[ -n ${GEMINI_CLI-} ]]; then _RCPT_ACTOR='Gemini CLI'
elif [[ -n ${AIDER_MODEL-}${AIDER_CHAT-} ]]; then _RCPT_ACTOR=Aider
elif [[ -n ${GROK_AGENT-}${GROK_CLI-}${GROK_SESSION_ID-} ]]; then _RCPT_ACTOR='Grok CLI'
elif [[ -n ${AI_AGENT-}${AGENT_NAME-} ]]; then _RCPT_ACTOR=${AI_AGENT:-$AGENT_NAME}
fi
[[ -n $_RCPT_ACTOR ]] || return 0
trap '_rcpt_send "$_RCPT_ACTOR" "${CODEX_THREAD_ID:-${GROK_SESSION_ID:-$PPID}}" zsh-exit "$?" "$PWD" "$ZSH_EXECUTION_STRING"' EXIT
return 0
