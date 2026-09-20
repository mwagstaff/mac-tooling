# Aliases
alias activate="python3 -m venv venv && source venv/bin/activate"
alias aliases="grep 'alias ' ~/.zshrc"
alias b="npm install @capacitor/ios && npx cap add ios >/dev/null ; npm run build && npx cap sync ios && npx cap open ios"
alias bp="code ~/.zshrc"
alias cj="code ~/.claude/settings.json"
alias ccusage="bunx ccusage"
alias cl="checkpoint list"
alias cu="bunx ccusage"
colours() {
  for i in {0..255}; do
    print -Pn "%K{$i}  %k%F{$i}${(l:3::0:)i}%f " ${${(M)$((i%6)):#3}:+$'\n'}
  done
}
alias dev="npm run dev"
alias pair="~/dev/scripts/xcode-scripts/pair.sh"
alias pip="pip3"
alias python="python3"
alias reload="exec zsh"
alias todo="grep -rIi todo . --exclude-dir={node_modules,.git,dist,cypress,.vscode,ios}"
alias mongo="ssh -L 27017:localhost:27017 sky"
alias clean-worktrees='git -C /Users/mwagstaff/dev/kidventures worktree list --porcelain | grep "worktree .*/.claude/worktrees" | awk "{print \$2}" | xargs -I{} git -C /Users/mwagstaff/dev/kidventures worktree remove --force {} 2>/dev/null; find /Users/mwagstaff/dev/kidventures/.claude/worktrees -mindepth 1 -maxdepth 1 -type d | xargs rm -rf'
alias gc="~/dev/mac-tooling/git/commit.zsh"
alias gs="~/dev/mac-tooling/git/status.zsh"

# Bitwarden
BW_ENV_FOLDER_NAME="${BW_ENV_FOLDER_NAME:-Local environment variables}"
BW_ENV_CACHE_TTL_SECONDS="${BW_ENV_CACHE_TTL_SECONDS:-900}"
BW_ENV_CACHE_FILE="${BW_ENV_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-tooling/bitwarden-env}"
BW_SESSION_CACHE_FILE="${BW_SESSION_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-tooling/bitwarden-session}"

# Git
git config --global user.name "Mike Wagstaff"
git config --global user.email "mike.wagstaff@gmail.com"

# Created by `pipx` on 2024-05-06 18:12:03
export PATH="$PATH:/Users/${USER}/.local/bin"

# Add Homebrew to PATH
export PATH="/opt/homebrew/bin:$PATH"

# Claude Code cleanup function - removes worktrees and branches created by Claude Code
function cleanup() {
  echo "Cleaning up Claude Code worktrees and branches..."

  # Remove worktrees
  for wt in $(git worktree list --porcelain | grep "worktree " | awk '{print $2}' | grep "\.claude/worktrees"); do
    git worktree remove --force "$wt"
  done

  # Delete merged local branches
  git branch | grep "claude/" | xargs git branch -d

  # Delete remote branches
  git branch -r | grep "origin/claude/" | sed 's|origin/||' | xargs -I{} git push origin --delete {}
}

# Set the terminal title to the current diretory using tabset
function setTitle() {
  dir=$(basename "$PWD")
  tabset --title "${dir}" --hash "${dir}"
}

# Find files by name using "find . -name <pattern>"
function f() {
  find . -name "$1"
}

# Functions to call when changing directories
chpwd_functions=(${chpwd_functions[@]} "setTitle")
export PATH="$PATH:$HOME/.local/bin"

# Claude Code Checkpoint - Added by claude-code-checkpoint
export PATH="/Users/mwagstaff/.claude/checkpoint/scripts:$PATH"

# Spinner code for slow Bitwarden commands
bw_show_spinner() {
  [ "$#" -eq 2 ] || return

  local pid="$1"
  local label="$2"
  local -a colors
  colors=(196 202 208 214 220 118 45 39 63 99 135 171)

  local width=24
  local trail=8
  local offset=0
  local i
  local distance
  local color_index
  local bar
  local segment

  while kill -0 "$pid" 2>/dev/null; do
    bar=""
    for (( i = 0; i < width; i++ )); do
      distance=$(( (i - offset + width) % width ))
      if (( distance < trail )); then
        color_index=$(( distance % ${#colors[@]} + 1 ))
        segment="$(printf '\033[38;5;%sm=\033[0m' "${colors[$color_index]}")"
      else
        segment="$(printf '\033[38;5;240m-\033[0m')"
      fi
      bar+="$segment"
    done

    print -n -u2 -- $'\r['"$bar"$'] '"$label"
    sleep 0.1
    (( offset = (offset + 1) % width ))
  done

  print -n -u2 -- $'\r\033[2K'
}

bw_run_with_spinner() {
  emulate -L zsh
  setopt localoptions nomonitor nonotify

  [ "$#" -ge 2 ] || return

  local label="$1"
  shift

  if ! [ -t 2 ]; then
    "$@"
    return $?
  fi

  local stdout_file
  local stderr_file
  local command_pid
  local spinner_pid
  local exit_code

  stdout_file="$(mktemp "${TMPDIR:-/tmp}/bw-stdout.XXXXXX")" || return
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/bw-stderr.XXXXXX")" || {
    rm -f "$stdout_file"
    return
  }

  "$@" >"$stdout_file" 2>"$stderr_file" &
  command_pid=$!

  bw_show_spinner "$command_pid" "$label" &
  spinner_pid=$!

  wait "$command_pid"
  exit_code=$?
  wait "$spinner_pid" 2>/dev/null

  [ -s "$stderr_file" ] && cat "$stderr_file" >&2
  cat "$stdout_file"

  rm -f "$stdout_file" "$stderr_file"
  return "$exit_code"
}

bw_require_command() {
  [ "$#" -eq 1 ] || return

  local cmd="$1"

  if [ -t 2 ]; then
    bw_run_with_spinner "Checking ${cmd}..." zsh -c 'command -v "$1" >/dev/null 2>&1' _ "$cmd" >/dev/null
    return $?
  fi

  command -v "$cmd" >/dev/null 2>&1
}

bw_cache_session() {
  [ -n "${BW_SESSION:-}" ] || return 0

  local cache_dir
  cache_dir="${BW_SESSION_CACHE_FILE:h}"
  mkdir -p "$cache_dir" || return

  ( umask 077 && printf '%s\n' "$BW_SESSION" > "$BW_SESSION_CACHE_FILE" ) || return
  chmod 600 "$BW_SESSION_CACHE_FILE" 2>/dev/null || true
}

bw_clear_cached_session() {
  [ -f "$BW_SESSION_CACHE_FILE" ] || return 0
  rm -f "$BW_SESSION_CACHE_FILE"
}

bw_load_cached_session() {
  local cached_session
  if [ -n "${BW_SESSION:-}" ]; then
    cached_session="$BW_SESSION"
  else
    [ -f "$BW_SESSION_CACHE_FILE" ] || return 1
    cached_session="$(<"$BW_SESSION_CACHE_FILE")"
  fi
  [ -n "$cached_session" ] || return 1

  local cached_status
  cached_status="$(
    BW_SESSION="$cached_session" bw --nointeraction status 2>/dev/null | jq -r '.status'
  )" || return 1

  if [ "$cached_status" = "unlocked" ]; then
    export BW_SESSION="$cached_session"
    return 0
  fi

  bw_clear_cached_session
  unset BW_SESSION
  return 1
}

bw_run_with_session() {
  [ "$#" -ge 1 ] || return

  bw --nointeraction --session "$BW_SESSION" "$@"
}

bw_ensure_session() {
  bw_require_command bw || return
  bw_require_command jq || return

  local interactive_shell=0
  [ -t 2 ] && interactive_shell=1

  bw_load_cached_session && return 0

  local bw_status
  bw_status="$(
    bw_run_with_spinner "Checking Bitwarden status..." bw status | jq -r '.status'
  )" || return

  if [ "$bw_status" = "locked" ]; then
    [ -t 0 ] || return
    [ "$interactive_shell" -eq 1 ] && print -u2 -- "Unlocking Bitwarden..."
    export BW_SESSION="$(bw unlock --raw)" || return
    bw_cache_session
  elif [ "$bw_status" = "unauthenticated" ]; then
    [ "$interactive_shell" -eq 1 ] && print -u2 -- "Bitwarden is not logged in. Run 'bw login' first."
    return
  elif [ "$bw_status" != "unlocked" ]; then
    return
  fi

  return 0
}

bw_file_mtime() {
  [ "$#" -eq 1 ] || return
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
}

bw_env_cache_is_fresh() {
  [ -f "$BW_ENV_CACHE_FILE" ] || return 1

  local now
  local modified
  local age
  now="$(date +%s)" || return 1
  modified="$(bw_file_mtime "$BW_ENV_CACHE_FILE")" || return 1
  age=$(( now - modified ))

  [ "$age" -ge 0 ] && [ "$age" -lt "$BW_ENV_CACHE_TTL_SECONDS" ]
}

bw_source_env_cache() {
  [ -f "$BW_ENV_CACHE_FILE" ] || return 1
  source "$BW_ENV_CACHE_FILE"
}

bw_write_env_cache() {
  [ "$#" -eq 1 ] || return

  local items_json="$1"
  local cache_dir
  local temp_file
  cache_dir="${BW_ENV_CACHE_FILE:h}"
  mkdir -p "$cache_dir" || return
  temp_file="$(mktemp "${cache_dir}/bitwarden-env.XXXXXX")" || return

  jq -r '
    def env_value:
      (.login.password // "") as $password
      | if $password != "" then
          $password
        else
          (
            .fields[]?
            | select(((.name // "") | ascii_downcase) == "value")
            | .value
          ) // (.value // empty)
        end;

    [
      .[]
      | {name, value: env_value}
      | select(.name | test("^[A-Za-z_][A-Za-z0-9_]*$"))
      | select(.value != "")
    ] as $items
    | "BW_ENV_CACHE_VARS=(\($items | map(.name | @sh) | join(" ")))",
      ($items[] | "export \(.name)=\(.value | @sh)")
  ' > "$temp_file" <<< "$items_json" || {
    rm -f "$temp_file"
    return 1
  }

  chmod 600 "$temp_file" 2>/dev/null || true
  mv "$temp_file" "$BW_ENV_CACHE_FILE"
}

bw_refresh_env_cache() {
  local force_sync="${1:-0}"
  local interactive_shell=0
  [ -t 2 ] && interactive_shell=1

  bw_ensure_session || return

  if [ "$force_sync" = "1" ]; then
    bw_run_with_spinner "Syncing Bitwarden vault..." bw_run_with_session sync >/dev/null || return
  fi

  local folder_id
  folder_id="$(
    bw_run_with_spinner "Finding Bitwarden folder..." bw_run_with_session list folders --search "$BW_ENV_FOLDER_NAME" \
      | jq -r --arg name "$BW_ENV_FOLDER_NAME" '.[] | select(.name == $name) | .id' \
      | head -n 1
  )" || return

  if [ -z "$folder_id" ]; then
    [ "$interactive_shell" -eq 1 ] && print -u2 -- "Unable to load Bitwarden environment variables: folder '${BW_ENV_FOLDER_NAME}' was not found. Run 'bw-reload' after creating or syncing it."
    return 1
  fi

  local items_json
  items_json="$(
    bw_run_with_spinner "Loading Bitwarden environment variables..." bw_run_with_session list items --folderid "$folder_id"
  )" || return

  bw_write_env_cache "$items_json" || return
  bw_source_env_cache
}

bw_load_env_vars() {
  if bw_env_cache_is_fresh; then
    bw_source_env_cache
    return
  fi

  bw_refresh_env_cache 0
}

bw-reload() {
  if [ "${#BW_ENV_CACHE_VARS[@]}" -gt 0 ]; then
    unset "${BW_ENV_CACHE_VARS[@]}"
  fi

  rm -f "$BW_ENV_CACHE_FILE"
  bw_refresh_env_cache 1
}

bw_load_env_vars

hr() {
  export ANTHROPIC_BASE_URL=http://127.0.0.1:8787
  export OPENAI_BASE_URL=http://127.0.0.1:8787/v1
  headroom proxy --port 8787
}

# Git push function that adds all changes, commits with a message, and pushes to the remote repository
# Example usage: gp "Your commit message"
function gp() {
  git add .
  git commit -m "$1"
  git push
}

# Initialize Oh My Posh if not running in Apple Terminal (which doesn't support it well)
if [ "$TERM_PROGRAM" != "Apple_Terminal" ]; then
  # Host name shown (and colour-coded) in the prompt, so it's easy to tell
  # which machine a shell is on, e.g. local MacBook vs an ssh session.
  export DGP_HOST="$(scutil --get LocalHostName 2>/dev/null || hostname)"
  export POSH_THEME="${${(%):-%x}:A:h}/oh-my-posh-theme.json"
  eval "$(oh-my-posh init zsh)"
fi

eval "$(zoxide init zsh)"

alias j="z"
export PATH="$(npm bin -g):$PATH"
export PATH="$(npm bin -g):$PATH"


# Display command start and end times, and duration for commands that take longer than 5 seconds

autoload -Uz add-zsh-hook

__cmd_start_epoch=0
__cmd_start_time=""
__cmd_interrupted=0
__cmd_threshold=5

__preexec() {
    __cmd_start_epoch=$EPOCHSECONDS
    __cmd_start_time=$(date '+%H:%M:%S')
    __cmd_interrupted=0

    printf "\n▶ Started at %s\n\n" "$__cmd_start_time"
}

__precmd() {
    local exit_code=$?

    [[ $__cmd_start_epoch -eq 0 ]] && return

    local end_time elapsed status

    end_time=$(date '+%H:%M:%S')
    elapsed=$((EPOCHSECONDS - __cmd_start_epoch))

    # Reset state before possibly returning
    local start_time="$__cmd_start_time"
    local interrupted="$__cmd_interrupted"

    __cmd_start_epoch=0
    __cmd_start_time=""
    __cmd_interrupted=0

    (( elapsed < __cmd_threshold )) && return

    if [[ $interrupted -eq 1 || $exit_code -eq 130 ]]; then
        status="Interrupted"
    elif [[ $exit_code -eq 0 ]]; then
        status="Completed"
    else
        status="Failed, exit $exit_code"
    fi

    printf "\n✓ %s — started %s, finished %s, took %ss\n\n" \
        "$status" "$start_time" "$end_time" "$elapsed"
}

TRAPINT() {
    if [[ $__cmd_start_epoch -ne 0 ]]; then
        __cmd_interrupted=1
    fi

    return 130
}

add-zsh-hook preexec __preexec
add-zsh-hook precmd __precmd

# Fix option key word navigation, e.g. option + left/right arrow to move by word
bindkey $'\e[1;3D' backward-word
bindkey $'\e[1;3C' forward-word

source "$HOME/.config/zsh/dev-git-prompt/dev-git-prompt.zsh"