# Section 2 (Services) - Implementation Complete

## Overview

All subsections of CIS Benchmark Section 2 "Services" have been fully implemented.

## Implementation Summary

### Section 2.1 - Configure Server Services (22 subsections) ✅

#### 2.1.1–2.1.19 Unused services not in use
- 2.1.1 - autofs
- 2.1.2 - avahi-daemon
- 2.1.3 - isc-dhcp-server
- 2.1.4 - bind9 (named.service)
- 2.1.5 - dnsmasq
- 2.1.6 - vsftpd
- 2.1.7 - slapd
- 2.1.8 - dovecot-imapd / dovecot-pop3d
- 2.1.9 - nfs-kernel-server
- 2.1.10 - ypserv
- 2.1.11 - cups
- 2.1.12 - rpcbind
- 2.1.13 - rsync
- 2.1.14 - samba
- 2.1.15 - snmpd
- 2.1.16 - tftpd-hpa
- 2.1.17 - squid
- 2.1.18 - apache2 and nginx
- 2.1.19 - xinetd

#### 2.1.20–2.1.22 Other server controls
- 2.1.20 - xserver-common not installed
- 2.1.21 - Mail transfer agent (postfix) configured for local-only mode
- 2.1.22 - Only approved services listening (Manual)

### Section 2.2 - Configure Client Services (6 subsections) ✅
- 2.2.1 - NIS client not installed
- 2.2.2 - rsh-client not installed
- 2.2.3 - talk not installed
- 2.2.4 - telnet and inetutils-telnet not installed
- 2.2.5 - ldap-utils not installed
- 2.2.6 - ftp and tnftp not installed

### Section 2.3 - Configure Time Synchronization (7 subsections) ✅
- 2.3.1.1 - Single time synchronization daemon (systemd-timesyncd or chrony only)
- 2.3.2.1 - systemd-timesyncd configured with authorized timeserver (if in use)
- 2.3.2.2 - systemd-timesyncd enabled and running (if in use)
- 2.3.3.1 - chrony configured with authorized timeserver (if in use)
- 2.3.3.2 - chrony running as user _chrony (if in use)
- 2.3.3.3 - chrony enabled and running (if in use)

### Section 2.4 - Job Schedulers (9 subsections) ✅
- 2.4.1.1 - cron daemon enabled and active
- 2.4.1.2 - Permissions on /etc/crontab (600 root:root)
- 2.4.1.3 - Permissions on /etc/cron.hourly (700 root:root)
- 2.4.1.4 - Permissions on /etc/cron.daily (700 root:root)
- 2.4.1.5 - Permissions on /etc/cron.weekly (700 root:root)
- 2.4.1.6 - Permissions on /etc/cron.monthly (700 root:root)
- 2.4.1.7 - Permissions on /etc/cron.d (700 root:root)
- 2.4.1.8 - crontab restricted to authorized users (cron.allow, cron.deny)
- 2.4.2.1 - at restricted to authorized users (at.allow, at.deny)

## Total Sections Implemented

**44 subsections** across 4 main areas:
- 2.1: 22 subsections (server services)
- 2.2: 6 subsections (client packages)
- 2.3: 7 subsections (time sync)
- 2.4: 9 subsections (cron and at)

## Helper Functions Created

- `check_service_not_in_use(pkg, unit1 unit2 ...)` - Compliant if package not installed or no unit enabled/active
- `ensure_service_stopped_masked(unit1 unit2 ...)` - Stop and mask systemd units
- `ensure_service_stopped_and_purge(pkg, unit1 unit2 ...)` - Stop units and purge package
- `check_path_permissions(path, perms, owner, group)` - Check file or directory permissions
- `set_path_permissions(path, perms, owner, group)` - Set file or directory permissions (with backup)

## Usage

```bash
# Process entire section 2
sudo bash cis_hardening.sh 2

# Process specific subsection
sudo bash cis_hardening.sh 2.1.5
sudo bash cis_hardening.sh 2.4.1.2

# Process multiple sections
sudo bash cis_hardening.sh 1,2,3

# Dry-run mode
sudo bash cis_hardening.sh --dry-run 2
```

## Notes

- **Manual Sections**: 2.1.22 (only approved services listening) is manual; script logs a warning only.
- **Time Sync**: Only one of systemd-timesyncd or chrony should be in use; 2.3.2.x applies only if timesyncd is in use, 2.3.3.x only if chrony is in use.
- **Cron/At**: 2.4.1.x applies only if cron is installed; 2.4.2.1 only if at is installed.
- **Service Purge**: Remediation prefers purging packages; if a package is required as a dependency, the benchmark allows stopping and masking the service instead (script purges by default).

## Testing

All sections have been:
- ✅ Syntax validated
- ✅ Function routing tested
- ✅ Dry-run mode tested
- ✅ Error handling verified

## Next Steps

Section 2 is complete. The script is ready to process all Services sections from the CIS Ubuntu Linux 24.04 LTS Benchmark.
