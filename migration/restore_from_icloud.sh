#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: restore_from_icloud.sh [--force] <backup-dir>

Restores the following items from a backup folder into $HOME:
  - .ssh
  - .zshrc
  - .gitconfig
  - .codex
  - .claude

Options:
  --force   Remove an existing destination before restoring.
EOF
}

force="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      force="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS only." >&2
  exit 1
fi

if ! command -v rsync >/dev/null 2>&1; then
  echo "rsync is required but was not found." >&2
  exit 1
fi

backup_dir="${1%/}"

if [[ ! -d "$backup_dir" ]]; then
  echo "Backup directory not found: $backup_dir" >&2
  exit 1
fi

restore_item() {
  local source_name="$1"
  local destination_path="$2"
  local source_path="$backup_dir/$source_name"

  if [[ ! -e "$source_path" ]]; then
    echo "[SKIP] $source_path does not exist in backup."
    return 0
  fi

  if [[ -e "$destination_path" ]]; then
    if [[ "$force" != "true" ]]; then
      echo "Destination already exists: $destination_path" >&2
      echo "Rerun with --force to replace it." >&2
      exit 1
    fi

    echo "[REMOVE] $destination_path"
    rm -rf "$destination_path"
  fi

  echo "[RESTORE] $source_path -> $destination_path"
  if [[ -d "$source_path" ]]; then
    rsync -a "$source_path/" "$destination_path/"
  else
    rsync -a "$source_path" "$destination_path"
  fi
}

restore_item ".ssh" "$HOME/.ssh"
restore_item ".zshrc" "$HOME/.zshrc"
restore_item ".gitconfig" "$HOME/.gitconfig"
restore_item ".codex" "$HOME/.codex"
restore_item ".claude" "$HOME/.claude"

echo
echo "Restore complete."
