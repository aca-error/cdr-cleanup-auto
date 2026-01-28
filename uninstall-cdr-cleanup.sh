#!/bin/bash
# CDR Cleanup Utility Uninstall Script
# =====================================
# Remove CDR Cleanup Utility from RHEL 9

set -o nounset -o pipefail -o errexit

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# File paths
SCRIPT_NAME="cdr-cleanup"
INSTALLED_SCRIPT="/usr/local/bin/cdr-cleanup"
CONFIG_FILE="/etc/cdr-cleanup.conf"
MAN_PAGE="/usr/local/share/man/man1/cdr-cleanup.1.gz"
MAN_PAGE_UNCOMPRESSED="/usr/local/share/man/man1/cdr-cleanup.1"
LOGROTATE_CONFIG="/etc/logrotate.d/cdr-cleanup"
SYSTEMD_SERVICE="/etc/systemd/system/cdr-cleanup.service"
SYSTEMD_TIMER="/etc/systemd/system/cdr-cleanup.timer"
CRON_FILE="/etc/cron.d/cdr-cleanup"
TEST_SCRIPT="/usr/local/bin/test-cdr-cleanup"
LOG_DIR="/var/log/cdr-cleanup"
LOCK_FILE="/var/lock/cdr-cleanup.lock"
BACKUP_DIR="/home/backup/deleted_files"
TARGET_DIR="/home/cdrsbx"
MAN_DIR="/usr/local/share/man/man1"

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

confirm_uninstall() {
    echo
    echo "========================================="
    echo "CDR CLEANUP UTILITY UNINSTALLATION"
    echo "========================================="
    echo
    echo "This will remove:"
    echo "  • Main script: $INSTALLED_SCRIPT"
    echo "  • Config file: $CONFIG_FILE"
    echo "  • Man page: $MAN_PAGE"
    echo "  • Logrotate config: $LOGROTATE_CONFIG"
    echo "  • Systemd files: $SYSTEMD_SERVICE, $SYSTEMD_TIMER"
    echo "  • Cron job: $CRON_FILE"
    echo "  • Test script: $TEST_SCRIPT"
    echo "  • Log directory: $LOG_DIR"
    echo "  • Lock file: $LOCK_FILE"
    echo
    echo "NOTE:"
    echo "  • Backup directory ($BACKUP_DIR) will NOT be removed"
    echo "  • Target directory ($TARGET_DIR) will NOT be removed"
    echo "  • Log files in $LOG_DIR will be removed"
    echo "  • Man page database will be updated"
    echo
    
    read -p "Are you sure you want to uninstall CDR Cleanup? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Uninstallation cancelled"
        exit 0
    fi
    
    # Optional: Confirm deletion of log files
    echo
    read -p "Delete all log files in $LOG_DIR? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        DELETE_LOGS=1
    else
        DELETE_LOGS=0
    fi
    
    # Optional: Confirm deletion of man page
    echo
    read -p "Remove man page from system? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        DELETE_MAN_PAGE=1
    else
        DELETE_MAN_PAGE=0
    fi
}

stop_services() {
    print_info "Stopping services..."
    
    # Stop and disable systemd timer if exists
    if systemctl is-active --quiet cdr-cleanup.timer 2>/dev/null; then
        systemctl stop cdr-cleanup.timer
        print_info "Stopped cdr-cleanup.timer"
    fi
    
    if systemctl is-enabled --quiet cdr-cleanup.timer 2>/dev/null; then
        systemctl disable cdr-cleanup.timer
        print_info "Disabled cdr-cleanup.timer"
    fi
    
    # Stop any running instance of the script
    local running_pids
    running_pids=$(pgrep -f "cdr-cleanup" 2>/dev/null || true)
    
    if [[ -n "$running_pids" ]]; then
        print_info "Stopping running cdr-cleanup processes..."
        kill $running_pids 2>/dev/null || true
        sleep 2
        
        # Force kill if still running
        running_pids=$(pgrep -f "cdr-cleanup" 2>/dev/null || true)
        if [[ -n "$running_pids" ]]; then
            kill -9 $running_pids 2>/dev/null || true
        fi
    fi
    
    # Remove lock file
    if [[ -f "$LOCK_FILE" ]]; then
        rm -f "$LOCK_FILE"
        print_info "Removed lock file: $LOCK_FILE"
    fi
    
    print_success "Services stopped"
}

