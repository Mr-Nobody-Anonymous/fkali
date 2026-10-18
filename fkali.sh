#!/usr/bin/env bash
# =============================================================================
# fkali.sh — Kali Linux self-healing & maintenance script
#
# Repairs the failure modes that most commonly break a Kali installation:
#   * stale / held APT & dpkg locks (waited out safely, never deleted)
#   * broken or outdated APT sources (migrated to the modern deb822 format
#     used by Kali >= 2026.2: /etc/apt/sources.list.d/kali.sources)
#   * missing / outdated archive signing key (installs the current
#     2025 Kali archive keyring and verifies its fingerprint before use)
#   * interrupted installs and broken dependencies
#   * a damaged dpkg status database (restored from backup when possible)
#   * bloated APT cache, journals and rotated logs
#   * removed-but-not-purged ("rc") packages and stale system caches
#   * corrupted zsh history files (NUL-byte damage)
#
# It then performs a full system upgrade and prints a summary.
#
# References:
#   * APT sources (deb822): https://www.kali.org/docs/general-use/kali-apt-sources/
#   * Updating Kali:        https://www.kali.org/docs/general-use/updating-kali/
#   * 2025 signing key:     https://www.kali.org/blog/new-kali-archive-signing-key/
#
# Usage: sudo ./fkali.sh [--dry-run] [--yes] [--install-tools] [options...]
#        ./fkali.sh --help   for the full list of options.
#
# SPDX-License-Identifier: MIT
# =============================================================================

# Deliberately NOT `set -e`: a self-healing script must keep going (and keep
# reporting) when an individual repair step fails. Critical steps are checked
# explicitly via die(); everything else accumulates into the warning counter.
set -uo pipefail
umask 022

# Non-interactive package management: never stop and wait for a prompt.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

VERSION="2.0.0"
SCRIPT_NAME="fkali"

# ---------------------------------------------------------------------------
# Configuration (overridable via flags / environment)
# ---------------------------------------------------------------------------
MIRROR_PRIMARY="http://http.kali.org/kali"      # official redirector / load balancer
MIRROR_FALLBACK="http://kali.download/kali"     # official CDN mirror
MIRROR="${FKALI_MIRROR:-}"                      # empty = auto (primary, then fallback)
KEYRING_URL="https://archive.kali.org/archive-keyring.gpg"
KEYRING_PATH="/usr/share/keyrings/kali-archive-keyring.gpg"
# Kali Linux Archive Automatic Signing Key (2025), expires 2028-04-17.
EXPECTED_KEY_FPR="827C8569F2518CC677FECA1AED65462EC8D5E4C5"
SOURCES_FILE="/etc/apt/sources.list.d/kali.sources"
LEGACY_SOURCES="/etc/apt/sources.list"
DEFAULT_LOG_FILE="/var/log/kali_self_heal.log"
LOG_FILE="${FKALI_LOG_FILE:-$DEFAULT_LOG_FILE}"
VACUUM_DAYS=7          # keep this many days of journal / rotated logs
LOCK_WAIT_SECS=120     # how long to wait for another apt/dpkg process
MIN_FREE_KB=2097152    # warn below 2 GiB free on /

APT_LOCKS=(
    /var/lib/dpkg/lock-frontend
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
    /var/lib/dpkg/lock
)

TOOL_METAPACKAGES=(
    kali-linux-large
    kali-tools-forensics
    kali-tools-web
    kali-tools-reverse-engineering
    kali-tools-malware
)

# Flags (set by parse_args)
DRY_RUN=0
ASSUME_YES=0
INSTALL_TOOLS=0
DO_UPGRADE=1
DO_CLEAN=1
DO_LOG=1
FORCE=0

WARNINGS=0
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_SUFFIX=".fkali-backup-${TIMESTAMP}"
ORIG_ARGS=("$@")

# Sizes captured during pre-flight, reported again at the end.
PRE_APT_CACHE="unknown"
PRE_USER_CACHE="unknown"
PRE_LOG_SIZE="unknown"

