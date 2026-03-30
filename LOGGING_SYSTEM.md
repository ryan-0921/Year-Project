# Logging System Documentation

## Overview

The CIS hardening script implements a comprehensive logging system that provides both **file-based logging** and **colored console output**. The system is designed to be resilient, user-friendly, and informative, ensuring that all script activities are recorded for audit and troubleshooting purposes.

---

## 1. Log File Location

### Default Log File Path

```bash
LOG_FILE="/var/log/cis-hardening.log"
```

- **Location**: `/var/log/cis-hardening.log`
- **Purpose**: Centralized system log file for all script executions
- **Permissions**: Requires root/sudo access to write (script runs as root)
- **Persistence**: Logs accumulate across multiple script runs (append mode)

### Log File Behavior

- The log file is **appended to** on each script run (not overwritten)
- If the log file cannot be written (e.g., permission denied), the script **gracefully degrades** to console-only output
- Each log entry includes a **timestamp** and **log level** for easy filtering and analysis

---

## 2. Core Logging Function: `log()`

### Function Signature

```bash
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Try to write to log file, but don't fail if we can't
    if echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE" 2>/dev/null; then
        : # Success
    else
        # If log file write fails, just output to console
        echo "[$timestamp] [$level] $message"
    fi
}
```

### How It Works

1. **Parameters**:
   - `level`: The log level (INFO, WARN, ERROR, SUCCESS, DRY-RUN)
   - `message`: All remaining arguments are treated as the message text

2. **Timestamp Generation**:
   - Uses `date '+%Y-%m-%d %H:%M:%S'` format
   - Example: `2026-01-19 23:12:34`

3. **Dual Output Strategy**:
   - **Primary**: Attempts to write to log file using `tee -a` (append mode)
   - **Fallback**: If file write fails (e.g., permission denied), outputs to console only
   - The `2>/dev/null` suppresses error messages from `tee` if it fails

4. **Log Format**:
   ```
   [YYYY-MM-DD HH:MM:SS] [LEVEL] message text
   ```
   - Example: `[2026-01-19 23:12:34] [INFO] Running as root - OK`

### Error Handling

- **Resilient Design**: If log file write fails, the script **continues** and outputs to console
- **No Script Failure**: Logging failures do not cause the script to exit
- **Silent Degradation**: Errors from `tee` are suppressed to avoid cluttering output

---

## 3. Log Level Functions

The script provides five specialized logging functions, each with distinct behavior:

### 3.1 `log_info()` - Informational Messages

```bash
log_info() {
    log "INFO" "$@"
}
```

**Usage**: General informational messages about script progress

**Examples**:
- `log_info "Running as root - OK"`
- `log_info "Loading configuration from $CONFIG_FILE"`
- `log_info "Processing Section: 1"`

**Output**:
- **Log File**: `[2026-01-19 23:12:34] [INFO] Running as root - OK`
- **Console**: Same format (no color, standard output)

---

### 3.2 `log_warn()` - Warning Messages

```bash
log_warn() {
    log "WARN" "$@"
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}
```

**Usage**: Non-critical issues that should be noted

**Behavior**:
1. Calls `log()` to write to log file with `[WARN]` level
2. **Additionally** outputs a **colored warning** to stderr (console)
3. Uses **yellow color** (`${YELLOW}`) for visibility

**Examples**:
- `log_warn "Config file not found: $CONFIG_FILE"`
- `log_warn "Mount point '/tmp' is not a mount point"`
- `log_warn "Section 1 failed, but continuing with remaining sections..."`

**Output**:
- **Log File**: `[2026-01-19 23:12:34] [WARN] Config file not found: /path/to/config.env`
- **Console**: `[WARNING] Config file not found: /path/to/config.env` (in yellow, to stderr)

---

### 3.3 `log_error()` - Error Messages

```bash
log_error() {
    log "ERROR" "$@"
    echo -e "${RED}[ERROR]${NC} $*" >&2
}
```

