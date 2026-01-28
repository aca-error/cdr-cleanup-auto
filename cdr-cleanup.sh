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
TEMP_ALL_FILES=$(mktemp /var/tmp/cdr_cleanup_all_XXXXXX)
TEMP_DELETE_LIST=$(mktemp /var/tmp/cdr_cleanup_delete_XXXXXX)

# =======================
# FUNGSI LOAD CONFIG
# =======================
load_config() {
    # Jika config file ada, load dari sana
    if [[ -f "$CONFIG_FILE" ]]; then
        print_to_terminal "Loading configuration from $CONFIG_FILE" "INFO"
        
        # Source config file dengan safety check
        if ! source "$CONFIG_FILE" 2>/dev/null; then
            print_to_terminal "Error: Failed to load config file $CONFIG_FILE" "ERROR"
            exit 1
        fi
        
        # Validate loaded variables
        if [[ -z "${DIRECTORY:-}" ]]; then
            print_to_terminal "Warning: DIRECTORY not set in config, using default" "WARNING"
            DIRECTORY="/home/cdrsbx"
        fi
        
        if [[ -z "${THRESHOLD:-}" ]] || ! [[ "$THRESHOLD" =~ ^[0-9]+$ ]]; then
            print_to_terminal "Warning: Invalid THRESHOLD in config, using default 90" "WARNING"
            THRESHOLD=90
        fi
        
        if [[ -z "${MIN_FILE_COUNT:-}" ]] || ! [[ "$MIN_FILE_COUNT" =~ ^[0-9]+$ ]]; then
            print_to_terminal "Warning: Invalid MIN_FILE_COUNT in config, using default 30" "WARNING"
            MIN_FILE_COUNT=30
        fi
        
        if [[ -z "${MAX_DELETE_PER_RUN:-}" ]] || ! [[ "$MAX_DELETE_PER_RUN" =~ ^[0-9]+$ ]]; then
            print_to_terminal "Warning: Invalid MAX_DELETE_PER_RUN in config, using default 100" "WARNING"
            MAX_DELETE_PER_RUN=100
        fi
        
        if [[ -z "${BACKUP_ENABLED:-}" ]] || ! [[ "$BACKUP_ENABLED" =~ ^[0-1]$ ]]; then
            print_to_terminal "Warning: Invalid BACKUP_ENABLED in config, using default 0" "WARNING"
            BACKUP_ENABLED=0
        fi
        
        if [[ -z "${BACKUP_DIR:-}" ]]; then
            print_to_terminal "Warning: BACKUP_DIR not set in config, using default" "WARNING"
            BACKUP_DIR="/home/backup/deleted_files"
        fi
        
        if [[ -z "${MAX_LOG_SIZE_MB:-}" ]] || ! [[ "$MAX_LOG_SIZE_MB" =~ ^[0-9]+$ ]]; then
            print_to_terminal "Warning: Invalid MAX_LOG_SIZE_MB in config, using default 50" "WARNING"
            MAX_LOG_SIZE_MB=50
        fi
        
        if [[ -z "${AUTO_ROTATE_LOG:-}" ]] || ! [[ "$AUTO_ROTATE_LOG" =~ ^[0-1]$ ]]; then
            print_to_terminal "Warning: Invalid AUTO_ROTATE_LOG in config, using default 1" "WARNING"
            AUTO_ROTATE_LOG=1
        fi
    else
        print_to_terminal "Config file $CONFIG_FILE not found, using default values" "INFO"
    fi
    
    # Log configuration
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
    # Cek versi RHEL
    if [[ -f /etc/redhat-release ]]; then
        local rhel_version
        rhel_version=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release 2>/dev/null || echo "0")
        local major_version=${rhel_version%%.*}
        
        if [[ "$major_version" -lt 9 ]]; then
            echo "WARNING: Script dioptimasi untuk RHEL 9, versi terdeteksi: $rhel_version"
        fi
    fi
    
    # Cek bash version (RHEL 9 punya bash 5.1+)
    if (( BASH_VERSINFO[0] < 4 )); then
        echo "Error: Membutuhkan bash 4.0+, versi saat ini: ${BASH_VERSION}"
        exit 1
    fi
    
    # Cek tools yang diperlukan
    local required_tools=("find" "sort" "stat" "df" "awk" "mkdir" "rm" "cp")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: Tool '$tool' tidak ditemukan"
            exit 1
        fi
    done
}

