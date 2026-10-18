#!/usr/bin/env bash
# =============================================================================
# tests/fkali_test.sh — unit tests for fkali.sh's internal functions.
#
# fkali.sh is safe to source (it only runs when executed directly), which
# lets these tests exercise its real sources/history/retry/argument code
# against a temporary directory. Nothing outside the temp directory is
# modified, and no root or Kali system is required.
#
# Usage: ./tests/fkali_test.sh   (exit code 0 = all tests passed)
# =============================================================================
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091  # path is computed above; run shellcheck -x to follow it
source "${REPO_DIR}/fkali.sh"

FAILURES=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# check <description> <command> [args...]
check() {
    local desc="$1"
    shift
    if "$@"; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

TMPD="$(mktemp -d)"
trap 'rm -rf -- "$TMPD"' EXIT
mkdir -p "${TMPD}/etc"

# --- write_sources: deb822 output + legacy migration -------------------------
# Point the script at the sandbox instead of /etc/apt. These variables are
# read by the sourced fkali.sh functions (hence the SC2034 exemptions).
# shellcheck disable=SC2034
SOURCES_FILE="${TMPD}/etc/kali.sources"
# shellcheck disable=SC2034
LEGACY_SOURCES="${TMPD}/etc/sources.list"
cat >"$LEGACY_SOURCES" <<'EOF'
deb http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware
deb http://example.com/debian stable main
EOF
printf 'stale content\n' >"$SOURCES_FILE"

# shellcheck disable=SC2034
DRY_RUN=0
write_sources "http://http.kali.org/kali" >"${TMPD}/out1.txt" 2>&1

check "deb822 URIs written" \
    grep -qx 'URIs: http://http.kali.org/kali/' "$SOURCES_FILE"
check "Signed-By written" \
    grep -qx "Signed-By: ${KEYRING_PATH}" "$SOURCES_FILE"
check "Suites written" \
    grep -qx 'Suites: kali-rolling' "$SOURCES_FILE"
check "backup of previous sources exists" \
    test -f "${SOURCES_FILE}${BACKUP_SUFFIX}"
check "legacy kali line commented out" \
    grep -q '^# fkali: migrated .*-- deb http://http.kali.org/kali kali-rolling' "$LEGACY_SOURCES"
check "third-party repository preserved" \
    grep -qx 'deb http://example.com/debian stable main' "$LEGACY_SOURCES"

write_sources "http://http.kali.org/kali" >"${TMPD}/out2.txt" 2>&1
check "second run is idempotent" grep -q 'already correct' "${TMPD}/out2.txt"

# --- file_contains_nul / repair_one_history ----------------------------------
HISTF="${TMPD}/.zsh_history"
printf 'ls -la\necho hi\n' >"$HISTF"
if file_contains_nul "$HISTF"; then
    fail "clean history reported as corrupt"
else
    pass "clean history detected as healthy"
fi

printf 'echo one\0\0echo two\n' >"$HISTF"
chmod 640 "$HISTF"
check "corrupt (NUL) history detected" file_contains_nul "$HISTF"

if have strings; then
    repair_one_history "$HISTF" >"${TMPD}/out3.txt" 2>&1
    if file_contains_nul "$HISTF"; then
        fail "history still corrupt after repair"
    else
        pass "history repaired (NUL bytes gone)"
    fi
    check "history permissions preserved" test "$(stat -c %a "$HISTF")" = "640"
    check "history backup exists" test -f "${HISTF}${BACKUP_SUFFIX}"
    check "history content kept" grep -q 'echo' "$HISTF"
else
    printf 'SKIP: strings (binutils) not installed; history repair not tested\n'
fi

# --- retry (must not use eval) -----------------------------------------------
if retry 2 0 true; then
    pass "retry succeeds for a successful command"
else
    fail "retry succeeds for a successful command"
fi
if retry 2 0 false 2>/dev/null; then
    fail "retry should give up and fail for a failing command"
else
    pass "retry gives up and fails for a failing command"
fi

# --- parse_args ---------------------------------------------------------------
if ( parse_args --vacuum-days 3 --mirror https://kali.download/kali/ --no-clean
     [[ "$VACUUM_DAYS" == "3" && "$MIRROR" == "https://kali.download/kali" && "$DO_CLEAN" == "0" ]] ); then
    pass "parse_args stores values (trailing slash stripped)"
else
    fail "parse_args stores values"
fi

if ( parse_args --vacuum-days nope ) 2>/dev/null; then
    fail "parse_args accepted a non-numeric --vacuum-days"
else
    pass "parse_args rejects a non-numeric --vacuum-days"
fi

if ( parse_args --definitely-not-an-option ) 2>/dev/null; then
    fail "parse_args accepted an unknown option"
else
    pass "parse_args rejects unknown options"
fi

# --- summary ------------------------------------------------------------------
if ((FAILURES > 0)); then
    printf '\n%d test(s) FAILED\n' "$FAILURES" >&2
    exit 1
fi
printf '\nAll tests passed.\n'
exit 0
