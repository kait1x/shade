#!/bin/bash
# Usage: deploy.sh <upload-dir>. Preserves data, configuration and old releases.
set -euo pipefail
exec 9>/run/lock/shade-deploy.lock
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; }
UP=${1:-/root/shade-upload}
STAMP=$(date +%Y%m%d-%H%M%S)
REL=/opt/shade/releases/$STAMP
export PATH=/opt/node/bin:$PATH
install -d -m 700 /var/backups/shade
caddy validate --config "$UP/Caddyfile" --adapter caddyfile
# Snapshot before changing any live files. Never prune data or releases here.
if [ -d /var/lib/shade/data ] && [ -n "$(ls -A /var/lib/shade/data)" ]; then
  tar -czf "/var/backups/shade/data-predeploy-$STAMP.tgz" -C /var/lib/shade data
fi
cp -a /etc/caddy/Caddyfile "/var/backups/shade/Caddyfile-$STAMP"
if [ -f /etc/shade/shade.env ]; then
  cp -a /etc/shade/shade.env "/var/backups/shade/env-$STAMP"
fi
install -d -m 755 "$REL"
tar -xzf "$UP/shade-server.tgz" -C "$REL"
cd "$REL"
npm ci --omit=dev --no-audit --no-fund --loglevel=error
node --check server.js
chown -R root:root "$REL"
chmod -R go-w "$REL"
# First migration is only allowed into an empty data directory.
if [ -d "$UP/data" ]; then
  if [ -n "$(ls -A /var/lib/shade/data)" ]; then
    echo 'Existing live data preserved; uploaded snapshot not imported'
  else
    cp -a "$UP/data/." /var/lib/shade/data/
  fi
fi
chown -R shade:shade /var/lib/shade
chmod 700 /var/lib/shade/data
find /var/lib/shade/data -type f -exec chmod 600 {} +
if [ ! -f /etc/shade/shade.env ]; then
  umask 027
  cat > /etc/shade/shade.env <<EOF
NODE_ENV=production
TLS_TERMINATED_BY_PROXY=1
BIND_HOST=127.0.0.1
PORT=3000
TRUST_PROXY=1
DATA_DIR=/var/lib/shade/data
ALLOWED_ORIGINS=https://13-143-207-108.sslip.io
WS_HOST=wss://13-143-207-108.sslip.io
DASHBOARD_PASS=$(openssl rand -hex 32)
EOF
  if [ -f "$UP/extra.env" ]; then cat "$UP/extra.env" >> /etc/shade/shade.env; fi
  chown root:shade /etc/shade/shade.env
  chmod 640 /etc/shade/shade.env
fi
# Smoke-test the candidate against a private copy, before switching the service.
STAGE=$(mktemp -d /var/lib/shade/stage.XXXXXX)
cp -a /var/lib/shade/data "$STAGE/data"
chown -R shade:shade "$STAGE"
chmod 700 "$STAGE"
cleanup() { if [ -n "${CANDIDATE:-}" ]; then kill "$CANDIDATE" 2>/dev/null || true; wait "$CANDIDATE" 2>/dev/null || true; fi; }
trap cleanup EXIT
set -a
. /etc/shade/shade.env
set +a
DATA_DIR="$STAGE/data" PORT=3100 runuser -u shade -- /opt/node/bin/node --max-old-space-size=256 "$REL/server.js" > "$STAGE/smoke.log" 2>&1 &
CANDIDATE=$!
READY=0
for i in $(seq 1 20); do
  if curl -fsS -m 2 http://127.0.0.1:3100/api/health >/dev/null; then READY=1; break; fi
  sleep 1
done
if [ "$READY" != 1 ]; then echo "Candidate failed; inspect $STAGE/smoke.log" >&2; exit 1; fi
cleanup
CANDIDATE=
OLD=$(readlink -f /opt/shade/current || true)
install -m 644 "$UP/shade.service" /etc/systemd/system/shade.service
ln -sfn "$REL" /opt/shade/current
systemctl daemon-reload
systemctl enable shade
systemctl restart shade
READY=0
for i in $(seq 1 20); do
  if curl -fsS -m 2 http://127.0.0.1:3000/api/health >/dev/null; then READY=1; break; fi
  sleep 1
done
if [ "$READY" != 1 ]; then
  if [ -n "$OLD" ]; then ln -sfn "$OLD" /opt/shade/current; systemctl restart shade; fi
  echo 'Service health check failed' >&2; exit 1
fi
install -m 644 "$UP/Caddyfile" /etc/caddy/Caddyfile
systemctl enable caddy
systemctl reload caddy
install -m 755 "$UP/shade-backup.sh" /usr/local/sbin/shade-backup
install -m 755 "$UP/shade-healthcheck.sh" /usr/local/sbin/shade-healthcheck
printf '17 3 * * * root /usr/local/sbin/shade-backup\n*/2 * * * * root /usr/local/sbin/shade-healthcheck\n' > /etc/cron.d/shade
systemctl is-active shade caddy
curl -fsS -m 5 http://127.0.0.1:3000/api/health
echo " DEPLOY_OK $REL"
