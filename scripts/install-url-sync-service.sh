#!/bin/bash
# ==============================================================================
# install-url-sync-service.sh
# Installs the URL sync systemd service and the orchestrator script.
# ==============================================================================
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 1. Deploy the orchestrator script
ORCHESTRATOR="/usr/local/bin/ciso-tunnel-url-sync.sh"

cat > "$ORCHESTRATOR" << 'SCRIPTEOF'
#!/bin/bash
# ==============================================================================
# ciso-tunnel-url-sync.sh
# Orchestrator: extracts tunnel URL, patches compose, runs health checks,
# and sends mail notification.
# Called by: ciso-tunnel-url-sync.service
# ==============================================================================
set -euo pipefail

CISO_DIR="${CISO_DIR:-/home/ubuntu/ciso-assistant}"
LOG_DIR="/var/log/ciso-onboarding"
URL_SYNC_LOG="${LOG_DIR}/cloudflare-url-sync.log"
AUDIT_LOG="${LOG_DIR}/setup-audit.jsonl"

mkdir -p "$LOG_DIR"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$URL_SYNC_LOG"; }

log "=== ciso-tunnel-url-sync: starting ==="

# Step 1: Get current tunnel URL
URL=$(/usr/local/bin/get-cloudflare-tunnel-url.sh 2>/dev/null || true)
if [ -z "$URL" ]; then
    log "WARNING: No tunnel URL found yet. Skipping sync."
    exit 0
fi
log "Tunnel URL: $URL"

# Step 2: Backup
BACKUP_DIR=$(/usr/local/bin/backup-ciso-config.sh 2>/dev/null || echo "")
log "Backup: ${BACKUP_DIR:-none}"

# Step 3: Patch compose
if [ -f "$CISO_DIR/docker-compose.yml" ]; then
    log "Patching docker-compose.yml..."
    python3 /usr/local/bin/patch-ciso-compose.py \
        --compose "$CISO_DIR/docker-compose.yml" \
        --url "$URL" 2>&1 | tee -a "$URL_SYNC_LOG" || true
fi

# Step 4: Recreate containers
log "Recreating affected containers (backend, huey, frontend, caddy)..."
cd "$CISO_DIR"
docker compose up -d backend huey frontend caddy 2>&1 | tee -a "$URL_SYNC_LOG" || true

# Step 5: Health check
log "Running health checks..."
PUBLIC_HOST="${URL#https://}"
if /usr/local/bin/test-ciso-health.sh "https://localhost:8443" "$URL" 2>&1 | tee -a "$URL_SYNC_LOG"; then
    log "Health checks PASSED"
    STATUS="success"
else
    log "Health checks FAILED"
    STATUS="failed"
fi

# Step 6: Mail notification
log "Sending mail notification..."
/usr/local/bin/send-tunnel-url-mail.sh "$URL" 2>&1 | tee -a "$URL_SYNC_LOG" || true

# Audit entry
echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"step\":\"url_sync_orchestrator\",\"status\":\"${STATUS}\",\"public_url\":\"${URL}\"}" >> "$AUDIT_LOG"

log "=== ciso-tunnel-url-sync: completed (${STATUS}) ==="
SCRIPTEOF

chmod 755 "$ORCHESTRATOR"
log "  [+] Orchestrator deployed: $ORCHESTRATOR"

# 2. Deploy helper scripts to /usr/local/bin
SCRIPT_SRC="/home/ubuntu/ciso-installation/scripts"
if [ -d "$SCRIPT_SRC" ]; then
    for s in backup-ciso-config.sh get-cloudflare-tunnel-url.sh test-ciso-health.sh send-tunnel-url-mail.sh; do
        if [ -f "${SCRIPT_SRC}/${s}" ]; then
            cp "${SCRIPT_SRC}/${s}" "/usr/local/bin/${s}"
            chmod 755 "/usr/local/bin/${s}"
            log "  [+] Helper deployed: /usr/local/bin/${s}"
        fi
    done
fi

# 3. Deploy patch-ciso-compose.py
if [ -f "${SCRIPT_SRC}/patch-ciso-compose.py" ]; then
    cp "${SCRIPT_SRC}/patch-ciso-compose.py" "/usr/local/bin/patch-ciso-compose.py"
    chmod 755 "/usr/local/bin/patch-ciso-compose.py"
    log "  [+] Compose patcher deployed: /usr/local/bin/patch-ciso-compose.py"
fi

# 4. Install systemd timer (runs every 5 minutes)
cat > /etc/systemd/system/ciso-tunnel-url-sync.service << 'SERVICEEOF'
[Unit]
Description=CISO Assistant Cloudflare Tunnel URL Sync
After=docker.service cloudflared.service
Requires=docker.service cloudflared.service

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/ciso-tunnel-url-sync.sh
StandardOutput=file:/var/log/ciso-onboarding/cloudflare-url-sync.log
StandardError=file:/var/log/ciso-onboarding/cloudflare-url-sync.log
SERVICEEOF

cat > /etc/systemd/system/ciso-tunnel-url-sync.timer << 'TIMEREOF'
[Unit]
Description=Check Cloudflare Tunnel URL every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
TIMEREOF

systemctl daemon-reload
systemctl enable ciso-tunnel-url-sync.timer
systemctl start ciso-tunnel-url-sync.timer

log "  [+] ciso-tunnel-url-sync.timer installed and started"
log "URL sync service installation complete."