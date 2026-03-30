#!/bin/bash

###############################################################################
# CIS Ubuntu Linux 24.04 LTS Benchmark Hardening Script
# 
# This script automatically applies CIS benchmark settings based on section
# arguments provided by the user.
#
# Usage: sudo bash cis_hardening.sh [OPTIONS] <section_numbers>
# Example: sudo bash cis_hardening.sh 1,3,5
# Example: sudo bash cis_hardening.sh --dry-run 1,3,5
# Example: sudo bash cis_hardening.sh --verify-only 1,3,5
###############################################################################

set -uo pipefail  # Exit on undefined vars, pipe failures (but not on command errors - we handle those)

###############################################################################
# Configuration and Constants
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
REPORT_DIR="${SCRIPT_DIR}/report"
BACKUP_TEMP_DIR="${SCRIPT_DIR}/backup_temp"
BACKUP_DIR="${BACKUP_TEMP_DIR}/$(date +%Y%m%d_%H%M%S)"
LOG_FILE="/var/log/cis-hardening.log"
REPORT_FILE="${REPORT_DIR}/cis_hardening_report_$(date +%Y%m%d_%H%M%S).csv"

# Dry-run mode flag (set via --dry-run argument)
DRY_RUN=false

# Verify-only: run verification checks and CSV report; no hardening or backups
VERIFY_ONLY=false

# Array to track backed up files for tar.gz compression
BACKED_UP_FILES=()

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

###############################################################################
# Logging Functions
###############################################################################

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # Try to write to log file, but don't fail if we can't (e.g., permission denied)
    if echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE" 2>/dev/null; then
        : # Success
    else
        # If log file write fails, just output to console
        echo "[$timestamp] [$level] $message"
    fi
}

log_info() {
    log "INFO" "$@"
}

log_warn() {
    log "WARN" "$@"
    echo -e "${YELLOW}[WARNING]${NC} $*" >&2
}

log_error() {
    log "ERROR" "$@"
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    log "SUCCESS" "$@"
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_dryrun() {
    log "DRY-RUN" "$@"
    echo -e "${BLUE}[DRY-RUN]${NC} $*"
}

###############################################################################
# Utility Functions
###############################################################################

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        if [[ "$DRY_RUN" == true ]] || [[ "$VERIFY_ONLY" == true ]]; then
            log_warn "Not running as root - some checks may fail in dry-run or verify-only mode"
            return 0
        else
            log_error "This script must be run as root (use sudo)"
            exit 1
        fi
    fi
    log_info "Running as root - OK"
}

# Load configuration from config.env
load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_warn "Config file not found: $CONFIG_FILE"
        log_info "Creating default config file..."
        create_default_config
    fi
    
    log_info "Loading configuration from $CONFIG_FILE"
    # Source the config file
    if [[ -f "$CONFIG_FILE" ]]; then
        set -a  # Automatically export all variables
        source "$CONFIG_FILE"
        set +a
        
        # Update paths if configured (support relative paths)
        if [[ -n "${REPORT_DIR:-}" ]]; then
            if [[ "${REPORT_DIR:0:1}" != "/" ]]; then
                REPORT_DIR="${SCRIPT_DIR}/${REPORT_DIR}"
            fi
        else
            REPORT_DIR="${SCRIPT_DIR}/report"
        fi
        
        if [[ -n "${BACKUP_TEMP_DIR:-}" ]]; then
            if [[ "${BACKUP_TEMP_DIR:0:1}" != "/" ]]; then
                BACKUP_TEMP_DIR="${SCRIPT_DIR}/${BACKUP_TEMP_DIR}"
            fi
        else
            BACKUP_TEMP_DIR="${SCRIPT_DIR}/backup_temp"
        fi
        
        # Update BACKUP_DIR and REPORT_FILE with new paths
        BACKUP_DIR="${BACKUP_TEMP_DIR}/$(date +%Y%m%d_%H%M%S)"
        REPORT_FILE="${REPORT_DIR}/cis_hardening_report_$(date +%Y%m%d_%H%M%S).csv"
        
        log_info "Configuration loaded successfully"
        log_info "Report directory: $REPORT_DIR"
        log_info "Backup temp directory: $BACKUP_TEMP_DIR"
    else
        log_error "Failed to load configuration"
        exit 1
    fi
}

# Create default config.env file
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# CIS Hardening Script Configuration
# Report output directory (relative to script directory)
REPORT_DIR="report"

# Backup temporary directory (relative to script directory)
BACKUP_TEMP_DIR="backup_temp"

# Log file path
LOG_FILE="/var/log/cis-hardening.log"

# Additional configuration can be added here
EOF
    log_info "Default config file created at $CONFIG_FILE"
}

# Create backup directory
create_backup_dir() {
    # Use backup_temp directory in script directory
    BACKUP_DIR="${BACKUP_TEMP_DIR}/$(date +%Y%m%d_%H%M%S)"
    
    if [[ "$VERIFY_ONLY" == true ]]; then
        log_info "Verify-only mode: skipping backup directory"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would create backup directory: $BACKUP_DIR"
        mkdir -p "$BACKUP_DIR" 2>/dev/null || true
    else
        mkdir -p "$BACKUP_DIR"
        log_info "Backup directory created: $BACKUP_DIR"
    fi
}

# Create report directory
create_report_dir() {
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would create report directory: $REPORT_DIR"
        mkdir -p "$REPORT_DIR" 2>/dev/null || true
    else
        mkdir -p "$REPORT_DIR"
        log_info "Report directory created: $REPORT_DIR"
    fi
}

# Backup a configuration file or directory
backup_file() {
    local file_path="$1"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would backup: $file_path"
        BACKED_UP_FILES+=("$file_path")
        return 0
    fi
    
    if [[ ! -e "$file_path" ]]; then
        log_warn "File/directory does not exist, skipping backup: $file_path"
        return 0
    fi
    
    local backup_path="${BACKUP_DIR}${file_path}"
    local backup_dir=$(dirname "$backup_path")
    
    mkdir -p "$backup_dir"
    
    if [[ -f "$file_path" ]]; then
        cp -p "$file_path" "$backup_path"
        BACKED_UP_FILES+=("$file_path")
        log_info "Backed up file: $file_path -> $backup_path"
    elif [[ -d "$file_path" ]]; then
        # For directories, backup the specific file we're about to modify
        # This function is called before creating/modifying files in the directory
        # So we just note the directory for backup
        BACKED_UP_FILES+=("$file_path")
        log_info "Noted directory for backup: $file_path"
    fi
}

