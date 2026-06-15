#!/bin/bash
# ==============================================================================
# backup-ciso-config.sh
# Creates a timestamped backup of docker-compose.yml and Caddy data.
# ==============================================================================
set -euo pipefail

CISO_DIR="${CISO_DIR:-/home/ubuntu/ciso-assistant}"
BACKUP_BASE="${BACKUP_BASE:-/opt/ciso-setup-archive}"
TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_BASE}/${TIMESTAMP}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

mkdir -p "$BACKUP_DIR"
log "Backing up to: $BACKUP_DIR"

# docker-compose.yml
if [ -f "$CISO_DIR/docker-compose.yml" ]; then
    cp "$CISO_DIR/docker-compose.yml" "$BACKUP_DIR/docker-compose.yml"
    log "  [+] docker-compose.yml saved"
fi

# Caddy data
if [ -d "$CISO_DIR/db/caddy" ]; then
    cp -r "$CISO_DIR/db/caddy" "$BACKUP_DIR/caddy"
    log "  [+] Caddy data saved"
fi

# .env if present
if [ -f "$CISO_DIR/.env" ]; then
    cp "$CISO_DIR/.env" "$BACKUP_DIR/.env"
    log "  [+] .env saved (excluded from git)"
fi

log "Backup complete: $BACKUP_DIR"
echo "$BACKUP_DIR"