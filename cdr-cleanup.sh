#!/bin/bash
set -o nounset -o pipefail -o errexit

# =======================
# KONFIGURASI DEFAULT
# =======================
CONFIG_FILE="/etc/cdr-cleanup.conf"
LOG_FILE="/var/log/cdr-cleanup/cdr-cleanup.log"
LOCK_FILE="/var/lock/cdr-cleanup.lock"
LOG_ROTATE_CONFIG="/etc/logrotate.d/cdr-cleanup"

# Default values (akan di-override oleh config file)
DIRECTORY="/home/cdrsbx"
THRESHOLD=90
MAX_LOG_SIZE_MB=50           # 50MB (sinkron dengan logrotate config)
MIN_FILE_COUNT=30            # Minimal file disisakan per directory
MAX_DELETE_PER_RUN=100       # Max file dihapus per eksekusi
BACKUP_ENABLED=0
BACKUP_DIR="/home/backup/deleted_files"
AUTO_ROTATE_LOG=1            # Enable auto log rotation

DRY_RUN=1
DEBUG_MODE=0

# =======================
# KONFIGURASI UMUR FILE
# =======================
ENABLE_AGE_BASED_CLEANUP=0
DEFAULT_FILE_AGE_DAYS=180
FILE_AGE_DAYS="$DEFAULT_FILE_AGE_DAYS"
FILE_AGE_SECONDS=$((FILE_AGE_DAYS * 24 * 60 * 60))

# =======================
# DEFAULT EXCLUDE PATTERNS
# =======================
# Hidden files/directories dan system files
DEFAULT_EXCLUDE_PATTERNS=(
    # Hidden files and directories
    '.*'
    '*/.*'
    
    # User home default directories (important)
    '*/Desktop/*'
    '*/Documents/*'
    '*/Downloads/*'
    '*/Pictures/*'
    '*/Music/*'
    '*/Videos/*'
    '*/Public/*'
    '*/Templates/*'
    
    # Configuration directories
    '*/\.config/*'
    '*/\.local/*'
    '*/\.cache/*'
    
    # SSH and security
    '*/\.ssh/*'
    '*/\.gnupg/*'
    '*/\.pki/*'
    
    # Version control
    '*/\.git/*'
    '*/\.svn/*'
    '*/\.hg/*'
    
    # Application data
    '*/\.mozilla/*'
    '*/\.thunderbird/*'
    '*/\.google-chrome/*'
    '*/\.vscode/*'
    
    # Shell and terminal
    '*/\.bash*'
    '*/\.profile'
    '*/\.zsh*'
    '*/\.history*'
    
    # System files
    'lost+found'
    '*/lost+found/*'
    
    # Temporary files pattern
    '*~'
    '*.swp'
    '*.swo'
    '*.tmp'
    '*.temp'
)

# =======================
# SETUP UTILITAS
# =======================
TEMP_ALL_FILES=$(mktemp "/tmp/cdr-cleanup.$$.all.XXXXXX")
TEMP_DELETE_LIST=$(mktemp "/tmp/cdr-cleanup.$$.delete.XXXXXX")

# =======================
# FLAG UNTUK TRACKING ARGUMENTS
# =======================
# Global flags untuk tracking argument
ARG_DIRECTORY_SET=0
ARG_THRESHOLD_SET=0
ARG_MAX_DELETE_SET=0
ARG_MIN_FILES_SET=0
ARG_BACKUP_SET=0
ARG_LOG_ROTATE_SET=0

# =======================
# GLOBAL VARIABLES FOR TIMING & CACHE
# =======================
declare -g SCRIPT_START_TIME
declare -g SCRIPT_END_TIME
declare -A FILE_AGE_CACHE
declare -A DIR_COUNTS_CACHE

# =======================
# FUNGSI VALIDASI
# =======================
validate_integer() {
    local value="$1"
    local name="$2"
    local min="${3:-0}"
    local max="${4:-999999}"
    
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        print_to_terminal "Error: $name harus berupa angka integer (diterima: '$value')" "ERROR"
        exit 1
    fi
    
    if [[ "$value" -lt "$min" ]]; then
        print_to_terminal "Error: $name minimal $min (diterima: $value)" "ERROR"
        exit 1
    fi
    
    if [[ "$value" -gt "$max" ]]; then
        print_to_terminal "Error: $name maksimal $max (diterima: $value)" "ERROR"
        exit 1
    fi
    
    return 0
}

# =======================
# FUNGSI UTAMA
# =======================
cleanup_temp() {
    rm -f "$TEMP_ALL_FILES" "$TEMP_DELETE_LIST"
    rm -f "$LOCK_FILE" 2>/dev/null
}

# Trap multiple signals untuk graceful shutdown
handle_exit() {
    local exit_code=$?
    SCRIPT_END_TIME=$(date +%s)
    
    # Log termination reason
    if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 130 ]]; then  # 130 = SIGINT
        print_to_terminal "Script terminated with error/signal (Code: $exit_code)" "ERROR"
    elif [[ $exit_code -eq 130 ]]; then
        print_to_terminal "Script interrupted by user (SIGINT)" "WARNING"
    fi
    
    # Log duration jika start time tersedia
    if [[ -n "${SCRIPT_START_TIME:-}" ]]; then
        local DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
        print_to_terminal "Execution duration: ${DURATION} seconds" "INFO"
    fi
    
    # Cleanup resources
    cleanup_temp
    
    exit $exit_code
}

# Register signal handlers
trap handle_exit EXIT INT TERM HUP

get_timestamp_ms() {
    date '+%F %T.%3N' # YYYY-MM-DD HH:MM:SS.mmm
}

get_time_only_ms() {
    date '+%H:%M:%S.%3N' # HH:MM:SS.mmm (Short version)
}