**Usage**: Critical errors that indicate failures

**Behavior**:
1. Calls `log()` to write to log file with `[ERROR]` level
2. **Additionally** outputs a **colored error** to stderr (console)
3. Uses **red color** (`${RED}`) for high visibility

**Examples**:
- `log_error "This script must be run as root (use sudo)"`
- `log_error "  $sub_section: fail - Verification failed"`
- `log_error "Failed to compress backup directory"`

**Output**:
- **Log File**: `[2026-01-19 23:12:34] [ERROR] This script must be run as root (use sudo)`
- **Console**: `[ERROR] This script must be run as root (use sudo)` (in red, to stderr)

---

### 3.4 `log_success()` - Success Messages

```bash
log_success() {
    log "SUCCESS" "$@"
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}
```

**Usage**: Positive outcomes and successful operations

**Behavior**:
1. Calls `log()` to write to log file with `[SUCCESS]` level
2. **Additionally** outputs a **colored success** message to stdout (console)
3. Uses **green color** (`${GREEN}`) for positive feedback

**Examples**:
- `log_success "Backup compressed: $backup_archive"`
- `log_success "  $sub_section: success - Hardening applied and verified"`
- `log_success "All sections processed successfully"`

**Output**:
- **Log File**: `[2026-01-19 23:12:34] [SUCCESS] Backup compressed: /path/to/backup.tar.gz`
- **Console**: `[SUCCESS] Backup compressed: /path/to/backup.tar.gz` (in green, to stdout)

---

### 3.5 `log_dryrun()` - Dry-Run Messages

```bash
log_dryrun() {
    log "DRY-RUN" "$@"
    echo -e "${BLUE}[DRY-RUN]${NC} $*"
}
```

**Usage**: Messages indicating what **would** happen in dry-run mode

**Behavior**:
1. Calls `log()` to write to log file with `[DRY-RUN]` level
2. **Additionally** outputs a **colored dry-run** message to stdout (console)
3. Uses **blue color** (`${BLUE}`) to distinguish from actual operations

**Examples**:
- `log_dryrun "Would backup: $file_path"`
- `log_dryrun "Would install apparmor package"`
- `log_dryrun "DRY-RUN MODE: No changes will be applied"`

**Output**:
- **Log File**: `[2026-01-19 23:12:34] [DRY-RUN] Would backup: /etc/fstab`
- **Console**: `[DRY-RUN] Would backup: /etc/fstab` (in blue, to stdout)

---

## 4. Color System

### Color Definitions

```bash
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color (reset)
```

### Color Usage

- **RED**: Errors (`log_error`)
- **GREEN**: Success (`log_success`)
- **YELLOW**: Warnings (`log_warn`)
- **BLUE**: Dry-run messages (`log_dryrun`)
- **NC (No Color)**: Resets color after each message

### Console Output Behavior

- **Colored output** is **only** sent to console (stdout/stderr)
- **Log file** contains **plain text** (no ANSI color codes)
- This ensures log files remain readable in text editors and log analysis tools

---

## 5. Output Streams

### Standard Output (stdout)

- **Used by**: `log_info()`, `log_success()`, `log_dryrun()`
- **Purpose**: Normal informational and success messages
- **Color**: Green (success), Blue (dry-run), or no color (info)

### Standard Error (stderr)

- **Used by**: `log_warn()`, `log_error()`
- **Purpose**: Warnings and errors that need attention
- **Color**: Yellow (warnings), Red (errors)
- **Rationale**: Separates warnings/errors from normal output, allows filtering

### Log File

- **Contains**: All messages regardless of level
- **Format**: Plain text with timestamps
- **Stream**: Written via `tee -a` (appends to file while also displaying)

---

## 6. Log Message Categories

### 6.1 Script Initialization

- Script startup messages
- Root privilege checks
- Configuration loading
- Directory creation

