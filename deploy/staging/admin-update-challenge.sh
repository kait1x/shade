#!/bin/bash
# Shade v2 STAGING — переключение на релиз 5783295 (challenge-binding v2).
# ВЫПОЛНЯЕТ ВЛАДЕЛЕЦ через root SSH. Production v1 НЕ затрагивается:
# скрипт пишет только в /opt/shade-staging и рестартует shade-staging.
# Запуск: bash /opt/shade-staging/admin-update-challenge.sh
#
# Подготовка (до запуска): релиз загружен, npm ci выполнен от shade-staging,
# MANIFEST.sha256 сверен. Полная процедура: docs/STAGING_RELEASE_5783295.md.
#
# ОТКАТ:
# - АВТОМАТИЧЕСКИЙ: если любая проверка ПОСЛЕ переключения symlink падает
#   (restart / is-active / health loopback:3101 / health домена / SW-файл),
#   скрипт САМ возвращает предыдущий релиз, рестартует shade-staging и
#   проверяет его health. Одна попытка, без циклов; результат печатается.
# - РУЧНОЙ: команда печатается всегда (включая случаи автоотката); прежние
#   релизы не удаляются, данные staging совместимы в обе стороны.
# - Ошибка ДО переключения ничего не меняет — откат не требуется.
# - Production-проверки после переключения НЕ запускают автооткат staging
#   (скрипт не пишет в production): при деградации v1 печатается CRITICAL
#   и команда ручного отката, скрипт завершается с ошибкой.
set -euo pipefail
NEW=/opt/shade-staging/releases/20261118-141500
OLD=$(readlink -f /opt/shade-staging/current)
export PATH=/opt/node/bin:$PATH
echo "current: $OLD"
echo "new:     $NEW"
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

[ -d "$NEW/server" ] || { echo "new release missing" >&2; exit 1; }
[ -d "$NEW/server/node_modules" ] || { echo "run npm ci in new release first (shade-staging)" >&2; exit 1; }
[ -f "$NEW/MANIFEST.sha256" ] || { echo "manifest missing" >&2; exit 1; }
[ -f "$NEW/MANIFEST.meta" ] || { echo "manifest meta missing" >&2; exit 1; }
[ -f /var/lib/shade-staging/staging.env ] || { echo "staging.env missing" >&2; exit 1; }
if [ ! -d "$OLD/server" ]; then
  echo "WARNING: current release dir missing; auto-rollback will be impossible" >&2
fi

echo "== manifest integrity (fail-closed) =="
(cd "$NEW" && sha256sum -c MANIFEST.sha256 --quiet)
echo "manifest: all checksums OK"
grep '^commit:' "$NEW/MANIFEST.meta"

echo "== syntax =="
node --check "$NEW/server/alpha.mjs"

echo "== production baseline (before switch) =="
systemctl is-active shade caddy
curl -fsS -m 5 http://127.0.0.1:3000/api/health; echo

echo "== switch =="
ln -sfn "$NEW" /opt/shade-staging/current
SWITCHED=1
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
PROD_OK=1
systemctl is-active shade caddy || PROD_OK=0
curl -fsS -m 5 http://127.0.0.1:3000/api/health || PROD_OK=0
echo
systemctl cat shade --no-pager | grep -E 'ExecStart|EnvironmentFile' || true
if [ "$PROD_OK" != 1 ]; then
  echo "CRITICAL: production v1 health degraded after switch; investigate v1 separately (staging rollback does not affect production)" >&2
  manual_rollback
  exit 1
fi

trap - ERR
echo "UPDATE_DONE"
manual_rollback