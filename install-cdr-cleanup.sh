#!/bin/bash
set -o errexit -o nounset -o pipefail

# ============================================
# CONFIGURATION
# ============================================
SCRIPT_NAME="install-cdr-cleanup.sh"
VERSION="4.0"
AUTHOR="aca-error"

# Main script (harus ada di direktori yang sama)
MAIN_SCRIPT_NAME="cdr-cleanup"
MAIN_SCRIPT_SOURCE="./${MAIN_SCRIPT_NAME}.sh"
INSTALL_DIR="/usr/local/bin"
INSTALL_PATH="${INSTALL_DIR}/${MAIN_SCRIPT_NAME}"

# Paths untuk semua komponen
CONFIG_FILE="/etc/${MAIN_SCRIPT_NAME}.conf"
CONFIG_EXAMPLE="/etc/${MAIN_SCRIPT_NAME}.conf.example"
LOG_DIR="/var/log/${MAIN_SCRIPT_NAME}"
LOG_FILE="${LOG_DIR}/${MAIN_SCRIPT_NAME}.log"
LOCK_FILE="/var/lock/${MAIN_SCRIPT_NAME}.lock"
LOGROTATE_FILE="/etc/logrotate.d/${MAIN_SCRIPT_NAME}"
SYSTEMD_SERVICE="/etc/systemd/system/${MAIN_SCRIPT_NAME}.service"
SYSTEMD_TIMER="/etc/systemd/system/${MAIN_SCRIPT_NAME}.timer"
MAN_PAGE="/usr/share/man/man1/${MAIN_SCRIPT_NAME}.1.gz"
BACKUP_DIR="/home/backup/deleted_files"
DOC_DIR="/usr/local/share/doc/${MAIN_SCRIPT_NAME}"

# ============================================
# COLOR FUNCTIONS
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

print_header() {
    echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${WHITE} $1${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} Error: $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_info() {
    echo -e "${CYAN}➜${NC} $1"
}

print_step() {
    echo -e "${PURPLE}▶${NC} $1"
}

# ============================================
# VALIDATION FUNCTIONS
# ============================================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Script ini memerlukan hak akses root"
        echo -e "Gunakan: ${CYAN}sudo $0${NC}"
        exit 1
    fi
}

check_main_script() {
    if [[ ! -f "$MAIN_SCRIPT_SOURCE" ]]; then
        print_error "File script utama tidak ditemukan: $MAIN_SCRIPT_SOURCE"
        echo ""
        echo "Pastikan file berikut ada di direktori yang sama:"
        echo "  - cdr-cleanup.sh (script utama)"
        echo "  - $0 (installer ini)"
        echo ""
        exit 1
    fi
    
    # Validasi script syntax
    if ! bash -n "$MAIN_SCRIPT_SOURCE" 2>/dev/null; then
        print_error "Script utama memiliki syntax error"
        exit 1
    fi
}

check_system() {
    print_info "Checking system compatibility..."
    
    # Check OS
    if [[ -f /etc/redhat-release ]]; then
        local os_version
        os_version=$(grep -o '[0-9]' /etc/redhat-release | head -1)
        print_success "OS: RHEL/CentOS $(cat /etc/redhat-release)"
    else
        print_warning "OS: Non-RHEL system, compatibility not guaranteed"
    fi
    
    # Check required commands
    local required_cmds=("bash" "find" "rm" "df" "stat" "mkdir" "gzip")
    local missing=()
    
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        print_error "Missing required commands: ${missing[*]}"
        exit 1
    fi
    
    print_success "System check passed"
}

# ============================================
# INSTALLATION FUNCTIONS
# ============================================
install_main_script() {
    print_step "Installing main script..."
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
    fi
    
    # Backup existing script if any
    if [[ -f "$INSTALL_PATH" ]]; then
        mv "$INSTALL_PATH" "${INSTALL_PATH}.backup.$(date +%Y%m%d)"
        print_info "Backed up existing script to ${INSTALL_PATH}.backup.$(date +%Y%m%d)"
    fi
    
    # Install script
    cp "$MAIN_SCRIPT_SOURCE" "$INSTALL_PATH"
    chmod 755 "$INSTALL_PATH"
    
    if [[ -x "$INSTALL_PATH" ]]; then
        print_success "Main script installed: $INSTALL_PATH"
        
        # Test basic functionality
        if "$INSTALL_PATH" --help &>/dev/null; then
            print_success "Script test passed"
        else
            print_warning "Script help test failed (but installed)"
        fi
    else
        print_error "Failed to install main script"
        exit 1
    fi
}

