#!/bin/bash
# Shade v2 STAGING — переключение на релиз challenge-binding (runtime 5783295).
# ВЫПОЛНЯЕТ ВЛАДЕЛЕЦ через root SSH. Production v1 НЕ затрагивается:
# скрипт пишет только в /opt/shade-staging и рестартует shade-staging.
# Запуск: bash /opt/shade-staging/admin-update-challenge.sh
#
# Подготовка: релиз загружен, npm ci выполнен от shade-staging, MANIFEST
# сверен. Процедура: docs/STAGING_RELEASE_5783295.md.
# EXPECTED_COMMIT подставляется package-upload.ps1 при упаковке (= commit
# упаковки, он же в MANIFEST.meta); нереплейснутый плейсхолдер = fail-closed.
#
# ПРОВЕРКИ (fail-closed, до переключения):
#   - MANIFEST.sha256 по checksum (sha256sum -c);
#   - ТОЧНОЕ совпадение commit в MANIFEST.meta с EXPECTED_COMMIT;
#   - синтаксис alpha.mjs; наличие staging.env; отсутствие REPLACE_WITH в
#     ALPHA_GOOGLE_CLIENT_ID/SECRET; наличие каталога предыдущего релиза.
# ПРОВЕРКИ (после переключения, провал = АВТОМАТИЧЕСКИЙ откат):
#   - restart/is-active shade-staging; health loopback:3101 и домена;
#   - googleConfigured:true (именно true, не наличие поля);
#   - фактическая SW-версия 0d7d7e9a778d5d847a5d в cache-files.js;
#   - предыдущий релиз остался на диске.
# PRODUCTION (до и после): is-active shade caddy, health :3000, ExecStart и
#   EnvironmentFile юнита shade неизменны; деградация = CRITICAL + exit 1
#   БЕЗ автоотката staging (скрипт не пишет в production).
# ОТКАТ: автоматический — одна попытка вернуть предыдущий релиз при провале
#   post-switch проверок; ручной — команда печатается всегда; прежние релизы
#   не удаляются; данные staging совместимы в обе стороны.
set -euo pipefail
NEW=/opt/shade-staging/releases/20261118-232000
EXPECTED_COMMIT=__SET_AT_PACK_TIME__
EXPECTED_SW=0d7d7e9a778d5d847a5d
OLD=$(readlink -f /opt/shade-staging/current)
export PATH=/opt/node/bin:$PATH
echo "current: $OLD"
echo "new:     $NEW"
echo "expect:  $EXPECTED_COMMIT"
SWITCHED=0

manual_rollback() {
  echo "Manual rollback: ln -sfn $OLD /opt/shade-staging/current && systemctl restart shade-staging"
}
auto_rollback() {
  echo "AUTO-ROLLBACK: post-switch verification failed; restoring $OLD"
  ln -sfn "$OLD" /opt/shade-staging/current || echo "CRITICAL: symlink restore failed" >&2
  systemctl restart shade-staging || echo "CRITICAL: restart failed" >&2
  sleep 2
  if curl -fsS -m 5 http://127.0.0.1:3101/api/health >/dev/null 2>&1; then
    echo "AUTO-ROLLBACK OK: staging serving $OLD again"
  else
    echo "CRITICAL: previous release health failed too; manual intervention required" >&2
  fi
}
on_error() {
  echo "UPDATE_FAILED (see error above)"
  if [ "$SWITCHED" = 1 ]; then
    if [ -d "$OLD/server" ]; then
      auto_rollback
    else
      echo "WARNING: previous release dir missing; auto-rollback impossible" >&2
    fi
  else
    echo "Failure before switch: staging unchanged"
  fi
  manual_rollback
}
trap on_error ERR

