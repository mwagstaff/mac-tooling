#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_ICLOUD_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
readonly DEFAULT_BACKUP_ROOT="$DEFAULT_ICLOUD_ROOT/MacBook-Trade-In-Backup"

usage() {
  cat <<'EOF'
Usage: backup_to_icloud.sh [backup-root]

Creates a timestamped backup folder inside iCloud Drive and copies:
  - ~/.ssh
  - ~/.zshrc
  - ~/.gitconfig
  - ~/.codex
  - ~/.claude

Arguments:
  backup-root  Optional parent folder to create the timestamped backup in.
               Default: ~/Library/Mobile Documents/com~apple~CloudDocs/MacBook-Trade-In-Backup
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS only." >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required but was not found." >&2
  exit 1
fi

backup_root="${1:-$DEFAULT_BACKUP_ROOT}"

if [[ ! -d "$DEFAULT_ICLOUD_ROOT" ]]; then
  echo "iCloud Drive does not appear to be available at: $DEFAULT_ICLOUD_ROOT" >&2
  exit 1
fi

timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
backup_dir="$backup_root/$timestamp"

mkdir -p "$backup_dir"

copy_item() {
  local source_path="$1"
  local target_name="$2"

  if [[ ! -e "$source_path" ]]; then
    echo "[SKIP] $source_path does not exist."
    return 0
  fi

  echo "[BACKUP] $source_path -> $backup_dir/$target_name"
  if [[ -d "$source_path" ]]; then
    rsync -a "$source_path/" "$backup_dir/$target_name/"
  else
    rsync -a "$source_path" "$backup_dir/$target_name"
  fi
}

copy_item "$HOME/.ssh" ".ssh"
copy_item "$HOME/.zshrc" ".zshrc"
copy_item "$HOME/.gitconfig" ".gitconfig"
copy_item "$HOME/.codex" ".codex"
copy_item "$HOME/.claude" ".claude"

cat >"$backup_dir/README.txt" <<EOF
Backup created: $(date)
Host: $(scutil --get ComputerName 2>/dev/null || hostname)
Source home: $HOME

Restore with:
  bash migration/restore_from_icloud.sh "$backup_dir"
EOF

echo
echo "Backup complete."
echo "Saved to: $backup_dir"