print_to_terminal() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp_full=$(get_timestamp_ms)
    local timestamp_short=$(get_time_only_ms)
    
    # SELALU log ke file
    echo "[$timestamp_full] [$level] $message" >> "$LOG_FILE"
    
    # Output ke Terminal (jika interaktif)
    if [[ -t 1 ]]; then
        # Skip terminal output untuk DEBUG mode jika tidak diaktifkan
        if [[ "$level" == "DEBUG" ]] && [[ "$DEBUG_MODE" -eq 0 ]]; then
            return
        fi
        
        case "$level" in
            "SUCCESS") echo -e "\033[0;32m[$timestamp_short] [SUCCESS] $message\033[0m" ;;
            "ERROR")   echo -e "\033[0;31m[$timestamp_short] [ERROR] $message\033[0m" ;;
            "WARNING") echo -e "\033[0;33m[$timestamp_short] [WARNING] $message\033[0m" ;;
            "INFO")    echo -e "\033[0;36m[$timestamp_short] [INFO] $message\033[0m" ;;
            "DRY_RUN") echo -e "\033[0;35m[$timestamp_short] [DRY_RUN] $message\033[0m" ;;
            "DEBUG")   echo -e "\033[0;90m[$timestamp_short] [DEBUG] $message\033[0m" ;;
            "HEADER")  echo -e "\033[1;34m$message\033[0m" ;;
            *)         echo -e "[$timestamp_short] [$level] $message" ;;
        esac
    fi
    
    # Log ke journald jika tersedia
    if command -v logger >/dev/null 2>&1 && [[ -v INVOCATION_ID ]]; then
        local journal_priority
        case "$level" in
            "SUCCESS"|"INFO") journal_priority="info" ;;
            "ERROR")   journal_priority="err" ;;
            "WARNING") journal_priority="warning" ;;
            "DRY_RUN"|"DEBUG") journal_priority="debug" ;;
            *)         journal_priority="info" ;;
        esac
        logger -t "cdr-cleanup" -p "user.$journal_priority" "$message"
    fi
}

# =======================
# FUNGSI LOG ROTATION
# =======================
check_and_rotate_log() {
    local log_file="$1"
    local max_size_mb="${MAX_LOG_SIZE_MB:-50}"
    local max_size_bytes=$((max_size_mb * 1024 * 1024))
    
    # Skip jika auto rotate disabled
    [[ "${AUTO_ROTATE_LOG:-1}" -eq 0 ]] && return 0
    
    if [[ -f "$log_file" ]]; then
        local current_size
        current_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
        local current_size_mb=$((current_size / 1024 / 1024))
        
        if [[ "$current_size" -ge "$max_size_bytes" ]]; then
            print_to_terminal "Log file size: ${current_size_mb}MB exceeds ${max_size_mb}MB limit" "WARNING"
            print_to_terminal "Performing automatic log rotation..." "INFO"
            
            if rotate_log_now "$log_file"; then
                print_to_terminal "Log rotation completed successfully" "SUCCESS"
            else
                print_to_terminal "Log rotation failed, continuing with existing log" "ERROR"
            fi
        elif [[ "$DEBUG_MODE" -eq 1 ]]; then
            print_to_terminal "Debug: Log file size: ${current_size_mb}MB (Limit: ${max_size_mb}MB)" "DEBUG"
        fi
    fi
}

rotate_log_now() {
    local log_file="$1"
    
    print_to_terminal "Starting manual log rotation..." "INFO"
    
    # Coba gunakan logrotate jika tersedia
    if command -v logrotate >/dev/null 2>&1 && [[ -f "$LOG_ROTATE_CONFIG" ]]; then
        if logrotate -f "$LOG_ROTATE_CONFIG" 2>/dev/null; then
            print_to_terminal "Logrotate command executed successfully" "DEBUG"
            return 0
        else
            print_to_terminal "Logrotate command failed, trying manual method" "WARNING"
        fi
    fi
    
    # Manual rotation (fallback)
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local rotated_file="${log_file}.${timestamp}"
    
    if cp "$log_file" "$rotated_file" 2>/dev/null; then
        # Truncate original log file
        > "$log_file"
        print_to_terminal "Rotated log saved to: $rotated_file" "INFO"
        
        # Compress rotated file
        if command -v gzip >/dev/null 2>&1; then
            if gzip -f "$rotated_file" 2>/dev/null; then
                print_to_terminal "Rotated log compressed: ${rotated_file}.gz" "DEBUG"
            fi
        fi
        
        # Cleanup old rotated logs
        cleanup_old_logs
        
        return 0
    else
        print_to_terminal "Failed to rotate log file" "ERROR"
        return 1
    fi
}

cleanup_old_logs() {
    local log_dir="/var/log/cdr-cleanup"
    local keep_days=30
    
    if [[ -d "$log_dir" ]]; then
        print_to_terminal "Cleaning up old log files (older than ${keep_days} days)..." "DEBUG"
        
        # Hapus compressed log files
        local deleted_count
        deleted_count=$(find "$log_dir" -name "*.gz" -type f -mtime "+${keep_days}" -delete -print 2>/dev/null | wc -l)
        
        if [[ "$deleted_count" -gt 0 ]]; then
            print_to_terminal "Cleaned up ${deleted_count} old compressed log files" "INFO"
        fi
        
        # Juga cleanup rotated files tanpa extension
        local rotated_count
        rotated_count=$(find "$log_dir" -name "$(basename "$LOG_FILE").*" -type f ! -name "*.gz" -mtime "+${keep_days}" -delete -print 2>/dev/null | wc -l)
        
        if [[ "$rotated_count" -gt 0 ]]; then
            print_to_terminal "Cleaned up ${rotated_count} old rotated log files" "INFO"
        fi
    fi
}

months_to_days() {
    local months="$1"
    echo $((months * 30))
}

