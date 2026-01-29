#!/bin/bash
set -o nounset -o pipefail -o errexit

# =======================
# KONFIGURASI DEFAULT
# =======================
CONFIG_FILE="/etc/cdr-cleanup.conf"
LOG_FILE="/var/log/cdr-cleanup/cdr-cleanup.log"
LOCK_FILE="/var/lock/cdr-cleanup.lock"
LOG_ROTATE_CONFIG="/etc/logrotate.d/cdr-cleanup"

# Default values
DIRECTORY="/home/cdrsbx"
THRESHOLD=90
MAX_LOG_SIZE_MB=50
MIN_FILE_COUNT=30
MAX_DELETE_PER_RUN=100
BACKUP_ENABLED=0
BACKUP_DIR="/home/backup/deleted_files"
AUTO_ROTATE_LOG=1

DRY_RUN=1
DEBUG_MODE=0

# =======================
# KONFIGURASI UMUR FILE
# =======================
ENABLE_AGE_BASED_CLEANUP=0
DEFAULT_FILE_AGE_DAYS=180
FILE_AGE_DAYS="$DEFAULT_FILE_AGE_DAYS"
FILE_AGE_SECONDS=$((FILE_AGE_DAYS * 24 * 60 * 60))

# Mode tracking
MODE="DISK_THRESHOLD"  # Default mode

# =======================
# DEFAULT EXCLUDE PATTERNS
# =======================
DEFAULT_EXCLUDE_PATTERNS=(
    '.*' '*/.*'
    '*/Desktop/*' '*/Documents/*' '*/Downloads/*' '*/Pictures/*'
    '*/Music/*' '*/Videos/*' '*/Public/*' '*/Templates/*'
    '*/\.config/*' '*/\.local/*' '*/\.cache/*'
    '*/\.ssh/*' '*/\.gnupg/*' '*/\.pki/*'
    '*/\.git/*' '*/\.svn/*' '*/\.hg/*'
    '*/\.mozilla/*' '*/\.thunderbird/*' '*/\.google-chrome/*'
    '*/\.vscode/*' '*/\.bash*' '*/\.profile' '*/\.zsh*'
    '*/\.history*' 'lost+found' '*/lost+found/*'
    '*~' '*.swp' '*.swo' '*.tmp' '*.temp'
)

# =======================
# SETUP UTILITAS
# =======================
TEMP_ALL_FILES=$(mktemp "/tmp/cdr-cleanup.$$.all.XXXXXX")
TEMP_DELETE_LIST=$(mktemp "/tmp/cdr-cleanup.$$.delete.XXXXXX")
TEMP_BATCH_LIST=$(mktemp "/tmp/cdr-cleanup.$$.batch.XXXXXX")

# =======================
# FLAG UNTUK TRACKING ARGUMENTS
# =======================
ARG_DIRECTORY_SET=0
ARG_THRESHOLD_SET=0
ARG_MAX_DELETE_SET=0
ARG_MIN_FILES_SET=0
ARG_BACKUP_SET=0
ARG_LOG_ROTATE_SET=0
ARG_AGE_DAYS_SET=0
ARG_AGE_MONTHS_SET=0

# =======================
# GLOBAL VARIABLES
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

