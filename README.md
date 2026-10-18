# fkali

**Kali Linux self-healing & maintenance script** — `fkali.sh`
![CI](https://github.com/Mr-Nobody-Anonymous/fkali/actions/workflows/ci.yml/badge.svg)

`fkali.sh` is a single, dependency-light Bash script that repairs the things
that most commonly break a Kali Linux installation — APT sources and signing
keys, held package-manager locks, interrupted installs, broken dependencies,
a damaged dpkg database, cache/journal bloat, and corrupted shell history —
then performs a full system upgrade and prints a summary.

Current version: **2.0.0** (see [CHANGELOG.md](CHANGELOG.md))

---

## Quick start

> ⚠️ **Read the script before running it.** It runs as root and modifies
> system files. It is written to back everything up, ask first, and offer a
> `--dry-run` preview — but it is still a powerful tool, intended for
> **Kali Linux only**.

```bash
git clone https://github.com/Mr-Nobody-Anonymous/fkali.git
cd fkali

./fkali.sh --dry-run     # safe preview: prints every action, changes nothing
sudo ./fkali.sh          # heal + upgrade + clean (asks for confirmation)
sudo ./fkali.sh --yes    # same, without the confirmation prompt
```

If you forget `sudo`, the script re-runs itself via `sudo` (and will prompt
for your password as usual — passwordless sudo is **not** required).

### Requirements

- Kali Linux (the script checks `/etc/os-release` and refuses to run on
  other systems unless you pass `--force`)
- `bash`, `apt-get` / `dpkg`, and root privileges (via `sudo`)
- An internet connection
- Optional but recommended: `curl` or `wget`, `gpg`, `fuser` (`psmisc`),
  `strings` (`binutils`) — the script warns and skips steps gracefully
  when these are missing

---

## Usage

```
Usage: sudo ./fkali.sh [OPTIONS]
```

| Option | Description |
| --- | --- |
| `-h`, `--help` | Show help and exit |
| `-V`, `--version` | Show version and exit |
| `-n`, `--dry-run` | Print what would be done; change nothing. Needs no root and no Kali system |
| `-y`, `--yes` | Skip the confirmation prompt |
| `--install-tools` | Also install tool metapackages: `kali-linux-large`, `kali-tools-forensics`, `kali-tools-web`, `kali-tools-reverse-engineering` (and `kali-tools-malware` when the release provides it) |
| `--no-upgrade` | Skip the `apt-get full-upgrade` step |
| `--no-clean` | Skip autoremove / cache / log cleanup |
| `--mirror URL` | Use this mirror base instead of auto-detecting (e.g. `--mirror http://kali.download/kali`) |
| `--vacuum-days N` | Delete journal entries and rotated logs older than `N` days (default: `7`) |
| `--log FILE` | Log all output to `FILE` (default: `/var/log/kali_self_heal.log`) |
| `--no-log` | Terminal output only; write no log file |
| `--force` | Run even if the system does not identify as Kali (Debian-based only; use with care) |

Environment variables: `FKALI_MIRROR` (= `--mirror`), `FKALI_LOG_FILE`
(= `--log`), `NO_COLOR` (disable coloured output).

### Examples

```bash
sudo ./fkali.sh                                  # standard heal + upgrade + clean
sudo ./fkali.sh --install-tools                  # …plus forensics/web/RE tool categories
sudo ./fkali.sh --no-upgrade --vacuum-days 3     # repair & aggressive log cleanup, no upgrade
sudo ./fkali.sh --mirror http://kali.download/kali --no-log
./fkali.sh --dry-run                             # preview on any machine, no root needed
```

---

## What does it do?

1. **Pre-flight checks** — verifies it's really Kali, that required tools
   and (roughly) enough free disk exist, and that the machine is online
   (ICMP first, then a real HTTP probe of the Kali mirror, since ping is
   blocked on some networks). If another apt/dpkg process is running, it
   **waits** for it (up to 120 s) instead of touching lock files.
2. **Fixes mirrors & signing key** — probes the official redirector
   `http://http.kali.org/kali`, falls back to the official CDN mirror
   `http://kali.download/kali` if it's unreachable, downloads the current
   Kali archive keyring, **verifies it contains the expected 2025 signing
   key before installing it**, and writes the modern deb822 sources file
   `/etc/apt/sources.list.d/kali.sources`. A legacy `kali-rolling` line in
   `/etc/apt/sources.list` is commented out (it would now be a duplicate);
   any other repositories you added there are left untouched.
3. **Repairs the package database** — restores `/var/lib/dpkg/status` from
   `/var/backups` if it's missing/empty, finishes interrupted installs
   (`dpkg --configure -a`), updates package lists with retries, and fixes
   broken dependencies (`apt-get install -f`).
4. **Full system upgrade** — `apt-get full-upgrade`, non-interactively
   (existing config files are kept), with retries for transient mirror
   failures.
5. **Filesystem checks & cache rebuild** — reports (never auto-deletes)
   broken symlinks in `/usr/bin`, `/usr/local/bin`, `/usr/sbin`, and
   rebuilds the locate, man, linker (`ldconfig`), font, and desktop/icon
   caches when the tools are present.
6. **Essential metadata & optional tools** — reinstalls the
   `kali-archive-keyring` package, and with `--install-tools`, installs the
   tool-category metapackages listed above (each is probed for existence
   first, so missing ones are skipped, not fatal).
7. **Deep cleaning** — `autoremove --purge`, clears the APT package cache,
   purges leftover config files of already-removed packages (the `rc`
   dpkg state), vacuums the journal, and deletes **rotated** logs older
   than `--vacuum-days`. Old kernels are only *reported*, never removed.
8. **Shell history repair** — detects NUL-byte corruption in
   `~/.zsh_history` (for your user and root), backs the file up, extracts
   the readable history, and restores the original owner/permissions.
   Healthy history files are left completely alone.
9. **Summary** — before/after cache and log sizes, disk usage, warning
   count, and where the log and backups are.

### Why the sources and key handling changed (2025/2026)

- Kali rolled a **new archive signing key in April 2025**
  (fingerprint `827C8569F2518CC677FECA1AED65462EC8D5E4C5`). Systems still
  trusting only the old key fail with *"Missing key 827C8569…"* on
  `apt update`. fkali installs the official
  [`archive-keyring.gpg`](https://www.kali.org/blog/new-kali-archive-signing-key/)
  to `/usr/share/keyrings/kali-archive-keyring.gpg` and checks the
  fingerprint before trusting it.
- Since **Kali 2026.2**, the default APT configuration is the deb822 file
  [`/etc/apt/sources.list.d/kali.sources`](https://www.kali.org/docs/general-use/kali-apt-sources/)
  instead of a one-line entry in `/etc/apt/sources.list`, with the key
  referenced per-repository via `Signed-By:` instead of the global
  `/etc/apt/trusted.gpg.d/`. fkali now writes that format (it also works
  on older Kali releases — APT has understood deb822 for years) and
  migrates the legacy entry for you.

---

## Safety: what fkali will *not* do

Older versions of this script did a few dangerous things. Version 2.0.0
deliberately does **not**:

- ❌ **Delete APT/dpkg lock files.** Modern locks are held with `flock`;
  deleting the file doesn't release the lock and can corrupt the package
  database if a process really is running. fkali waits, then tells you
  how to proceed.
- ❌ **Truncate active log files** or delete *all* rotated logs regardless
  of age. Only rotated logs older than `--vacuum-days` (default 7) go.
- ❌ **Overwrite a working keyring with a failed download.** The keyring is
  downloaded to a temp file and fingerprint-checked first; on failure the
  existing keyring is left byte-for-byte intact.
- ❌ **Overwrite your whole `/etc/apt/sources.list`.** Only the Kali line
  is migrated; third-party repositories you added survive.
- ❌ **Remove old kernels or broken symlinks automatically.** Both can
  break your system if guessed wrong, so they're reported with the exact
  manual command instead.
- ❌ **Tamper with `apt-listbugs` configuration.** (A previous version
  installed a broken apt hook for it; that's gone.)

And before it changes any config file, it keeps a copy (see below).

### Backups & logging

- Every modified config file is first copied next to the original with a
  timestamped suffix, e.g.
  `/etc/apt/sources.list.d/kali.sources.fkali-backup-20261018-143000`.
  To undo a change: `sudo cp <file>.fkali-backup-<timestamp> <file>`.
- All output is logged to `/var/log/kali_self_heal.log` by default
  (change with `--log FILE`, disable with `--no-log`).

---

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| *"Another apt/dpkg process still holds a lock"* | Close Synaptic/other package managers, or wait for `unattended-upgrades` to finish, then re-run. Never delete lock files by hand. |
| *"Missing key 827C8569F2518CC677FECA1AED65462EC8D5E4C5"* | This is the 2025 signing-key rollover. fkali fixes it automatically; the manual fix is `sudo wget https://archive.kali.org/archive-keyring.gpg -O /usr/share/keyrings/kali-archive-keyring.gpg`. |
| Mirror connection errors (`Could not connect to …`) | Transient redirector/mirror problems are retried automatically. To pin the CDN mirror: `sudo ./fkali.sh --mirror http://kali.download/kali`. |
| *"This does not look like Kali Linux"* | The script is Kali-only by design. On a Debian-based system you are sure about, use `--force` — after a `--dry-run` review. |
| Upgrade stalls on bug reports / `503` from a bug server | `apt-listbugs` is asking interactively. Run the failing `apt-get` command by hand once, or remove `apt-listbugs`. fkali deliberately doesn't reconfigure it. |
| Low-disk-space warning | Free space (old VMs, ISOs, `~/.cache`), then re-run. fkali warns below 2 GiB free on `/`. |
| Anything else | Check `/var/log/kali_self_heal.log` (or your `--log` file) — the full apt/dpkg output is in there. |

---

## Repository layout

```
.
├── fkali.sh            # the script (only file you need to copy to a Kali box)
├── tests/
│   └── fkali_test.sh   # unit tests for the script's internal functions
├── README.md           # this file
├── CHANGELOG.md        # release history
└── LICENSE             # MIT
```

Earlier versions shipped three near-identical, diverging scripts
(`fkali.sh`, `fnew.sh`, `fkali-old.sh`). In 2.0.0 they were merged into the
single `fkali.sh`; everything `fnew.sh` added (retries, mirror fallback,
dpkg-status recovery, broken-symlink scan, cache rebuilds,
`--install-tools`, …) is included. The old files remain available in git
history, e.g.:

```bash
git show 9db9f9f:fnew.sh > fnew.sh   # recover the pre-2.0.0 draft, if ever needed
```

## Development

No build step — it's one Bash script. Before submitting a change, run:

```bash
bash -n fkali.sh tests/fkali_test.sh     # syntax check
shellcheck fkali.sh tests/fkali_test.sh  # lint — must be clean (enforced by CI)
./tests/fkali_test.sh                    # unit tests (sandboxed, no root needed)
./fkali.sh --dry-run                     # smoke test — must exit 0, change nothing
```

GitHub Actions (`.github/workflows/ci.yml`) runs exactly these checks on
every push and pull request. The unit tests work because `fkali.sh` is
safe to `source`: execution only starts when the file is run directly.

---

## Disclaimer

This script modifies critical system files (`/etc/apt/…`, the dpkg
database) and runs a full upgrade. It is designed for **Kali Linux**, is
provided as-is under the MIT license, and — like any root shell script —
should be reviewed before use, ideally tested in a VM or snapshot first.
You are responsible for your own system (and for using Kali only on
systems you're authorized to test).

## License

MIT — see [LICENSE](LICENSE).

**Happy hacking!** 🐉
