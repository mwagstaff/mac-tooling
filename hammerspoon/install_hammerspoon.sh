#!/usr/bin/env bash
set -euo pipefail

DOTFILE_DIR="$HOME/dev/mac-tooling/hammerspoon/config"
HAMMERSPOON_DIR="$HOME/.hammerspoon"

# Install Hammerspoon if not already installed
if ! brew list --cask hammerspoon &>/dev/null; then
    echo "Installing Hammerspoon..."
    brew install --cask hammerspoon
else
    echo "Hammerspoon already installed, skipping."
fi

# Remove existing .hammerspoon dir/symlink and replace with symlink
if [ -L "$HAMMERSPOON_DIR" ]; then
    echo "Removing existing symlink at $HAMMERSPOON_DIR"
    rm "$HAMMERSPOON_DIR"
elif [ -d "$HAMMERSPOON_DIR" ]; then
    echo "Removing existing directory at $HAMMERSPOON_DIR"
    rm -rf "$HAMMERSPOON_DIR"
fi

echo "Creating symlink: $HAMMERSPOON_DIR -> $DOTFILE_DIR"
ln -s "$DOTFILE_DIR" "$HAMMERSPOON_DIR"

echo "Done."