validate_mutual_exclusive() {
    local mode_count=0
    
    if [[ "$ARG_THRESHOLD_SET" -eq 1 ]]; then
        mode_count=$((mode_count + 1))
        MODE="DISK_THRESHOLD"
    fi
    
    if [[ "$ARG_AGE_DAYS_SET" -eq 1 ]]; then
        mode_count=$((mode_count + 1))
        MODE="AGE_DAYS"
    fi
    
    if [[ "$ARG_AGE_MONTHS_SET" -eq 1 ]]; then
        mode_count=$((mode_count + 1))
        MODE="AGE_MONTHS"
    fi
    
    # Validasi hanya satu mode yang aktif
    if [[ "$mode_count" -gt 1 ]]; then
        print_to_terminal "Error: Opsi --threshold, --age-days, dan --age-months tidak bisa digunakan bersamaan" "ERROR"
        print_to_terminal "Pilih salah satu mode:" "ERROR"
        print_to_terminal "  --threshold=N    : Hapus file hingga disk usage < N%" "ERROR"
        print_to_terminal "  --age-days=N     : Hapus file lebih tua dari N hari" "ERROR"
        print_to_terminal "  --age-months=N   : Hapus file lebih tua dari N bulan" "ERROR"
        exit 1
    fi
    
    # Jika tidak ada mode yang ditentukan, gunakan default (disk threshold)
    if [[ "$mode_count" -eq 0 ]]; then
        MODE="DISK_THRESHOLD"
        print_to_terminal "No mode specified, using default: Disk Threshold (${THRESHOLD}%)" "INFO"
    fi
    
    return 0
}

# =======================
# FUNGSI UTAMA
# =======================
cleanup_temp() {
    rm -f "$TEMP_ALL_FILES" "$TEMP_DELETE_LIST" "$TEMP_BATCH_LIST"
    rm -f "$LOCK_FILE" 2>/dev/null
}

handle_exit() {
    local exit_code=$?
    SCRIPT_END_TIME=$(date +%s)
    
    if [[ $exit_code -ne 0 ]] && [[ $exit_code -ne 130 ]]; then
        print_to_terminal "Script terminated with error/signal (Code: $exit_code)" "ERROR"
    elif [[ $exit_code -eq 130 ]]; then
        print_to_terminal "Script interrupted by user (SIGINT)" "WARNING"
    fi
    
    if [[ -n "${SCRIPT_START_TIME:-}" ]]; then
        local DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
        print_to_terminal "Execution duration: ${DURATION} seconds" "INFO"
    fi
    
    cleanup_temp
    exit $exit_code
}

trap handle_exit EXIT INT TERM HUP

get_timestamp_ms() {
    date '+%F %T.%3N'
}

get_time_only_ms() {
    date '+%H:%M:%S.%3N'
}

print_to_terminal() {
    local message="$1"
    local level="${2:-INFO}"
    local timestamp_full=$(get_timestamp_ms)
    local timestamp_short=$(get_time_only_ms)
    
    echo "[$timestamp_full] [$level] $message" >> "$LOG_FILE"
    
    if [[ -t 1 ]]; then
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
# PARSING ARGUMEN DENGAN VALIDASI MUTUAL EXCLUSIVE
# =======================
parse_arguments() {
    USER_EXCLUDE_PATTERNS=()
    INCLUDE_HIDDEN=0
    
    # Parse arguments pertama
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
                FILE_AGE_DAYS="${1#*=}"; ARG_AGE_DAYS_SET=1
                validate_integer "$FILE_AGE_DAYS" "--age-days" 1 36500
                ENABLE_AGE_BASED_CLEANUP=1
                shift ;;
                
            --age-months=*) 
                local months="${1#*=}"; ARG_AGE_MONTHS_SET=1
                validate_integer "$months" "--age-months" 1 1200
                FILE_AGE_DAYS=$(months_to_days "$months")
                ENABLE_AGE_BASED_CLEANUP=1
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
    
    # Validasi mutual exclusivity setelah semua argument diparsing
    validate_mutual_exclusive
    
    return 0
}

