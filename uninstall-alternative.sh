#!/bin/bash
# Quick uninstall command
sudo systemctl stop cdr-cleanup.timer 2>/dev/null
sudo systemctl disable cdr-cleanup.timer 2>/dev/null
sudo systemctl daemon-reload
sudo pkill -f cdr-cleanup
sudo rm -f /usr/local/bin/cdr-cleanup
sudo rm -f /etc/cdr-cleanup.conf
sudo rm -f /etc/logrotate.d/cdr-cleanup
sudo rm -f /etc/systemd/system/cdr-cleanup.service
sudo rm -f /etc/systemd/system/cdr-cleanup.timer
sudo rm -f /etc/cron.d/cdr-cleanup
sudo rm -f /usr/local/bin/test-cdr-cleanup
sudo rm -f /var/lock/cdr-cleanup.lock
# Optional: remove logs
# sudo rm -rf /var/log/cdr-cleanup
echo "CDR Cleanup has been uninstalled"
