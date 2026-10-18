# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-10-18

Major cleanup: the three diverging scripts were merged into one maintained
`fkali.sh`, modernized for current Kali (2025 signing key, 2026 deb822 APT
sources), and made considerably safer.

### Added

- `--dry-run` mode: prints every action and changes nothing; needs neither
  root nor a Kali system, so it doubles as a smoke test.
- `--help`, `--version`, argument validation (unknown options now exit
  with code 2 instead of being silently ignored).
- `--yes` (skip the new interactive confirmation), `--no-upgrade`,
  `--no-clean`, `--mirror URL`, `--vacuum-days N`, `--log FILE`,
  `--no-log`, and `--force` flags; `FKALI_MIRROR` / `FKALI_LOG_FILE` /
  `NO_COLOR` environment variables.
- Installs the **2025 Kali archive signing key** from the official
  `archive-keyring.gpg`, verifies its fingerprint
  (`827C8569F2518CC677FECA1AED65462EC8D5E4C5`) before installing it, and
  stores it at `/usr/share/keyrings/kali-archive-keyring.gpg`.
- Writes APT sources in the modern **deb822 format**
  (`/etc/apt/sources.list.d/kali.sources`, with `Signed-By:`), as used by
  Kali ≥ 2026.2, and migrates the legacy `/etc/apt/sources.list` entry.
- Timestamped backups (`<file>.fkali-backup-YYYYMMDD-HHMMSS`) before every
  config file the script modifies.
- Sanity checks: refuses to run on non-Kali systems (`/etc/os-release`),
  warns below 2 GiB free on `/`, and checks required tools up front.
- Recovers a missing `/var/lib/dpkg/status` from `/var/backups`
  (including the `.gz` variant), kept from `fnew.sh`.
- Warning counter and before/after sizes in the final summary; functional
  progress bar; colours only when writing to a terminal.
- `LICENSE` (the old README linked to one that didn't exist), this
  changelog, `.gitignore`, a unit-test suite (`tests/fkali_test.sh`,
  enabled by making the script safely sourceable), and a GitHub Actions
  CI workflow (`bash -n` + ShellCheck + unit tests + dry-run smoke test).

### Changed

- **Merged** `fkali.sh`, `fnew.sh`, and `fkali-old.sh` into a single
  script. The two extra files were removed (they remain in git history;
  see the README for how to recover them).
- No longer requires *passwordless* sudo: when run without privileges it
  re-executes itself via `sudo` and you get the normal password prompt.
  Once root, it stops prefixing everything with redundant `sudo` calls.
- Internet check no longer relies solely on `ping` (ICMP is often
  blocked): it also probes the Kali mirror over HTTP.
- Mirror health is probed by fetching `dists/kali-rolling/Release`
  instead of running a throwaway full `apt-get update` and grepping its
  log in a predictably named `/tmp` file.
- `retry()` no longer uses `eval` on a command string; it executes its
  arguments directly, so quoting can never break (or be abused).
- Journal/log retention is 7 days by default (configurable) instead of
  a hard-coded, evidence-destroying 1 day; cleanup reporting now shows
  real before/after sizes.
- Zsh history repair now detects corruption by scanning for NUL bytes
  (instead of the unreliable `file | grep data`), only touches files
  that are actually corrupt (no more backup litter on every run),
  preserves owner/mode after repair, de-duplicates the root home, and
  resolves home directories with `getent` instead of `eval echo ~user`.
- Logging runs through `main | tee`, so the final lines can no longer be
  lost when the script exits (the old `exec > >(tee …)` race).
  `fnew.sh` had logging disabled entirely; `--no-log` reproduces that.
- The script is now executable in git (`100755`), uses
  `#!/usr/bin/env bash`, and is ShellCheck-clean.

### Fixed

- The keyring pipeline masked download failures (`set -e` without
  `pipefail`, `$?` reporting `tee`'s status) and, when `wget` failed,
  truncated the keyring to an empty file — breaking APT completely.
  Downloads now go to a temp file and are verified before install.
- Unquoted variable expansions throughout (cache sizes, package lists,
  `stat`/`dirname` targets), and `grep -c`/command-substitution exits
  that could abort the script under `set -e`.
- `apt-get full-upgrade` could block on conffile prompts despite
  `DEBIAN_FRONTEND=noninteractive`; `--force-confdef`/`--force-confold`
  are now passed explicitly.
- User-cache size was measured for root's home when run under `sudo`;
  it's now measured for the invoking user.

### Removed (unsafe behaviour)

- **Deleting APT/dpkg lock files.** Locks are flock-based; `rm`-ing them
  releases nothing and risks database corruption. The script now waits
  for the other process and exits with guidance if it doesn't finish.
- **Truncating live log files > 50 MB** and deleting *all* rotated logs
  regardless of age. Only rotated logs older than `--vacuum-days` are
  deleted; active logs are left alone. The self-heal log is also no
  longer deleted while the script may still be writing to it.
- **Blindly overwriting `/etc/apt/sources.list`** (destroying any
  third-party repositories in it). Only the Kali line is migrated.
- The broken `apt-listbugs` `DPkg::Pre-Invoke` hook (it used a
  non-existent `--dont-stop` flag and silently rewired apt's config).
  The script now just prints an explanatory note when apt-listbugs is
  installed.
- Dropping the keyring into the legacy global trust store
  `/etc/apt/trusted.gpg.d/` in favour of `Signed-By:`.

### From the merged-away files, also fixed

- `fkali-old.sh`: blank line before the shebang (script couldn't be
  executed directly), the stray `clrae` command at the end, no root
  check, and `apt-get purge $(…)` blowing up when the package list was
  empty.

## [1.x] - 2026-07-04 and earlier

- `fkali.sh` / `fkali-old.sh`: original self-healing script — pre-flight
  checks, mirror/key repair, broken-dependency fixes, full upgrade,
  deep cleaning, and zsh history repair.
- `fnew.sh` draft: added retries, mirror fallback, dpkg-status recovery,
  broken-symlink scan, cache rebuilds, `--install-tools`, and extra log
  cleanup. All of this (in fixed form) lives on in 2.0.0.

[2.0.0]: https://github.com/Mr-Nobody-Anonymous/fkali/releases/tag/v2.0.0
