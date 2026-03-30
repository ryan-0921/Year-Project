## Section 7 (System Maintenance) - Implementation Complete

### Overview

All subsections of CIS Benchmark Section 7 **“System Maintenance”** have been implemented in `cis_hardening.sh`:

- **7.1 System File Permissions**
- **7.2 Local User and Group Settings**

Section 7.3 and 7.4 (automated OS and application patch management) are high-level operational practices and are treated as **manual** processes outside the scope of this system configuration script.

### 7.1 System File Permissions ✅

The script enforces CIS-recommended ownership and permission settings for critical system files:

- **7.1.1** – `/etc/passwd`  
  - Ensures mode `0644` (or more restrictive) and owner/group `root:root`.
- **7.1.2** – `/etc/passwd-` (backup)  
  - Ensures mode `0644` (or more restrictive) and owner/group `root:root` (if present).
- **7.1.3** – `/etc/group`  
  - Ensures mode `0644` (or more restrictive) and owner/group `root:root`.
- **7.1.4** – `/etc/group-` (backup)  
  - Ensures mode `0644` (or more restrictive) and owner/group `root:root` (if present).
- **7.1.5** – `/etc/shadow`  
  - Ensures mode `0640` (or more restrictive), owner `root`, group `root` or `shadow`.
- **7.1.6** – `/etc/shadow-` (backup)  
  - Ensures mode `0640` (or more restrictive), owner `root`, group `root` or `shadow` (if present).
- **7.1.7** – `/etc/gshadow`  
  - Ensures mode `0640` (or more restrictive), owner `root`, group `shadow` (if present).
- **7.1.8** – `/etc/gshadow-` (backup)  
  - Ensures mode `0640` (or more restrictive), owner `root`, group `shadow` (if present).
- **7.1.9** – `/etc/shells`  
  - Ensures mode `0644` (or more restrictive), owner/group `root:root` (if present).
- **7.1.10** – `/etc/security/opasswd` and `/etc/security/opasswd.old`  
  - Ensures mode `0600` (or more restrictive), owner/group `root:root` (if present).

The script also includes **detection-only** implementations (with manual remediation guidance) for:

- **7.1.11** – World-writable files and directories  
  - Detects world-writable files and world-writable directories missing the sticky bit, logs findings, and returns non-compliant.
- **7.1.12** – Files/directories without an owner or group  
  - Detects `-nouser` / `-nogroup` paths and logs them for remediation.
- **7.1.13** – SUID/SGID file review (Manual)  
  - Logs that periodic review is required; does not attempt automatic modification.

### 7.2 Local User and Group Settings ✅

The script covers all 7.2.x recommendations:

- **7.2.1** – Accounts in `/etc/passwd` use shadowed passwords  
  - Detects accounts without `x` in the password field and uses `pwconv` (where available) to migrate to `/etc/shadow`.
- **7.2.2** – `/etc/shadow` password fields are not empty  
  - Detects accounts with empty password hashes and (optionally) locks them via `passwd -l` (respecting `DRY_RUN` mode).
- **7.2.3** – All groups in `/etc/passwd` exist in `/etc/group` (detection only)  
  - Reports users whose primary GID is missing from `/etc/group`.
- **7.2.4** – `shadow` group is empty  
  - Ensures no extra members are listed in the `shadow` group; reports any findings for manual cleanup.
- **7.2.5–7.2.8** – No duplicate UIDs, GIDs, user names, or group names (detection only)  
  - Detects duplicates and logs them; remediation (reassigning IDs/names and fixing ownerships) is left to administrators.
- **7.2.9** – Local interactive user home directories are configured  
  - Identifies **local interactive users** by login shell (excluding `nologin`/`false`).  
  - Ensures each home directory exists, is owned by the user, and has no group/other write permissions.  
  - Remediation adjusts ownership and removes group/other write bits where needed.
- **7.2.10** – Local interactive user dot files access is configured (detection only)  
  - For each interactive user, flags:
    - Presence of `.forward` and `.rhost` files  
    - `.netrc` or `.bash_history` files that are more permissive than mode `0600`  
  - Logs findings; concrete clean-up actions are left to site policy.

### Wiring and Usage

- `check_compliance` and `apply_hardening` both have a **Section 7** case that runs all 7.1.x and 7.2.x controls.
- Individual 7.x section numbers (e.g. `7.1.5`, `7.2.9`) are wired into the generic dispatch so they can be run independently.
- `verify_hardening` uses `check_compliance "7"` when Section 7 is processed via `process_section`.

#### Example Usage

```bash
# Process entire Section 7
sudo bash cis_hardening.sh 7

# Process only system file permissions (7.1.x)
sudo bash cis_hardening.sh 7.1.1,7.1.2,7.1.3,7.1.4,7.1.5,7.1.6,7.1.7,7.1.8,7.1.9,7.1.10

# Process local user/group consistency (7.2.x)
sudo bash cis_hardening.sh 7.2.1,7.2.2,7.2.3,7.2.4,7.2.5,7.2.6,7.2.7,7.2.8,7.2.9,7.2.10

# Dry-run mode
sudo bash cis_hardening.sh --dry-run 7
```

### Notes

- Potentially disruptive actions (changing world-writable files, resolving duplicate IDs, removing SUID/SGID bits, or altering user dot files) are **reported but not auto-remediated**, in line with CIS guidance that these require local policy decisions.
- All remediation functions respect the global `DRY_RUN` flag used elsewhere in the script.

