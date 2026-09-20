# Source at the END of ~/.zshrc, after Oh My Posh initialization.
# Requires zsh 5.8+ and Python 3.8+. Git scans run only in a background process.
[[ -o interactive ]] || return 0

# Re-sourcing must not stack workers or duplicate hooks.
if (( $+functions[dev-git-prompt-off] )); then
  dev-git-prompt-off
fi

autoload -Uz add-zsh-hook
zmodload zsh/system || return 1

# Capture these paths once; changing directory/activating a venv is harmless.
typeset -g _dgp_script="${${(%):-%x}:A:h}/dev-git-scan.py"
typeset -g _dgp_python="${commands[python3]:-}"
if [[ -z $_dgp_python || ! -r $_dgp_script ]]; then
  print -u2 -- 'dev-git-prompt: Python 3 or dev-git-scan.py is missing.'
  return 1
fi

typeset -g DEV_GIT_ROOT="${DEV_GIT_ROOT:-$HOME/dev}"
typeset -g DEV_GIT_INTERVAL="${DEV_GIT_INTERVAL:-15}"
typeset -gi _dgp_fd=-1
typeset -g _dgp_buffer='' _dgp_banner='' _dgp_applied=''
typeset -g _dgp_details='The first background scan has not finished.'

_dgp_decorate() {
  emulate -L zsh
  # Strip only our own previous prefix. Never overwrite the theme's prompt.
  if [[ -n $_dgp_applied && $PROMPT == "$_dgp_applied"* ]]; then
    PROMPT=${PROMPT:${#_dgp_applied}}
  fi
  _dgp_applied=$_dgp_banner
  PROMPT="${_dgp_applied}${PROMPT}"
  return 0
}

_dgp_close() {
  emulate -L zsh
  if (( _dgp_fd >= 0 )); then
    zle -F $_dgp_fd 2>/dev/null
    exec {_dgp_fd}<&-
    _dgp_fd=-1
  fi
  _dgp_buffer=''
  return 0
}

_dgp_receive() {
  emulate -L zsh
  local chunk='' frame='' summary='' next='' old="$_dgp_banner"
  local -i rc=0 reads=0
  # Strictly nonblocking; incomplete records are saved until the next event.
  while (( reads++ < 16 )); do
    if sysread -i $_dgp_fd -s 8192 -t 0 chunk; then
      _dgp_buffer+=$chunk
    else
      rc=$?
      break
    fi
  done
  while [[ $_dgp_buffer == *$'\n'* ]]; do
    frame=${_dgp_buffer%%$'\n'*}
    _dgp_buffer=${_dgp_buffer#*$'\n'}
    [[ $frame == *$'\t'* ]] || continue
    summary=${frame%%$'\t'*}
    _dgp_details=${frame#*$'\t'}
    if [[ -n $summary ]]; then
      next="%F{yellow}${summary}%f"$'\n'
    else
      next=''
    fi
    _dgp_banner=$next
  done
  if (( rc == 5 || rc == 2 )) || [[ ${2:-} == nval ]]; then
    _dgp_close
    _dgp_banner='%F{yellow}~/dev: status worker stopped; run dev-git-refresh%f'$'\n'
  fi
  if [[ $_dgp_banner != "$old" ]]; then
    _dgp_decorate
    # Re-expand the existing prompt, preserving the edit buffer and cursor.
    zle && zle .reset-prompt
  fi
  return 0
}

_dgp_precmd() {
  emulate -L zsh
  if (( _dgp_fd < 0 )); then
    # sysopen gives the pipe close-on-exec semantics: `reload`/`exec zsh`
    # cannot inherit an abandoned reader. The Python worker exits on EPIPE.
    if sysopen -r -o cloexec -u _dgp_fd <(
      exec "$_dgp_python" "$_dgp_script" \
        --root "$DEV_GIT_ROOT" --interval "$DEV_GIT_INTERVAL" 2>/dev/null
    ); then
      zle -F $_dgp_fd _dgp_receive
    else
      _dgp_fd=-1
    fi
  fi
  _dgp_decorate
  return 0
}

dev-dirty() {
  # Cached results only. This command does not run a foreground Git scan.
  print -r -- "${_dgp_details// | /$'\n'}"
}

dev-git-refresh() {
  # Request a fresh asynchronous scan without waiting for it.
  _dgp_close
  _dgp_precmd
}

dev-git-prompt-off() {
  _dgp_close
  add-zsh-hook -d precmd _dgp_precmd
  add-zsh-hook -d zshexit _dgp_close
  _dgp_banner=''
  _dgp_decorate
  return 0
}

add-zsh-hook precmd _dgp_precmd
add-zsh-hook zshexit _dgp_close