create_config_file() {
    print_step "Creating configuration file..."
    
    cat > "$CONFIG_FILE" << 'EOF'
# ====================================================
# CDR CLEANUP CONFIGURATION FILE
# ====================================================
# This file is sourced by cdr-cleanup script
# Command line arguments override these values
# ====================================================

# [TARGET SETTINGS]
# Directory to clean up
DIRECTORY="/home/cdrsbx"

# [CLEANUP MODE SETTINGS]
# Mode 1: Disk Threshold (1-100%)
# Default mode when using --threshold
THRESHOLD=85

# Mode 2: Age Based (days)
# Used with --age-days or --age-months
FILE_AGE_DAYS=180

# [SAFETY LIMITS]
# Maximum files to delete per execution (1-10000)
MAX_DELETE_PER_RUN=100

# Minimum files to keep per directory (0-100000)
MIN_FILE_COUNT=30

# [BACKUP SETTINGS]
# Enable backup before deletion (0=no, 1=yes)
BACKUP_ENABLED=0

# Directory for backups
BACKUP_DIR="/home/backup/deleted_files"

# [LOGGING SETTINGS]
# Enable automatic log rotation (0=no, 1=yes)
AUTO_ROTATE_LOG=1

# Maximum log file size in MB before rotation
MAX_LOG_SIZE_MB=50

# [DEBUG SETTINGS]
# Enable debug mode (0=no, 1=yes)
DEBUG_MODE=0

# [EXCLUDE PATTERNS]
# Additional exclude patterns (bash array format)
# USER_EXCLUDE_PATTERNS=("*.log" "*.tmp" "temp_*")

# ====================================================
# NOTES:
# 1. Command line arguments have highest priority
# 2. THRESHOLD and AGE modes are mutually exclusive
# 3. Set proper permissions on directories
# ====================================================
EOF
    
    chmod 644 "$CONFIG_FILE"
    print_success "Config file created: $CONFIG_FILE"
    
    # Create example config
    cp "$CONFIG_FILE" "$CONFIG_EXAMPLE"
    print_success "Example config created: $CONFIG_EXAMPLE"
}

setup_logging() {
    print_step "Setting up logging system..."
    
    # Create log directory
    mkdir -p "$LOG_DIR"
    
    # Create log file
    touch "$LOG_FILE"
    
    # Set permissions
    chmod 755 "$LOG_DIR"
    chmod 644 "$LOG_FILE"
    chown root:root "$LOG_DIR" "$LOG_FILE"
    
    print_success "Log directory: $LOG_DIR"
    print_success "Log file: $LOG_FILE"
}

create_logrotate_config() {
    print_step "Creating logrotate configuration..."
    
    cat > "$LOGROTATE_FILE" << 'EOF'
# Log rotation for CDR Cleanup Utility
/var/log/cdr-cleanup/cdr-cleanup.log {
    missingok               # Don't error if log file is missing
    notifempty             # Don't rotate empty logs
    compress               # Compress rotated logs
    delaycompress          # Delay compression until next rotation
    maxsize 50M            # Rotate when log reaches 50MB
    rotate 12              # Keep 12 rotated logs
    weekly                 # Rotate weekly
    create 0644 root root  # Create new log with these permissions
    
    # Optional post-rotate commands
    postrotate
        # Reload syslog if needed
        # /bin/systemctl reload rsyslog.service > /dev/null 2>&1 || true
    endscript
}
EOF
    
    chmod 644 "$LOGROTATE_FILE"
    print_success "Logrotate config: $LOGROTATE_FILE"
}

