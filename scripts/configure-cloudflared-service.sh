#!/bin/bash
# ==============================================================================
# configure-cloudflared-service.sh
# Installs cloudflared binary (if missing) and sets up systemd service
# with logfile support.
# ==============================================================================
set -euo pipefail

ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 1. Install cloudflared binary if missing
if ! command -v /usr/local/bin/cloudflared &>/dev/null; then
    log "Installing cloudflared binary..."
    curl -L --output /usr/local/bin/cloudflared \
        "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH"
    chmod +x /usr/local/bin/cloudflared
    log "  [+] cloudflared installed"
else
    log "  [+] cloudflared already present"
fi

# 2. Ensure log directory exists
mkdir -p /var/log/ciso-onboarding

# 3. Write systemd service
cat > /etc/systemd/system/cloudflared.service << 'SERVICEEOF'
[Unit]
Description=Cloudflare Tunnel Quick Tunnel
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/cloudflared tunnel --url https://localhost:8443 --no-tls-verify --no-autoupdate --logfile /var/log/cloudflared.log
Restart=always
RestartSec=5
StandardOutput=file:/var/log/cloudflared.log
StandardError=file:/var/log/cloudflared.log

[Install]
WantedBy=multi-user.target
SERVICEEOF

log "  [+] cloudflared.service written"

# 4. Reload and enable
systemctl daemon-reload
systemctl enable cloudflared
systemctl start cloudflared
log "  [+] cloudflared service started"

log "Cloudflare Tunnel service configuration complete."