# =======================
# FUNGSI UTAMA
# =======================
cleanup_temp() {
    rm -f "$TEMP_ALL_FILES" "$TEMP_DELETE_LIST"
    rm -f "$LOCK_FILE" 2>/dev/null
}
trap cleanup_temp EXIT

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
    
    # SELALU log ke file (termasuk DEBUG)
    echo "[$timestamp_full] [$level] $message" >> "$LOG_FILE"
    
    # Output ke Terminal (jika interaktif)
    if [[ -t 1 ]]; then
        # Tampilkan DEBUG hanya jika DEBUG_MODE=1
        if [[ "$level" == "DEBUG" ]] && [[ "$DEBUG_MODE" -eq 0 ]]; then
            return  # Skip terminal output untuk DEBUG mode normal
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
    
    # Log ke journald jika tersedia (RHEL 9 feature)
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
    
    # Jika auto rotate disabled, skip
    [[ "${AUTO_ROTATE_LOG:-1}" -eq 0 ]] && return 0
    
    # Cek jika log file ada dan ukurannya melebihi batas
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
    else
        print_to_terminal "Debug: Log file not found: $log_file" "DEBUG"
    fi
}

rotate_log_now() {
    local log_file="$1"
    
    print_to_terminal "Starting manual log rotation..." "INFO"
    
    # Method 1: Gunakan logrotate jika tersedia
    if command -v logrotate >/dev/null 2>&1 && [[ -f "$LOG_ROTATE_CONFIG" ]]; then
        print_to_terminal "Using logrotate command..." "DEBUG"
        
        # Force logrotate dengan config file
        if logrotate -f "$LOG_ROTATE_CONFIG" 2>/dev/null; then
            print_to_terminal "Logrotate command executed successfully" "DEBUG"
            return 0
        else
            print_to_terminal "Logrotate command failed, trying manual method" "WARNING"
        fi
    fi
    
    # Method 2: Manual rotation (fallback)
    print_to_terminal "Using manual rotation method..." "DEBUG"
    
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local rotated_file="${log_file}.${timestamp}"
    
    # Rotate log file
    if cp "$log_file" "$rotated_file" 2>/dev/null; then
        # Truncate original log file
        > "$log_file"
        print_to_terminal "Rotated log saved to: $rotated_file" "INFO"
        
        # Compress rotated file
        if command -v gzip >/dev/null 2>&1; then
            if gzip -f "$rotated_file" 2>/dev/null; then
                print_to_terminal "Rotated log compressed: ${rotated_file}.gz" "DEBUG"
            else
                print_to_terminal "Failed to compress rotated log" "WARNING"
            fi
        fi
        
        # Cleanup old rotated logs (keep last 10)
        cleanup_old_logs
        
        print_to_terminal "Manual log rotation completed" "INFO"
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
        
        # Hapus compressed log files yang lebih tua dari keep_days
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
    
    # Validasi input
    if [[ -z "$dir" ]] || [[ ! -d "$dir" ]]; then
        print_to_terminal "Error: Directory '$dir' tidak valid untuk get_disk_usage" "ERROR"
        echo "0"
        return 1
    fi
    
    # Gunakan df untuk mendapatkan disk usage
    local df_output
    df_output=$(df -P "$dir" 2>/dev/null)
    
    if [[ -z "$df_output" ]]; then
        print_to_terminal "Warning: Gagal mendapatkan disk usage untuk $dir" "WARNING"
        echo "0"
        return 1
    fi
    
    # Parse output - ambil persentase dari kolom ke-5
    local usage
    usage=$(echo "$df_output" | awk 'NR==2 {gsub(/%/, "", $5); print $5}')
    
    # Debug info
    if [[ "$DEBUG_MODE" -eq 1 ]]; then
        print_to_terminal "Debug: df output untuk $dir:" "DEBUG"
        echo "$df_output" | while read -r line; do
            print_to_terminal "Debug: $line" "DEBUG"
        done
        print_to_terminal "Debug: Parsed usage: ${usage}%" "DEBUG"
    fi
    
    # Validasi output
    if [[ -z "$usage" ]] || ! [[ "$usage" =~ ^[0-9]+$ ]]; then
        print_to_terminal "Warning: Nilai disk usage tidak valid: '$usage'" "WARNING"
        echo "0"
        return 1
    fi
    
    echo "$usage"
}

get_file_age_days() {
    local filepath="$1"
    local current_time=$(date +%s)
    if [[ -f "$filepath" ]]; then
        # Gunakan format yang kompatibel dengan RHEL 9
        local file_mtime=$(stat -c %Y "$filepath" 2>/dev/null || echo 0)
        echo $(((current_time - file_mtime) / 86400))
    else
        echo "0"
    fi
}

