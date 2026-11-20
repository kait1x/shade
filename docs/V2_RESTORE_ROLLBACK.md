# Restore-тест и репетиция rollback перехода v1→v2

Все шаги на VPS — только с отдельного «го» владельца. До защиты 23.11 сервисы
staging/prod не переключаются и не рестартуются ради репетиций.

## 1. Изолированный restore-тест (можно до защиты: не трогает сервисы)
1. `bash deploy/transition/backup-transition.sh <stamp>` (root). Архивы +
   SHA256SUMS в /var/backups/shade-transition/<stamp> (права 700/600).
2. Внешняя копия архива владельцем; на копии `sha256sum -c SHA256SUMS`.
3. Изолированный каталог: `install -d -m 700 /root/restore-test-<stamp>`;
   распаковать data-v2.tgz туда; скопировать staging.env как env файл с правами
   600 (секрет не эхоить).
4. Boot восстановленного инстанса ОТДЕЛЬНЫМ процессом на свободном loopback-порту
   (например 3199): `node --env-file=<env> alpha.mjs` с dataDir=изолированный
   каталог и publicOrigin=http://127.0.0.1:3199 (или https-фикстура). Порт/origin
   задаются env; сервис shade-staging НЕ трогается.
5. Сверки: /api/health ok; op directory по тестовому аккаунту (синтетический
   device-proof из recovery-пакета теста ИЛИ read-only сверка счётчиков через
   sqlite/снапшот): число аккаунтов, сумма длин очередей, receipts count —
   идентичны оригиналу (снять счётчики оригинала ДО бэкапа тем же read-only
   способом). sha256 распакованных файлов против SHA256SUMS.
6. Негатив: подменить один байт в снапшоте копии → boot должен отказать
   (fail-closed storage) ИЛИ verifyHistory отклонить подменённый манифест.
7. Остановить изолированный процесс, удалить каталог только после отчёта.
8. Отчёт: stamp, sha256, счётчики до/после, результат негатива → в RC-документ.

## 2. Репетиция rollback (ТОЛЬКО после защиты, отдельное «го»)
1. Бэкап по §1 перед репетицией.
2. На staging: `ln -sfn /opt/shade-staging/releases/<previous> /opt/shade-staging/current`
   + `systemctl restart shade-staging` + smoke-staging.sh → SMOKE_OK.
3. Вернуть текущий релиз тем же способом + smoke. Замерить время отката.
4. Caddy-rollback: `install -m 644 <backup>/Caddyfile /etc/caddy/Caddyfile` +
   `caddy validate` + `systemctl reload caddy` + smoke обоих origins.
5. Отчёт: время отката, smoke-результаты, целостность данных (счётчики).
6. Prod-rollback аналогично через /opt/shade/current + shade.service, только
   отдельным «го» и после проверки объединённого Caddyfile (4 блока alpha).

## 3. Grace и хранения
- v1 data не prune-ится до cutoff + 14 дней grace.
- Внешние копии бэкапов: минимум 2 (VPS + внешняя), ротация вне Git/чата.
- Recovery-ключи/storage secret: только env-файлы 600 и внешняя копия владельца;
  никогда в Git/логах/отчётах.