# =======================
# LOAD CONFIGURATION FILE - DIPERBAIKI LAGI
# =======================
load_config_file() {
    local config_file="$1"
    
    if [[ ! -f "$config_file" ]]; then
        print_to_terminal "Config file not found: $config_file" "WARNING"
        return 0
    fi
    
    print_to_terminal "Loading configuration from $config_file" "INFO"
    
    # Gunakan approach yang lebih aman untuk membaca config
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        # Skip comments and empty lines
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        
        # Trim whitespace dan quotes dari key
        key=$(echo "$key" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        
        # Trim whitespace dan quotes dari value
        value=$(echo "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
        
        # Skip jika key kosong
        [[ -z "$key" ]] && continue
        
        # Debug logging jika perlu
        if [[ "$DEBUG_MODE" -eq 1 ]]; then
            print_to_terminal "Config: $key='$value'" "DEBUG"
        fi
        
        # Hanya load nilai jika belum di-set via command line
        case "$key" in
            DIRECTORY)
                if [[ "$ARG_DIRECTORY_SET" -eq 0 ]] && [[ -n "$value" ]]; then
                    DIRECTORY="$value"
                fi
                ;;
            THRESHOLD)
                if [[ "$ARG_THRESHOLD_SET" -eq 0 ]] && [[ -n "$value" ]]; then
                    THRESHOLD="$value"
                fi
                ;;
            MAX_DELETE_PER_RUN)
                if [[ "$ARG_MAX_DELETE_SET" -eq 0 ]] && [[ -n "$value" ]]; then
                    MAX_DELETE_PER_RUN="$value"
                fi
                ;;
            MIN_FILE_COUNT)
                if [[ "$ARG_MIN_FILES_SET" -eq 0 ]] && [[ -n "$value" ]]; then
                    MIN_FILE_COUNT="$value"
                fi
                ;;
            BACKUP_ENABLED)
                if [[ "$ARG_BACKUP_SET" -eq 0 ]] && [[ -n "$value" ]]; then
                    BACKUP_ENABLED="$value"
                fi
                ;;
            AUTO_ROTATE_LOG)
                if [[ "$ARG_LOG_ROTATE_SET" -eq 0 ]] && [[ -n "$value" ]]; then
                    AUTO_ROTATE_LOG="$value"
                fi
                ;;
            FILE_AGE_DAYS)
                if [[ "$ARG_AGE_DAYS_SET" -eq 0 ]] && [[ "$ARG_AGE_MONTHS_SET" -eq 0 ]] && [[ -n "$value" ]]; then
                    FILE_AGE_DAYS="$value"
                fi
                ;;
            LOG_FILE)
                if [[ -n "$value" ]]; then
                    LOG_FILE="$value"
                fi
                ;;
            BACKUP_DIR)
                if [[ -n "$value" ]]; then
                    BACKUP_DIR="$value"
                fi
                ;;
            MAX_LOG_SIZE_MB)
                if [[ -n "$value" ]]; then
                    MAX_LOG_SIZE_MB="$value"
                fi
                ;;
            DEBUG_MODE)
                if [[ -n "$value" ]]; then
                    DEBUG_MODE="$value"
                fi
                ;;
            # Handle other variables safely
            *)
                # Only set if it's a valid variable name
                if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && [[ -n "$value" ]]; then
                    # Use printf untuk menghindari interpretasi khusus
                    printf -v "$key" '%s' "$value"
                fi
                ;;
        esac
    done < "$config_file"
    
    # Update calculated values setelah semua config di-load
    FILE_AGE_SECONDS=$((FILE_AGE_DAYS * 24 * 60 * 60))
    
    # Debug output untuk memverifikasi
    if [[ "$DEBUG_MODE" -eq 1 ]]; then
        print_to_terminal "After config load:" "DEBUG"
        print_to_terminal "  DIRECTORY='$DIRECTORY'" "DEBUG"
        print_to_terminal "  THRESHOLD='$THRESHOLD'" "DEBUG"
        print_to_terminal "  MAX_DELETE_PER_RUN='$MAX_DELETE_PER_RUN'" "DEBUG"
        print_to_terminal "  MIN_FILE_COUNT='$MIN_FILE_COUNT'" "DEBUG"
    fi
    
    return 0
}

