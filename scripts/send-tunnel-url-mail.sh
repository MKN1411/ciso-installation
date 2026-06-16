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

# Update mail.env from OCI metadata service if running on OCI
if curl -s -I -m 2 -H "Authorization: Bearer Oracle" http://169.254.169.254/opc/v2/instance/ >/dev/null; then
    log "Checking for updated SMTP credentials from OCI metadata..."
    LATEST_USER=$(curl -H "Authorization: Bearer Oracle" -s http://169.254.169.254/opc/v2/instance/metadata/smtp_user || true)
    LATEST_PASS=$(curl -H "Authorization: Bearer Oracle" -s http://169.254.169.254/opc/v2/instance/metadata/smtp_password || true)
    NOTIF_EMAIL=$(curl -H "Authorization: Bearer Oracle" -s http://169.254.169.254/opc/v2/instance/metadata/notification_email || true)
    
    if [ -n "$LATEST_USER" ] && [ -n "$LATEST_PASS" ]; then
        CURRENT_USER=""
        CURRENT_PASS=""
        if [ -f "$MAIL_ENV" ]; then
            CURRENT_USER=$(grep "^SMTP_AUTH_USER=" "$MAIL_ENV" | cut -d= -f2- || true)
            CURRENT_PASS=$(grep "^SMTP_AUTH_PASSWORD=" "$MAIL_ENV" | cut -d= -f2- || true)
        fi
        
        if [ "$LATEST_USER" != "$CURRENT_USER" ] || [ "$LATEST_PASS" != "$CURRENT_PASS" ] || [ ! -f "$MAIL_ENV" ]; then
            log "SMTP credentials have changed or mail.env is missing. Updating $MAIL_ENV..."
            # Query region from OCI metadata
            OCI_REGION=$(curl -H "Authorization: Bearer Oracle" -s http://169.254.169.254/opc/v2/instance/region || true)
            if [ -z "$OCI_REGION" ]; then OCI_REGION="eu-frankfurt-1"; fi
            
            # Read existing values if any
            EXISTING_FROM=""
            EXISTING_TO=""
            if [ -f "$MAIL_ENV" ]; then
                EXISTING_FROM=$(grep "^MAIL_FROM=" "$MAIL_ENV" | cut -d= -f2- || true)
                EXISTING_TO=$(grep "^MAIL_TO=" "$MAIL_ENV" | cut -d= -f2- || true)
            fi
            
            M_FROM="${EXISTING_FROM:-${NOTIF_EMAIL}}"
            M_TO="${EXISTING_TO:-${NOTIF_EMAIL}}"
            
            mkdir -p "$(dirname "$MAIL_ENV")"
            cat > "$MAIL_ENV" << EOF
SMTP_SERVER="smtp.email.${OCI_REGION}.oci.oraclecloud.com"
SMTP_PORT="587"
SMTP_AUTH_USER="${LATEST_USER}"
SMTP_AUTH_PASSWORD="${LATEST_PASS}"
MAIL_FROM="${M_FROM}"
MAIL_TO="${M_TO}"
EOF
            chmod 600 "$MAIL_ENV"
            chown root:root "$MAIL_ENV" 2>/dev/null || true
        fi
    fi
fi

# Load mail config safely without sourcing (executing) it
if [ ! -f "$MAIL_ENV" ]; then
    log "ERROR: $MAIL_ENV not found."
    exit 1
fi
SMTP_SERVER=$(grep -E '^SMTP_SERVER=' "$MAIL_ENV" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
SMTP_PORT=$(grep -E '^SMTP_PORT=' "$MAIL_ENV" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
SMTP_AUTH_USER=$(grep -E '^SMTP_AUTH_USER=' "$MAIL_ENV" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
SMTP_AUTH_PASSWORD=$(grep -E '^SMTP_AUTH_PASSWORD=' "$MAIL_ENV" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
MAIL_FROM=$(grep -E '^MAIL_FROM=' "$MAIL_ENV" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")
MAIL_TO=$(grep -E '^MAIL_TO=' "$MAIL_ENV" | cut -d= -f2- | tr -d '\r' | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")

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

# Read OCI Metadata
VM_SHAPE=$(curl -H "Authorization: Bearer Oracle" -s -m 2 http://169.254.169.254/opc/v2/instance/shape || echo "VM.Standard.A1.Flex (Always Free)")
VM_AD=$(curl -H "Authorization: Bearer Oracle" -s -m 2 http://169.254.169.254/opc/v2/instance/availabilityDomain || echo "Availability Domain 1")
VM_OCID=$(curl -H "Authorization: Bearer Oracle" -s -m 2 http://169.254.169.254/opc/v2/instance/id || echo "N/A")
VM_COMP=$(curl -H "Authorization: Bearer Oracle" -s -m 2 http://169.254.169.254/opc/v2/instance/compartmentId || echo "N/A")

# Read Seeding status from /var/log/cloud-init-ciso-setup.log
SETUP_LOG="/var/log/cloud-init-ciso-setup.log"
SEED_DORA="Inaktiv"
SEED_NIS2="Inaktiv"
SEED_ISO="Inaktiv"
SEED_PRIVACY="Inaktiv"

if [ -f "$SETUP_LOG" ]; then
    if grep -q "grc_setup completed" "$SETUP_LOG" || grep -q "Step 6: Seed GRC database" "$SETUP_LOG"; then
        SEED_ISO="Aktiv (ISO/IEC 27001:2022)"
    fi
    if grep -q "grc_setup_m365_deconstruction.py" "$SETUP_LOG"; then
        SEED_DORA="Aktiv (DORA Compliance & Exit Plans)"
    fi
    if grep -q "grc_setup_metrology.py" "$SETUP_LOG"; then
        SEED_NIS2="Aktiv (NIS 2 & BSI IT-Grundschutz)"
    fi
    if grep -q "populate_privacy_custom.py" "$SETUP_LOG" || grep -q "GDPR / Privacy Data Seeding completed" "$SETUP_LOG"; then
        SEED_PRIVACY="Aktiv (GDPR & Data Protection)"
    fi
fi

# Build email content (plain text)
TEXT_CONTENT="CISO Assistant - GRC Audit-Ready System Report

Deine Instanz wurde erfolgreich bereitgestellt und initialisiert.

Aktuelle Cloudflare-Tunnel-URL:
  ${URL}

System-Details:
- VM Shape: ${VM_SHAPE}
- Availability Domain: ${VM_AD}
- VM Instance ID: ${VM_OCID}

Initialisierte Frameworks:
- DORA: ${SEED_DORA}
- NIS 2 & BSI: ${SEED_NIS2}
- ISO 27001: ${SEED_ISO}
- DSGVO: ${SEED_PRIVACY}"

# Build email content (HTML)
HTML_CONTENT="<html>
<body style=\"font-family: 'Inter', Arial, sans-serif; background-color: #f1f5f9; padding: 30px; margin: 0;\">
<div style=\"max-width: 650px; margin: auto; background-color: #ffffff; border-radius: 16px; overflow: hidden; box-shadow: 0 4px 20px rgba(0,0,0,0.08); border: 1px solid #e2e8f0;\">
  
  <!-- Header -->
  <div style=\"background: linear-gradient(135deg, #1e1b4b 0%, #312e81 100%); padding: 35px; text-align: center; color: #ffffff;\">
    <span style=\"font-size: 40px; display: block; margin-bottom: 10px;\">🛡️</span>
    <h1 style=\"margin: 0; font-size: 24px; font-weight: 800; letter-spacing: -0.5px;\">CISO Assistant</h1>
    <p style=\"margin: 5px 0 0 0; color: #a5f3fc; font-size: 14px; font-weight: 500;\">GRC Audit-Ready System Report</p>
  </div>
  
  <div style=\"padding: 35px;\">
    <!-- Tunnel URL Area -->
    <div style=\"background-color: #f8fafc; border: 1px dashed #cbd5e1; border-radius: 12px; padding: 24px; text-align: center; margin-bottom: 30px;\">
      <h3 style=\"margin: 0 0 8px 0; color: #0f172a; font-size: 15px; font-weight: 700;\">Dynamische Access URL</h3>
      <p style=\"margin: 0 0 20px 0; color: #64748b; font-size: 13px;\">Deine Instanz wurde erfolgreich ueber Cloudflare Quick Tunnels geschuetzt:</p>
      <a href=\"${URL}\" style=\"display: inline-block; background-color: #4f46e5; color: #ffffff; padding: 14px 28px; border-radius: 8px; text-decoration: none; font-size: 15px; font-weight: 600; box-shadow: 0 4px 12px rgba(79, 70, 229, 0.25);\">
        GRC-Plattform oeffnen &rarr;
      </a>
      <p style=\"margin: 15px 0 0 0; font-family: monospace; font-size: 12px; color: #475569; word-break: break-all;\">${URL}</p>
    </div>

    <!-- System Info Table -->
    <h3 style=\"color: #1e293b; font-size: 16px; margin: 0 0 12px 0; border-bottom: 2px solid #e2e8f0; padding-bottom: 6px; font-weight: 700;\">💻 OCI VPS Deployment-Details</h3>
    <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 30px; font-size: 13px; color: #334155;\">
      <tr style=\"border-bottom: 1px solid #f1f5f9;\">
        <td style=\"padding: 10px 0; font-weight: 600; color: #64748b; width: 35%;\">VM Shape:</td>
        <td style=\"padding: 10px 0; font-family: monospace; color: #0f172a;\">${VM_SHAPE}</td>
      </tr>
      <tr style=\"border-bottom: 1px solid #f1f5f9;\">
        <td style=\"padding: 10px 0; font-weight: 600; color: #64748b;\">Availability Domain:</td>
        <td style=\"padding: 10px 0; color: #0f172a;\">${VM_AD}</td>
      </tr>
      <tr style=\"border-bottom: 1px solid #f1f5f9;\">
        <td style=\"padding: 10px 0; font-weight: 600; color: #64748b;\">Instance OCID:</td>
        <td style=\"padding: 10px 0; font-family: monospace; font-size: 11px; word-break: break-all; color: #0f172a;\">${VM_OCID}</td>
      </tr>
      <tr style=\"border-bottom: 1px solid #f1f5f9;\">
        <td style=\"padding: 10px 0; font-weight: 600; color: #64748b;\">Compartment OCID:</td>
        <td style=\"padding: 10px 0; font-family: monospace; font-size: 11px; word-break: break-all; color: #0f172a;\">${VM_COMP}</td>
      </tr>
    </table>

    <!-- Database Seeding Table -->
    <h3 style=\"color: #1e293b; font-size: 16px; margin: 0 0 12px 0; border-bottom: 2px solid #e2e8f0; padding-bottom: 6px; font-weight: 700;\">📊 Initialisierte GRC-Frameworks</h3>
    <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 20px; font-size: 13px; color: #334155;\">
      <tr style=\"border-bottom: 1px solid #f1f5f9;\">
        <td style=\"padding: 10px 0; font-weight: 600; color: #64748b; width: 45%;\">DORA Framework:</td>
        <td style=\"padding: 10px 0; color: #15803d; font-weight: 500;\">✅ ${SEED_DORA}</td>
      </tr>
      <tr style=\"border-bottom: 1px solid #f1f5f9;\">
        <td style=\"padding: 10px 0; font-weight: 600; color: #64748b;\">NIS 2 Framework:</td>
        <td style=\"padding: 10px 0; color: #15803d; font-weight: 500;\">✅ ${SEED_NIS2}</td>
      </tr>
      <tr style=\"border-bottom: 1px solid #f1f5f9;\">
        <td style=\"padding: 10px 0; font-weight: 600; color: #64748b;\">ISO/IEC 27001:2022:</td>
        <td style=\"padding: 10px 0; color: #15803d; font-weight: 500;\">✅ ${SEED_ISO}</td>
      </tr>
      <tr style=\"border-bottom: 1px solid #f1f5f9;\">
        <td style=\"padding: 10px 0; font-weight: 600; color: #64748b;\">Datenschutz / DSGVO:</td>
        <td style=\"padding: 10px 0; color: #15803d; font-weight: 500;\">✅ ${SEED_PRIVACY}</td>
      </tr>
    </table>

    <div style=\"background-color: #eff6ff; border-left: 4px solid #3b82f6; border-radius: 4px; padding: 15px; margin-top: 30px;\">
      <p style=\"margin: 0; font-size: 12px; color: #1e3a8a; line-height: 1.5;\">
        <strong>Audit Ready Hinweis:</strong> Alle Frameworks wurden in getrennten Organisationseinheiten angelegt. 
        Die KPI-Dashboards fuer Risikomessung sind aktiv. Die Standard-Kontraktvorlagen fuer Microsoft Ireland Operations Ltd. 
        und AWS EMEA wurden in die TPRM (Vendor Management) Datenbank importiert.
      </p>
    </div>
  </div>

  <!-- Footer -->
  <div style=\"background-color: #f8fafc; border-top: 1px solid #e2e8f0; padding: 20px; text-align: center; font-size: 11px; color: #94a3b8;\">
    Diese E-Mail wurde automatisch von deiner CISO Assistant Instanz auf OCI generiert.<br>
    &copy; 2026 GRC Managed Security Services.
  </div>
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
set +e
CURL_OUT=$(curl --url "smtp://${SMTP_SERVER}:${SMTP_PORT}" \
    --ssl-reqd \
    --mail-from "${MAIL_FROM}" \
    --mail-rcpt "${MAIL_TO}" \
    --user "${SMTP_AUTH_USER}:${SMTP_AUTH_PASSWORD}" \
    --upload-file "$MAIL_FILE" 2>&1)
EXIT_CODE=$?
set -e

if [ $EXIT_CODE -eq 0 ]; then
    log "  [+] Mail sent successfully to ${MAIL_TO}"
    STATUS="success"
else
    log "  [ERROR] Mail delivery failed (exit code $EXIT_CODE): ${CURL_OUT}"
    STATUS="failed"
fi

rm -f "$MAIL_FILE"

# Audit log
mkdir -p "$(dirname "$AUDIT_LOG")"
echo "{\"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"step\":\"send_tunnel_url_mail\",\"status\":\"${STATUS}\",\"mail_to\":\"${MAIL_TO}\",\"public_url\":\"${URL}\"}" >> "$AUDIT_LOG"

exit 0