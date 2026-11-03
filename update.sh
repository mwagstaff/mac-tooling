#!/bin/bash
#
# Updates all tooling on this Mac to the latest: re-runs shell/install.sh
# (pulls mac-tooling and iterm2-tab-set, upgrades the Homebrew CLI tools,
# re-links the shell config), links and restarts the Hammerspoon config if
# Hammerspoon is installed, then clones or pulls server-tooling.
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/mwagstaff/mac-tooling/main/update.sh)"

set -euo pipefail

SERVER_TOOLING_REPO_URL="https://github.com/mwagstaff/server-tooling.git"
SERVER_TOOLING_DIR="${HOME}/dev/server-tooling"

echo "==> Updating mac-tooling, shell config and CLI tools"
bash -c "$(curl -fsSL https://raw.githubusercontent.com/mwagstaff/mac-tooling/main/shell/install.sh)"

if [[ -d /Applications/Hammerspoon.app ]]; then
  echo "==> Linking and reloading Hammerspoon config"
  bash "${HOME}/dev/mac-tooling/hammerspoon/setup.sh"
fi

echo "==> Updating server-tooling in ${SERVER_TOOLING_DIR}"
if [[ -d "${SERVER_TOOLING_DIR}/.git" ]]; then
  git -C "$SERVER_TOOLING_DIR" pull --ff-only
else
  mkdir -p "$(dirname "$SERVER_TOOLING_DIR")"
  git clone "$SERVER_TOOLING_REPO_URL" "$SERVER_TOOLING_DIR"
fi

echo "✅ All tooling up to date. Open a new terminal (or run: exec zsh) to pick up shell changes."
