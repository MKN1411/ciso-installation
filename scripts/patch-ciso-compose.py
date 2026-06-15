#!/usr/bin/env python3
"""
CISO Assistant Compose Patcher
===============================
Patches backend, huey, frontend and caddy services in docker-compose.yml
with a new trycloudflare.com URL extracted from cloudflared.log.

Usage:
    python3 patch-ciso-compose.py [--compose /path/to/docker-compose.yml]
                                  [--url https://xxx.trycloudflare.com]

If --url is omitted, the script reads /var/log/cloudflared.log for the URL.
"""

import sys
import os
import re
import json
import shutil
import argparse
import subprocess
from datetime import datetime
from pathlib import Path


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
AUDIT_LOG = "/var/log/ciso-onboarding/setup-audit.jsonl"
CLOUDFLARED_LOG = "/var/log/cloudflared.log"
BACKUP_DIR = "/opt/ciso-setup-archive"
COMPOSE_PATH = "/home/ubuntu/ciso-assistant/docker-compose.yml"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def log_audit(entry: dict):
    """Write a JSON line to the audit log (no secrets)."""
    os.makedirs(os.path.dirname(AUDIT_LOG), exist_ok=True)
    with open(AUDIT_LOG, "a") as f:
        f.write(json.dumps(entry, default=str) + "\n")


def get_tunnel_url(log_path: str = CLOUDFLARED_LOG) -> str | None:
    """Extract the latest trycloudflare.com URL from cloudflared.log."""
    if not os.path.exists(log_path):
        return None
    with open(log_path, "r", errors="ignore") as f:
        content = f.read()
    match = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", content)
    return match.group(0) if match else None


def derive_host(public_url: str) -> str:
    """Extract hostname from https://xxx.trycloudflare.com"""
    return public_url.replace("https://", "")


def backup_file(src: str) -> str:
    """Copy file to timestamped backup directory."""
    ts = datetime.utcnow().strftime("%Y%m%d-%H%M%S")
    backup_path = os.path.join(BACKUP_DIR, ts)
    os.makedirs(backup_path, exist_ok=True)
    dest = os.path.join(backup_path, os.path.basename(src))
    shutil.copy2(src, dest)
    return dest


def read_file(path: str) -> str:
    with open(path, "r") as f:
        return f.read()


def write_file(path: str, content: str):
    with open(path, "w") as f:
        f.write(content)


