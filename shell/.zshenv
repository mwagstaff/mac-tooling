BW_SESSION_CACHE_FILE="${BW_SESSION_CACHE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/server-tooling/bitwarden-session}"
export BW_SESSION_CACHE_FILE

if [ -z "${BW_SESSION:-}" ] && [ -r "$BW_SESSION_CACHE_FILE" ]; then
  IFS= read -r BW_SESSION < "$BW_SESSION_CACHE_FILE"
  export BW_SESSION
fi
