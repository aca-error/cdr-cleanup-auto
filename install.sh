#!/bin/bash
# Installation script for CDR Cleanup Utility

set -e

echo "=== CDR Cleanup Utility Installation ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Create necessary directories
echo "Creating directories..."
mkdir -p /var/log/cdr-cleanup
mkdir -p /home/cdrsbx
mkdir -p /home/backup/deleted_files
mkdir -p /usr/local/bin

# Set permissions
echo "Setting permissions..."
chmod 755 /var/log/cdr-cleanup
chmod 755 /home/cdrsbx
chmod 700 /home/backup/deleted_files

# Copy main script
echo "Installing main script..."
cp cdr-cleanup.sh /usr/local/bin/cdr-cleanup
chmod 755 /usr/local/bin/cdr-cleanup
chown root:root /usr/local/bin/cdr-cleanup

# Install config file
echo "Installing config file..."
cat > /etc/cdr-cleanup.conf << 'EOF'
#!/bin/bash
# CDR Cleanup Configuration File

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
EOF

chmod 600 /etc/cdr-cleanup.conf
chown root:root /etc/cdr-cleanup.conf

# Install logrotate config dengan monthly rotation dan 50MB limit
echo "Installing logrotate configuration..."
cat > /etc/logrotate.d/cdr-cleanup << 'EOF'
/var/log/cdr-cleanup/cdr-cleanup.log {
    monthly                    # Rotate monthly
    rotate 12                  # Keep 12 months of logs
    maxsize 50M                # Rotate if file exceeds 50MB
    compress                   # Compress rotated logs
    delaycompress              # Delay compression until next rotation
    missingok                  # Don't error if log is missing
    notifempty                 # Don't rotate empty logs
    create 640 root root       # Set permissions on new log file
    dateext                    # Add date extension to rotated logs
    dateformat -%Y%m          # Format: cdr-cleanup.log-202401
    postrotate
        /usr/bin/systemctl reload rsyslog >/dev/null 2>&1 || true
    endscript
}
EOF

chmod 644 /etc/logrotate.d/cdr-cleanup

# Create man page (optional)
echo "Creating documentation..."
mkdir -p /usr/local/share/man/man1
cat > /usr/local/share/man/man1/cdr-cleanup.1 << 'EOF'
.TH CDR-CLEANUP 1 "January 2024" "CDR Cleanup Utility"
.SH NAME
cdr-cleanup \- Disk cleanup utility for RHEL 9
.SH SYNOPSIS
.B cdr-cleanup
[OPTIONS]
.SH DESCRIPTION
CDR Cleanup Utility adalah script untuk membersihkan file lama berdasarkan 
penggunaan disk atau umur file. Script ini dirancang khusus untuk RHEL 9.
.SH LOG ROTATION
Log file di-rotate secara bulanan atau ketika mencapai ukuran 50MB.
Konfigurasi logrotate: /etc/logrotate.d/cdr-cleanup
.SH OPTIONS
.TP
.B \-\-dry-run
Simulasi saja, tidak menghapus file (Default).
.TP
.B \-\-force
Jalankan penghapusan file secara nyata.
.TP
.B \-\-threshold=N
Batas persen disk usage (Default: 85).
.TP
.B \-\-age-days=N
Hapus file > N hari (Age Based mode).
.TP
.B \-\-age-months=N
Hapus file > N bulan (Age Based mode).
.TP
.B \-\-directory=PATH
Target direktori.
.TP
.B \-\-help
Tampilkan pesan bantuan.
.SH FILES
.TP
.I /etc/cdr-cleanup.conf
File konfigurasi utama.
.TP
.I /var/log/cdr-cleanup/cdr-cleanup.log
File log (rotasi bulanan/50MB).
.TP
.I /var/lock/cdr-cleanup.lock
Lock file.
.SH SEE ALSO
.BR logrotate (8),
.BR crontab (5)
.SH AUTHOR
System Administration Team
EOF

gzip -f /usr/local/share/man/man1/cdr-cleanup.1

# Create systemd service (optional)
echo "Creating systemd service..."
cat > /etc/systemd/system/cdr-cleanup.service << 'EOF'
[Unit]
Description=CDR Disk Cleanup Service
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
EnvironmentFile=/etc/cdr-cleanup.conf
ExecStart=/usr/local/bin/cdr-cleanup --force --threshold=${THRESHOLD}
StandardOutput=journal
StandardError=journal
PrivateTmp=yes
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/cdr-cleanup.timer << 'EOF'
[Unit]
Description=Run CDR Cleanup Daily
Requires=cdr-cleanup.service

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

echo "Installation completed!"
echo ""
echo "Log Rotation Configuration:"
echo "  - Monthly rotation OR when log reaches 50MB"
echo "  - Keep 12 months of history"
echo "  - Compressed archives"
echo ""
echo "Quick test:"
echo "  cdr-cleanup --help"
echo ""
echo "Files installed:"
echo "  /usr/local/bin/cdr-cleanup"
echo "  /etc/cdr-cleanup.conf"
echo "  /etc/logrotate.d/cdr-cleanup"
echo ""
echo "To enable daily cleanup:"
echo "  systemctl enable --now cdr-cleanup.timer"
