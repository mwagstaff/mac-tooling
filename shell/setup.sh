#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"

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

typeset -A DIRS
DIRS=(
  ".config/zsh/dev-git-prompt" "${SCRIPT_DIR}/dev-git-prompt"
)

for target in "${(@k)DIRS}"; do
  source_dir="${DIRS[$target]}"
  target_dir="${HOME}/${target}"

  if [[ ! -d "$source_dir" ]]; then
    echo "❌ Source directory missing: $source_dir"
    continue
  fi

  mkdir -p "${target_dir:h}"

  if [[ -L "$target_dir" ]]; then
    current_link="$(readlink "$target_dir")"

    if [[ "$current_link" == "$source_dir" ]]; then
      echo "✅ Symlink already correct: $target_dir -> $source_dir"
    else
      echo "🔄 Updating symlink: $target_dir"
      rm "$target_dir"
      ln -s "$source_dir" "$target_dir"
    fi

  elif [[ -e "$target_dir" ]]; then
    backup="${target_dir}.backup.$(date +%Y%m%d-%H%M%S)"
    echo "⚠️ Existing directory detected, backing up to: $backup"
    mv "$target_dir" "$backup"
    ln -s "$source_dir" "$target_dir"

  else
    echo "➕ Creating symlink: $target_dir -> $source_dir"
    ln -s "$source_dir" "$target_dir"
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