# =======================
# HELP & USAGE
# =======================
show_help() {
    local script_name
    script_name=$(basename "${0}")
    
    cat << EOF
CDR CLEANUP UTILITY FOR RHEL 9
--------------------------------
Script ini menghapus file lama dengan dua mode yang saling eksklusif:

MODE 1: DISK THRESHOLD (Default)
    Hapus file terlama hingga disk usage di bawah threshold.
    Opsi: --threshold=N (1-100)

MODE 2: AGE BASED
    Hapus semua file yang lebih tua dari N hari/bulan.
    Opsi: --age-days=N ATAU --age-months=N

❗ PERHATIAN: Mode-mode di atas TIDAK BISA digunakan bersamaan.
    Pilih salah satu: --threshold ATAU --age-days ATAU --age-months

CONFIGURATION:
    Main config: /etc/cdr-cleanup.conf
    Log file: /var/log/cdr-cleanup/cdr-cleanup.log
    Lock file: /var/lock/cdr-cleanup.lock

USAGE:
    ./$script_name [OPTIONS]

OPTIONS UTAMA (PILIH SALAH SATU):
    --threshold=N         Batas disk usage (1-100%). Mode: Disk Threshold.
    --age-days=N          Hapus file > N hari. Mode: Age Based.
    --age-months=N        Hapus file > N bulan. Mode: Age Based.

OPTIONS TAMBAHAN:
    --dry-run             Simulasi saja (Default).
    --force               Jalankan penghapusan secara nyata.
    --directory=PATH      Target direktori.
    --min-files=N         Minimum file per folder (0-100000).
    --max-delete=N        Maksimum file dihapus per run (1-10000).
    --exclude=PATTERN     Tambah pattern exclude.
    --include-hidden      Include hidden files.
    --backup              Backup sebelum hapus.
    --no-backup           Nonaktifkan backup.
    --debug               Tampilkan debug messages.
    --quiet               Matikan output terminal.
    --config=FILE         Config file alternatif.
    --no-log-rotate       Nonaktifkan auto log rotation.
    --help                Tampilkan bantuan.

CONTOH MODE DISK THRESHOLD:
    # Cleanup hingga disk usage < 85%
    ./$script_name --force --threshold=85
    
    # Dengan parameter tambahan
    ./$script_name --force --threshold=80 --max-delete=500 --min-files=10

CONTOH MODE AGE BASED:
    # Hapus file > 180 hari
    ./$script_name --force --age-days=180
    
    # Hapus file > 6 bulan
    ./$script_name --force --age-months=6

CONTOH TIDAK VALID (ERROR):
    ./$script_name --threshold=85 --age-days=180  # ❌ TIDAK BISA BERSAMAAN
    ./$script_name --age-days=90 --age-months=3   # ❌ TIDAK BISA BERSAMAAN

FEATURES:
- Iterative disk checking untuk mode threshold
- File age cache untuk performance
- Safety limits: max delete per run, min files per dir
- Auto log rotation
- Lock file untuk prevent multiple execution

EOF
}

# =======================
# FUNGSI LOG ROTATION
# =======================
check_and_rotate_log() {
    local log_file="$1"
    local max_size_mb="${MAX_LOG_SIZE_MB:-50}"
    local max_size_bytes=$((max_size_mb * 1024 * 1024))
    
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
        fi
    fi
}

rotate_log_now() {
    local log_file="$1"
    
    print_to_terminal "Starting manual log rotation..." "INFO"
    
    if command -v logrotate >/dev/null 2>&1 && [[ -f "$LOG_ROTATE_CONFIG" ]]; then
        if logrotate -f "$LOG_ROTATE_CONFIG" 2>/dev/null; then
            return 0
        fi
    fi
    
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local rotated_file="${log_file}.${timestamp}"
    
    if cp "$log_file" "$rotated_file" 2>/dev/null; then
        > "$log_file"
        print_to_terminal "Rotated log saved to: $rotated_file" "INFO"
        
        if command -v gzip >/dev/null 2>&1; then
            gzip -f "$rotated_file" 2>/dev/null || true
        fi
        
        return 0
    else
        print_to_terminal "Failed to rotate log file" "ERROR"
        return 1
    fi
}

months_to_days() {
    local months="$1"
    echo $((months * 30))
}