**Example**:
```
[2026-01-19 23:12:32] [INFO] =========================================
[2026-01-19 23:12:32] [INFO] CIS Hardening Script Started
[2026-01-19 23:12:32] [INFO] =========================================
[2026-01-19 23:12:32] [INFO] Running as root - OK
[2026-01-19 23:12:32] [INFO] Loading configuration from /path/to/config.env
```

### 6.2 Section Processing

- Section start/end markers
- Subsection processing status
- Compliance check results
- Hardening application status

**Example**:
```
[2026-01-19 23:12:34] [INFO] Processing Section: 1 (with detailed subsection reporting)
[2026-01-19 23:12:34] [INFO] Checking compliance for section 1.3.1.3...
[2026-01-19 23:12:34] [INFO] Applying hardening for section 1.3.1.3...
[2026-01-19 23:12:34] [SUCCESS]   1.3.1.3: success - Hardening applied and verified
```

### 6.3 File Operations

- File backups
- File modifications
- Permission changes
- Configuration updates

**Example**:
```
[2026-01-19 23:12:34] [INFO] Backed up file: /etc/fstab -> /path/to/backup/etc/fstab
[2026-01-19 23:12:34] [INFO] Added line to '/etc/fstab': nodev
[2026-01-19 23:12:34] [INFO] Set permissions on '/etc/fstab' to 644 root:root
```

### 6.4 System Operations

- Package installations/removals
- Service management
- Kernel module operations
- Sysctl parameter changes

**Example**:
```
[2026-01-19 23:12:34] [INFO] Applying hardening for section 1.3.1.1...
[2026-01-19 23:12:34] [INFO] Set sysctl parameter 'kernel.randomize_va_space' to '2'
```

### 6.5 Verification and Results

- Verification attempts
- Success/failure status
- Summary statistics

**Example**:
```
[2026-01-19 23:12:34] [INFO] Verifying hardening for section 1.3.1.3...
[2026-01-19 23:12:34] [SUCCESS]   1.3.1.3: success
[2026-01-19 23:12:34] [ERROR]   1.3.1.1: fail
```

### 6.6 Backup and Reporting

- Backup directory creation
- Backup compression
- Report generation
- Summary statistics

**Example**:
```
[2026-01-19 23:12:34] [INFO] Compressing backup directory to tar.gz...
[2026-01-19 23:12:34] [SUCCESS] Backup compressed: /path/to/backup.tar.gz
[2026-01-19 23:12:34] [INFO] Generating Summary Report
[2026-01-19 23:12:34] [INFO]   Total sections processed: 66
[2026-01-19 23:12:34] [INFO]   Fixed: 28
```

---

## 7. Logging Usage Patterns

### 7.1 Progress Tracking

The script uses `log_info()` extensively to track progress through each phase:

```bash
log_info "========================================="
log_info "Processing Section: 1"
log_info "========================================="
log_info "Checking compliance for section 1.3.1.3..."
```

### 7.2 Error Reporting

Errors are logged with `log_error()` and also displayed prominently:

```bash
if ! apply_hardening "$sub_section"; then
    log_error "  $sub_section: fail - Failed to apply hardening"
    return 1
fi
```

### 7.3 Success Confirmation

Success messages provide positive feedback:

```bash
if verify_hardening "$sub_section"; then
    log_success "  $sub_section: success - Hardening applied and verified"
fi
```

### 7.4 Warning Notifications

Warnings alert users to non-critical issues:

```bash
if [[ ! -f "$file" ]]; then
    log_warn "File '$file' does not exist"
    return 1
fi
```

### 7.5 Dry-Run Indication

Dry-run mode is clearly marked throughout:

```bash
if [[ "$DRY_RUN" == true ]]; then
    log_dryrun "Would backup: $file_path"
else
    backup_file "$file_path"
fi
```

---

## 8. Log File Management

### 8.1 Append Mode

- Log file uses **append mode** (`tee -a`)
- Each script run adds to the existing log
- **No automatic rotation** - log file grows over time

### 8.2 Log File Size Considerations

