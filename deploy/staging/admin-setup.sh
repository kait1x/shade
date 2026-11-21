#!/bin/bash
# Shade v2 STAGING — административная установка. ВЫПОЛНЯЕТ ВЛАДЕЛЕЦ через root SSH.
# Разрешение владельца от 17.11.2026: systemd shade-staging + Caddy alpha-блок
# + ALPHA_PUBLIC_ORIGIN. Production v1 (shade.service, sslip-блок, /var/lib/shade,
# /etc/shade) НЕ затрагивается. Google OAuth остаётся отключённым.
#
# Запуск:  bash /opt/shade-staging/admin-setup.sh
# Откат:   см. команды в конце файла и docs/STAGING_INSTALL_PLAN.md
set -euo pipefail
STAMP=$(date +%Y%m%d-%H%M%S)
REL=/opt/shade-staging/releases/20261117-213644
ENVF=/var/lib/shade-staging/staging.env
BLOCK=/opt/shade-staging/Caddyfile.staging-block
UNIT=/opt/shade-staging/shade-staging.service

echo "== 0. prerequisites =="
[ -f "$UNIT" ] || { echo "missing $UNIT" >&2; exit 1; }
[ -f "$BLOCK" ] || { echo "missing $BLOCK" >&2; exit 1; }
[ -d "$REL/server" ] || { echo "missing release $REL" >&2; exit 1; }
grep -q '^ALPHA_STORAGE_SECRET=.' "$ENVF" || { echo "staging.env not filled" >&2; exit 1; }

echo "== 1. stop manual staging process (free :3101) =="
if [ -f /var/lib/shade-staging/alpha.pid ]; then
  kill "$(cat /var/lib/shade-staging/alpha.pid)" 2>/dev/null || true
  sleep 2
fi

echo "== 2. systemd: install + enable shade-staging =="
install -m 644 "$UNIT" /etc/systemd/system/shade-staging.service
systemctl daemon-reload
systemctl enable --now shade-staging
sleep 2
systemctl is-active shade-staging
curl -fsS -m 5 http://127.0.0.1:3101/api/health; echo

echo "== 3. Caddy: backup -> append alpha block -> validate -> reload =="
cp -a /etc/caddy/Caddyfile "/var/backups/shade/Caddyfile-staging-$STAMP"
echo "backup: /var/backups/shade/Caddyfile-staging-$STAMP"
if grep -q 'alpha.shadechat.ru' /etc/caddy/Caddyfile; then
  echo "alpha block already present — not appending"
else
  printf '\n' >> /etc/caddy/Caddyfile
  cat "$BLOCK" >> /etc/caddy/Caddyfile
fi
if ! caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile; then
  echo "VALIDATION FAILED — restoring backup, Caddy NOT reloaded" >&2
  cp -a "/var/backups/shade/Caddyfile-staging-$STAMP" /etc/caddy/Caddyfile
  exit 1
fi
systemctl reload caddy

echo "== 4. ALPHA_PUBLIC_ORIGIN -> https://alpha.shadechat.ru =="
sed -i 's#^ALPHA_PUBLIC_ORIGIN=.*#ALPHA_PUBLIC_ORIGIN=https://alpha.shadechat.ru#' "$ENVF"
systemctl restart shade-staging
sleep 2
curl -fsS -m 5 http://127.0.0.1:3101/api/health; echo

echo "== 5. HTTPS check (Let's Encrypt issuance may take up to ~60s) =="
OK=0
for i in $(seq 1 12); do
  if curl -fsS -m 10 https://alpha.shadechat.ru/api/health; then OK=1; break; fi
  echo "  waiting for DNS/certificate ($i/12)..."; sleep 5
done
echo
if [ "$OK" != 1 ]; then
  echo "WARNING: HTTPS not ready yet (DNS propagation or ACME). Caddy will retry automatically."
  echo "Check: journalctl -u caddy -n 30 --no-pager | grep -iE 'certificate|obtain|error'"
  echo "DNS:   dig alpha.shadechat.ru A +short @1.1.1.1"
fi

echo "== 6. production untouched verification =="
systemctl is-active shade caddy
curl -fsS -m 5 http://127.0.0.1:3000/api/health; echo
curl -fsS -m 10 https://13-143-207-108.sslip.io/api/health; echo
grep -c '13-143-207-108.sslip.io' /etc/caddy/Caddyfile   # sslip block still present

echo "ADMIN_SETUP_DONE stamp=$STAMP"
echo
echo "Rollback (if needed):"
echo "  systemctl disable --now shade-staging"
echo "  cp -a /var/backups/shade/Caddyfile-staging-$STAMP /etc/caddy/Caddyfile"
echo "  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && systemctl reload caddy"
echo "  sed -i 's#^ALPHA_PUBLIC_ORIGIN=.*#ALPHA_PUBLIC_ORIGIN=http://127.0.0.1:3101#' $ENVF"