remove_main_script() {
    print_info "Removing main script..."
    
    if [[ -f "$INSTALLED_SCRIPT" ]]; then
        rm -f "$INSTALLED_SCRIPT"
        
        if [[ ! -f "$INSTALLED_SCRIPT" ]]; then
            print_success "Removed main script: $INSTALLED_SCRIPT"
        else
            print_error "Failed to remove main script"
        fi
    else
        print_warning "Main script not found: $INSTALLED_SCRIPT"
    fi
}

remove_man_page() {
    local delete_man=${1:-1}
    
    print_info "Removing man page..."
    
    if [[ "$delete_man" -eq 1 ]]; then
        # Remove compressed man page
        if [[ -f "$MAN_PAGE" ]]; then
            rm -f "$MAN_PAGE"
            print_success "Removed man page: $MAN_PAGE"
        else
            print_warning "Compressed man page not found: $MAN_PAGE"
        fi
        
        # Remove uncompressed man page if exists
        if [[ -f "$MAN_PAGE_UNCOMPRESSED" ]]; then
            rm -f "$MAN_PAGE_UNCOMPRESSED"
            print_success "Removed uncompressed man page: $MAN_PAGE_UNCOMPRESSED"
        fi
        
        # Update man database
        if command -v mandb >/dev/null 2>&1; then
            mandb 2>/dev/null || true
            print_info "Updated man database"
        fi
    else
        print_info "Man page preservation requested, skipping removal"
    fi
    
    # Check if man directory is empty and remove if it is
    if [[ -d "$MAN_DIR" ]] && [[ -z "$(ls -A "$MAN_DIR" 2>/dev/null)" ]]; then
        rmdir "$MAN_DIR" 2>/dev/null || true
        print_info "Removed empty man directory: $MAN_DIR"
    fi
}

remove_config_files() {
    print_info "Removing configuration files..."
    
    # Remove config file
    if [[ -f "$CONFIG_FILE" ]]; then
        # Backup config file before removal
        local backup_file="/tmp/cdr-cleanup-config-backup-$(date +%Y%m%d_%H%M%S).conf"
        cp "$CONFIG_FILE" "$backup_file"
        print_info "Backed up config to: $backup_file"
        
        rm -f "$CONFIG_FILE"
        print_success "Removed config file: $CONFIG_FILE"
    else
        print_warning "Config file not found: $CONFIG_FILE"
    fi
    
    # Remove logrotate config
    if [[ -f "$LOGROTATE_CONFIG" ]]; then
        rm -f "$LOGROTATE_CONFIG"
        print_success "Removed logrotate config: $LOGROTATE_CONFIG"
    else
        print_warning "Logrotate config not found: $LOGROTATE_CONFIG"
    fi
}

remove_systemd_files() {
    print_info "Removing systemd files..."
    
    # Reload systemd first
    systemctl daemon-reload 2>/dev/null || true
    
    # Remove service file
    if [[ -f "$SYSTEMD_SERVICE" ]]; then
        rm -f "$SYSTEMD_SERVICE"
        print_success "Removed systemd service: $SYSTEMD_SERVICE"
    else
        print_warning "Systemd service not found: $SYSTEMD_SERVICE"
    fi
    
    # Remove timer file
    if [[ -f "$SYSTEMD_TIMER" ]]; then
        rm -f "$SYSTEMD_TIMER"
        print_success "Removed systemd timer: $SYSTEMD_TIMER"
    else
        print_warning "Systemd timer not found: $SYSTEMD_TIMER"
    fi
    
    # Final daemon reload
    systemctl daemon-reload 2>/dev/null || true
}

remove_cron_job() {
    print_info "Removing cron job..."
    
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        print_success "Removed cron file: $CRON_FILE"
    else
        print_warning "Cron file not found: $CRON_FILE"
    fi
}

remove_test_script() {
    print_info "Removing test script..."
    
    if [[ -f "$TEST_SCRIPT" ]]; then
        rm -f "$TEST_SCRIPT"
        print_success "Removed test script: $TEST_SCRIPT"
    else
        print_warning "
