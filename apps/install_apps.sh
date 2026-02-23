#!/usr/bin/env bash

set -u -o pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS only."
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required but was not found."
  echo "Install it first: https://brew.sh"
  exit 1
fi

APP_DIRS=("/Applications" "$HOME/Applications")
INSTALLED=()
ALREADY_PRESENT=()
FAILED=()
MANUAL_ACTION=()
MAS_READY="unknown"

app_exists() {
  local bundle_name="$1"

  if [[ -z "$bundle_name" ]]; then
    return 1
  fi

  local app_dir
  for app_dir in "${APP_DIRS[@]}"; do
    if [[ -d "$app_dir/$bundle_name.app" ]]; then
      return 0
    fi
  done

  return 1
}

is_installed() {
  local bundle_name="$1"
  local cmd_name="$2"

  if app_exists "$bundle_name"; then
    return 0
  fi

  if [[ -n "$cmd_name" ]] && command -v "$cmd_name" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

ensure_mas() {
  if [[ "$MAS_READY" == "yes" ]]; then
    return 0
  fi

  if [[ "$MAS_READY" == "no" ]]; then
    return 1
  fi

  if ! command -v mas >/dev/null 2>&1; then
    echo "Installing mas (required for App Store apps)..."
    if ! brew install mas; then
      MAS_READY="no"
      FAILED+=("mas")
      return 1
    fi
  fi

  if ! mas account >/dev/null 2>&1; then
    MAS_READY="no"
    MANUAL_ACTION+=("Sign in to the Mac App Store, then rerun this script for Amphetamine/Xcode.")
    return 1
  fi

  MAS_READY="yes"
  return 0
}

install_cask_app() {
  local display_name="$1"
  local cask_token="$2"
  local bundle_name="$3"
  local cmd_name="$4"

  if is_installed "$bundle_name" "$cmd_name"; then
    echo "[SKIP] $display_name is already installed."
    ALREADY_PRESENT+=("$display_name")
    return 0
  fi

  echo "[INSTALL] $display_name via Homebrew cask ($cask_token)..."
  if brew install --cask "$cask_token"; then
    INSTALLED+=("$display_name")
  else
    echo "[FAIL] Failed to install $display_name via Homebrew."
    FAILED+=("$display_name")
  fi
}

install_app_store_app() {
  local display_name="$1"
  local app_store_id="$2"
  local bundle_name="$3"

  if is_installed "$bundle_name" ""; then
    echo "[SKIP] $display_name is already installed."
    ALREADY_PRESENT+=("$display_name")
    return 0
  fi

  if ! ensure_mas; then
    echo "[MANUAL] Could not auto-install $display_name from the App Store."
    MANUAL_ACTION+=("Install $display_name from the App Store (id: $app_store_id).")
    return 1
  fi

  echo "[INSTALL] $display_name via Mac App Store (id: $app_store_id)..."
  if mas install "$app_store_id"; then
    INSTALLED+=("$display_name")
  else
    echo "[FAIL] Failed to install $display_name from the App Store."
    FAILED+=("$display_name")
  fi
}

CASK_APPS=(
  "Bitwarden|bitwarden|Bitwarden|"
  "ChatGPT|chatgpt|ChatGPT|"
  "Citrix Workspace|citrix-workspace|Citrix Workspace|"
  "Claude|claude|Claude|"
  "Codex|codex||codex"
  "Go2Shell|go2shell|Go2Shell|"
  "Google Chrome|google-chrome|Google Chrome|"
  "GrandPerspective|grandperspective|GrandPerspective|"
  "Hammerspoon|hammerspoon|Hammerspoon|"
  "iTerm|iterm2|iTerm|"
  "Microsoft Outlook|microsoft-outlook|Microsoft Outlook|"
  "NordVPN|nordvpn|NordVPN|"
  "Scroll Reverser|scroll-reverser|Scroll Reverser|"
  "Signal|signal|Signal|"
  "Tailscale|tailscale|Tailscale|"
  "Visual Studio Code|visual-studio-code|Visual Studio Code|"
  "WhatsApp|whatsapp|WhatsApp|"
)

APP_STORE_APPS=(
  "Amphetamine|937984704|Amphetamine"
  "Xcode|497799835|Xcode"
)

for app in "${CASK_APPS[@]}"; do
  IFS='|' read -r display_name cask_token bundle_name cmd_name <<<"$app"
  install_cask_app "$display_name" "$cask_token" "$bundle_name" "$cmd_name"
done

for app in "${APP_STORE_APPS[@]}"; do
  IFS='|' read -r display_name app_store_id bundle_name <<<"$app"
  install_app_store_app "$display_name" "$app_store_id" "$bundle_name"
done

echo
echo "Install summary"
echo "---------------"
echo "Installed: ${#INSTALLED[@]}"
echo "Already present: ${#ALREADY_PRESENT[@]}"
echo "Failed: ${#FAILED[@]}"
echo "Manual action needed: ${#MANUAL_ACTION[@]}"

if (( ${#FAILED[@]} > 0 )); then
  echo
  echo "Failed installs:"
  printf ' - %s\n' "${FAILED[@]}"
fi

if (( ${#MANUAL_ACTION[@]} > 0 )); then
  echo
  echo "Manual steps:"
  printf ' - %s\n' "${MANUAL_ACTION[@]}"
fi