create_systemd_service() {
    print_step "Creating systemd service..."
    
    # Service file
    cat > "$SYSTEMD_SERVICE" << 'EOF'
[Unit]
Description=CDR Cleanup Utility
Documentation=man:cdr-cleanup(1)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
Group=root

# Environment variables
Environment="INVOCATION_ID=%i"

# Main command
ExecStart=/usr/local/bin/cdr-cleanup --force --threshold=85 --quiet

# Post-execution logging
ExecStartPost=/bin/sh -c 'echo "[SYSTEMD] CDR Cleanup completed at $(date)" >> /var/log/cdr-cleanup/service.log'

# Safety limits
MemoryLimit=512M
CPUQuota=50%
Restart=no

# Security settings
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/var/log/cdr-cleanup /var/lock

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cdr-cleanup

[Install]
WantedBy=multi-user.target
EOF
    
    # Timer file for scheduled execution
    cat > "$SYSTEMD_TIMER" << 'EOF'
[Unit]
Description=Daily CDR Cleanup Timer
Documentation=man:cdr-cleanup(1)
Requires=cdr-cleanup.service

[Timer]
# Run daily at 2:30 AM
OnCalendar=*-*-* 02:30:00
Persistent=true
RandomizedDelaySec=300

# Accuracy settings
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
    
    chmod 644 "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER"
    
    # Reload systemd
    systemctl daemon-reload
    
    print_success "Systemd service: $SYSTEMD_SERVICE"
    print_success "Systemd timer: $SYSTEMD_TIMER"
}

