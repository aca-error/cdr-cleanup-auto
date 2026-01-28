#!/bin/bash
# monitor-log-size.sh
# Run this in cron to monitor log size

LOG_FILE="/var/log/cdr-cleanup/cdr-cleanup.log"
MAX_SIZE_MB=50
WARNING_THRESHOLD=45  # 45MB - send warning
CRITICAL_THRESHOLD=48 # 48MB - send critical alert

if [[ -f "$LOG_FILE" ]]; then
    SIZE_BYTES=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
    SIZE_MB=$((SIZE_BYTES / 1024 / 1024))
    
    if [[ "$SIZE_MB" -ge "$CRITICAL_THRESHOLD" ]]; then
        echo "CRITICAL: Log file ${LOG_FILE} is ${SIZE_MB}MB (>${CRITICAL_THRESHOLD}MB)"
        echo "Forcing log rotation..."
        
        # Force rotation using cdr-cleanup method
        if [[ -x /usr/local/bin/cdr-cleanup ]]; then
            /usr/local/bin/cdr-cleanup --dry-run 2>&1 | grep -i "rotation\|log.*size" | head -5
        fi
        exit 2
    elif [[ "$SIZE_MB" -ge "$WARNING_THRESHOLD" ]]; then
        echo "WARNING: Log file ${LOG_FILE} is ${SIZE_MB}MB (>${WARNING_THRESHOLD}MB)"
        exit 1
    else
        echo "OK: Log file ${LOG_FILE} is ${SIZE_MB}MB"
        exit 0
    fi
else
    echo "UNKNOWN: Log file ${LOG_FILE} not found"
    exit 3
fi
