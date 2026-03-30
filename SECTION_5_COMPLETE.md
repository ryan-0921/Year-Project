## Section 5 (Access Control – SSH Server) - Implementation Complete

### Overview

All subsections of CIS Benchmark Section 5 **“Access Control”**, specifically **5.1 Configure SSH Server**, have been fully implemented in `cis_hardening.sh`.

The implementation uses `sshd -T` to evaluate the **effective** SSH daemon configuration (including `Include` and `Match` blocks) and then enforces CIS‑recommended settings while allowing some configurability for cryptographic algorithms.

### Implementation Summary

#### 5.1.1–5.1.3 SSH configuration and host key permissions ✅

- **5.1.1** – Ensure permissions on `/etc/ssh/sshd_config` and `*.conf` in `/etc/ssh/sshd_config.d` are:
  - Mode **0600**
  - Owned by `root:root`
- **5.1.2** – Ensure permissions on SSH **private host key** files:
  - Files matching `/etc/ssh/*_key` (excluding `*.pub`)  
  - Mode **[0-7]00** (no group/other bits) and owned by `root:root`
- **5.1.3** – Ensure permissions on SSH **public host key** files:
  - Files matching `/etc/ssh/*.pub`  
  - Mode matching `^[0-7][0-4][0-4]$` (no group/other write/exec) and owned by `root:root`

#### 5.1.4 SSH access controls (Manual policy) ✅

- **5.1.4** – Ensure sshd access is configured:
  - Compliance check verifies that at least one of `AllowUsers`, `AllowGroups`, `DenyUsers`, or `DenyGroups` is present in the effective config.
  - Remediation is **manual by design**: the script logs guidance but does not guess your user/group policy.

#### 5.1.5 Banner configuration ✅

- **5.1.5** – Ensure `Banner /etc/issue.net` is configured:
  - Uses `sshd -T` to check `banner` option.
  - Ensures `/etc/issue.net` exists and is set to **644 root:root**.

#### 5.1.6, 5.1.12, 5.1.15 – Ciphers, KEX, and MACs (with selectable profiles) ✅

The script supports **two profiles** for each of Ciphers, MACs, and KEX algorithms, controlled via environment variables:

- **Profiles**
  - `SSHD_CIPHERS_PROFILE`: `cis_strict` (default) or `extended`
  - `SSHD_MACS_PROFILE`: `cis_strict` (default) or `extended`
  - `SSHD_KEX_PROFILE`: `cis_strict` (default) or `extended`

- **Ciphers (5.1.6)**
  - `cis_strict`:  
    `chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr`
  - `extended`:  
    `chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr`

- **KEX algorithms (5.1.12)**
  - `cis_strict`:  
    `curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256`
  - `extended`:  
    same as above **plus** `diffie-hellman-group14-sha256`

- **MACs (5.1.15)**
  - `cis_strict`:  
    `hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com`
  - `extended`:  
    same as above **plus** `hmac-sha1` for broader legacy compatibility

Each check compares the **effective** `sshd -T` value to the profile’s expected string, and remediation writes a single canonical value into `/etc/ssh/sshd_config`.

#### 5.1.7–5.1.22 Remaining SSH daemon controls ✅

All other 5.1.x items are implemented via `sshd -T` checks and direct modifications to `sshd_config`:

- **5.1.7** – `ClientAliveInterval 300`, `ClientAliveCountMax 3`
- **5.1.8** – `DisableForwarding yes`
- **5.1.9** – `GSSAPIAuthentication no`
- **5.1.10** – `HostbasedAuthentication no`
- **5.1.11** – `IgnoreRhosts yes`
- **5.1.13** – `LoginGraceTime 60`
- **5.1.14** – `LogLevel VERBOSE`
- **5.1.16** – `MaxAuthTries 4`
- **5.1.17** – `MaxSessions 10`
- **5.1.18** – `MaxStartups 10:30:60`
- **5.1.19** – `PermitEmptyPasswords no`
- **5.1.20** – `PermitRootLogin no` (check allows `no` or `prohibit-password`, remediation enforces `no`)
- **5.1.21** – `PermitUserEnvironment no`
- **5.1.22** – `UsePAM yes`

All checks **short‑circuit** if `openssh-server` is not installed, as allowed by the benchmark (server without SSH can skip Section 5).

### Helper Functions

- `sshd_installed()` – Detects if the `openssh-server` package is installed.
- `get_sshd_effective_config()` / `get_sshd_effective_value(key)` – Wrap `sshd -T -C user=root,addr=127.0.0.1,lport=22` to read effective configuration (including `Include` and `Match` blocks).
- `set_sshd_config_option(key, value)` – Safely ensures `/etc/ssh/sshd_config` exists, backs it up, and sets or replaces the given directive.
- `get_sshd_ciphers_expected()`, `get_sshd_macs_expected()`, `get_sshd_kex_expected()` – Return profile‑specific expected values for Ciphers, MACs, and KEX algorithms.

### Wiring and Usage

- Section 5 is fully wired into:
  - `check_compliance` (case `5` and per‑subsection `5.1.x` dispatch)
  - `apply_hardening` (case `5` and per‑subsection `5.1.x` dispatch)
  - `verify_hardening` via `check_compliance "5"` when section 5 is requested.

#### Running Section 5

```bash
# Process entire Section 5 (all SSH controls)
sudo bash cis_hardening.sh 5

# Process a specific SSH control
sudo bash cis_hardening.sh 5.1.5    # Banner
sudo bash cis_hardening.sh 5.1.20   # PermitRootLogin

# Use extended crypto profiles
export SSHD_CIPHERS_PROFILE=extended
export SSHD_MACS_PROFILE=extended
export SSHD_KEX_PROFILE=extended
sudo bash cis_hardening.sh 5

# Dry‑run mode
sudo bash cis_hardening.sh --dry-run 5
```

### Notes

- **Manual policy (5.1.4)** – The script validates that some access control (`AllowUsers`/`AllowGroups`/`DenyUsers`/`DenyGroups`) is present but does not enforce a specific user list; this must align with your site policy.
- **Crypto compatibility** – Use the `extended` profiles when you must support older SSH clients; otherwise, `cis_strict` keeps you close to the CIS recommendations.
- **Service detection** – All checks and remediation in Section 5 are no‑ops when `openssh-server` is not installed, as permitted by the benchmark.

