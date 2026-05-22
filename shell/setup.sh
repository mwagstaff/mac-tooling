#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="/Users/mwagstaff/dev/mac-tooling/shell"

typeset -A FILES
FILES=(
  ".zshenv" "${SCRIPT_DIR}/.zshenv"
  ".zshrc"  "${SCRIPT_DIR}/.zshrc"
)

echo "Setting up shell config symlinks..."

for target in "${(@k)FILES}"; do
  source_file="${FILES[$target]}"
  target_file="${HOME}/${target}"

  if [[ ! -f "$source_file" ]]; then
    echo "❌ Source file missing: $source_file"
    continue
  fi

  if [[ -L "$target_file" ]]; then
    current_link="$(readlink "$target_file")"

    if [[ "$current_link" == "$source_file" ]]; then
      echo "✅ Symlink already correct: $target_file -> $source_file"
    else
      echo "🔄 Updating symlink: $target_file"
      rm "$target_file"
      ln -s "$source_file" "$target_file"
    fi

  elif [[ -e "$target_file" ]]; then
    backup="${target_file}.backup.$(date +%Y%m%d-%H%M%S)"
    echo "⚠️ Existing file detected, backing up to: $backup"
    mv "$target_file" "$backup"
    ln -s "$source_file" "$target_file"

  else
    echo "➕ Creating symlink: $target_file -> $source_file"
    ln -s "$source_file" "$target_file"
  fi
done

echo ""
echo "Reloading shell configuration..."

# Temporarily disable nounset so .zshrc can safely reference unset arrays/vars
set +u
source "${HOME}/.zshenv"
source "${HOME}/.zshrc"
set -u

echo "✅ Shell configuration reloaded"