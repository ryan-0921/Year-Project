## Section 6 (Logging and Auditing) - Implementation Complete

### Overview

All subsections of CIS Benchmark Section 6 **“Logging and Auditing”** have been implemented in `cis_hardening.sh`.

The script configures **system logging (journald/rsyslog)**, **auditd service, data retention, rules**, and **integrity checking** in accordance with the benchmark, and wires all 6.x controls into the standard `check_compliance`, `apply_hardening`, and `verify_hardening` flows.

### 6.1 System Logging ✅

#### 6.1.1 Configure systemd‑journald service
- **6.1.1.1** – journald service enabled and active.  
- **6.1.1.2** – journald log file access (Manual – script logs guidance).  
- **6.1.1.3** – journald log file rotation (Manual – script logs guidance).  
- **6.1.1.4** – Only one logging system in use (journald vs. rsyslog).

#### 6.1.2 Configure journald
- **6.1.2.1.1** – `systemd-journal-remote` installed (if used).  
- **6.1.2.1.2** – `systemd-journal-upload` authentication configured (Manual).  
- **6.1.2.1.3** – `systemd-journal-upload` enabled and active.  
- **6.1.2.1.4** – `systemd-journal-remote` service not in use when not required.  
- **6.1.2.2** – `ForwardToSyslog` disabled when rsyslog is not the primary logger.  
- **6.1.2.3** – `Compress` configured.  
- **6.1.2.4** – `Storage` configured appropriately (e.g. `persistent`).

#### 6.1.3 Configure rsyslog
- **6.1.3.1** – rsyslog installed.  
- **6.1.3.2** – rsyslog service enabled and active.  
- **6.1.3.3** – journald configured to send logs to rsyslog (when rsyslog is in use).  
- **6.1.3.4** – rsyslog log file creation mode configured.  
- **6.1.3.5** – rsyslog logging configuration (Manual – script logs guidance).  
- **6.1.3.6** – rsyslog remote log host configuration (Manual).  
- **6.1.3.7** – rsyslog not configured to receive remote logs, unless required.  
- **6.1.3.8** – logrotate configuration (Manual – script logs guidance).

#### 6.1.4 Configure logfiles
- **6.1.4.1** – Access to all log files under `/var/log` checked and remediated to reasonable permissions (no world‑writable, no inappropriate execute bits).

### 6.2 System Auditing (auditd) ✅

#### 6.2.1 Configure auditd service
- **6.2.1.1** – auditd packages installed.  
- **6.2.1.2** – auditd service enabled and active.  
- **6.2.1.3** – auditing for processes that start prior to auditd is enabled (kernel boot parameter).  
- **6.2.1.4** – `audit_backlog_limit` is sufficient.

#### 6.2.2 Configure data retention
- **6.2.2.1** – Audit log storage size configured.  
- **6.2.2.2** – Audit logs are not automatically deleted.  
- **6.2.2.3** – System disabled or appropriately handled when audit logs are full.  
- **6.2.2.4** – System warns when audit logs are low on space.

#### 6.2.3 Configure auditd rules

The script uses a central rules file (e.g. `AUDIT_CIS_RULES_FILE`) and helper functions to manage rules, implementing:

- **6.2.3.1** – Changes to system administration scope (sudoers).  
- **6.2.3.2** – Actions as another user are always logged.  
- **6.2.3.3** – Events that modify the sudo log file.  
- **6.2.3.4** – Date/time modification events.  
- **6.2.3.5** – Network environment modifications.  
- **6.2.3.6** – Use of privileged commands.  
- **6.2.3.7** – Unsuccessful file access attempts.  
- **6.2.3.8** – User/group information modification.  
- **6.2.3.9** – Discretionary access control (DAC) permission change events.  
- **6.2.3.10** – Successful filesystem mounts.  
- **6.2.3.11** – Session initiation information.  
- **6.2.3.12** – Login and logout events.  
- **6.2.3.13** – File deletion events.  
- **6.2.3.14** – Mandatory access control (MAC) policy changes.  
- **6.2.3.15** – Use of `chcon`.  
- **6.2.3.16** – Use of `setfacl`.  
- **6.2.3.17** – Use of `chacl`.  
- **6.2.3.18** – Use of `usermod`.  
- **6.2.3.19** – Kernel module loading/unloading.  
- **6.2.3.20** – Setting audit configuration immutable.  
- **6.2.3.21** – Additional distribution‑specific rules (as per CIS script guidance).

Each rule has a `check_compliance_6_2_3_x` that verifies presence in the audit rules file, and an `apply_hardening_6_2_3_x` that ensures the rule is present (respecting `DRY_RUN`).

#### 6.2.4 Audit log file permissions
- **6.2.4.1–6.2.4.4** – Permissions and ownership on `/var/log/audit` and `audit.log` enforced (e.g. `640 root:adm`, directory `750 root:adm`).  
- **6.2.4.5–6.2.4.7** – Permissions and ownership on `/etc/audit/auditd.conf` enforced (`640 root:root`).  
- **6.2.4.8–6.2.4.10** – Permissions and ownership on `aureport` binary (root:root, `755`).

### 6.3 File Integrity and Audit Tool Protection ✅

- **6.3.1** – File integrity tool is installed and configured (e.g. AIDE/alternative as per the benchmark).  
- **6.3.2** – Filesystem integrity is regularly checked (cron/systemd timer and config).  
- **6.3.3** – Cryptographic mechanisms are used to protect integrity of audit tools (e.g. checksums, package verification configuration).

### Wiring and Usage

- Section 6 is fully wired into:
  - `check_compliance` (case `6` and per‑subsection `6.x.y` patterns).  
  - `apply_hardening` (case `6` and per‑subsection `6.x.y` patterns).  
  - `verify_hardening` via `check_compliance "6"` when processing Section 6.

#### Example Usage

```bash
# Process entire Section 6
sudo bash cis_hardening.sh 6

# Process only logging (6.1.x)
sudo bash cis_hardening.sh 6.1.1.1,6.1.1.4,6.1.3.1,6.1.3.2,6.1.3.3,6.1.4.1

# Process only auditd (6.2.x)
sudo bash cis_hardening.sh 6.2.1.1,6.2.1.2,6.2.2.1,6.2.3.4,6.2.4.1

# Dry-run mode
sudo bash cis_hardening.sh --dry-run 6
```

### Notes

- Some sub‑controls are **manual** by design (e.g. journald log file access, rsyslog detailed configuration, logrotate policy); for these, the script logs findings and guidance but does not enforce a specific local policy.
- All Section 6 hardening paths respect the global `DRY_RUN` mode and use the central backup and reporting mechanisms shared across the script.

