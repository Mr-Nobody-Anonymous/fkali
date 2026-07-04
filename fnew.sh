#!/bin/bash
# --- AUTOMATION HEADERS ---
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
 
# Exit on error, but handle specific failures gracefully
set -e
 
# --- PRE-FLIGHT CHECKS (BEFORE LOGGING SETUP) ---
 
# 1. Verify script is run with appropriate privileges FIRST
if [[ $EUID -ne 0 ]] && ! sudo -n true 2>/dev/null; then
    echo "[!] ERROR: This script requires sudo privileges. Please configure passwordless sudo or run with sudo."
    exit 1
fi
 
# Setup Logging (after privilege check)
LOG_FILE="/var/log/kali_self_heal.log"
exec > >(tee -i $LOG_FILE) 2>&1
 
# --- OPTIONAL FLAGS ---
# Run with: sudo ./fkali.sh --install-tools   to also pull in forensics/web/RE metapackages
INSTALL_TOOLS=0
for arg in "$@"; do
    case "$arg" in
        --install-tools) INSTALL_TOOLS=1 ;;
    esac
done
 
# Progress bar function
show_progress() {
    echo -e "\n\e[1;34m[PROG]\e[0m #################### ($1)"
}
 
# Error handler
error_exit() {
    echo "[!] ERROR: $1"
    exit 1
}
 
# Retry wrapper: retries a command up to N times with a delay between attempts.
# Usage: retry <max_attempts> <sleep_seconds> "<command string>"
retry() {
    local max_attempts="$1"; shift
    local delay="$1"; shift
    local cmd="$*"
    local attempt=1
    until eval "$cmd"; do
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "[!] WARNING: command failed after $attempt attempts: $cmd"
            return 1
        fi
        echo "[!] Attempt $attempt failed. Retrying in ${delay}s..."
        attempt=$((attempt + 1))
        sleep "$delay"
    done
    return 0
}
 
echo "[*] Starting ULTIMATE Kali self-healing script..."
echo "[*] Date: $(date)"
 
# --- PRE-FLIGHT CHECKS ---
show_progress "5% - Pre-flight Checks"
 
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
 
# 6. Disable apt-listbugs' network bug-report fetch (causes "503 Service Unavailable"
#    prompts that abort otherwise-successful installs). We don't remove it, just stop
#    it from blocking non-interactive runs.
if dpkg -l | grep -q "^ii.*apt-listbugs"; then
    echo "[*] Configuring apt-listbugs to not block automated installs..."
    echo "apt-listbugs apt-listbugs/enable_bugscan boolean false" | sudo debconf-set-selections 2>/dev/null || true
    sudo mkdir -p /etc/apt/apt.conf.d
    echo 'DPkg::Pre-Invoke {"if [ -x /usr/sbin/apt-listbugs ]; then /usr/sbin/apt-listbugs --dont-stop apt || true; fi";};' | \
        sudo tee /etc/apt/apt.conf.d/10apt-listbugs-noninteractive >/dev/null 2>&1 || true
fi
 
show_progress "15% - Fixing Mirrors & Keys"
 
# 7. Mirror health check: fall back to a known-good direct mirror if the default
#    redirector (deb.kali.org / http.kali.org) resolves to a dead host.
#    This directly addresses the "Could not connect to mirrors.netix.net" failure class.
PRIMARY_SOURCE="deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware"
FALLBACK_SOURCE="deb http://kali.download/kali kali-rolling main contrib non-free non-free-firmware"
 
echo "[*] Writing primary Kali sources..."
echo "$PRIMARY_SOURCE" | sudo tee /etc/apt/sources.list >/dev/null
 
echo "[*] Testing repository reachability..."
set +e
sudo apt-get update -o Acquire::Retries=2 -o Acquire::http::Timeout=10 &>/tmp/apt_update_test.log
UPDATE_STATUS=$?
set -e
 
if [ $UPDATE_STATUS -ne 0 ] || grep -qi "unable to connect\|connection refused\|could not resolve\|service unavailable" /tmp/apt_update_test.log; then
    echo "[!] WARNING: Primary source unreachable or partially failing. Switching to fallback mirror (kali.download)..."
    echo "$FALLBACK_SOURCE" | sudo tee /etc/apt/sources.list >/dev/null
