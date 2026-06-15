# Audit-Logging-Modell für CISO Assistant Setup

## Übersicht

Alle technischen Schritte während der Installation und des laufenden Betriebs werden strukturiert protokolliert. Die Logs befinden sich unter `/var/log/ciso-onboarding/` und dienen der Nachvollziehbarkeit für Audits.

## Log-Dateien

| Datei | Zweck |
|---|---|
| `setup-audit.jsonl` | JSONL-formatierte Audit-Events (maschinenlesbar) |
| `setup-status.jsonl` | Installations-Statusübergänge |
| `health-checks.jsonl` | Ergebnisse der Health-Checks |
| `mail-events.jsonl` | Mail-Versand-Ereignisse |
| `cloudflare-url-sync.log` | Detail-Log des URL-Sync-Prozesses |

## Audit-Event-Format

Jede Zeile in `setup-audit.jsonl` ist ein eigenständiges JSON-Objekt:

```json
{
  "timestamp": "2026-06-15T12:23:38Z",
  "step": "patch_ciso_compose",
  "status": "success",
  "public_url": "https://example.trycloudflare.com",
  "public_host": "example.trycloudflare.com",
  "services_changed": ["backend", "huey", "frontend", "caddy"],
  "backup_path": "/opt/ciso-setup-archive/20260615-122300/docker-compose.yml",
  "validation": "docker compose config succeeded"
}
```

## Sicherheitsregeln

1. **Keine Secrets in Logs**: SMTP-Passwörter, Private Keys, GitHub PATs und OCI API Keys
   werden niemals im Klartext protokolliert.
2. **Status only**: Protokolliert wird *dass* ein Secret erstellt/gespeichert wurde, wo es
   liegt und welche Dateirechte gesetzt sind – niemals der Wert selbst.
3. **Root-only Zugriff**: Log-Verzeichnis und Dateien sind nur für root lesbar.