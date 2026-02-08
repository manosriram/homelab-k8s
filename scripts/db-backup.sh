#!/bin/bash

# Usage: ./k3s-backup.sh [daily|monthly]

set -uo pipefail

# --- Configuration ---
NAMESPACE="default"
BACKUP_TYPE="${1:-daily}"
BACKUP_BASE_DIR="/fs/backups/cold/containerdb"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Webhook URLs for notifications
HEALTHCHECK_DAILY="https://hc-ping.com/d7d85e6e-1bfc-47de-abb9-e779de6155c0"
HEALTHCHECK_MONTHLY="https://hc-ping.com/a6a7e144-043d-45cd-9766-e8116233e9f5"

# PostgreSQL configurations (app_name -> pod_label:db_name:user:service_name)
declare -A PG_CONFIGS
PG_CONFIGS[miniflux]="miniflux-db:minifluxrss:manosriram:miniflux"

# SQLite configurations (app_name -> host_path:description)
declare -A SQLITE_CONFIGS
SQLITE_CONFIGS[vaultwarden]="/fs/lab/data/vaultwarden:Vaultwarden data"
SQLITE_CONFIGS[linkding]="/fs/lab/data/linkding:Linkding data"
SQLITE_CONFIGS[beszel]="/fs/lab/data/beszel:Beszel data"
SQLITE_CONFIGS[gatus]="/fs/lab/data/gatus:Gatus data"
SQLITE_CONFIGS[npm]="/fs/containers/docker-compose/npm/data:NPM Data"

