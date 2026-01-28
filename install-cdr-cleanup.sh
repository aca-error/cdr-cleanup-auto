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
    local required_tools=("bash" "find" "sort" "stat" "df" "awk" "mkdir" "rm" "cp")
    
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
    chmod 700 /home/cdrsbx
    chmod 700 /home/backup/deleted_files
    
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

echo "2. Testing dry-run mode:"
cdr-cleanup --dry-run --threshold=90 2>&1 | tail -10
echo

echo "3. Testing debug mode:"
cdr-cleanup --dry-run --debug --threshold=90 2>&1 | grep -E "(Debug|INFO|SUCCESS)" | head -5
echo

echo "4. Testing config file:"
if [[ -f /etc/cdr-cleanup.conf ]]; then
    echo "Config file exists: /etc/cdr-cleanup.conf"
    echo "Content preview:"
    head -10 /etc/cdr-cleanup.conf
else
    echo "Config file not found"
fi
echo

echo "5. Testing log file:"
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
    echo
    echo "Log Rotation:"
    echo "  • Monthly rotation OR when log reaches 50MB"
    echo "  • Keep 12 months of history"
    echo "  • Auto rotation in script when size limit reached"
    echo
    echo "Quick Start:"
    echo "  1. Edit configuration: sudo vi /etc/cdr-cleanup.conf"
    echo "  2. Test script: sudo cdr-cleanup --dry-run --debug"
    echo "  3. Run manually: sudo cdr-cleanup --force --threshold=85"
    echo "  4. Enable auto-schedule:"
    echo "     Systemd: sudo systemctl enable --now cdr-cleanup.timer"
    echo "     OR Cron: Already configured in /etc/cron.d/cdr-cleanup"
    echo
    echo "Test installation: sudo test-cdr-cleanup"
    echo
    echo "For help: cdr-cleanup --help"
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