get_disk_usage() {
    local dir="$1"
    
    if [[ -z "$dir" ]] || [[ ! -d "$dir" ]]; then
        print_to_terminal "Error: Directory '$dir' tidak valid" "ERROR"
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
    
    if [[ -z "$usage" ]] || ! [[ "$usage" =~ ^[0-9]+$ ]]; then
        echo "0"
        return 1
    fi
    
    echo "$usage"
}

get_file_age_days() {
    local filepath="$1"
    
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

# =======================
# ITERATIVE DISK THRESHOLD CLEANUP
# =======================
perform_disk_threshold_cleanup() {
    print_to_terminal "Starting DISK THRESHOLD cleanup..." "INFO"
    print_to_terminal "Target: Disk usage < ${THRESHOLD}%" "INFO"
    print_to_terminal "Max files to delete: $MAX_DELETE_PER_RUN" "INFO"
    print_to_terminal "Min files per directory: $MIN_FILE_COUNT" "INFO"
    
    local current_usage
    current_usage=$(get_disk_usage "$DIRECTORY")
    local initial_usage="$current_usage"
    
    if [[ "$current_usage" -eq 0 ]]; then
        print_to_terminal "Error: Cannot get disk usage for $DIRECTORY" "ERROR"
        return 1
    fi
    
    print_to_terminal "Current disk usage: ${current_usage}%" "INFO"
    
    if [[ "$current_usage" -lt "$THRESHOLD" ]]; then
        print_to_terminal "Disk usage already below threshold ($current_usage% < $THRESHOLD%). No action needed." "SUCCESS"
        return 0
    fi
    
    # Generate initial file list (oldest first)
    if ! generate_all_files_list; then
        print_to_terminal "Failed to generate file list" "ERROR"
        return 1
    fi
    
    local iteration=1
    local total_deleted=0
    
    # ITERATIVE LOOP: Hentikan saat threshold tercapai atau max delete tercapai
    while [[ "$current_usage" -ge "$THRESHOLD" ]] && [[ "$total_deleted" -lt "$MAX_DELETE_PER_RUN" ]]; do
        print_to_terminal "--- Iteration $iteration ---" "INFO"
        print_to_terminal "Current: ${current_usage}%, Target: <${THRESHOLD}%" "INFO"
        print_to_terminal "Remaining delete quota: $((MAX_DELETE_PER_RUN - total_deleted)) files" "INFO"
        
        # Calculate adaptive batch size
        local batch_size=50
        local remaining_to_target=$((current_usage - THRESHOLD))
        
        if [[ "$remaining_to_target" -lt 3 ]]; then
            batch_size=10
        elif [[ "$remaining_to_target" -lt 10 ]]; then
            batch_size=25
        fi
        
        # Adjust based on remaining quota
        if [[ $batch_size -gt $((MAX_DELETE_PER_RUN - total_deleted)) ]]; then
            batch_size=$((MAX_DELETE_PER_RUN - total_deleted))
        fi
        
        if [[ $batch_size -eq 0 ]]; then
            print_to_terminal "Reached maximum delete limit" "WARNING"
            break
        fi
        
        print_to_terminal "Processing batch of $batch_size files..." "INFO"
        
        # Get next batch of files to delete
        local batch_deleted
        batch_deleted=$(get_next_batch "$batch_size")
        
        if [[ "$batch_deleted" -eq 0 ]]; then
            print_to_terminal "No more files eligible for deletion (min files per dir constraint)" "INFO"
            break
        fi
        
        # Delete the batch
        local actual_deleted
        actual_deleted=$(delete_batch)
        total_deleted=$((total_deleted + actual_deleted))
        
        # Get updated disk usage SETELAH menghapus batch
        local previous_usage="$current_usage"
        current_usage=$(get_disk_usage "$DIRECTORY")
        
        print_to_terminal "Batch result: Deleted $actual_deleted files" "INFO"
        print_to_terminal "Disk usage: ${previous_usage}% → ${current_usage}%" "INFO"
        
        # Check if we've reached threshold
        if [[ "$current_usage" -lt "$THRESHOLD" ]]; then
            print_to_terminal "✓ Threshold reached! ($current_usage% < $THRESHOLD%)" "SUCCESS"
            break
        fi
        
        iteration=$((iteration + 1))
        
        # Small delay to allow filesystem updates
        sleep 1
    done
    
    # Final report
    local final_reduction=$((initial_usage - current_usage))
    print_to_terminal "=== DISK THRESHOLD CLEANUP COMPLETE ===" "SUCCESS"
    print_to_terminal "Initial disk usage: ${initial_usage}%" "INFO"
    print_to_terminal "Final disk usage: ${current_usage}%" "INFO"
    print_to_terminal "Reduction: ${final_reduction}%" "INFO"
    print_to_terminal "Total files deleted: ${total_deleted}" "INFO"
    print_to_terminal "Iterations: $((iteration - 1))" "INFO"
    
    if [[ "$current_usage" -ge "$THRESHOLD" ]]; then
        print_to_terminal "Note: Still above threshold after deleting ${total_deleted} files" "WARNING"
        if [[ "$total_deleted" -eq "$MAX_DELETE_PER_RUN" ]]; then
            print_to_terminal "Maximum delete limit ($MAX_DELETE_PER_RUN) reached" "INFO"
        fi
    fi
    
    return 0
}

# =======================
# AGE BASED CLEANUP
# =======================
perform_age_based_cleanup() {
    print_to_terminal "Starting AGE BASED cleanup..." "INFO"
    print_to_terminal "Target: Files older than ${FILE_AGE_DAYS} days" "INFO"
    print_to_terminal "Max files to delete: $MAX_DELETE_PER_RUN" "INFO"
    print_to_terminal "Min files per directory: $MIN_FILE_COUNT" "INFO"
    
    # Generate file list
    if ! generate_all_files_list; then
        print_to_terminal "Failed to generate file list" "ERROR"
        return 1
    fi
    
    local current_time=$(date +%s)
    local cutoff_time=$((current_time - (FILE_AGE_DAYS * 86400)))
    local total_eligible=0
    local total_deleted=0
    
    # Count eligible files
    while IFS='|' read -r timestamp_str filepath; do
        local dirname=$(dirname "$filepath")
        local current_count=${DIR_COUNTS_CACHE["$dirname"]:-0}
        
        if [[ "$current_count" -le "$MIN_FILE_COUNT" ]]; then
            continue
        fi
        
        local file_ts
        if [[ "$timestamp_str" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            file_ts=$(printf "%.0f" "$timestamp_str")
        else
            file_ts=${timestamp_str%%.*}
        fi
        
        if [[ "$file_ts" -lt "$cutoff_time" ]]; then
            total_eligible=$((total_eligible + 1))
        fi
    done < "$TEMP_ALL_FILES"
    
    print_to_terminal "Found $total_eligible files older than $FILE_AGE_DAYS days" "INFO"
    
    if [[ "$total_eligible" -eq 0 ]]; then
        print_to_terminal "No files meet the age criteria" "INFO"
        return 0
    fi
    
    # Select files for deletion
    > "$TEMP_DELETE_LIST"
    
    while IFS='|' read -r timestamp_str filepath && [[ $total_deleted -lt $MAX_DELETE_PER_RUN ]]; do
        local dirname=$(dirname "$filepath")
        local current_count=${DIR_COUNTS_CACHE["$dirname"]:-0}
        
        if [[ "$current_count" -le "$MIN_FILE_COUNT" ]]; then
            continue
        fi
        
        local file_ts
        if [[ "$timestamp_str" =~ ^[0-9]+\.?[0-9]*$ ]]; then
            file_ts=$(printf "%.0f" "$timestamp_str")
        else
            file_ts=${timestamp_str%%.*}
        fi
        
        if [[ "$file_ts" -lt "$cutoff_time" ]]; then
            echo "$filepath" >> "$TEMP_DELETE_LIST"
            DIR_COUNTS_CACHE["$dirname"]=$((current_count - 1))
            total_deleted=$((total_deleted + 1))
        fi
    done < "$TEMP_ALL_FILES"
    
    # Process deletions
    if [[ -s "$TEMP_DELETE_LIST" ]]; then
        local count=0
        local errors=0
        
        while read -r filepath; do
            if [[ "$DRY_RUN" -eq 1 ]]; then
                local age_days=$(get_file_age_days "$filepath")
                print_to_terminal "Would delete: $filepath (Age: $age_days days)" "DRY_RUN"
                count=$((count + 1))
            else
                if rm -f -- "$filepath"; then
                    print_to_terminal "Deleted: $filepath" "SUCCESS"
                    count=$((count + 1))
                else
                    print_to_terminal "Failed to delete: $filepath" "ERROR"
                    errors=$((errors + 1))
                fi
            fi
        done < "$TEMP_DELETE_LIST"
        
        print_to_terminal "=== AGE BASED CLEANUP COMPLETE ===" "SUCCESS"
        print_to_terminal "Files deleted: $count" "INFO"
        print_to_terminal "Errors: $errors" "INFO"
        print_to_terminal "Remaining eligible files: $((total_eligible - count))" "INFO"
    else
        print_to_terminal "No files selected for deletion" "INFO"
    fi
    
    return 0
}

# =======================
# SUPPORTING FUNCTIONS
# =======================
generate_all_files_list() {
    print_to_terminal "Generating file list (sorted by age, oldest first)..." "INFO"
    
    local find_args=("$DIRECTORY" "-type" "f")
    
    find_args+=("!" "-path" "$LOG_FILE")
    find_args+=("!" "-path" "$LOG_FILE.old")
    find_args+=("!" "-path" "$LOCK_FILE")
    
    if [[ "$BACKUP_ENABLED" -eq 1 ]] && [[ -n "$BACKUP_DIR" ]]; then
        find_args+=("!" "-path" "$BACKUP_DIR/*")
    fi
    
    find_args+=("!" "-path" "*/cdr-cleanup.*")
    
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
    
    if ! LC_ALL=C find "${find_args[@]}" -printf '%T@|%p\n' 2>/dev/null | \
        sort -t'|' -k1,1n > "$TEMP_ALL_FILES"; then
        return 1
    fi

    local total_found
    total_found=$(wc -l < "$TEMP_ALL_FILES" 2>/dev/null || echo 0)
    
    if [[ "$total_found" -eq 0 ]]; then
        print_to_terminal "No files found (after exclude patterns)" "INFO"
        return 0
    fi
    
    print_to_terminal "Total files found: $total_found" "INFO"
    
    # Initialize directory counts
    while IFS='|' read -r _ filepath; do
        local dirname=$(dirname "$filepath")
        DIR_COUNTS_CACHE["$dirname"]=$(( ${DIR_COUNTS_CACHE["$dirname"]:-0} + 1 ))
    done < "$TEMP_ALL_FILES"
    
    return 0
}

get_next_batch() {
    local batch_size="$1"
    local processed=0
    
    > "$TEMP_BATCH_LIST"
    
    while IFS='|' read -r timestamp_str filepath && [[ $processed -lt $batch_size ]]; do
        local dirname=$(dirname "$filepath")
        local current_count=${DIR_COUNTS_CACHE["$dirname"]:-0}
        
        if [[ "$current_count" -le "$MIN_FILE_COUNT" ]]; then
            continue
        fi
        
        echo "$filepath" >> "$TEMP_BATCH_LIST"
        DIR_COUNTS_CACHE["$dirname"]=$((current_count - 1))
        processed=$((processed + 1))
    done < "$TEMP_ALL_FILES"
    
    # Remove processed lines
    if [[ $processed -gt 0 ]]; then
        sed -i "1,${processed}d" "$TEMP_ALL_FILES"
    fi
    
    echo "$processed"
}

delete_batch() {
    local count=0
    
    while read -r filepath; do
        if [[ "$DRY_RUN" -eq 1 ]]; then
            local age_days=$(get_file_age_days "$filepath")
            print_to_terminal "Would delete: $filepath (Age: $age_days days)" "DRY_RUN"
            count=$((count + 1))
        else
            if rm -f -- "$filepath"; then
                print_to_terminal "Deleted: $filepath" "SUCCESS"
                count=$((count + 1))
            else
                print_to_terminal "Failed to delete: $filepath" "ERROR"
            fi
        fi
    done < "$TEMP_BATCH_LIST"
    
    echo "$count"
}

# =======================
# MAIN SCRIPT
# =======================
main() {
    mkdir -p "/var/log/cdr-cleanup" 2>/dev/null || {
        echo "Error: Cannot create log directory /var/log/cdr-cleanup"
        exit 1
    }
    
    echo "=== CDR CLEANUP UTILITY FOR RHEL 9 ==="
    echo "Config: $CONFIG_FILE | Log: $LOG_FILE"
    
    print_to_terminal "=========================================" "HEADER"
    print_to_terminal "🚀 CDR CLEANUP STARTED" "HEADER"
    print_to_terminal "Timestamp: $(get_timestamp_ms)" "INFO"
    print_to_terminal "Arguments: $*" "INFO"
    print_to_terminal "=========================================" "HEADER"
    
    SCRIPT_START_TIME=$(date +%s)
    
    # 1. Parse arguments terlebih dahulu
    parse_arguments "$@"
    
    # 2. Load config file dengan prioritas yang benar
    load_config_file "$CONFIG_FILE"
    
    # 3. Check log rotation
    check_and_rotate_log "$LOG_FILE"
    
    # 4. Set MODE dan tampilkan info
    if [[ "$MODE" == "DISK_THRESHOLD" ]]; then
        print_to_terminal "Mode: DISK THRESHOLD (Target: <${THRESHOLD}%)" "INFO"
        # Pastikan age-based cleanup disabled
        ENABLE_AGE_BASED_CLEANUP=0
    elif [[ "$MODE" == "AGE_DAYS" ]]; then
        print_to_terminal "Mode: AGE DAYS (Older than ${FILE_AGE_DAYS} days)" "INFO"
        ENABLE_AGE_BASED_CLEANUP=1
    elif [[ "$MODE" == "AGE_MONTHS" ]]; then
        print_to_terminal "Mode: AGE MONTHS (Older than ${FILE_AGE_DAYS} days)" "INFO"
        ENABLE_AGE_BASED_CLEANUP=1
    fi
    
    # 5. Validasi directory
    if [[ ! -d "$DIRECTORY" ]]; then
        print_to_terminal "Error: Directory '$DIRECTORY' tidak ditemukan" "ERROR"
        exit 1
    fi
    
    print_to_terminal "Target directory: $DIRECTORY" "INFO"
    print_to_terminal "Mode: $MODE" "INFO"
    
    # 6. Execute based on mode
    if [[ "$MODE" == "DISK_THRESHOLD" ]]; then
        perform_disk_threshold_cleanup
    elif [[ "$MODE" == "AGE_DAYS" ]] || [[ "$MODE" == "AGE_MONTHS" ]]; then
        perform_age_based_cleanup
    else
        print_to_terminal "Error: Unknown mode '$MODE'" "ERROR"
        exit 1
    fi
    
    # 7. Completion
    SCRIPT_END_TIME=$(date +%s)
    local DURATION=$((SCRIPT_END_TIME - SCRIPT_START_TIME))
    
    print_to_terminal "=========================================" "HEADER"
    print_to_terminal "✅ CLEANUP COMPLETED" "HEADER"
    print_to_terminal "Total Duration: ${DURATION} seconds" "INFO"
    print_to_terminal "Mode: $MODE" "INFO"
    print_to_terminal "=========================================" "HEADER"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
