#!/usr/bin/env bash

set -euo pipefail

readonly DEFAULT_ICLOUD_ROOT="$HOME/Library/Mobile Documents/com~apple~CloudDocs"
readonly DEFAULT_BACKUP_ROOT="$DEFAULT_ICLOUD_ROOT/MacBook-Trade-In-Backup/Xcode-Signing"
readonly XCODE_PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
readonly MOBILEDEVICE_PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

usage() {
  cat <<'EOF'
Usage: backup_xcode_signing_assets.sh [backup-root]

Creates a timestamped backup folder in iCloud Drive containing:
  - login-keychain identities exported as a password-protected PKCS#12 file
  - code-signing identity inventory
  - provisioning profiles from the standard Xcode/macOS locations

Arguments:
  backup-root  Optional parent folder for the timestamped backup.
               Default: ~/Library/Mobile Documents/com~apple~CloudDocs/MacBook-Trade-In-Backup/Xcode-Signing

Environment:
  P12_EXPORT_PASSWORD  Optional passphrase for the PKCS#12 export.
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

for command_name in rsync security /usr/libexec/PlistBuddy; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command not found: $command_name" >&2
    exit 1
  fi
done

backup_root="${1:-$DEFAULT_BACKUP_ROOT}"

if [[ ! -d "$DEFAULT_ICLOUD_ROOT" ]]; then
  echo "iCloud Drive does not appear to be available at: $DEFAULT_ICLOUD_ROOT" >&2
  exit 1
fi

read_passphrase() {
  if [[ -n "${P12_EXPORT_PASSWORD:-}" ]]; then
    printf '%s\n' "$P12_EXPORT_PASSWORD"
    return 0
  fi

  local passphrase_one
  local passphrase_two

  read -r -s -p "Enter a passphrase for the PKCS#12 export: " passphrase_one
  echo
  read -r -s -p "Re-enter the passphrase: " passphrase_two
  echo

  if [[ -z "$passphrase_one" ]]; then
    echo "Passphrase cannot be empty." >&2
    exit 1
  fi

  if [[ "$passphrase_one" != "$passphrase_two" ]]; then
    echo "Passphrases did not match." >&2
    exit 1
  fi

  printf '%s\n' "$passphrase_one"
}

copy_profiles() {
  local source_dir="$1"
  local target_label="$2"
  local target_dir="$backup_dir/provisioning-profiles/$target_label"

  if [[ ! -d "$source_dir" ]]; then
    echo "[SKIP] $source_dir does not exist."
    return 0
  fi

  if ! find "$source_dir" -maxdepth 1 -type f -name '*.mobileprovision' | grep -q .; then
    echo "[SKIP] No provisioning profiles found in $source_dir."
    return 0
  fi

  mkdir -p "$target_dir"
  echo "[BACKUP] Provisioning profiles from $source_dir"
  rsync -rltp --include='*.mobileprovision' --exclude='*' "$source_dir/" "$target_dir/"
}

append_profile_inventory() {
  local source_dir="$1"
  local target_label="$2"
  local profile_path

  if [[ ! -d "$source_dir" ]]; then
    return 0
  fi

  while IFS= read -r profile_path; do
    local plist_path
    local profile_file
    local name
    local uuid
    local team_id
    local expiration_date

    plist_path="$(mktemp)"
    if ! security cms -D -i "$profile_path" >"$plist_path" 2>/dev/null; then
      rm -f "$plist_path"
      continue
    fi

    profile_file="$(basename "$profile_path")"
    name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "$plist_path" 2>/dev/null || true)"
    uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$plist_path" 2>/dev/null || true)"
    team_id="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$plist_path" 2>/dev/null || true)"
    expiration_date="$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$plist_path" 2>/dev/null || true)"

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$target_label" \
      "$profile_file" \
      "$uuid" \
      "$name" \
      "$team_id" \
      "$expiration_date" >>"$backup_dir/provisioning-profiles/inventory.tsv"

    rm -f "$plist_path"
  done < <(find "$source_dir" -maxdepth 1 -type f -name '*.mobileprovision' | sort)
}

timestamp="$(date '+%Y-%m-%d_%H-%M-%S')"
backup_dir="$backup_root/$timestamp"
mkdir -p "$backup_dir/provisioning-profiles"

login_keychain="$(security login-keychain | sed 's/^ *//' | tr -d '"')"
if [[ -z "$login_keychain" || ! -f "$login_keychain" ]]; then
  echo "Could not determine the login keychain." >&2
  exit 1
fi

identity_report_path="$backup_dir/codesigning-identities.txt"
identity_report="$(security find-identity -v -p codesigning "$login_keychain" 2>/dev/null || true)"
printf '%s\n' "$identity_report" >"$identity_report_path"

identity_count="$(printf '%s\n' "$identity_report" | awk '/valid identities found/ { print $1 }' | tail -n 1)"
if [[ -z "$identity_count" ]]; then
  identity_count="0"
fi

if [[ "$identity_count" != "0" ]]; then
  export_password="$(read_passphrase)"
  export_path="$backup_dir/signing-identities.p12"

  echo "[BACKUP] Exporting identities from $login_keychain"
  security export \
    -k "$login_keychain" \
    -t identities \
    -f pkcs12 \
    -P "$export_password" \
    -o "$export_path"
else
  echo "[SKIP] No code-signing identities found in $login_keychain."
fi

printf 'source\tfile\tuuid\tname\tteam_id\texpires\n' >"$backup_dir/provisioning-profiles/inventory.tsv"
copy_profiles "$XCODE_PROFILES_DIR" "xcode-userdata"
copy_profiles "$MOBILEDEVICE_PROFILES_DIR" "mobiledevice"

append_profile_inventory "$XCODE_PROFILES_DIR" "xcode-userdata"
append_profile_inventory "$MOBILEDEVICE_PROFILES_DIR" "mobiledevice"

cat >"$backup_dir/README.txt" <<EOF
Backup created: $(date)
Host: $(scutil --get ComputerName 2>/dev/null || hostname)
Login keychain: $login_keychain

Contents:
  - signing-identities.p12 (if code-signing identities were found)
  - codesigning-identities.txt
  - provisioning-profiles/

Restore with:
  bash migration/restore_xcode_signing_assets.sh "$backup_dir"

Notes:
  - The PKCS#12 export uses the passphrase you entered when backing up.
  - This captures certificates/private keys and provisioning profiles, not your Xcode Apple ID session.
EOF

echo
echo "Xcode signing backup complete."
echo "Saved to: $backup_dir"
