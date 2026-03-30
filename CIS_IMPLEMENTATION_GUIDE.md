# CIS Benchmark Implementation Guide

## Overview

The script now includes a working implementation for CIS section 1.1.1.1 (Ensure cramfs kernel module is not available). This document explains how the implementation works and how to add more CIS sections.

## Implemented Section: 1.1.1.1

### What It Does

Section 1.1.1.1 ensures that the `cramfs` kernel module is disabled to reduce the attack surface. The implementation:

1. **Checks Compliance**: Verifies if the cramfs module:
   - Doesn't exist (compliant)
   - Is not currently loaded
   - Has an `install` command set to `/bin/false` in `/etc/modprobe.d/`
   - Is blacklisted in `/etc/modprobe.d/`

2. **Applies Hardening**: If not compliant:
   - Unloads the module if currently loaded
   - Creates/updates `/etc/modprobe.d/cramfs.conf` with:
     - `install cramfs /bin/false`
     - `blacklist cramfs`
   - Backs up the configuration file before modification

### Usage

```bash
# Check and fix section 1.1.1.1 (dry-run)
sudo bash cis_hardening.sh --dry-run 1.1.1.1

# Actually apply the hardening
sudo bash cis_hardening.sh 1.1.1.1

# You can also use top-level section 1 (processes all subsections)
sudo bash cis_hardening.sh 1
```

## Architecture

### Helper Functions

The script includes reusable helper functions:

1. **`check_kernel_module_compliance(module_name, module_type)`**
   - Checks if a kernel module is properly disabled
   - Returns 0 if compliant, 1 if not compliant
   - Can be reused for other filesystem modules (freevxfs, hfs, etc.)

2. **`disable_kernel_module(module_name, module_type)`**
   - Disables a kernel module by:
     - Unloading it if loaded
     - Adding install command to `/etc/modprobe.d/`
     - Adding blacklist entry
   - Handles dry-run mode
   - Backs up files before modification

### Section Mapping

The `check_compliance()` and `apply_hardening()` functions use a `case` statement to map section numbers to specific functions:

```bash
case "$section" in
    1.1.1.1)
        check_compliance_1_1_1_1
        ;;
    *)
        # Not implemented yet
        ;;
esac
```

## Adding New Sections

To add a new CIS section, follow these steps:

### Step 1: Create Compliance Check Function

```bash
check_compliance_X_X_X_X() {
    # Implement the audit logic
    # Return 0 if compliant, 1 if not compliant
}
```

### Step 2: Create Hardening Function

```bash
apply_hardening_X_X_X_X() {
    # Backup relevant files using backup_file()
    # Apply the hardening settings
    # Return 0 on success, 1 on failure
}
```

### Step 3: Add to Case Statements

Update both `check_compliance()` and `apply_hardening()` functions:

```bash
case "$section" in
    1.1.1.1)
        check_compliance_1_1_1_1
        ;;
    X.X.X.X)  # Your new section
        check_compliance_X_X_X_X
        ;;
    *)
        # ...
        ;;
esac
```

### Step 4: Test

```bash
# Test in dry-run mode first
sudo bash cis_hardening.sh --dry-run X.X.X.X

# Then test actual application
sudo bash cis_hardening.sh X.X.X.X
```

## Example: Adding More Kernel Module Sections

Since sections 1.1.1.2 through 1.1.1.9 follow the same pattern (different module names), you can easily add them:

```bash
# Add compliance checks
check_compliance_1_1_1_2() {
    check_kernel_module_compliance "freevxfs" "fs"
}

check_compliance_1_1_1_3() {
    check_kernel_module_compliance "hfs" "fs"
}

# Add hardening functions
apply_hardening_1_1_1_2() {
    disable_kernel_module "freevxfs" "fs"
}

apply_hardening_1_1_1_3() {
    disable_kernel_module "hfs" "fs"
}

# Update case statements
case "$section" in
    1.1.1.1)
        check_compliance_1_1_1_1
        ;;
    1.1.1.2)
        check_compliance_1_1_1_2
        ;;
    1.1.1.3)
        check_compliance_1_1_1_3
        ;;
    # ... etc
esac
```

## Testing

The script has been tested with:

- ✅ Syntax validation
- ✅ Dry-run mode
- ✅ Compliance checking
- ✅ Report generation
- ✅ Error handling

## Next Steps

1. **Add more kernel module sections** (1.1.1.2 - 1.1.1.9) using the helper functions
2. **Add filesystem partition sections** (1.1.2.x) - will need new helper functions
3. **Add other section types** as needed

## Notes

- All file modifications are automatically backed up
- Backups are compressed to tar.gz after processing
- The script continues processing even if one section fails
- All actions are logged to `/var/log/cis-hardening.log`
- Detailed CSV reports are generated for each run