validate_directory() {
    local dir="$1"
    
    # Cek jika directory ada
    if [[ ! -d "$dir" ]]; then
        print_to_terminal "Error: Directory '$dir' tidak ditemukan" "ERROR"
        exit 1
    fi
    
    # Cek permission
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
    
    # Cek jika mount point valid
    if ! df -P "$dir" >/dev/null 2>&1; then
        print_to_terminal "Warning: Directory '$dir' mungkin bukan mount point yang valid" "WARNING"
    fi
}

check_security_files() {
    local dir="$1"
    
    # Cek jika directory mengandung file security sensitif
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
        if find "$dir" -name "$pattern" -type f 2>/dev/null | head -1 | grep -q .; then
            print_to_terminal "WARNING: Directory mengandung file security-sensitive: $pattern" "WARNING"
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
        # Coba preserve SELinux context
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
    
    # Backup jika enabled
    if [[ "$BACKUP_ENABLED" -eq 1 ]]; then
        backup_file "$filepath"
    fi
    
    # Dry run mode
    if [[ "$DRY_RUN" -eq 1 ]]; then
        local age_days=$(get_file_age_days "$filepath")
        print_to_terminal "Would delete: $filepath (Age: $age_days days)" "DRY_RUN"
        return 0
    fi
    
    # Real delete
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
                          (Hanya berlaku di mode Disk Threshold)
                          
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
    # 1. Simulasi cleanup dengan threshold dari config
    ./$script_name --dry-run

    # 2. Hapus file tua > 180 hari dengan auto log rotation
    ./$script_name --force --age-days=180

    # 3. Cleanup tanpa auto log rotation
    ./$script_name --force --threshold=80 --no-log-rotate

    # 4. Override directory dari config
    ./$script_name --force --directory=/data --threshold=75 --debug

DEFAULT EXCLUDES:
    • Semua hidden files/directories (.*, */.*)
    • User home directories: Desktop, Documents, Downloads, Pictures, Music, Videos
    • Configuration: .config, .local, .cache, .ssh, .gnupg
    • Version control: .git, .svn, .hg
    • Application data: .mozilla, .thunderbird, .vscode
    • Shell files: .bash*, .profile, .zsh*

LOG ROTATION:
    Logrotate config: /etc/logrotate.d/cdr-cleanup
    Auto rotation: ${MAX_LOG_SIZE_MB}MB limit atau monthly

EOF
}