# Get pod name by label
get_pod_by_label() {
    local label=$1
    kubectl get pods -n "$NAMESPACE" -l "app=$label" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Set backup destination based on type
BACKUP_DIR="$BACKUP_BASE_DIR/$BACKUP_TYPE"
mkdir -p "$BACKUP_DIR"

# Logging function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Call webhook URL
hit_webhook() {
    local url=$1
    local backup_type=$2
    
    if [[ -z "$url" ]]; then
        return 0
    fi
    
    log "  [INFO] Calling $backup_type webhook..."
    if curl -sSf "$url" >/dev/null 2>&1; then
        log "  [SUCCESS] Webhook call successful"
        return 0
    else
        log "  [WARNING] Webhook call failed"
        return 1
    fi
}

# Get secret from Kubernetes
get_k8s_secret() {
    local secret_name=$1
    local key=$2
    kubectl get secret -n "$NAMESPACE" "$secret_name" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d
}

# Backup PostgreSQL database
backup_postgres() {
    local app=$1
    local config="${PG_CONFIGS[$app]}"
    
    IFS=':' read -r pod_label db_name user secret_name password_key <<< "$config"
    
    log "Processing PostgreSQL: $app..."
    
    # Get pod by label
    local pod_name
    pod_name=$(get_pod_by_label "$pod_label")
    
    if [[ -z "$pod_name" ]]; then
        log "  [ERROR] No pod found with label app=$pod_label. Skipping..."
        return 1
    fi
    
    log "  [INFO] Found Pod: $pod_name"
    
    local out_file="$BACKUP_DIR/${app}_backup_${TIMESTAMP}.tar.gz"
    local sql_file="${app}_backup_${TIMESTAMP}.sql"
    local temp_dir=$(mktemp -d)
    
    # Execute pg_dump inside the pod with debug output
    log "  [INFO] Running pg_dump for database '$db_name'..."
    
    local pg_dump_output
    pg_dump_output=$(kubectl exec -n "$NAMESPACE" "$pod_name" -- pg_dump -U "$user" -d "$db_name" --no-owner --no-acl 2>&1) || {
        log "  [ERROR] pg_dump failed for $app"
        log "  [DEBUG] Error output: $pg_dump_output"
        rm -rf "$temp_dir"
        return 1
    }
    
    # Save SQL to temp file
    echo "$pg_dump_output" > "$temp_dir/$sql_file"
    
    # Create tar.gz archive
    if tar -czf "$out_file" -C "$temp_dir" "$sql_file" 2>/dev/null; then
        if [[ -s "$out_file" ]]; then
            log "  [SUCCESS] Saved to $out_file ($(du -h "$out_file" | cut -f1))"
            rm -rf "$temp_dir"
            return 0
        else
            log "  [ERROR] Backup file is empty: $out_file"
            rm -f "$out_file"
            rm -rf "$temp_dir"
            return 1
        fi
    else
        log "  [ERROR] Failed to create tar archive for $app"
        rm -f "$out_file"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Backup SQLite database from host filesystem using sqlite3
backup_sqlite() {
    local app=$1
    local config="${SQLITE_CONFIGS[$app]}"
    
    IFS=':' read -r host_path description <<< "$config"
    
    log "Processing SQLite: $app..."
    
    # Check if host path exists
    if [[ ! -d "$host_path" ]]; then
        log "  [ERROR] Host path does not exist: $host_path"
        return 1
    fi
    
    log "  [INFO] Searching for SQLite databases in: $host_path"
    
    # Find all SQLite database files on host
    local db_files
    db_files=$(find "$host_path" -type f \( -name "*.db" -o -name "*.sqlite" -o -name "*.sqlite3" \) 2>/dev/null | head -20)
    
    if [[ -z "$db_files" ]]; then
        log "  [WARNING] No SQLite databases found in $host_path"
        return 1
    fi
    
    local success_count=0
    local total_count=0
    local temp_dir=$(mktemp -d)
    local out_file="$BACKUP_DIR/${app}_backup_${TIMESTAMP}.tar.gz"
    
    # Backup each SQLite database found to temp directory
    while IFS= read -r db_file; do
        [[ -z "$db_file" ]] && continue
        
        total_count=$((total_count + 1))
        local db_basename
        db_basename=$(basename "$db_file" | sed 's/\.[^.]*$//')  # Remove extension
        local temp_db_file="$temp_dir/${db_basename}.db"
        
        log "  [INFO] Backing up database: $db_file"
        
        # Use sqlite3 .backup command for consistent backup
        if sqlite3 "$db_file" ".backup '$temp_db_file'" 2>/dev/null; then
            if [[ -s "$temp_db_file" ]]; then
                success_count=$((success_count + 1))
            else
                log "  [ERROR] Backup file is empty for $db_file"
                rm -f "$temp_db_file"
            fi
        else
            log "  [ERROR] SQLite backup failed for $db_file (sqlite3 command failed)"
            rm -f "$temp_db_file"
        fi
    done <<< "$db_files"
    
    # Create tar.gz archive from temp directory
    if [[ $success_count -gt 0 ]]; then
        if tar -czf "$out_file" -C "$temp_dir" . 2>/dev/null; then
            if [[ -s "$out_file" ]]; then
                log "  [SUCCESS] Saved to $out_file ($(du -h "$out_file" | cut -f1))"
                rm -rf "$temp_dir"
            else
                log "  [ERROR] Archive file is empty: $out_file"
                rm -f "$out_file"
                rm -rf "$temp_dir"
                return 1
            fi
        else
            log "  [ERROR] Failed to create tar archive for $app"
            rm -f "$out_file"
            rm -rf "$temp_dir"
            return 1
        fi
    fi
    
    if [[ $success_count -eq 0 ]]; then
        log "  [ERROR] All SQLite backups failed for $app"
        rm -rf "$temp_dir"
        return 1
    elif [[ $success_count -lt $total_count ]]; then
        log "  [WARNING] Only $success_count/$total_count databases backed up for $app"
        return 0
    else
        log "  [SUCCESS] All $total_count database(s) backed up for $app"
        return 0
    fi
}

# Main execution
log "Starting K3s database backups at $(date)"
log "Backup type: $BACKUP_TYPE"
log "Backup directory: $BACKUP_DIR"
log "------------------------------------------"

FAILED=()
SUCCESS=()

# Backup PostgreSQL databases
for app in "${!PG_CONFIGS[@]}"; do
    if backup_postgres "$app"; then
        SUCCESS+=("$app")
    else
        FAILED+=("$app")
    fi
    echo ""
done

# Backup SQLite databases
for app in "${!SQLITE_CONFIGS[@]}"; do
    if backup_sqlite "$app"; then
        SUCCESS+=("$app")
    else
        FAILED+=("$app")
    fi
    echo ""
done

log "------------------------------------------"
log "Backup process completed."
log ""
log "Summary:"
log "  Successful: ${#SUCCESS[@]} - ${SUCCESS[*]}"
log "  Failed: ${#FAILED[@]} - ${FAILED[*]}"

# Call webhook based on backup type if all backups succeeded
if [[ ${#FAILED[@]} -eq 0 ]]; then
    case "$BACKUP_TYPE" in
        daily)
            hit_webhook "$HEALTHCHECK_DAILY" "daily"
            ;;
        monthly)
            hit_webhook "$HEALTHCHECK_MONTHLY" "monthly"
            ;;
    esac
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    exit 1
fi

exit 0
