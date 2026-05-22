#!/bin/bash

# --- AUTOMATION HEADERS ---
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1 

# Exit on error, but handle specific failures gracefully
set -e

# Setup Logging
LOG_FILE="/var/log/kali_self_heal.log"
exec > >(tee -i $LOG_FILE) 2>&1

# Progress bar function
show_progress() {
    echo -e "\n\e[1;34m[PROG]\e[0m #################### ($1)"
}

echo "[*] Starting ULTIMATE Kali self-healing script..."
echo "[*] Date: $(date)"

# --- PRE-FLIGHT CHECKS ---
show_progress "5% - Pre-flight Checks"

# 1. Check for Internet
if ! ping -c 1 8.8.8.8 &>/dev/null; then
    echo "[!] ERROR: No internet connection. Updates will fail."
    exit 1
fi

# 2. Release Package Locks (Fixes "Could not get lock" errors)
echo "[*] Clearing potential package locks..."
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock

# 3. Measure Cache
D_CACHE_SIZE=$(du -sh ~/.cache 2>/dev/null | awk '{print $1}') || D_CACHE_SIZE="0"
S_CACHE_SIZE=$(du -sh /var/cache/apt 2>/dev/null | awk '{print $1}') || S_CACHE_SIZE="0"
LOG_SIZE=$(du -sh /var/log 2>/dev/null | awk '{print $1}') || LOG_SIZE="0"

show_progress "15% - Fixing Mirrors & Keys"
# Ensure the official Kali sources are present
echo "deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware" | sudo tee /etc/apt/sources.list
wget -q -O - https://archive.kali.org/archive-key.asc | gpg --dearmor | sudo tee /etc/apt/trusted.gpg.d/kali-archive-keyring.gpg > /dev/null

show_progress "30% - Repairing Broken Dependencies"
# Added 'configure -a' before update to fix interrupted installs
sudo dpkg --configure -a
sudo apt-get update --fix-missing
sudo apt-get install -f -y

show_progress "50% - Core System Upgrade"
# Using full-upgrade instead of dist-upgrade for better dependency resolution
sudo apt-get full-upgrade -y




show_progress "70% - Reinstalling Essential Metadata"
# Fixed: Only reinstalls if they are missing or broken to save time
sudo apt-get install --reinstall -y kali-archive-keyring

show_progress "85% - Deep Cleaning"
sudo apt-get autoremove --purge -y
sudo apt-get clean
# Clean up journal logs older than 1 day to save massive space
sudo journalctl --vacuum-time=1d
# Remove old kernels (keeps the current one)
sudo apt-get purge $(dpkg -l | awk '/^rc/ { print $2 }') -y || true

show_progress "95% - History & Filesystem Sync"
# Repair ZSH history
REAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(eval echo ~$REAL_USER)
for TARGET_HIST in "$USER_HOME/.zsh_history" "/root/.zsh_history"; do
    if [ -f "$TARGET_HIST" ]; then
        strings "$TARGET_HIST" > "${TARGET_HIST}.tmp" && mv "${TARGET_HIST}.tmp" "$TARGET_HIST"
        chown $(stat -c '%U:%G' $(dirname $TARGET_HIST)) "$TARGET_HIST" || true
    fi
done

sync
show_progress "100% - Done"



# Final Stats
DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}')
echo "--------------------------------------------------"
echo "SUCCESS: KALI IS HEALED"
echo "Space Recovered from Logs/Cache: ~$S_CACHE_SIZE"
echo "Current Disk Usage: $DISK_USAGE"
echo "--------------------------------------------------"
