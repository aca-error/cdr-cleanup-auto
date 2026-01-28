#!/bin/bash
# CDR Cleanup Utility Installation Script
# ========================================
# Install script untuk cdr-cleanup utility di RHEL 9

set -o nounset -o pipefail -o errexit

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        print_error "Script ini harus dijalankan sebagai root"
        echo "Gunakan: sudo $0"
        exit 1
    fi
}

check_rhel9() {
    if [[ -f /etc/redhat-release ]]; then
        local rhel_version
        rhel_version=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release 2>/dev/null || echo "0")
        local major_version=${rhel_version%%.*}
        
        if [[ "$major_version" -lt 9 ]]; then
            print_warning "Script dioptimasi untuk RHEL 9, versi terdeteksi: $rhel_version"
            read -p "Lanjutkan installasi? (y/N): " -n 1 -r
            echo
            [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
        fi
    else
        print_warning "Sistem operasi bukan RHEL/CentOS. Lanjutkan dengan hati-hati."
        read -p "Lanjutkan installasi? (y/N): " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
}

check_dependencies() {
    print_info "Checking dependencies..."
    
    local missing_deps=()
    local required_tools=("bash" "find" "sort" "stat" "df" "awk" "mkdir" "rm" "cp" "gzip")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_deps+=("$tool")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        print_error "Dependencies missing: ${missing_deps[*]}"
        echo "Install dengan: dnf install ${missing_deps[*]}"
        exit 1
    fi
    
    print_success "All dependencies satisfied"
}

create_directories() {
    print_info "Creating necessary directories..."
    
    local directories=(
        "/var/log/cdr-cleanup"
        "/home/cdrsbx"
        "/home/backup/deleted_files"
        "/usr/local/bin"
        "/usr/local/share/man/man1"
        "/etc"
    )
    
    for dir in "${directories[@]}"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            print_info "Created directory: $dir"
        fi
    done
    
    # Set permissions
    chmod 755 /var/log/cdr-cleanup
    chmod 755 /home/cdrsbx
    chmod 700 /home/backup/deleted_files
    chmod 755 /usr/local/share/man/man1
    
    print_success "Directories created and permissions set"
}

install_main_script() {
    print_info "Installing main script..."
    
    local script_source="cdr-cleanup.sh"
    
    if [[ ! -f "$script_source" ]]; then
        print_error "Main script not found: $script_source"
        print_error "Pastikan file cdr-cleanup.sh berada di directory yang sama"
        exit 1
    fi
    
    # Copy script
    cp "$script_source" /usr/local/bin/cdr-cleanup
    chmod 755 /usr/local/bin/cdr-cleanup
    chown root:root /usr/local/bin/cdr-cleanup
    
    # Verify installation
    if [[ -x /usr/local/bin/cdr-cleanup ]]; then
        print_success "Main script installed: /usr/local/bin/cdr-cleanup"
    else
        print_error "Failed to install main script"
        exit 1
    fi
}

install_config_file() {
    print_info "Installing config file..."
    
    cat > /etc/cdr-cleanup.conf << 'EOF'
#!/bin/bash
# CDR Cleanup Configuration File
# ==============================
# Semua variabel di sini akan di-load oleh cdr-cleanup.sh

# Direktori target untuk cleanup
DIRECTORY="/home/cdrsbx"

# Threshold disk usage (1-100%)
THRESHOLD=85

# Minimum file count per directory
MIN_FILE_COUNT=30

# Maximum files to delete per run
MAX_DELETE_PER_RUN=100

# Backup enabled (0=disabled, 1=enabled)
BACKUP_ENABLED=0

# Backup directory
BACKUP_DIR="/home/backup/deleted_files"

# Log file max size in MB (for auto rotation)
MAX_LOG_SIZE_MB=50

# Enable auto log rotation (0=disabled, 1=enabled)
AUTO_ROTATE_LOG=1
EOF
    
    chmod 600 /etc/cdr-cleanup.conf
    chown root:root /etc/cdr-cleanup.conf
    
    if [[ -f /etc/cdr-cleanup.conf ]]; then
        print_success "Config file installed: /etc/cdr-cleanup.conf"
    else
        print_error "Failed to install config file"
        exit 1
    fi
}

