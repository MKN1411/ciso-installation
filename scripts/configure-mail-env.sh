#!/bin/bash
# ==============================================================================
# configure-mail-env.sh
# Creates /etc/ciso-onboarding/mail.env with root-only access.
# ==============================================================================
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

MAIL_DIR="/etc/ciso-onboarding"
MAIL_ENV="${MAIL_DIR}/mail.env"

# Usage
if [ $# -lt 5 ]; then
    echo "Usage: $0 <SMTP_SERVER> <SMTP_PORT> <SMTP_AUTH_USER> <SMTP_AUTH_PASSWORD> <MAIL_ADDRESS>"
    echo ""
    echo "In the Community version, MAIL_ADDRESS is both sender and receiver."
    exit 1
fi

SMTP_SERVER="$1"
SMTP_PORT="$2"
SMTP_AUTH_USER="$3"
SMTP_AUTH_PASSWORD="$4"
MAIL_ADDRESS="$5"

mkdir -p "$MAIL_DIR"

cat > "$MAIL_ENV" << EOF
# CISO Assistant Mail Configuration
# Created: $(date -Iseconds)
SMTP_SERVER=${SMTP_SERVER}
SMTP_PORT=${SMTP_PORT}
SMTP_AUTH_USER=${SMTP_AUTH_USER}
SMTP_AUTH_PASSWORD=${SMTP_AUTH_PASSWORD}
MAIL_FROM=${MAIL_ADDRESS}
MAIL_TO=${MAIL_ADDRESS}
EOF

chmod 600 "$MAIL_ENV"
chown root:root "$MAIL_ENV"

log "  [+] mail.env created at $MAIL_ENV (chmod 600, root:root)"
log "  [+] MAIL_FROM = MAIL_TO = ${MAIL_ADDRESS}"