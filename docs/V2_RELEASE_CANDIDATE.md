# Релиз-кандидат production v2 (RC) — статус и состав

Ветка: `v2-production`. База: staging-линия 092f1fb (живой staging 20261119-2355)
+ merge recovery + компоненты перехода. Prod/staging до 23.11 не меняются;
деплой RC — только после защиты и отдельного «го» владельца на каждый шаг.

## Состав (коммиты)
- ead75c8 merge recovery-session (implicit-view hostFlutter, идемпотентная загрузка)
- 0dd5304 recovery-сессии memory-only + never rolling-refreshed (регресс-тесты)
- e1f2bbd receipts pruning (7d окно дедупа, дедуп очередей) + backup/restore тесты
- 8ba96a9 native pairing (golden-векторы байт-совместимости с pairing.mjs),
  экраны approve/new-device, crash-safe journal, contactHistory (schema v12)
- d5d46ed native v2 entry + UI (чаты/диалог/профиль/устройства) + offline outbox
- 59d163c history.transfer (per-device staging, курсор, дедуп, лимиты) + PWA-методы
- f95ae4e enrollment-мастер + локальный импорт истории v1→v2 + маршрут /enrollment
- bc7e313 нативный recovery-экран + recoverWithBackup (1:1 веб-контракт) + QA-сценарий
- d4de08e карта рисков: native at-rest вариант A
- 07c43aa session-aware sync (secondary/recovered), restore без v1-профиля,
  фикс fanout self-copy trust, prefs после completePairing
- bcb927e кнопка enrollment на экране подключения (код-HEAD RC; дальнейшие
  коммиты — только документация/статусы)

## Тесты (прогоны lead лично)
- server npm test: **130/130** (на 59d163c; server-файлы после не менялись).
- flutter test: **225/225** на финальном HEAD bcb927e (включая реальные
  SQLCipher/FFI и реальный alpha.mjs через тестовые мосты).
- flutter analyze: **0 errors / 0 warnings** (info — существующий baseline).
- Browser-QA матрица: edge normal / edge hostile / webkit — все passed=true.

## Browser-QA результаты (прогон lead 20.11 ~23:40, локальный HTTPS-фикстур)
- edge normal: passed=true, pageErrors=[] (registration, E2EE+WSS, ACK, offline
  outbox, media chunks, readAck, typing, profile/avatar/stickers, pairing=true,
  pwaRecovery=true, push subscribed, responsive, scroll restoration).
- edge hostile (SHADE_QA_HOSTILE_BLOB=1): passed=true, pageErrors=[] — тот же
  набор, Android-класс отказа blob-XHR воспроизведён и пережит.
- webkit: passed=true, pageErrors=[]; push = honest-failure («Push не
  поддерживается этим браузером») — честное поведение, не дефект.
- enrollment/transfer в browser-матрице отдельными сценариями не покрыты:
  покрыты серверными тестами (history-transfer, migration, recovery-session)
  и нативными тестами на реальном SQLCipher/scripted+real transport;
  browser-сценарии enrollment/transfer — опциональное дополнение до открытой беты.
- 429 при быстром прогоне: штатный лимит 300 req/min, клиент восстановился
  повтором (http429DuringRapidRun 14/23/6) — не дефект.

## Backup/restore и rollback
- Синтетический restore-тест: PASS (server/test/backup-restore.test.mjs).
- Restore на копии staging-данных: ОЖИДАЕТ «го» владельца (P5).
- Репетиция rollback на staging: ОЖИДАЕТ «го» владельца (P5).
- Внешняя копия бэкапа: подтверждение владельца ожидается.

## GO/NO-GO (план §5)
- [x] server suite зелёный
- [x] flutter suite зелёный + analyze 0/0
- [x] browser-QA матрица PASS оба движка (edge normal+hostile, webkit)
- [ ] физические QA A31/iPhone подписаны (после защиты + «го»)
- [ ] restore-тест на реальных данных + репетиция rollback (по «го»)
- [x] RC commit-bound (SHA выше; manifest собирается при паке)
- [ ] защита 23.11 проведена
- [ ] отдельные «го» на prod-шаги

## Открытые задачи (не блокеры RC, но до открытой беты)
- Периодический refreshOwn как в web (опережающее обновление каталога другим
  устройством → stale install до refresh; сейчас честный отказ).
- Переносимый vault-экспорт native→web (после беты, решение lead).
- PRF-проводка натива (после беты).
- Групповая история v1 не переносится (v2 = 1:1; честно в UI enrollment).
- Firebase service-account key для нативного push (действие владельца).