else
    echo "[*] Primary source reachable."
fi
rm -f /tmp/apt_update_test.log
 
echo "[*] Downloading and installing Kali archive keyring..."
set +e
wget -q -O - https://archive.kali.org/archive-key.asc 2>/dev/null | gpg --dearmor 2>/dev/null | sudo tee /etc/apt/trusted.gpg.d/kali-archive-keyring.gpg > /dev/null
KEYRING_STATUS=$?
set -e
 
if [ $KEYRING_STATUS -ne 0 ]; then
    echo "[!] WARNING: Failed to update Kali archive keyring. Continuing anyway..."
fi
 
show_progress "25% - Repairing Broken Dependencies & Package DB"
 
# 8. Repair a corrupted dpkg status/lock state before touching anything else
echo "[*] Checking dpkg database integrity..."
if [ ! -s /var/lib/dpkg/status ]; then
    echo "[!] WARNING: dpkg status file missing or empty. Attempting recovery from backup..."
    sudo cp /var/backups/dpkg.status.0 /var/lib/dpkg/status 2>/dev/null || \
        echo "[!] WARNING: No dpkg status backup found. Manual intervention may be required."
fi
 
echo "[*] Configuring pending packages..."
sudo dpkg --configure -a || echo "[!] WARNING: dpkg configure had issues, continuing..."
 
# 9. Fix "held broken packages" / interrupted installs more aggressively
echo "[*] Force-repairing any half-installed packages..."
sudo apt-get install -f -y --fix-missing || echo "[!] WARNING: Initial dependency fix incomplete, continuing..."
 
echo "[*] Updating package lists (with retry)..."
retry 3 10 "sudo apt-get update --fix-missing" || error_exit "Failed to update package lists after multiple attempts"
 
echo "[*] Installing broken dependencies..."
sudo apt-get install -f -y || echo "[!] WARNING: Some dependency fixes failed, continuing..."
 
# 10. Clean up duplicate/conflicting source entries (common cause of "unable to
#     locate package" and duplicate signature warnings)
echo "[*] Checking for duplicate or conflicting APT source entries..."
if [ -d /etc/apt/sources.list.d ]; then
    DUPES=$(find /etc/apt/sources.list.d -name "*.list" 2>/dev/null | xargs -I{} md5sum {} 2>/dev/null | sort | uniq -c -w32 | awk '$1>1{print}')
    if [ -n "$DUPES" ]; then
        echo "[!] WARNING: Duplicate source files detected. Review /etc/apt/sources.list.d manually if issues persist."
    fi
fi
 
show_progress "50% - Core System Upgrade"
 
# 11. Full upgrade with retry logic — mirror redirector hiccups (like the netix.net
#     connection-refused errors) are usually transient and succeed on a retry against
#     a re-resolved mirror.
echo "[*] Performing full system upgrade (with retry on transient mirror failures)..."
retry 3 15 "sudo apt-get full-upgrade -y --fix-missing" || \
    error_exit "Full upgrade failed after multiple attempts. Try running with a pinned mirror (see kali.download fallback in this script)."
 
show_progress "65% - Filesystem & Broken Symlink Cleanup"
 
# 12. Find and report broken symlinks in common binary paths (frequent cause of
#     "command not found" after botched installs/upgrades)
echo "[*] Scanning for broken symlinks in /usr/bin, /usr/local/bin, /usr/sbin..."
BROKEN_LINKS=$(find /usr/bin /usr/local/bin /usr/sbin -xtype l 2>/dev/null)
if [ -n "$BROKEN_LINKS" ]; then
    echo "[!] WARNING: Broken symlinks found:"
    echo "$BROKEN_LINKS"
    echo "[*] These were NOT auto-removed. Review and remove manually with: sudo rm <path>"
else
    echo "[*] No broken symlinks found."
fi
 
