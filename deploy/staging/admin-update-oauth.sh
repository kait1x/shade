#!/bin/bash
# Shade v2 STAGING — переключение на OAuth-релиз (iOS handoff + allowlist).
# ВЫПОЛНЯЕТ ВЛАДЕЛЕЦ через root SSH. Production не затрагивается.
# Запуск: bash /opt/shade-staging/admin-update-oauth.sh
#
# Перед запуском (если ещё не сделано): заполнить в /var/lib/shade-staging/staging.env
#   ALPHA_GOOGLE_CLIENT_ID=<staging Web Client ID>
#   ALPHA_GOOGLE_CLIENT_SECRET=<staging Web Client secret>
# (docs/STAGING_OAUTH_SETUP.md). Без них Google-вход останется отключён —
# остальной функционал релиза работает.
set -euo pipefail
NEW=/opt/shade-staging/releases/20261118-005500
OLD=$(readlink -f /opt/shade-staging/current)
echo "current: $OLD"
echo "new:     $NEW"
[ -d "$NEW/server" ] || { echo "new release missing" >&2; exit 1; }
[ -d "$NEW/server/node_modules" ] || { echo "run npm ci in new release first (shade-staging)" >&2; exit 1; }
[ -f "$NEW/MANIFEST.sha256" ] || { echo "manifest missing" >&2; exit 1; }

ln -sfn "$NEW" /opt/shade-staging/current
systemctl restart shade-staging
sleep 2
systemctl is-active shade-staging
curl -fsS -m 5 http://127.0.0.1:3101/api/health; echo
curl -fsS -m 10 https://alpha.shadechat.ru/api/health; echo
echo "== googleConfigured =="
curl -fsS -m 10 https://alpha.shadechat.ru/api/session | grep -o '"googleConfigured":[a-z]*' || true

echo "== production untouched =="
systemctl is-active shade caddy
curl -fsS -m 5 http://127.0.0.1:3000/api/health; echo

echo "UPDATE_DONE"
echo "Rollback: ln -sfn $OLD /opt/shade-staging/current && systemctl restart shade-staging"