create_man_page() {
    print_step "Creating comprehensive man page..."
    
    # Create temporary man page file
    TEMP_MAN="/tmp/${MAIN_SCRIPT_NAME}.1"
    
    cat > "$TEMP_MAN" << 'MANPAGE_CONTENT'
.TH CDR\-CLEANUP 1 "2026-01-01" "Version 4.0" "System Administration Utilities"
.SH NAME
cdr\-cleanup \- Cleanup utility for old files based on disk usage threshold or file age
.SH SYNOPSIS
.B cdr\-cleanup
[\fIOPTIONS\fR]...
.SH DESCRIPTION
.B cdr\-cleanup
is a comprehensive bash utility for automatically cleaning up old files from specified directories. It operates in two mutually exclusive modes:
.PP
1. \fBDisk Threshold Mode\fR: Deletes the oldest files until disk usage falls below a specified percentage threshold.
.PP
2. \fBAge\-Based Mode\fR: Deletes all files older than a specified number of days or months.
.PP
The utility includes extensive safety features, logging, and configuration options making it suitable for production environments on RHEL 9 systems.
.SH MODES OF OPERATION (MUTUALLY EXCLUSIVE)
.TP
\fB\-\-threshold=\fIN\fR
Set disk usage threshold percentage (1\-100). Activates Disk Threshold Mode.
.br
\fBExample:\fR \-\-threshold=85 (clean until disk usage < 85%)
.TP
\fB\-\-age\-days=\fIN\fR
Delete files older than N days. Activates Age\-Based Mode.
.br
\fBExample:\fR \-\-age\-days=180 (delete files > 180 days old)
.TP
\fB\-\-age\-months=\fIN\fR
Delete files older than N months. Activates Age\-Based Mode.
.br
\fBExample:\fR \-\-age\-months=6 (delete files > 6 months old)
.PP
\fB⚠ WARNING:\fR These modes cannot be used together. Choose only one.
.SH EXECUTION OPTIONS
.TP
\fB\-\-dry\-run\fR
Simulation mode only. No files are actually deleted (DEFAULT).
.br
Shows what would be deleted without taking action.
.TP
\fB\-\-force\fR
Perform actual deletion. Required for real cleanup operations.
.SH DIRECTORY AND FILTERING OPTIONS
.TP
\fB\-\-directory=\fIPATH\fR
Target directory to clean. Default: \fI/home/cdrsbx\fR.
.TP
\fB\-\-exclude=\fIPATTERN\fR
Add exclusion pattern for files/directories.
.br
Can be used multiple times.
.br
\fBExample:\fR \-\-exclude="*.log" \-\-exclude="temp_*"
.TP
\fB\-\-include\-hidden\fR
Include hidden files and directories (those starting with dot).
.br
Default: Hidden files are excluded.
.SH SAFETY LIMIT OPTIONS
.TP
\fB\-\-max\-delete=\fIN\fR
Maximum number of files to delete in one execution (1\-10000).
.br
Default: 100. Prevents excessive deletion.
.TP
\fB\-\-min\-files=\fIN\fR
Minimum number of files to keep in each directory (0\-100000).
.br
Default: 30. Maintains directory structure integrity.
.SH BACKUP OPTIONS
.TP
\fB\-\-backup\fR
Enable backup before deletion. Files are copied to BACKUP_DIR.
.TP
\fB\-\-no\-backup\fR
Disable backup (DEFAULT).
.SH LOGGING AND DEBUG OPTIONS
.TP
\fB\-\-debug\fR
Enable debug mode for detailed output.
.TP
\fB\-\-quiet\fR
Suppress terminal output. Logs only to file.
.TP
\fB\-\-no\-log\-rotate\fR
Disable automatic log rotation.
.SH CONFIGURATION OPTIONS
.TP
\fB\-\-config=\fIFILE\fR
Use alternative configuration file.
.br
Default: \fI/etc/cdr\-cleanup.conf\fR
.TP
\fB\-h, \-\-help\fR
Display help message and exit.
.SH CONFIGURATION FILE
The utility reads default configuration from \fI/etc/cdr\-cleanup.conf\fR if it exists. The file uses simple shell variable assignment syntax:
.PP
.nf
# Example configuration
DIRECTORY="/home/cdrsbx"
THRESHOLD=85
MAX_DELETE_PER_RUN=100
MIN_FILE_COUNT=30
BACKUP_ENABLED=0
BACKUP_DIR="/home/backup/deleted_files"
AUTO_ROTATE_LOG=1
MAX_LOG_SIZE_MB=50
DEBUG_MODE=0
FILE_AGE_DAYS=180
.fi
.PP
\fBPriority Order:\fR
.IP 1. 4
Command line arguments
.IP 2. 4
Configuration file values
.IP 3. 4
Built\-in defaults
.SH ENVIRONMENT
.TP
.B INVOCATION_ID
If set (typically by systemd), logs are also written to systemd journal.
.SH FILES
.TP
.B /usr/local/bin/cdr\-cleanup
Main executable script.
.TP
.B /etc/cdr\-cleanup.conf
Main configuration file.
.TP
.B /etc/cdr\-cleanup.conf.example
Example configuration file.
.TP
.B /var/log/cdr\-cleanup/cdr\-cleanup.log
Main log file with timestamped entries.
.TP
.B /var/lock/cdr\-cleanup.lock
Lock file preventing concurrent execution.
.TP
.B /etc/logrotate.d/cdr\-cleanup
Automatic log rotation configuration.
.TP
.B /etc/systemd/system/cdr\-cleanup.service
Systemd service unit file.
.TP
.B /etc/systemd/system/cdr\-cleanup.timer
Systemd timer for scheduled execution.
.TP
.B /home/backup/deleted_files
Default backup directory.
.TP
.B /tmp/cdr\-cleanup.*.tmp
Temporary files created during execution.
.SH EXAMPLES
.SS "Basic Disk Threshold Cleanup"
.nf
# Clean until disk usage < 80%
$ cdr\-cleanup \-\-force \-\-threshold=80
.fi
.SS "Age\-Based Cleanup with Safety Limits"
.nf
# Delete files > 90 days old, max 200 files
$ cdr\-cleanup \-\-force \-\-age\-days=90 \e
    \-\-max\-delete=200 \-\-min\-files=10
.fi
.SS "Dry Run for Testing"
.nf
# Test what would be deleted
$ cdr\-cleanup \-\-threshold=85 \-\-dry\-run \-\-debug
.fi
.SS "Custom Directory with Exclusions"
.nf
# Clean custom directory, exclude logs and temp files
$ cdr\-cleanup \-\-force \-\-threshold=75 \e
    \-\-directory="/data/cdrs" \e
    \-\-exclude="*.log" \-\-exclude="*.tmp"
.fi
.SS "Comprehensive Example"
.nf
$ cdr\-cleanup \-\-force \-\-threshold=80 \e
    \-\-max\-delete=500 \-\-min\-files=20 \e
    \-\-backup \-\-debug \-\-exclude="*.log"
.fi
.SS "Invalid Usage (Will Error)"
.nf
$ cdr\-cleanup \-\-threshold=85 \-\-age\-days=180
ERROR: Modes cannot be used together
.fi
.SH EXIT STATUS
.TP
.B 0
Success
.TP
.B 1
General error (invalid arguments, permission issues, etc.)
.TP
.B 130
Script interrupted by user (SIGINT)
.SH SAFETY FEATURES
.IP \(bu 3
\fBIterative disk checking\fR for threshold mode
.IP \(bu 3
\fBFile age caching\fR for improved performance
.IP \(bu 3
\fBSafety limits\fR (max delete per run, min files per directory)
.IP \(bu 3
\fBAutomatic log rotation\fR (50MB maximum size)
.IP \(bu 3
\fBLock file mechanism\fR prevents multiple concurrent executions
.IP \(bu 3
\fBDry\-run mode default\fR for safe testing
.IP \(bu 3
\fBExclude patterns\fR for system files and directories
.IP \(bu 3
\fBBackup option\fR before file deletion
.IP \(bu 3
\fBConfiguration file support\fR for persistent settings
.SH LOGGING FORMAT
Log entries follow this format:
.PP
.nf
[YYYY\-MM\-DD HH:MM:SS.MMM] [LEVEL] Message
.fi
.PP
Available log levels: SUCCESS, ERROR, WARNING, INFO, DRY_RUN, DEBUG, HEADER
.SH SCHEDULING
.SS "Using Systemd Timer (Recommended)"
.nf
# Enable and start the timer
$ sudo systemctl enable cdr\-cleanup.timer
$ sudo systemctl start cdr\-cleanup.timer

# Check timer status
$ systemctl list\-timers cdr\-cleanup.timer

# View service logs
$ journalctl \-u cdr\-cleanup.service
.fi
.SS "Using Cron"
.nf
# Add to crontab (runs daily at 2:30 AM)
30 2 * * * /usr/local/bin/cdr\-cleanup \e
    \-\-force \-\-threshold=85 \-\-quiet
.fi
.SS "Different Schedule Examples"
.nf
# Weekly cleanup (Sunday at 3 AM)
0 3 * * 0 /usr/local/bin/cdr\-cleanup \e
    \-\-force \-\-age\-days=90 \-\-quiet

# Monthly cleanup (1st of month at 4 AM)
0 4 1 * * /usr/local/bin/cdr\-cleanup \e
    \-\-force \-\-threshold=80 \-\-backup \-\-quiet
.fi
.SH TROUBLESHOOTING
.TP
.B "Permission denied"
Ensure the user has appropriate permissions on the target directory and log directory.
.TP
.B "Lock file exists"
Remove \fI/var/lock/cdr\-cleanup.lock\fR if previous execution was interrupted.
.TP
.B "Configuration file errors"
Check syntax of \fI/etc/cdr\-cleanup.conf\fR. Use bash \-n to validate.
.TP
.B "Script not found"
Verify installation: \fBls \-la /usr/local/bin/cdr\-cleanup\fR
.TP
.B "Debug information"
Use \fB\-\-debug\fR flag for detailed execution information.
.TP
.B "Check logs"
Examine \fI/var/log/cdr\-cleanup/cdr\-cleanup.log\fR for error messages.
.SH PERFORMANCE TIPS
.IP \(bu 3
Use \fB\-\-max\-delete\fR to limit impact on busy systems
.IP \(bu 3
Schedule during off\-peak hours
.IP \(bu 3
Use \fB\-\-dry\-run\fR first to estimate impact
.IP \(bu 3
Consider backup requirements with \fB\-\-backup\fR
.IP \(bu 3
Adjust \fBMIN_FILE_COUNT\fR based on directory structure
.SH COMPATIBILITY
Designed for RHEL 9 and compatible systems. Requires standard GNU utilities.
.SH AUTHOR
CDR Management Team
.SH BUGS
Report bugs through appropriate support channels. Include log files and configuration details.
.SH SEE ALSO
.BR find (1),
.BR rm (1),
.BR df (1),
.BR stat (1),
.BR logrotate (8),
.BR systemctl (1),
.BR crontab (5),
.BR bash (1)
MANPAGE_CONTENT
    
    # Compress and install man page
    mkdir -p "$(dirname "$MAN_PAGE")"
    gzip -c "$TEMP_MAN" > "$MAN_PAGE"
    chmod 644 "$MAN_PAGE"
    
    # Update man database
    if command -v mandb &>/dev/null; then
        mandb >/dev/null 2>&1
        print_success "Man database updated"
    fi
    
    print_success "Man page installed: $MAN_PAGE"
}

create_backup_dir() {
    print_info "Membuat backup directory..."
    
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    
    print_success "Backup directory: $BACKUP_DIR"
}

create_readme() {
    print_info "Membuat dokumentasi..."
    
    README_DIR="/usr/local/share/doc/cdr-cleanup"
    mkdir -p "$README_DIR"
    
    cat > "${README_DIR}/README" << 'README'
CDR CLEANUP UTILITY
===================

Quick Start:
- Test: cdr-cleanup --help
- Dry run: cdr-cleanup --threshold=85 --dry-run
- Actual: cdr-cleanup --force --threshold=80

Files:
- Config: /etc/cdr-cleanup.conf
- Logs: /var/log/cdr-cleanup/
- Man page: man cdr-cleanup

Scheduling:
systemctl enable cdr-cleanup.timer
systemctl start cdr-cleanup.timer
README
    
    print_success "README: ${README_DIR}/README"
}

verify_installation() {
    print_info "Memverifikasi instalasi..."
    
    local checks=0
    local passed=0
    
    check_file() {
        ((checks++))
        if [[ -e "$1" ]]; then
            print_success "$2"
            ((passed++))
        else
            print_error "$2 tidak ditemukan"
        fi
    }
    
    check_file "$INSTALL_PATH" "Main script"
    check_file "$CONFIG_FILE" "Config file"
    check_file "$LOG_DIR" "Log directory"
    check_file "$LOGROTATE_FILE" "Logrotate config"
    check_file "$SERVICE_FILE" "Systemd service"
    check_file "$TIMER_FILE" "Systemd timer"
    check_file "${MAN_PATH}.gz" "Man page"
    
    echo ""
    if [[ $passed -eq $checks ]]; then
        print_success "Semua komponen terinstal dengan sukses!"
        return 0
    else
        print_warning "$passed dari $checks komponen terinstal"
        return 1
    fi
}

show_summary() {
    print_header "INSTALASI SELESAI"
    
    echo -e "${WHITE}Komponen yang diinstal:${NC}"
    echo "  • Script:      $INSTALL_PATH"
    echo "  • Config:      $CONFIG_FILE"
    echo "  • Logs:        $LOG_DIR"
    echo "  • Logrotate:   $LOGROTATE_FILE"
    echo "  • Systemd:     $SERVICE_FILE"
    echo "  • Timer:       $TIMER_FILE"
    echo "  • Man page:    man cdr-cleanup"
    echo "  • Backup dir:  $BACKUP_DIR"
    echo ""
    
    echo -e "${CYAN}Penggunaan:${NC}"
    echo "  cdr-cleanup --help"
    echo "  cdr-cleanup --threshold=85 --dry-run"
    echo "  cdr-cleanup --force --threshold=80"
    echo ""
    
    echo -e "${YELLOW}Untuk auto-cleanup harian:${NC}"
    echo "  systemctl enable cdr-cleanup.timer"
    echo "  systemctl start cdr-cleanup.timer"
    echo ""
    
    echo -e "${GREEN}✅ Instalasi berhasil!${NC}"
}

uninstall() {
    print_header "UNINSTALL CDR CLEANUP"
    
    read -p "Yakin ingin uninstall? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Dibatalkan"
        exit 0
    fi
    
    print_info "Menghapus komponen..."
    
    # Remove files
    rm -f "$INSTALL_PATH"
    rm -f "$CONFIG_FILE"
    rm -f "$LOGROTATE_FILE"
    rm -f "$SERVICE_FILE"
    rm -f "$TIMER_FILE"
    rm -f "${MAN_PATH}.gz"
    
    # Keep logs and backup for safety
    print_info "Logs disimpan di: $LOG_DIR"
    print_info "Backup directory disimpan: $BACKUP_DIR"
    
    # Reload systemd if service files existed
    if [[ -f "$SERVICE_FILE.bak" ]] || [[ -f "$TIMER_FILE.bak" ]]; then
        systemctl daemon-reload 2>/dev/null || true
    fi
    
    print_success "Uninstall selesai"
}

# ============================================
# MAIN INSTALLATION
# ============================================
install_all() {
    print_header "CDR CLEANUP COMPLETE INSTALLER"
    
    # Checks
    check_root
    check_main_script
    
    # Installation steps
    install_main_script
    create_config_file
    setup_logging
    create_logrotate_config
    create_systemd_service
    create_man_page
    create_backup_dir
    create_readme
    
    # Verify
    verify_installation
    
    # Summary
    show_summary
}

# ============================================
# MAIN SCRIPT
# ============================================
main() {
    case "${1:-}" in
        "--install"|"-i")
            install_all
            ;;
        "--uninstall"|"-u")
            uninstall
            ;;
        "--help"|"-h")
            echo "Usage: $0 [OPTION]"
            echo "Options:"
            echo "  --install, -i    Install CDR Cleanup"
            echo "  --uninstall, -u  Uninstall CDR Cleanup"
            echo "  --help, -h       Show this help"
            echo ""
            echo "Example: sudo $0 --install"
            ;;
        *)
            echo "CDR Cleanup Installer"
            echo "Usage: sudo $0 --install"
            echo "       sudo $0 --uninstall"
            ;;
    esac
}

# Run main
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