# ---------------------------------------------------------------------------
# Patching logic
# ---------------------------------------------------------------------------
def patch_compose(compose_content: str, public_url: str, public_host: str) -> str:
    """
    Apply all four patches to the docker-compose.yml content.
    Returns the patched content as a string.
    """
    lines = compose_content.splitlines()
    result = []
    i = 0
    in_block = None
    block_indent = 0
    block_lines = []
    services_changed = []

    def flush_block():
        nonlocal block_lines, in_block
        if in_block == "backend_env":
            block_lines = [l for l in block_lines if not l.lstrip().startswith("- ALLOWED_HOSTS=")]
            block_lines = [l for l in block_lines if not l.lstrip().startswith("- CISO_ASSISTANT_URL=")]
            block_lines = [l for l in block_lines if not l.lstrip().startswith("- CSRF_TRUSTED_ORIGINS=")]
            indent = " " * (block_indent + 6)
            block_lines.append(f'{indent}- ALLOWED_HOSTS=backend,localhost,{public_host}')
            block_lines.append(f'{indent}- CISO_ASSISTANT_URL={public_url}')
            block_lines.append(f'{indent}- CSRF_TRUSTED_ORIGINS=https://trycloudflare.com,https://*.trycloudflare.com')
            services_changed.append("backend")
            in_block = None
        elif in_block == "huey_env":
            block_lines = [l for l in block_lines if not l.lstrip().startswith("- ALLOWED_HOSTS=")]
            block_lines = [l for l in block_lines if not l.lstrip().startswith("- CISO_ASSISTANT_URL=")]
            indent = " " * (block_indent + 6)
            block_lines.append(f'{indent}- ALLOWED_HOSTS=backend,localhost,{public_host}')
            block_lines.append(f'{indent}- CISO_ASSISTANT_URL={public_url}')
            services_changed.append("huey")
            in_block = None
        elif in_block == "frontend_env":
            block_lines = [l for l in block_lines if not l.lstrip().startswith("- PUBLIC_BACKEND_API_EXPOSED_URL=")]
            block_lines = [l for l in block_lines if not l.lstrip().startswith("- ORIGIN=")]
            indent = " " * (block_indent + 6)
            block_lines.append(f'{indent}- PUBLIC_BACKEND_API_EXPOSED_URL={public_url}/api')
            block_lines.append(f'{indent}- ORIGIN={public_url}')
            services_changed.append("frontend")
            in_block = None
        elif in_block == "caddy_cmd":
            new_caddyfile = f'''{block_indent}command: |
{block_indent}  sh -c 'cat > /tmp/Caddyfile <<EOF
{block_indent}  localhost:443, {public_host}:443 {{
{block_indent}    tls internal
{block_indent}    reverse_proxy /api/* backend:8000
{block_indent}    reverse_proxy /* frontend:3000
{block_indent}  }}
{block_indent}  EOF
{block_indent}  echo "----- ACTIVE CADDYFILE -----"
{block_indent}  cat /tmp/Caddyfile
{block_indent}  echo "----------------------------"
{block_indent}  caddy run --config /tmp/Caddyfile --adapter caddyfile' '''
            block_lines = new_caddyfile.rstrip().splitlines()
            services_changed.append("caddy")
            in_block = None
        result.extend(block_lines)

    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()

        # Detect service blocks
        if re.match(r"^\s+backend:\s*$", line):
            result.append(line)
            i += 1
            continue
        if re.match(r"^\s+huey:\s*$", line):
            result.append(line)
            i += 1
            continue
        if re.match(r"^\s+frontend:\s*$", line):
            result.append(line)
            i += 1
            continue
        if re.match(r"^\s+caddy:\s*$", line):
            result.append(line)
            i += 1
            continue

        # Detect environment blocks
        if stripped == "environment:" and i > 0:
            prev_line = lines[i - 1].strip()
            if prev_line in ("backend:", "huey:", "frontend:"):
                flush_block()
                block_indent = len(line) - len(line.lstrip())
                block_lines = [line]
                key = prev_line.replace(":", "")
                in_block = f"{key}_env"
                i += 1
                # Collect subsequent env lines
                while i < len(lines):
                    next_line = lines[i]
                    if next_line.strip() == "" or re.match(r"^\s+\w", next_line) and not next_line.lstrip().startswith("- "):
                        break
                    block_lines.append(next_line)
                    i += 1
                continue

        # Detect caddy command block
        if stripped == "command:" and i > 0:
            prev_line = lines[i - 1].strip()
            if prev_line == "caddy:":
                flush_block()
                block_indent = len(line) - len(line.lstrip())
                in_block = "caddy_cmd"
                # Collect all caddy command lines
                lines_in_block = [line]
                i += 1
                while i < len(lines):
                    next_line = lines[i]
                    # Check if we're back to a top-level key
                    if next_line.strip() and not next_line.startswith(" "):
                        break
                    lines_in_block.append(next_line)
                    i += 1
                block_lines = lines_in_block
                flush_block()
                continue

        flush_block()
        result.append(line)
        i += 1

    flush_block()
    return "\n".join(result)


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
def validate_compose(compose_path: str) -> bool:
    """Run 'docker compose config' to validate the YAML."""
    try:
        result = subprocess.run(
            ["docker", "compose", "config", "--quiet"],
            cwd=os.path.dirname(compose_path),
            capture_output=True,
            text=True,
            timeout=30
        )
        return result.returncode == 0
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="Patch docker-compose.yml for new Cloudflare URL")
    parser.add_argument("--compose", default=COMPOSE_PATH, help="Path to docker-compose.yml")
    parser.add_argument("--url", default=None, help="New public URL (https://xxx.trycloudflare.com)")
    args = parser.parse_args()

    compose_path = args.compose
    if not os.path.exists(compose_path):
        print(f"ERROR: Compose file not found: {compose_path}")
        sys.exit(1)

    # Get URL
    public_url = args.url or get_tunnel_url()
    if not public_url:
        print("ERROR: No Cloudflare URL found in cloudflared.log and --url not provided.")
        sys.exit(1)

    public_host = derive_host(public_url)
    print(f"Public URL : {public_url}")
    print(f"Public Host: {public_host}")

    # Read and patch
    original = read_file(compose_path)
    patched = patch_compose(original, public_url, public_host)

    # Backup
    backup_path = backup_file(compose_path)
    print(f"Backup saved to: {backup_path}")

    # Write patched file
    write_file(compose_path, patched)
    print(f"Patched: {compose_path}")

    # Validate
    if validate_compose(compose_path):
        print("Validation: docker compose config SUCCEEDED")
        status = "success"
    else:
        print("ERROR: docker compose config FAILED – restoring backup")
        shutil.copy2(backup_path, compose_path)
        status = "failed"

    # Audit log
    log_audit({
        "timestamp": datetime.utcnow().isoformat() + "Z",
        "step": "patch_ciso_compose",
        "status": status,
        "public_url": public_url,
        "public_host": public_host,
        "services_changed": ["backend", "huey", "frontend", "caddy"],
        "backup_path": backup_path,
        "validation": "docker compose config succeeded" if status == "success" else "docker compose config failed"
    })

    sys.exit(0 if status == "success" else 1)


if __name__ == "__main__":
    main()