# apt-get options used for every mutating apt call: answer yes, keep existing
# conffiles by default, and retry flaky mirrors.
APT_OPTS=(
    -y
    -o Dpkg::Options::="--force-confdef"
    -o Dpkg::Options::="--force-confold"
    -o Acquire::Retries=3
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_BLUE=$'\e[1;34m'
    C_YELLOW=$'\e[1;33m'
    C_RED=$'\e[1;31m'
    C_GREEN=$'\e[1;32m'
    C_OFF=$'\e[0m'
else
    C_BLUE="" C_YELLOW="" C_RED="" C_GREEN="" C_OFF=""
fi

info() { printf '%s\n' "[*] $*"; }

warn() {
    printf '%b\n' "${C_YELLOW}[!] WARNING:${C_OFF} $*" >&2
    WARNINGS=$((WARNINGS + 1))
}

error() { printf '%b\n' "${C_RED}[!] ERROR:${C_OFF} $*" >&2; }

die() {
    error "$*"
    exit 1
}

# progress <percent> <label>
progress() {
    local pct="$1" label="$2"
    local width=20 filled bar
    filled=$((pct * width / 100))
    printf -v bar '%*s' "$filled" ''
    bar="${bar// /#}"
    printf -v bar '%-20s' "$bar"
    printf '\n%b [%s] %3d%% - %s\n' "${C_BLUE}[PROGRESS]${C_OFF}" "$bar" "$pct" "$label"
}

print_version() { printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; }

usage() {
    cat <<EOF
Usage: sudo ./fkali.sh [OPTIONS]

Kali Linux self-healing script: repairs APT sources/keys, broken packages
and locks, upgrades the system, and cleans up safely.

Options:
  -h, --help              Show this help and exit.
  -V, --version           Show version and exit.
  -n, --dry-run           Print what would be done; change nothing.
                          (Does not require root or a Kali system.)
  -y, --yes               Do not ask for confirmation before starting.
      --install-tools     Also install tool metapackages:
                          kali-linux-large, kali-tools-forensics,
                          kali-tools-web, kali-tools-reverse-engineering
                          (and kali-tools-malware when available).
      --no-upgrade        Skip the 'apt-get full-upgrade' step.
      --no-clean          Skip autoremove / cache / log cleanup.
      --mirror URL        Use this mirror base instead of auto-detecting
                          (default: $MIRROR_PRIMARY, falling back to
                          $MIRROR_FALLBACK). Example:
                          --mirror http://kali.download/kali
      --vacuum-days N     Delete journal entries and rotated logs older
                          than N days (default: $VACUUM_DAYS).
      --log FILE          Log all output to FILE
                          (default: $DEFAULT_LOG_FILE).
      --no-log            Do not write a log file; terminal output only.
      --force             Run even if /etc/os-release does not say Kali.
                          (Debian-based systems only; use with care.)

Environment:
  FKALI_MIRROR            Same as --mirror.
  FKALI_LOG_FILE          Same as --log.
  NO_COLOR                Disable coloured output.

Examples:
  sudo ./fkali.sh                     # heal + upgrade + clean
  sudo ./fkali.sh --yes               # same, without the confirmation prompt
  sudo ./fkali.sh --install-tools     # heal, upgrade, install tool categories
  ./fkali.sh --dry-run                # preview every action safely
EOF
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

# Run a command, or just print it in --dry-run mode.
run() {
    if ((DRY_RUN)); then
        printf '[dry-run] '
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

# retry <max_attempts> <delay_seconds> <command> [args...]
# (No eval: the command is executed directly, so quoting always stays intact.)
retry() {
    local max_attempts="$1" delay="$2"
    shift 2
    local attempt=1
    while true; do
        if run "$@"; then
            return 0
        fi
        if ((attempt >= max_attempts)); then
            warn "Command failed after ${attempt} attempt(s): $*"
            return 1
        fi
        info "Attempt ${attempt} failed; retrying in ${delay}s..."
        attempt=$((attempt + 1))
        ((DRY_RUN)) || sleep "$delay"
    done
}

# Human-readable size of a directory ("unknown" when it cannot be measured).
dir_size() {
    local size
    size="$(du -sh "$1" 2>/dev/null | awk '{print $1}')"
    printf '%s' "${size:-unknown}"
}

# Copy a file aside before modifying it. No-op for missing files.
backup_file() {
    local file="$1"
    [[ -e "$file" ]] || return 0
    if ((DRY_RUN)); then
        info "[dry-run] Would back up ${file} -> ${file}${BACKUP_SUFFIX}"
        return 0
    fi
    if cp -a -- "$file" "${file}${BACKUP_SUFFIX}"; then
        info "Backed up ${file} -> ${file}${BACKUP_SUFFIX}"
    else
        warn "Could not back up ${file}"
    fi
}

# URL download / reachability, using whichever tool is installed.
download_file() { # <url> <dest>
    if have curl; then
        curl -fsSL --retry 3 --connect-timeout 10 -o "$2" "$1"
    elif have wget; then
        wget -q --tries=3 --timeout=10 -O "$2" "$1"
    else
        return 127
    fi
}

probe_url() { # <url>
    if have curl; then
        curl -fsSL --max-time 15 -o /dev/null "$1"
    elif have wget; then
        wget -q --spider --timeout=15 "$1"
    else
        return 127
    fi
}

# Home directory of a user, without the unsafe `eval echo ~user` trick.
home_of() {
    local user="$1" home
    home="$(getent passwd "$user" 2>/dev/null | cut -d: -f6)"
    printf '%s' "$home"
}

# ---------------------------------------------------------------------------
# Argument parsing & privilege handling
# ---------------------------------------------------------------------------
parse_args() {
    while (($#)); do
        case "$1" in
            -h|--help)    usage; exit 0 ;;
            -V|--version) print_version; exit 0 ;;
            -n|--dry-run) DRY_RUN=1 ;;
            -y|--yes)     ASSUME_YES=1 ;;
            --install-tools) INSTALL_TOOLS=1 ;;
            --no-upgrade) DO_UPGRADE=0 ;;
            --no-clean)   DO_CLEAN=0 ;;
            --no-log)     DO_LOG=0 ;;
            --force)      FORCE=1 ;;
            --mirror)
                (($# >= 2)) || { error "--mirror requires a URL"; exit 2; }
                MIRROR="$2"; shift ;;
            --mirror=*)   MIRROR="${1#*=}" ;;
            --log)
                (($# >= 2)) || { error "--log requires a file path"; exit 2; }
                LOG_FILE="$2"; DO_LOG=1; shift ;;
            --log=*)      LOG_FILE="${1#*=}"; DO_LOG=1 ;;
            --vacuum-days)
                (($# >= 2)) || { error "--vacuum-days requires a number"; exit 2; }
                VACUUM_DAYS="$2"; shift ;;
            --vacuum-days=*) VACUUM_DAYS="${1#*=}" ;;
            --) shift; break ;;
            *)
                error "Unknown option: $1"
                usage >&2
                exit 2 ;;
        esac
        shift
    done

    if (($#)); then
        error "Unexpected argument(s): $*"
        exit 2
    fi

    [[ "$VACUUM_DAYS" =~ ^[0-9]+$ ]] || { error "--vacuum-days must be a non-negative integer (got: $VACUUM_DAYS)"; exit 2; }
    if [[ -n "$MIRROR" && ! "$MIRROR" =~ ^https?:// ]]; then
        error "--mirror must start with http:// or https:// (got: $MIRROR)"
        exit 2
    fi
    MIRROR="${MIRROR%/}"
}

# This script repairs system files, so it needs root. Instead of failing
# (the old script demanded *passwordless* sudo), re-run ourselves via sudo,
# which will prompt for a password as usual. --dry-run needs no privileges.
ensure_privileges() {
    ((EUID == 0)) && return 0
    if ((DRY_RUN)); then
        info "Dry-run as unprivileged user: nothing will be changed."
        return 0
    fi
    have sudo || die "This script must run as root, and 'sudo' is not installed. Re-run as root."
    [[ -f "$0" ]] || die "This script must run as root. Re-run it as: sudo ./fkali.sh"
    info "Root privileges are required; re-running with sudo..."
    exec sudo -- bash "$0" "${ORIG_ARGS[@]}"
}

confirm_or_exit() {
    ((ASSUME_YES || DRY_RUN)) && return 0
    [[ -t 0 ]] || return 0   # non-interactive input: do not block automation
    local answer
    printf '%s\n' "This will modify APT sources/keys, repair packages, upgrade the system and clean up."
    read -r -p "Continue? [y/N] " answer || answer=""
    case "$answer" in
        y|Y|yes|YES) ;;
        *) info "Aborted by user."; exit 0 ;;
    esac
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
check_os() {
    local os_id=""
    if [[ -r /etc/os-release ]]; then
        os_id="$(awk -F= '$1=="ID" {gsub(/"/, "", $2); print $2; exit}' /etc/os-release)"
    fi
    if [[ "$os_id" == "kali" ]]; then
        info "Detected Kali Linux."
        return 0
    fi
    if ((FORCE)); then
        warn "/etc/os-release reports '${os_id:-unknown}', not Kali; continuing because --force was given."
    elif ((DRY_RUN)); then
        warn "/etc/os-release reports '${os_id:-unknown}', not Kali; continuing for this dry-run only."
    else
        die "This does not look like Kali Linux (/etc/os-release ID='${os_id:-unknown}'). Refusing to run; use --force to override."
    fi
}

