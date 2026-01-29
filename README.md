CDR CLEANUP UTILITY
===================

Quick Start:
- Test: cdr-cleanup --help
- Dry run: cdr-cleanup --threshold=85 --dry-run
- Actual: cdr-cleanup --force --threshold=80

Files:
- Config: /etc/cdr-cleanup.conf
- Logs: /var/log/cdr-cleanup/
- Man page: man cdr-cleanup

Scheduling:  
systemctl enable cdr-cleanup.timer
systemctl start cdr-cleanup.timer
