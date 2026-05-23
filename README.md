# fkali

**ULTIMATE Kali Linux Self-Healing Script**

`fkali.sh` is an advanced, all-in-one maintenance and self-healing script for Kali Linux. It automatically troubleshoots and repairs common system issues related to package management, sources, keys, space usage, and log clutter with minimal user interaction.

---

## Features

- **Internet & Pre-flight Checks**: Ensures system has internet connectivity and is ready for self-repair.
- **Unlocks Package Manager**: Clears stuck dpkg/apt locks to fix "could not get lock" errors.
- **Repairs Sources & GPG Keys**: Fixes common issues with Kali repositories and signature verification.
- **Fixes Broken Packages**: Recovers from interrupted installs and resolves broken dependencies.
- **Safe System Upgrade**: Runs a comprehensive upgrade with best practices for dependency resolution.
- **Reinstalls Essential Packages**: Safely reinstalls essential keyring packages.
- **Deep Cleaning**: Clears unused packages, cleans apt cache, purges old logs, and removes obsolete kernels.
- **History & Filesystem Sync**: Repairs corrupted zsh history and flushes disk operations.

---

## Usage

> **Warning:** This script is intended for advanced users, system admins, or those who have read the code. It requires root privileges and is best used on a Kali Linux system.

```bash
curl -O https://raw.githubusercontent.com/Mr-Nobody-Anonymous/fkali/main/fkali.sh
chmod +x fkali.sh
sudo ./fkali.sh
```

---

## What Does It Do?

1. **Checks for Internet**  
   Exits if no connection is found (updates require network).

2. **Releases APT/DPKG Locks**  
   Removes potential lock files that can prevent package management.

3. **Repairs Mirrors & Keys**  
   Ensures `/etc/apt/sources.list` is valid and updates GPG keys.

4. **Repairs Broken Installs**  
   Completes interrupted installs, repairs package DB, and fetches missing updates.

5. **Performs System Upgrade**  
   Performs a safe, full system upgrade.

6. **Reinstalls Keyring**  
   Re-installs Kali's archive keyring if needed.

7. **Cleans System**  
   Removes unnecessary packages, shrinks the journal, cleans apt cache, and removes old kernels.

8. **Repairs ZSH History**  
   Attempts to recover broken `.zsh_history` files for regular and root users.

9. **Shows Recovery Summary**  
   At the end, you’ll see space recovered and the disk usage.

---

## Logging

- All actions, warnings, and errors are logged to:
  ```
  /var/log/kali_self_heal.log
  ```

---

## Troubleshooting

- If the script fails due to missing system requirements, update your system manually and rerun.
- For persistent issues, consult the log file for details.

---

## Disclaimer

- This script is highly opinionated and modifies critical system files (like sources.list).
- Only use on a Kali Linux system – not designed/tested for other distributions.
- Examine the code or run in a test environment before executing on production machines.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

---

**Happy Hacking!**