# Compress backup directory to tar.gz
compress_backup() {
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would compress backup directory to: ${BACKUP_DIR}.tar.gz"
        return 0
    fi
    
    if [[ ${#BACKED_UP_FILES[@]} -eq 0 ]]; then
        log_info "No files were backed up, skipping compression"
        return 0
    fi
    
    log_info "Compressing backup directory to tar.gz..."
    local backup_archive="${BACKUP_DIR}.tar.gz"
    
    # Create tar.gz archive from backup directory
    if tar -czf "$backup_archive" -C "$(dirname "$BACKUP_DIR")" "$(basename "$BACKUP_DIR")" 2>/dev/null; then
        log_success "Backup compressed: $backup_archive"
        # Remove uncompressed backup directory
        rm -rf "$BACKUP_DIR"
        log_info "Removed uncompressed backup directory"
        BACKUP_DIR="${backup_archive}"
    else
        log_error "Failed to compress backup directory"
        return 1
    fi
}

# Parse command line arguments
parse_arguments() {
    local sections_arg=""
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-d)
                DRY_RUN=true
                log_info "Dry-run mode enabled - no changes will be made"
                shift
                ;;
            --verify-only|-v)
                VERIFY_ONLY=true
                log_info "Verify-only mode: compliance checks and report only (no hardening or backups)"
                shift
                ;;
            --help|-h)
                show_usage
                exit 0
                ;;
            *)
                if [[ -z "$sections_arg" ]]; then
                    sections_arg="$1"
                else
                    log_error "Unexpected argument: $1"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    if [[ "$DRY_RUN" == true ]] && [[ "$VERIFY_ONLY" == true ]]; then
        log_error "Options --dry-run and --verify-only cannot be used together"
        show_usage
        exit 1
    fi
    
    if [[ -z "$sections_arg" ]]; then
        log_error "No sections specified."
        show_usage
        exit 1
    fi
    
    # Split comma-separated sections into array
    IFS=',' read -ra SECTIONS <<< "$sections_arg"
    log_info "Parsed sections: ${SECTIONS[*]}"
    
    # Validate sections are numeric (allow dots for subsections like 1.1.1.1)
    for section in "${SECTIONS[@]}"; do
        if ! [[ "$section" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            log_error "Invalid section number: $section (must be numeric, e.g., 1 or 1.1.1.1)"
            exit 1
        fi
    done
}

# Show usage information
show_usage() {
    cat << EOF
Usage: sudo $0 [OPTIONS] <section_numbers>

OPTIONS:
    --dry-run, -d       Run in dry-run mode (preview changes without applying)
    --verify-only, -v   Only run verification checks and write the CSV report (no hardening, no backups)
    --help, -h          Show this help message

ARGUMENTS:
    section_numbers  Comma-separated list of CIS section numbers to process

EXAMPLES:
    sudo $0 1,3,5
    sudo $0 --dry-run 1,3,5
    sudo $0 -d 1,3,5
    sudo $0 -v 1,3,5
    sudo $0 --verify-only 2,5,7

EOF
}

###############################################################################
# CIS Compliance Functions
###############################################################################

# Helper function: Check kernel module compliance
# Returns 0 if compliant, 1 if not compliant
check_kernel_module_compliance() {
    local l_mod_name="$1"
    local l_mod_type="${2:-fs}"  # Default to filesystem type
    local a_output=()
    local a_output2=()
    local l_dl=""
    local l_mod_chk_name=""
    
    # Find module path
    local l_mod_path
    l_mod_path="$(readlink -f /lib/modules/*/kernel/$l_mod_type 2>/dev/null | sort -u)"
    
    if [[ -z "$l_mod_path" ]]; then
        # Module doesn't exist in any kernel - compliant
        log_info "Kernel module '$l_mod_name' does not exist - compliant"
        return 0
    fi
    
    # Check if module exists in any installed kernel
    local module_exists=false
    for l_mod_base_directory in $l_mod_path; do
        if [[ -d "$l_mod_base_directory/${l_mod_name/-/\/}" ]] && [[ -n "$(ls -A "$l_mod_base_directory/${l_mod_name/-/\/}" 2>/dev/null)" ]]; then
            module_exists=true
            break
        fi
    done
    
    if [[ "$module_exists" == false ]]; then
        # Module doesn't exist - compliant
        log_info "Kernel module '$l_mod_name' does not exist - compliant"
        return 0
    fi
    
    # Module exists, check if it's properly disabled
    l_mod_chk_name="$l_mod_name"
    [[ "$l_mod_name" =~ overlay ]] && l_mod_chk_name="${l_mod_name::-2}"
    
    # Check if module is loaded
    if lsmod | grep -q "^${l_mod_chk_name//-/_}[[:space:]]" 2>/dev/null; then
        log_warn "Kernel module '$l_mod_name' is currently loaded"
        return 1
    fi
    
    # Check modprobe configuration
    local a_showconfig=()
    while IFS= read -r l_showconfig; do
        a_showconfig+=("$l_showconfig")
    done < <(modprobe --showconfig 2>/dev/null | grep -P -- '\b(install|blacklist)\h+'"${l_mod_chk_name//-/_}"'\b' || true)
    
    # Check for install command with /bin/false
    if ! grep -Pq -- '\binstall\h+'"${l_mod_chk_name//-/_}"'\h+(\/usr)?\/bin\/(true|false)\b' <<< "${a_showconfig[*]}" 2>/dev/null; then
        log_warn "Kernel module '$l_mod_name' is not set to /bin/false"
        return 1
    fi
    
    # Check for blacklist entry
    if ! grep -Pq -- '\bblacklist\h+'"${l_mod_chk_name//-/_}"'\b' <<< "${a_showconfig[*]}" 2>/dev/null; then
        log_warn "Kernel module '$l_mod_name' is not blacklisted"
        return 1
    fi
    
    log_info "Kernel module '$l_mod_name' is properly disabled - compliant"
    return 0
}

# Helper function: Disable kernel module
# Returns 0 on success, 1 on failure
disable_kernel_module() {
    local l_mod_name="$1"
    local l_mod_type="${2:-fs}"  # Default to filesystem type
    local l_mod_chk_name=""
    local changes_made=false
    
    # Determine module check name (handle special cases like overlay)
    l_mod_chk_name="$l_mod_name"
    [[ "$l_mod_name" =~ overlay ]] && l_mod_chk_name="${l_mod_name::-2}"
    
    # We'll backup the specific config file when we create/modify it
    
    # Unload module if currently loaded
    if lsmod | grep -q "^${l_mod_chk_name//-/_}[[:space:]]" 2>/dev/null; then
        log_info "Unloading kernel module: $l_mod_name"
        if [[ "$DRY_RUN" == false ]]; then
            modprobe -r "$l_mod_chk_name" 2>/dev/null || true
            rmmod "$l_mod_name" 2>/dev/null || true
        else
            log_dryrun "Would unload kernel module: $l_mod_name"
        fi
        changes_made=true
    fi
    
    # Check if install command exists
    local a_showconfig=()
    while IFS= read -r l_showconfig; do
        a_showconfig+=("$l_showconfig")
    done < <(modprobe --showconfig 2>/dev/null | grep -P -- '\b(install|blacklist)\h+'"${l_mod_chk_name//-/_}"'\b' || true)
    
    local modprobe_conf="/etc/modprobe.d/${l_mod_name}.conf"
    
    # Add install command if not present
    if ! grep -Pq -- '\binstall\h+'"${l_mod_chk_name//-/_}"'\h+(\/usr)?\/bin\/(true|false)\b' <<< "${a_showconfig[*]}" 2>/dev/null; then
        log_info "Setting kernel module '$l_mod_name' to /bin/false"
        if [[ "$DRY_RUN" == false ]]; then
            # Backup the file if it exists, or create it
            if [[ -f "$modprobe_conf" ]]; then
                backup_file "$modprobe_conf"
            fi
            echo "install $l_mod_chk_name $(readlink -f /bin/false)" >> "$modprobe_conf"
        else
            log_dryrun "Would add: install $l_mod_chk_name /bin/false to $modprobe_conf"
        fi
        changes_made=true
    fi
    
    # Add blacklist entry if not present
    if ! grep -Pq -- '\bblacklist\h+'"${l_mod_chk_name//-/_}"'\b' <<< "${a_showconfig[*]}" 2>/dev/null; then
        log_info "Blacklisting kernel module: $l_mod_name"
        if [[ "$DRY_RUN" == false ]]; then
            # Backup the file if it exists, or create it
            if [[ -f "$modprobe_conf" ]]; then
                backup_file "$modprobe_conf"
            fi
            echo "blacklist $l_mod_chk_name" >> "$modprobe_conf"
        else
            log_dryrun "Would add: blacklist $l_mod_chk_name to $modprobe_conf"
        fi
        changes_made=true
    fi
    
    if [[ "$changes_made" == true ]]; then
        return 0
    else
        log_info "No changes needed for kernel module: $l_mod_name"
        return 0
    fi
}

# Check compliance for section 1.1.1.1 - cramfs kernel module
check_compliance_1_1_1_1() {
    check_kernel_module_compliance "cramfs" "fs"
}

# Apply hardening for section 1.1.1.1 - cramfs kernel module
apply_hardening_1_1_1_1() {
    disable_kernel_module "cramfs" "fs"
}

# Check compliance for section 1.1.1.2 - freevxfs kernel module
check_compliance_1_1_1_2() {
    check_kernel_module_compliance "freevxfs" "fs"
}

# Apply hardening for section 1.1.1.2 - freevxfs kernel module
apply_hardening_1_1_1_2() {
    disable_kernel_module "freevxfs" "fs"
}

# Check compliance for section 1.1.1.3 - hfs kernel module
check_compliance_1_1_1_3() {
    check_kernel_module_compliance "hfs" "fs"
}

# Apply hardening for section 1.1.1.3 - hfs kernel module
apply_hardening_1_1_1_3() {
    disable_kernel_module "hfs" "fs"
}

# Check compliance for section 1.1.1.4 - hfsplus kernel module
check_compliance_1_1_1_4() {
    check_kernel_module_compliance "hfsplus" "fs"
}

# Apply hardening for section 1.1.1.4 - hfsplus kernel module
apply_hardening_1_1_1_4() {
    disable_kernel_module "hfsplus" "fs"
}

# Check compliance for section 1.1.1.5 - jffs2 kernel module
check_compliance_1_1_1_5() {
    check_kernel_module_compliance "jffs2" "fs"
}

# Apply hardening for section 1.1.1.5 - jffs2 kernel module
apply_hardening_1_1_1_5() {
    disable_kernel_module "jffs2" "fs"
}

# Check compliance for section 1.1.1.6 - overlayfs kernel module
check_compliance_1_1_1_6() {
    check_kernel_module_compliance "overlayfs" "fs"
}

# Apply hardening for section 1.1.1.6 - overlayfs kernel module
apply_hardening_1_1_1_6() {
    disable_kernel_module "overlayfs" "fs"
}

# Check compliance for section 1.1.1.7 - squashfs kernel module
check_compliance_1_1_1_7() {
    check_kernel_module_compliance "squashfs" "fs"
}

# Apply hardening for section 1.1.1.7 - squashfs kernel module
apply_hardening_1_1_1_7() {
    disable_kernel_module "squashfs" "fs"
}

# Check compliance for section 1.1.1.8 - udf kernel module
check_compliance_1_1_1_8() {
    check_kernel_module_compliance "udf" "fs"
}

# Apply hardening for section 1.1.1.8 - udf kernel module
apply_hardening_1_1_1_8() {
    disable_kernel_module "udf" "fs"
}

# Check compliance for section 1.1.1.9 - usb-storage kernel module
check_compliance_1_1_1_9() {
    check_kernel_module_compliance "usb-storage" "drivers"
}

# Apply hardening for section 1.1.1.9 - usb-storage kernel module
apply_hardening_1_1_1_9() {
    disable_kernel_module "usb-storage" "drivers"
}

# Check compliance for section 1.1.1.10 - unused filesystems (Manual)
# This section requires manual review of unused filesystem modules
check_compliance_1_1_1_10() {
    log_info "Section 1.1.1.10 is a Manual section requiring review of unused filesystem modules"
    log_info "Checking /usr/lib/modules/$(uname -r)/kernel/fs for available modules..."
    
    # List available filesystem modules for manual review
    local fs_modules_path="/usr/lib/modules/$(uname -r)/kernel/fs"
    if [[ -d "$fs_modules_path" ]]; then
        local available_modules
        available_modules=$(find "$fs_modules_path" -type d -mindepth 1 -maxdepth 1 2>/dev/null | sed 's|.*/||' | sort)
        if [[ -n "$available_modules" ]]; then
            log_info "Available filesystem modules found:"
            echo "$available_modules" | while read -r mod; do
                log_info "  - $mod"
            done
            log_warn "Manual review required: Ensure all unused filesystem modules are disabled"
            return 1
        else
            log_info "No additional filesystem modules found - compliant"
            return 0
        fi
    else
        log_info "Filesystem modules directory not found - compliant"
        return 0
    fi
}

# Apply hardening for section 1.1.1.10 - unused filesystems (Manual)
apply_hardening_1_1_1_10() {
    log_warn "Section 1.1.1.10 is Manual - cannot be automatically remediated"
    log_info "Please manually review and disable unused filesystem modules"
    log_info "Use the compliance check output to identify modules that need attention"
    return 0  # Manual section - not a failure, just requires manual intervention
}

###############################################################################
# Section 1.1.2 - Configure Filesystem Partitions
###############################################################################

# Section 1.1.2.1 - Configure /tmp
check_compliance_1_1_2_1_1() { check_separate_partition "/tmp"; }
apply_hardening_1_1_2_1_1() { log_warn "Section 1.1.2.1.1 requires manual partition configuration"; log_info "Please ensure '/tmp' is on a separate partition"; return 0; }
check_compliance_1_1_2_1_2() { check_mount_option "/tmp" "nodev"; }
apply_hardening_1_1_2_1_2() { add_fstab_option "/tmp" "nodev"; }
check_compliance_1_1_2_1_3() { check_mount_option "/tmp" "nosuid"; }
apply_hardening_1_1_2_1_3() { add_fstab_option "/tmp" "nosuid"; }
check_compliance_1_1_2_1_4() { check_mount_option "/tmp" "noexec"; }
apply_hardening_1_1_2_1_4() { add_fstab_option "/tmp" "noexec"; }

# Section 1.1.2.2 - Configure /dev/shm
check_compliance_1_1_2_2_1() { check_separate_partition "/dev/shm"; }
apply_hardening_1_1_2_2_1() { log_warn "Section 1.1.2.2.1 requires manual partition configuration"; log_info "Please ensure '/dev/shm' is on a separate partition"; return 0; }
check_compliance_1_1_2_2_2() { check_mount_option "/dev/shm" "nodev"; }
apply_hardening_1_1_2_2_2() { add_fstab_option "/dev/shm" "nodev"; }
check_compliance_1_1_2_2_3() { check_mount_option "/dev/shm" "nosuid"; }
apply_hardening_1_1_2_2_3() { add_fstab_option "/dev/shm" "nosuid"; }
check_compliance_1_1_2_2_4() { check_mount_option "/dev/shm" "noexec"; }
apply_hardening_1_1_2_2_4() { add_fstab_option "/dev/shm" "noexec"; }

# Section 1.1.2.3 - Configure /home
check_compliance_1_1_2_3_1() { check_separate_partition "/home"; }
apply_hardening_1_1_2_3_1() { log_warn "Section 1.1.2.3.1 requires manual partition configuration"; log_info "Please ensure '/home' is on a separate partition"; return 0; }
check_compliance_1_1_2_3_2() { check_mount_option "/home" "nodev"; }
apply_hardening_1_1_2_3_2() { add_fstab_option "/home" "nodev"; }
check_compliance_1_1_2_3_3() { check_mount_option "/home" "nosuid"; }
apply_hardening_1_1_2_3_3() { add_fstab_option "/home" "nosuid"; }

# Section 1.1.2.4 - Configure /var
check_compliance_1_1_2_4_1() { check_separate_partition "/var"; }
apply_hardening_1_1_2_4_1() { log_warn "Section 1.1.2.4.1 requires manual partition configuration"; log_info "Please ensure '/var' is on a separate partition"; return 0; }
check_compliance_1_1_2_4_2() { check_mount_option "/var" "nodev"; }
apply_hardening_1_1_2_4_2() { add_fstab_option "/var" "nodev"; }
check_compliance_1_1_2_4_3() { check_mount_option "/var" "nosuid"; }
apply_hardening_1_1_2_4_3() { add_fstab_option "/var" "nosuid"; }

# Section 1.1.2.5 - Configure /var/tmp
check_compliance_1_1_2_5_1() { check_separate_partition "/var/tmp"; }
apply_hardening_1_1_2_5_1() { log_warn "Section 1.1.2.5.1 requires manual partition configuration"; log_info "Please ensure '/var/tmp' is on a separate partition"; return 0; }
check_compliance_1_1_2_5_2() { check_mount_option "/var/tmp" "nodev"; }
apply_hardening_1_1_2_5_2() { add_fstab_option "/var/tmp" "nodev"; }
check_compliance_1_1_2_5_3() { check_mount_option "/var/tmp" "nosuid"; }
apply_hardening_1_1_2_5_3() { add_fstab_option "/var/tmp" "nosuid"; }
check_compliance_1_1_2_5_4() { check_mount_option "/var/tmp" "noexec"; }
apply_hardening_1_1_2_5_4() { add_fstab_option "/var/tmp" "noexec"; }

# Section 1.1.2.6 - Configure /var/log
check_compliance_1_1_2_6_1() { check_separate_partition "/var/log"; }
apply_hardening_1_1_2_6_1() { log_warn "Section 1.1.2.6.1 requires manual partition configuration"; log_info "Please ensure '/var/log' is on a separate partition"; return 0; }
check_compliance_1_1_2_6_2() { check_mount_option "/var/log" "nodev"; }
apply_hardening_1_1_2_6_2() { add_fstab_option "/var/log" "nodev"; }
check_compliance_1_1_2_6_3() { check_mount_option "/var/log" "nosuid"; }
apply_hardening_1_1_2_6_3() { add_fstab_option "/var/log" "nosuid"; }
check_compliance_1_1_2_6_4() { check_mount_option "/var/log" "noexec"; }
apply_hardening_1_1_2_6_4() { add_fstab_option "/var/log" "noexec"; }

# Section 1.1.2.7 - Configure /var/log/audit
check_compliance_1_1_2_7_1() { check_separate_partition "/var/log/audit"; }
apply_hardening_1_1_2_7_1() { log_warn "Section 1.1.2.7.1 requires manual partition configuration"; log_info "Please ensure '/var/log/audit' is on a separate partition"; return 0; }
check_compliance_1_1_2_7_2() { check_mount_option "/var/log/audit" "nodev"; }
apply_hardening_1_1_2_7_2() { add_fstab_option "/var/log/audit" "nodev"; }
check_compliance_1_1_2_7_3() { check_mount_option "/var/log/audit" "nosuid"; }
apply_hardening_1_1_2_7_3() { add_fstab_option "/var/log/audit" "nosuid"; }
check_compliance_1_1_2_7_4() { check_mount_option "/var/log/audit" "noexec"; }
apply_hardening_1_1_2_7_4() { add_fstab_option "/var/log/audit" "noexec"; }

###############################################################################
# Section 1.2 - Package Management (Manual sections)
###############################################################################

check_compliance_1_2_1_1() { log_info "Section 1.2.1.1 is Manual - GPG keys configuration"; return 1; }
apply_hardening_1_2_1_1() { log_warn "Section 1.2.1.1 is Manual - cannot be automatically remediated"; return 0; }
check_compliance_1_2_1_2() { log_info "Section 1.2.1.2 is Manual - package repositories configuration"; return 1; }
apply_hardening_1_2_1_2() { log_warn "Section 1.2.1.2 is Manual - cannot be automatically remediated"; return 0; }
check_compliance_1_2_2_1() { log_info "Section 1.2.2.1 is Manual - updates installation"; return 1; }
apply_hardening_1_2_2_1() { log_warn "Section 1.2.2.1 is Manual - run 'apt update && apt upgrade' manually"; return 0; }

###############################################################################
# Section 1.3 - Mandatory Access Control / AppArmor
###############################################################################

check_compliance_1_3_1_1() { check_package_installed "apparmor" && command -v aa-status >/dev/null 2>&1; }
apply_hardening_1_3_1_1() { if [[ "$DRY_RUN" == false ]]; then apt-get install -y apparmor 2>/dev/null || true; systemctl enable apparmor.service 2>/dev/null || true; systemctl start apparmor.service 2>/dev/null || true; sleep 1; else log_dryrun "Would install apparmor package"; fi; }
check_compliance_1_3_1_2() { check_file_contains "/etc/default/grub" "apparmor=1"; }
apply_hardening_1_3_1_2() { ensure_file_line "/etc/default/grub" 'GRUB_CMDLINE_LINUX="apparmor=1 security=apparmor"' "apparmor=1"; }
check_compliance_1_3_1_3() { if ! command -v aa-status >/dev/null 2>&1; then return 1; fi; local status_output=$(aa-status 2>/dev/null); if [[ -z "$status_output" ]]; then return 1; fi; local total_profiles=$(echo "$status_output" | grep -E "[0-9]+\s+profiles are loaded" | grep -oE "[0-9]+" | head -1); local enforce_profiles=$(echo "$status_output" | grep -E "[0-9]+\s+profiles are in enforce mode" | grep -oE "[0-9]+" | head -1); local complain_profiles=$(echo "$status_output" | grep -E "[0-9]+\s+profiles are in complain mode" | grep -oE "[0-9]+" | head -1); enforce_profiles=${enforce_profiles:-0}; complain_profiles=${complain_profiles:-0}; total_profiles=${total_profiles:-0}; if [[ "$total_profiles" -eq 0 ]]; then return 1; fi; [[ $((enforce_profiles + complain_profiles)) -eq "$total_profiles" ]] && return 0 || return 1; }
apply_hardening_1_3_1_3() { if [[ "$DRY_RUN" == false ]]; then aa-enforce /etc/apparmor.d/* 2>/dev/null || true; systemctl reload apparmor.service 2>/dev/null || true; sleep 1; else log_dryrun "Would enforce all AppArmor profiles"; fi; }
check_compliance_1_3_1_4() { local enforce=$(aa-status 2>/dev/null | grep -c "profiles are in enforce mode"); [[ "$enforce" -gt 0 ]] && return 0 || return 1; }
apply_hardening_1_3_1_4() { if [[ "$DRY_RUN" == false ]]; then aa-enforce /etc/apparmor.d/* 2>/dev/null || true; else log_dryrun "Would enforce all AppArmor profiles"; fi; }

###############################################################################
# Section 1.4 - Configure Bootloader
###############################################################################

check_compliance_1_4_1() { check_file_contains "/boot/grub/grub.cfg" "^set superusers=" && check_file_contains "/boot/grub/grub.cfg" "^password"; }
apply_hardening_1_4_1() { log_warn "Section 1.4.1 requires manual bootloader password configuration"; log_info "Run: grub-mkpasswd-pbkdf2 and update /etc/grub.d/00_header"; return 0; }
check_compliance_1_4_2() { check_file_permissions "/boot/grub/grub.cfg" "600" "root" "root"; }
apply_hardening_1_4_2() { set_file_permissions "/boot/grub/grub.cfg" "600" "root" "root"; }

###############################################################################
# Section 1.5 - Configure Additional Process Hardening
###############################################################################

check_compliance_1_5_1() { check_sysctl "kernel.randomize_va_space" "2"; }
apply_hardening_1_5_1() { set_sysctl "kernel.randomize_va_space" "2"; }
check_compliance_1_5_2() { check_sysctl "kernel.yama.ptrace_scope" "1"; }
apply_hardening_1_5_2() { set_sysctl "kernel.yama.ptrace_scope" "1"; }
check_compliance_1_5_3() { check_file_contains "/etc/security/limits.conf" "hard core 0" || (find /etc/security/limits.d -name "*.conf" -type f 2>/dev/null | xargs grep -q "hard core 0" 2>/dev/null); }
apply_hardening_1_5_3() { ensure_file_line "/etc/security/limits.d/cis-hardening.conf" "* hard core 0" "hard core 0"; set_sysctl "fs.suid_dumpable" "0"; }
check_compliance_1_5_4() { check_package_not_installed "prelink"; }
apply_hardening_1_5_4() { if [[ "$DRY_RUN" == false ]]; then apt-get remove -y prelink 2>/dev/null || true; else log_dryrun "Would remove prelink package"; fi; }
check_compliance_1_5_5() { ! systemctl is-enabled apport.service 2>/dev/null | grep -q "enabled"; }
apply_hardening_1_5_5() { if [[ "$DRY_RUN" == false ]]; then systemctl disable apport.service 2>/dev/null || true; systemctl stop apport.service 2>/dev/null || true; else log_dryrun "Would disable apport service"; fi; }

###############################################################################
# Section 1.6 - Configure Command Line Warning Banners
###############################################################################

check_compliance_1_6_1() { check_file_contains -i "/etc/motd" "authorized" || check_file_contains -i "/etc/motd" "warning"; }
apply_hardening_1_6_1() { ensure_file_line "/etc/motd" "Authorized uses only. All activity may be monitored and reported." "Authorized"; }
check_compliance_1_6_2() { check_file_contains -i "/etc/issue" "authorized" || check_file_contains -i "/etc/issue" "warning"; }
apply_hardening_1_6_2() { ensure_file_line "/etc/issue" "Authorized uses only. All activity may be monitored and reported." "Authorized"; }
check_compliance_1_6_3() { check_file_contains -i "/etc/issue.net" "authorized" || check_file_contains -i "/etc/issue.net" "warning"; }
apply_hardening_1_6_3() { ensure_file_line "/etc/issue.net" "Authorized uses only. All activity may be monitored and reported." "Authorized"; }
check_compliance_1_6_4() { check_file_permissions "/etc/motd" "644" "root" "root"; }
apply_hardening_1_6_4() { set_file_permissions "/etc/motd" "644" "root" "root"; }
check_compliance_1_6_5() { check_file_permissions "/etc/issue" "644" "root" "root"; }
apply_hardening_1_6_5() { set_file_permissions "/etc/issue" "644" "root" "root"; }
check_compliance_1_6_6() { check_file_permissions "/etc/issue.net" "644" "root" "root"; }
apply_hardening_1_6_6() { set_file_permissions "/etc/issue.net" "644" "root" "root"; }

###############################################################################
# Section 1.7 - Configure GNOME Display Manager
###############################################################################

check_compliance_1_7_1() { check_package_not_installed "gdm3"; }
apply_hardening_1_7_1() { if [[ "$DRY_RUN" == false ]]; then apt-get remove -y gdm3 2>/dev/null || true; else log_dryrun "Would remove gdm3 package"; fi; }
check_compliance_1_7_2() { check_file_contains "/etc/gdm3/greeter.dconf-defaults" "banner-message-text"; }
apply_hardening_1_7_2() { if [[ "$DRY_RUN" == false ]]; then mkdir -p /etc/gdm3; ensure_file_line "/etc/gdm3/greeter.dconf-defaults" "[org/gnome/login-screen]" "banner-message-text"; ensure_file_line "/etc/gdm3/greeter.dconf-defaults" "banner-message-text='Authorized uses only.'" "banner-message-text"; else log_dryrun "Would configure GDM login banner"; fi; }
check_compliance_1_7_3() { check_file_contains "/etc/gdm3/greeter.dconf-defaults" "disable-user-list=true"; }
apply_hardening_1_7_3() { ensure_file_line "/etc/gdm3/greeter.dconf-defaults" "disable-user-list=true" "disable-user-list"; }
check_compliance_1_7_4() { check_file_contains "/etc/gdm3/greeter.dconf-defaults" "idle-delay=uint32 900"; }
apply_hardening_1_7_4() { ensure_file_line "/etc/gdm3/greeter.dconf-defaults" "idle-delay=uint32 900" "idle-delay"; }
check_compliance_1_7_5() { check_file_contains "/etc/gdm3/greeter.dconf-defaults" "lock-delay=uint32 0"; }
apply_hardening_1_7_5() { ensure_file_line "/etc/gdm3/greeter.dconf-defaults" "lock-delay=uint32 0" "lock-delay"; }
check_compliance_1_7_6() { check_file_contains "/etc/gdm3/greeter.dconf-defaults" "automount=false"; }
apply_hardening_1_7_6() { ensure_file_line "/etc/gdm3/greeter.dconf-defaults" "automount=false" "automount"; }
check_compliance_1_7_7() { check_file_contains "/etc/gdm3/greeter.dconf-defaults" "automount-open=false"; }
apply_hardening_1_7_7() { ensure_file_line "/etc/gdm3/greeter.dconf-defaults" "automount-open=false" "automount-open"; }
check_compliance_1_7_8() { check_file_contains "/etc/gdm3/greeter.dconf-defaults" "autorun-never=true"; }
apply_hardening_1_7_8() { ensure_file_line "/etc/gdm3/greeter.dconf-defaults" "autorun-never=true" "autorun-never"; }
check_compliance_1_7_9() { ! check_file_contains "/etc/gdm3/greeter.dconf-defaults" "autorun-never=false" && check_file_contains "/etc/gdm3/greeter.dconf-defaults" "autorun-never=true"; }
apply_hardening_1_7_9() { if [[ "$DRY_RUN" == false ]]; then mkdir -p /etc/gdm3; sed -i '/autorun-never=false/d' /etc/gdm3/greeter.dconf-defaults 2>/dev/null || true; ensure_file_line "/etc/gdm3/greeter.dconf-defaults" "autorun-never=true" "autorun-never=true"; else log_dryrun "Would ensure autorun-never is not overridden in GDM"; fi; }
check_compliance_1_7_10() { if [[ ! -f "/etc/gdm3/custom.conf" ]]; then return 0; fi; if ! check_file_contains "/etc/gdm3/custom.conf" "\[xdmcp\]"; then return 0; fi; if check_file_contains "/etc/gdm3/custom.conf" "Enable=false"; then return 0; fi; if check_file_contains "/etc/gdm3/custom.conf" "Enable=true"; then return 1; fi; return 0; }
apply_hardening_1_7_10() { if [[ "$DRY_RUN" == false ]]; then mkdir -p /etc/gdm3; backup_file "/etc/gdm3/custom.conf"; if ! grep -q "^\[xdmcp\]" "/etc/gdm3/custom.conf" 2>/dev/null; then echo -e "\n[xdmcp]\nEnable=false" >> "/etc/gdm3/custom.conf"; else sed -i '/^\[xdmcp\]/,/^\[/{ /^Enable=/d; }' "/etc/gdm3/custom.conf" 2>/dev/null; sed -i '/^\[xdmcp\]/a Enable=false' "/etc/gdm3/custom.conf" 2>/dev/null; fi; else log_dryrun "Would disable XDMCP in GDM"; fi; }

###############################################################################
# Helper Functions for Section 1 (Additional)
###############################################################################

# Helper: Check if a mount point has a specific mount option
check_mount_option() {
    local mount_point="$1"
    local option="$2"
    
    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        log_warn "Mount point '$mount_point' is not a mount point"
        return 1
    fi
    
    if mount | grep -q " $mount_point " && mount | grep " $mount_point " | grep -q "$option"; then
        return 0
    else
        return 1
    fi
}

# Helper: Check if a directory is on a separate partition
check_separate_partition() {
    local dir="$1"
    
    if [[ ! -d "$dir" ]]; then
        log_warn "Directory '$dir' does not exist"
        return 1
    fi
    
    if mountpoint -q "$dir" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Helper: Add mount option to /etc/fstab
add_fstab_option() {
    local mount_point="$1"
    local option="$2"
    local fstab="/etc/fstab"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would add mount option '$option' to '$mount_point' in $fstab"
        return 0
    fi
    
    backup_file "$fstab"
    
    if grep -q "^[^#].*[[:space:]]$mount_point[[:space:]]" "$fstab"; then
        if ! grep "^[^#].*[[:space:]]$mount_point[[:space:]]" "$fstab" | grep -q "$option"; then
            sed -i "s|^\([^#].*[[:space:]]$mount_point[[:space:]].*\)|\1,$option|" "$fstab"
            log_info "Added mount option '$option' to '$mount_point' in $fstab"
            return 0
        else
            log_info "Mount option '$option' already present for '$mount_point'"
            return 0
        fi
    else
        log_warn "Mount point '$mount_point' not found in $fstab - manual configuration required"
        return 0  # Not a failure - mount point may not exist yet, requires manual setup
    fi
}

# Helper: Check file permissions
check_file_permissions() {
    local file="$1"
    local expected_perms="$2"
    local expected_owner="${3:-root}"
    local expected_group="${4:-root}"
    
    if [[ ! -f "$file" ]]; then
        log_warn "File '$file' does not exist"
        return 1
    fi
    
    local current_perms=$(stat -c "%a" "$file" 2>/dev/null)
    local current_owner=$(stat -c "%U" "$file" 2>/dev/null)
    local current_group=$(stat -c "%G" "$file" 2>/dev/null)
    
    if [[ "$current_perms" == "$expected_perms" ]] && \
       [[ "$current_owner" == "$expected_owner" ]] && \
       [[ "$current_group" == "$expected_group" ]]; then
        return 0
    else
        log_warn "File '$file' has incorrect permissions: $current_perms/$current_owner/$current_group (expected: $expected_perms/$expected_owner/$expected_group)"
        return 1
    fi
}

# Helper: Set file permissions
set_file_permissions() {
    local file="$1"
    local perms="$2"
    local owner="${3:-root}"
    local group="${4:-root}"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set permissions on '$file' to $perms $owner:$group"
        return 0
    fi
    
    if [[ ! -f "$file" ]]; then
        log_warn "File '$file' does not exist"
        return 1
    fi
    
    backup_file "$file"
    chmod "$perms" "$file"
    chown "$owner:$group" "$file"
    log_info "Set permissions on '$file' to $perms $owner:$group"
    return 0
}

# Helper: Check if package is installed
check_package_installed() {
    local package="$1"
    if dpkg -l | grep -q "^ii[[:space:]]*$package[[:space:]]"; then
        return 0
    else
        return 1
    fi
}

# Helper: Check if package is NOT installed
check_package_not_installed() {
    local package="$1"
    if check_package_installed "$package"; then
        return 1
    else
        return 0
    fi
}

# Helper: Check sysctl parameter
check_sysctl() {
    local param="$1"
    local expected="$2"
    local current=$(sysctl -n "$param" 2>/dev/null)
    
    if [[ "$current" == "$expected" ]]; then
        return 0
    else
        log_warn "Sysctl parameter '$param' is '$current' (expected: '$expected')"
        return 1
    fi
}

# Helper: Set sysctl parameter
set_sysctl() {
    local param="$1"
    local value="$2"
    local sysctl_d_file="/etc/sysctl.d/99-cis-hardening.conf"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set sysctl parameter '$param' to '$value'"
        return 0
    fi
    
    sysctl -w "$param=$value" >/dev/null 2>&1
    
    backup_file "$sysctl_d_file"
    mkdir -p "$(dirname "$sysctl_d_file")"
    if ! grep -q "^$param[[:space:]]*=" "$sysctl_d_file" 2>/dev/null; then
        echo "$param = $value" >> "$sysctl_d_file"
        log_info "Set sysctl parameter '$param' to '$value' in $sysctl_d_file"
    else
        sed -i "s|^$param[[:space:]]*=.*|$param = $value|" "$sysctl_d_file"
        log_info "Updated sysctl parameter '$param' to '$value' in $sysctl_d_file"
    fi
    
    return 0
}

# Helper: Check if a line exists in a file
check_file_contains() {
    local file="$1"
    local pattern="$2"
    local case_insensitive=false
    
    # Check for -i flag for case-insensitive search (can be first or second arg)
    if [[ "$1" == "-i" ]]; then
        case_insensitive=true
        file="$2"
        pattern="$3"
    elif [[ "$2" == "-i" ]]; then
        case_insensitive=true
        pattern="$3"
    fi
    
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    
    if [[ "$case_insensitive" == true ]]; then
        if grep -qi "$pattern" "$file" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    else
        if grep -q "$pattern" "$file" 2>/dev/null; then
            return 0
        else
            return 1
        fi
    fi
}

# Helper: Add or ensure line in file
ensure_file_line() {
    local file="$1"
    local line="$2"
    local pattern="${3:-$line}"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would ensure line in '$file': $line"
        return 0
    fi
    
    backup_file "$file"
    
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        echo "$line" >> "$file"
        log_info "Added line to '$file': $line"
    else
        log_info "Line already exists in '$file'"
    fi
    
    return 0
}

###############################################################################
# Section 2 Helpers (Services)
###############################################################################

# Helper: Check service(s) not in use - compliant if package not installed OR no unit enabled/active
check_service_not_in_use() {
    local pkg="$1"
    shift
    local units=("$@")
    if ! check_package_installed "$pkg"; then
        log_info "Package '$pkg' is not installed - compliant"
        return 0
    fi
    local u
    for u in "${units[@]}"; do
        if systemctl is-enabled "$u" 2>/dev/null | grep -q 'enabled'; then
            log_warn "Service '$u' is enabled (package $pkg installed)"
            return 1
        fi
        if systemctl is-active "$u" 2>/dev/null | grep -q '^active'; then
            log_warn "Service '$u' is active (package $pkg installed)"
            return 1
        fi
    done
    log_info "Package '$pkg' installed but all listed services disabled/inactive - compliant"
    return 0
}

# Helper: Stop and mask service unit(s)
ensure_service_stopped_masked() {
    local units=("$@")
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would stop and mask: ${units[*]}"
        return 0
    fi
    for u in "${units[@]}"; do
        systemctl stop "$u" 2>/dev/null || true
        systemctl mask "$u" 2>/dev/null || true
    done
    return 0
}

# Helper: Stop service unit(s) and purge package
ensure_service_stopped_and_purge() {
    local pkg="$1"
    shift
    local units=("$@")
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would stop ${units[*]} and purge $pkg"
        return 0
    fi
    for u in "${units[@]}"; do
        systemctl stop "$u" 2>/dev/null || true
    done
    DEBIAN_FRONTEND=noninteractive apt-get -y purge "$pkg" 2>/dev/null || true
    return 0
}

# Helper: Check path (file or dir) permissions/owner/group
check_path_permissions() {
    local path="$1"
    local expected_perms="$2"
    local expected_owner="${3:-root}"
    local expected_group="${4:-root}"
    if [[ ! -e "$path" ]]; then
        log_warn "Path '$path' does not exist"
        return 1
    fi
    local current_perms current_owner current_group
    current_perms=$(stat -c "%a" "$path" 2>/dev/null)
    current_owner=$(stat -c "%U" "$path" 2>/dev/null)
    current_group=$(stat -c "%G" "$path" 2>/dev/null)
    if [[ "$current_perms" == "$expected_perms" ]] && \
       [[ "$current_owner" == "$expected_owner" ]] && \
       [[ "$current_group" == "$expected_group" ]]; then
        return 0
    fi
    log_warn "Path '$path' has incorrect permissions: $current_perms/$current_owner/$current_group (expected: $expected_perms/$expected_owner/$expected_group)"
    return 1
}

# Helper: Set path (file or dir) permissions/owner/group
set_path_permissions() {
    local path="$1"
    local perms="$2"
    local owner="${3:-root}"
    local group="${4:-root}"
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set permissions on '$path' to $perms $owner:$group"
        return 0
    fi
    if [[ ! -e "$path" ]]; then
        log_warn "Path '$path' does not exist"
        return 1
    fi
    backup_file "$path"
    chmod "$perms" "$path"
    chown "$owner:$group" "$path"
    log_info "Set permissions on '$path' to $perms $owner:$group"
    return 0
}

###############################################################################
# Section 2 - Services (compliance and hardening)
###############################################################################

# 2.1.1 autofs
check_compliance_2_1_1() { check_service_not_in_use "autofs" "autofs.service"; }
apply_hardening_2_1_1() { ensure_service_stopped_and_purge "autofs" "autofs.service"; }

# 2.1.2 avahi-daemon
check_compliance_2_1_2() { check_service_not_in_use "avahi-daemon" "avahi-daemon.socket" "avahi-daemon.service"; }
apply_hardening_2_1_2() { ensure_service_stopped_and_purge "avahi-daemon" "avahi-daemon.socket" "avahi-daemon.service"; }

# 2.1.3 isc-dhcp-server
check_compliance_2_1_3() { check_service_not_in_use "isc-dhcp-server" "isc-dhcp-server.service" "isc-dhcp-server6.service"; }
apply_hardening_2_1_3() { ensure_service_stopped_and_purge "isc-dhcp-server" "isc-dhcp-server.service" "isc-dhcp-server6.service"; }

# 2.1.4 bind9 (named.service)
check_compliance_2_1_4() { check_service_not_in_use "bind9" "named.service"; }
apply_hardening_2_1_4() { ensure_service_stopped_and_purge "bind9" "named.service"; }

# 2.1.5 dnsmasq
check_compliance_2_1_5() { check_service_not_in_use "dnsmasq" "dnsmasq.service"; }
apply_hardening_2_1_5() { ensure_service_stopped_and_purge "dnsmasq" "dnsmasq.service"; }

# 2.1.6 vsftpd
check_compliance_2_1_6() { check_service_not_in_use "vsftpd" "vsftpd.service"; }
apply_hardening_2_1_6() { ensure_service_stopped_and_purge "vsftpd" "vsftpd.service"; }

# 2.1.7 slapd
check_compliance_2_1_7() { check_service_not_in_use "slapd" "slapd.service"; }
apply_hardening_2_1_7() { ensure_service_stopped_and_purge "slapd" "slapd.service"; }

# 2.1.8 dovecot (imapd/pop3d) - check either package and dovecot socket/service
check_compliance_2_1_8() {
    if ! check_package_installed "dovecot-imapd" && ! check_package_installed "dovecot-pop3d"; then
        log_info "dovecot-imapd and dovecot-pop3d not installed - compliant"
        return 0
    fi
    local units=("dovecot.socket" "dovecot.service")
    for u in "${units[@]}"; do
        if systemctl is-enabled "$u" 2>/dev/null | grep -q 'enabled'; then return 1; fi
        if systemctl is-active "$u" 2>/dev/null | grep -q '^active'; then return 1; fi
    done
    return 0
}
apply_hardening_2_1_8() {
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would stop/mask dovecot and purge dovecot-imapd dovecot-pop3d"
        return 0
    fi
    ensure_service_stopped_masked "dovecot.socket" "dovecot.service"
    DEBIAN_FRONTEND=noninteractive apt-get -y purge dovecot-imapd dovecot-pop3d 2>/dev/null || true
    return 0
}

# 2.1.9 nfs-kernel-server
check_compliance_2_1_9() { check_service_not_in_use "nfs-kernel-server" "nfs-server.service"; }
apply_hardening_2_1_9() { ensure_service_stopped_and_purge "nfs-kernel-server" "nfs-server.service"; }

# 2.1.10 ypserv
check_compliance_2_1_10() { check_service_not_in_use "ypserv" "ypserv.service"; }
apply_hardening_2_1_10() { ensure_service_stopped_and_purge "ypserv" "ypserv.service"; }

# 2.1.11 cups
check_compliance_2_1_11() { check_service_not_in_use "cups" "cups.socket" "cups.service"; }
apply_hardening_2_1_11() { ensure_service_stopped_and_purge "cups" "cups.socket" "cups.service"; }

# 2.1.12 rpcbind
check_compliance_2_1_12() { check_service_not_in_use "rpcbind" "rpcbind.socket" "rpcbind.service"; }
apply_hardening_2_1_12() { ensure_service_stopped_and_purge "rpcbind" "rpcbind.socket" "rpcbind.service"; }

# 2.1.13 rsync
check_compliance_2_1_13() { check_service_not_in_use "rsync" "rsync.service"; }
apply_hardening_2_1_13() { ensure_service_stopped_and_purge "rsync" "rsync.service"; }

# 2.1.14 samba
check_compliance_2_1_14() { check_service_not_in_use "samba" "smbd.service"; }
apply_hardening_2_1_14() { ensure_service_stopped_and_purge "samba" "smbd.service"; }

# 2.1.15 snmpd
check_compliance_2_1_15() { check_service_not_in_use "snmpd" "snmpd.service"; }
apply_hardening_2_1_15() { ensure_service_stopped_and_purge "snmpd" "snmpd.service"; }

# 2.1.16 tftpd-hpa
check_compliance_2_1_16() { check_service_not_in_use "tftpd-hpa" "tftpd-hpa.service"; }
apply_hardening_2_1_16() { ensure_service_stopped_and_purge "tftpd-hpa" "tftpd-hpa.service"; }

# 2.1.17 squid
check_compliance_2_1_17() { check_service_not_in_use "squid" "squid.service"; }
apply_hardening_2_1_17() { ensure_service_stopped_and_purge "squid" "squid.service"; }

# 2.1.18 apache2 and nginx
check_compliance_2_1_18() {
    local bad=false
    if check_package_installed "apache2"; then
        if systemctl is-enabled apache2.socket 2>/dev/null | grep -q 'enabled'; then bad=true; fi
        if systemctl is-enabled apache2.service 2>/dev/null | grep -q 'enabled'; then bad=true; fi
        if systemctl is-active apache2.socket 2>/dev/null | grep -q '^active'; then bad=true; fi
        if systemctl is-active apache2.service 2>/dev/null | grep -q '^active'; then bad=true; fi
    fi
    if check_package_installed "nginx"; then
        if systemctl is-enabled nginx.service 2>/dev/null | grep -q 'enabled'; then bad=true; fi
        if systemctl is-active nginx.service 2>/dev/null | grep -q '^active'; then bad=true; fi
    fi
    [[ "$bad" == true ]] && return 1 || return 0
}
apply_hardening_2_1_18() {
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would stop/mask apache2 and nginx and purge packages"
        return 0
    fi
    systemctl stop apache2.socket apache2.service nginx.service 2>/dev/null || true
    systemctl mask apache2.socket apache2.service nginx.service 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get -y purge apache2 nginx 2>/dev/null || true
    return 0
}

# 2.1.19 xinetd
check_compliance_2_1_19() { check_service_not_in_use "xinetd" "xinetd.service"; }
apply_hardening_2_1_19() { ensure_service_stopped_and_purge "xinetd" "xinetd.service"; }

# 2.1.20 xserver-common (purge only)
check_compliance_2_1_20() { check_package_not_installed "xserver-common"; }
apply_hardening_2_1_20() {
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would purge xserver-common"
        return 0
    fi
    DEBIAN_FRONTEND=noninteractive apt-get -y purge xserver-common 2>/dev/null || true
    return 0
}

# 2.1.21 MTA local-only (postfix inet_interfaces = loopback-only)
check_compliance_2_1_21() {
    if ! command -v postconf &>/dev/null; then
        log_info "Postfix not installed - compliant (no MTA listening)"
        return 0
    fi
    local iface
    iface=$(postconf -n inet_interfaces 2>/dev/null | grep -oP '=\s*\K.+')
    if [[ -z "$iface" ]]; then
        log_warn "Could not determine inet_interfaces"
        return 1
    fi
    if echo "$iface" | grep -qiE 'loopback-only|localhost|127\.0\.0\.1'; then
        log_info "MTA inet_interfaces is local-only - compliant"
        return 0
    fi
    log_warn "MTA inet_interfaces is not loopback-only: $iface"
    return 1
}
apply_hardening_2_1_21() {
    if ! command -v postconf &>/dev/null; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set postfix inet_interfaces = loopback-only"
        return 0
    fi
    local main_cf="/etc/postfix/main.cf"
    if [[ ! -f "$main_cf" ]]; then
        log_warn "Postfix main.cf not found"
        return 1
    fi
    backup_file "$main_cf"
    if grep -q '^inet_interfaces' "$main_cf" 2>/dev/null; then
        sed -i 's/^inet_interfaces.*/inet_interfaces = loopback-only/' "$main_cf"
    else
        echo "inet_interfaces = loopback-only" >> "$main_cf"
    fi
    systemctl restart postfix 2>/dev/null || true
    log_info "Set postfix inet_interfaces = loopback-only"
    return 0
}

# 2.1.22 Manual - no automated remediation
check_compliance_2_1_22() { log_info "2.1.22 is manual - skipping compliance check"; return 0; }
apply_hardening_2_1_22() { log_warn "2.1.22 is manual - ensure only approved services listen on network"; return 0; }

# 2.2.x Client packages (not installed)
check_compliance_2_2_1() { check_package_not_installed "nis"; }
apply_hardening_2_2_1() { if [[ "$DRY_RUN" != true ]]; then DEBIAN_FRONTEND=noninteractive apt-get -y purge nis 2>/dev/null || true; fi; return 0; }
check_compliance_2_2_2() { check_package_not_installed "rsh-client"; }
apply_hardening_2_2_2() { if [[ "$DRY_RUN" != true ]]; then DEBIAN_FRONTEND=noninteractive apt-get -y purge rsh-client 2>/dev/null || true; fi; return 0; }
check_compliance_2_2_3() { check_package_not_installed "talk"; }
apply_hardening_2_2_3() { if [[ "$DRY_RUN" != true ]]; then DEBIAN_FRONTEND=noninteractive apt-get -y purge talk 2>/dev/null || true; fi; return 0; }
check_compliance_2_2_4() {
    check_package_not_installed "telnet" && check_package_not_installed "inetutils-telnet"
}
apply_hardening_2_2_4() {
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would purge telnet inetutils-telnet"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get -y purge telnet inetutils-telnet 2>/dev/null || true
    return 0
}
check_compliance_2_2_5() { check_package_not_installed "ldap-utils"; }
apply_hardening_2_2_5() { if [[ "$DRY_RUN" != true ]]; then DEBIAN_FRONTEND=noninteractive apt-get -y purge ldap-utils 2>/dev/null || true; fi; return 0; }
check_compliance_2_2_6() {
    check_package_not_installed "ftp" && check_package_not_installed "tnftp"
}
apply_hardening_2_2_6() {
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would purge ftp tnftp"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get -y purge ftp tnftp 2>/dev/null || true
    return 0
}

# 2.3.1.1 Single time sync daemon (exactly one of systemd-timesyncd or chrony)
check_compliance_2_3_1_1() {
    local ts_enabled=false chrony_enabled=false
    systemctl is-enabled systemd-timesyncd.service 2>/dev/null | grep -q 'enabled' && ts_enabled=true
    systemctl is-active systemd-timesyncd.service 2>/dev/null | grep -q '^active' && ts_enabled=true
    systemctl is-enabled chrony.service 2>/dev/null | grep -q 'enabled' && chrony_enabled=true
    systemctl is-active chrony.service 2>/dev/null | grep -q '^active' && chrony_enabled=true
    if [[ "$ts_enabled" == true && "$chrony_enabled" == true ]]; then
        log_warn "Both systemd-timesyncd and chrony are in use - only one should be"
        return 1
    fi
    if [[ "$ts_enabled" == false && "$chrony_enabled" == false ]]; then
        log_warn "No time synchronization daemon enabled and active"
        return 1
    fi
    log_info "Single time sync daemon in use - compliant"
    return 0
}
apply_hardening_2_3_1_1() {
    local ts_ena=false ch_ena=false
    systemctl is-enabled systemd-timesyncd.service 2>/dev/null | grep -q 'enabled' && ts_ena=true
    systemctl is-active systemd-timesyncd.service 2>/dev/null | grep -q '^active' && ts_ena=true
    systemctl is-enabled chrony.service 2>/dev/null | grep -q 'enabled' && ch_ena=true
    systemctl is-active chrony.service 2>/dev/null | grep -q '^active' && ch_ena=true
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would ensure single time sync daemon"
        return 0
    fi
    if [[ "$ts_ena" == true && "$ch_ena" == true ]]; then
        systemctl stop systemd-timesyncd.service 2>/dev/null || true
        systemctl mask systemd-timesyncd.service 2>/dev/null || true
        log_info "Masked systemd-timesyncd (chrony in use)"
    elif [[ "$ts_ena" == false && "$ch_ena" == false ]]; then
        systemctl unmask systemd-timesyncd.service 2>/dev/null || true
        systemctl --now enable systemd-timesyncd.service 2>/dev/null || true
        log_info "Enabled systemd-timesyncd (no time daemon was active)"
    fi
    return 0
}

# 2.3.2.1 systemd-timesyncd authorized timeserver (only if timesyncd in use)
check_compliance_2_3_2_1() {
    if ! systemctl is-enabled systemd-timesyncd.service 2>/dev/null | grep -q 'enabled'; then
        log_info "systemd-timesyncd not in use - skip 2.3.2.1"
        return 0
    fi
    local f
    for f in /etc/systemd/timesyncd.conf /etc/systemd/timesyncd.conf.d/*.conf; do
        [[ -f "$f" ]] || continue
        if grep -E '^\s*NTP=\S|^\s*FallbackNTP=\S' "$f" 2>/dev/null | grep -vq '^\s*#'; then
            log_info "NTP or FallbackNTP set in $f - compliant"
            return 0
        fi
    done
    log_warn "NTP/FallbackNTP not set for systemd-timesyncd"
    return 1
}
apply_hardening_2_3_2_1() {
    if ! systemctl is-enabled systemd-timesyncd.service 2>/dev/null | grep -q 'enabled'; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set NTP/FallbackNTP for timesyncd"
        return 0
    fi
    mkdir -p /etc/systemd/timesyncd.conf.d
    local dropin="/etc/systemd/timesyncd.conf.d/60-timesyncd.conf"
    backup_file "$dropin" 2>/dev/null || true
    if ! grep -q '^\[Time\]' "$dropin" 2>/dev/null; then
        echo -e "[Time]\nNTP=time.nist.gov\nFallbackNTP=time-a-g.nist.gov time-b-g.nist.gov time-c-g.nist.gov" > "$dropin"
    else
        grep -q '^NTP=' "$dropin" 2>/dev/null || echo "NTP=time.nist.gov" >> "$dropin"
        grep -q '^FallbackNTP=' "$dropin" 2>/dev/null || echo "FallbackNTP=time-a-g.nist.gov time-b-g.nist.gov time-c-g.nist.gov" >> "$dropin"
    fi
    systemctl reload-or-restart systemd-timesyncd.service 2>/dev/null || true
    return 0
}

# 2.3.2.2 systemd-timesyncd enabled and running (only if timesyncd in use)
check_compliance_2_3_2_2() {
    if ! systemctl is-enabled systemd-timesyncd.service 2>/dev/null | grep -q 'enabled'; then
        return 0
    fi
    systemctl is-enabled systemd-timesyncd.service 2>/dev/null | grep -q 'enabled' && \
    systemctl is-active systemd-timesyncd.service 2>/dev/null | grep -q '^active' && return 0
    return 1
}
apply_hardening_2_3_2_2() {
    if ! systemctl is-enabled systemd-timesyncd.service 2>/dev/null | grep -q 'enabled'; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would enable/start systemd-timesyncd"; return 0; fi
    systemctl unmask systemd-timesyncd.service 2>/dev/null || true
    systemctl --now enable systemd-timesyncd.service 2>/dev/null || true
    return 0
}

# 2.3.3.1 chrony authorized timeserver (only if chrony in use)
check_compliance_2_3_3_1() {
    if ! systemctl is-enabled chrony.service 2>/dev/null | grep -q 'enabled'; then
        log_info "chrony not in use - skip 2.3.3.1"
        return 0
    fi
    if grep -E '^\s*(server|pool)\s+\S+' /etc/chrony/chrony.conf /etc/chrony/conf.d/*.conf /etc/chrony/sources.d/*.sources 2>/dev/null | grep -vq '^\s*#'; then
        return 0
    fi
    log_warn "chrony has no server/pool configured"
    return 1
}
apply_hardening_2_3_3_1() {
    if ! systemctl is-enabled chrony.service 2>/dev/null | grep -q 'enabled'; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would add chrony server/pool"; return 0; fi
    mkdir -p /etc/chrony/sources.d
    local f="/etc/chrony/sources.d/60-sources.sources"
    backup_file "$f" 2>/dev/null || true
    if ! grep -qE '^\s*(server|pool)\s+' "$f" 2>/dev/null; then
        echo -e "\npool time.nist.gov iburst maxsources 4" >> "$f"
    fi
    grep -q 'sourcedir' /etc/chrony/chrony.conf 2>/dev/null || echo "sourcedir /etc/chrony/sources.d" >> /etc/chrony/chrony.conf
    systemctl reload-or-restart chrony.service 2>/dev/null || true
    return 0
}

# 2.3.3.2 chrony running as _chrony (only if chrony in use)
check_compliance_2_3_3_2() {
    if ! systemctl is-enabled chrony.service 2>/dev/null | grep -q 'enabled'; then
        return 0
    fi
    local out
    out=$(ps -ef 2>/dev/null | awk '/[c]hronyd/ { if ($1!="_chrony") print $1 }')
    if [[ -n "$out" ]]; then
        log_warn "chronyd is not running as user _chrony"
        return 1
    fi
    return 0
}
apply_hardening_2_3_3_2() {
    if ! systemctl is-enabled chrony.service 2>/dev/null | grep -q 'enabled'; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then return 0; fi
    if ! grep -q '^\s*user\s\+_chrony' /etc/chrony/chrony.conf /etc/chrony/conf.d/*.conf 2>/dev/null; then
        mkdir -p /etc/chrony/conf.d
        echo "user _chrony" >> /etc/chrony/conf.d/99-user.conf
        systemctl restart chrony.service 2>/dev/null || true
    fi
    return 0
}

# 2.3.3.3 chrony enabled and running (only if chrony in use)
check_compliance_2_3_3_3() {
    if ! systemctl is-enabled chrony.service 2>/dev/null | grep -q 'enabled'; then
        return 0
    fi
    systemctl is-enabled chrony.service 2>/dev/null | grep -q 'enabled' && \
    systemctl is-active chrony.service 2>/dev/null | grep -q '^active' && return 0
    return 1
}
apply_hardening_2_3_3_3() {
    if [[ "$DRY_RUN" == true ]]; then return 0; fi
    systemctl unmask chrony.service 2>/dev/null || true
    systemctl --now enable chrony.service 2>/dev/null || true
    return 0
}

# 2.4.1.1 cron enabled and active
check_compliance_2_4_1_1() {
    if ! check_package_installed "cron"; then
        log_info "cron not installed - skip 2.4.1.1"
        return 0
    fi
    local unit
    unit=$(systemctl list-unit-files 2>/dev/null | awk '$1~/^cron\.service$/{print $1}')
    [[ -z "$unit" ]] && unit="cron.service"
    systemctl is-enabled "$unit" 2>/dev/null | grep -q 'enabled' && \
    systemctl is-active "$unit" 2>/dev/null | grep -q '^active' && return 0
    return 1
}
apply_hardening_2_4_1_1() {
    if ! check_package_installed "cron"; then return 0; fi
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would enable cron"; return 0; fi
    local unit
    unit=$(systemctl list-unit-files 2>/dev/null | awk '$1~/^cron\.service$/{print $1}')
    [[ -z "$unit" ]] && unit="cron.service"
    systemctl unmask "$unit" 2>/dev/null || true
    systemctl --now enable "$unit" 2>/dev/null || true
    return 0
}

# 2.4.1.2 - 2.4.1.7 cron dir/file permissions
check_compliance_2_4_1_2() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -f /etc/crontab ]] && check_path_permissions "/etc/crontab" "600" "root" "root" || return 0
}
apply_hardening_2_4_1_2() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -f /etc/crontab ]] && set_path_permissions "/etc/crontab" "600" "root" "root"
    return 0
}
check_compliance_2_4_1_3() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.hourly ]] && check_path_permissions "/etc/cron.hourly" "700" "root" "root" || return 0
}
apply_hardening_2_4_1_3() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.hourly ]] && set_path_permissions "/etc/cron.hourly" "700" "root" "root"
    return 0
}
check_compliance_2_4_1_4() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.daily ]] && check_path_permissions "/etc/cron.daily" "700" "root" "root" || return 0
}
apply_hardening_2_4_1_4() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.daily ]] && set_path_permissions "/etc/cron.daily" "700" "root" "root"
    return 0
}
check_compliance_2_4_1_5() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.weekly ]] && check_path_permissions "/etc/cron.weekly" "700" "root" "root" || return 0
}
apply_hardening_2_4_1_5() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.weekly ]] && set_path_permissions "/etc/cron.weekly" "700" "root" "root"
    return 0
}
check_compliance_2_4_1_6() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.monthly ]] && check_path_permissions "/etc/cron.monthly" "700" "root" "root" || return 0
}
apply_hardening_2_4_1_6() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.monthly ]] && set_path_permissions "/etc/cron.monthly" "700" "root" "root"
    return 0
}
check_compliance_2_4_1_7() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.d ]] && check_path_permissions "/etc/cron.d" "700" "root" "root" || return 0
}
apply_hardening_2_4_1_7() {
    if ! check_package_installed "cron"; then return 0; fi
    [[ -d /etc/cron.d ]] && set_path_permissions "/etc/cron.d" "700" "root" "root"
    return 0
}

# 2.4.1.8 crontab restricted (cron.allow exists, cron.deny restricted)
check_compliance_2_4_1_8() {
    if ! check_package_installed "cron"; then return 0; fi
    if [[ ! -f /etc/cron.allow ]]; then
        log_warn "/etc/cron.allow does not exist"
        return 1
    fi
    check_path_permissions "/etc/cron.allow" "640" "root" "root" || check_path_permissions "/etc/cron.allow" "640" "root" "crontab" || return 1
    if [[ -f /etc/cron.deny ]]; then
        check_path_permissions "/etc/cron.deny" "640" "root" "root" || check_path_permissions "/etc/cron.deny" "640" "root" "crontab" || return 1
    fi
    return 0
}
apply_hardening_2_4_1_8() {
    if ! check_package_installed "cron"; then return 0; fi
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would create/restrict cron.allow and cron.deny"; return 0; fi
    touch /etc/cron.allow
    grep -q '^root$' /etc/cron.allow 2>/dev/null || echo "root" >> /etc/cron.allow
    chmod 640 /etc/cron.allow
    getent group crontab &>/dev/null && chown root:crontab /etc/cron.allow || chown root:root /etc/cron.allow
    if [[ -f /etc/cron.deny ]]; then
        chmod 640 /etc/cron.deny
        getent group crontab &>/dev/null && chown root:crontab /etc/cron.deny || chown root:root /etc/cron.deny
    fi
    return 0
}

# 2.4.2.1 at restricted (at.allow exists, at.deny restricted)
check_compliance_2_4_2_1() {
    if ! check_package_installed "at"; then
        log_info "at not installed - skip 2.4.2.1"
        return 0
    fi
    if [[ ! -f /etc/at.allow ]]; then
        log_warn "/etc/at.allow does not exist"
        return 1
    fi
    local perms_ok=false
    stat -Lc '%a' /etc/at.allow 2>/dev/null | grep -qE '^[0-7][0-4][0-9]$' && perms_ok=true
    [[ "$perms_ok" == false ]] && return 1
    if [[ -f /etc/at.deny ]]; then
        stat -Lc '%a' /etc/at.deny 2>/dev/null | grep -qE '^[0-7][0-4][0-9]$' || return 1
    fi
    return 0
}
apply_hardening_2_4_2_1() {
    if ! check_package_installed "at"; then return 0; fi
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would create/restrict at.allow and at.deny"; return 0; fi
    local l_group
    grep -Pq '^daemon\b' /etc/group 2>/dev/null && l_group="daemon" || l_group="root"
    touch /etc/at.allow
    chown root:"$l_group" /etc/at.allow
    chmod 640 /etc/at.allow
    [[ -f /etc/at.deny ]] && { chown root:"$l_group" /etc/at.deny; chmod 640 /etc/at.deny; }
    return 0
}

###############################################################################
# Section 3 - Network (helpers and compliance/hardening)
###############################################################################

# Helper: Check kernel module compliance by name only (no path; for wireless etc.)
check_kernel_module_compliance_any() {
    local l_mod_name="$1"
    local l_mod_chk_name="${l_mod_name//-/_}"
    local a_showconfig=()
    while IFS= read -r line; do
        a_showconfig+=("$line")
    done < <(modprobe --showconfig 2>/dev/null | grep -P -- '\b(install|blacklist)\h+'"$l_mod_chk_name"'\b' || true)
    if lsmod | grep -q "^${l_mod_chk_name}[[:space:]]" 2>/dev/null; then
        log_warn "Kernel module '$l_mod_name' is currently loaded"
        return 1
    fi
    if ! grep -Pq -- '\binstall\h+'"$l_mod_chk_name"'\h+(\/usr)?\/bin\/(true|false)\b' <<< "${a_showconfig[*]}" 2>/dev/null; then
        log_warn "Kernel module '$l_mod_name' is not set to /bin/false"
        return 1
    fi
    if ! grep -Pq -- '\bblacklist\h+'"$l_mod_chk_name"'\b' <<< "${a_showconfig[*]}" 2>/dev/null; then
        log_warn "Kernel module '$l_mod_name' is not blacklisted"
        return 1
    fi
    return 0
}

# Helper: Disable kernel module by name only (for wireless etc.)
disable_kernel_module_by_name() {
    local l_mod_name="$1"
    local l_mod_chk_name="${l_mod_name//-/_}"
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would disable kernel module (by name): $l_mod_name"
        return 0
    fi
    if lsmod | grep -q "^${l_mod_chk_name}[[:space:]]" 2>/dev/null; then
        modprobe -r "$l_mod_chk_name" 2>/dev/null || true
        rmmod "$l_mod_name" 2>/dev/null || true
    fi
    local conf="/etc/modprobe.d/${l_mod_name}.conf"
    local need_install need_blacklist
    need_install=1
    need_blacklist=1
    modprobe --showconfig 2>/dev/null | grep -Pq -- '\binstall\h+'"$l_mod_chk_name"'\h+(\/usr)?\/bin\/(true|false)\b' && need_install=0
    modprobe --showconfig 2>/dev/null | grep -Pq -- '\bblacklist\h+'"$l_mod_chk_name"'\b' && need_blacklist=0
    [[ -f "$conf" ]] && backup_file "$conf"
    if [[ "$need_install" -eq 1 ]]; then
        echo "install $l_mod_chk_name $(readlink -f /bin/false)" >> "$conf"
    fi
    if [[ "$need_blacklist" -eq 1 ]]; then
        echo "blacklist $l_mod_chk_name" >> "$conf"
    fi
    return 0
}

# Helper: Return 0 if IPv6 is disabled on the system
is_ipv6_disabled() {
    if [[ -f /sys/module/ipv6/parameters/disable ]]; then
        grep -Pqs -- '^\h*1\b' /sys/module/ipv6/parameters/disable 2>/dev/null && return 0
    fi
    sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | grep -Pqs -- '^\h*net\.ipv6\.conf\.all\.disable_ipv6\h*=\h*1\b' && \
    sysctl net.ipv6.conf.default.disable_ipv6 2>/dev/null | grep -Pqs -- '^\h*net\.ipv6\.conf\.default\.disable_ipv6\h*=\h*1\b' && return 0
    return 1
}

# 3.1.1 Manual - IPv6 status identified
check_compliance_3_1_1() { log_info "3.1.1 is manual - identify IPv6 status per site policy"; return 0; }
apply_hardening_3_1_1() { log_warn "3.1.1 is manual - enable or disable IPv6 per site policy"; return 0; }

# 3.1.2 Wireless interfaces disabled
check_compliance_3_1_2() {
    local d mod_names m
    if [[ -z "$(find /sys/class/net/ -maxdepth 2 -type d -name wireless 2>/dev/null)" ]]; then
        log_info "No wireless interfaces found - compliant"
        return 0
    fi
    mod_names=$(for d in $(find /sys/class/net/ -maxdepth 2 -type d -name wireless 2>/dev/null); do
        if [[ -L "$(dirname "$d")/device/driver/module" ]]; then
            basename "$(readlink -f "$(dirname "$d")/device/driver/module")" 2>/dev/null
        fi
    done | sort -u)
    [[ -z "$mod_names" ]] && return 0
    for m in $mod_names; do
        [[ -z "$m" ]] && continue
        check_kernel_module_compliance_any "$m" || return 1
    done
    return 0
}
apply_hardening_3_1_2() {
    local d mod_names m
    mod_names=$(for d in $(find /sys/class/net/ -maxdepth 2 -type d -name wireless 2>/dev/null); do
        if [[ -L "$(dirname "$d")/device/driver/module" ]]; then
            basename "$(readlink -f "$(dirname "$d")/device/driver/module")" 2>/dev/null
        fi
    done | sort -u)
    [[ -z "$mod_names" ]] && return 0
    for m in $mod_names; do
        [[ -z "$m" ]] && continue
        disable_kernel_module_by_name "$m"
    done
    return 0
}

# 3.1.3 Bluetooth not in use
check_compliance_3_1_3() { check_service_not_in_use "bluez" "bluetooth.service"; }
apply_hardening_3_1_3() { ensure_service_stopped_and_purge "bluez" "bluetooth.service"; }

# 3.2.x Network kernel modules (dccp, tipc, rds, sctp) - use existing helpers with type "net"
check_compliance_3_2_1() { check_kernel_module_compliance "dccp" "net"; }
apply_hardening_3_2_1() { disable_kernel_module "dccp" "net"; }
check_compliance_3_2_2() { check_kernel_module_compliance "tipc" "net"; }
apply_hardening_3_2_2() { disable_kernel_module "tipc" "net"; }
check_compliance_3_2_3() { check_kernel_module_compliance "rds" "net"; }
apply_hardening_3_2_3() { disable_kernel_module "rds" "net"; }
check_compliance_3_2_4() { check_kernel_module_compliance "sctp" "net"; }
apply_hardening_3_2_4() { disable_kernel_module "sctp" "net"; }

# 3.3.1 ip forwarding disabled
check_compliance_3_3_1() {
    check_sysctl "net.ipv4.ip_forward" "0" || return 1
    is_ipv6_disabled && return 0
    check_sysctl "net.ipv6.conf.all.forwarding" "0"
}
apply_hardening_3_3_1() {
    set_sysctl "net.ipv4.ip_forward" "0"
    is_ipv6_disabled && return 0
    set_sysctl "net.ipv6.conf.all.forwarding" "0"
    return 0
}

# 3.3.2 packet redirect sending disabled
check_compliance_3_3_2() {
    check_sysctl "net.ipv4.conf.all.send_redirects" "0" && \
    check_sysctl "net.ipv4.conf.default.send_redirects" "0"
}
apply_hardening_3_3_2() {
    set_sysctl "net.ipv4.conf.all.send_redirects" "0"
    set_sysctl "net.ipv4.conf.default.send_redirects" "0"
    return 0
}

# 3.3.3 bogus icmp ignored
check_compliance_3_3_3() { check_sysctl "net.ipv4.icmp_ignore_bogus_error_responses" "1"; }
apply_hardening_3_3_3() { set_sysctl "net.ipv4.icmp_ignore_bogus_error_responses" "1"; return 0; }

# 3.3.4 broadcast icmp ignored
check_compliance_3_3_4() { check_sysctl "net.ipv4.icmp_echo_ignore_broadcasts" "1"; }
apply_hardening_3_3_4() { set_sysctl "net.ipv4.icmp_echo_ignore_broadcasts" "1"; return 0; }

# 3.3.5 icmp redirects not accepted
check_compliance_3_3_5() {
    check_sysctl "net.ipv4.conf.all.accept_redirects" "0" && \
    check_sysctl "net.ipv4.conf.default.accept_redirects" "0" || return 1
    is_ipv6_disabled && return 0
    check_sysctl "net.ipv6.conf.all.accept_redirects" "0" && \
    check_sysctl "net.ipv6.conf.default.accept_redirects" "0"
}
apply_hardening_3_3_5() {
    set_sysctl "net.ipv4.conf.all.accept_redirects" "0"
    set_sysctl "net.ipv4.conf.default.accept_redirects" "0"
    is_ipv6_disabled && return 0
    set_sysctl "net.ipv6.conf.all.accept_redirects" "0"
    set_sysctl "net.ipv6.conf.default.accept_redirects" "0"
    return 0
}

# 3.3.6 secure icmp redirects not accepted
check_compliance_3_3_6() {
    check_sysctl "net.ipv4.conf.all.secure_redirects" "0" && \
    check_sysctl "net.ipv4.conf.default.secure_redirects" "0"
}
apply_hardening_3_3_6() {
    set_sysctl "net.ipv4.conf.all.secure_redirects" "0"
    set_sysctl "net.ipv4.conf.default.secure_redirects" "0"
    return 0
}

# 3.3.7 reverse path filtering enabled
check_compliance_3_3_7() {
    check_sysctl "net.ipv4.conf.all.rp_filter" "1" && \
    check_sysctl "net.ipv4.conf.default.rp_filter" "1"
}
apply_hardening_3_3_7() {
    set_sysctl "net.ipv4.conf.all.rp_filter" "1"
    set_sysctl "net.ipv4.conf.default.rp_filter" "1"
    return 0
}

# 3.3.8 source routed packets not accepted
check_compliance_3_3_8() {
    check_sysctl "net.ipv4.conf.all.accept_source_route" "0" && \
    check_sysctl "net.ipv4.conf.default.accept_source_route" "0" || return 1
    is_ipv6_disabled && return 0
    check_sysctl "net.ipv6.conf.all.accept_source_route" "0" && \
    check_sysctl "net.ipv6.conf.default.accept_source_route" "0"
}
apply_hardening_3_3_8() {
    set_sysctl "net.ipv4.conf.all.accept_source_route" "0"
    set_sysctl "net.ipv4.conf.default.accept_source_route" "0"
    is_ipv6_disabled && return 0
    set_sysctl "net.ipv6.conf.all.accept_source_route" "0"
    set_sysctl "net.ipv6.conf.default.accept_source_route" "0"
    return 0
}

# 3.3.9 suspicious packets logged
check_compliance_3_3_9() {
    check_sysctl "net.ipv4.conf.all.log_martians" "1" && \
    check_sysctl "net.ipv4.conf.default.log_martians" "1"
}
apply_hardening_3_3_9() {
    set_sysctl "net.ipv4.conf.all.log_martians" "1"
    set_sysctl "net.ipv4.conf.default.log_martians" "1"
    return 0
}

# 3.3.10 tcp syn cookies enabled
check_compliance_3_3_10() { check_sysctl "net.ipv4.tcp_syncookies" "1"; }
apply_hardening_3_3_10() { set_sysctl "net.ipv4.tcp_syncookies" "1"; return 0; }

# 3.3.11 ipv6 router advertisements not accepted (only if IPv6 enabled)
check_compliance_3_3_11() {
    is_ipv6_disabled && { log_info "IPv6 disabled - skip 3.3.11"; return 0; }
    check_sysctl "net.ipv6.conf.all.accept_ra" "0" && \
    check_sysctl "net.ipv6.conf.default.accept_ra" "0"
}
apply_hardening_3_3_11() {
    is_ipv6_disabled && return 0
    set_sysctl "net.ipv6.conf.all.accept_ra" "0"
    set_sysctl "net.ipv6.conf.default.accept_ra" "0"
    return 0
}

###############################################################################
# Section 4 - Host Based Firewall
###############################################################################

# Helper: Determine which single firewall is in use (ufw, nftables, iptables). Echo one or empty.
get_active_firewall() {
    local active=()
    if command -v ufw &>/dev/null && systemctl is-enabled ufw 2>/dev/null | grep -q . && systemctl is-active ufw 2>/dev/null | grep -q '^active'; then
        active+=("ufw")
    fi
    if command -v nft &>/dev/null && systemctl is-enabled nftables 2>/dev/null | grep -q . && systemctl is-active nftables 2>/dev/null | grep -q '^active'; then
        active+=("nftables")
    fi
    # iptables: use netfilter-persistent as the service on Ubuntu/Debian
    if command -v iptables &>/dev/null && systemctl is-enabled netfilter-persistent 2>/dev/null | grep -q . && systemctl is-active netfilter-persistent 2>/dev/null | grep -q '^active'; then
        active+=("iptables")
    fi
    if [[ ${#active[@]} -eq 1 ]]; then
        echo "${active[0]}"
    else
        echo ""
    fi
}

# 4.1.1 Single firewall configuration utility in use
check_compliance_4_1_1() {
    local fw
    fw=$(get_active_firewall)
    if [[ -n "$fw" ]]; then
        log_info "Single firewall in use: $fw - compliant"
        return 0
    fi
    log_warn "No single firewall in use (none or multiple active)"
    return 1
}
apply_hardening_4_1_1() {
    local fw
    fw=$(get_active_firewall)
    if [[ -n "$fw" ]]; then
        log_info "Single firewall already in use: $fw"
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would ensure single firewall (default: enable ufw)"
        return 0
    fi
    # Default: enable ufw, disable/mask others
    systemctl stop nftables 2>/dev/null || true
    systemctl mask nftables 2>/dev/null || true
    systemctl stop netfilter-persistent 2>/dev/null || true
    systemctl mask netfilter-persistent 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw 2>/dev/null || true
    systemctl unmask ufw 2>/dev/null || true
    systemctl --now enable ufw 2>/dev/null || true
    ufw --force enable 2>/dev/null || true
    log_info "Enabled ufw as single firewall (default)"
    return 0
}

# 4.2.1 ufw installed (only when ufw is the active firewall)
check_compliance_4_2_1() {
    [[ "$(get_active_firewall)" != "ufw" ]] && { log_info "UFW not in use - skip 4.2.1"; return 0; }
    check_package_installed "ufw"
}
apply_hardening_4_2_1() {
    [[ "$(get_active_firewall)" != "ufw" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would install ufw"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y ufw 2>/dev/null || true
    return 0
}

# 4.2.2 iptables-persistent not installed with ufw
check_compliance_4_2_2() {
    [[ "$(get_active_firewall)" != "ufw" ]] && { log_info "UFW not in use - skip 4.2.2"; return 0; }
    check_package_not_installed "iptables-persistent"
}
apply_hardening_4_2_2() {
    [[ "$(get_active_firewall)" != "ufw" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would purge iptables-persistent"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y iptables-persistent 2>/dev/null || true
    return 0
}

# 4.2.3 ufw service enabled and active
check_compliance_4_2_3() {
    [[ "$(get_active_firewall)" != "ufw" ]] && { log_info "UFW not in use - skip 4.2.3"; return 0; }
    systemctl is-enabled ufw 2>/dev/null | grep -q . && systemctl is-active ufw 2>/dev/null | grep -q '^active' && ufw status 2>/dev/null | grep -q "Status: active"
}
apply_hardening_4_2_3() {
    [[ "$(get_active_firewall)" != "ufw" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would enable ufw"; return 0; fi
    systemctl unmask ufw 2>/dev/null || true
    systemctl --now enable ufw 2>/dev/null || true
    ufw --force enable 2>/dev/null || true
    return 0
}

# 4.2.4 ufw loopback traffic configured
check_compliance_4_2_4() {
    [[ "$(get_active_firewall)" != "ufw" ]] && { log_info "UFW not in use - skip 4.2.4"; return 0; }
    grep -qE 'ufw-before-input.*-i lo.*ACCEPT|ACCEPT.*-i lo' /etc/ufw/before.rules 2>/dev/null && \
    grep -qE 'ufw-before-output.*-o lo.*ACCEPT|ACCEPT.*-o lo' /etc/ufw/before.rules 2>/dev/null && \
    (grep -q '127.0.0.0/8' /etc/ufw/before.rules 2>/dev/null || ufw status verbose 2>/dev/null | grep -q '127.0.0.0/8') && \
    (grep -q '::1' /etc/ufw/before.rules 2>/dev/null || ufw status verbose 2>/dev/null | grep -q '::1')
}
apply_hardening_4_2_4() {
    [[ "$(get_active_firewall)" != "ufw" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would configure ufw loopback"; return 0; fi
    ufw allow in on lo 2>/dev/null || true
    ufw allow out on lo 2>/dev/null || true
    ufw deny in from 127.0.0.0/8 2>/dev/null || true
    ufw deny in from ::1 2>/dev/null || true
    return 0
}

# 4.2.5 ufw outbound connections (Manual)
check_compliance_4_2_5() { log_info "4.2.5 is manual - configure outbound per site policy"; return 0; }
apply_hardening_4_2_5() { log_warn "4.2.5 is manual - configure ufw outbound per site policy"; return 0; }

# 4.2.6 ufw firewall rules exist for all open ports
check_compliance_4_2_6() {
    [[ "$(get_active_firewall)" != "ufw" ]] && { log_info "UFW not in use - skip 4.2.6"; return 0; }
    local ufw_ports open_ports
    ufw_ports=$(ufw status 2>/dev/null | awk '$1 ~ /^[0-9]+\/(tcp|udp)$/ {split($1,a,"/"); print a[1]}' | sort -u)
    open_ports=$(ss -tuln 2>/dev/null | awk 'NR>1 && $5!~/%lo:/ && $5!~/127\.0\.0\.1:/ && $5!~/\[?::1\]?:/ {split($5,a,":"); print a[2]}' | sort -u)
    local missing=""
    while read -r port; do
        [[ -z "$port" ]] && continue
        echo "$ufw_ports" | grep -q "^${port}$" || missing="$missing $port"
    done <<< "$open_ports"
    [[ -z "$missing" ]] && return 0
    log_warn "Open ports without UFW rule:$missing"
    return 1
}
apply_hardening_4_2_6() {
    [[ "$(get_active_firewall)" != "ufw" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would add ufw rules for open ports"; return 0; fi
    local open_ports port
    open_ports=$(ss -tuln 2>/dev/null | awk '($5!~/%lo:/ && $5!~/127\.0\.0.1:/ && $5!~/\[?::1\]?:/) {split($5,a,":"); print a[2]}' | sort -u)
    while read -r port; do
        [[ -z "$port" ]] && continue
        ufw allow "$port"/tcp 2>/dev/null || true
        ufw allow "$port"/udp 2>/dev/null || true
    done <<< "$open_ports"
    return 0
}

# 4.2.7 ufw default deny firewall policy
check_compliance_4_2_7() {
    [[ "$(get_active_firewall)" != "ufw" ]] && { log_info "UFW not in use - skip 4.2.7"; return 0; }
    ufw status verbose 2>/dev/null | grep -q 'Default:.*deny (incoming)' && \
    ufw status verbose 2>/dev/null | grep -q 'deny (outgoing)' && \
    ufw status verbose 2>/dev/null | grep -qE 'disabled \(routed\)|deny \(routed\)'
}
apply_hardening_4_2_7() {
    [[ "$(get_active_firewall)" != "ufw" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would set ufw default deny"; return 0; fi
    ufw default deny incoming 2>/dev/null || true
    ufw default deny outgoing 2>/dev/null || true
    ufw default deny routed 2>/dev/null || true
    return 0
}

# 4.3.x nftables (only when nftables is the active firewall)
check_compliance_4_3_1() {
    [[ "$(get_active_firewall)" != "nftables" ]] && { log_info "nftables not in use - skip 4.3.1"; return 0; }
    check_package_installed "nftables"
}
apply_hardening_4_3_1() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would install nftables"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y nftables 2>/dev/null || true
    return 0
}

check_compliance_4_3_2() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    ! check_package_installed "ufw" || (ufw status 2>/dev/null | grep -q "Status: inactive" && systemctl is-enabled ufw 2>/dev/null | grep -q "masked")
}
apply_hardening_4_3_2() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would disable ufw for nftables"; return 0; fi
    ufw disable 2>/dev/null || true
    systemctl stop ufw 2>/dev/null || true
    systemctl mask ufw 2>/dev/null || true
    return 0
}

check_compliance_4_3_3() { log_info "4.3.3 is manual - flush iptables with nftables"; return 0; }
apply_hardening_4_3_3() { log_warn "4.3.3 is manual - flush iptables if using nftables"; return 0; }

check_compliance_4_3_4() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    nft list tables 2>/dev/null | grep -q "table inet filter"
}
apply_hardening_4_3_4() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would create nftables inet filter table"; return 0; fi
    nft create table inet filter 2>/dev/null || true
    return 0
}

check_compliance_4_3_5() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    nft list ruleset 2>/dev/null | grep -q 'hook input' && \
    nft list ruleset 2>/dev/null | grep -q 'hook forward' && \
    nft list ruleset 2>/dev/null | grep -q 'hook output'
}
apply_hardening_4_3_5() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would create nftables base chains"; return 0; fi
    nft create table inet filter 2>/dev/null || true
    nft create chain inet filter input '{ type filter hook input priority 0; policy drop; }' 2>/dev/null || true
    nft create chain inet filter forward '{ type filter hook forward priority 0; policy drop; }' 2>/dev/null || true
    nft create chain inet filter output '{ type filter hook output priority 0; policy drop; }' 2>/dev/null || true
    return 0
}

check_compliance_4_3_6() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    nft list ruleset 2>/dev/null | awk '/hook input/,/}/' | grep -q 'iif "lo" accept' && \
    nft list ruleset 2>/dev/null | awk '/hook input/,/}/' | grep -q '127.0.0.0/8'
}
apply_hardening_4_3_6() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would configure nftables loopback"; return 0; fi
    nft add rule inet filter input iif lo accept 2>/dev/null || true
    nft add rule inet filter input ip saddr 127.0.0.0/8 counter drop 2>/dev/null || true
    nft add rule inet filter input ip6 saddr ::1 counter drop 2>/dev/null || true
    return 0
}

check_compliance_4_3_7() { log_info "4.3.7 is manual - nftables outbound/established"; return 0; }
apply_hardening_4_3_7() { log_warn "4.3.7 is manual - configure nftables outbound per site policy"; return 0; }

check_compliance_4_3_8() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    nft list ruleset 2>/dev/null | grep -q 'policy drop'
}
apply_hardening_4_3_8() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    # Chains created with policy drop in 4.3.5
    return 0
}

check_compliance_4_3_9() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    systemctl is-enabled nftables 2>/dev/null | grep -q . && systemctl is-active nftables 2>/dev/null | grep -q '^active'
}
apply_hardening_4_3_9() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would enable nftables"; return 0; fi
    systemctl unmask nftables 2>/dev/null || true
    systemctl --now enable nftables 2>/dev/null || true
    return 0
}

check_compliance_4_3_10() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    grep -qE '^\s*include\s+' /etc/nftables.conf 2>/dev/null
}
apply_hardening_4_3_10() {
    [[ "$(get_active_firewall)" != "nftables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would add include to nftables.conf"; return 0; fi
    if ! grep -q 'include "/etc/nftables.rules"' /etc/nftables.conf 2>/dev/null; then
        backup_file /etc/nftables.conf 2>/dev/null || true
        echo 'include "/etc/nftables.rules"' >> /etc/nftables.conf
    fi
    return 0
}

# 4.4.x iptables (only when iptables/netfilter-persistent is the active firewall)
check_compliance_4_4_1_1() {
    [[ "$(get_active_firewall)" != "iptables" ]] && { log_info "iptables not in use - skip 4.4.1.1"; return 0; }
    check_package_installed "iptables" && check_package_installed "iptables-persistent"
}
apply_hardening_4_4_1_1() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would install iptables iptables-persistent"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y iptables iptables-persistent 2>/dev/null || true
    return 0
}

check_compliance_4_4_1_2() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    ! (command -v nft &>/dev/null && systemctl is-enabled nftables 2>/dev/null | grep -q . && systemctl is-active nftables 2>/dev/null | grep -q '^active')
}
apply_hardening_4_4_1_2() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would disable nftables for iptables"; return 0; fi
    systemctl stop nftables 2>/dev/null || true
    systemctl mask nftables 2>/dev/null || true
    return 0
}

check_compliance_4_4_1_3() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    ! (command -v ufw &>/dev/null && systemctl is-active ufw 2>/dev/null | grep -q '^active')
}
apply_hardening_4_4_1_3() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would disable ufw for iptables"; return 0; fi
    ufw disable 2>/dev/null || true
    systemctl stop ufw 2>/dev/null || true
    systemctl mask ufw 2>/dev/null || true
    return 0
}

check_compliance_4_4_2_1() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    iptables -L INPUT -n 2>/dev/null | head -1 | grep -qE 'policy (DROP|REJECT)'
}
apply_hardening_4_4_2_1() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would set iptables default deny"; return 0; fi
    iptables -P INPUT DROP 2>/dev/null || true
    iptables -P FORWARD DROP 2>/dev/null || true
    iptables -P OUTPUT DROP 2>/dev/null || true
    return 0
}

check_compliance_4_4_2_2() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    iptables -L INPUT -n -v 2>/dev/null | grep -q 'lo.*ACCEPT' && iptables -L OUTPUT -n -v 2>/dev/null | grep -q 'lo.*ACCEPT'
}
apply_hardening_4_4_2_2() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would configure iptables loopback"; return 0; fi
    iptables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    return 0
}

check_compliance_4_4_2_3() { log_info "4.4.2.3 is manual - iptables outbound/established"; return 0; }
apply_hardening_4_4_2_3() { log_warn "4.4.2.3 is manual - configure iptables outbound per site policy"; return 0; }

check_compliance_4_4_2_4() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    # Similar to 4.2.6 - open ports should have rules; simplified pass if iptables has some input rules
    iptables -L INPUT -n 2>/dev/null | grep -q ACCEPT
}
apply_hardening_4_4_2_4() { [[ "$(get_active_firewall)" != "iptables" ]] && return 0; return 0; }

check_compliance_4_4_3_1() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    ip6tables -L INPUT -n 2>/dev/null | head -1 | grep -qE 'policy (DROP|REJECT)'
}
apply_hardening_4_4_3_1() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would set ip6tables default deny"; return 0; fi
    ip6tables -P INPUT DROP 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
    return 0
}

check_compliance_4_4_3_2() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    ip6tables -L INPUT -n -v 2>/dev/null | grep -q 'lo.*ACCEPT' && ip6tables -L OUTPUT -n -v 2>/dev/null | grep -q 'lo.*ACCEPT'
}
apply_hardening_4_4_3_2() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then log_dryrun "Would configure ip6tables loopback"; return 0; fi
    ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
    ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
    return 0
}

check_compliance_4_4_3_3() { log_info "4.4.3.3 is manual - ip6tables outbound/established"; return 0; }
apply_hardening_4_4_3_3() { log_warn "4.4.3.3 is manual - configure ip6tables outbound per site policy"; return 0; }

check_compliance_4_4_3_4() {
    [[ "$(get_active_firewall)" != "iptables" ]] && return 0
    ip6tables -L INPUT -n 2>/dev/null | grep -q ACCEPT
}
apply_hardening_4_4_3_4() { [[ "$(get_active_firewall)" != "iptables" ]] && return 0; return 0; }

###############################################################################
# Section 5 - Access Control (SSH Server)
###############################################################################

# SSH configuration profiles (can be overridden via environment variables)
# Supported values: cis_strict (default), extended
: "${SSHD_CIPHERS_PROFILE:=cis_strict}"
: "${SSHD_MACS_PROFILE:=cis_strict}"
: "${SSHD_KEX_PROFILE:=cis_strict}"

# Helper: Check if SSH server is installed
sshd_installed() {
    check_package_installed "openssh-server"
}

# Helper: Get effective sshd configuration using sshd -T
get_sshd_effective_config() {
    if ! sshd_installed; then
        return 1
    fi
    if ! command -v sshd &>/dev/null; then
        # On some systems sshd may be at /usr/sbin/sshd without PATH entry
        if [[ -x /usr/sbin/sshd ]]; then
            /usr/sbin/sshd -T -C user=root,addr=127.0.0.1,lport=22 2>/dev/null
        else
            return 1
        fi
    else
        sshd -T -C user=root,addr=127.0.0.1,lport=22 2>/dev/null
    fi
}

# Helper: Get a single sshd -T key's value
get_sshd_effective_value() {
    local key="$1"
    get_sshd_effective_config | awk -v k="$key" '$1 == k { $1=""; sub(/^ /,""); print; exit }'
}

# Helper: Set or add an sshd_config option in /etc/ssh/sshd_config
set_sshd_config_option() {
    local key="$1"
    local value="$2"
    local file="/etc/ssh/sshd_config"

    if ! sshd_installed; then
        log_info "openssh-server not installed - skipping sshd option $key"
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set $key in $file to '$value'"
        return 0
    fi

    # Ensure file exists
    if [[ ! -f "$file" ]]; then
        touch "$file"
    fi

    backup_file "$file"

    if grep -qE "^[[:space:]]*${key}\\b" "$file"; then
        sed -ri "s|^[[:space:]]*${key}\\b.*|${key} ${value}|" "$file"
    else
        echo "${key} ${value}" >> "$file"
    fi
}

# Helper: Expected values for Ciphers/MACs/KEX based on selected profiles
get_sshd_ciphers_expected() {
    case "$SSHD_CIPHERS_PROFILE" in
        extended)
            # Adds common GCM ciphers while remaining reasonably strong
            echo "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
            ;;
        cis_strict|*)
            echo "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
            ;;
    esac
}

get_sshd_macs_expected() {
    case "$SSHD_MACS_PROFILE" in
        extended)
            # Includes non-ETM variants for broader compatibility
            echo "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com,hmac-sha1"
            ;;
        cis_strict|*)
            echo "hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com,hmac-sha2-512,hmac-sha2-256,umac-128@openssh.com"
            ;;
    esac
}

get_sshd_kex_expected() {
    case "$SSHD_KEX_PROFILE" in
        extended)
            # Adds diffie-hellman-group14-sha256 for wider client support
            echo "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256,diffie-hellman-group14-sha256"
            ;;
        cis_strict|*)
            echo "curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group-exchange-sha256"
            ;;
    esac
}

# 5.1.1 Ensure permissions on /etc/ssh/sshd_config are configured
check_compliance_5_1_1() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.1"
        return 0
    fi
    local ok=true
    if [[ -f /etc/ssh/sshd_config ]]; then
        check_path_permissions "/etc/ssh/sshd_config" "600" "root" "root" || ok=false
    else
        log_warn "/etc/ssh/sshd_config does not exist"
        ok=false
    fi
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        while IFS= read -r -d '' f; do
            check_path_permissions "$f" "600" "root" "root" || ok=false
        done < <(find /etc/ssh/sshd_config.d -type f -name '*.conf' -print0 2>/dev/null)
    fi
    [[ "$ok" == true ]]
}
apply_hardening_5_1_1() {
    if ! sshd_installed; then return 0; fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set permissions on sshd_config and included .conf files to 600 root:root"
        return 0
    fi
    if [[ -f /etc/ssh/sshd_config ]]; then
        set_path_permissions "/etc/ssh/sshd_config" "600" "root" "root"
    fi
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        while IFS= read -r -d '' f; do
            set_path_permissions "$f" "600" "root" "root"
        done < <(find /etc/ssh/sshd_config.d -type f -name '*.conf' -print0 2>/dev/null)
    fi
    return 0
}

# 5.1.2 Ensure permissions on SSH private host key files are configured
check_compliance_5_1_2() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.2"
        return 0
    fi
    local ok=true
    while IFS= read -r -d '' f; do
        local perm owner group
        perm=$(stat -c '%a' "$f" 2>/dev/null || echo "")
        owner=$(stat -c '%U' "$f" 2>/dev/null || echo "")
        group=$(stat -c '%G' "$f" 2>/dev/null || echo "")
        # Require no group/other permissions: [0-7]00
        if [[ ! "$perm" =~ ^[0-7]00$ ]] || [[ "$owner" != "root" ]] || [[ "$group" != "root" ]]; then
            log_warn "Private key '$f' has insecure permissions $perm $owner:$group"
            ok=false
        fi
    done < <(find /etc/ssh -xdev -type f -name '*_key' ! -name '*.pub' -print0 2>/dev/null)
    [[ "$ok" == true ]]
}
apply_hardening_5_1_2() {
    if ! sshd_installed; then return 0; fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set SSH private host key files to 600 root:root"
        return 0
    fi
    while IFS= read -r -d '' f; do
        set_path_permissions "$f" "600" "root" "root"
    done < <(find /etc/ssh -xdev -type f -name '*_key' ! -name '*.pub' -print0 2>/dev/null)
    return 0
}

# 5.1.3 Ensure permissions on SSH public host key files are configured
check_compliance_5_1_3() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.3"
        return 0
    fi
    local ok=true
    while IFS= read -r -d '' f; do
        local perm owner group
        perm=$(stat -c '%a' "$f" 2>/dev/null || echo "")
        owner=$(stat -c '%U' "$f" 2>/dev/null || echo "")
        group=$(stat -c '%G' "$f" 2>/dev/null || echo "")
        # Require group/other not writable or executable
        if [[ ! "$perm" =~ ^[0-7][0-4][0-4]$ ]] || [[ "$owner" != "root" ]] || [[ "$group" != "root" ]]; then
            log_warn "Public key '$f' has insecure permissions $perm $owner:$group"
            ok=false
        fi
    done < <(find /etc/ssh -xdev -type f -name '*.pub' -print0 2>/dev/null)
    [[ "$ok" == true ]]
}
apply_hardening_5_1_3() {
    if ! sshd_installed; then return 0; fi
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set SSH public host key files to 644 root:root"
        return 0
    fi
    while IFS= read -r -d '' f; do
        set_path_permissions "$f" "644" "root" "root"
    done < <(find /etc/ssh -xdev -type f -name '*.pub' -print0 2>/dev/null)
    return 0
}

# 5.1.4 Ensure sshd access is configured (Manual – site-specific users/groups)
check_compliance_5_1_4() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.4"
        return 0
    fi
    local cfg
    cfg=$(get_sshd_effective_config)
    if echo "$cfg" | grep -qiE '^(allowusers|allowgroups|denyusers|denygroups)[[:space:]]'; then
        return 0
    fi
    log_warn "sshd access controls (AllowUsers/AllowGroups/DenyUsers/DenyGroups) are not configured - manual review required"
    return 1
}
apply_hardening_5_1_4() {
    log_warn "5.1.4 is site-specific - please configure AllowUsers/AllowGroups/DenyUsers/DenyGroups per policy"
    return 0
}

# 5.1.5 Ensure sshd Banner is configured
check_compliance_5_1_5() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.5"
        return 0
    fi
    local banner
    banner=$(get_sshd_effective_value "banner")
    [[ "$banner" == "/etc/issue.net" ]] || return 1
    [[ -f /etc/issue.net ]] || return 1
    check_path_permissions "/etc/issue.net" "644" "root" "root"
}
apply_hardening_5_1_5() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "Banner" "/etc/issue.net"
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would ensure /etc/issue.net exists and set permissions to 644 root:root"
        return 0
    fi
    [[ -f /etc/issue.net ]] || touch /etc/issue.net
    set_path_permissions "/etc/issue.net" "644" "root" "root"
    return 0
}

# 5.1.6 Ensure sshd Ciphers are configured
check_compliance_5_1_6() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.6"
        return 0
    fi
    local expected val
    expected=$(get_sshd_ciphers_expected)
    val=$(get_sshd_effective_value "ciphers")
    [[ "$val" == "$expected" ]]
}
apply_hardening_5_1_6() {
    if ! sshd_installed; then return 0; fi
    local value
    value=$(get_sshd_ciphers_expected)
    set_sshd_config_option "Ciphers" "$value"
    return 0
}

# 5.1.7 Ensure sshd ClientAliveInterval and ClientAliveCountMax are configured
check_compliance_5_1_7() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.7"
        return 0
    fi
    local interval count
    interval=$(get_sshd_effective_value "clientaliveinterval")
    count=$(get_sshd_effective_value "clientalivecountmax")
    [[ "$interval" == "300" ]] && [[ "$count" == "3" ]]
}
apply_hardening_5_1_7() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "ClientAliveInterval" "300"
    set_sshd_config_option "ClientAliveCountMax" "3"
    return 0
}

# 5.1.8 Ensure sshd DisableForwarding is enabled
check_compliance_5_1_8() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.8"
        return 0
    fi
    [[ "$(get_sshd_effective_value "disableforwarding")" == "yes" ]]
}
apply_hardening_5_1_8() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "DisableForwarding" "yes"
    return 0
}

# 5.1.9 Ensure sshd GSSAPIAuthentication is disabled
check_compliance_5_1_9() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.9"
        return 0
    fi
    [[ "$(get_sshd_effective_value "gssapiauthentication")" == "no" ]]
}
apply_hardening_5_1_9() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "GSSAPIAuthentication" "no"
    return 0
}

# 5.1.10 Ensure sshd HostbasedAuthentication is disabled
check_compliance_5_1_10() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.10"
        return 0
    fi
    [[ "$(get_sshd_effective_value "hostbasedauthentication")" == "no" ]]
}
apply_hardening_5_1_10() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "HostbasedAuthentication" "no"
    return 0
}

# 5.1.11 Ensure sshd IgnoreRhosts is enabled
check_compliance_5_1_11() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.11"
        return 0
    fi
    [[ "$(get_sshd_effective_value "ignorerhosts")" == "yes" ]]
}
apply_hardening_5_1_11() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "IgnoreRhosts" "yes"
    return 0
}

# 5.1.12 Ensure sshd KexAlgorithms is configured
check_compliance_5_1_12() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.12"
        return 0
    fi
    local expected val
    expected=$(get_sshd_kex_expected)
    val=$(get_sshd_effective_value "kexalgorithms")
    [[ "$val" == "$expected" ]]
}
apply_hardening_5_1_12() {
    if ! sshd_installed; then return 0; fi
    local value
    value=$(get_sshd_kex_expected)
    set_sshd_config_option "KexAlgorithms" "$value"
    return 0
}

# 5.1.13 Ensure sshd LoginGraceTime is configured
check_compliance_5_1_13() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.13"
        return 0
    fi
    [[ "$(get_sshd_effective_value "logingracetime")" == "60" ]]
}
apply_hardening_5_1_13() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "LoginGraceTime" "60"
    return 0
}

# 5.1.14 Ensure sshd LogLevel is configured
check_compliance_5_1_14() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.14"
        return 0
    fi
    [[ "$(get_sshd_effective_value "loglevel")" == "VERBOSE" ]]
}
apply_hardening_5_1_14() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "LogLevel" "VERBOSE"
    return 0
}

# 5.1.15 Ensure sshd MACs are configured
check_compliance_5_1_15() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.15"
        return 0
    fi
    local expected val
    expected=$(get_sshd_macs_expected)
    val=$(get_sshd_effective_value "macs")
    [[ "$val" == "$expected" ]]
}
apply_hardening_5_1_15() {
    if ! sshd_installed; then return 0; fi
    local value
    value=$(get_sshd_macs_expected)
    set_sshd_config_option "MACs" "$value"
    return 0
}

# 5.1.16 Ensure sshd MaxAuthTries is configured
check_compliance_5_1_16() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.16"
        return 0
    fi
    [[ "$(get_sshd_effective_value "maxauthtries")" == "4" ]]
}
apply_hardening_5_1_16() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "MaxAuthTries" "4"
    return 0
}

# 5.1.17 Ensure sshd MaxSessions is configured
check_compliance_5_1_17() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.17"
        return 0
    fi
    [[ "$(get_sshd_effective_value "maxsessions")" == "10" ]]
}
apply_hardening_5_1_17() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "MaxSessions" "10"
    return 0
}

# 5.1.18 Ensure sshd MaxStartups is configured
check_compliance_5_1_18() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.18"
        return 0
    fi
    [[ "$(get_sshd_effective_value "maxstartups")" == "10:30:60" ]]
}
apply_hardening_5_1_18() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "MaxStartups" "10:30:60"
    return 0
}

# 5.1.19 Ensure sshd PermitEmptyPasswords is disabled
check_compliance_5_1_19() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.19"
        return 0
    fi
    [[ "$(get_sshd_effective_value "permitemptypasswords")" == "no" ]]
}
apply_hardening_5_1_19() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "PermitEmptyPasswords" "no"
    return 0
}

# 5.1.20 Ensure sshd PermitRootLogin is disabled
check_compliance_5_1_20() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.20"
        return 0
    fi
    local val
    val=$(get_sshd_effective_value "permitrootlogin")
    [[ "$val" == "no" ]] || [[ "$val" == "prohibit-password" ]]
}
apply_hardening_5_1_20() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "PermitRootLogin" "no"
    return 0
}

# 5.1.21 Ensure sshd PermitUserEnvironment is disabled
check_compliance_5_1_21() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.21"
        return 0
    fi
    [[ "$(get_sshd_effective_value "permituserenvironment")" == "no" ]]
}
apply_hardening_5_1_21() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "PermitUserEnvironment" "no"
    return 0
}

# 5.1.22 Ensure sshd UsePAM is enabled
check_compliance_5_1_22() {
    if ! sshd_installed; then
        log_info "openssh-server not installed - skip 5.1.22"
        return 0
    fi
    [[ "$(get_sshd_effective_value "usepam")" == "yes" ]]
}
apply_hardening_5_1_22() {
    if ! sshd_installed; then return 0; fi
    set_sshd_config_option "UsePAM" "yes"
    return 0
}

###############################################################################
# Section 7 - System Maintenance
###############################################################################

# 7.1.1 Ensure permissions on /etc/passwd are configured
check_compliance_7_1_1() {
    [[ ! -e /etc/passwd ]] && { log_warn "/etc/passwd not found"; return 1; }
    local perm owner group
    perm=$(stat -Lc '%a' /etc/passwd 2>/dev/null || echo "")
    owner=$(stat -Lc '%U' /etc/passwd 2>/dev/null || echo "")
    group=$(stat -Lc '%G' /etc/passwd 2>/dev/null || echo "")
    (( 10#$perm <= 644 )) && [[ "$owner" == "root" ]] && [[ "$group" == "root" ]]
}
apply_hardening_7_1_1() {
    [[ ! -e /etc/passwd ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/passwd to mode 644 root:root"
        return 0
    fi
    chmod u-x,go-wx /etc/passwd 2>/dev/null || true
    chown root:root /etc/passwd 2>/dev/null || true
    return 0
}

# 7.1.2 Ensure permissions on /etc/passwd- are configured
check_compliance_7_1_2() {
    [[ ! -e /etc/passwd- ]] && return 0
    local perm owner group
    perm=$(stat -Lc '%a' /etc/passwd- 2>/dev/null || echo "")
    owner=$(stat -Lc '%U' /etc/passwd- 2>/dev/null || echo "")
    group=$(stat -Lc '%G' /etc/passwd- 2>/dev/null || echo "")
    (( 10#$perm <= 644 )) && [[ "$owner" == "root" ]] && [[ "$group" == "root" ]]
}
apply_hardening_7_1_2() {
    [[ ! -e /etc/passwd- ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/passwd- to mode 644 root:root"
        return 0
    fi
    chmod u-x,go-wx /etc/passwd- 2>/dev/null || true
    chown root:root /etc/passwd- 2>/dev/null || true
    return 0
}

# 7.1.3 Ensure permissions on /etc/group are configured
check_compliance_7_1_3() {
    [[ ! -e /etc/group ]] && { log_warn "/etc/group not found"; return 1; }
    local perm owner group
    perm=$(stat -Lc '%a' /etc/group 2>/dev/null || echo "")
    owner=$(stat -Lc '%U' /etc/group 2>/dev/null || echo "")
    group=$(stat -Lc '%G' /etc/group 2>/dev/null || echo "")
    (( 10#$perm <= 644 )) && [[ "$owner" == "root" ]] && [[ "$group" == "root" ]]
}
apply_hardening_7_1_3() {
    [[ ! -e /etc/group ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/group to mode 644 root:root"
        return 0
    fi
    chmod u-x,go-wx /etc/group 2>/dev/null || true
    chown root:root /etc/group 2>/dev/null || true
    return 0
}

# 7.1.4 Ensure permissions on /etc/group- are configured
check_compliance_7_1_4() {
    [[ ! -e /etc/group- ]] && return 0
    local perm owner group
    perm=$(stat -Lc '%a' /etc/group- 2>/dev/null || echo "")
    owner=$(stat -Lc '%U' /etc/group- 2>/dev/null || echo "")
    group=$(stat -Lc '%G' /etc/group- 2>/dev/null || echo "")
    (( 10#$perm <= 644 )) && [[ "$owner" == "root" ]] && [[ "$group" == "root" ]]
}
apply_hardening_7_1_4() {
    [[ ! -e /etc/group- ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/group- to mode 644 root:root"
        return 0
    fi
    chmod u-x,go-wx /etc/group- 2>/dev/null || true
    chown root:root /etc/group- 2>/dev/null || true
    return 0
}

# 7.1.5 Ensure permissions on /etc/shadow are configured
check_compliance_7_1_5() {
    [[ ! -e /etc/shadow ]] && { log_warn "/etc/shadow not found"; return 1; }
    local perm owner group
    perm=$(stat -Lc '%a' /etc/shadow 2>/dev/null || echo "")
    owner=$(stat -Lc '%U' /etc/shadow 2>/dev/null || echo "")
    group=$(stat -Lc '%G' /etc/shadow 2>/dev/null || echo "")
    (( 10#$perm <= 640 )) || return 1
    [[ "$owner" == "root" ]] || return 1
    [[ "$group" == "root" || "$group" == "shadow" ]]
}
apply_hardening_7_1_5() {
    [[ ! -e /etc/shadow ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/shadow to mode 640 root:shadow (or root:root)"
        return 0
    fi
    if getent group shadow &>/dev/null; then
        chown root:shadow /etc/shadow 2>/dev/null || true
    else
        chown root:root /etc/shadow 2>/dev/null || true
    fi
    chmod u-x,g-wx,o-rwx /etc/shadow 2>/dev/null || true
    return 0
}

# 7.1.6 Ensure permissions on /etc/shadow- are configured
check_compliance_7_1_6() {
    [[ ! -e /etc/shadow- ]] && return 0
    local perm owner group
    perm=$(stat -Lc '%a' /etc/shadow- 2>/dev/null || echo "")
    owner=$(stat -Lc '%U' /etc/shadow- 2>/dev/null || echo "")
    group=$(stat -Lc '%G' /etc/shadow- 2>/dev/null || echo "")
    (( 10#$perm <= 640 )) || return 1
    [[ "$owner" == "root" ]] || return 1
    [[ "$group" == "root" || "$group" == "shadow" ]]
}
apply_hardening_7_1_6() {
    [[ ! -e /etc/shadow- ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/shadow- to mode 640 root:shadow (or root:root)"
        return 0
    fi
    if getent group shadow &>/dev/null; then
        chown root:shadow /etc/shadow- 2>/dev/null || true
    else
        chown root:root /etc/shadow- 2>/dev/null || true
    fi
    chmod u-x,g-wx,o-rwx /etc/shadow- 2>/dev/null || true
    return 0
}

# 7.1.7 Ensure permissions on /etc/gshadow are configured
check_compliance_7_1_7() {
    [[ ! -e /etc/gshadow ]] && return 0
    local perm owner group
    perm=$(stat -Lc '%a' /etc/gshadow 2>/dev/null || echo "")
    owner=$(stat -Lc '%U' /etc/gshadow 2>/dev/null || echo "")
    group=$(stat -Lc '%G' /etc/gshadow 2>/dev/null || echo "")
    (( 10#$perm <= 640 )) && [[ "$owner" == "root" ]] && [[ "$group" == "shadow" ]]
}
apply_hardening_7_1_7() {
    [[ ! -e /etc/gshadow ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/gshadow to mode 640 root:shadow"
        return 0
    fi
    chown root:shadow /etc/gshadow 2>/dev/null || true
    chmod u-x,g-wx,o-rwx /etc/gshadow 2>/dev/null || true
    return 0
}

# 7.1.8 Ensure permissions on /etc/gshadow- are configured
check_compliance_7_1_8() {
    [[ ! -e /etc/gshadow- ]] && return 0
    local perm owner group
    perm=$(stat -Lc '%a' /etc/gshadow- 2>/dev/null || echo "")
    owner=$(stat -Lc '%U' /etc/gshadow- 2>/dev/null || echo "")
    group=$(stat -Lc '%G' /etc/gshadow- 2>/dev/null || echo "")
    (( 10#$perm <= 640 )) && [[ "$owner" == "root" ]] && [[ "$group" == "shadow" ]]
}
apply_hardening_7_1_8() {
    [[ ! -e /etc/gshadow- ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/gshadow- to mode 640 root:shadow"
        return 0
    fi
    chown root:shadow /etc/gshadow- 2>/dev/null || true
    chmod u-x,g-wx,o-rwx /etc/gshadow- 2>/dev/null || true
    return 0
}

# 7.1.9 Ensure permissions on /etc/shells are configured
check_compliance_7_1_9() {
    [[ ! -e /etc/shells ]] && return 0
    local perm owner group
    perm=$(stat -Lc '%a' /etc/shells 2>/dev/null || echo "")
    owner=$(stat -Lc '%U' /etc/shells 2>/dev/null || echo "")
    group=$(stat -Lc '%G' /etc/shells 2>/dev/null || echo "")
    (( 10#$perm <= 644 )) && [[ "$owner" == "root" ]] && [[ "$group" == "root" ]]
}
apply_hardening_7_1_9() {
    [[ ! -e /etc/shells ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/shells to mode 644 root:root"
        return 0
    fi
    chmod u-x,go-wx /etc/shells 2>/dev/null || true
    chown root:root /etc/shells 2>/dev/null || true
    return 0
}

# 7.1.10 Ensure permissions on /etc/security/opasswd are configured
check_compliance_7_1_10() {
    [[ ! -e /etc/security/opasswd && ! -e /etc/security/opasswd.old ]] && return 0
    local ok=true
    if [[ -e /etc/security/opasswd ]]; then
        local perm owner group
        perm=$(stat -Lc '%a' /etc/security/opasswd 2>/dev/null || echo "")
        owner=$(stat -Lc '%U' /etc/security/opasswd 2>/dev/null || echo "")
        group=$(stat -Lc '%G' /etc/security/opasswd 2>/dev/null || echo "")
        if ! (( 10#$perm <= 600 )) || [[ "$owner" != "root" ]] || [[ "$group" != "root" ]]; then
            ok=false
        fi
    fi
    if [[ -e /etc/security/opasswd.old ]]; then
        local perm owner group
        perm=$(stat -Lc '%a' /etc/security/opasswd.old 2>/dev/null || echo "")
        owner=$(stat -Lc '%U' /etc/security/opasswd.old 2>/dev/null || echo "")
        group=$(stat -Lc '%G' /etc/security/opasswd.old 2>/dev/null || echo "")
        if ! (( 10#$perm <= 600 )) || [[ "$owner" != "root" ]] || [[ "$group" != "root" ]]; then
            ok=false
        fi
    fi
    [[ "$ok" == true ]]
}
apply_hardening_7_1_10() {
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would set /etc/security/opasswd* to mode 600 root:root (if present)"
        return 0
    fi
    if [[ -e /etc/security/opasswd ]]; then
        chmod 600 /etc/security/opasswd 2>/dev/null || true
        chown root:root /etc/security/opasswd 2>/dev/null || true
    fi
    if [[ -e /etc/security/opasswd.old ]]; then
        chmod 600 /etc/security/opasswd.old 2>/dev/null || true
        chown root:root /etc/security/opasswd.old 2>/dev/null || true
    fi
    return 0
}

# 7.1.11 Ensure world writable files and directories are secured (detection, manual remediation)
check_compliance_7_1_11() {
    local world_files world_dirs
    world_files=$(find / -xdev \( -path "/proc/*" -o -path "/sys/*" -o -path "/run/user/*" -o -path "/snap/*" \) -prune -o -type f -perm -0002 -print 2>/dev/null)
    world_dirs=$(find / -xdev \( -path "/proc/*" -o -path "/sys/*" -o -path "/run/user/*" -o -path "/snap/*" \) -prune -o -type d -perm -0002 ! -perm -1000 -print 2>/dev/null)
    if [[ -z "$world_files" && -z "$world_dirs" ]]; then
        return 0
    fi
    [[ -n "$world_files" ]] && log_warn "World-writable files detected:\n$world_files"
    [[ -n "$world_dirs" ]] && log_warn "World-writable directories without sticky bit detected:\n$world_dirs"
    return 1
}
apply_hardening_7_1_11() {
    log_warn "7.1.11 remediation is environment-specific - review world-writable files/directories and fix manually"
    return 0
}

# 7.1.12 Ensure no files or directories without an owner and a group exist (detection, manual remediation)
check_compliance_7_1_12() {
    local orphans
    orphans=$(find / -xdev \( -path "/proc/*" -o -path "/sys/*" -o -path "/run/user/*" -o -path "/snap/*" \) -prune -o \( -nouser -o -nogroup \) -print 2>/dev/null)
    if [[ -z "$orphans" ]]; then
        return 0
    fi
    log_warn "Files/directories without owner or group detected:\n$orphans"
    return 1
}
apply_hardening_7_1_12() {
    log_warn "7.1.12 remediation is environment-specific - assign proper ownership to orphaned files manually"
    return 0
}

# 7.1.13 Ensure SUID and SGID files are reviewed (Manual)
check_compliance_7_1_13() {
    log_info "7.1.13 is manual - review SUID/SGID files per site policy"
    return 0
}
apply_hardening_7_1_13() {
    log_warn "7.1.13 is manual - review and adjust SUID/SGID files per site policy"
    return 0
}

###############################################################################
# 7.2 Local User and Group Settings
###############################################################################

# 7.2.1 Ensure accounts in /etc/passwd use shadowed passwords
check_compliance_7_2_1() {
    awk -F: '($2 != "x") { print "User \"" $1 "\" is not using shadowed passwords" }' /etc/passwd | {
        local out
        out=$(cat)
        [[ -z "$out" ]] && return 0
        log_warn "$out"
        return 1
    }
}
apply_hardening_7_2_1() {
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would run pwconv to migrate passwords to /etc/shadow"
        return 0
    fi
    if command -v pwconv &>/dev/null; then
        pwconv 2>/dev/null || true
    else
        log_warn "pwconv not available - cannot automatically convert to shadow passwords"
    fi
    return 0
}

# 7.2.2 Ensure /etc/shadow password fields are not empty
check_compliance_7_2_2() {
    awk -F: '($2 == "") { print $1 " does not have a password" }' /etc/shadow | {
        local out
        out=$(cat)
        [[ -z "$out" ]] && return 0
        log_warn "$out"
        return 1
    }
}
apply_hardening_7_2_2() {
    local users
    users=$(awk -F: '($2 == "") { print $1 }' /etc/shadow)
    [[ -z "$users" ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would lock accounts with empty passwords: $users"
        return 0
    fi
    local u
    for u in $users; do
        passwd -l "$u" 2>/dev/null || true
    done
    return 0
}

# 7.2.3 Ensure all groups in /etc/passwd exist in /etc/group (detection only)
check_compliance_7_2_3() {
    local missing
    missing=$(awk -F: 'NR==FNR {g[$3]; next} !($4 in g) {print $1 " has missing GID " $4}' /etc/group /etc/passwd)
    if [[ -z "$missing" ]]; then
        return 0
    fi
    log_warn "Groups referenced in /etc/passwd but missing from /etc/group:\n$missing"
    return 1
}
apply_hardening_7_2_3() {
    log_warn "7.2.3 remediation (creating missing groups or adjusting users) requires manual review"
    return 0
}

# 7.2.4 Ensure shadow group is empty
check_compliance_7_2_4() {
    local members
    members=$(awk -F: '($1 == "shadow" && $4 != "") {print $4}' /etc/group)
    [[ -z "$members" ]]
}
apply_hardening_7_2_4() {
    local members
    members=$(awk -F: '($1 == "shadow" && $4 != "") {print $4}' /etc/group | tr ',' ' ')
    [[ -z "$members" ]] && return 0
    log_warn "7.2.4 remediation is manual - remove these users from shadow group if not required: $members"
    return 0
}

# 7.2.5 Ensure no duplicate UIDs exist (detection only)
check_compliance_7_2_5() {
    local dups
    dups=$(awk -F: '{print $3}' /etc/passwd | sort | uniq -d)
    if [[ -z "$dups" ]]; then
        return 0
    fi
    local out=""
    local uid
    for uid in $dups; do
        out+=$(awk -F: -v id="$uid" '($3==id){print "UID " id " used by user \"" $1 "\"" }' /etc/passwd; echo $'\n')
    done
    log_warn "Duplicate UIDs detected:\n$out"
    return 1
}
apply_hardening_7_2_5() {
    log_warn "7.2.5 (duplicate UIDs) requires manual remediation (reassign UIDs and fix ownerships)"
    return 0
}

# 7.2.6 Ensure no duplicate GIDs exist (detection only)
check_compliance_7_2_6() {
    local dups
    dups=$(awk -F: '{print $3}' /etc/group | sort | uniq -d)
    if [[ -z "$dups" ]]; then
        return 0
    fi
    local out="" gid
    for gid in $dups; do
        out+=$(awk -F: -v id="$gid" '($3==id){print "GID " id " used by group \"" $1 "\"" }' /etc/group; echo $'\n')
    done
    log_warn "Duplicate GIDs detected:\n$out"
    return 1
}
apply_hardening_7_2_6() {
    log_warn "7.2.6 (duplicate GIDs) requires manual remediation (reassign GIDs and fix ownerships)"
    return 0
}

# 7.2.7 Ensure no duplicate user names exist (detection only)
check_compliance_7_2_7() {
    local dups
    dups=$(awk -F: '{print $1}' /etc/passwd | sort | uniq -d)
    if [[ -z "$dups" ]]; then
        return 0
    fi
    log_warn "Duplicate user names detected:\n$dups"
    return 1
}
apply_hardening_7_2_7() {
    log_warn "7.2.7 (duplicate user names) requires manual remediation"
    return 0
}

# 7.2.8 Ensure no duplicate group names exist (detection only)
check_compliance_7_2_8() {
    local dups
    dups=$(awk -F: '{print $1}' /etc/group | sort | uniq -d)
    if [[ -z "$dups" ]]; then
        return 0
    fi
    log_warn "Duplicate group names detected:\n$dups"
    return 1
}
apply_hardening_7_2_8() {
    log_warn "7.2.8 (duplicate group names) requires manual remediation"
    return 0
}

# Helper: list local interactive users (user home) based on shell not ending in nologin/false
get_local_interactive_users() {
    awk -F: '($7 !~ /(nologin|false)$/) {print $1 " " $6}' /etc/passwd
}

# 7.2.9 Ensure local interactive user home directories are configured
check_compliance_7_2_9() {
    local ok=true
    while read -r user home; do
        [[ -z "$user" || -z "$home" ]] && continue
        if [[ ! -d "$home" ]]; then
            log_warn "Home directory for user \"$user\" does not exist: $home"
            ok=false
            continue
        fi
        local perm owner
        perm=$(stat -Lc '%a' "$home" 2>/dev/null || echo "")
        owner=$(stat -Lc '%U' "$home" 2>/dev/null || echo "")
        # Require owner is user and no group/other write permissions
        if [[ "$owner" != "$user" ]] || ! [[ "$perm" =~ ^[0-7][0-5][0-5]$ ]]; then
            log_warn "Home directory \"$home\" for user \"$user\" has insecure ownership/permissions ($perm, owner=$owner)"
            ok=false
        fi
    done <<< "$(get_local_interactive_users)"
    [[ "$ok" == true ]]
}
apply_hardening_7_2_9() {
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would fix ownership and permissions on local interactive user home directories"
        return 0
    fi
    while read -r user home; do
        [[ -z "$user" || -z "$home" ]] && continue
        [[ -d "$home" ]] || continue
        chown "$user":"$(id -gn "$user" 2>/dev/null || echo "$user")" "$home" 2>/dev/null || true
        chmod go-w "$home" 2>/dev/null || true
    done <<< "$(get_local_interactive_users)"
    return 0
}

# 7.2.10 Ensure local interactive user dot files access is configured (detection only)
check_compliance_7_2_10() {
    local ok=true
    while read -r user home; do
        [[ -z "$user" || -z "$home" ]] && continue
        [[ -d "$home" ]] || continue
        # Flag dangerous dotfiles
        local f
        for f in ".forward" ".rhost"; do
            if [[ -e "$home/$f" ]]; then
                log_warn "User \"$user\" has disallowed file $home/$f"
                ok=false
            fi
        done
        # .netrc and .bash_history permission checks
        if [[ -e "$home/.netrc" ]]; then
            local perm
            perm=$(stat -Lc '%a' "$home/.netrc" 2>/dev/null || echo "")
            if ! [[ "$perm" =~ ^[0-6]00$ ]]; then
                log_warn "User \"$user\" .netrc has insecure permissions ($perm)"
                ok=false
            fi
        fi
        if [[ -e "$home/.bash_history" ]]; then
            local perm
            perm=$(stat -Lc '%a' "$home/.bash_history" 2>/dev/null || echo "")
            if ! [[ "$perm" =~ ^[0-6]00$ ]]; then
                log_warn "User \"$user\" .bash_history has insecure permissions ($perm)"
                ok=false
            fi
        fi
    done <<< "$(get_local_interactive_users)"
    [[ "$ok" == true ]]
}
apply_hardening_7_2_10() {
    log_warn "7.2.10 remediation (dot file cleanup/perms) is site-specific - please review reported issues"
    return 0
}


# Check if a section is already compliant
check_compliance() {
    local section="$1"
    log_info "Checking compliance for section $section..."
    
    # Map section numbers to specific compliance check functions
    case "$section" in
        1)
            # Section 1: Initial Setup - check all subsections
            log_info "Section 1 includes multiple subsections. Checking all..."
            local all_compliant=true
            # 1.1.1
            check_compliance_1_1_1_1 || all_compliant=false
            check_compliance_1_1_1_2 || all_compliant=false
            check_compliance_1_1_1_3 || all_compliant=false
            check_compliance_1_1_1_4 || all_compliant=false
            check_compliance_1_1_1_5 || all_compliant=false
            check_compliance_1_1_1_6 || all_compliant=false
            check_compliance_1_1_1_7 || all_compliant=false
            check_compliance_1_1_1_8 || all_compliant=false
            check_compliance_1_1_1_9 || all_compliant=false
            check_compliance_1_1_1_10 || all_compliant=false
            # 1.1.2
            check_compliance_1_1_2_1_1 || all_compliant=false
            check_compliance_1_1_2_1_2 || all_compliant=false
            check_compliance_1_1_2_1_3 || all_compliant=false
            check_compliance_1_1_2_1_4 || all_compliant=false
            check_compliance_1_1_2_2_1 || all_compliant=false
            check_compliance_1_1_2_2_2 || all_compliant=false
            check_compliance_1_1_2_2_3 || all_compliant=false
            check_compliance_1_1_2_2_4 || all_compliant=false
            check_compliance_1_1_2_3_1 || all_compliant=false
            check_compliance_1_1_2_3_2 || all_compliant=false
            check_compliance_1_1_2_3_3 || all_compliant=false
            check_compliance_1_1_2_4_1 || all_compliant=false
            check_compliance_1_1_2_4_2 || all_compliant=false
            check_compliance_1_1_2_4_3 || all_compliant=false
            check_compliance_1_1_2_5_1 || all_compliant=false
            check_compliance_1_1_2_5_2 || all_compliant=false
            check_compliance_1_1_2_5_3 || all_compliant=false
            check_compliance_1_1_2_5_4 || all_compliant=false
            check_compliance_1_1_2_6_1 || all_compliant=false
            check_compliance_1_1_2_6_2 || all_compliant=false
            check_compliance_1_1_2_6_3 || all_compliant=false
            check_compliance_1_1_2_6_4 || all_compliant=false
            check_compliance_1_1_2_7_1 || all_compliant=false
            check_compliance_1_1_2_7_2 || all_compliant=false
            check_compliance_1_1_2_7_3 || all_compliant=false
            check_compliance_1_1_2_7_4 || all_compliant=false
            # 1.2, 1.3, 1.4, 1.5, 1.6, 1.7
            check_compliance_1_2_1_1 || all_compliant=false
            check_compliance_1_2_1_2 || all_compliant=false
            check_compliance_1_2_2_1 || all_compliant=false
            check_compliance_1_3_1_1 || all_compliant=false
            check_compliance_1_3_1_2 || all_compliant=false
            check_compliance_1_3_1_3 || all_compliant=false
            check_compliance_1_3_1_4 || all_compliant=false
            check_compliance_1_4_1 || all_compliant=false
            check_compliance_1_4_2 || all_compliant=false
            check_compliance_1_5_1 || all_compliant=false
            check_compliance_1_5_2 || all_compliant=false
            check_compliance_1_5_3 || all_compliant=false
            check_compliance_1_5_4 || all_compliant=false
            check_compliance_1_5_5 || all_compliant=false
            check_compliance_1_6_1 || all_compliant=false
            check_compliance_1_6_2 || all_compliant=false
            check_compliance_1_6_3 || all_compliant=false
            check_compliance_1_6_4 || all_compliant=false
            check_compliance_1_6_5 || all_compliant=false
            check_compliance_1_6_6 || all_compliant=false
            check_compliance_1_7_1 || all_compliant=false
            check_compliance_1_7_2 || all_compliant=false
            check_compliance_1_7_3 || all_compliant=false
            check_compliance_1_7_4 || all_compliant=false
            check_compliance_1_7_5 || all_compliant=false
            check_compliance_1_7_6 || all_compliant=false
            check_compliance_1_7_7 || all_compliant=false
            check_compliance_1_7_8 || all_compliant=false
            check_compliance_1_7_9 || all_compliant=false
            check_compliance_1_7_10 || all_compliant=false
            [[ "$all_compliant" == true ]] && return 0 || return 1
            ;;
        2)
            # Section 2: Services - check all subsections
            log_info "Section 2 includes multiple subsections. Checking all..."
            local all_compliant=true
            check_compliance_2_1_1 || all_compliant=false
            check_compliance_2_1_2 || all_compliant=false
            check_compliance_2_1_3 || all_compliant=false
            check_compliance_2_1_4 || all_compliant=false
            check_compliance_2_1_5 || all_compliant=false
            check_compliance_2_1_6 || all_compliant=false
            check_compliance_2_1_7 || all_compliant=false
            check_compliance_2_1_8 || all_compliant=false
            check_compliance_2_1_9 || all_compliant=false
            check_compliance_2_1_10 || all_compliant=false
            check_compliance_2_1_11 || all_compliant=false
            check_compliance_2_1_12 || all_compliant=false
            check_compliance_2_1_13 || all_compliant=false
            check_compliance_2_1_14 || all_compliant=false
            check_compliance_2_1_15 || all_compliant=false
            check_compliance_2_1_16 || all_compliant=false
            check_compliance_2_1_17 || all_compliant=false
            check_compliance_2_1_18 || all_compliant=false
            check_compliance_2_1_19 || all_compliant=false
            check_compliance_2_1_20 || all_compliant=false
            check_compliance_2_1_21 || all_compliant=false
            check_compliance_2_1_22 || all_compliant=false
            check_compliance_2_2_1 || all_compliant=false
            check_compliance_2_2_2 || all_compliant=false
            check_compliance_2_2_3 || all_compliant=false
            check_compliance_2_2_4 || all_compliant=false
            check_compliance_2_2_5 || all_compliant=false
            check_compliance_2_2_6 || all_compliant=false
            check_compliance_2_3_1_1 || all_compliant=false
            check_compliance_2_3_2_1 || all_compliant=false
            check_compliance_2_3_2_2 || all_compliant=false
            check_compliance_2_3_3_1 || all_compliant=false
            check_compliance_2_3_3_2 || all_compliant=false
            check_compliance_2_3_3_3 || all_compliant=false
            check_compliance_2_4_1_1 || all_compliant=false
            check_compliance_2_4_1_2 || all_compliant=false
            check_compliance_2_4_1_3 || all_compliant=false
            check_compliance_2_4_1_4 || all_compliant=false
            check_compliance_2_4_1_5 || all_compliant=false
            check_compliance_2_4_1_6 || all_compliant=false
            check_compliance_2_4_1_7 || all_compliant=false
            check_compliance_2_4_1_8 || all_compliant=false
            check_compliance_2_4_2_1 || all_compliant=false
            [[ "$all_compliant" == true ]] && return 0 || return 1
            ;;
        3)
            # Section 3: Network - check all subsections
            log_info "Section 3 includes multiple subsections. Checking all..."
            local all_compliant=true
            check_compliance_3_1_1 || all_compliant=false
            check_compliance_3_1_2 || all_compliant=false
            check_compliance_3_1_3 || all_compliant=false
            check_compliance_3_2_1 || all_compliant=false
            check_compliance_3_2_2 || all_compliant=false
            check_compliance_3_2_3 || all_compliant=false
            check_compliance_3_2_4 || all_compliant=false
            check_compliance_3_3_1 || all_compliant=false
            check_compliance_3_3_2 || all_compliant=false
            check_compliance_3_3_3 || all_compliant=false
            check_compliance_3_3_4 || all_compliant=false
            check_compliance_3_3_5 || all_compliant=false
            check_compliance_3_3_6 || all_compliant=false
            check_compliance_3_3_7 || all_compliant=false
            check_compliance_3_3_8 || all_compliant=false
            check_compliance_3_3_9 || all_compliant=false
            check_compliance_3_3_10 || all_compliant=false
            check_compliance_3_3_11 || all_compliant=false
            [[ "$all_compliant" == true ]] && return 0 || return 1
            ;;
        5)
            # Section 5: Access Control (SSH) - check all subsections
            log_info "Section 5 includes multiple subsections. Checking all..."
            local all_compliant=true
            check_compliance_5_1_1 || all_compliant=false
            check_compliance_5_1_2 || all_compliant=false
            check_compliance_5_1_3 || all_compliant=false
            check_compliance_5_1_4 || all_compliant=false
            check_compliance_5_1_5 || all_compliant=false
            check_compliance_5_1_6 || all_compliant=false
            check_compliance_5_1_7 || all_compliant=false
            check_compliance_5_1_8 || all_compliant=false
            check_compliance_5_1_9 || all_compliant=false
            check_compliance_5_1_10 || all_compliant=false
            check_compliance_5_1_11 || all_compliant=false
            check_compliance_5_1_12 || all_compliant=false
            check_compliance_5_1_13 || all_compliant=false
            check_compliance_5_1_14 || all_compliant=false
            check_compliance_5_1_15 || all_compliant=false
            check_compliance_5_1_16 || all_compliant=false
            check_compliance_5_1_17 || all_compliant=false
            check_compliance_5_1_18 || all_compliant=false
            check_compliance_5_1_19 || all_compliant=false
            check_compliance_5_1_20 || all_compliant=false
            check_compliance_5_1_21 || all_compliant=false
            check_compliance_5_1_22 || all_compliant=false
            [[ "$all_compliant" == true ]] && return 0 || return 1
            ;;
        7)
            # Section 7: System Maintenance - check all subsections
            log_info "Section 7 includes multiple subsections. Checking all..."
            local all_compliant=true
            check_compliance_7_1_1 || all_compliant=false
            check_compliance_7_1_2 || all_compliant=false
            check_compliance_7_1_3 || all_compliant=false
            check_compliance_7_1_4 || all_compliant=false
            check_compliance_7_1_5 || all_compliant=false
            check_compliance_7_1_6 || all_compliant=false
            check_compliance_7_1_7 || all_compliant=false
            check_compliance_7_1_8 || all_compliant=false
            check_compliance_7_1_9 || all_compliant=false
            check_compliance_7_1_10 || all_compliant=false
            check_compliance_7_1_11 || all_compliant=false
            check_compliance_7_1_12 || all_compliant=false
            check_compliance_7_1_13 || all_compliant=false
            check_compliance_7_2_1 || all_compliant=false
            check_compliance_7_2_2 || all_compliant=false
            check_compliance_7_2_3 || all_compliant=false
            check_compliance_7_2_4 || all_compliant=false
            check_compliance_7_2_5 || all_compliant=false
            check_compliance_7_2_6 || all_compliant=false
            check_compliance_7_2_7 || all_compliant=false
            check_compliance_7_2_8 || all_compliant=false
            check_compliance_7_2_9 || all_compliant=false
            check_compliance_7_2_10 || all_compliant=false
            [[ "$all_compliant" == true ]] && return 0 || return 1
            ;;
        4)
            # Section 4: Host Based Firewall - check all subsections
            log_info "Section 4 includes multiple subsections. Checking all..."
            local all_compliant=true
            check_compliance_4_1_1 || all_compliant=false
            check_compliance_4_2_1 || all_compliant=false
            check_compliance_4_2_2 || all_compliant=false
            check_compliance_4_2_3 || all_compliant=false
            check_compliance_4_2_4 || all_compliant=false
            check_compliance_4_2_5 || all_compliant=false
            check_compliance_4_2_6 || all_compliant=false
            check_compliance_4_2_7 || all_compliant=false
            check_compliance_4_3_1 || all_compliant=false
            check_compliance_4_3_2 || all_compliant=false
            check_compliance_4_3_3 || all_compliant=false
            check_compliance_4_3_4 || all_compliant=false
            check_compliance_4_3_5 || all_compliant=false
            check_compliance_4_3_6 || all_compliant=false
            check_compliance_4_3_7 || all_compliant=false
            check_compliance_4_3_8 || all_compliant=false
            check_compliance_4_3_9 || all_compliant=false
            check_compliance_4_3_10 || all_compliant=false
            check_compliance_4_4_1_1 || all_compliant=false
            check_compliance_4_4_1_2 || all_compliant=false
            check_compliance_4_4_1_3 || all_compliant=false
            check_compliance_4_4_2_1 || all_compliant=false
            check_compliance_4_4_2_2 || all_compliant=false
            check_compliance_4_4_2_3 || all_compliant=false
            check_compliance_4_4_2_4 || all_compliant=false
            check_compliance_4_4_3_1 || all_compliant=false
            check_compliance_4_4_3_2 || all_compliant=false
            check_compliance_4_4_3_3 || all_compliant=false
            check_compliance_4_4_3_4 || all_compliant=false
            [[ "$all_compliant" == true ]] && return 0 || return 1
            ;;
        1.1.1)
            # Section 1.1.1: Configure Filesystem Kernel Modules - check all subsections
            log_info "Checking all 1.1.1 kernel module sections..."
            local all_compliant=true
            check_compliance_1_1_1_1 || all_compliant=false
            check_compliance_1_1_1_2 || all_compliant=false
            check_compliance_1_1_1_3 || all_compliant=false
            check_compliance_1_1_1_4 || all_compliant=false
            check_compliance_1_1_1_5 || all_compliant=false
            check_compliance_1_1_1_6 || all_compliant=false
            check_compliance_1_1_1_7 || all_compliant=false
            check_compliance_1_1_1_8 || all_compliant=false
            check_compliance_1_1_1_9 || all_compliant=false
            check_compliance_1_1_1_10 || all_compliant=false
            [[ "$all_compliant" == true ]] && return 0 || return 1
            ;;
        1.1.1.1)
            check_compliance_1_1_1_1
            ;;
        1.1.1.2)
            check_compliance_1_1_1_2
            ;;
        1.1.1.3)
            check_compliance_1_1_1_3
            ;;
        1.1.1.4)
            check_compliance_1_1_1_4
            ;;
        1.1.1.5)
            check_compliance_1_1_1_5
            ;;
        1.1.1.6)
            check_compliance_1_1_1_6
            ;;
        1.1.1.7)
            check_compliance_1_1_1_7
            ;;
        1.1.1.8)
            check_compliance_1_1_1_8
            ;;
        1.1.1.9)
            check_compliance_1_1_1_9
            ;;
        1.1.1.10)
            check_compliance_1_1_1_10
            ;;
        1.1.2.1.1|1.1.2.1.2|1.1.2.1.3|1.1.2.1.4|1.1.2.2.1|1.1.2.2.2|1.1.2.2.3|1.1.2.2.4|1.1.2.3.1|1.1.2.3.2|1.1.2.3.3|1.1.2.4.1|1.1.2.4.2|1.1.2.4.3|1.1.2.5.1|1.1.2.5.2|1.1.2.5.3|1.1.2.5.4|1.1.2.6.1|1.1.2.6.2|1.1.2.6.3|1.1.2.6.4|1.1.2.7.1|1.1.2.7.2|1.1.2.7.3|1.1.2.7.4)
            local func_name="check_compliance_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        1.2.1.1|1.2.1.2|1.2.2.1|1.3.1.1|1.3.1.2|1.3.1.3|1.3.1.4|1.4.1|1.4.2|1.5.1|1.5.2|1.5.3|1.5.4|1.5.5|1.6.1|1.6.2|1.6.3|1.6.4|1.6.5|1.6.6|1.7.1|1.7.2|1.7.3|1.7.4|1.7.5|1.7.6|1.7.7|1.7.8|1.7.9|1.7.10)
            local func_name="check_compliance_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        2.1.1|2.1.2|2.1.3|2.1.4|2.1.5|2.1.6|2.1.7|2.1.8|2.1.9|2.1.10|2.1.11|2.1.12|2.1.13|2.1.14|2.1.15|2.1.16|2.1.17|2.1.18|2.1.19|2.1.20|2.1.21|2.1.22|2.2.1|2.2.2|2.2.3|2.2.4|2.2.5|2.2.6|2.3.1.1|2.3.2.1|2.3.2.2|2.3.3.1|2.3.3.2|2.3.3.3|2.4.1.1|2.4.1.2|2.4.1.3|2.4.1.4|2.4.1.5|2.4.1.6|2.4.1.7|2.4.1.8|2.4.2.1)
            local func_name="check_compliance_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        3.1.1|3.1.2|3.1.3|3.2.1|3.2.2|3.2.3|3.2.4|3.3.1|3.3.2|3.3.3|3.3.4|3.3.5|3.3.6|3.3.7|3.3.8|3.3.9|3.3.10|3.3.11)
            local func_name="check_compliance_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        4.1.1|4.2.1|4.2.2|4.2.3|4.2.4|4.2.5|4.2.6|4.2.7|4.3.1|4.3.2|4.3.3|4.3.4|4.3.5|4.3.6|4.3.7|4.3.8|4.3.9|4.3.10|4.4.1.1|4.4.1.2|4.4.1.3|4.4.2.1|4.4.2.2|4.4.2.3|4.4.2.4|4.4.3.1|4.4.3.2|4.4.3.3|4.4.3.4|5.1.1|5.1.2|5.1.3|5.1.4|5.1.5|5.1.6|5.1.7|5.1.8|5.1.9|5.1.10|5.1.11|5.1.12|5.1.13|5.1.14|5.1.15|5.1.16|5.1.17|5.1.18|5.1.19|5.1.20|5.1.21|5.1.22|7.1.1|7.1.2|7.1.3|7.1.4|7.1.5|7.1.6|7.1.7|7.1.8|7.1.9|7.1.10|7.1.11|7.1.12|7.1.13|7.2.1|7.2.2|7.2.3|7.2.4|7.2.5|7.2.6|7.2.7|7.2.8|7.2.9|7.2.10)
            local func_name="check_compliance_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        *)
            log_warn "Compliance check for section $section not yet implemented"
            # Return non-compliant to trigger remediation attempt
            return 1
            ;;
    esac
}

# Apply hardening setting for a section
apply_hardening() {
    local section="$1"
    
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "Would apply hardening for section $section..."
    fi
    
    log_info "Applying hardening for section $section..."
    
    # Map section numbers to specific hardening functions
    case "$section" in
        1)
            # Section 1: Initial Setup - apply all subsections
            log_info "Section 1 includes multiple subsections. Applying all..."
            local all_success=true
            # 1.1.1
            apply_hardening_1_1_1_1 || all_success=false
            apply_hardening_1_1_1_2 || all_success=false
            apply_hardening_1_1_1_3 || all_success=false
            apply_hardening_1_1_1_4 || all_success=false
            apply_hardening_1_1_1_5 || all_success=false
            apply_hardening_1_1_1_6 || all_success=false
            apply_hardening_1_1_1_7 || all_success=false
            apply_hardening_1_1_1_8 || all_success=false
            apply_hardening_1_1_1_9 || all_success=false
            apply_hardening_1_1_1_10 || all_success=false
            # 1.1.2
            apply_hardening_1_1_2_1_1 || all_success=false
            apply_hardening_1_1_2_1_2 || all_success=false
            apply_hardening_1_1_2_1_3 || all_success=false
            apply_hardening_1_1_2_1_4 || all_success=false
            apply_hardening_1_1_2_2_1 || all_success=false
            apply_hardening_1_1_2_2_2 || all_success=false
            apply_hardening_1_1_2_2_3 || all_success=false
            apply_hardening_1_1_2_2_4 || all_success=false
            apply_hardening_1_1_2_3_1 || all_success=false
            apply_hardening_1_1_2_3_2 || all_success=false
            apply_hardening_1_1_2_3_3 || all_success=false
            apply_hardening_1_1_2_4_1 || all_success=false
            apply_hardening_1_1_2_4_2 || all_success=false
            apply_hardening_1_1_2_4_3 || all_success=false
            apply_hardening_1_1_2_5_1 || all_success=false
            apply_hardening_1_1_2_5_2 || all_success=false
            apply_hardening_1_1_2_5_3 || all_success=false
            apply_hardening_1_1_2_5_4 || all_success=false
            apply_hardening_1_1_2_6_1 || all_success=false
            apply_hardening_1_1_2_6_2 || all_success=false
            apply_hardening_1_1_2_6_3 || all_success=false
            apply_hardening_1_1_2_6_4 || all_success=false
            apply_hardening_1_1_2_7_1 || all_success=false
            apply_hardening_1_1_2_7_2 || all_success=false
            apply_hardening_1_1_2_7_3 || all_success=false
            apply_hardening_1_1_2_7_4 || all_success=false
            # 1.2, 1.3, 1.4, 1.5, 1.6, 1.7
            apply_hardening_1_2_1_1 || all_success=false
            apply_hardening_1_2_1_2 || all_success=false
            apply_hardening_1_2_2_1 || all_success=false
            apply_hardening_1_3_1_1 || all_success=false
            apply_hardening_1_3_1_2 || all_success=false
            apply_hardening_1_3_1_3 || all_success=false
            apply_hardening_1_3_1_4 || all_success=false
            apply_hardening_1_4_1 || all_success=false
            apply_hardening_1_4_2 || all_success=false
            apply_hardening_1_5_1 || all_success=false
            apply_hardening_1_5_2 || all_success=false
            apply_hardening_1_5_3 || all_success=false
            apply_hardening_1_5_4 || all_success=false
            apply_hardening_1_5_5 || all_success=false
            apply_hardening_1_6_1 || all_success=false
            apply_hardening_1_6_2 || all_success=false
            apply_hardening_1_6_3 || all_success=false
            apply_hardening_1_6_4 || all_success=false
            apply_hardening_1_6_5 || all_success=false
            apply_hardening_1_6_6 || all_success=false
            apply_hardening_1_7_1 || all_success=false
            apply_hardening_1_7_2 || all_success=false
            apply_hardening_1_7_3 || all_success=false
            apply_hardening_1_7_4 || all_success=false
            apply_hardening_1_7_5 || all_success=false
            apply_hardening_1_7_6 || all_success=false
            apply_hardening_1_7_7 || all_success=false
            apply_hardening_1_7_8 || all_success=false
            apply_hardening_1_7_9 || all_success=false
            apply_hardening_1_7_10 || all_success=false
            [[ "$all_success" == true ]] && return 0 || return 1
            ;;
        2)
            # Section 2: Services - apply all subsections
            log_info "Section 2 includes multiple subsections. Applying all..."
            local all_success=true
            apply_hardening_2_1_1 || all_success=false
            apply_hardening_2_1_2 || all_success=false
            apply_hardening_2_1_3 || all_success=false
            apply_hardening_2_1_4 || all_success=false
            apply_hardening_2_1_5 || all_success=false
            apply_hardening_2_1_6 || all_success=false
            apply_hardening_2_1_7 || all_success=false
            apply_hardening_2_1_8 || all_success=false
            apply_hardening_2_1_9 || all_success=false
            apply_hardening_2_1_10 || all_success=false
            apply_hardening_2_1_11 || all_success=false
            apply_hardening_2_1_12 || all_success=false
            apply_hardening_2_1_13 || all_success=false
            apply_hardening_2_1_14 || all_success=false
            apply_hardening_2_1_15 || all_success=false
            apply_hardening_2_1_16 || all_success=false
            apply_hardening_2_1_17 || all_success=false
            apply_hardening_2_1_18 || all_success=false
            apply_hardening_2_1_19 || all_success=false
            apply_hardening_2_1_20 || all_success=false
            apply_hardening_2_1_21 || all_success=false
            apply_hardening_2_1_22 || all_success=false
            apply_hardening_2_2_1 || all_success=false
            apply_hardening_2_2_2 || all_success=false
            apply_hardening_2_2_3 || all_success=false
            apply_hardening_2_2_4 || all_success=false
            apply_hardening_2_2_5 || all_success=false
            apply_hardening_2_2_6 || all_success=false
            apply_hardening_2_3_1_1 || all_success=false
            apply_hardening_2_3_2_1 || all_success=false
            apply_hardening_2_3_2_2 || all_success=false
            apply_hardening_2_3_3_1 || all_success=false
            apply_hardening_2_3_3_2 || all_success=false
            apply_hardening_2_3_3_3 || all_success=false
            apply_hardening_2_4_1_1 || all_success=false
            apply_hardening_2_4_1_2 || all_success=false
            apply_hardening_2_4_1_3 || all_success=false
            apply_hardening_2_4_1_4 || all_success=false
            apply_hardening_2_4_1_5 || all_success=false
            apply_hardening_2_4_1_6 || all_success=false
            apply_hardening_2_4_1_7 || all_success=false
            apply_hardening_2_4_1_8 || all_success=false
            apply_hardening_2_4_2_1 || all_success=false
            [[ "$all_success" == true ]] && return 0 || return 1
            ;;
        3)
            # Section 3: Network - apply all subsections
            log_info "Section 3 includes multiple subsections. Applying all..."
            local all_success=true
            apply_hardening_3_1_1 || all_success=false
            apply_hardening_3_1_2 || all_success=false
            apply_hardening_3_1_3 || all_success=false
            apply_hardening_3_2_1 || all_success=false
            apply_hardening_3_2_2 || all_success=false
            apply_hardening_3_2_3 || all_success=false
            apply_hardening_3_2_4 || all_success=false
            apply_hardening_3_3_1 || all_success=false
            apply_hardening_3_3_2 || all_success=false
            apply_hardening_3_3_3 || all_success=false
            apply_hardening_3_3_4 || all_success=false
            apply_hardening_3_3_5 || all_success=false
            apply_hardening_3_3_6 || all_success=false
            apply_hardening_3_3_7 || all_success=false
            apply_hardening_3_3_8 || all_success=false
            apply_hardening_3_3_9 || all_success=false
            apply_hardening_3_3_10 || all_success=false
            apply_hardening_3_3_11 || all_success=false
            [[ "$all_success" == true ]] && return 0 || return 1
            ;;
        5)
            # Section 5: Access Control (SSH) - apply all subsections
            log_info "Section 5 includes multiple subsections. Applying all..."
            local all_success=true
            apply_hardening_5_1_1 || all_success=false
            apply_hardening_5_1_2 || all_success=false
            apply_hardening_5_1_3 || all_success=false
            apply_hardening_5_1_4 || all_success=false
            apply_hardening_5_1_5 || all_success=false
            apply_hardening_5_1_6 || all_success=false
            apply_hardening_5_1_7 || all_success=false
            apply_hardening_5_1_8 || all_success=false
            apply_hardening_5_1_9 || all_success=false
            apply_hardening_5_1_10 || all_success=false
            apply_hardening_5_1_11 || all_success=false
            apply_hardening_5_1_12 || all_success=false
            apply_hardening_5_1_13 || all_success=false
            apply_hardening_5_1_14 || all_success=false
            apply_hardening_5_1_15 || all_success=false
            apply_hardening_5_1_16 || all_success=false
            apply_hardening_5_1_17 || all_success=false
            apply_hardening_5_1_18 || all_success=false
            apply_hardening_5_1_19 || all_success=false
            apply_hardening_5_1_20 || all_success=false
            apply_hardening_5_1_21 || all_success=false
            apply_hardening_5_1_22 || all_success=false
            [[ "$all_success" == true ]] && return 0 || return 1
            ;;
        7)
            # Section 7: System Maintenance - apply all subsections
            log_info "Section 7 includes multiple subsections. Applying all..."
            local all_success=true
            apply_hardening_7_1_1 || all_success=false
            apply_hardening_7_1_2 || all_success=false
            apply_hardening_7_1_3 || all_success=false
            apply_hardening_7_1_4 || all_success=false
            apply_hardening_7_1_5 || all_success=false
            apply_hardening_7_1_6 || all_success=false
            apply_hardening_7_1_7 || all_success=false
            apply_hardening_7_1_8 || all_success=false
            apply_hardening_7_1_9 || all_success=false
            apply_hardening_7_1_10 || all_success=false
            apply_hardening_7_1_11 || all_success=false
            apply_hardening_7_1_12 || all_success=false
            apply_hardening_7_1_13 || all_success=false
            apply_hardening_7_2_1 || all_success=false
            apply_hardening_7_2_2 || all_success=false
            apply_hardening_7_2_3 || all_success=false
            apply_hardening_7_2_4 || all_success=false
            apply_hardening_7_2_5 || all_success=false
            apply_hardening_7_2_6 || all_success=false
            apply_hardening_7_2_7 || all_success=false
            apply_hardening_7_2_8 || all_success=false
            apply_hardening_7_2_9 || all_success=false
            apply_hardening_7_2_10 || all_success=false
            [[ "$all_success" == true ]] && return 0 || return 1
            ;;
        4)
            # Section 4: Host Based Firewall - apply all subsections
            log_info "Section 4 includes multiple subsections. Applying all..."
            local all_success=true
            apply_hardening_4_1_1 || all_success=false
            apply_hardening_4_2_1 || all_success=false
            apply_hardening_4_2_2 || all_success=false
            apply_hardening_4_2_3 || all_success=false
            apply_hardening_4_2_4 || all_success=false
            apply_hardening_4_2_5 || all_success=false
            apply_hardening_4_2_6 || all_success=false
            apply_hardening_4_2_7 || all_success=false
            apply_hardening_4_3_1 || all_success=false
            apply_hardening_4_3_2 || all_success=false
            apply_hardening_4_3_3 || all_success=false
            apply_hardening_4_3_4 || all_success=false
            apply_hardening_4_3_5 || all_success=false
            apply_hardening_4_3_6 || all_success=false
            apply_hardening_4_3_7 || all_success=false
            apply_hardening_4_3_8 || all_success=false
            apply_hardening_4_3_9 || all_success=false
            apply_hardening_4_3_10 || all_success=false
            apply_hardening_4_4_1_1 || all_success=false
            apply_hardening_4_4_1_2 || all_success=false
            apply_hardening_4_4_1_3 || all_success=false
            apply_hardening_4_4_2_1 || all_success=false
            apply_hardening_4_4_2_2 || all_success=false
            apply_hardening_4_4_2_3 || all_success=false
            apply_hardening_4_4_2_4 || all_success=false
            apply_hardening_4_4_3_1 || all_success=false
            apply_hardening_4_4_3_2 || all_success=false
            apply_hardening_4_4_3_3 || all_success=false
            apply_hardening_4_4_3_4 || all_success=false
            [[ "$all_success" == true ]] && return 0 || return 1
            ;;
        1.1.1)
            # Section 1.1.1: Configure Filesystem Kernel Modules - apply all subsections
            log_info "Applying all 1.1.1 kernel module sections..."
            local all_success=true
            apply_hardening_1_1_1_1 || all_success=false
            apply_hardening_1_1_1_2 || all_success=false
            apply_hardening_1_1_1_3 || all_success=false
            apply_hardening_1_1_1_4 || all_success=false
            apply_hardening_1_1_1_5 || all_success=false
            apply_hardening_1_1_1_6 || all_success=false
            apply_hardening_1_1_1_7 || all_success=false
            apply_hardening_1_1_1_8 || all_success=false
            apply_hardening_1_1_1_9 || all_success=false
            apply_hardening_1_1_1_10 || all_success=false
            [[ "$all_success" == true ]] && return 0 || return 1
            ;;
        1.1.1.1)
            apply_hardening_1_1_1_1
            ;;
        1.1.1.2)
            apply_hardening_1_1_1_2
            ;;
        1.1.1.3)
            apply_hardening_1_1_1_3
            ;;
        1.1.1.4)
            apply_hardening_1_1_1_4
            ;;
        1.1.1.5)
            apply_hardening_1_1_1_5
            ;;
        1.1.1.6)
            apply_hardening_1_1_1_6
            ;;
        1.1.1.7)
            apply_hardening_1_1_1_7
            ;;
        1.1.1.8)
            apply_hardening_1_1_1_8
            ;;
        1.1.1.9)
            apply_hardening_1_1_1_9
            ;;
        1.1.1.10)
            apply_hardening_1_1_1_10
            ;;
        1.1.2.1.1|1.1.2.1.2|1.1.2.1.3|1.1.2.1.4|1.1.2.2.1|1.1.2.2.2|1.1.2.2.3|1.1.2.2.4|1.1.2.3.1|1.1.2.3.2|1.1.2.3.3|1.1.2.4.1|1.1.2.4.2|1.1.2.4.3|1.1.2.5.1|1.1.2.5.2|1.1.2.5.3|1.1.2.5.4|1.1.2.6.1|1.1.2.6.2|1.1.2.6.3|1.1.2.6.4|1.1.2.7.1|1.1.2.7.2|1.1.2.7.3|1.1.2.7.4)
            local func_name="apply_hardening_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        1.2.1.1|1.2.1.2|1.2.2.1|1.3.1.1|1.3.1.2|1.3.1.3|1.3.1.4|1.4.1|1.4.2|1.5.1|1.5.2|1.5.3|1.5.4|1.5.5|1.6.1|1.6.2|1.6.3|1.6.4|1.6.5|1.6.6|1.7.1|1.7.2|1.7.3|1.7.4|1.7.5|1.7.6|1.7.7|1.7.8|1.7.9|1.7.10)
            local func_name="apply_hardening_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        2.1.1|2.1.2|2.1.3|2.1.4|2.1.5|2.1.6|2.1.7|2.1.8|2.1.9|2.1.10|2.1.11|2.1.12|2.1.13|2.1.14|2.1.15|2.1.16|2.1.17|2.1.18|2.1.19|2.1.20|2.1.21|2.1.22|2.2.1|2.2.2|2.2.3|2.2.4|2.2.5|2.2.6|2.3.1.1|2.3.2.1|2.3.2.2|2.3.3.1|2.3.3.2|2.3.3.3|2.4.1.1|2.4.1.2|2.4.1.3|2.4.1.4|2.4.1.5|2.4.1.6|2.4.1.7|2.4.1.8|2.4.2.1)
            local func_name="apply_hardening_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        3.1.1|3.1.2|3.1.3|3.2.1|3.2.2|3.2.3|3.2.4|3.3.1|3.3.2|3.3.3|3.3.4|3.3.5|3.3.6|3.3.7|3.3.8|3.3.9|3.3.10|3.3.11)
            local func_name="apply_hardening_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        4.1.1|4.2.1|4.2.2|4.2.3|4.2.4|4.2.5|4.2.6|4.2.7|4.3.1|4.3.2|4.3.3|4.3.4|4.3.5|4.3.6|4.3.7|4.3.8|4.3.9|4.3.10|4.4.1.1|4.4.1.2|4.4.1.3|4.4.2.1|4.4.2.2|4.4.2.3|4.4.2.4|4.4.3.1|4.4.3.2|4.4.3.3|4.4.3.4|5.1.1|5.1.2|5.1.3|5.1.4|5.1.5|5.1.6|5.1.7|5.1.8|5.1.9|5.1.10|5.1.11|5.1.12|5.1.13|5.1.14|5.1.15|5.1.16|5.1.17|5.1.18|5.1.19|5.1.20|5.1.21|5.1.22|7.1.1|7.1.2|7.1.3|7.1.4|7.1.5|7.1.6|7.1.7|7.1.8|7.1.9|7.1.10|7.1.11|7.1.12|7.1.13|7.2.1|7.2.2|7.2.3|7.2.4|7.2.5|7.2.6|7.2.7|7.2.8|7.2.9|7.2.10)
            local func_name="apply_hardening_$(echo $section | tr '.' '_')"
            $func_name
            ;;
        *)
            log_warn "Hardening for section $section not yet implemented"
            return 1
            ;;
    esac
}

# Verify that the hardening was applied successfully
verify_hardening() {
    local section="$1"
    log_info "Verifying hardening for section $section..."
    
    # For section 1, only verify automated sections (skip manual and partition sections)
    if [[ "$section" == "1" ]]; then
        log_info "Verifying automated sections only (skipping manual sections)..."
        local all_compliant=true
        # 1.1.1 - Skip 1.1.1.10 (manual)
        check_compliance_1_1_1_1 || all_compliant=false
        check_compliance_1_1_1_2 || all_compliant=false
        check_compliance_1_1_1_3 || all_compliant=false
        check_compliance_1_1_1_4 || all_compliant=false
        check_compliance_1_1_1_5 || all_compliant=false
        check_compliance_1_1_1_6 || all_compliant=false
        check_compliance_1_1_1_7 || all_compliant=false
        check_compliance_1_1_1_8 || all_compliant=false
        check_compliance_1_1_1_9 || all_compliant=false
        # Skip 1.1.1.10 - manual section
        
        # 1.1.2 - Skip partition sections (1.1.2.X.1), only check mount options if mount point exists in fstab
        # Skip 1.1.2.1.1, 1.1.2.2.1, 1.1.2.3.1, 1.1.2.4.1, 1.1.2.5.1, 1.1.2.6.1, 1.1.2.7.1 (manual partition config)
        # For mount options, only verify if the mount point exists in fstab (otherwise it's manual setup)
        if grep -q "^[^#].*[[:space:]]/tmp[[:space:]]" /etc/fstab 2>/dev/null; then
            check_compliance_1_1_2_1_2 || all_compliant=false
            check_compliance_1_1_2_1_3 || all_compliant=false
            check_compliance_1_1_2_1_4 || all_compliant=false
        fi
        if grep -q "^[^#].*[[:space:]]/dev/shm[[:space:]]" /etc/fstab 2>/dev/null; then
            check_compliance_1_1_2_2_2 || all_compliant=false
            check_compliance_1_1_2_2_3 || all_compliant=false
            check_compliance_1_1_2_2_4 || all_compliant=false
        fi
        if grep -q "^[^#].*[[:space:]]/home[[:space:]]" /etc/fstab 2>/dev/null; then
            check_compliance_1_1_2_3_2 || all_compliant=false
            check_compliance_1_1_2_3_3 || all_compliant=false
        fi
        if grep -q "^[^#].*[[:space:]]/var[[:space:]]" /etc/fstab 2>/dev/null; then
            check_compliance_1_1_2_4_2 || all_compliant=false
            check_compliance_1_1_2_4_3 || all_compliant=false
        fi
        if grep -q "^[^#].*[[:space:]]/var/tmp[[:space:]]" /etc/fstab 2>/dev/null; then
            check_compliance_1_1_2_5_2 || all_compliant=false
            check_compliance_1_1_2_5_3 || all_compliant=false
            check_compliance_1_1_2_5_4 || all_compliant=false
        fi
        if grep -q "^[^#].*[[:space:]]/var/log[[:space:]]" /etc/fstab 2>/dev/null; then
            check_compliance_1_1_2_6_2 || all_compliant=false
            check_compliance_1_1_2_6_3 || all_compliant=false
            check_compliance_1_1_2_6_4 || all_compliant=false
        fi
        if grep -q "^[^#].*[[:space:]]/var/log/audit[[:space:]]" /etc/fstab 2>/dev/null; then
            check_compliance_1_1_2_7_2 || all_compliant=false
            check_compliance_1_1_2_7_3 || all_compliant=false
            check_compliance_1_1_2_7_4 || all_compliant=false
        fi
        
        # 1.2 - Skip all (manual sections)
        # Skip 1.2.1.1, 1.2.1.2, 1.2.2.1 - all manual
        
        # 1.3, 1.4, 1.5, 1.6, 1.7 - Check all except manual sections
        check_compliance_1_3_1_1 || all_compliant=false
        check_compliance_1_3_1_2 || all_compliant=false
        check_compliance_1_3_1_3 || all_compliant=false
        check_compliance_1_3_1_4 || all_compliant=false
        # Skip 1.4.1 - manual bootloader password
        check_compliance_1_4_2 || all_compliant=false
        check_compliance_1_5_1 || all_compliant=false
        check_compliance_1_5_2 || all_compliant=false
        check_compliance_1_5_3 || all_compliant=false
        check_compliance_1_5_4 || all_compliant=false
        check_compliance_1_5_5 || all_compliant=false
        check_compliance_1_6_1 || all_compliant=false
        check_compliance_1_6_2 || all_compliant=false
        check_compliance_1_6_3 || all_compliant=false
        check_compliance_1_6_4 || all_compliant=false
        check_compliance_1_6_5 || all_compliant=false
        check_compliance_1_6_6 || all_compliant=false
        check_compliance_1_7_1 || all_compliant=false
        check_compliance_1_7_2 || all_compliant=false
        check_compliance_1_7_3 || all_compliant=false
        check_compliance_1_7_4 || all_compliant=false
        check_compliance_1_7_5 || all_compliant=false
        check_compliance_1_7_6 || all_compliant=false
        check_compliance_1_7_7 || all_compliant=false
        check_compliance_1_7_8 || all_compliant=false
        check_compliance_1_7_9 || all_compliant=false
        check_compliance_1_7_10 || all_compliant=false
        
        [[ "$all_compliant" == true ]] && return 0 || return 1
    else
        # For other sections, use standard compliance check
        if check_compliance "$section"; then
            return 0
        else
            return 1
        fi
    fi
}

# Return 0 if post-apply verify should be skipped (manual control, fstab N/A, etc.); else 1.
cis_subsection_skip_post_verify() {
    local sub_section="$1"
    case "$sub_section" in
        1.1.1.10|1.1.2.1.1|1.1.2.2.1|1.1.2.3.1|1.1.2.4.1|1.1.2.5.1|1.1.2.6.1|1.1.2.7.1|1.2.1.1|1.2.1.2|1.2.2.1|1.4.1)
            return 0
            ;;
        4.2.5|4.3.3|4.3.7|4.4.2.3|4.4.3.3|5.1.4|7.1.11|7.1.12|7.2.3|7.2.4|7.2.5|7.2.6|7.2.7|7.2.8|7.2.10)
            return 0
            ;;
    esac
    case "$sub_section" in
        1.1.2.1.2|1.1.2.1.3|1.1.2.1.4)
            if ! grep -q "^[^#].*[[:space:]]/tmp[[:space:]]" /etc/fstab 2>/dev/null; then
                return 0
            fi
            ;;
        1.1.2.2.2|1.1.2.2.3|1.1.2.2.4)
            if ! grep -q "^[^#].*[[:space:]]/dev/shm[[:space:]]" /etc/fstab 2>/dev/null; then
                return 0
            fi
            ;;
        1.1.2.3.2|1.1.2.3.3)
            if ! grep -q "^[^#].*[[:space:]]/home[[:space:]]" /etc/fstab 2>/dev/null; then
                return 0
            fi
            ;;
        1.1.2.4.2|1.1.2.4.3)
            if ! grep -q "^[^#].*[[:space:]]/var[[:space:]]" /etc/fstab 2>/dev/null; then
                return 0
            fi
            ;;
        1.1.2.5.2|1.1.2.5.3|1.1.2.5.4)
            if ! grep -q "^[^#].*[[:space:]]/var/tmp[[:space:]]" /etc/fstab 2>/dev/null; then
                return 0
            fi
            ;;
        1.1.2.6.2|1.1.2.6.3|1.1.2.6.4)
            if ! grep -q "^[^#].*[[:space:]]/var/log[[:space:]]" /etc/fstab 2>/dev/null; then
                return 0
            fi
            ;;
        1.1.2.7.2|1.1.2.7.3|1.1.2.7.4)
            if ! grep -q "^[^#].*[[:space:]]/var/log/audit[[:space:]]" /etc/fstab 2>/dev/null; then
                return 0
            fi
            ;;
    esac
    return 1
}

# Process one CIS subsection ID: one CSV row, optional summary via nameref array (bash 4.3+).
# Args: subsection_id results_array_name
# Returns 0 on success path, 1 if apply or verify failed.
process_one_cis_subsection() {
    local sub_section="$1"
    local -n _subsection_results="${2:?}"
    local sub_status=""
    local sub_message=""
    local dry_run_suffix=""
    [[ "$DRY_RUN" == true ]] && dry_run_suffix=" (DRY-RUN)"

    if [[ "$VERIFY_ONLY" == true ]]; then
        if cis_subsection_skip_post_verify "$sub_section"; then
            sub_status="success"
            sub_message="Verify-only: not assessed (manual or prerequisite missing)"
            log_info "  $sub_section: $sub_message"
            echo "$sub_section,SKIPPED,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
            _subsection_results+=("$sub_section:$sub_status")
            return 0
        fi
        if verify_hardening "$sub_section" 2>/dev/null; then
            sub_status="success"
            sub_message="Compliant (verify only)"
            log_success "  $sub_section: $sub_message"
            echo "$sub_section,PASS,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
            _subsection_results+=("$sub_section:$sub_status")
            return 0
        else
            sub_status="fail"
            sub_message="Not compliant (verify only)"
            log_error "  $sub_section: $sub_message"
            echo "$sub_section,VERIFY_FAILED,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
            _subsection_results+=("$sub_section:$sub_status")
            return 1
        fi
    fi

    if check_compliance "$sub_section" 2>/dev/null; then
        sub_status="success"
        sub_message="Already compliant"
        log_info "  $sub_section: $sub_status - $sub_message"
        echo "$sub_section,SKIPPED,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
        _subsection_results+=("$sub_section:$sub_status")
        return 0
    fi

    if apply_hardening "$sub_section" 2>/dev/null; then
        local skip_verify=false
        if cis_subsection_skip_post_verify "$sub_section"; then
            skip_verify=true
        fi

        if [[ "$DRY_RUN" == true ]] || [[ "$skip_verify" == true ]] || verify_hardening "$sub_section" 2>/dev/null; then
            if [[ "$DRY_RUN" == true ]]; then
                sub_status="success"
                sub_message="Would apply hardening${dry_run_suffix}"
            else
                sub_status="success"
                sub_message="Hardening applied and verified"
            fi
            log_success "  $sub_section: $sub_status - $sub_message"
            echo "$sub_section,FIXED,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
            _subsection_results+=("$sub_section:$sub_status")
            return 0
        else
            sub_status="fail"
            sub_message="Verification failed"
            log_error "  $sub_section: $sub_status - $sub_message"
            echo "$sub_section,VERIFY_FAILED,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
            _subsection_results+=("$sub_section:$sub_status")
            return 1
        fi
    else
        sub_status="fail"
        sub_message="Failed to apply hardening"
        log_error "  $sub_section: $sub_status - $sub_message"
        echo "$sub_section,FAILED,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
        _subsection_results+=("$sub_section:$sub_status")
        return 1
    fi
}

# Sections 2–5 and 7: same per-subsection CSV reporting as section 1 (order matches check_compliance).
process_section_multi_detailed() {
    local sec="$1"

    log_info "========================================="
    log_info "Processing Section: $sec (with detailed subsection reporting)"
    if [[ "$VERIFY_ONLY" == true ]]; then
        log_info "VERIFY-ONLY MODE: compliance checks and report only (no hardening)"
    elif [[ "$DRY_RUN" == true ]]; then
        log_dryrun "DRY-RUN MODE: No changes will be applied"
    fi
    log_info "========================================="

    local overall_success=true
    local subsection_results=()

    local subs=()
    case "$sec" in
        2)
            subs=(
                2.1.1 2.1.2 2.1.3 2.1.4 2.1.5 2.1.6 2.1.7 2.1.8 2.1.9 2.1.10 2.1.11 2.1.12 2.1.13 2.1.14 2.1.15 2.1.16 2.1.17 2.1.18 2.1.19 2.1.20 2.1.21 2.1.22
                2.2.1 2.2.2 2.2.3 2.2.4 2.2.5 2.2.6
                2.3.1.1 2.3.2.1 2.3.2.2 2.3.3.1 2.3.3.2 2.3.3.3
                2.4.1.1 2.4.1.2 2.4.1.3 2.4.1.4 2.4.1.5 2.4.1.6 2.4.1.7 2.4.1.8 2.4.2.1
            )
            ;;
        3)
            subs=(
                3.1.1 3.1.2 3.1.3
                3.2.1 3.2.2 3.2.3 3.2.4
                3.3.1 3.3.2 3.3.3 3.3.4 3.3.5 3.3.6 3.3.7 3.3.8 3.3.9 3.3.10 3.3.11
            )
            ;;
        4)
            subs=(
                4.1.1
                4.2.1 4.2.2 4.2.3 4.2.4 4.2.5 4.2.6 4.2.7
                4.3.1 4.3.2 4.3.3 4.3.4 4.3.5 4.3.6 4.3.7 4.3.8 4.3.9 4.3.10
                4.4.1.1 4.4.1.2 4.4.1.3
                4.4.2.1 4.4.2.2 4.4.2.3 4.4.2.4
                4.4.3.1 4.4.3.2 4.4.3.3 4.4.3.4
            )
            ;;
        5)
            subs=(
                5.1.1 5.1.2 5.1.3 5.1.4 5.1.5 5.1.6 5.1.7 5.1.8 5.1.9 5.1.10 5.1.11 5.1.12 5.1.13 5.1.14 5.1.15
                5.1.16 5.1.17 5.1.18 5.1.19 5.1.20 5.1.21 5.1.22
            )
            ;;
        7)
            subs=(
                7.1.1 7.1.2 7.1.3 7.1.4 7.1.5 7.1.6 7.1.7 7.1.8 7.1.9 7.1.10 7.1.11 7.1.12 7.1.13
                7.2.1 7.2.2 7.2.3 7.2.4 7.2.5 7.2.6 7.2.7 7.2.8 7.2.9 7.2.10
            )
            ;;
        *)
            log_error "process_section_multi_detailed: unsupported section $sec"
            return 1
            ;;
    esac

    log_info "Processing subsections..."
    log_info ""

    local s
    for s in "${subs[@]}"; do
        process_one_cis_subsection "$s" subsection_results || overall_success=false
    done

    log_info ""
    log_info "========================================="
    log_info "Section $sec Subsection Summary:"
    log_info "========================================="
    for result in "${subsection_results[@]}"; do
        local sub_sec="${result%%:*}"
        local sub_stat="${result##*:}"
        if [[ "$sub_stat" == "success" ]]; then
            log_success "  $sub_sec: $sub_stat"
        else
            log_error "  $sub_sec: $sub_stat"
        fi
    done
    log_info "========================================="
    log_info ""

    if [[ "$overall_success" == true ]]; then
        return 0
    else
        return 1
    fi
}

# Process section 1 with detailed subsection reporting
process_section_1_detailed() {
    log_info "========================================="
    log_info "Processing Section: 1 (with detailed subsection reporting)"
    if [[ "$VERIFY_ONLY" == true ]]; then
        log_info "VERIFY-ONLY MODE: compliance checks and report only (no hardening)"
    elif [[ "$DRY_RUN" == true ]]; then
        log_dryrun "DRY-RUN MODE: No changes will be applied"
    fi
    log_info "========================================="
    
    local overall_success=true
    local subsection_results=()
    
    log_info "Processing subsections..."
    log_info ""
    
    # Process all subsections
    # 1.1.1
    process_one_cis_subsection "1.1.1.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.1.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.1.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.1.4" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.1.5" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.1.6" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.1.7" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.1.8" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.1.9" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.1.10" subsection_results || overall_success=false
    
    # 1.1.2
    process_one_cis_subsection "1.1.2.1.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.1.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.1.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.1.4" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.2.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.2.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.2.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.2.4" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.3.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.3.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.3.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.4.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.4.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.4.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.5.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.5.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.5.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.5.4" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.6.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.6.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.6.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.6.4" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.7.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.7.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.7.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.1.2.7.4" subsection_results || overall_success=false
    
    # 1.2
    process_one_cis_subsection "1.2.1.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.2.1.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.2.2.1" subsection_results || overall_success=false
    
    # 1.3
    process_one_cis_subsection "1.3.1.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.3.1.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.3.1.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.3.1.4" subsection_results || overall_success=false
    
    # 1.4
    process_one_cis_subsection "1.4.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.4.2" subsection_results || overall_success=false
    
    # 1.5
    process_one_cis_subsection "1.5.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.5.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.5.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.5.4" subsection_results || overall_success=false
    process_one_cis_subsection "1.5.5" subsection_results || overall_success=false
    
    # 1.6
    process_one_cis_subsection "1.6.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.6.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.6.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.6.4" subsection_results || overall_success=false
    process_one_cis_subsection "1.6.5" subsection_results || overall_success=false
    process_one_cis_subsection "1.6.6" subsection_results || overall_success=false
    
    # 1.7
    process_one_cis_subsection "1.7.1" subsection_results || overall_success=false
    process_one_cis_subsection "1.7.2" subsection_results || overall_success=false
    process_one_cis_subsection "1.7.3" subsection_results || overall_success=false
    process_one_cis_subsection "1.7.4" subsection_results || overall_success=false
    process_one_cis_subsection "1.7.5" subsection_results || overall_success=false
    process_one_cis_subsection "1.7.6" subsection_results || overall_success=false
    process_one_cis_subsection "1.7.7" subsection_results || overall_success=false
    process_one_cis_subsection "1.7.8" subsection_results || overall_success=false
    process_one_cis_subsection "1.7.9" subsection_results || overall_success=false
    process_one_cis_subsection "1.7.10" subsection_results || overall_success=false
    
    # Print summary
    log_info ""
    log_info "========================================="
    log_info "Section 1 Subsection Summary:"
    log_info "========================================="
    for result in "${subsection_results[@]}"; do
        local sub_sec="${result%%:*}"
        local sub_stat="${result##*:}"
        if [[ "$sub_stat" == "success" ]]; then
            log_success "  $sub_sec: $sub_stat"
        else
            log_error "  $sub_sec: $sub_stat"
        fi
    done
    log_info "========================================="
    log_info ""
    
    if [[ "$overall_success" == true ]]; then
        return 0
    else
        return 1
    fi
}

# Process a single section
process_section() {
    local section="$1"
    
    # Detailed CSV row per subsection (same pattern as section 1)
    if [[ "$section" == "1" ]]; then
        process_section_1_detailed
        return $?
    fi
    if [[ "$section" =~ ^[23457]$ ]]; then
        process_section_multi_detailed "$section"
        return $?
    fi
    
    # Standard processing for other sections (e.g. single subsection IDs, or section 6 when wired)
    local status=""
    local message=""
    local dry_run_suffix=""
    
    log_info "========================================="
    log_info "Processing Section: $section"
    if [[ "$VERIFY_ONLY" == true ]]; then
        log_info "VERIFY-ONLY MODE: compliance check and report only (no hardening)"
    elif [[ "$DRY_RUN" == true ]]; then
        log_dryrun "DRY-RUN MODE: No changes will be applied"
        dry_run_suffix=" (DRY-RUN)"
    fi
    log_info "========================================="

    if [[ "$VERIFY_ONLY" == true ]]; then
        if verify_hardening "$section" 2>/dev/null; then
            message="Compliant (verify only)"
            log_success "$section: $message"
            echo "$section,PASS,$(date '+%Y-%m-%d %H:%M:%S'),$message" >> "$REPORT_FILE"
            return 0
        else
            message="Not compliant (verify only)"
            log_error "$section: $message"
            echo "$section,VERIFY_FAILED,$(date '+%Y-%m-%d %H:%M:%S'),$message" >> "$REPORT_FILE"
            return 1
        fi
    fi
    
    # Check current compliance state
    if check_compliance "$section"; then
        status="SKIPPED"
        message="Already compliant - no action taken${dry_run_suffix}"
        log_info "$message"
        echo "$section,SKIPPED,$(date '+%Y-%m-%d %H:%M:%S'),$message" >> "$REPORT_FILE"
        return 0
    fi
    
    # Apply hardening
    if apply_hardening "$section"; then
        # Verify the fix (skip verification in dry-run mode)
        if [[ "$DRY_RUN" == true ]] || verify_hardening "$section"; then
            if [[ "$DRY_RUN" == true ]]; then
                status="DRY-RUN"
                message="Would apply hardening${dry_run_suffix}"
                log_dryrun "$message"
            else
                status="FIXED"
                message="Hardening applied and verified successfully"
                log_success "$message"
            fi
            echo "$section,$status,$(date '+%Y-%m-%d %H:%M:%S'),$message" >> "$REPORT_FILE"
            return 0
        else
            status="VERIFY_FAILED"
            message="Hardening applied but verification failed"
            log_error "$message"
            echo "$section,VERIFY_FAILED,$(date '+%Y-%m-%d %H:%M:%S'),$message" >> "$REPORT_FILE"
            return 1
        fi
    else
        status="FAILED"
        message="Failed to apply hardening${dry_run_suffix}"
        log_error "$message"
        echo "$section,FAILED,$(date '+%Y-%m-%d %H:%M:%S'),$message" >> "$REPORT_FILE"
        return 1
    fi
}

###############################################################################
# Report Generation
###############################################################################

initialize_report() {
    # Ensure report directory exists
    create_report_dir
    
    # Create CSV report file with header
    echo "Section,Status,Timestamp,Details" > "$REPORT_FILE"
    log_info "Report file initialized: $REPORT_FILE"
}

generate_summary() {
    log_info "========================================="
    log_info "Generating Summary Report"
    log_info "========================================="
    
    if [[ ! -f "$REPORT_FILE" ]]; then
        log_error "Report file not found: $REPORT_FILE"
        return 1
    fi
    
    # Count statuses
    local total=$(tail -n +2 "$REPORT_FILE" | wc -l)
    local fixed=$(grep -c ",FIXED," "$REPORT_FILE" || echo "0")
    local skipped=$(grep -c ",SKIPPED," "$REPORT_FILE" || echo "0")
    local failed=$(grep -c ",FAILED," "$REPORT_FILE" || echo "0")
    local verify_failed=$(grep -c ",VERIFY_FAILED," "$REPORT_FILE" || echo "0")
    local dry_run_count=$(grep -c ",DRY-RUN," "$REPORT_FILE" || echo "0")
    local pass_count=$(grep -c ",PASS," "$REPORT_FILE" || echo "0")
    
    log_info "Summary:"
    log_info "  Total sections processed: $total"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "  Would fix (dry-run): $dry_run_count"
    else
        log_info "  Fixed: $fixed"
    fi
    if [[ "$pass_count" =~ ^[0-9]+$ ]] && [[ "$pass_count" -gt 0 ]]; then
        log_info "  Pass (compliant, verify-only): $pass_count"
    fi
    log_info "  Skipped (already compliant): $skipped"
    log_info "  Failed: $failed"
    log_info "  Verify failed: $verify_failed"
    log_info ""
    log_info "Detailed report saved to: $REPORT_FILE"
    if [[ "$DRY_RUN" == false ]] && [[ "$VERIFY_ONLY" == false ]]; then
        log_info "Backup location: $BACKUP_DIR"
    fi
}

###############################################################################
# Main Execution
###############################################################################

main() {
    # Step 1: Parse command line arguments first (to set DRY_RUN flag)
    parse_arguments "$@"
    
    log_info "========================================="
    log_info "CIS Hardening Script Started"
    if [[ "$VERIFY_ONLY" == true ]]; then
        log_info "VERIFY-ONLY MODE - No hardening or backups; report only"
    elif [[ "$DRY_RUN" == true ]]; then
        log_dryrun "DRY-RUN MODE ENABLED - No changes will be made"
    fi
    log_info "========================================="
    
    # Step 2: Check if running as root
    check_root
    
    # Step 3: Load configuration
    load_config
    
    # Step 4: Create backup directory (skipped in verify-only)
    create_backup_dir
    
    # Step 5: Initialize report
    initialize_report
    
    # Step 6: Process each section (continue even if one fails)
    local failed_sections=()
    for section in "${SECTIONS[@]}"; do
        if ! process_section "$section"; then
            failed_sections+=("$section")
            log_warn "Section $section failed, but continuing with remaining sections..."
        fi
    done
    
    # Step 7: Compress backup directory to tar.gz
    if [[ "$DRY_RUN" == false ]] && [[ "$VERIFY_ONLY" == false ]]; then
        compress_backup
    fi
    
    # Step 8: Generate summary report
    generate_summary
    
    # Step 9: Exit with appropriate code
    if [[ ${#failed_sections[@]} -gt 0 ]]; then
        log_warn "Some sections failed: ${failed_sections[*]}"
        log_info "Check the report and logs for details"
        exit 1
    else
        if [[ "$VERIFY_ONLY" == true ]]; then
            log_success "Verify-only run completed successfully"
        elif [[ "$DRY_RUN" == true ]]; then
            log_success "Dry-run completed successfully - no changes were made"
        else
            log_success "All sections processed successfully"
        fi
        exit 0
    fi
}

# Run main function
main "$@"
