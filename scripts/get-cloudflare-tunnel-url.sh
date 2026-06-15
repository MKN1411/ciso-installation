#!/bin/bash
# ==============================================================================
# get-cloudflare-tunnel-url.sh
# Extracts the current trycloudflare.com URL from cloudflared.log.
# Returns the URL on stdout, or exits with code 1 if not found.
# ==============================================================================
set -euo pipefail

LOGFILE="${1:-/var/log/cloudflared.log}"
TIMEOUT="${2:-30}"  # Max seconds to wait for a URL to appear

if [ ! -f "$LOGFILE" ]; then
    echo "ERROR: Logfile not found: $LOGFILE" >&2
    exit 1
fi

# Try up to $TIMEOUT seconds for the URL to appear
END=$((SECONDS + TIMEOUT))
while [ $SECONDS -lt $END ]; do
    URL=$(grep -oP 'https://[a-z0-9-]+\.trycloudflare\.com' "$LOGFILE" | tail -1)
    if [ -n "$URL" ]; then
        echo "$URL"
        exit 0
    fi
    sleep 2
done

echo "ERROR: No trycloudflare.com URL found in $LOGFILE after ${TIMEOUT}s" >&2
exit 1