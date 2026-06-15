#!/bin/bash
# ==============================================================================
# test-ciso-health.sh
# Runs local and (optionally) public health checks against CISO Assistant.
# ==============================================================================
set -euo pipefail

LOCAL_URL="${1:-https://localhost:8443}"
PUBLIC_URL="${2:-}"
TIMEOUT="${3:-10}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
fail() { log "FAILED: $*"; exit 1; }

# -- Local health check --
log "Checking local health: $LOCAL_URL/api/health/"
LOCAL_RESULT=$(curl -k -s --max-time "$TIMEOUT" "$LOCAL_URL/api/health/" 2>&1) || true
if echo "$LOCAL_RESULT" | grep -q '"status":"ok"'; then
    log "  [+] Local health: OK"
else
    fail "Local health check returned: $LOCAL_RESULT"
fi

# -- Local web check (302 or 200) --
log "Checking local web: $LOCAL_URL"
LOCAL_WEB=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$LOCAL_URL" 2>&1) || true
if [ "$LOCAL_WEB" = "302" ] || [ "$LOCAL_WEB" = "200" ]; then
    log "  [+] Local web: HTTP $LOCAL_WEB"
else
    fail "Local web returned HTTP $LOCAL_WEB (expected 302 or 200)"
fi

# -- Public health check (if URL provided) --
if [ -n "$PUBLIC_URL" ]; then
    log "Checking public health: $PUBLIC_URL/api/health/"
    PUBLIC_RESULT=$(curl -s --max-time "$TIMEOUT" "$PUBLIC_URL/api/health/" 2>&1) || true
    if echo "$PUBLIC_RESULT" | grep -q '"status":"ok"'; then
        log "  [+] Public health: OK"
    else
        fail "Public health check returned: $PUBLIC_RESULT"
    fi

    log "Checking public web: $PUBLIC_URL"
    PUBLIC_WEB=$(curl -s -o /dev/null -w "%{http_code}" --max-time "$TIMEOUT" "$PUBLIC_URL" 2>&1) || true
    if [ "$PUBLIC_WEB" = "302" ] || [ "$PUBLIC_WEB" = "200" ]; then
        log "  [+] Public web: HTTP $PUBLIC_WEB"
    else
        fail "Public web returned HTTP $PUBLIC_WEB (expected 302 or 200)"
    fi
fi

log "All health checks passed."