get_disk_usage() {
    local dir="$1"
    
    if [[ -z "$dir" ]] || [[ ! -d "$dir" ]]; then
        print_to_terminal "Error: Directory '$dir' tidak valid untuk get_disk_usage" "ERROR"
        echo "0"
        return 1
    fi
    
    local df_output
    df_output=$(df -P "$dir" 2>/dev/null)
    
    if [[ -z "$df_output" ]]; then
        print_to_terminal "Warning: Gagal mendapatkan disk usage untuk $dir" "WARNING"
        echo "0"
        return 1
    fi
    
    local usage
    usage=$(echo "$df_output" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
    
    if [[ "$DEBUG_MODE" -eq 1 ]]; then
        print_to_terminal "Debug: Disk usage untuk $dir: ${usage}%" "DEBUG"
    fi
    
    if [[ -z "$usage" ]] || ! [[ "$usage" =~ ^[0-9]+$ ]]; then
        print_to_terminal "Warning: Nilai disk usage tidak valid: '$usage'" "WARNING"
        echo "0"
        return 1
    fi
    
    echo "$usage"
}

get_file_age_days() {
    local filepath="$1"
    
    # Gunakan cache untuk performance
    if [[ -n "${FILE_AGE_CACHE[$filepath]:-}" ]]; then
        echo "${FILE_AGE_CACHE[$filepath]}"
        return
    fi
    
    local current_time=$(date +%s)
    if [[ -f "$filepath" ]]; then
        local file_mtime=$(stat -c %Y "$filepath" 2>/dev/null || echo 0)
        local age=$(((current_time - file_mtime) / 86400))
        FILE_AGE_CACHE["$filepath"]=$age
        echo "$age"
    else
        echo "0"
    fi
}

validate_directory() {
    local dir="$1"
    
    if [[ ! -d "$dir" ]]; then
        print_to_terminal "Error: Directory '$dir' tidak ditemukan" "ERROR"
        exit 1
    fi
    
    if [[ ! -r "$dir" ]] || [[ ! -x "$dir" ]]; then
        print_to_terminal "Error: Tidak ada permission read/execute untuk '$dir'" "ERROR"
        exit 1
    fi
    
    # Prevent cleanup of protected system directories
    local protected_dirs=("/" "/bin" "/sbin" "/usr" "/etc" "/boot" "/lib" "/lib64" "/var" "/sys" "/proc" "/dev")
    for protected in "${protected_dirs[@]}"; do
        if [[ "$dir" == "$protected" ]] || [[ "$dir" == "$protected/"* ]]; then
            print_to_terminal "Error: Directory '$dir' adalah system protected directory" "ERROR"
            exit 1
        fi
    done
    
    if ! df -P "$dir" >/dev/null 2>&1; then
        print_to_terminal "Warning: Directory '$dir' mungkin bukan mount point yang valid" "WARNING"
    fi
}

check_security_files() {
    local dir="$1"
    
    local security_patterns=(
        "authorized_keys"
        "known_hosts"
        "id_rsa"
        "id_dsa"
        "*.pem"
        "*.key"
        "*.crt"
        "shadow"
        "passwd"
        "*.db"
        "selinux/*"
    )
    
    for pattern in "${security_patterns[@]}"; do
        # Hindari SIGPIPE dengan membaca semua output dulu
        local found_files
        found_files=$(find "$dir" -name "$pattern" -type f 2>/dev/null)
        
        if [[ -n "$found_files" ]]; then
            print_to_terminal "WARNING: Directory mengandung file security-sensitive: $pattern" "WARNING"
            
            if [[ "$DEBUG_MODE" -eq 1 ]]; then
                print_to_terminal "Debug: Found security files: $(echo "$found_files" | head -3 | tr '\n' ',')" "DEBUG"
            fi
            
            if [[ "$DRY_RUN" -eq 0 ]] && [[ -t 0 ]]; then
                read -p "Lanjutkan? (y/N): " -n 1 -r
                echo
                [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
            fi
            break
        fi
    done
}

backup_file() {
    local filepath="$1"
    [[ "$BACKUP_ENABLED" -eq 0 ]] && return 0
    
    local filename=$(basename "$filepath")
    local safe_dirname=$(dirname "$filepath" | sed 's/[^a-zA-Z0-9.-]/_/g')
    local backup_path="$BACKUP_DIR/$(date +%Y%m%d)/$safe_dirname"
    
    mkdir -p "$backup_path" 2>/dev/null
    
    # Preserve SELinux context jika SELinux enabled
    local selinux_enabled=0
    if command -v getenforce >/dev/null 2>&1; then
        if [[ "$(getenforce)" != "Disabled" ]]; then
            selinux_enabled=1
        fi
    fi
    
    if [[ "$selinux_enabled" -eq 1 ]]; then
        if cp --preserve=context -- "$filepath" "$backup_path/$filename" 2>/dev/null; then
            print_to_terminal "Backup dengan SELinux context: $filepath" "INFO"
        elif cp --preserve=all -- "$filepath" "$backup_path/$filename" 2>/dev/null; then
            print_to_terminal "Backup: $filepath" "INFO"
        else
            cp -- "$filepath" "$backup_path/$filename" 2>/dev/null
            print_to_terminal "Backup (tanpa preserve): $filepath" "WARNING"
        fi
    else
        if cp --preserve=all -- "$filepath" "$backup_path/$filename" 2>/dev/null; then
            print_to_terminal "Backup: $filepath" "INFO"
        else
            cp -- "$filepath" "$backup_path/$filename" 2>/dev/null
            print_to_terminal "Backup (basic): $filepath" "INFO"
        fi
    fi
}

safe_delete() {
    local filepath="$1"
    
    if [[ "$BACKUP_ENABLED" -eq 1 ]]; then
        backup_file "$filepath"
    fi
    
    if [[ "$DRY_RUN" -eq 1 ]]; then
        local age_days=$(get_file_age_days "$filepath")
        print_to_terminal "Would delete: $filepath (Age: $age_days days)" "DRY_RUN"
        return 0
    fi
    
    if rm -f -- "$filepath"; then
        print_to_terminal "Deleted: $filepath" "SUCCESS"
        return 0
    else
        print_to_terminal "Failed to delete: $filepath" "ERROR"
        return 1
    fi
}

# =======================
# HELP & USAGE
# =======================
show_help() {
    local script_name
    script_name=$(basename "${0}")
    
    cat << EOF
CDR Cleanup Utility for RHEL 9
--------------------------------
Script ini menghapus file lama berdasarkan penggunaan disk (threshold) atau umur file,
dengan mekanisme proteksi jumlah file minimum per folder.

CONFIGURATION:
    Main config: /etc/cdr-cleanup.conf
    Log file: /var/log/cdr-cleanup/cdr-cleanup.log
    Lock file: /var/lock/cdr-cleanup.lock
    Log rotation: /etc/logrotate.d/cdr-cleanup

SECURITY FEATURES:
- Exclude semua hidden files/directories (dimulai dengan .)
- Exclude default user directories (Desktop, Documents, Downloads, dll)
- Exclude configuration directories (.config, .ssh, .git, dll)
- Validasi directory system untuk keamanan

AUTO LOG ROTATION:
- Log akan di-rotate otomatis jika mencapai ${MAX_LOG_SIZE_MB}MB
- Menggunakan logrotate atau manual method sebagai fallback
- Konfigurasi: MAX_LOG_SIZE_MB dan AUTO_ROTATE_LOG di config file

USAGE:
    ./$script_name [OPTIONS]

MODES:
    1. Disk Threshold (Default):
       Hapus file terlama hanya jika penggunaan disk >= threshold.
    2. Age Based (--age-days / --age-months):
       Hapus file yang umurnya > N hari/bulan tanpa melihat disk usage.

OPTIONS:
    --dry-run             Simulasi saja, tidak menghapus file (Default).
    --force               Jalankan penghapusan file secara nyata.
    
    --threshold=N         Batas persen disk usage (Default: dari config).
                          
    --age-days=N          Hapus file > N hari. Mengaktifkan mode Age Based.
    --age-months=N        Hapus file > N bulan. Mengaktifkan mode Age Based.
    
    --directory=PATH      Target direktori (Override config).
    --min-files=N         Minimum file yang WAJIB disisakan per folder (Override config).
    --max-delete=N        Batas maksimum file yang dihapus per eksekusi (Override config).
    
    --exclude=PATTERN     Tambah pattern untuk exclude (bisa digunakan berkali-kali).
    --include-hidden      INCLUDE hidden files/directories (TIDAK DISARANKAN!).
    
    --backup              Backup file sebelum dihapus (Override config).
    --no-backup           Nonaktifkan backup (Override config).
    --debug               Tampilkan debug messages ke terminal.
    --quiet               Matikan semua output ke terminal (tetap log ke file).
    --config=FILE         Gunakan config file alternatif.
    --no-log-rotate       Nonaktifkan auto log rotation untuk run ini.
    --help                Tampilkan pesan bantuan ini.

EXAMPLES:
    # Simulasi cleanup dengan threshold dari config
    ./$script_name --dry-run

    # Hapus file tua > 180 hari
    ./$script_name --force --age-days=180

    # Cleanup tanpa auto log rotation
    ./$script_name --force --threshold=80 --no-log-rotate

    # Override directory dari config
    ./$script_name --force --directory=/data --threshold=75 --debug

DEFAULT EXCLUDES:
    • Semua hidden files/directories (.*, */.*)
    • User home directories: Desktop, Documents, Downloads, Pictures, Music, Videos
    • Configuration: .config, .local, .cache, .ssh, .gnupg
    • Version control: .git, .svn, .hg
    • Application data: .mozilla, .thunderbird, .vscode
    • Shell files: .bash*, .profile, .zsh*

EOF
}

# =======================
# PARSING ARGUMEN
# =======================
parse_arguments() {
    USER_EXCLUDE_PATTERNS=()
    INCLUDE_HIDDEN=0
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            --force) DRY_RUN=0; shift ;;
            --backup) BACKUP_ENABLED=1; ARG_BACKUP_SET=1; shift ;;
            --no-backup) BACKUP_ENABLED=0; ARG_BACKUP_SET=1; shift ;;
            --threshold=*) 
                THRESHOLD="${1#*=}"; ARG_THRESHOLD_SET=1
                validate_integer "$THRESHOLD" "--threshold" 1 100
                shift ;;
            --max-delete=*) 
                MAX_DELETE_PER_RUN="${1#*=}"; ARG_MAX_DELETE_SET=1
                validate_integer "$MAX_DELETE_PER_RUN" "--max-delete" 1 10000
                shift ;;
            --min-files=*) 
                MIN_FILE_COUNT="${1#*=}"; ARG_MIN_FILES_SET=1
                validate_integer "$MIN_FILE_COUNT" "--min-files" 0 100000
                shift ;;
            --directory=*) 
                DIRECTORY="${1#*=}"; ARG_DIRECTORY_SET=1
                shift ;;
            --age-days=*) 
                ENABLE_AGE_BASED_CLEANUP=1
                FILE_AGE_DAYS="${1#*=}"
                validate_integer "$FILE_AGE_DAYS" "--age-days" 1 36500  # 1-100 tahun
                shift ;;
            --age-months=*) 
                ENABLE_AGE_BASED_CLEANUP=1
                local months="${1#*=}"
                validate_integer "$months" "--age-months" 1 1200  # 1-100 tahun
                FILE_AGE_DAYS=$(months_to_days "$months")
                shift ;;
            --exclude=*)
                USER_EXCLUDE_PATTERNS+=("${1#*=}")
                shift ;;
            --include-hidden)
                INCLUDE_HIDDEN=1
                shift ;;
            --debug)
                DEBUG_MODE=1
                shift ;;
            --config=*)
                CONFIG_FILE="${1#*=}"
                shift ;;
            --no-log-rotate)
                AUTO_ROTATE_LOG=0; ARG_LOG_ROTATE_SET=1
                shift ;;
            --quiet) 
                print_to_terminal() {
                    local message="$1"
                    local level="${2:-INFO}"
                    local timestamp_full=$(get_timestamp_ms)
                    echo "[$timestamp_full] [$level] $message" >> "$LOG_FILE"
                }
                shift ;;
            --help)
                show_help
                exit 0 ;;
            *) 
                echo "Error: Opsi tidak dikenal '$1'"
                echo "Gunakan './$(basename "$0") --help' untuk bantuan."
                exit 1 ;;
        esac
    done
}