install_man_page() {
    print_info "Installing man page..."
    
    local man_page_content=$(cat << 'MAN_PAGE_EOF'
.TH CDR\-CLEANUP 1 "January 2024" "CDR Cleanup Utility v1.0"
.SH NAME
cdr\-cleanup \- Disk cleanup utility for RHEL 9
.SH SYNOPSIS
.B cdr\-cleanup
[\fIOPTIONS\fR]
.SH DESCRIPTION
.B cdr\-cleanup
is a bash script utility designed specifically for Red Hat Enterprise Linux 9
that helps manage disk usage by automatically removing old files based on disk
threshold or file age, with comprehensive safety features and logging.
.PP
The utility operates in two main modes:
.IP \(bu 3
\fBDisk Threshold Mode\fR: Removes oldest files when disk usage exceeds a
configurable threshold percentage.
.IP \(bu 3
\fBAge\-Based Mode\fR: Removes files older than a specified number of days or
months, regardless of current disk usage.
.PP
The script includes multiple safety mechanisms such as minimum file count
protection per directory, exclusion of hidden files and system directories,
SELinux context preservation, and comprehensive logging with automatic
rotation.
.SH OPTIONS
.TP
.B \-\-dry\-run
Simulation mode only, no files will be deleted (Default).
.TP
.B \-\-force
Execute actual file deletion (overrides dry\-run).
.TP
.B \-\-threshold=\fIN\fR
Set disk usage threshold percentage (1\-100). Default: 85.
Only applies to Disk Threshold mode.
.TP
.B \-\-age\-days=\fIN\fR
Delete files older than N days. Activates Age\-Based mode.
.TP
.B \-\-age\-months=\fIN\fR
Delete files older than N months. Activates Age\-Based mode.
.TP
.B \-\-directory=\fIPATH\fR
Target directory for cleanup. Default: /home/cdrsbx.
.TP
.B \-\-min\-files=\fIN\fR
Minimum number of files to keep per directory. Default: 30.
.TP
.B \-\-max\-delete=\fIN\fR
Maximum number of files to delete per execution. Default: 100.
.TP
.B \-\-exclude=\fIPATTERN\fR
Additional exclusion pattern (can be used multiple times).
.TP
.B \-\-include\-hidden
Include hidden files/directories (NOT RECOMMENDED).
.TP
.B \-\-backup
Enable backup before deletion.
.TP
.B \-\-no\-backup
Disable backup (overrides config).
.TP
.B \-\-debug
Show debug messages to terminal.
.TP
.B \-\-quiet
Suppress all terminal output (still logs to file).
.TP
.B \-\-config=\fIFILE\fR
Use alternative config file.
.TP
.B \-\-no\-log\-rotate
Disable auto log rotation for this run.
.TP
.B \-\-help
Display this help message.
.SH CONFIGURATION
The main configuration file is
.I /etc/cdr\-cleanup.conf
which is sourced by the script. This file contains default values for:
.IP \(bu 3
DIRECTORY: Target directory
.IP \(bu 3
THRESHOLD: Disk usage percentage threshold
.IP \(bu 3
MIN_FILE_COUNT: Minimum files per directory
.IP \(bu 3
MAX_DELETE_PER_RUN: Maximum deletions per execution
.IP \(bu 3
BACKUP_ENABLED: Backup toggle (0/1)
.IP \(bu 3
BACKUP_DIR: Backup location
.IP \(bu 3
MAX_LOG_SIZE_MB: Log file size limit for auto rotation
.IP \(bu 3
AUTO_ROTATE_LOG: Auto rotation toggle (0/1)
.PP
Command line arguments override config file values.
.SH EXCLUSION PATTERNS
By default, the script excludes:
.IP \(bu 3
All hidden files and directories (starting with .)
.IP \(bu 3
Default user directories: Desktop, Documents, Downloads, Pictures, Music, Videos
.IP \(bu 3
Configuration directories: .config, .local, .cache, .ssh, .gnupg
.IP \(bu 3
Version control directories: .git, .svn, .hg
.IP \(bu 3
Application data: .mozilla, .thunderbird, .vscode
.IP \(bu 3
Shell files: .bash*, .profile, .zsh*
.IP \(bu 3
System directories: /, /bin, /sbin, /usr, /etc, /boot, /var
.SH LOGGING
The script maintains comprehensive logs at
.I /var/log/cdr\-cleanup/cdr\-cleanup.log
with the following features:
.IP \(bu 3
Automatic rotation when log reaches 50MB or monthly
.IP \(bu 3
Start and end timestamps with duration
.IP \(bu 3
Process summary and statistics
.IP \(bu 3
Journald integration when run under systemd
.IP \(bu 3
Logrotate configuration at /etc/logrotate.d/cdr\-cleanup
.SH FILES
.TP
.I /usr/local/bin/cdr\-cleanup
Main executable script.
.TP
.I /etc/cdr\-cleanup.conf
Main configuration file.
.TP
.I /var/log/cdr\-cleanup/cdr\-cleanup.log
Main log file.
.TP
.I /var/lock/cdr\-cleanup.lock
Lock file to prevent multiple executions.
.TP
.I /etc/logrotate.d/cdr\-cleanup
Log rotation configuration.
.TP
.I /etc/systemd/system/cdr\-cleanup.service
Systemd service unit file.
.TP
.I /etc/systemd/system/cdr\-cleanup.timer
Systemd timer unit file.
.TP
.I /etc/cron.d/cdr\-cleanup
Cron job configuration.
.SH EXAMPLES
Delete files when disk usage exceeds 85% (dry run):
.RS
.PP
.nf
.B cdr\-cleanup \-\-dry\-run \-\-threshold=85
.fi
.RE
.PP
Force deletion of files older than 180 days:
.RS
.PP
.nf
.B cdr\-cleanup \-\-force \-\-age\-days=180
.fi
.RE
.PP
Cleanup with custom directory and debug output:
.RS
.PP
.nf
.B cdr\-cleanup \-\-force \-\-directory=/var/log \-\-threshold=80 \-\-debug
.fi
.RE
.PP
Schedule daily cleanup via systemd:
.RS
.PP
.nf
.B systemctl enable \-\-now cdr\-cleanup.timer
.fi
.RE
.SH SAFETY FEATURES
.IP \(bu 3
Dry\-run mode is default
.IP \(bu 3
Minimum file count protection per directory
.IP \(bu 3
Exclusion of system and hidden files
.IP \(bu 3
Lock file to prevent concurrent execution
.IP \(bu 3
Comprehensive error handling and logging
.IP \(bu 3
User confirmation for security\-sensitive directories
.IP \(bu 3
SELinux context preservation for backups
.SH EXIT STATUS
.IP 0
Success
.IP 1
General error
.IP 2
Invalid arguments
.IP 3
Permission denied
.IP 4
Invalid directory
.IP 5
Already running (lock file exists)
.SH SEE ALSO
.BR logrotate (8),
.BR crontab (5),
.BR systemd.timer (5),
.BR find (1),
.BR df (1)
.SH BUGS
Report bugs to your system administrator or create an issue at the
project repository if available.
.SH AUTHOR
System Administration Team
.SH COPYRIGHT
Copyright © 2024 System Administration Team.
This is free software; see the source for copying conditions.
There is NO warranty; not even for MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE.
MAN_PAGE_EOF
)
    
    # Create man page
    echo "$man_page_content" > /usr/local/share/man/man1/cdr-cleanup.1
    
    # Compress man page
    gzip -f /usr/local/share/man/man1/cdr-cleanup.1
    
    # Update man database
    mandb 2>/dev/null || true
    
    if [[ -f /usr/local/share/man/man1/cdr-cleanup.1.gz ]]; then
        print_success "Man page installed: /usr/local/share/man/man1/cdr-cleanup.1.gz"
    else
        print_error "Failed to install man page"
        exit 1
    fi
}

install_logrotate_config() {
    print_info "Installing logrotate configuration..."
    
    cat > /etc/logrotate.d/cdr-cleanup << 'EOF'
/var/log/cdr-cleanup/cdr-cleanup.log {
    monthly                    # Rotate monthly
    rotate 12                  # Keep 12 months of logs
    size 50M                   # Rotate if file exceeds 50MB
    compress                   # Compress rotated logs
    delaycompress              # Delay compression until next rotation
    missingok                  # Don't error if log is missing
    notifempty                 # Don't rotate empty logs
    create 640 root root       # Set permissions on new log file
    dateext                    # Add date extension to rotated logs
    dateformat -%Y%m%d        # Format: cdr-cleanup.log-20240127
    sharedscripts              # Run postrotate script once for all logs
    postrotate
        echo "[$(date '+%F %T')] [INFO] Logrotate executed rotation" >> /var/log/cdr-cleanup/cdr-cleanup.log 2>/dev/null || true
    endscript
}
EOF
    
    chmod 644 /etc/logrotate.d/cdr-cleanup
    
    if [[ -f /etc/logrotate.d/cdr-cleanup ]]; then
        print_success "Logrotate config installed: /etc/logrotate.d/cdr-cleanup"
    else
        print_error "Failed to install logrotate config"
        exit 1
    fi
}

install_systemd_service() {
    print_info "Installing systemd service (optional)..."
    
    # Create service file
    cat > /etc/systemd/system/cdr-cleanup.service << 'EOF'
[Unit]
Description=CDR Disk Cleanup Service
After=network-online.target
Wants=network-online.target
Documentation=man:cdr-cleanup(1)

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/cdr-cleanup.conf
ExecStart=/usr/local/bin/cdr-cleanup --force --threshold=${THRESHOLD}
StandardOutput=journal
StandardError=journal
LockPersonality=yes
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/home/cdrsbx /home/backup

[Install]
WantedBy=multi-user.target
EOF
    
    # Create timer file
    cat > /etc/systemd/system/cdr-cleanup.timer << 'EOF'
[Unit]
Description=Run CDR Cleanup Daily
Requires=cdr-cleanup.service
Documentation=man:cdr-cleanup(1)

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOF
    
    # Reload systemd
    systemctl daemon-reload 2>/dev/null || true
    
    print_success "Systemd service files created"
    print_info "To enable: systemctl enable --now cdr-cleanup.timer"
}

create_cron_job() {
    print_info "Creating cron job (alternative to systemd)..."
    
    # Create cron file
    cat > /etc/cron.d/cdr-cleanup << 'EOF'
# CDR Cleanup Cron Job
SHELL=/bin/bash
PATH=/sbin:/bin:/usr/sbin:/usr/bin
MAILTO=root

# Run daily at 2 AM
0 2 * * * root /usr/local/bin/cdr-cleanup --force --quiet

# Force logrotate monthly
0 0 1 * * root /usr/sbin/logrotate -f /etc/logrotate.d/cdr-cleanup
EOF
    
    chmod 644 /etc/cron.d/cdr-cleanup
    
    if [[ -f /etc/cron.d/cdr-cleanup ]]; then
        print_success "Cron job installed: /etc/cron.d/cdr-cleanup"
    else
        print_warning "Failed to install cron job (manual setup required)"
    fi
}

create_test_script() {
    print_info "Creating test script..."
    
    cat > /usr/local/bin/test-cdr-cleanup << 'EOF'
#!/bin/bash
# Test script for CDR Cleanup Utility

echo "=== Testing CDR Cleanup Utility ==="
echo

echo "1. Testing help command:"
cdr-cleanup --help | head -20
echo

echo "2. Testing man page:"
if man cdr-cleanup >/dev/null 2>&1; then
    echo "Man page exists and is accessible"
else
    echo "Man page not accessible"
fi
echo

echo "3. Testing dry-run mode:"
cdr-cleanup --dry-run --threshold=90 2>&1 | tail -10
echo

echo "4. Testing debug mode:"
cdr-cleanup --dry-run --debug --threshold=90 2>&1 | grep -E "(Debug|INFO|SUCCESS)" | head -5
echo

echo "5. Testing config file:"
if [[ -f /etc/cdr-cleanup.conf ]]; then
    echo "Config file exists: /etc/cdr-cleanup.conf"
    echo "Content preview:"
    head -10 /etc/cdr-cleanup.conf
else
    echo "Config file not found"
fi
echo

echo "6. Testing log file:"
if [[ -f /var/log/cdr-cleanup/cdr-cleanup.log ]]; then
    echo "Log file exists: /var/log/cdr-cleanup/cdr-cleanup.log"
    echo "Last 5 lines:"
    tail -5 /var/log/cdr-cleanup/cdr-cleanup.log
else
    echo "Log file not found"
fi
echo

echo "=== Test Completed ==="
EOF
    
    chmod 755 /usr/local/bin/test-cdr-cleanup
    print_success "Test script created: /usr/local/bin/test-cdr-cleanup"
}

verify_installation() {
    print_info "Verifying installation..."
    
    local success=true
    
    # Check main script
    if [[ ! -x /usr/local/bin/cdr-cleanup ]]; then
        print_error "Main script not found or not executable"
        success=false
    fi
    
    # Check config file
    if [[ ! -f /etc/cdr-cleanup.conf ]]; then
        print_error "Config file not found"
        success=false
    fi
    
    # Check man page
    if [[ ! -f /usr/local/share/man/man1/cdr-cleanup.1.gz ]]; then
        print_error "Man page not found"
        success=false
    fi
    
    # Check logrotate config
    if [[ ! -f /etc/logrotate.d/cdr-cleanup ]]; then
        print_error "Logrotate config not found"
        success=false
    fi
    
    # Check directories
    if [[ ! -d /var/log/cdr-cleanup ]]; then
        print_error "Log directory not found"
        success=false
    fi
    
    # Test script execution
    if /usr/local/bin/cdr-cleanup --dry-run --threshold=90 >/dev/null 2>&1; then
        print_success "Script test execution successful"
    else
        print_error "Script test execution failed"
        success=false
    fi
    
    # Test man page access
    if man cdr-cleanup >/dev/null 2>&1; then
        print_success "Man page accessible"
    else
        print_warning "Man page not accessible (may need manual mandb update)"
    fi
    
    if [[ "$success" == true ]]; then
        print_success "Installation verification passed!"
        return 0
    else
        print_error "Installation verification failed!"
        return 1
    fi
}

show_summary() {
    echo
    echo "========================================="
    echo "CDR CLEANUP UTILITY INSTALLATION COMPLETE"
    echo "========================================="
    echo
    echo "Files installed:"
    echo "  • /usr/local/bin/cdr-cleanup          (Main script)"
    echo "  • /etc/cdr-cleanup.conf              (Configuration)"
    echo "  • /usr/local/share/man/man1/cdr-cleanup.1.gz (Man page)"
    echo "  • /etc/logrotate.d/cdr-cleanup       (Log rotation)"
    echo "  • /etc/systemd/system/cdr-cleanup.service (Systemd service)"
    echo "  • /etc/systemd/system/cdr-cleanup.timer   (Systemd timer)"
    echo "  • /etc/cron.d/cdr-cleanup            (Cron job)"
    echo "  • /usr/local/bin/test-cdr-cleanup    (Test script)"
    echo
    echo "Directories created:"
    echo "  • /var/log/cdr-cleanup/              (Log files)"
    echo "  • /home/cdrsbx/                      (Default target)"
    echo "  • /home/backup/deleted_files/        (Backup directory)"
    echo "  • /usr/local/share/man/man1/         (Man page directory)"
    echo
    echo "Documentation:"
    echo "  • Man page: man cdr-cleanup"
    echo "  • Help: cdr-cleanup --help"
    echo "  • Test: test-cdr-cleanup"
    echo
    echo "Log Rotation:"
    echo "  • Monthly rotation OR when log reaches 50MB"
    echo "  • Keep 12 months of history"
    echo "  • Auto rotation in script when size limit reached"
    echo
    echo "Quick Start:"
    echo "  1. Read man page: man cdr-cleanup"
    echo "  2. Edit configuration: sudo vi /etc/cdr-cleanup.conf"
    echo "  3. Test script: sudo cdr-cleanup --dry-run --debug"
    echo "  4. Run manually: sudo cdr-cleanup --force --threshold=85"
    echo "  5. Enable auto-schedule:"
    echo "     Systemd: sudo systemctl enable --now cdr-cleanup.timer"
    echo "     OR Cron: Already configured in /etc/cron.d/cdr-cleanup"
    echo
    echo "For help: cdr-cleanup --help OR man cdr-cleanup"
    echo "========================================="
}

main() {
    echo
    echo "========================================="
    echo "CDR CLEANUP UTILITY INSTALLATION"
    echo "========================================="
    echo
    
    # Check prerequisites
    check_root
    check_rhel9
    check_dependencies
    
    # Installation steps
    create_directories
    install_main_script
    install_config_file
    install_man_page
    install_logrotate_config
    install_systemd_service
    create_cron_job
    create_test_script
    
    # Verify installation
    if verify_installation; then
        show_summary
        print_success "Installation completed successfully!"
        exit 0
    else
        print_error "Installation completed with errors. Please check above messages."
        exit 1
    fi
}

# Run main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
