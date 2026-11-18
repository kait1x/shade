#!/bin/bash
# Shade v2 STAGING — переключение на релиз 4ba238c (onboarding + pairing v2).
# ВЫПОЛНЯЕТ ВЛАДЕЛЕЦ через root SSH. Production v1 НЕ затрагивается:
# скрипт пишет только в /opt/shade-staging и рестартует shade-staging.
# Запуск: bash /opt/shade-staging/admin-update-v2-glm.sh
#
# Подготовка (до запуска): релиз загружен, npm ci выполнен от shade-staging,
# MANIFEST.sha256 сверен. Полная процедура: docs/STAGING_RELEASE_4ba238c.md.
# Отличия от admin-update-oauth.sh: MANIFEST проверяется по checksum (fail-closed),
# rollback печатается при ЛЮБОЙ ошибке (trap ERR), проверяется staging.env.
set -euo pipefail
NEW=/opt/shade-staging/releases/20261118-122400
OLD=$(readlink -f /opt/shade-staging/current)
export PATH=/opt/node/bin:$PATH
echo "current: $OLD"
echo "new:     $NEW"
rollback() { echo "Rollback: ln -sfn $OLD /opt/shade-staging/current && systemctl restart shade-staging"; }
trap 'echo "UPDATE_FAILED (see error above)"; rollback' ERR

[ -d "$NEW/server" ] || { echo "new release missing" >&2; exit 1; }
[ -d "$NEW/server/node_modules" ] || { echo "run npm ci in new release first (shade-staging)" >&2; exit 1; }
[ -f "$NEW/MANIFEST.sha256" ] || { echo "manifest missing" >&2; exit 1; }
[ -f "$NEW/MANIFEST.meta" ] || { echo "manifest meta missing" >&2; exit 1; }
[ -f /var/lib/shade-staging/staging.env ] || { echo "staging.env missing" >&2; exit 1; }

echo "== manifest integrity (fail-closed) =="
(cd "$NEW" && sha256sum -c MANIFEST.sha256 --quiet)
echo "manifest: all checksums OK"
grep '^commit:' "$NEW/MANIFEST.meta"

echo "== syntax =="
node --check "$NEW/server/alpha.mjs"

echo "== switch =="
ln -sfn "$NEW" /opt/shade-staging/current
systemctl restart shade-staging
sleep 2
systemctl is-active shade-staging
curl -fsS -m 5 http://127.0.0.1:3101/api/health; echo
curl -fsS -m 10 https://alpha.shadechat.ru/api/health; echo
echo "== googleConfigured =="
curl -fsS -m 10 https://alpha.shadechat.ru/api/session | grep -o '"googleConfigured":[a-z]*' || true
echo "== SW version served =="
curl -fsS -m 10 https://alpha.shadechat.ru/flutter-ui/cache-files.js | head -1

echo "== production untouched =="
systemctl is-active shade caddy
curl -fsS -m 5 http://127.0.0.1:3000/api/health; echo
systemctl cat shade --no-pager | grep -E 'ExecStart|EnvironmentFile' || true

trap - ERR
echo "UPDATE_DONE"
rollback