# Cloudflare Tunnel URL Synchronisierung

## Problemstellung

Der CISO Assistant in der OCI Community-Version nutzt einen temporären Cloudflare Quick Tunnel (trycloudflare.com). Jedes Mal wenn der Tunnel neu startet (z. B. nach VM-Neustart oder Service-Restart), ändert sich die öffentliche URL.

Da die docker-compose.yml **vier Services** (backend, huey, frontend, caddy) mit der aktuellen URL konfiguriert, müssen alle vier Bereiche aktualisiert werden, sobald sich die Tunnel-URL ändert.

## Automatisierte Lösung

### Architektur

```
cloudflared.service (systemd)
  │
  ├── schreibt URL → /var/log/cloudflared.log
  │
  └── ciso-tunnel-url-sync.timer (alle 5 Minuten)
        │
        └── ciso-tunnel-url-sync.service (oneshot)
              │
              └── /usr/local/bin/patch-ciso-compose.py
                    │
                    ├── 1. Extrahiert URL aus cloudflared.log
                    ├── 2. Backup von docker-compose.yml nach /opt/ciso-setup-archive/
                    ├── 3. Patched: backend, huey, frontend, caddy
                    ├── 4. Validiert mit `docker compose config`
                    ├── 5. Startet Container neu
                    └── 6. Audit-Log in /var/log/ciso-onboarding/
```

### Gepatche Services

| Service | Umgebungsvariablen |
|---|---|
| **backend** | `ALLOWED_HOSTS=backend,localhost,<PUBLIC_HOST>`<br>`CISO_ASSISTANT_URL=<PUBLIC_URL>`<br>`CSRF_TRUSTED_ORIGINS=https://trycloudflare.com,https://*.trycloudflare.com` |
| **huey** | `ALLOWED_HOSTS=backend,localhost,<PUBLIC_HOST>`<br>`CISO_ASSISTANT_URL=<PUBLIC_URL>` |
| **frontend** | `PUBLIC_BACKEND_API_EXPOSED_URL=<PUBLIC_URL>/api`<br>`ORIGIN=<PUBLIC_URL>` |
| **caddy** | Caddyfile: `localhost:443, <PUBLIC_HOST>:443 { ... }` |

### Backup-Strategie

- Vor jeder Änderung: Backup nach `/opt/ciso-setup-archive/<timestamp>/`
- Bei Validierungsfehler: Automatische Wiederherstellung

### Audit-Log

Alle Aktionen werden in `/var/log/ciso-onboarding/setup-audit.jsonl` protokolliert.

```json
{
  "timestamp": "2026-06-15T12:23:38Z",
  "step": "patch_ciso_compose",
  "status": "success",
  "public_url": "https://xyz.trycloudflare.com",
  "services_changed": ["backend", "huey", "frontend", "caddy"]
}