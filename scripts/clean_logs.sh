ls -t /fs/backups/cold/logs/cronicle/healthchecksioheartbeat.*.log 2>/dev/null | tail -n +15 | xargs -r rm;
ls -t /fs/backups/cold/logs/cronicle/dailybackup.*.log 2>/dev/null | tail -n +15 | xargs -r rm;
ls -t /fs/backups/cold/logs/cronicle/monthlybackup.*.log 2>/dev/null | tail -n +15 | xargs -r rm;
