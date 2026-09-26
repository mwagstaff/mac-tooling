#!/usr/bin/env bash
set -euo pipefail

SOURCE_INIT="/Users/mwagstaff/dev/mac-tooling/hammerspoon/config/init.lua"
HAMMERSPOON_DIR="${HOME}/.hammerspoon"
TARGET_INIT="${HAMMERSPOON_DIR}/init.lua"

echo "Setting up Hammerspoon config..."

if [[ ! -f "$SOURCE_INIT" ]]; then
  echo "Source file missing: $SOURCE_INIT"
  exit 1
fi

if [[ -L "$HAMMERSPOON_DIR" ]]; then
  link_target="$(readlink "$HAMMERSPOON_DIR")"
  if [[ "$link_target" = /* ]]; then
    resolved_dir="$link_target"
  else
    resolved_dir="$(cd "$(dirname "$HAMMERSPOON_DIR")" && pwd -P)/$link_target"
  fi

  resolved_dir="$(cd "$resolved_dir" && pwd -P)"
  source_dir="$(cd "$(dirname "$SOURCE_INIT")" && pwd -P)"

  if [[ "$resolved_dir" == "$source_dir" ]]; then
    echo "Existing Hammerspoon directory symlink already points at config: $HAMMERSPOON_DIR -> $SOURCE_INIT"
  else
    backup="${HAMMERSPOON_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
    echo "Backing up existing Hammerspoon directory symlink to: $backup"
    mv "$HAMMERSPOON_DIR" "$backup"
    mkdir -p "$HAMMERSPOON_DIR"
  fi
else
  if [[ -e "$HAMMERSPOON_DIR" && ! -d "$HAMMERSPOON_DIR" ]]; then
    backup="${HAMMERSPOON_DIR}.backup.$(date +%Y%m%d-%H%M%S)"
    echo "Backing up existing Hammerspoon path to: $backup"
    mv "$HAMMERSPOON_DIR" "$backup"
  fi

  mkdir -p "$HAMMERSPOON_DIR"
fi

if [[ -L "$TARGET_INIT" ]]; then
  current_link="$(readlink "$TARGET_INIT")"

  if [[ "$current_link" == "$SOURCE_INIT" ]]; then
    echo "Symlink already correct: $TARGET_INIT -> $SOURCE_INIT"
  else
    echo "Updating symlink: $TARGET_INIT"
    rm "$TARGET_INIT"
    ln -s "$SOURCE_INIT" "$TARGET_INIT"
  fi
elif [[ -e "$TARGET_INIT" ]]; then
  target_realpath="$(cd "$(dirname "$TARGET_INIT")" && pwd -P)/$(basename "$TARGET_INIT")"
  source_realpath="$(cd "$(dirname "$SOURCE_INIT")" && pwd -P)/$(basename "$SOURCE_INIT")"

  if [[ "$target_realpath" == "$source_realpath" ]]; then
    echo "Existing Hammerspoon path already resolves to source config: $TARGET_INIT -> $SOURCE_INIT"
  else
    backup="${TARGET_INIT}.backup.$(date +%Y%m%d-%H%M%S)"
    echo "Backing up existing init.lua to: $backup"
    mv "$TARGET_INIT" "$backup"
    ln -s "$SOURCE_INIT" "$TARGET_INIT"
  fi
else
  echo "Creating symlink: $TARGET_INIT -> $SOURCE_INIT"
  ln -s "$SOURCE_INIT" "$TARGET_INIT"
fi

# Device Hub doesn't expose its menu bar to Accessibility, so init.lua
# triggers Controls -> Screenshot via this keyboard shortcut instead.
# Device Hub is sandboxed (its own preferences aren't writable without sudo,
# and it isn't listed in System Settings' App Shortcuts), so the shortcut is
# set globally; it applies to any app with a menu item titled "Screenshot".
echo "Assigning Cmd-Opt-Ctrl-S to the Screenshot menu item..."
defaults write -g NSUserKeyEquivalents -dict-add "Screenshot" "@~^s"

echo "Restarting Hammerspoon..."

if pgrep -x "Hammerspoon" >/dev/null; then
  osascript -e 'tell application "Hammerspoon" to quit' >/dev/null 2>&1 || true

  for _ in {1..20}; do
    if ! pgrep -x "Hammerspoon" >/dev/null; then
      break
    fi

    sleep 0.25
  done
fi

open -a "Hammerspoon"

echo "Done."