# =======================
# PARSING ARGUMEN
# =======================
parse_arguments() {
    # Array untuk user-defined exclude patterns
    USER_EXCLUDE_PATTERNS=()
    INCLUDE_HIDDEN=0
    
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) DRY_RUN=1; shift ;;
            --force) DRY_RUN=0; shift ;;
            --backup) BACKUP_ENABLED=1; shift ;;
            --no-backup) BACKUP_ENABLED=0; shift ;;
            --threshold=*) THRESHOLD="${1#*=}"; shift ;;
            --max-delete=*) MAX_DELETE_PER_RUN="${1#*=}"; shift ;;
            --min-files=*) MIN_FILE_COUNT="${1#*=}"; shift ;;
            --directory=*) DIRECTORY="${1#*=}"; shift ;;
            --age-days=*) 
                ENABLE_AGE_BASED_CLEANUP=1
                FILE_AGE_DAYS="${1#*=}"
                shift ;;
            --age-months=*) 
                ENABLE_AGE_BASED_CLEANUP=1
                FILE_AGE_DAYS=$(months_to_days "${1#*=}")
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
                AUTO_ROTATE_LOG=0
                shift ;;
            --quiet) 
                # Redefine print_to_terminal untuk quiet mode
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
# LOGIKA UTAMA (BATCH PROCESS)
# =======================
generate_delete_list() {
    print_to_terminal "STEP 2: Mengumpulkan dan mengurutkan file..." "INFO"
    
    # Build find command
    local find_cmd="find \"$DIRECTORY\" -type f"
    
    # Exclude log files dan lock files
    find_cmd+=" ! -path \"$LOG_FILE\" ! -path \"$LOG_FILE.old\""
    find_cmd+=" ! -path \"$LOCK_FILE\""
    
    # Exclude backup directory jika backup enabled
    if [[ "$BACKUP_ENABLED" -eq 1 ]] && [[ -n "$BACKUP_DIR" ]]; then
        find_cmd+=" ! -path \"$BACKUP_DIR/*\""
    fi
    
    # Exclude temporary files dari script ini
    find_cmd+=" ! -path \"*/cdr_cleanup_all_*\" ! -path \"*/cdr_cleanup_delete_*\""
    find_cmd+=" ! -path \"/tmp/cdr_cleanup_*\" ! -path \"/var/tmp/cdr_cleanup_*\""
    
    # Exclude system temp files umum
    find_cmd+=" ! -name \"*.tmp\" ! -name \"temp*\" ! -name \"*.temp\""
    
    # Exclude hidden files/directories kecuali jika --include-hidden
    if [[ "$INCLUDE_HIDDEN" -eq 0 ]]; then
        find_cmd+=" ! -path \"*/.*\" ! -name \".*\""
    fi
    
    # Tambahkan default exclude patterns
    for pattern in "${DEFAULT_EXCLUDE_PATTERNS[@]}"; do
        find_cmd+=" ! -path \"*/${pattern}\" ! -name \"${pattern}\""
    done
    
    # Tambahkan user-defined excludes
    for pattern in "${USER_EXCLUDE_PATTERNS[@]}"; do
        find_cmd+=" ! -path \"*/${pattern}\" ! -name \"${pattern}\""
    done
    
    # Debug logging (selalu ke log file, ke terminal hanya jika debug mode)
    print_to_terminal "Find command: $find_cmd" "DEBUG"
    
    # Execute find command
    print_to_terminal "Menjalankan find command..." "INFO"
    
    if ! eval "LC_ALL=C $find_cmd -printf '%T@|%p\\n' 2>/dev/null" | \
        sort -t'|' -k1,1n > "$TEMP_ALL_FILES"; then
        
        print_to_terminal "Error: Gagal menjalankan find command" "ERROR"
        return 1
    fi

    local total_found
    total_found=$(wc -l < "$TEMP_ALL_FILES" 2>/dev/null || echo 0)
    
    if [[ "$total_found" -eq 0 ]]; then
        print_to_terminal "Tidak ada file yang ditemukan (setelah exclude patterns)" "INFO"
        
        # Debug info jika di debug mode
        if [[ "$DEBUG_MODE" -eq 1 ]]; then
            print_to_terminal "Debug: Mencari semua file termasuk hidden..." "DEBUG"
            find "$DIRECTORY" -type f 2>/dev/null | wc -l | \
                while read count; do 
                    print_to_terminal "Total semua file (termasuk hidden): $count" "DEBUG"; 
                done
        fi
        return 0
    fi
    
    print_to_terminal "Total file ditemukan (setelah exclude): $total_found" "INFO"
    
    # Debug: hitung hidden files yang di-exclude
    if [[ "$DEBUG_MODE" -eq 1 ]] && [[ "$INCLUDE_HIDDEN" -eq 0 ]]; then
        local hidden_count=$(find "$DIRECTORY" -type f -name '.*' 2>/dev/null | wc -l)
        print_to_terminal "Debug: Hidden files yang di-exclude: $hidden_count" "DEBUG"
    fi

    print_to_terminal "Menganalisis struktur directory..." "INFO"
    declare -A dir_counts
    
    # Hitung jumlah file awal per directory
    while IFS='|' read -r _ filepath; do
        local dirname=$(dirname "$filepath")
        dir_counts["$dirname"]=$(( ${dir_counts["$dirname"]:-0} + 1 ))
    done < "$TEMP_ALL_FILES"

    print_to_terminal "STEP 3 & 4: Memfilter list berdasarkan kriteria..." "INFO"
    
    local files_marked_for_delete=0
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - (FILE_AGE_DAYS * 86400)))

    # Loop utama filtering
    while IFS='|' read -r timestamp_str filepath; do
        if [[ "$files_marked_for_delete" -ge "$MAX_DELETE_PER_RUN" ]]; then
            print_to_terminal "Mencapai batas MAX_DELETE ($MAX_DELETE_PER_RUN), berhenti mencari kandidat." "INFO"
            break
        fi

        local dirname=$(dirname "$filepath")
        local current_count=${dir_counts["$dirname"]:-0}
        
        # Convert timestamp dengan rounding yang benar
        local file_ts
        if [[ "$timestamp_str" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            file_ts=$(printf "%.0f" "$timestamp_str")
        else
            file_ts=${timestamp_str%%.*}
        fi
        
        local should_delete=0

        # Cek Kriteria MIN_FILES (Global Rule)
        if [[ "$current_count" -le "$MIN_FILE_COUNT" ]]; then
            continue
        fi

        # [STEP 3] DISK BASED
        if [[ "$ENABLE_AGE_BASED_CLEANUP" -eq 0 ]]; then
            should_delete=1 # Hapus terlama karena min files aman
        
        # [STEP 4] AGE BASED
        else
            if [[ "$file_ts" -lt "$cutoff_time" ]]; then
                should_delete=1
            else
                should_delete=0
            fi
        fi

        if [[ "$should_delete" -eq 1 ]]; then
            echo "$filepath" >> "$TEMP_DELETE_LIST"
            dir_counts["$dirname"]=$((current_count - 1))
            files_marked_for_delete=$((files_marked_for_delete + 1))
            
            # Debug logging untuk file yang akan dihapus
            if [[ "$DEBUG_MODE" -eq 1 ]]; then
                local file_age=$(( (current_time - file_ts) / 86400 ))
                print_to_terminal "Debug: Mark for deletion - $filepath (Age: ${file_age}d, Dir: $dirname, Count: $current_count)" "DEBUG"
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
# MAIN SCRIPT
# =======================
main() {
    # Banner
    echo "=== CDR CLEANUP UTILITY FOR RHEL 9 ==="
    echo "Config: $CONFIG_FILE | Log: $LOG_FILE"
    
    # ============================================
    # START LOG & AUTO ROTATION CHECK
    # ============================================
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
    
    # Start time untuk menghitung duration
    local START_TIME
    START_TIME=$(date +%s)
    print_to_terminal "Start Time (Unix timestamp): $START_TIME" "DEBUG"
    
    # Cek kompatibilitas RHEL 9
    check_rhel9_compatibility
    
    # Setup directories
    mkdir -p "/var/log/cdr-cleanup" 2>/dev/null || {
        echo "Error: Cannot create log directory /var/log/cdr-cleanup"
        exit 1
    }
    
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
    
    parse_arguments "$@"
    
    # Load configuration
    load_config
    
    # Check and rotate log if needed (sebelum validasi lain)
    print_to_terminal "Checking log file size..." "INFO"
    check_and_rotate_log "$LOG_FILE"
    
    # Validasi input
    if [[ "$THRESHOLD" -lt 1 ]] || [[ "$THRESHOLD" -gt 100 ]]; then
        print_to_terminal "Error: Threshold harus antara 1-100%" "ERROR"
        exit 1
    fi
    
    if [[ "$MIN_FILE_COUNT" -lt 0 ]]; then
        print_to_terminal "Error: MIN_FILE_COUNT tidak boleh negatif" "ERROR"
        exit 1
    fi
    
    if [[ "$MAX_DELETE_PER_RUN" -lt 1 ]]; then
        print_to_terminal "Error: MAX_DELETE_PER_RUN minimal 1" "ERROR"
        exit 1
    fi
    
    # Cleanup old logs
    cleanup_old_logs
    
    # Validasi directory
    validate_directory "$DIRECTORY"
    check_security_files "$DIRECTORY"
    
    # Lock file untuk mencegah multiple execution
    if ! ( set -o noclobber; echo "$$" > "$LOCK_FILE" ) 2>/dev/null; then
        if [[ -f "$LOCK_FILE" ]]; then
            local pid=$(cat "$LOCK_FILE" 2>/dev/null)
            if kill -0 "$pid" 2>/dev/null; then
                print_to_terminal "Script sudah berjalan dengan PID: $pid" "ERROR"
                print_to_terminal "Exiting..." "INFO"
                exit 0
            else
                # Stale lock file
                rm -f "$LOCK_FILE"
                echo "$$" > "$LOCK_FILE"
                print_to_terminal "Cleaned stale lock file, proceeding..." "WARNING"
            fi
        fi
    fi
    
    # Tambah trap untuk cleanup lock file
    trap 'rm -f "$LOCK_FILE" 2>/dev/null' EXIT
    print_to_terminal "Lock file created: $LOCK_FILE" "DEBUG"
    
    # Test disk usage
    print_to_terminal "Testing disk usage for directory: $DIRECTORY" "DEBUG"
    local test_usage
    test_usage=$(get_disk_usage "$DIRECTORY")
    print_to_terminal "Test disk usage result: ${test_usage}%" "DEBUG"
    
    # [STEP 1] LIHAT OPSINYA
    if [[ "$ENABLE_AGE_BASED_CLEANUP" -eq 1 ]]; then
        # === MODE AGE BASED ===
        print_to_terminal "MODE: AGE BASED (Older than $FILE_AGE_DAYS days)" "HEADER"
        print_to_terminal "Exclude patterns aktif: Hidden files & user directories" "INFO"
        print_to_terminal "Logic: Search files > Age Limit, Keep Min $MIN_FILE_COUNT per dir, Max Delete $MAX_DELETE_PER_RUN" "INFO"
        
        generate_delete_list
        execute_cleanup
    else
        # === MODE DISK THRESHOLD ===
        local current_usage
        current_usage=$(get_disk_usage "$DIRECTORY")
        
        # Validasi current_usage
        if [[ -z "$current_usage" ]] || ! [[ "$current_usage" =~ ^[0-9]+$ ]]; then
            print_to_terminal "Error: Gagal mendapatkan disk usage untuk $DIRECTORY" "ERROR"
            print_to_terminal "Current usage value: '$current_usage'" "DEBUG"
            exit 1
        fi
        
        print_to_terminal "MODE: DISK THRESHOLD (Current: ${current_usage}%, Threshold: $THRESHOLD%)" "HEADER"
        print_to_terminal "Exclude patterns aktif: Hidden files & user directories" "INFO"
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
            else
                print_to_terminal "Disk usage after cleanup: N/A" "WARNING"
            fi
        else
            print_to_terminal "Disk usage aman ($current_usage% < $THRESHOLD%). Tidak ada aksi." "SUCCESS"
        fi
    fi
    
    # ============================================
    # END LOG dengan summary
    # ============================================
    local END_TIME
    END_TIME=$(date +%s)
    local DURATION=$((END_TIME - START_TIME))
    
    print_to_terminal "Cleanup process completed" "SUCCESS"
    
    # Tambah log size info di summary
    if [[ -f "$LOG_FILE" ]]; then
        local log_size_bytes
        log_size_bytes=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        local log_size_mb=$((log_size_bytes / 1024 / 1024))
        local log_size_percent=0
        
        if [[ "$MAX_LOG_SIZE_MB" -gt 0 ]]; then
            log_size_percent=$(( (log_size_bytes * 100) / (MAX_LOG_SIZE_MB * 1024 * 1024) ))
        fi
        
        print_to_terminal "Log file size: ${log_size_mb}MB (${log_size_percent}% of ${MAX_LOG_SIZE_MB}MB limit)" "INFO"
        
        if [[ "$log_size_percent" -ge 80 ]] && [[ "$log_size_percent" -lt 100 ]]; then
            print_to_terminal "Note: Log file approaching size limit" "INFO"
        elif [[ "$log_size_percent" -ge 100 ]]; then
            print_to_terminal "Warning: Log file at or over size limit" "WARNING"
        fi
    fi
    
    print_to_terminal "=========================================" "HEADER"
    print_to_terminal "✅ CDR CLEANUP COMPLETED" "HEADER"
    print_to_terminal "Completion Time: $(get_timestamp_ms)" "INFO"
    print_to_terminal "Total Duration: ${DURATION} seconds" "INFO"
    print_to_terminal "Start Time: $(date -d "@$START_TIME" '+%F %T' 2>/dev/null || echo "$START_TIME")" "INFO"
    print_to_terminal "End Time: $(date -d "@$END_TIME" '+%F %T' 2>/dev/null || echo "$END_TIME")" "INFO"
    
    # Summary statistics
    print_to_terminal "--- SUMMARY ---" "INFO"
    print_to_terminal "Mode: $([ "$ENABLE_AGE_BASED_CLEANUP" -eq 1 ] && echo "AGE-BASED ($FILE_AGE_DAYS days)" || echo "DISK-THRESHOLD ($THRESHOLD%)")" "INFO"
    print_to_terminal "Directory: $DIRECTORY" "INFO"
    print_to_terminal "Dry Run: $([ "$DRY_RUN" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "Backup Enabled: $([ "$BACKUP_ENABLED" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "Debug Mode: $([ "$DEBUG_MODE" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "Include Hidden: $([ "$INCLUDE_HIDDEN" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    print_to_terminal "Auto Log Rotation: $([ "$AUTO_ROTATE_LOG" -eq 1 ] && echo "YES" || echo "NO")" "INFO"
    
    # Log file info
    if [[ -f "$LOG_FILE" ]]; then
        local log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "N/A")
        print_to_terminal "Log File: $LOG_FILE (Size: $log_size bytes)" "INFO"
    fi
    
    print_to_terminal "Exit Code: 0" "INFO"
    print_to_terminal "=========================================" "HEADER"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