check_required_tools() {
    local missing=() tool
    for tool in apt-get dpkg; do
        have "$tool" || missing+=("$tool")
    done
    if ((${#missing[@]})); then
        if ((DRY_RUN)); then
            warn "Required tool(s) not found on this machine: ${missing[*]} (dry-run continues)"
        else
            die "Required tool(s) not found: ${missing[*]}. Is this a Debian/Kali system?"
        fi
    fi
    have curl || have wget || warn "Neither curl nor wget found: keyring download and mirror probes will be skipped."
    have gpg || warn "gpg not found: the downloaded keyring cannot be fingerprint-verified."
}

check_disk_space() {
    local avail_kb
    avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
    [[ "$avail_kb" =~ ^[0-9]+$ ]] || return 0
    if ((avail_kb < MIN_FREE_KB)); then
        warn "Low free space on / ($((avail_kb / 1024)) MiB). The upgrade may fail; cleanup at the end will help future runs."
    else
        info "Free space on /: $((avail_kb / 1024)) MiB."
    fi
}

check_connectivity() {
    if ((DRY_RUN)); then
        info "[dry-run] Would check internet connectivity (ping 8.8.8.8 / 1.1.1.1, then the Kali mirror)."
        return 0
    fi
    info "Checking internet connectivity..."
    # ICMP is blocked on some networks, so fall back to a real HTTP probe
    # of the Kali mirror before declaring the machine offline.
    if have ping && { ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 || ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; }; then
        info "Internet connection verified (ICMP)."
        return 0
    fi
    if probe_url "${MIRROR_PRIMARY}/dists/kali-rolling/Release" 2>/dev/null; then
        info "Internet connection verified (Kali mirror reachable over HTTP)."
        return 0
    fi
    die "No internet connection detected and the Kali mirror is unreachable. Connect to a network and re-run."
}

apt_is_locked() {
    local lock
    for lock in "${APT_LOCKS[@]}"; do
        if [[ -e "$lock" ]] && fuser "$lock" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# IMPORTANT: modern apt/dpkg lock *files* are held with flock(2); deleting
# them (as older versions of this script did) does not release the lock and
# can corrupt the package database if a process really is running. The only
# safe fix for "Could not get lock" is to wait for, or stop, the other
# process -- so we wait, then give up with a clear message.
wait_for_apt_locks() {
    if ((DRY_RUN)); then
        info "[dry-run] Would wait up to ${LOCK_WAIT_SECS}s for other apt/dpkg processes (lock files are never deleted)."
        return 0
    fi
    if ! have fuser; then
        warn "'fuser' (psmisc) not found: cannot check whether apt/dpkg is already running."
        return 0
    fi
    local waited=0
    while apt_is_locked; do
        if ((waited >= LOCK_WAIT_SECS)); then
            die "Another apt/dpkg process still holds a lock after ${LOCK_WAIT_SECS}s. Close other package managers (or wait for unattended-upgrades) and re-run. Do NOT delete lock files by hand."
        fi
        info "apt/dpkg is in use by another process; waiting... (${waited}/${LOCK_WAIT_SECS}s)"
        sleep 5
        waited=$((waited + 5))
    done
    info "No other apt/dpkg process is running."
}

measure_sizes() {
    local real_user="${SUDO_USER:-${USER:-root}}"
    local user_home
    user_home="$(home_of "$real_user")"
    [[ -n "$user_home" ]] || user_home="${HOME:-/root}"
    PRE_USER_CACHE="$(dir_size "${user_home}/.cache")"
    PRE_APT_CACHE="$(dir_size /var/cache/apt)"
    PRE_LOG_SIZE="$(dir_size /var/log)"
    info "Pre-run sizes - apt cache: ${PRE_APT_CACHE}, user cache (${user_home}/.cache): ${PRE_USER_CACHE}, /var/log: ${PRE_LOG_SIZE}"
}

# ---------------------------------------------------------------------------
# APT sources & signing key
# ---------------------------------------------------------------------------
# Sets the global CHOSEN_MIRROR. (A previous draft printed the result on
# stdout and captured it with $(...), which also captured the info/warn
# messages into the sources file -- hence the global.)
CHOSEN_MIRROR=""
choose_mirror() {
    if [[ -n "$MIRROR" ]]; then
        info "Using mirror from --mirror/FKALI_MIRROR: ${MIRROR}"
        CHOSEN_MIRROR="$MIRROR"
        return 0
    fi
    if ((DRY_RUN)); then
        info "[dry-run] Would probe ${MIRROR_PRIMARY}, falling back to ${MIRROR_FALLBACK} if unreachable."
        CHOSEN_MIRROR="$MIRROR_PRIMARY"
        return 0
    fi
    info "Probing primary mirror (${MIRROR_PRIMARY})..."
    if probe_url "${MIRROR_PRIMARY}/dists/kali-rolling/Release" 2>/dev/null; then
        info "Primary mirror is reachable."
        CHOSEN_MIRROR="$MIRROR_PRIMARY"
        return 0
    fi
    warn "Primary mirror unreachable; trying fallback (${MIRROR_FALLBACK})..."
    if probe_url "${MIRROR_FALLBACK}/dists/kali-rolling/Release" 2>/dev/null; then
        info "Fallback mirror is reachable."
        CHOSEN_MIRROR="$MIRROR_FALLBACK"
        return 0
    fi
    warn "Neither mirror answered the probe (the redirector may still work from apt). Keeping the primary mirror."
    CHOSEN_MIRROR="$MIRROR_PRIMARY"
}

# Verify that a downloaded keyring really contains the expected Kali key,
# so a truncated/error-page download can never replace a working keyring.
keyring_has_expected_key() {
    local file="$1" listing
    have gpg || return 0   # already warned in check_required_tools
    # --show-keys inspects the file without importing it or creating
    # keyring/trustdb files anywhere; fall back to the keyring listing
    # form for very old GnuPG versions.
    listing="$(gpg --batch --show-keys --with-colons --with-fingerprint "$file" 2>/dev/null)" \
        || listing="$(gpg --batch --no-default-keyring --keyring "$file" \
            --list-keys --with-colons --with-fingerprint 2>/dev/null)" \
        || return 1
    [[ "$listing" == *"$EXPECTED_KEY_FPR"* ]]
}

install_keyring() {
    info "Installing the current Kali archive keyring..."
    if ((DRY_RUN)); then
        info "[dry-run] Would download ${KEYRING_URL}, verify fingerprint ${EXPECTED_KEY_FPR}, then install to ${KEYRING_PATH}."
        return 0
    fi
    local tmp
    tmp="$(mktemp)" || { warn "mktemp failed; skipping keyring update."; return 1; }
    # Always download to a temp file first: piping straight into the target
    # (the old approach) truncates the keyring to 0 bytes when the network
    # fails, which breaks apt completely.
    if ! download_file "$KEYRING_URL" "$tmp" || [[ ! -s "$tmp" ]]; then
        warn "Could not download ${KEYRING_URL}; keeping the existing keyring untouched."
        rm -f -- "$tmp"
        return 1
    fi
    if ! keyring_has_expected_key "$tmp"; then
        warn "Downloaded keyring does not contain the expected Kali key (${EXPECTED_KEY_FPR}); refusing to install it."
        rm -f -- "$tmp"
        return 1
    fi
    backup_file "$KEYRING_PATH"
    if run install -D -m 0644 -- "$tmp" "$KEYRING_PATH"; then
        info "Keyring installed at ${KEYRING_PATH}."
    else
        warn "Failed to install the keyring to ${KEYRING_PATH}."
    fi
    rm -f -- "$tmp"
}

desired_sources_content() { # <mirror>
    cat <<EOF
# See https://www.kali.org/docs/general-use/kali-apt-sources/
# Managed by fkali.sh ${VERSION}; edit the URIs line to use another mirror.
Types: deb
URIs: ${1%/}/
Suites: kali-rolling
Components: main contrib non-free non-free-firmware
Signed-By: ${KEYRING_PATH}
EOF
}

write_sources() { # <mirror>
    local mirror="$1" desired tmp
    desired="$(desired_sources_content "$mirror")"

    if [[ -f "$SOURCES_FILE" ]] && [[ "$(cat "$SOURCES_FILE")" == "$desired" ]]; then
        info "${SOURCES_FILE} is already correct; leaving it unchanged."
    elif ((DRY_RUN)); then
        info "[dry-run] Would write ${SOURCES_FILE} with:"
        printf '%s\n' "$desired" | sed 's/^/[dry-run]   /'
    else
        backup_file "$SOURCES_FILE"
        tmp="$(mktemp)" || { warn "mktemp failed; cannot write ${SOURCES_FILE}."; return 1; }
        printf '%s\n' "$desired" >"$tmp"
        if run install -D -m 0644 -- "$tmp" "$SOURCES_FILE"; then
            info "Wrote ${SOURCES_FILE} (mirror: ${mirror})."
        else
            warn "Failed to write ${SOURCES_FILE}."
        fi
        rm -f -- "$tmp"
    fi

    # Legacy one-line entry for the same repo would now duplicate the
    # deb822 stanza ("Target ... is configured multiple times" warnings),
    # so comment only the Kali line(s) out. Any *other* repositories the
    # user put in sources.list are left alone (older fkali versions
    # overwrote the whole file and destroyed them).
    if [[ -f "$LEGACY_SOURCES" ]] && grep -Eq '^[[:space:]]*deb(-src)?[[:space:]][^#]*kali-rolling' "$LEGACY_SOURCES"; then
        if ((DRY_RUN)); then
            info "[dry-run] Would comment out the legacy kali-rolling line(s) in ${LEGACY_SOURCES} (migrated to ${SOURCES_FILE})."
        else
            backup_file "$LEGACY_SOURCES"
            if sed -i -E 's|^([[:space:]]*deb(-src)?[[:space:]][^#]*kali-rolling.*)$|# fkali: migrated to /etc/apt/sources.list.d/kali.sources -- \1|' "$LEGACY_SOURCES"; then
                info "Commented out the legacy kali-rolling line(s) in ${LEGACY_SOURCES}."
            else
                warn "Could not migrate the legacy entry in ${LEGACY_SOURCES}; check for duplicate-source warnings."
            fi
        fi
    fi
}

report_duplicate_sources() {
    local dupes
    dupes="$(grep -hE '^[[:space:]]*deb[[:space:]]' "$LEGACY_SOURCES" /etc/apt/sources.list.d/*.list 2>/dev/null \
        | sort | uniq -d || true)"
    if [[ -n "$dupes" ]]; then
        warn "Duplicate APT source line(s) found (left untouched; remove the duplicates manually):"
        printf '%s\n' "$dupes" >&2
    fi
}

note_apt_listbugs() {
    # Older fkali versions wrote a bogus DPkg::Pre-Invoke hook for
    # apt-listbugs using a flag that does not exist. We no longer touch
    # its configuration; just explain the one failure mode it can cause.
    if dpkg-query -W -f='${db:Status-Status}' apt-listbugs 2>/dev/null | grep -q '^installed$'; then
        info "Note: apt-listbugs is installed. If an upgrade stalls asking about reported bugs (or a bug server returns 503), re-run the failing apt command interactively, or remove apt-listbugs. fkali does not modify its configuration."
    fi
}

# ---------------------------------------------------------------------------
# Package database repair & upgrade
# ---------------------------------------------------------------------------
repair_dpkg_status() {
    if [[ -s /var/lib/dpkg/status ]]; then
        return 0
    fi
    warn "/var/lib/dpkg/status is missing or empty; attempting recovery from backup..."
    if [[ -s /var/backups/dpkg.status.0 ]]; then
        if run cp -a -- /var/backups/dpkg.status.0 /var/lib/dpkg/status; then
            info "Restored /var/lib/dpkg/status from /var/backups/dpkg.status.0."
        else
            warn "Failed to restore the dpkg status file."
        fi
    elif [[ -s /var/backups/dpkg.status.0.gz ]] && have gzip; then
        if ((DRY_RUN)); then
            info "[dry-run] Would restore /var/lib/dpkg/status from /var/backups/dpkg.status.0.gz."
        elif gzip -dc /var/backups/dpkg.status.0.gz >/var/lib/dpkg/status 2>/dev/null; then
            info "Restored /var/lib/dpkg/status from /var/backups/dpkg.status.0.gz."
        else
            warn "Failed to restore the dpkg status file from the compressed backup."
        fi
    else
        warn "No dpkg status backup found in /var/backups. Manual recovery may be required."
    fi
}

repair_and_update() {
    repair_dpkg_status

    info "Configuring any half-installed packages..."
    run dpkg --configure -a || warn "dpkg --configure -a reported problems; continuing with apt repair."

    info "Updating package lists..."
    retry 3 10 apt-get update --fix-missing \
        || die "Failed to update package lists after multiple attempts. Check the mirror and your network, then re-run."

    info "Repairing broken dependencies..."
    run apt-get install -f "${APT_OPTS[@]}" --fix-missing \
        || warn "Some dependency repairs failed; continuing."
    run dpkg --configure -a || warn "dpkg --configure -a still reports problems; continuing."
}

perform_upgrade() {
    if ((DO_UPGRADE == 0)); then
        info "Skipping system upgrade (--no-upgrade)."
        return 0
    fi
    info "Performing full system upgrade (retries cover transient mirror failures)..."
    if ! retry 3 15 apt-get full-upgrade "${APT_OPTS[@]}" --fix-missing; then
        local log_hint=""
        ((DO_LOG)) && log_hint=" and ${LOG_FILE}"
        die "Full upgrade failed after multiple attempts. See the output above${log_hint}; try '--mirror ${MIRROR_FALLBACK}' if a mirror is at fault."
    fi
}

# ---------------------------------------------------------------------------
# Filesystem caches & broken symlinks
# ---------------------------------------------------------------------------
report_broken_symlinks() {
    info "Scanning for broken symlinks in /usr/bin, /usr/local/bin, /usr/sbin..."
    local list count
    list="$(find /usr/bin /usr/local/bin /usr/sbin -xtype l 2>/dev/null | head -n 20 || true)"
    count="$(find /usr/bin /usr/local/bin /usr/sbin -xtype l 2>/dev/null | wc -l | awk '{print $1}')"
    if [[ "${count:-0}" =~ ^[0-9]+$ ]] && ((count > 0)); then
        warn "Found ${count} broken symlink(s) (first 20 shown). They are NOT auto-removed; review each and delete with: sudo rm <path>"
        printf '%s\n' "$list" >&2
    else
        info "No broken symlinks found."
    fi
}

rebuild_caches() {
    info "Rebuilding system caches (locate / man / linker / fonts / desktop)..."
    if have updatedb; then
        run updatedb || warn "updatedb failed."
    elif have updatedb.plocate; then
        run updatedb.plocate || warn "updatedb.plocate failed."
    else
        info "locate database: mlocate/plocate not installed; skipping."
    fi
    if have mandb; then
        run mandb -q || warn "mandb failed."
    fi
    run ldconfig || warn "ldconfig failed."
    if have fc-cache; then
        run fc-cache -f || warn "fc-cache failed."
    fi
    if have update-desktop-database; then
        run update-desktop-database || warn "update-desktop-database failed."
    fi
    if have gtk-update-icon-cache && [[ -d /usr/share/icons/hicolor ]]; then
        run gtk-update-icon-cache -f /usr/share/icons/hicolor || warn "gtk-update-icon-cache failed."
    fi
}

# ---------------------------------------------------------------------------
# Essential packages & optional tool metapackages
# ---------------------------------------------------------------------------
reinstall_keyring_package() {
    info "Ensuring the kali-archive-keyring package itself is healthy..."
    run apt-get install --reinstall "${APT_OPTS[@]}" kali-archive-keyring \
        || warn "Failed to reinstall kali-archive-keyring; the manually installed keyring (previous step) is still in place."
}

install_tool_metapackages() {
    if ((INSTALL_TOOLS == 0)); then
        info "Skipping tool metapackages (pass --install-tools to install forensics/web/reverse-engineering tools)."
        return 0
    fi
    info "Installing tool category metapackages..."
    local pkg
    for pkg in "${TOOL_METAPACKAGES[@]}"; do
        # Not every Kali branch ships every metapackage (e.g.
        # kali-tools-malware), so probe before trying to install.
        if ((DRY_RUN == 0)) && ! apt-cache show "$pkg" >/dev/null 2>&1; then
            info "${pkg} is not available in this release; skipping."
            continue
        fi
        info "Installing ${pkg}..."
        retry 2 10 apt-get install "${APT_OPTS[@]}" "$pkg" \
            || warn "${pkg} did not install completely; continuing."
    done
}

# ---------------------------------------------------------------------------
# Deep cleaning
# ---------------------------------------------------------------------------
deep_clean() {
    if ((DO_CLEAN == 0)); then
        info "Skipping cleanup (--no-clean)."
        return 0
    fi

    info "Removing unused packages..."
    run apt-get autoremove --purge "${APT_OPTS[@]}" || warn "autoremove reported problems."

    info "Cleaning the local package cache..."
    run apt-get clean || warn "apt-get clean failed."

    info "Purging configuration files of already-removed packages ('rc' state)..."
    local -a rc_packages=()
    mapfile -t rc_packages < <(dpkg -l 2>/dev/null | awk '/^rc/ {print $2}')
    if ((${#rc_packages[@]})); then
        run apt-get purge "${APT_OPTS[@]}" "${rc_packages[@]}" \
            || warn "Failed to purge some residual configuration packages."
    else
        info "No residual configuration packages to purge."
    fi

    info "Vacuuming journal entries older than ${VACUUM_DAYS} day(s)..."
    if have journalctl; then
        run journalctl --vacuum-time="${VACUUM_DAYS}d" \
            || warn "journalctl vacuum failed (journald may not be in use)."
    else
        info "journalctl not available; skipping."
    fi

    # Only *rotated* logs older than the retention window are deleted.
    # Older fkali versions deleted every rotated log and truncated live
    # log files larger than 50 MB, which destroys exactly the evidence
    # you need when debugging -- and truncating a file a daemon holds
    # open leaves sparse, garbled logs. Active logs are left alone.
    info "Removing rotated log files older than ${VACUUM_DAYS} day(s)..."
    run find /var/log -type f \
        \( -name '*.gz' -o -name '*.old' -o -name '*.log.*' -o -name '*.[0-9]' \) \
        -mtime "+${VACUUM_DAYS}" -delete \
        || warn "Some rotated logs could not be removed."

    local kernel_count
    kernel_count="$(dpkg -l 2>/dev/null | awk '/^ii[[:space:]]+linux-image-[0-9]/ {c++} END {print c + 0}')"
    if [[ "${kernel_count:-0}" =~ ^[0-9]+$ ]] && ((kernel_count > 2)); then
        warn "${kernel_count} kernel images are installed. Old kernels are never auto-removed here (removing the running one can break boot; you are running $(uname -r)). Review with 'dpkg -l linux-image-*' and purge old ones manually."
    fi
}

# ---------------------------------------------------------------------------
# Shell history repair
# ---------------------------------------------------------------------------
file_contains_nul() {
    local file="$1" total stripped
    total="$(stat -c %s -- "$file" 2>/dev/null)" || return 1
    stripped="$(tr -d '\000' <"$file" 2>/dev/null | wc -c | awk '{print $1}')"
    [[ "$total" =~ ^[0-9]+$ && "$stripped" =~ ^[0-9]+$ && "$stripped" -ne "$total" ]]
}

repair_one_history() { # <path>
    local hist="$1"
    [[ -f "$hist" ]] || return 0

    if ! file_contains_nul "$hist"; then
        info "History file OK: ${hist}"
        return 0
    fi

    warn "History file appears corrupted (contains NUL bytes): ${hist}"
    if ((DRY_RUN)); then
        info "[dry-run] Would back it up and extract the readable strings in place."
        return 0
    fi
    if ! have strings; then
        warn "'strings' (binutils) not found; cannot repair ${hist}. A manual fix: back it up, then start a fresh shell."
        return 1
    fi

    local owner mode tmp
    owner="$(stat -c '%U:%G' -- "$hist" 2>/dev/null || printf 'root:root')"
    mode="$(stat -c '%a' -- "$hist" 2>/dev/null || printf '600')"
    backup_file "$hist"

    # Temp file beside the target: same filesystem (atomic mv) and no
    # predictable name in a shared /tmp.
    tmp="$(mktemp "${hist}.fkali.XXXXXX")" || { warn "mktemp failed for ${hist}."; return 1; }
    if strings -- "$hist" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
        if mv -- "$tmp" "$hist"; then
            chown "$owner" -- "$hist" 2>/dev/null || warn "Could not restore ownership (${owner}) on ${hist}."
            chmod "$mode" -- "$hist" 2>/dev/null || warn "Could not restore permissions (${mode}) on ${hist}."
            info "Repaired ${hist} (original kept as ${hist}${BACKUP_SUFFIX}). Note: extended-history timestamps may be lost."
            return 0
        fi
    fi
    warn "Could not repair ${hist}; original left untouched."
    rm -f -- "$tmp"
    return 1
}

repair_histories() {
    info "Validating shell history files..."
    local real_user="${SUDO_USER:-${USER:-root}}"
    local user_home
    user_home="$(home_of "$real_user")"
    [[ -n "$user_home" ]] || user_home="/root"

    local -A seen=()
    local -a homes=()
    local home
    for home in "$user_home" "/root"; do
        if [[ -n "$home" && -z "${seen[$home]:-}" ]]; then
            seen["$home"]=1
            homes+=("$home")
        fi
    done

    for home in "${homes[@]}"; do
        repair_one_history "${home}/.zsh_history" || true
    done
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary() {
    local disk_usage post_apt_cache post_logs
    disk_usage="$(df -h / 2>/dev/null | awk 'NR==2 {print $5}')"
    post_apt_cache="$(dir_size /var/cache/apt)"
    post_logs="$(dir_size /var/log)"

    printf '\n--------------------------------------------------\n'
    if ((DRY_RUN)); then
        printf '%b\n' "${C_GREEN}DRY-RUN COMPLETE: nothing was changed.${C_OFF}"
    else
        printf '%b\n' "${C_GREEN}SUCCESS: KALI IS HEALED${C_OFF}"
    fi
    printf 'APT cache:      %s -> %s\n' "$PRE_APT_CACHE" "$post_apt_cache"
    printf 'User cache:     %s (not cleaned; informational only)\n' "$PRE_USER_CACHE"
    printf '/var/log:       %s -> %s\n' "$PRE_LOG_SIZE" "$post_logs"
    printf 'Disk usage (/): %s\n' "${disk_usage:-unknown}"
    printf 'Warnings:       %d\n' "$WARNINGS"
    if ((DO_LOG && DRY_RUN == 0)); then
        printf 'Log file:       %s\n' "$LOG_FILE"
    else
        printf 'Log file:       (disabled)\n'
    fi
    if ((INSTALL_TOOLS == 0 && DRY_RUN == 0)); then
        printf 'Tip: run with --install-tools to add forensics/web/reverse-engineering metapackages.\n'
    fi
    printf 'Backups of any changed config files end in: %s\n' "$BACKUP_SUFFIX"
    printf '%s\n' '--------------------------------------------------'
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    printf '%b  %s\n' "${C_GREEN}fkali ${VERSION}${C_OFF}" "— Kali Linux self-healing script"
    info "Date: $(date -Is)"
    ((DRY_RUN)) && info "Mode: DRY-RUN (no changes will be made)"

    confirm_or_exit

    progress 5 "Pre-flight checks"
    check_os
    check_required_tools
    check_disk_space
    check_connectivity
    wait_for_apt_locks
    measure_sizes
    note_apt_listbugs

    progress 15 "Fixing mirrors & signing key (deb822)"
    choose_mirror
    install_keyring
    write_sources "$CHOSEN_MIRROR"
    report_duplicate_sources

    progress 30 "Repairing broken dependencies & package database"
    repair_and_update

    progress 50 "Core system upgrade"
    perform_upgrade

    progress 65 "Filesystem checks & cache rebuild"
    report_broken_symlinks
    rebuild_caches

    progress 75 "Essential metadata & optional tools"
    reinstall_keyring_package
    install_tool_metapackages

    progress 90 "Deep cleaning"
    deep_clean

    progress 95 "History repair & filesystem sync"
    repair_histories
    run sync || warn "sync failed."

    progress 100 "Done"
    print_summary
    return 0
}

# Only run when executed, not when sourced (keep the functions above
# unit-testable: `source ./fkali.sh` must have no side effects beyond
# defining functions/variables).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    parse_args "$@"
    ensure_privileges

    if ((DO_LOG && DRY_RUN == 0)); then
        log_dir="$(dirname -- "$LOG_FILE")"
        if mkdir -p -- "$log_dir" 2>/dev/null && touch -- "$LOG_FILE" 2>/dev/null; then
            # Run main through tee: the log is flushed before we read
            # PIPESTATUS, unlike the old `exec > >(tee ...)` which could
            # lose the final lines when the script exited.
            main 2>&1 | tee -a -- "$LOG_FILE"
            exit "${PIPESTATUS[0]}"
        fi
        printf '[!] WARNING: Cannot write log file %s; continuing without logging.\n' "$LOG_FILE" >&2
    fi

    main
    exit $?
fi