# Fail-closed: an unbaked placeholder is not a 40-hex commit sha.
if ! [[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{40}$ ]]; then echo "script not prepared by package-upload (placeholder commit)" >&2; false; fi
[ -d "$NEW/server" ] || { echo "new release missing" >&2; false; }
[ -d "$NEW/server/node_modules" ] || { echo "run npm ci in new release first (shade-staging)" >&2; false; }
[ -f "$NEW/MANIFEST.sha256" ] || { echo "manifest missing" >&2; false; }
[ -f "$NEW/MANIFEST.meta" ] || { echo "manifest meta missing" >&2; false; }
[ -f /var/lib/shade-staging/staging.env ] || { echo "staging.env missing" >&2; false; }
[ -d "$OLD/server" ] || { echo "previous release dir missing; rollback would be impossible" >&2; false; }
if grep -q '^ALPHA_GOOGLE_CLIENT_ID=REPLACE_WITH' /var/lib/shade-staging/staging.env; then echo "staging.env: Google client id placeholder" >&2; false; fi
if grep -q '^ALPHA_GOOGLE_CLIENT_SECRET=REPLACE_WITH' /var/lib/shade-staging/staging.env; then echo "staging.env: Google client secret placeholder" >&2; false; fi

echo "== manifest integrity (fail-closed) =="
(cd "$NEW" && sha256sum -c MANIFEST.sha256 --quiet)
echo "manifest: all checksums OK"
echo "== exact commit binding =="
grep -q "^commit: ${EXPECTED_COMMIT}$" "$NEW/MANIFEST.meta" || { echo "MANIFEST commit mismatch (expected $EXPECTED_COMMIT)" >&2; false; }
grep '^commit:' "$NEW/MANIFEST.meta"

echo "== syntax =="
node --check "$NEW/server/alpha.mjs"

echo "== production baseline (before switch) =="
systemctl is-active shade caddy
curl -fsS -m 5 http://127.0.0.1:3000/api/health; echo
PROD_UNIT_BEFORE=$(systemctl cat shade --no-pager | grep -E 'ExecStart|EnvironmentFile' || true)
echo "$PROD_UNIT_BEFORE"

echo "== switch =="
ln -sfn "$NEW" /opt/shade-staging/current
SWITCHED=1
systemctl restart shade-staging
sleep 2
systemctl is-active shade-staging
curl -fsS -m 5 http://127.0.0.1:3101/api/health; echo
curl -fsS -m 10 https://alpha.shadechat.ru/api/health; echo
echo "== googleConfigured must be true =="
# Capture first, match second: curl | grep -q under pipefail can fail via
# SIGPIPE (grep -q exits on first match while curl still writes).
SESSION_JSON=$(curl -fsS -m 10 https://alpha.shadechat.ru/api/session)
[[ "$SESSION_JSON" == *'"googleConfigured":true'* ]] || { echo "googleConfigured is not true" >&2; false; }
echo "googleConfigured:true OK"
echo "== SW version must be $EXPECTED_SW =="
SW_JS=$(curl -fsS -m 10 https://alpha.shadechat.ru/flutter-ui/cache-files.js)
[[ "$SW_JS" == *"$EXPECTED_SW"* ]] || { echo "served SW version mismatch" >&2; false; }
echo "SW version OK"
echo "== previous release preserved =="
[ -d "$OLD/server" ] || { echo "previous release disappeared" >&2; false; }
echo "previous release intact: $OLD"

echo "== production untouched =="
PROD_OK=1
systemctl is-active shade caddy || PROD_OK=0
curl -fsS -m 5 http://127.0.0.1:3000/api/health || PROD_OK=0
echo
PROD_UNIT_AFTER=$(systemctl cat shade --no-pager | grep -E 'ExecStart|EnvironmentFile' || true)
[ "$PROD_UNIT_BEFORE" = "$PROD_UNIT_AFTER" ] || PROD_OK=0
if [ "$PROD_OK" != 1 ]; then
  echo "CRITICAL: production v1 health/unit changed after switch; investigate v1 separately (staging rollback does not affect production)" >&2
  manual_rollback
  exit 1
fi
echo "production v1 unchanged OK"

trap - ERR
echo "UPDATE_DONE"
manual_rollback