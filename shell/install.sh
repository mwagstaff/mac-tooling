#!/bin/bash
#
# Bootstraps mac-tooling on a fresh Mac: installs Homebrew (if needed) and the
# CLI tools the shell config depends on, clones the repo, then runs
# shell/setup.sh to symlink the dotfiles and prompt config into place.
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/mwagstaff/mac-tooling/main/shell/install.sh)"

set -euo pipefail

REPO_URL="https://github.com/mwagstaff/mac-tooling.git"
REPO_DIR="${HOME}/dev/mac-tooling"
BREW_PACKAGES=(zoxide jq bitwarden-cli node)

TABSET_REPO_URL="https://github.com/mwagstaff/iterm2-tab-set.git"
TABSET_DIR="${HOME}/dev/iterm2-tab-set"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "⚠️  Xcode Command Line Tools aren't installed. Run 'xcode-select --install' and re-run this script."
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "==> Installing Homebrew"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [[ -x /usr/local/bin/brew ]]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

echo "==> Installing oh-my-posh"
if ! oh_my_posh_output=$(brew install oh-my-posh 2>&1); then
  echo "$oh_my_posh_output"
  if echo "$oh_my_posh_output" | grep -q "Formulae with the same name from different taps"; then
    echo "==> Existing oh-my-posh is from a different tap; switching to homebrew/core"
    brew uninstall oh-my-posh
    brew install oh-my-posh
  else
    exit 1
  fi
fi

echo "==> Installing required packages: ${BREW_PACKAGES[*]}"
brew install "${BREW_PACKAGES[@]}"

echo "==> Cloning mac-tooling into ${REPO_DIR}"
if [[ -d "${REPO_DIR}/.git" ]]; then
  echo "Repo already present, pulling latest"
  git -C "$REPO_DIR" pull --ff-only
else
  mkdir -p "$(dirname "$REPO_DIR")"
  git clone "$REPO_URL" "$REPO_DIR"
fi

echo "==> Cloning iterm2-tab-set into ${TABSET_DIR}"
if [[ -d "${TABSET_DIR}/.git" ]]; then
  echo "Repo already present, pulling latest"
  git -C "$TABSET_DIR" pull --ff-only
else
  mkdir -p "$(dirname "$TABSET_DIR")"
  git clone "$TABSET_REPO_URL" "$TABSET_DIR"
fi

echo "==> Linking tabset command globally"
(cd "$TABSET_DIR" && npm install && npm link)

echo "==> Running shell setup"
zsh "${REPO_DIR}/shell/setup.sh"

echo "✅ mac-tooling installed. Open a new terminal (or run: exec zsh) to see your prompt."
