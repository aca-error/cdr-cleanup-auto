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
LOGROTATE_CONFIG="/etc/logrotate.d/cdr-cleanup"
SYSTEMD_SERVICE="/etc/systemd/system/cdr-cleanup.service"
SYSTEMD_TIMER="/etc/systemd/system/cdr-cleanup.timer"
CRON_FILE="/etc/cron.d/cdr-cleanup"
TEST_SCRIPT="/usr/local/bin/test-cdr-cleanup"
LOG_DIR="/var/log/cdr-cleanup"
LOCK_FILE="/var/lock/cdr-cleanup.lock"
BACKUP_DIR="/home/backup/deleted_files"
TARGET_DIR="/home/cdrsbx"

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
        print_warning "Test script not found: $TEST_SCRIPT"
    fi
}

remove_log_files() {
    local delete_logs=${1:-0}
    
    print_info "Managing log files..."
    
    if [[ "$delete_logs" -eq 1 ]]; then
        # Delete entire log directory
        if [[ -d "$LOG_DIR" ]]; then
            # Backup logs before deletion
            local backup_dir="/tmp/cdr-cleanup-logs-backup-$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$backup_dir"
            cp -r "$LOG_DIR"/* "$backup_dir" 2>/dev/null || true
            print_info "Backed up logs to: $backup_dir"
            
            rm -rf "$LOG_DIR"
            print_success "Removed log directory: $LOG_DIR"
        else
            print_warning "Log directory not found: $LOG_DIR"
        fi
    else
        # Just remove current log file, keep directory
        if [[ -f "$LOG_DIR/cdr-cleanup.log" ]]; then
            rm -f "$LOG_DIR/cdr-cleanup.log"
            print_success "Removed main log file: $LOG_DIR/cdr-cleanup.log"
        fi
        
        # Remove rotated log files but keep directory
        if [[ -d "$LOG_DIR" ]]; then
            rm -f "$LOG_DIR"/*.gz 2>/dev/null || true
            rm -f "$LOG_DIR"/cdr-cleanup.log-* 2>/dev/null || true
            print_success "Cleaned up rotated log files"
        fi
    fi
}

cleanup_temporary_files() {
    print_info "Cleaning up temporary files..."
    
    # Remove temporary files from /tmp and /var/tmp
    rm -f /tmp/cdr_cleanup_* 2>/dev/null || true
    rm -f /var/tmp/cdr_cleanup_* 2>/dev/null || true
    rm -f /tmp/cdr-cleanup-* 2>/dev/null || true
    
    print_success "Temporary files cleaned up"
}

check_remaining_files() {
    print_info "Checking for remaining files..."
    
    local remaining_files=()
    
    # Check each file/directory
    [[ -f "$INSTALLED_SCRIPT" ]] && remaining_files+=("$INSTALLED_SCRIPT")
    [[ -f "$CONFIG_FILE" ]] && remaining_files+=("$CONFIG_FILE")
    [[ -f "$LOGROTATE_CONFIG" ]] && remaining_files+=("$LOGROTATE_CONFIG")
    [[ -f "$SYSTEMD_SERVICE" ]] && remaining_files+=("$SYSTEMD_SERVICE")
    [[ -f "$SYSTEMD_TIMER" ]] && remaining_files+=("$SYSTEMD_TIMER")
    [[ -f "$CRON_FILE" ]] && remaining_files+=("$CRON_FILE")
    [[ -f "$TEST_SCRIPT" ]] && remaining_files+=("$TEST_SCRIPT")
    [[ -f "$LOCK_FILE" ]] && remaining_files+=("$LOCK_FILE")
    
    # Check log directory based on DELETE_LOGS flag
    if [[ "${DELETE_LOGS:-0}" -eq 0 ]] && [[ -d "$LOG_DIR" ]]; then
        # Check if directory is empty
        if [[ -n "$(ls -A "$LOG_DIR" 2>/dev/null)" ]]; then
            remaining_files+=("$LOG_DIR (contains files)")
        fi
    elif [[ "${DELETE_LOGS:-0}" -eq 1 ]] && [[ -d "$LOG_DIR" ]]; then
        remaining_files+=("$LOG_DIR")
    fi
    
    if [[ ${#remaining_files[@]} -gt 0 ]]; then
        print_warning "The following files/directories remain:"
        for file in "${remaining_files[@]}"; do
            echo "  • $file"
        done
        
        echo
        read -p "Force remove these files? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            for file in "${remaining_files[@]}"; do
                if [[ "$file" == *"("*")"* ]]; then
                    # Extract path from parentheses
                    local path="${file%% (*}"
                    if [[ -d "$path" ]]; then
                        rm -rf "$path"
                        print_info "Force removed: $path"
                    fi
                else
                    rm -rf "$file" 2>/dev/null || true
                    print_info "Force removed: $file"
                fi
            done
        fi
    else
        print_success "All files removed successfully"
    fi
}

show_preserved_directories() {
    print_info "The following directories were preserved:"
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo "  • $BACKUP_DIR"
        echo "    Contents: $(find "$BACKUP_DIR" -type f 2>/dev/null | wc -l) files"
        echo "    Size: $(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1) || "N/A""
    fi
    
    if [[ -d "$TARGET_DIR" ]]; then
        echo "  • $TARGET_DIR"
        echo "    Contents: $(find "$TARGET_DIR" -type f 2>/dev/null | wc -l) files"
        echo "    Size: $(du -sh "$TARGET_DIR" 2>/dev/null | cut -f1) || "N/A""
    fi
    
    echo
    echo "You may want to manually check these directories."
}

verify_uninstallation() {
    print_info "Verifying uninstallation..."
    
    local verification_passed=true
    
    # Check main components
    if [[ -f "$INSTALLED_SCRIPT" ]]; then
        print_error "Main script still exists: $INSTALLED_SCRIPT"
        verification_passed=false
    fi
    
    if [[ -f "$CONFIG_FILE" ]]; then
        print_error "Config file still exists: $CONFIG_FILE"
        verification_passed=false
    fi
    
    if [[ -f "$SYSTEMD_SERVICE" ]]; then
        print_error "Systemd service still exists: $SYSTEMD_SERVICE"
        verification_passed=false
    fi
    
    if [[ -f "$SYSTEMD_TIMER" ]]; then
        print_error "Systemd timer still exists: $SYSTEMD_TIMER"
        verification_passed=false
    fi
    
    if [[ -f "$CRON_FILE" ]]; then
        print_error "Cron file still exists: $CRON_FILE"
        verification_passed=false
    fi
    
    # Check if services are still active
    if systemctl is-active --quiet cdr-cleanup.timer 2>/dev/null; then
        print_error "Systemd timer is still active"
        verification_passed=false
    fi
    
    if pgrep -f "cdr-cleanup" >/dev/null 2>&1; then
        print_error "cdr-cleanup process is still running"
        verification_passed=false
    fi
    
    if [[ "$verification_passed" == true ]]; then
        print_success "Uninstallation verification passed!"
        return 0
    else
        print_error "Uninstallation verification failed!"
        return 1
    fi
}

show_summary() {
    echo
    echo "========================================="
    echo "CDR CLEANUP UNINSTALLATION SUMMARY"
    echo "========================================="
    echo
    echo "Removed:"
    [[ ! -f "$INSTALLED_SCRIPT" ]] && echo "  ✓ Main script"
    [[ ! -f "$CONFIG_FILE" ]] && echo "  ✓ Config file"
    [[ ! -f "$LOGROTATE_CONFIG" ]] && echo "  ✓ Logrotate config"
    [[ ! -f "$SYSTEMD_SERVICE" ]] && echo "  ✓ Systemd service"
    [[ ! -f "$SYSTEMD_TIMER" ]] && echo "  ✓ Systemd timer"
    [[ ! -f "$CRON_FILE" ]] && echo "  ✓ Cron job"
    [[ ! -f "$TEST_SCRIPT" ]] && echo "  ✓ Test script"
    [[ ! -f "$LOCK_FILE" ]] && echo "  ✓ Lock file"
    
    if [[ "${DELETE_LOGS:-0}" -eq 1 ]]; then
        [[ ! -d "$LOG_DIR" ]] && echo "  ✓ Log directory (all logs)"
    else
        [[ ! -f "$LOG_DIR/cdr-cleanup.log" ]] && echo "  ✓ Current log file"
        echo "  ✓ Rotated log files"
    fi
    
    echo
    echo "Preserved (not removed):"
    [[ -d "$BACKUP_DIR" ]] && echo "  • Backup directory: $BACKUP_DIR"
    [[ -d "$TARGET_DIR" ]] && echo "  • Target directory: $TARGET_DIR"
    
    if [[ "${DELETE_LOGS:-0}" -eq 0 ]] && [[ -d "$LOG_DIR" ]]; then
        echo "  • Log directory structure: $LOG_DIR"
    fi
    
    echo
    echo "Backups created:"
    if ls /tmp/cdr-cleanup-*-backup-* 2>/dev/null | head -1 >/dev/null; then
        ls -la /tmp/cdr-cleanup-*-backup-* 2>/dev/null | while read -r line; do
            echo "  • $(echo "$line" | awk '{print $9}')"
        done
        echo
        echo "Note: Backup files are in /tmp and may be cleaned on reboot."
    else
        echo "  • No backups created"
    fi
    
    echo
    echo "Next steps:"
    echo "  1. Review preserved directories above"
    echo "  2. Remove backup files from /tmp if no longer needed"
    echo "  3. Reboot if any processes were still running"
    echo "  4. Run 'systemctl daemon-reload' if systemd issues persist"
    echo
    echo "To reinstall, run the installation script again."
    echo "========================================="
}

main() {
    # Check if running as root
    check_root
    
    # Confirm uninstallation
    confirm_uninstall
    
    # Stop services and processes
    stop_services
    
    # Remove files
    remove_main_script
    remove_config_files
    remove_systemd_files
    remove_cron_job
    remove_test_script
    
    # Handle log files based on user choice
    remove_log_files "${DELETE_LOGS:-0}"
    
    # Cleanup temporary files
    cleanup_temporary_files
    
    # Check for remaining files
    check_remaining_files
    
    # Show preserved directories
    show_preserved_directories
    
    # Verify uninstallation
    if verify_uninstallation; then
        print_success "Uninstallation completed successfully!"
    else
        print_warning "Uninstallation completed with warnings"
    fi
    
    # Show summary
    show_summary
}

# Run main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
