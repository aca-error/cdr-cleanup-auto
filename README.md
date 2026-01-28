**Log File Structure:**

/home/cdrsbx/cleanup.log    
├── START LOG (Timestamp, PID, Arguments)    
├── CONFIGURATION (Settings)    
├── PROCESS STEPS (Find, Filter, Delete)    
├── END LOG (Duration, Summary)    
└── ERROR/WARNING MESSAGES    


**File Structure:**    
/    
├── etc/    
│   ├── cdr-cleanup.conf              # Main config    
│   ├── logrotate.d/    
│   │   └── cdr-cleanup               # Logrotate config    
│   └── systemd/system/    
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