# =======================
# FUNGSI LOAD CONFIG
# =======================
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        print_to_terminal "Loading configuration from $CONFIG_FILE" "INFO"
        
        # Simpan nilai dari arguments sebelum di-override
        local ARG_DIRECTORY="$DIRECTORY"
        local ARG_THRESHOLD="$THRESHOLD"
        local ARG_MAX_DELETE="$MAX_DELETE_PER_RUN"
        local ARG_MIN_FILES="$MIN_FILE_COUNT"
        local ARG_BACKUP_ENABLED="$BACKUP_ENABLED"
        local ARG_BACKUP_DIR="$BACKUP_DIR"
        local ARG_AUTO_ROTATE_LOG="$AUTO_ROTATE_LOG"
        
        if ! source "$CONFIG_FILE" 2>/dev/null; then
            print_to_terminal "Error: Failed to load config file $CONFIG_FILE" "ERROR"
            exit 1
        fi
        
        print_to_terminal "Merging command line arguments with config..." "DEBUG"
        
        # Command line arguments > Config file > Default values
        if [[ "$ARG_DIRECTORY_SET" -eq 1 ]]; then
            DIRECTORY="$ARG_DIRECTORY"
            print_to_terminal "Using directory from arguments: $DIRECTORY" "DEBUG"
        elif [[ -z "${DIRECTORY:-}" ]]; then
            DIRECTORY="/home/cdrsbx"
            print_to_terminal "Using default directory: $DIRECTORY" "DEBUG"
        fi
        
        if [[ "$ARG_THRESHOLD_SET" -eq 1 ]]; then
            THRESHOLD="$ARG_THRESHOLD"
            print_to_terminal "Using threshold from arguments: $THRESHOLD" "DEBUG"
        elif [[ -z "${THRESHOLD:-}" ]] || ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
            THRESHOLD=90
            print_to_terminal "Using default threshold: $THRESHOLD" "DEBUG"
        fi
        
        if [[ "$ARG_MIN_FILES_SET" -eq 1 ]]; then
            MIN_FILE_COUNT="$ARG_MIN_FILES"
            print_to_terminal "Using min-files from arguments: $MIN_FILE_COUNT" "DEBUG"
        elif [[ -z "${MIN_FILE_COUNT:-}" ]] || ! [[ "$MIN_FILE_COUNT" =~ ^[0-9]+$ ]]; then
            MIN_FILE_COUNT=30
            print_to_terminal "Using default min-files: $MIN_FILE_COUNT" "DEBUG"
        fi
        
        if [[ "$ARG_MAX_DELETE_SET" -eq 1 ]]; then
            MAX_DELETE_PER_RUN="$ARG_MAX_DELETE"
            print_to_terminal "Using max-delete from arguments: $MAX_DELETE_PER_RUN" "DEBUG"
        elif [[ -z "${MAX_DELETE_PER_RUN:-}" ]] || ! [[ "$MAX_DELETE_PER_RUN" =~ ^[0-9]+$ ]]; then
            MAX_DELETE_PER_RUN=100
            print_to_terminal "Using default max-delete: $MAX_DELETE_PER_RUN" "DEBUG"
        fi
        
        if [[ "$ARG_BACKUP_SET" -eq 1 ]]; then
            BACKUP_ENABLED="$ARG_BACKUP_ENABLED"
            print_to_terminal "Using backup from arguments: $BACKUP_ENABLED" "DEBUG"
        elif [[ -z "${BACKUP_ENABLED:-}" ]] || ! [[ "$BACKUP_ENABLED" =~ ^[0-1]$ ]]; then
            BACKUP_ENABLED=0
            print_to_terminal "Using default backup: $BACKUP_ENABLED" "DEBUG"
        fi
        
        if [[ "$ARG_BACKUP_SET" -eq 1 ]] && [[ -n "$ARG_BACKUP_DIR" ]]; then
            BACKUP_DIR="$ARG_BACKUP_DIR"
            print_to_terminal "Using backup-dir from arguments: $BACKUP_DIR" "DEBUG"
        elif [[ -z "${BACKUP_DIR:-}" ]]; then
            BACKUP_DIR="/home/backup/deleted_files"
            print_to_terminal "Using default backup-dir: $BACKUP_DIR" "DEBUG"
        fi
        
        if [[ "$ARG_LOG_ROTATE_SET" -eq 1 ]]; then
            AUTO_ROTATE_LOG="$ARG_AUTO_ROTATE_LOG"
            print_to_terminal "Using log-rotate from arguments: $AUTO_ROTATE_LOG" "DEBUG"
        elif [[ -z "${AUTO_ROTATE_LOG:-}" ]] || ! [[ "$AUTO_ROTATE_LOG" =~ ^[0-1]$ ]]; then
            AUTO_ROTATE_LOG=1
            print_to_terminal "Using default log-rotate: $AUTO_ROTATE_LOG" "DEBUG"
        fi
        
        if [[ -z "${MAX_LOG_SIZE_MB:-}" ]] || ! [[ "$MAX_LOG_SIZE_MB" =~ ^[0-9]+$ ]]; then
            MAX_LOG_SIZE_MB=50
            print_to_terminal "Using default max-log-size: $MAX_LOG_SIZE_MB" "DEBUG"
        fi
        
    else
        print_to_terminal "Config file $CONFIG_FILE not found, using default values" "INFO"
    fi
    
    print_to_terminal "Active Configuration:" "INFO"
    print_to_terminal "  Directory: $DIRECTORY" "INFO"
    print_to_terminal "  Threshold: ${THRESHOLD}%" "INFO"
    print_to_terminal "  Min Files/Dir: $MIN_FILE_COUNT" "INFO"
    print_to_terminal "  Max Delete/Run: $MAX_DELETE_PER_RUN" "INFO"
    print_to_terminal "  Backup Enabled: $([ "$BACKUP_ENABLED" -eq 1 ] && echo "YES ($BACKUP_DIR)" || echo "NO")" "INFO"
    print_to_terminal "  Log File: $LOG_FILE (Max: ${MAX_LOG_SIZE_MB}MB)" "INFO"
    print_to_terminal "  Auto Log Rotation: $([ "$AUTO_ROTATE_LOG" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "  Lock File: $LOCK_FILE" "INFO"
}

