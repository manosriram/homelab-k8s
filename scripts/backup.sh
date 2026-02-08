#!/bin/bash

source ~/.bashrc;

# Exit if no tag argument is provided
[ -z "$1" ] && { echo "Usage: $0 <tag>"; exit 1; }
TAG="$1" # Assign the provided tag

# Paths to backup
BACKUP_PATHS="/fs/backups /fs/lab/data /fs/lab/scripts /fs/containers/docker-compose/npm"

DAILY_HEALTHCHECKS_URL="https://hc-ping.com/5d70a7da-b8ca-4571-a059-839cff1fb6d0"
MONTHLY_HEALTHCHECKS_URL="https://hc-ping.com/f03e366d-22a9-414a-8039-32d17b1dc632"

restic unlock;

# Perform backup and log status
restic backup --tag "$TAG" $BACKUP_PATHS \
	&& echo "Backup with tag '$TAG' completed."

# Conditional curl notification based on tag
if [[ "$TAG" == "daily" ]]; then
	curl -s -X POST -H 'Content-Type: application/json' -d '{"text":"Daily backup completed!"}' $DAILY_HEALTHCHECKS_URL \
		&& echo "Daily curl notification sent."
elif [[ "$TAG" == "monthly" ]]; then
	curl -s -X POST -H 'Content-Type: application/json' -d '{"text":"Monthly backup completed!"}' $MONTHLY_HEALTHCHECKS_URL \
		&& echo "Monthly curl notification sent."
fi

# Apply retention for daily backups
restic forget --tag daily --prune --keep-last 60 \
	&& echo "Daily retention applied." \
	|| echo "Daily retention FAILED!"

# Apply retention for monthly backups
restic forget --tag monthly --prune --keep-last 36 \
	&& echo "Monthly retention applied." \
	|| echo "Monthly retention FAILED!"
