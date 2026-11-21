#!/bin/bash
# Shade v2 STAGING deployment on the VPS. Isolated from production v1:
# separate user, directories, port (3101 loopback), secrets and OAuth client.
# NEVER writes into /var/lib/shade or /etc/shade; never removes the sslip block.
#
# Usage (on the VPS, from an upload dir prepared by the owner):
#   bash staging-deploy.sh /root/shade-alpha-upload
# Upload must contain:
#   server/            (server sources incl. multidevice/, tools/, package*.json;
#                       NO .env, NO data/, NO certs, NO node_modules)
#   client/web/        (alpha shell, protocol, sw, manifests)
#   client/build/web-alpha/   (Flutter web release output)
#   shade-alpha.service       (from deploy/alpha/shade-alpha.service.example)
#   Caddyfile.alpha-block     (single alpha.shadechat.ru block to MERGE)
#   alpha.env                 (filled by owner from deploy/alpha/.env.example;
#                              secrets generated ON the server, never in Git)
# Owner approval required: this creates a system service and merges a Caddy
# block (production Caddy change). The script backs up Caddyfile first.
set -euo pipefail
UP=${1:?usage: staging-deploy.sh <upload-dir>}
exec 9>/run/lock/shade-alpha-deploy.lock
flock -n 9 || { echo 'Another staging deployment is running' >&2; exit 1; }
STAMP=$(date +%Y%m%d-%H%M%S)
export PATH=/opt/node/bin:$PATH

[ -d "$UP/server" ] || { echo 'upload/server missing' >&2; exit 1; }
[ -f "$UP/alpha.env" ] || { echo 'upload/alpha.env missing (owner-filled)' >&2; exit 1; }
grep -q '^SHADE_ENV=alpha' "$UP/alpha.env" || { echo 'alpha.env must set SHADE_ENV=alpha' >&2; exit 1; }
grep -q 'REPLACE_WITH' "$UP/alpha.env" && { echo 'alpha.env still has placeholders' >&2; exit 1; }

# 1. User + directories (idempotent).
id shade-alpha >/dev/null 2>&1 || useradd --system --home /opt/shade-alpha --shell /usr/sbin/nologin shade-alpha
install -d -m 755 /opt/shade-alpha/releases/$STAMP
install -d -m 750 -o shade-alpha -g shade-alpha /var/lib/shade-alpha/data
install -d -m 750 -o shade-alpha -g shade-alpha /var/lib/shade-alpha/checkpoints
install -d -m 750 -o root -g shade-alpha /etc/shade-alpha

# 2. Code + web assets.
cp -a "$UP/server" /opt/shade-alpha/releases/$STAMP/server
mkdir -p /opt/shade-alpha/releases/$STAMP/client
cp -a "$UP/client/web" /opt/shade-alpha/releases/$STAMP/client/web
cp -a "$UP/client/build/web-alpha" /opt/shade-alpha/releases/$STAMP/client/build/web-alpha 2>/dev/null || {
  install -d /opt/shade-alpha/releases/$STAMP/client/build
  cp -a "$UP/client/build/web-alpha" /opt/shade-alpha/releases/$STAMP/client/build/web-alpha; }
(cd /opt/shade-alpha/releases/$STAMP/server && npm ci --omit=dev --no-audit --no-fund --loglevel=error)
node --check /opt/shade-alpha/releases/$STAMP/server/alpha.mjs
chown -R root:root /opt/shade-alpha/releases/$STAMP
chmod -R go-w /opt/shade-alpha/releases/$STAMP
ln -sfn /opt/shade-alpha/releases/$STAMP /opt/shade-alpha/current

# 3. Secrets (owner-provided file; permissions hardened).
install -m 640 -o root -g shade-alpha "$UP/alpha.env" /etc/shade-alpha/alpha.env

# 4. systemd unit.
install -m 644 "$UP/shade-alpha.service" /etc/systemd/system/shade-alpha.service
systemctl daemon-reload
systemctl enable shade-alpha
systemctl restart shade-alpha
READY=0
for i in $(seq 1 20); do
  if curl -fsS -m 2 http://127.0.0.1:3101/api/health >/dev/null; then READY=1; break; fi
  sleep 1
done
[ "$READY" = 1 ] || { echo 'shade-alpha health check failed' >&2; journalctl -u shade-alpha -n 20 --no-pager; exit 1; }

# 5. Caddy: MERGE the alpha block (backup + validate before reload).
if [ -f "$UP/Caddyfile.alpha-block" ]; then
  cp -a /etc/caddy/Caddyfile "/var/backups/shade/Caddyfile-$STAMP"
  if grep -q 'alpha.shadechat.ru' /etc/caddy/Caddyfile; then
    echo 'alpha block already present; review manually before replacing' >&2
  else
    cat "$UP/Caddyfile.alpha-block" >> /etc/caddy/Caddyfile
  fi
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
  systemctl reload caddy
fi

systemctl is-active shade-alpha caddy
curl -fsS -m 5 http://127.0.0.1:3101/api/health
echo " STAGING_DEPLOY_OK $STAMP"
echo 'Next: DNS alpha A record, OAuth Web client for https://alpha.shadechat.ru,'
echo 'then migration dry-run per docs/V2_DEPLOYMENT.md §3.'