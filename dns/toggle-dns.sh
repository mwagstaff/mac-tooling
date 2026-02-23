#!/bin/zsh
#
# toggle-dns.sh
# Toggles between automatic (DHCP) and manual DNS (8.8.8.8 / 1.1.1.1)
#
# Usage:
#   toggle-dns.sh            # Toggle current state
#   toggle-dns.sh --enable   # Force manual DNS on
#   toggle-dns.sh --disable  # Force manual DNS off (automatic/DHCP)
#

MANUAL_DNS=(8.8.8.8 1.1.1.1)

# ── Argument parsing ──────────────────────────────────────────────────────────
MODE="toggle"   # default
case "$1" in
  --enable)   MODE="enable"  ;;
  --disable)  MODE="disable" ;;
  "")                        ;;
  *)
    echo "Usage: $0 [--enable|--disable]" >&2
    exit 1
    ;;
esac

# ── Helpers ───────────────────────────────────────────────────────────────────
get_active_service() {
  local iface
  iface=$(route get default 2>/dev/null | awk '/interface:/ { print $2 }')
  if [[ -z "$iface" ]]; then
    echo "Error: could not determine active network interface." >&2
    exit 1
  fi

  # Map interface device name → network service name
  networksetup -listallhardwareports \
    | awk -v iface="$iface" '
        /Hardware Port:/ { port = substr($0, index($0,$3)) }
        /Device: / && $2 == iface { print port }
      '
}

is_manual() {
  networksetup -getdnsservers "$1" 2>/dev/null | grep -q "^8\.8\.8\.8"
}

enable_manual() {
  networksetup -setdnsservers "$SERVICE" "${MANUAL_DNS[@]}"
  echo "DNS set to manual (${MANUAL_DNS[*]}) on '$SERVICE'."
}

disable_manual() {
  networksetup -setdnsservers "$SERVICE" "Empty"
  echo "DNS set to automatic (DHCP) on '$SERVICE'."
}

# ── Main ──────────────────────────────────────────────────────────────────────
SERVICE=$(get_active_service)

if [[ -z "$SERVICE" ]]; then
  echo "Error: could not find a network service for the active interface." >&2
  exit 1
fi

case "$MODE" in
  enable)
    if is_manual "$SERVICE"; then
      echo "DNS is already set to manual on '$SERVICE'. Nothing to do."
    else
      enable_manual
    fi
    ;;
  disable)
    if is_manual "$SERVICE"; then
      disable_manual
    else
      echo "DNS is already set to automatic on '$SERVICE'. Nothing to do."
    fi
    ;;
  toggle)
    if is_manual "$SERVICE"; then
      disable_manual
    else
      enable_manual
    fi
    ;;
esac

# ── Status ────────────────────────────────────────────────────────────────────
echo ""
echo "Current DNS servers on '$SERVICE':"
networksetup -getdnsservers "$SERVICE"