- For production use, consider implementing **log rotation** (e.g., `logrotate`)
- Example `logrotate` configuration:
  ```
  /var/log/cis-hardening.log {
      daily
      rotate 7
      compress
      missingok
      notifempty
  }
  ```

### 8.3 Log File Permissions

- Log file is created with default permissions (typically `644`)
- Only root can write (script runs as root)
- All users can read (for audit purposes)

---

## 9. Log Analysis

### 9.1 Filtering by Log Level

**Extract only errors**:
```bash
grep "\[ERROR\]" /var/log/cis-hardening.log
```

**Extract only warnings**:
```bash
grep "\[WARN\]" /var/log/cis-hardening.log
```

**Extract only successes**:
```bash
grep "\[SUCCESS\]" /var/log/cis-hardening.log
```

### 9.2 Filtering by Section

**Find all logs for a specific section**:
```bash
grep "section 1.3.1.3" /var/log/cis-hardening.log
```

### 9.3 Filtering by Date/Time

**Find logs from a specific date**:
```bash
grep "2026-01-19" /var/log/cis-hardening.log
```

**Find logs from a specific time range**:
```bash
grep "2026-01-19 23:" /var/log/cis-hardening.log
```

### 9.4 Combining Filters

**Find errors for a specific section on a specific date**:
```bash
grep "2026-01-19" /var/log/cis-hardening.log | grep "\[ERROR\]" | grep "1.3.1.3"
```

---

## 10. Logging Best Practices in the Script

### 10.1 Consistent Formatting

- All log messages follow the same format: `[timestamp] [level] message`
- Section numbers are consistently formatted (e.g., `1.3.1.3`)
- File paths are consistently logged with full paths

### 10.2 Appropriate Log Levels

- **INFO**: Normal operations, progress updates
- **WARN**: Non-critical issues, missing optional files
- **ERROR**: Failures, critical issues
- **SUCCESS**: Successful operations, positive outcomes
- **DRY-RUN**: Simulated operations

### 10.3 Error Context

- Error messages include context (section number, file path, etc.)
- Example: `"  $sub_section: fail - Verification failed"` includes the subsection number

### 10.4 Graceful Degradation

- If log file write fails, script continues with console output
- No script failures due to logging issues

---

## 11. Integration with Reporting System

### 11.1 CSV Report vs Log File

- **Log File**: Detailed, chronological record of all operations
- **CSV Report**: Structured summary with status per section/subsection
- Both systems complement each other:
  - Log file provides **audit trail** and **debugging information**
  - CSV report provides **quick status overview** and **data analysis**

### 11.2 Correlation

- Log entries and CSV report entries can be correlated via timestamps
- Example: Log shows `[2026-01-19 23:12:34] [SUCCESS] 1.3.1.3: success`
- CSV shows: `1.3.1.3,FIXED,2026-01-19 23:12:34,Hardening applied and verified`

---

## 12. Example Log File Output

