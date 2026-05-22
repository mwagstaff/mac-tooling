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

# Git
git config --global user.name "Mike Wagstaff"
git config --global user.email "mike.wagstaff@gmail.com"

# Created by `pipx` on 2024-05-06 18:12:03
export PATH="$PATH:/Users/${USER}/.local/bin"

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

# Bitwarden items to load as environment variables.
# Use ENV_VAR when the Bitwarden item has the same name, or ENV_VAR=ITEM_NAME otherwise.
BW_ENV_ITEMS=(
  "GRAFANA_PASSWORD=${GRAFANA_LOGIN_BW_ITEM:-GRAFANA_LOGIN}"
  "OPENAI_API_KEY_KIDSPLORERS"
  "ANTHROPIC_API_KEY_KIDSPLORERS"
)

BW_SESSION_CACHE_FILE="${BW_SESSION_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-tooling/bitwarden-session}"

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

bw_export_item_as_env_var() {
  [ "$#" -eq 2 ] || return

  local env_var="$1"
  local item_name="$2"

  bw_require_command bw || return
  bw_require_command jq || return

  local interactive_shell=0
  [ -t 2 ] && interactive_shell=1

  bw_load_cached_session

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

  local env_value
  env_value="$(
    bw_run_with_spinner "Fetching ${item_name} from Bitwarden..." bw get item "$item_name" | jq -r '
      (.login.password // "") as $password
      | if $password != "" then
          $password
        else
          .value // (
            .fields[]?
            | select(((.name // "") | ascii_downcase) == "value")
            | .value
          ) // empty
        end
    '
  )" || return
  if [ -z "$env_value" ]; then
    [ "$interactive_shell" -eq 1 ] && print -u2 -- "Unable to set ${env_var} environment variable: no login password or value field found in ${item_name}."
    return
  fi

  unset "${env_var}"
  export "${env_var}=$env_value"
}

bw_export_configured_items() {
  local entry
  local env_var
  local item_name

  for entry in "${BW_ENV_ITEMS[@]}"; do
    env_var="${entry%%=*}"
    if [ "$entry" = "$env_var" ]; then
      item_name="$env_var"
    else
      item_name="${entry#*=}"
    fi

    [ -n "$env_var" ] || continue
    [ -n "$item_name" ] || continue
    bw_export_item_as_env_var "$env_var" "$item_name"
  done
}

bw_export_configured_items

# Initialize Oh My Posh if not running in Apple Terminal (which doesn't support it well)
if [ "$TERM_PROGRAM" != "Apple_Terminal" ]; then
  eval "$(oh-my-posh init zsh)"
fi

eval "$(zoxide init zsh)"

alias j="z"
