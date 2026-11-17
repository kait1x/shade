#!/bin/bash
# READ-ONLY production audit for the v1 -> v2 migration (Stage 1).
# Run from the owner machine with SSH key access:
#   bash deploy/staging/production-audit.sh [user@host] [ssh-key-path]
# Defaults: root@13.143.207.108, ~/.ssh/id_ed25519_pl
# NEVER prints secrets, tokens, private keys or message contents.
# It does not modify anything on the server: no writes, no restarts.
set -euo pipefail
TARGET=${1:-root@13.143.207.108}
KEY=${2:-$HOME/.ssh/id_ed25519_pl}
SSH=(ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 "$TARGET")

echo "== connectivity =="
"${SSH[@]}" 'echo SSH_OK; hostname; uptime; date -u'

echo "== runtime versions =="
"${SSH[@]}" '/opt/node/bin/node --version 2>/dev/null || node --version; caddy version 2>/dev/null | head -1; cat /etc/debian_version'

echo "== services (state only) =="
"${SSH[@]}" 'systemctl is-active shade caddy shade-alpha 2>/dev/null; systemctl show shade -p NRestarts -p MemoryCurrent -p ActiveEnterTimestamp 2>/dev/null'

echo "== resources =="
"${SSH[@]}" 'df -h / /var; free -m | head -2'

echo "== releases =="
"${SSH[@]}" 'readlink -f /opt/shade/current; ls -1 /opt/shade/releases 2>/dev/null | tail -5'

echo "== data inventory (names/sizes only, no contents) =="
"${SSH[@]}" 'ls -la /var/lib/shade/data | head -60; du -sh /var/lib/shade/data'

echo "== backups inventory =="
"${SSH[@]}" 'ls -la /var/backups/shade | tail -8'

echo "== backup readability probe (listing only, no extraction) =="
"${SSH[@]}" 'L=$(ls -1t /var/backups/shade/data-*.tgz 2>/dev/null | head -1); if [ -n "$L" ]; then tar -tzf "$L" | head -20; echo "BACKUP_LIST_OK $L"; else echo NO_BACKUP_FOUND; fi'

echo "== cron / healthcheck =="
"${SSH[@]}" 'cat /etc/cron.d/shade 2>/dev/null; ls -la /usr/local/sbin/shade-backup /usr/local/sbin/shade-healthcheck 2>/dev/null'

echo "== recent service ERRORS only (no info logs, no payloads) =="
"${SSH[@]}" 'journalctl -u shade -p err -n 20 --no-pager 2>/dev/null | tail -20'

echo "== listening sockets (loopback expectation) =="
"${SSH[@]}" 'ss -ltnp 2>/dev/null | grep -E ":(3000|3100|3101|80|443|22)\b" || true'

echo "== Caddyfile (routing only; contains no secrets) =="
"${SSH[@]}" 'cat /etc/caddy/Caddyfile'

echo "== env file metadata (NOT contents) =="
"${SSH[@]}" 'ls -la /etc/shade/shade.env; grep -oE "^[A-Z_]+" /etc/shade/shade.env | sort'

echo AUDIT_DONE