```
[2026-01-19 23:12:32] [INFO] =========================================
[2026-01-19 23:12:32] [INFO] CIS Hardening Script Started
[2026-01-19 23:12:32] [INFO] =========================================
[2026-01-19 23:12:32] [INFO] Running as root - OK
[2026-01-19 23:12:32] [INFO] Loading configuration from /home/test/year_project/config.env
[2026-01-19 23:12:32] [INFO] Configuration loaded successfully
[2026-01-19 23:12:32] [INFO] Report directory: /home/test/year_project/report
[2026-01-19 23:12:32] [INFO] Backup temp directory: /home/test/year_project/backup_temp
[2026-01-19 23:12:32] [INFO] Backup directory created: /home/test/year_project/backup_temp/20260119_231232
[2026-01-19 23:12:32] [INFO] Report directory created: /home/test/year_project/report
[2026-01-19 23:12:32] [INFO] Report file initialized: /home/test/year_project/report/cis_hardening_report_20260119_231232.csv
[2026-01-19 23:12:32] [INFO] =========================================
[2026-01-19 23:12:32] [INFO] Processing Section: 1 (with detailed subsection reporting)
[2026-01-19 23:12:32] [INFO] =========================================
[2026-01-19 23:12:32] [INFO] Processing subsections...
[2026-01-19 23:12:32] [INFO] 
[2026-01-19 23:12:32] [INFO] Checking compliance for section 1.1.1.1...
[2026-01-19 23:12:33] [INFO] Kernel module 'cramfs' is properly disabled - compliant
[2026-01-19 23:12:33] [INFO]   1.1.1.1: success - Already compliant
[2026-01-19 23:12:34] [INFO] Checking compliance for section 1.3.1.3...
[2026-01-19 23:12:34] [INFO] Applying hardening for section 1.3.1.3...
[2026-01-19 23:12:34] [INFO] Verifying hardening for section 1.3.1.3...
[2026-01-19 23:12:34] [INFO] Checking compliance for section 1.3.1.3...
[2026-01-19 23:12:34] [SUCCESS]   1.3.1.3: success - Hardening applied and verified
[2026-01-19 23:12:34] [INFO] =========================================
[2026-01-19 23:12:34] [INFO] Section 1 Subsection Summary:
[2026-01-19 23:12:34] [INFO] =========================================
[2026-01-19 23:12:34] [SUCCESS]   1.1.1.1: success
[2026-01-19 23:12:34] [SUCCESS]   1.1.1.2: success
[2026-01-19 23:12:34] [ERROR]   1.3.1.1: fail
[2026-01-19 23:12:34] [ERROR]   1.3.1.3: fail
[2026-01-19 23:12:34] [ERROR]   1.7.10: fail
[2026-01-19 23:12:34] [INFO] =========================================
[2026-01-19 23:12:34] [WARN] Section 1 failed, but continuing with remaining sections...
[2026-01-19 23:12:34] [INFO] Compressing backup directory to tar.gz...
[2026-01-19 23:12:34] [SUCCESS] Backup compressed: /home/test/year_project/backup_temp/20260119_231232.tar.gz
[2026-01-19 23:12:34] [INFO] Removed uncompressed backup directory
[2026-01-19 23:12:34] [INFO] =========================================
[2026-01-19 23:12:34] [INFO] Generating Summary Report
[2026-01-19 23:12:34] [INFO] =========================================
[2026-01-19 23:12:34] [INFO] Summary:
[2026-01-19 23:12:34] [INFO]   Total sections processed: 66
[2026-01-19 23:12:34] [INFO]   Fixed: 28
[2026-01-19 23:12:34] [INFO]   Skipped (already compliant): 35
[2026-01-19 23:12:34] [INFO]   Failed: 0
[2026-01-19 23:12:34] [INFO]   Verify failed: 3
[2026-01-19 23:12:34] [INFO] 
[2026-01-19 23:12:34] [INFO] Detailed report saved to: /home/test/year_project/report/cis_hardening_report_20260119_231232.csv
[2026-01-19 23:12:34] [INFO] Backup location: /home/test/year_project/backup_temp/20260119_231232.tar.gz
[2026-01-19 23:12:34] [WARN] Some sections failed: 1
[2026-01-19 23:12:34] [INFO] Check the report and logs for details
```

---

## 13. Summary

The logging system in the CIS hardening script provides:

1. **Dual Output**: Both file-based logging and colored console output
2. **Five Log Levels**: INFO, WARN, ERROR, SUCCESS, DRY-RUN
3. **Resilient Design**: Gracefully handles log file write failures
4. **Comprehensive Coverage**: Logs all script operations from start to finish
5. **User-Friendly**: Colored output for immediate visual feedback
6. **Audit-Ready**: Structured format suitable for log analysis tools
7. **Integration**: Works seamlessly with the CSV reporting system

The system ensures that administrators have complete visibility into script execution, making troubleshooting, auditing, and compliance verification straightforward and reliable.