# =======================
# VALIDASI RHEL 9
# =======================
check_rhel9_compatibility() {
    if [[ -f /etc/redhat-release ]]; then
        local rhel_version
        rhel_version=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release 2>/dev/null || echo "0")
        local major_version=${rhel_version%%.*}
        
        if [[ "$major_version" -lt 9 ]]; then
            echo "WARNING: Script dioptimasi untuk RHEL 9, versi terdeteksi: $rhel_version"
        fi
    fi
    
    if (( BASH_VERSINFO[0] < 4 )); then
        echo "Error: Membutuhkan bash 4.0+, versi saat ini: ${BASH_VERSION}"
        exit 1
    fi
    
    local required_tools=("find" "sort" "stat" "df" "awk" "mkdir" "rm" "cp")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: Tool '$tool' tidak ditemukan"
            exit 1
        fi
    done
}

# =======================
# LOGIKA UTAMA (BATCH PROCESS)
# =======================
generate_delete_list() {
    print_to_terminal "STEP 2: Mengumpulkan dan mengurutkan file..." "INFO"
    
    # Build find command menggunakan array
    local find_args=("$DIRECTORY" "-type" "f")
    
    # Exclude patterns
    find_args+=("!" "-path" "$LOG_FILE")
    find_args+=("!" "-path" "$LOG_FILE.old")
    find_args+=("!" "-path" "$LOCK_FILE")
    
    if [[ "$BACKUP_ENABLED" -eq 1 ]] && [[ -n "$BACKUP_DIR" ]]; then
        find_args+=("!" "-path" "$BACKUP_DIR/*")
    fi
    
    find_args+=("!" "-path" "*/cdr-cleanup.*.all.*")
    find_args+=("!" "-path" "*/cdr-cleanup.*.delete.*")
    find_args+=("!" "-path" "/tmp/cdr-cleanup.*")
    find_args+=("!" "-path" "/var/tmp/cdr-cleanup.*")
    
    find_args+=("!" "-name" "*.tmp")
    find_args+=("!" "-name" "temp*")
    find_args+=("!" "-name" "*.temp")
    
    if [[ "$INCLUDE_HIDDEN" -eq 0 ]]; then
        find_args+=("!" "-path" "*/.*")
        find_args+=("!" "-name" ".*")
    fi
    
    for pattern in "${DEFAULT_EXCLUDE_PATTERNS[@]}"; do
        find_args+=("!" "-path" "*/${pattern}")
        find_args+=("!" "-name" "${pattern}")
    done
    
    for pattern in "${USER_EXCLUDE_PATTERNS[@]}"; do
        find_args+=("!" "-path" "*/${pattern}")
        find_args+=("!" "-name" "${pattern}")
    done
    
    if [[ "$DEBUG_MODE" -eq 1 ]]; then
        print_to_terminal "Debug: Find command: find ${find_args[*]}" "DEBUG"
    fi
    
    print_to_terminal "Menjalankan find command..." "INFO"
    
    if ! LC_ALL=C find "${find_args[@]}" -printf '%T@|%p\n' 2>/dev/null | \
        sort -t'|' -k1,1n > "$TEMP_ALL_FILES"; then
        
        print_to_terminal "Error: Gagal menjalankan find command" "ERROR"
        return 1
    fi

    local total_found
    total_found=$(wc -l < "$TEMP_ALL_FILES" 2>/dev/null || echo 0)
    
    if [[ "$total_found" -eq 0 ]]; then
        print_to_terminal "Tidak ada file yang ditemukan (setelah exclude patterns)" "INFO"
        return 0
    fi
    
    print_to_terminal "Total file ditemukan (setelah exclude): $total_found" "INFO"
    
    print_to_terminal "Menganalisis struktur directory..." "INFO"
    declare -A dir_counts
    
    while IFS='|' read -r _ filepath; do
        local dirname=$(dirname "$filepath")
        dir_counts["$dirname"]=$(( ${dir_counts["$dirname"]:-0} + 1 ))
        DIR_COUNTS_CACHE["$dirname"]=${dir_counts["$dirname"]}
    done < "$TEMP_ALL_FILES"

    print_to_terminal "STEP 3 & 4: Memfilter list berdasarkan kriteria..." "INFO"
    
    local files_marked_for_delete=0
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - (FILE_AGE_DAYS * 86400)))

    while IFS='|' read -r timestamp_str filepath; do
        if [[ "$files_marked_for_delete" -ge "$MAX_DELETE_PER_RUN" ]]; then
            print_to_terminal "Mencapai batas MAX_DELETE ($MAX_DELETE_PER_RUN), berhenti mencari kandidat." "INFO"
            break
        fi

        local dirname=$(dirname "$filepath")
        local current_count=${dir_counts["$dirname"]:-0}
        
        local file_ts
        if [[ "$timestamp_str" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            file_ts=$(printf "%.0f" "$timestamp_str")
        else
            file_ts=${timestamp_str%%.*}
        fi
        
        local should_delete=0

        if [[ "$current_count" -le "$MIN_FILE_COUNT" ]]; then
            continue
        fi

        if [[ "$ENABLE_AGE_BASED_CLEANUP" -eq 0 ]]; then
            should_delete=1
        else
            if [[ "$file_ts" -lt "$cutoff_time" ]]; then
                should_delete=1
            fi
        fi

        if [[ "$should_delete" -eq 1 ]]; then
            echo "$filepath" >> "$TEMP_DELETE_LIST"
            dir_counts["$dirname"]=$((current_count - 1))
            DIR_COUNTS_CACHE["$dirname"]=$((current_count - 1))
            files_marked_for_delete=$((files_marked_for_delete + 1))
            
            if [[ "$DEBUG_MODE" -eq 1 ]]; then
                local file_age=$(( (current_time - file_ts) / 86400 ))
                print_to_terminal "Debug: Mark for deletion - $filepath (Age: ${file_age}d)" "DEBUG"
            fi
        fi

    done < "$TEMP_ALL_FILES"
    
    print_to_terminal "File yang akan dihapus: $files_marked_for_delete" "INFO"
}

execute_cleanup() {
    print_to_terminal "STEP 5: Menghapus file yang sudah masuk list..." "INFO"

    if [[ ! -s "$TEMP_DELETE_LIST" ]]; then
        print_to_terminal "Tidak ada file yang perlu dihapus." "SUCCESS"
        return 0
    fi

    local count=0
    local errors=0

    while read -r filepath; do
        if [[ "$DRY_RUN" -eq 1 ]]; then
            local age_days=$(get_file_age_days "$filepath")
            print_to_terminal "Would delete: $filepath (Age: $age_days days)" "DRY_RUN"
            count=$((count + 1))
        else
            if safe_delete "$filepath"; then
                count=$((count + 1))
            else
                errors=$((errors + 1))
            fi
        fi
    done < "$TEMP_DELETE_LIST"

    print_to_terminal "Total diproses: $count file. Error: $errors" "INFO"
}

# =======================
# LOCK FILE HANDLING
# =======================
acquire_lock() {
    local lock_file="$1"
    local lock_dir="$(dirname "$lock_file")"
    
    mkdir -p "$lock_dir" 2>/dev/null || true
    
    if ! ( set -o noclobber; echo "$$" > "$lock_file" ) 2>/dev/null; then
        if [[ -f "$lock_file" ]]; then
            local pid
            pid=$(cat "$lock_file" 2>/dev/null || echo "")
            
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                print_to_terminal "Script sudah berjalan dengan PID: $pid" "ERROR"
                return 1
            else
                print_to_terminal "Cleaning stale lock file (PID: ${pid:-unknown})" "WARNING"
                rm -f "$lock_file"
                
                if ! ( set -o noclobber; echo "$$" > "$lock_file" ) 2>/dev/null; then
                    print_to_terminal "Failed to acquire lock after cleanup" "ERROR"
                    return 1
                fi
            fi
        else
            print_to_terminal "Failed to acquire lock" "ERROR"
            return 1
        fi
    fi
    
    print_to_terminal "Lock acquired: $lock_file (PID: $$)" "DEBUG"
    return 0
}

# =======================
# MAIN SCRIPT
# =======================
main() {
    # Buat log directory pertama kali
    mkdir -p "/var/log/cdr-cleanup" 2>/dev/null || {
        echo "Error: Cannot create log directory /var/log/cdr-cleanup"
        exit 1
    }
    
    # Banner
    echo "=== CDR CLEANUP UTILITY FOR RHEL 9 ==="
    echo "Config: $CONFIG_FILE | Log: $LOG_FILE"
    
    # Start logging
    print_to_terminal "=========================================" "HEADER"
    print_to_terminal "🚀 CDR CLEANUP STARTED" "HEADER"
    print_to_terminal "Timestamp: $(get_timestamp_ms)" "INFO"
    print_to_terminal "Arguments: $*" "INFO"
    print_to_terminal "PID: $$" "INFO"
    print_to_terminal "User: $(whoami)" "INFO"
    print_to_terminal "Hostname: $(hostname)" "INFO"
    print_to_terminal "Script: $(realpath "$0" 2>/dev/null || echo "$0")" "INFO"
    print_to_terminal "Config File: $CONFIG_FILE" "INFO"
    print_to_terminal "Log File: $LOG_FILE (Max: ${MAX_LOG_SIZE_MB}MB)" "INFO"
    print_to_terminal "=========================================" "HEADER"
    
    SCRIPT_START_TIME=$(date +%s)
    
    # Parse arguments
    print_to_terminal "STEP 1: Parsing command line arguments..." "INFO"
    parse_arguments "$@"
    
    # Load configuration
    load_config
    
    # Check log rotation
    print_to_terminal "Checking log file size..." "INFO"
    check_and_rotate_log "$LOG_FILE"
    
    # Acquire lock
    if ! acquire_lock "$LOCK_FILE"; then
        print_to_terminal "Cannot proceed, another instance is running or lock issue" "ERROR"
        exit 1
    fi
    
    # Check compatibility
    check_rhel9_compatibility
    
    # Validate inputs
    validate_integer "$THRESHOLD" "THRESHOLD" 1 100
    validate_integer "$MIN_FILE_COUNT" "MIN_FILE_COUNT" 0 100000
    validate_integer "$MAX_DELETE_PER_RUN" "MAX_DELETE_PER_RUN" 1 10000
    
    # Debug configuration
    print_to_terminal "Final Configuration Values:" "INFO"
    print_to_terminal "  MAX_DELETE_PER_RUN: $MAX_DELETE_PER_RUN" "INFO"
    print_to_terminal "  DIRECTORY: $DIRECTORY" "INFO"
    print_to_terminal "  THRESHOLD: $THRESHOLD" "INFO"
    print_to_terminal "  MIN_FILE_COUNT: $MIN_FILE_COUNT" "INFO"
    print_to_terminal "  BACKUP_ENABLED: $BACKUP_ENABLED" "INFO"
    print_to_terminal "  FILE_AGE_DAYS: $FILE_AGE_DAYS" "INFO"
    print_to_terminal "  ENABLE_AGE_BASED_CLEANUP: $ENABLE_AGE_BASED_CLEANUP" "INFO"
    
    # Cleanup old logs
    cleanup_old_logs
    
    # Validate directory
    validate_directory "$DIRECTORY"
    check_security_files "$DIRECTORY"
    
    # Determine mode
    if [[ "$ENABLE_AGE_BASED_CLEANUP" -eq 1 ]]; then
        print_to_terminal "MODE: AGE BASED (Older than $FILE_AGE_DAYS days)" "HEADER"
        print_to_terminal "Logic: Search files > Age Limit, Keep Min $MIN_FILE_COUNT per dir, Max Delete $MAX_DELETE_PER_RUN" "INFO"
        
        generate_delete_list
        execute_cleanup
    else
        local current_usage
        current_usage=$(get_disk_usage "$DIRECTORY")
        
        if [[ -z "$current_usage" ]] || ! [[ "$current_usage" =~ ^[0-9]+$ ]]; then
            print_to_terminal "Error: Gagal mendapatkan disk usage untuk $DIRECTORY" "ERROR"
            exit 1
        fi
        
        print_to_terminal "MODE: DISK THRESHOLD (Current: ${current_usage}%, Threshold: $THRESHOLD%)" "HEADER"
        print_to_terminal "Logic: Remove oldest files until threshold safe or max limit reached." "INFO"

        if [[ "$current_usage" -ge "$THRESHOLD" ]]; then
            print_to_terminal "Disk usage ($current_usage%) > Threshold ($THRESHOLD%). Memulai cleanup..." "WARNING"
            generate_delete_list
            execute_cleanup
            
            local new_usage
            new_usage=$(get_disk_usage "$DIRECTORY")
            if [[ -n "$new_usage" ]] && [[ "$new_usage" =~ ^[0-9]+$ ]]; then
                print_to_terminal "Disk usage after cleanup: $new_usage%" "INFO"
                print_to_terminal "Reduction: $((current_usage - new_usage))%" "INFO"
            fi
        else
            print_to_terminal "Disk usage aman ($current_usage% < $THRESHOLD%). Tidak ada aksi." "SUCCESS"
        fi
    fi
    
    # Completion log
    SCRIPT_END_TIME=$(date +%s)
    local DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
    
    print_to_terminal "Cleanup process completed" "SUCCESS"
    
    # Log size info
    if [[ -f "$LOG_FILE" ]]; then
        local log_size_bytes
        log_size_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        local log_size_mb=$((log_size_bytes / 1024 / 1024))
        local log_size_percent=0
        
        if [[ "$MAX_LOG_SIZE_MB" -gt 0 ]]; then
            log_size_percent=$(( (log_size_bytes * 100) / (MAX_LOG_SIZE_MB * 1024 * 1024) ))
        fi
        
        print_to_terminal "Log file size: ${log_size_mb}MB (${log_size_percent}% of ${MAX_LOG_SIZE_MB}MB limit)" "INFO"
    fi
    
    print_to_terminal "=========================================" "HEADER"
    print_to_terminal "✅ CDR CLEANUP COMPLETED" "HEADER"
    print_to_terminal "Completion Time: $(get_timestamp_ms)" "INFO"
    print_to_terminal "Total Duration: ${DURATION} seconds" "INFO"
    print_to_terminal "Start Time: $(date -d "@$SCRIPT_START_TIME" '+%F %T' 2>/dev/null || echo "$SCRIPT_START_TIME")" "INFO"
    print_to_terminal "End Time: $(date -d "@$SCRIPT_END_TIME" '+%F %T' 2>/dev/null || echo "$SCRIPT_END_TIME")" "INFO"
    
    # Summary
    print_to_terminal "--- SUMMARY ---" "INFO"
    print_to_terminal "Mode: $([ "$ENABLE_AGE_BASED_CLEANUP" -eq 1 ] && echo "AGE-BASED ($FILE_AGE_DAYS days)" || echo "DISK-THRESHOLD ($THRESHOLD%)")" "INFO"
    print_to_terminal "Directory: $DIRECTORY" "INFO"
    print_to_terminal "Dry Run: $([ "$DRY_RUN" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "Backup Enabled: $([ "$BACKUP_ENABLED" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "Debug Mode: $([ "$DEBUG_MODE" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "Include Hidden: $([ "$INCLUDE_HIDDEN" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "Auto Log Rotation: $([ "$AUTO_ROTATE_LOG" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "Max Delete Per Run: $MAX_DELETE_PER_RUN" "INFO"
    print_to_terminal "Min Files Per Dir: $MIN_FILE_COUNT" "INFO"
    
    # Release lock
    rm -f "$LOCK_FILE" 2>/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
