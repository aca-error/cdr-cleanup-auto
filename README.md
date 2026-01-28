**File Structure**
>/
>├── etc/
>│   ├── cdr-cleanup.conf              # Main config
>│   ├── logrotate.d/
>│   │   └── cdr-cleanup               # Logrotate config
>│   └── systemd/system/
│       ├── cdr-cleanup.service       # Systemd service
│       └── cdr-cleanup.timer         # Systemd timer
├── usr/
│   └── local/
│       ├── bin/cdr-cleanup           # Main script
│       └── share/man/man1/
│           └── cdr-cleanup.1.gz      # Man page
├── var/
│   ├── log/cdr-cleanup/              # Log directory
│   │   └── cdr-cleanup.log           # Current log
│   └── lock/cdr-cleanup.lock         # Lock file
└── home/
    ├── cdrsbx/                       # Default target
    └── backup/deleted_files/         # Backup directory


**Log Retention**
/var/log/cdr-cleanup/
├── cdr-cleanup.log          # Current log (active)
├── cdr-cleanup.log-202401.gz # January 2024 (compressed)
├── cdr-cleanup.log-202402.gz # February 2024
├── cdr-cleanup.log-202403.gz # March 2024
└── ... (up to 12 months)
