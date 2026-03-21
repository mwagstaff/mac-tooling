#!/usr/bin/env bash

set -euo pipefail

readonly XCODE_PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
readonly MOBILEDEVICE_PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

usage() {
  cat <<'EOF'
Usage: restore_xcode_signing_assets.sh <backup-dir>

Restores:
  - signing identities from signing-identities.p12 into the login keychain
  - provisioning profiles back into the standard Xcode/macOS locations

Environment:
  P12_IMPORT_PASSWORD  Optional passphrase for the PKCS#12 import.
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

if [[ $# -ne 1 ]]; then
  usage >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is for macOS only." >&2
  exit 1
fi

for command_name in rsync security; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

backup_dir="${1%/}"
if [[ ! -d "$backup_dir" ]]; then
  echo "Backup directory not found: $backup_dir" >&2
  exit 1
fi

read_passphrase() {
  if [[ -n "${P12_IMPORT_PASSWORD:-}" ]]; then
    printf '%s\n' "$P12_IMPORT_PASSWORD"
    return 0
  fi

  local passphrase
  read -r -s -p "Enter the passphrase for signing-identities.p12: " passphrase
  echo

  if [[ -z "$passphrase" ]]; then
    echo "Passphrase cannot be empty." >&2
    exit 1
  fi

  printf '%s\n' "$passphrase"
}

restore_profiles() {
  local source_dir="$1"
  local destination_dir="$2"

  if [[ ! -d "$source_dir" ]]; then
    echo "[SKIP] $source_dir does not exist in the backup."
    return 0
  fi

  mkdir -p "$destination_dir"
  echo "[RESTORE] Provisioning profiles -> $destination_dir"
  rsync -rltp --include='*.mobileprovision' --exclude='*' "$source_dir/" "$destination_dir/"
}

login_keychain="$(security login-keychain | sed 's/^ *//' | tr -d '"')"
if [[ -z "$login_keychain" || ! -f "$login_keychain" ]]; then
  echo "Could not determine the login keychain." >&2
  exit 1
fi

p12_path="$backup_dir/signing-identities.p12"
if [[ -f "$p12_path" ]]; then
  import_targets=(
    -T /usr/bin/codesign
    -T /usr/bin/security
    -T /usr/bin/productbuild
    -T /usr/bin/productsign
  )

  if [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
    import_targets+=(-T /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild)
  fi

  import_password="$(read_passphrase)"
  echo "[RESTORE] Importing signing identities into $login_keychain"
  security import \
    "$p12_path" \
    -k "$login_keychain" \
    -f pkcs12 \
    -P "$import_password" \
    "${import_targets[@]}"
else
  echo "[SKIP] No signing-identities.p12 found in the backup."
fi

restore_profiles "$backup_dir/provisioning-profiles/xcode-userdata" "$XCODE_PROFILES_DIR"
restore_profiles "$backup_dir/provisioning-profiles/mobiledevice" "$MOBILEDEVICE_PROFILES_DIR"

echo
echo "Xcode signing restore complete."
echo "If Xcode still shows missing accounts, sign back in via Xcode Settings > Accounts."
