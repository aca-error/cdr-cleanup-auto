#!/bin/bash
# Test script for CDR Cleanup log rotation feature

LOG_FILE="/var/log/cdr-cleanup/cdr-cleanup.log"
BACKUP_LOG="/var/log/cdr-cleanup/test-rotation.log"

echo "=== Testing CDR Cleanup Log Rotation ==="
echo

# 1. Backup current log if exists
if [[ -f "$LOG_FILE" ]]; then
    cp "$LOG_FILE" "$BACKUP_LOG"
    echo "1. Backed up current log to: $BACKUP_LOG"
else
    echo "1. No existing log file found"
fi

# 2. Create test log files of various sizes
echo -e "\n2. Creating test log files..."
echo "   Creating 10MB log file..."
dd if=/dev/urandom of="$LOG_FILE" bs=1M count=10 2>/dev/null
echo "   Current size: $(ls -lh "$LOG_FILE" | awk '{print $5}')"

echo -e "\n   Testing with 10MB (under limit)..."
cdr-cleanup --dry-run --debug 2>&1 | grep -i "log.*size\|rotation" | head -3

# 3. Test with exactly 50MB
echo -e "\n3. Creating 50MB log file (at limit)..."
dd if=/dev/urandom of="$LOG_FILE" bs=1M count=50 2>/dev/null
echo "   Current size: $(ls -lh "$LOG_FILE" | awk '{print $5}')"

echo -e "\n   Testing with 50MB (at limit)..."
cdr-cleanup --dry-run --debug 2>&1 | grep -i "log.*size\|rotation\|warning" | head -5

# 4. Test with 60MB (over limit)
echo -e "\n4. Creating 60MB log file (over limit)..."
dd if=/dev/urandom of="$LOG_FILE" bs=1M count=60 2>/dev/null
echo "   Current size: $(ls -lh "$LOG_FILE" | awk '{print $5}')"

echo -e "\n   Testing with 60MB (over limit)..."
cdr-cleanup --dry-run --debug 2>&1 | grep -i "log.*size\|rotation\|warning\|success" | head -10

# 5. Check results
echo -e "\n5. Checking results..."
echo "   Current log directory contents:"
ls -lh /var/log/cdr-cleanup/ | head -10

echo -e "\n   Looking for rotated files:"
find /var/log/cdr-cleanup -name "cdr-cleanup.log*" -type f ! -name "cdr-cleanup.log" 2>/dev/null | head -5

# 6. Restore original log if backed up
if [[ -f "$BACKUP_LOG" ]]; then
    echo -e "\n6. Restoring original log..."
    mv "$BACKUP_LOG" "$LOG_FILE"
    echo "   Log restored"
fi

echo -e "\n=== Test Completed ==="
echo "Check /var/log/cdr-cleanup/cdr-cleanup.log for rotation messages"
