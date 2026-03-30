# CIS Ubuntu Linux 24.04 LTS Benchmark Hardening Script

This project provides an automated bash script to apply CIS (Center for Internet Security) benchmark settings to Ubuntu Linux 24.04 LTS systems.

## Overview

The script follows a structured approach to:
1. Parse section arguments from the command line
2. Check root privileges
3. Load configuration from `config.env`
4. Backup existing configuration files (skipped in verify-only mode)
5. Check compliance status for each section
6. Apply hardening settings if needed (skipped in verify-only mode)
7. Verify the changes
8. Generate a detailed CSV report

In **verify-only** mode (`-v` / `--verify-only`), steps 4 and 6 are skipped: the script runs verification checks and writes the CSV report only—no backups and no remediation.

## Usage

```bash
# Run with specific sections (requires root)
sudo bash cis_hardening.sh 1,3,5

# Dry-run mode (preview changes without applying)
sudo bash cis_hardening.sh --dry-run 1,3,5
# or
sudo bash cis_hardening.sh -d 1,3,5

# Verify-only mode (compliance checks + CSV report only; no hardening, no backups)
sudo bash cis_hardening.sh --verify-only 1,3,5
# or
sudo bash cis_hardening.sh -v 1,3,5

# Show help
bash cis_hardening.sh --help

# The script will:
# - Process sections 1, 3, and 5
# - Backup configuration files (compressed as tar.gz)
# - Apply hardening if needed
# - Continue processing even if one section fails
# - Generate a detailed CSV report
```

## Requirements

- Ubuntu Linux 24.04 LTS
- Root/sudo privileges
- Bash shell

## Files

- `cis_hardening.sh` - Main hardening script
- `config.env` - Configuration file (auto-created if missing)
- `report/` - Directory containing generated CSV reports
- `backup_temp/` - Directory containing temporary backup files (compressed to tar.gz after processing)

## Configuration

Edit `config.env` to customize:
- `REPORT_DIR` - Report output directory (default: "report", relative to script)
- `BACKUP_TEMP_DIR` - Backup temporary directory (default: "backup_temp", relative to script)
- `LOG_FILE` - Log file path (default: "/var/log/cis-hardening.log")

## Implementation Status

The script structure is complete and follows the flowchart design. The following functions need to be implemented with actual CIS benchmark commands:

1. `check_compliance()` - Check if a section is already compliant
2. `apply_hardening()` - Apply the hardening setting for a section
3. `verify_hardening()` - Verify that hardening was applied successfully

These functions are marked with `TODO` comments in the script.

## Logging

Logs are written to `/var/log/cis-hardening.log` by default (configurable in `config.env`).

## Backups

All modified configuration files are backed up before any changes are made. The backup directory is automatically compressed to a tar.gz archive after processing completes. Backups are stored in `backup_temp/TIMESTAMP.tar.gz` by default (configurable in `config.env`).

Verify-only mode does not create or compress backups.

Dry-run and verify-only cannot be combined in a single run.

## Reports

The script generates CSV reports with the following columns:
- Section: The CIS section or subsection ID (e.g. `1`, `1.1.1.1`, `5.1.6`)
- Status: SKIPPED, FIXED, FAILED, VERIFY_FAILED, DRY-RUN, or **PASS** (compliant in verify-only mode)
- Timestamp: When the section was processed
- Details: Additional information about the result

## Features

- **Dry-run mode**: Preview changes without applying them using `--dry-run` / `-d`
- **Verify-only mode**: Run verification checks and generate the CSV report using `--verify-only` / `-v` (no hardening, no backups; cannot be used with dry-run)
- **Automatic backups**: All configuration files are backed up before modification
- **Compressed backups**: Backups are automatically compressed to tar.gz format
- **Error resilience**: Script continues processing remaining sections even if one fails
- **Detailed logging**: All actions are logged to `/var/log/cis-hardening.log`
- **CSV reports**: Detailed reports in CSV format for easy analysis
- **Comprehensive status tracking**: Tracks SKIPPED, FIXED, FAILED, VERIFY_FAILED, PASS (verify-only), and DRY-RUN where applicable
