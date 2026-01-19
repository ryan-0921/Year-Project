#!/bin/bash

###############################################################################
# CIS Ubuntu Linux 24.04 LTS Benchmark Hardening Script
# 
# This script automatically applies CIS benchmark settings based on section
# arguments provided by the user.
#
# Usage: sudo bash cis_hardening.sh [--dry-run] [section_numbers]
# Example: sudo bash cis_hardening.sh 1,3,5
# Example: sudo bash cis_hardening.sh --dry-run 1,3,5
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
        if [[ "$DRY_RUN" == true ]]; then
            log_warn "Not running as root - some checks may fail in dry-run mode"
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
    --dry-run, -d    Run in dry-run mode (preview changes without applying)
    --help, -h       Show this help message

ARGUMENTS:
    section_numbers  Comma-separated list of CIS section numbers to process

EXAMPLES:
    sudo $0 1,3,5
    sudo $0 --dry-run 1,3,5
    sudo $0 -d 1,3,5

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

# Process section 1 with detailed subsection reporting
process_section_1_detailed() {
    local dry_run_suffix=""
    if [[ "$DRY_RUN" == true ]]; then
        dry_run_suffix=" (DRY-RUN)"
    fi
    
    log_info "========================================="
    log_info "Processing Section: 1 (with detailed subsection reporting)"
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "DRY-RUN MODE: No changes will be applied"
    fi
    log_info "========================================="
    
    local overall_success=true
    local subsection_results=()
    
    # Helper function to process a subsection
    process_subsection() {
        local sub_section="$1"
        local sub_status=""
        local sub_message=""
        
        # Check compliance
        if check_compliance "$sub_section" 2>/dev/null; then
            sub_status="success"
            sub_message="Already compliant"
            log_info "  $sub_section: $sub_status - $sub_message"
            echo "$sub_section,SKIPPED,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
            subsection_results+=("$sub_section:$sub_status")
            return 0
        fi
        
        # Apply hardening
        if apply_hardening "$sub_section" 2>/dev/null; then
            # Verify (skip in dry-run, skip manual sections, skip mount options if mount point not in fstab)
            local skip_verify=false
            # Skip verification for manual sections
            case "$sub_section" in
                1.1.1.10|1.1.2.1.1|1.1.2.2.1|1.1.2.3.1|1.1.2.4.1|1.1.2.5.1|1.1.2.6.1|1.1.2.7.1|1.2.1.1|1.2.1.2|1.2.2.1|1.4.1)
                    skip_verify=true
                    ;;
            esac
            
            # Skip verification for mount option sections if mount point doesn't exist in fstab
            if [[ "$skip_verify" == false ]]; then
                case "$sub_section" in
                    1.1.2.1.2|1.1.2.1.3|1.1.2.1.4)
                        if ! grep -q "^[^#].*[[:space:]]/tmp[[:space:]]" /etc/fstab 2>/dev/null; then
                            skip_verify=true
                        fi
                        ;;
                    1.1.2.2.2|1.1.2.2.3|1.1.2.2.4)
                        if ! grep -q "^[^#].*[[:space:]]/dev/shm[[:space:]]" /etc/fstab 2>/dev/null; then
                            skip_verify=true
                        fi
                        ;;
                    1.1.2.3.2|1.1.2.3.3)
                        if ! grep -q "^[^#].*[[:space:]]/home[[:space:]]" /etc/fstab 2>/dev/null; then
                            skip_verify=true
                        fi
                        ;;
                    1.1.2.4.2|1.1.2.4.3)
                        if ! grep -q "^[^#].*[[:space:]]/var[[:space:]]" /etc/fstab 2>/dev/null; then
                            skip_verify=true
                        fi
                        ;;
                    1.1.2.5.2|1.1.2.5.3|1.1.2.5.4)
                        if ! grep -q "^[^#].*[[:space:]]/var/tmp[[:space:]]" /etc/fstab 2>/dev/null; then
                            skip_verify=true
                        fi
                        ;;
                    1.1.2.6.2|1.1.2.6.3|1.1.2.6.4)
                        if ! grep -q "^[^#].*[[:space:]]/var/log[[:space:]]" /etc/fstab 2>/dev/null; then
                            skip_verify=true
                        fi
                        ;;
                    1.1.2.7.2|1.1.2.7.3|1.1.2.7.4)
                        if ! grep -q "^[^#].*[[:space:]]/var/log/audit[[:space:]]" /etc/fstab 2>/dev/null; then
                            skip_verify=true
                        fi
                        ;;
                esac
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
                subsection_results+=("$sub_section:$sub_status")
                return 0
            else
                sub_status="fail"
                sub_message="Verification failed"
                log_error "  $sub_section: $sub_status - $sub_message"
                echo "$sub_section,VERIFY_FAILED,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
                subsection_results+=("$sub_section:$sub_status")
                overall_success=false
                return 1
            fi
        else
            sub_status="fail"
            sub_message="Failed to apply hardening"
            log_error "  $sub_section: $sub_status - $sub_message"
            echo "$sub_section,FAILED,$(date '+%Y-%m-%d %H:%M:%S'),$sub_message" >> "$REPORT_FILE"
            subsection_results+=("$sub_section:$sub_status")
            overall_success=false
            return 1
        fi
    }
    
    log_info "Processing subsections..."
    log_info ""
    
    # Process all subsections
    # 1.1.1
    process_subsection "1.1.1.1"
    process_subsection "1.1.1.2"
    process_subsection "1.1.1.3"
    process_subsection "1.1.1.4"
    process_subsection "1.1.1.5"
    process_subsection "1.1.1.6"
    process_subsection "1.1.1.7"
    process_subsection "1.1.1.8"
    process_subsection "1.1.1.9"
    process_subsection "1.1.1.10"
    
    # 1.1.2
    process_subsection "1.1.2.1.1"
    process_subsection "1.1.2.1.2"
    process_subsection "1.1.2.1.3"
    process_subsection "1.1.2.1.4"
    process_subsection "1.1.2.2.1"
    process_subsection "1.1.2.2.2"
    process_subsection "1.1.2.2.3"
    process_subsection "1.1.2.2.4"
    process_subsection "1.1.2.3.1"
    process_subsection "1.1.2.3.2"
    process_subsection "1.1.2.3.3"
    process_subsection "1.1.2.4.1"
    process_subsection "1.1.2.4.2"
    process_subsection "1.1.2.4.3"
    process_subsection "1.1.2.5.1"
    process_subsection "1.1.2.5.2"
    process_subsection "1.1.2.5.3"
    process_subsection "1.1.2.5.4"
    process_subsection "1.1.2.6.1"
    process_subsection "1.1.2.6.2"
    process_subsection "1.1.2.6.3"
    process_subsection "1.1.2.6.4"
    process_subsection "1.1.2.7.1"
    process_subsection "1.1.2.7.2"
    process_subsection "1.1.2.7.3"
    process_subsection "1.1.2.7.4"
    
    # 1.2
    process_subsection "1.2.1.1"
    process_subsection "1.2.1.2"
    process_subsection "1.2.2.1"
    
    # 1.3
    process_subsection "1.3.1.1"
    process_subsection "1.3.1.2"
    process_subsection "1.3.1.3"
    process_subsection "1.3.1.4"
    
    # 1.4
    process_subsection "1.4.1"
    process_subsection "1.4.2"
    
    # 1.5
    process_subsection "1.5.1"
    process_subsection "1.5.2"
    process_subsection "1.5.3"
    process_subsection "1.5.4"
    process_subsection "1.5.5"
    
    # 1.6
    process_subsection "1.6.1"
    process_subsection "1.6.2"
    process_subsection "1.6.3"
    process_subsection "1.6.4"
    process_subsection "1.6.5"
    process_subsection "1.6.6"
    
    # 1.7
    process_subsection "1.7.1"
    process_subsection "1.7.2"
    process_subsection "1.7.3"
    process_subsection "1.7.4"
    process_subsection "1.7.5"
    process_subsection "1.7.6"
    process_subsection "1.7.7"
    process_subsection "1.7.8"
    process_subsection "1.7.9"
    process_subsection "1.7.10"
    
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
    
    # Special handling for section 1 - use detailed reporting
    if [[ "$section" == "1" ]]; then
        process_section_1_detailed
        return $?
    fi
    
    # Standard processing for other sections
    local status=""
    local message=""
    local dry_run_suffix=""
    
    log_info "========================================="
    log_info "Processing Section: $section"
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "DRY-RUN MODE: No changes will be applied"
        dry_run_suffix=" (DRY-RUN)"
    fi
    log_info "========================================="
    
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
    
    log_info "Summary:"
    log_info "  Total sections processed: $total"
    if [[ "$DRY_RUN" == true ]]; then
        log_info "  Would fix (dry-run): $dry_run_count"
    else
        log_info "  Fixed: $fixed"
    fi
    log_info "  Skipped (already compliant): $skipped"
    log_info "  Failed: $failed"
    log_info "  Verify failed: $verify_failed"
    log_info ""
    log_info "Detailed report saved to: $REPORT_FILE"
    if [[ "$DRY_RUN" == false ]]; then
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
    if [[ "$DRY_RUN" == true ]]; then
        log_dryrun "DRY-RUN MODE ENABLED - No changes will be made"
    fi
    log_info "========================================="
    
    # Step 2: Check if running as root
    check_root
    
    # Step 3: Load configuration
    load_config
    
    # Step 4: Create backup directory
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
    if [[ "$DRY_RUN" == false ]]; then
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
        if [[ "$DRY_RUN" == true ]]; then
            log_success "Dry-run completed successfully - no changes were made"
        else
            log_success "All sections processed successfully"
        fi
        exit 0
    fi
}

# Run main function
main "$@"
