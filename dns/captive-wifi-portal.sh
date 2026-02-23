#!/bin/zsh
#
# captive-wifi-portal.sh
# Temporarily removes manual DNS entries so a captive WiFi portal can
# authenticate, waits for the portal window to complete, then restores them.
#
# Usage: sudo ./captive-wifi-portal.sh [wait_seconds]
#   wait_seconds  How long to keep DNS on automatic (default: 120)
#

WAIT="${1:-120}"
SCRIPT_DIR="${0:A:h}"
TOGGLE="$SCRIPT_DIR/toggle-dns.sh"

if [[ ! -x "$TOGGLE" ]]; then
  echo "Error: toggle-dns.sh not found or not executable at '$TOGGLE'" >&2
  exit 1
fi

# ── Validate wait time ────────────────────────────────────────────────────────
if ! [[ "$WAIT" =~ ^[0-9]+$ ]] || (( WAIT < 1 )); then
  echo "Error: wait_seconds must be a positive integer." >&2
  exit 1
fi

# ── Disable manual DNS ────────────────────────────────────────────────────────
echo "==> Disabling manual DNS for captive portal..."
"$TOGGLE" --disable
echo ""

# ── Wait ──────────────────────────────────────────────────────────────────────
echo "==> Waiting ${WAIT}s for captive portal authentication..."
echo "    (press Ctrl+C to restore DNS immediately)"

# Restore DNS on Ctrl+C as well
trap '
  echo ""
  echo "==> Interrupted — restoring manual DNS early..."
  "$TOGGLE" --enable
  exit 0
' INT TERM

# Countdown so the user can see progress
for (( i = WAIT; i > 0; i-- )); do
  printf "\r    %3ds remaining..." "$i"
  sleep 1
done
printf "\r%-40s\n" "    Done waiting."

# ── Re-enable manual DNS ──────────────────────────────────────────────────────
echo ""
echo "==> Restoring manual DNS..."
"$TOGGLE" --enable
