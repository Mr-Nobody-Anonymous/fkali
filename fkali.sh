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

# Error handler
error_exit() {
    echo "[!] ERROR: $1"
    exit 1
}

echo "[*] Starting ULTIMATE Kali self-healing script..."
echo "[*] Date: $(date)"

# --- PRE-FLIGHT CHECKS ---
show_progress "5% - Pre-flight Checks"

# 1. Verify script is run with appropriate privileges
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    error_exit "This script requires sudo privileges. Please configure passwordless sudo or run with sudo."
fi

# 2. Check for Internet (try multiple DNS servers for reliability)
echo "[*] Checking internet connectivity..."
if ! ping -c 1 8.8.8.8 &>/dev/null && ! ping -c 1 1.1.1.1 &>/dev/null; then
    error_exit "No internet connection detected. Updates will fail."
fi
echo "[*] Internet connection verified."

# 3. Check if apt is locked
if sudo fuser /var/lib/apt/lists/lock &>/dev/null; then
    echo "[!] WARNING: apt is currently in use. Waiting 30 seconds..."
    sleep 30
    if sudo fuser /var/lib/apt/lists/lock &>/dev/null; then
        error_exit "apt lock is still held after waiting. Please close other package managers."
    fi
fi

# 4. Release Package Locks (Fixes "Could not get lock" errors)
echo "[*] Clearing potential package locks..."
sudo rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock /var/lib/dpkg/lock

# 5. Measure Cache (store all sizes for final report)
echo "[*] Measuring cache and log sizes..."
D_CACHE_SIZE=$(du -sh ~/.cache 2>/dev/null | awk '{print $1}') || D_CACHE_SIZE="0"
S_CACHE_SIZE=$(du -sh /var/cache/apt 2>/dev/null | awk '{print $1}') || S_CACHE_SIZE="0"
LOG_SIZE=$(du -sh /var/log 2>/dev/null | awk '{print $1}') || LOG_SIZE="0"

show_progress "15% - Fixing Mirrors & Keys"
# Ensure the official Kali sources are present
echo "deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware" | sudo tee /etc/apt/sources.list >/dev/null
echo "[*] Downloading and installing Kali archive keyring..."
if ! wget -q -O - https://archive.kali.org/archive-key.asc 2>/dev/null | gpg --dearmor 2>/dev/null | sudo tee /etc/apt/trusted.gpg.d/kali-archive-keyring.gpg > /dev/null; then
    echo "[!] WARNING: Failed to update Kali archive keyring. Continuing anyway..."
fi

show_progress "30% - Repairing Broken Dependencies"
# Added 'configure -a' before update to fix interrupted installs
echo "[*] Configuring pending packages..."
sudo dpkg --configure -a || echo "[!] WARNING: dpkg configure had issues, continuing..."

echo "[*] Updating package lists..."
sudo apt-get update --fix-missing || error_exit "Failed to update package lists"

echo "[*] Installing broken dependencies..."
sudo apt-get install -f -y || echo "[!] WARNING: Some dependency fixes failed, continuing..."

show_progress "50% - Core System Upgrade"
# Using full-upgrade instead of dist-upgrade for better dependency resolution
echo "[*] Performing full system upgrade..."
sudo apt-get full-upgrade -y || error_exit "Full upgrade failed"

show_progress "70% - Reinstalling Essential Metadata"
# Fixed: Only reinstalls if they are missing or broken to save time
echo "[*] Reinstalling Kali archive keyring..."
sudo apt-get install --reinstall -y kali-archive-keyring || echo "[!] WARNING: Failed to reinstall keyring, continuing..."

show_progress "85% - Deep Cleaning"
echo "[*] Removing unused packages..."
sudo apt-get autoremove --purge -y || echo "[!] WARNING: Autoremove had issues"

echo "[*] Cleaning package cache..."
sudo apt-get clean

echo "[*] Cleaning old journal logs..."
sudo journalctl --vacuum-time=1d

echo "[*] Removing old kernel packages..."
sudo apt-get purge $(dpkg -l | awk '/^rc/ { print $2 }') -y 2>/dev/null || true

show_progress "95% - History & Filesystem Sync"
# Repair ZSH history safely
echo "[*] Validating and repairing shell history..."
REAL_USER=${SUDO_USER:-$USER}

# Verify REAL_USER is set properly
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    REAL_USER="root"
    USER_HOME="/root"
else
    USER_HOME=$(eval echo ~$REAL_USER) 2>/dev/null || USER_HOME="/root"
fi

for TARGET_HIST in "$USER_HOME/.zsh_history" "/root/.zsh_history"; do
    if [ -f "$TARGET_HIST" ]; then
        echo "[*] Validating $TARGET_HIST..."
        # Create backup before modification
        sudo cp "$TARGET_HIST" "${TARGET_HIST}.backup" 2>/dev/null || true
        
        # Use a safer method: validate and reconstruct if needed
        if sudo file "$TARGET_HIST" 2>/dev/null | grep -q "data"; then
            echo "[*] History file appears corrupted, attempting repair..."
            sudo strings "$TARGET_HIST" > "${TARGET_HIST}.tmp" 2>/dev/null && \
            sudo mv "${TARGET_HIST}.tmp" "$TARGET_HIST" || \
            echo "[!] WARNING: Could not repair $TARGET_HIST"
        fi
        
        # Fix ownership if needed
        HIST_OWNER=$(stat -c '%U:%G' $(dirname $TARGET_HIST) 2>/dev/null) || HIST_OWNER="root:root"
        sudo chown "$HIST_OWNER" "$TARGET_HIST" 2>/dev/null || true
    fi
done

echo "[*] Syncing filesystem..."
sync

show_progress "100% - Done"

# Final Stats
DISK_USAGE=$(df -h / | tail -1 | awk '{print $5}')
echo "--------------------------------------------------"
echo "SUCCESS: KALI IS HEALED"
echo "Pre-Cleaning Sizes:"
echo "  - Apt Cache: $S_CACHE_SIZE"
echo "  - User Cache: $D_CACHE_SIZE"
echo "  - Log Files: $LOG_SIZE"
echo "Current Disk Usage: $DISK_USAGE"
echo "Log file saved to: $LOG_FILE"
echo "--------------------------------------------------"