# 13. Rebuild common caches that silently break tools (locate, man, font, icon, ld)
echo "[*] Rebuilding system caches..."
sudo updatedb 2>/dev/null || echo "[!] NOTE: updatedb not available (mlocate/plocate not installed) - skipping."
sudo mandb -q 2>/dev/null || echo "[!] NOTE: mandb not available - skipping."
sudo ldconfig || echo "[!] WARNING: ldconfig failed."
sudo fc-cache -f 2>/dev/null || echo "[!] NOTE: fontconfig not available - skipping."
sudo update-desktop-database 2>/dev/null || true
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor 2>/dev/null || true
 
show_progress "75% - Reinstalling Essential Metadata"
 
echo "[*] Reinstalling Kali archive keyring..."
sudo apt-get install --reinstall -y kali-archive-keyring || echo "[!] WARNING: Failed to reinstall keyring, continuing..."
 
# 14. Optional: install the requested tool category metapackages
#     (forensics, web pentest, reverse engineering). Run with --install-tools.
if [ "$INSTALL_TOOLS" -eq 1 ]; then
    show_progress "80% - Installing Tool Category Metapackages"
    echo "[*] Installing kali-linux-large, kali-tools-forensics, kali-tools-web, kali-tools-reverse-engineering..."
    for PKG in kali-linux-large kali-tools-forensics kali-tools-web kali-tools-reverse-engineering; do
        echo "[*] Installing $PKG (with retry)..."
        retry 2 10 "sudo apt-get install -y $PKG" || echo "[!] WARNING: $PKG failed to install fully, continuing..."
    done
 
    # kali-tools-malware isn't guaranteed to exist in every Kali branch; probe first.
    if apt-cache show kali-tools-malware &>/dev/null; then
        echo "[*] Installing kali-tools-malware..."
        retry 2 10 "sudo apt-get install -y kali-tools-malware" || echo "[!] WARNING: kali-tools-malware failed to install fully, continuing..."
    else
        echo "[*] kali-tools-malware not available in this release; malware-analysis tools are likely folded into forensics/RE metapackages already installed above."
    fi
else
    echo "[*] Skipping tool category installs (run with --install-tools to enable)."
fi
 
show_progress "90% - Deep Cleaning"
 
echo "[*] Removing unused packages..."
sudo apt-get autoremove --purge -y || echo "[!] WARNING: Autoremove had issues"
 
echo "[*] Cleaning package cache..."
sudo apt-get clean
 
echo "[*] Cleaning old journal logs..."
sudo journalctl --vacuum-time=1d || echo "[!] NOTE: journalctl vacuum skipped (journald may not be in use)."
 
echo "[*] Removing old kernel packages..."
# Check if there are actually packages to remove first
PACKAGES_TO_REMOVE=$(dpkg -l | awk '/^rc/ { print $2 }' | tr '\n' ' ')
if [ -n "$PACKAGES_TO_REMOVE" ]; then
    sudo apt-get purge $PACKAGES_TO_REMOVE -y 2>/dev/null || echo "[!] WARNING: Failed to remove some packages"
else
    echo "[*] No obsolete packages to remove."
fi
 
# 15. Warn (don't auto-remove) if multiple kernels are installed and disk space is tight,
#     since removing the running kernel can break boot.
echo "[*] Checking installed kernel count..."
KERNEL_COUNT=$(dpkg -l | grep -c '^ii  linux-image-[0-9]')
if [ "$KERNEL_COUNT" -gt 2 ]; then
    echo "[!] NOTE: $KERNEL_COUNT kernel images installed. Consider manually removing old ones with 'sudo apt autoremove --purge' after confirming you're not on them (uname -r)."
fi
 
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
            # Use a temp file in /var/tmp (more reliable than /tmp)
            TEMP_HIST=$(mktemp /var/tmp/zsh_hist.XXXXXX)
            if sudo strings "$TARGET_HIST" > "$TEMP_HIST" 2>/dev/null && [ -s "$TEMP_HIST" ]; then
                sudo mv "$TEMP_HIST" "$TARGET_HIST" && echo "[*] Successfully repaired $TARGET_HIST"
            else
                echo "[!] WARNING: Could not repair $TARGET_HIST"
                rm -f "$TEMP_HIST"
            fi
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
if [ "$INSTALL_TOOLS" -eq 0 ]; then
    echo "TIP: Run './fkali.sh --install-tools' to also install forensics/web/reverse-engineering tool metapackages."
fi
echo "--------------------------------------------------"
