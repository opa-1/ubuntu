#!/usr/bin/env bash
#
# setup_swap.sh
# Updates the system and configures a 16G swapfile with swappiness=20.
# Safe to re-run: skips steps that are already done.
#
# Usage: sudo ./setup_swap.sh

set -euo pipefail

DEFAULT_SWAP_FILE="/swapfile"
SWAPPINESS=20

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root (use: sudo ./setup_swap.sh)" >&2
  exit 1
fi

LEGACY_SWAP_FILE="/swap.img"
SWAP_FILE="$DEFAULT_SWAP_FILE"

# If Ubuntu's default /swap.img exists, remove it — we standardize on /swapfile
if [[ -f "$LEGACY_SWAP_FILE" ]]; then
  echo "==> Found legacy swapfile ${LEGACY_SWAP_FILE}, removing it (switching to ${SWAP_FILE})"

  if swapon --show | grep -q "^${LEGACY_SWAP_FILE}"; then
    swapoff "$LEGACY_SWAP_FILE"
  fi
  rm -f "$LEGACY_SWAP_FILE"

  # Remove any fstab entry pointing at the legacy swapfile
  if grep -q "^${LEGACY_SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null; then
    sed -i "\|^${LEGACY_SWAP_FILE}[[:space:]]|d" /etc/fstab
  fi
fi

if [[ -f "$SWAP_FILE" ]]; then
  echo "==> Found existing swapfile: ${SWAP_FILE}"
  CURRENT_SIZE="$(du -h "$SWAP_FILE" | cut -f1)"
  echo "    Current size: ${CURRENT_SIZE}"
else
  echo "==> No existing swapfile detected. A new one will be created at ${SWAP_FILE}"
fi

# Prompt user for swap size (in GB)
read -rp "Enter desired swap size in GB (e.g. 16): " SWAP_SIZE_GB
if ! [[ "$SWAP_SIZE_GB" =~ ^[0-9]+$ ]] || [[ "$SWAP_SIZE_GB" -le 0 ]]; then
  echo "Invalid swap size: '${SWAP_SIZE_GB}'. Please enter a positive whole number." >&2
  exit 1
fi
SWAP_SIZE="${SWAP_SIZE_GB}G"

echo "==> Updating package lists"
apt update

echo "==> Upgrading installed packages"
apt upgrade -y

echo "==> Removing unused packages"
apt autoremove -y

echo "==> Configuring ${SWAP_SIZE} swapfile at ${SWAP_FILE}"
if [[ -f "$SWAP_FILE" ]]; then
  echo "    Existing swapfile found, resizing to ${SWAP_SIZE}"

  # Turn off swap if currently active
  if swapon --show | grep -q "^${SWAP_FILE}"; then
    swapoff "$SWAP_FILE"
  fi

  rm -f "$SWAP_FILE"

  if ! fallocate -l "$SWAP_SIZE" "$SWAP_FILE"; then
    echo "ERROR: fallocate failed to create ${SWAP_FILE}. Stopping." >&2
    exit 1
  fi
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
else
  if ! fallocate -l "$SWAP_SIZE" "$SWAP_FILE"; then
    echo "ERROR: fallocate failed to create ${SWAP_FILE}. Stopping." >&2
    exit 1
  fi
  chmod 600 "$SWAP_FILE"
  mkswap "$SWAP_FILE"
fi

swapon "$SWAP_FILE"

echo "==> Current swap status"
swapon --show
free -h

echo "==> Ensuring fstab entry exists"
if grep -q "^${SWAP_FILE}[[:space:]]" /etc/fstab 2>/dev/null; then
  echo "    fstab entry already present, skipping."
else
  echo "${SWAP_FILE} none swap sw 0 0" | tee -a /etc/fstab
fi

echo "==> Setting swappiness to ${SWAPPINESS} (runtime)"
sysctl "vm.swappiness=${SWAPPINESS}"
sysctl vm.swappiness

echo "==> Ensuring swappiness persists across reboots"
if grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
  echo "    Updating existing vm.swappiness entry in /etc/sysctl.conf"
  sed -i "s/^vm.swappiness.*/vm.swappiness=${SWAPPINESS}/" /etc/sysctl.conf
else
  echo "vm.swappiness=${SWAPPINESS}" | tee -a /etc/sysctl.conf
fi

echo "==> Applying sysctl settings"
sysctl -p

echo "==> Done."
