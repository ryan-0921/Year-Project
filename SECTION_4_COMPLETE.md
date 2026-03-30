## Section 4 (Host Based Firewall) - Implementation Complete

### Overview

All subsections of CIS Benchmark Section 4 **“Host Based Firewall”** have been fully implemented in `cis_hardening.sh`.

The implementation follows the benchmark guidance to ensure that **exactly one** host-based firewall utility is in use (`ufw`, `nftables`, or `iptables`), and then applies the appropriate checks and remediation only for the active firewall.

### Implementation Summary

#### 4.1 Configure a single firewall utility ✅
- **4.1.1** – Ensure a single firewall configuration utility is in use  
  - Helper `get_active_firewall` detects the active firewall based on commands and systemd state.  
  - Hardening prefers **ufw** as the default if none/ambiguous, and disables/masks other firewall utilities to avoid conflicts.

#### 4.2 Configure UncomplicatedFirewall (UFW) ✅
Applies **only when `ufw` is detected as the active firewall**:

- **4.2.1** – Ensure `ufw` is installed  
- **4.2.2** – Ensure `iptables-persistent` is not installed with `ufw`  
- **4.2.3** – Ensure `ufw` is enabled and active  
- **4.2.4** – Ensure loopback traffic is configured correctly (allow `lo`, drop 127.0.0.0/8 and ::1)  
- **4.2.5** – Outbound connections (Manual – script logs guidance only)  
- **4.2.6** – Ensure firewall rules exist for all open ports (compares `ss` output with `ufw status`)  
- **4.2.7** – Ensure default deny policy for incoming, outgoing, and routed traffic

#### 4.3 Configure nftables ✅
Applies **only when `nftables` is detected as the active firewall**:

- **4.3.1** – Ensure `nftables` is installed  
- **4.3.2** – Ensure `ufw` is not in use with `nftables`  
- **4.3.3** – Flush iptables rules (Manual – script logs guidance only)  
- **4.3.4** – Ensure an `inet filter` table exists  
- **4.3.5** – Ensure base chains (input, forward, output) are defined with appropriate hooks  
- **4.3.6** – Ensure loopback traffic is configured and loopback source addresses are dropped  
- **4.3.7** – Outbound/established nftables rules (Manual – script logs guidance only)  
- **4.3.8** – Ensure default deny policy in nftables  
- **4.3.9** – Ensure `nftables.service` is enabled and active  
- **4.3.10** – Ensure nftables rules are persistent (e.g. via `/etc/nftables.conf` include)

#### 4.4 Configure iptables / ip6tables ✅
Applies **only when iptables via `netfilter-persistent` is the active firewall**:

- **4.4.1.1** – Ensure `iptables` and `iptables-persistent` packages are installed  
- **4.4.1.2** – Ensure `nftables` is not in use with iptables  
- **4.4.1.3** – Ensure `ufw` is not in use with iptables  

IPv4 rules:
- **4.4.2.1** – Ensure default deny firewall policy (INPUT/FORWARD/OUTPUT = DROP/REJECT)  
- **4.4.2.2** – Ensure loopback traffic is configured and allowed  
- **4.4.2.3** – Outbound/established iptables rules (Manual – script logs guidance only)  
- **4.4.2.4** – Ensure iptables rules exist for open ports (simplified compliance check)

IPv6 rules:
- **4.4.3.1** – Ensure default deny firewall policy for ip6tables  
- **4.4.3.2** – Ensure loopback traffic is configured and allowed for ip6tables  
- **4.4.3.3** – Outbound/established ip6tables rules (Manual – script logs guidance only)  
- **4.4.3.4** – Ensure ip6tables rules exist for open ports (simplified compliance check)

### Helper Functions and Behaviour

- **`get_active_firewall`** – Detects which firewall utility is active (`ufw`, `nftables`, `iptables`) by combining `command -v` with `systemctl is-enabled` / `systemctl is-active`.  
- Manual items (4.2.5, 4.3.3, 4.3.7, 4.4.2.3, 4.4.3.3) are implemented as **non-blocking**: they log guidance but do not enforce a particular policy.
- All Section 4 checks and applies are wired into:
  - `check_compliance` (case `4` and per‑subsection dispatch)
  - `apply_hardening` (case `4` and per‑subsection dispatch)
  - `verify_hardening` via `check_compliance "4"` when section 4 is requested.

### Usage

```bash
# Process entire Section 4
sudo bash cis_hardening.sh 4

# Process a specific subsection
sudo bash cis_hardening.sh 4.2.3
sudo bash cis_hardening.sh 4.3.6

# Dry‑run mode
sudo bash cis_hardening.sh --dry-run 4
```

### Notes

- **Single Firewall Only**: The script enforces that only one of `ufw`, `nftables`, or `iptables` is active to avoid conflicting rules.  
- **Service‑aware**: UFW, nftables, and iptables logic is only applied when that firewall is the active utility; others are skipped with informative logs.  
- **Lock‑out Risk**: As with the CIS benchmark, applying firewall changes on remote systems can cause lock‑outs. Use `--dry-run` first and ensure you have console or out‑of‑band access.

