#!/bin/bash
# ==============================================================================
# send-tunnel-url-mail.sh
# Sends the current Cloudflare Tunnel URL via SMTP mail.
# Reads credentials from /etc/ciso-onboarding/mail.env.
# ==============================================================================
set -euo pipefail

log() { echo "[$(date '+%H:%M:%S')] $*"; }

MAIL_ENV="/etc/ciso-onboarding/mail.env"
AUDIT_LOG="/var/log/ciso-onboarding/setup-audit.jsonl"

# Load mail config
if [ ! -f "$MAIL_ENV" ]; then
    log "ERROR: $MAIL_ENV not found. Run configure-mail-env.sh first."
    exit 1
fi
source "$MAIL_ENV"

# Get current tunnel URL
URL="${1:-}"
if [ -z "$URL" ]; then
    URL=$(/usr/local/bin/get-cloudflare-tunnel-url.sh 2>/dev/null || true)
fi
if [ -z "$URL" ]; then
    log "ERROR: No tunnel URL provided or found."
    exit 1
fi

HOST="${URL#https://}"

# Build email content (plain text)
TEXT_CONTENT="CISO Assistant - Tunnel URL geaendert

Die aktuelle Cloudflare-Tunnel-URL deiner CISO-Assistant-Instanz:

  ${URL}

Bitte oeffne diese URL in deinem Browser, um auf die GRC-Plattform zuzugreifen."

# Build email content (HTML)
HTML_CONTENT="<html>
<body style=\"font-family: Arial, sans-serif; background: #f8fafc; padding: 20px;\">
<div style=\"max-width: 600px; margin: auto; background: white; border-radius: 12px; padding: 30px; box-shadow: 0 2px 8px rgba(0,0,0,0.1);\">
  <h2 style=\"color: #1e293b;\">CISO Assistant</h2>
  <p style=\"color: #475569;\">Die aktuelle Cloudflare-Tunnel-URL deiner Instanz:</p>
  <p style=\"text-align: center; margin: 24px 0;\">
    <a href=\"${URL}\" style=\"display: inline-block; background: #4f46e5; color: white; padding: 14px 28px; border-radius: 8px; text-decoration: none; font-size: 16px; font-weight: 600;\">
      GRC-Plattform oeffnen →
    </a>
  </p>
  <p style=\"color: #64748b; font-size: 13px; word-break: break-all;\">${URL}</p>
  <hr style=\"border: 0; border-top: 1px solid #e2e8f0; margin: 20px 0;\">
  <p style=\"color: #94a3b8; font-size: 12px;\">Diese E-Mail wurde automatisch vom CISO-Assistant-Setup generiert.</p>
</div>
</body>
</html>"

BOUNDARY="CISO-BOUNDARY-$(date +%s)"
SUBJECT="=?UTF-8?Q?CISO_Assistant_Tunnel-URL_=C3=BCndert?="

# Write email to temp file
MAIL_FILE=$(mktemp)
cat > "$MAIL_FILE" << MAILEOF
From: ${MAIL_FROM}
To: ${MAIL_TO}
Subject: ${SUBJECT}
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="${BOUNDARY}"

--${BOUNDARY}
Content-Type: text/plain; charset="UTF-8"

${TEXT_CONTENT}

--${BOUNDARY}
Content-Type: text/html; charset="UTF-8"

${HTML_CONTENT}

--${BOUNDARY}--
MAILEOF

# Send via curl SMTP
log "Sending mail to ${MAIL_TO} via ${SMTP_SERVER}:${SMTP_PORT}..."
if curl --url "smtp://${SMTP_SERVER}:${SMTP_PORT}" \
    --mail-from "${MAIL_FROM}" \
    --mail-rcpt "${MAIL_TO}" \
    --user "${SMTP_AUTH_USER}:${SMTP_AUTH_PASSWORD}" \
    --upload-file "$MAIL_FILE" 2>/dev/null; then
    log "  [+] Mail sent successfully to ${MAIL_TO}"
    STATUS="success"
else
    log "  [ERROR] Mail delivery failed"
    STATUS="failed"
fi

rm -f "$MAIL_FILE"

# Audit log
mkdir -p "$(dirname "$AUDIT_LOG")"
echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"step\":\"send_tunnel_url_mail\",\"status\":\"${STATUS}\",\"mail_to\":\"${MAIL_TO}\",\"public_url\":\"${URL}\"}" >> "$AUDIT_LOG"

exit 0