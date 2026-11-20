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
- 7e03065 backup-скрипт перехода + процедура restore/rollback
- 1d2bccd D3: переключение клиентов/applicationId/DNS (ожидает решения владельца)
- 9a96121 когортная миграция диалогами D1 (state-машина, fail-closed gate,
  CAS flip, HOLD send-gate, rollback reverse-replay grace 14д) + PWA-методы
- (в работе) v1 per-dialog guard ingestion + reverseReplay ingestion + PWA-баннеры
- (lead) file_picker заменён на platform channel MainActivity (ACTION_OPEN_DOCUMENT):
  Android-часть file_picker 11.0.3 не применяет KGP при AGP>=9 и ломает registrant;
  builtInKotlin=true конфликтует с KGP остальных плагинов → убрали зависимость,
  свой тип PickedFile + метод pickRecoveryPackage (лимит 1 МБ читается на нативе).

## Тесты (прогоны lead лично)
- server npm test: **135/135** на 9a96121 (130 + 5 когортных).
- flutter test: **225/225** на bcb927e; повтор после wiring-коммита — ниже.
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

## Manifest RC (пак lead 20.11 ~23:55, локально, без деплоя)
- MANIFEST.meta: commit **9998fc0987c662b0ffe4c5954973a6e470a57b23**,
  branch v2-production, sw_version **e5246847d6d00a2ee301**, files **133**.
- Пакет: build/staging-upload (28 MB), secrets check: no secret-like files.
- ВНИМАНИЕ: промежуточный пак (до когортной миграции). Финальный RC-пак
  пересобирается на финальном HEAD после wiring-коммитов; manifest обязан
  совпадать с деплоящимся commit (fail-closed).
- SHA256 всех файлов runtime — в MANIFEST.sha256 пакета; commit-bound fail-closed
  переключение ожидает точного совпадения commit при паке деплоя.
- Backup-скрипт перехода: deploy/transition/backup-transition.sh (bash -n OK);
  процедура restore/rollback: docs/V2_RESTORE_ROLLBACK.md. Исполнение на VPS —
  только по отдельному «го» владельца.

## Installable QA APK (для физического QA на Galaxy A31)
- Файл: artifacts/v2-a31-staging/shade-v2-qa-300-debug.apk (локально, в Git не
  коммитится — бинарь ~190 МБ).
- SHA-256: D60EA751D7E634723EACFB1FD3CF90CF4BDB387ED502D87D29D7F9DCC6C144E1.
- package com.example.shade, versionCode 300, versionName 2.1.0-qa; подписан
  debug-ключом машины (SHA-256 d7d88767fbb4d126… = установленная база v1) →
  бесшовное обновление поверх v1 с сохранением SQLCipher/Keystore-данных.
- Установка: adb install -r <apk> (или передача файла на телефон); поверх
  установленного v1 обновление без удаления данных. Отдельный applicationId
  не используется (D3: сохранить production id).
- Origin для QA: https://alpha.shadechat.ru (вводится на экране подключения);
  staging-сервис не изменяется.

## Backup/restore и rollback
- Синтетический restore-тест: PASS (server/test/backup-restore.test.mjs).
- **Изолированный restore-тест на копии staging-данных: PASS (21.11 ~00:48, GO
  владельца)**: COPY_INTEGRITY_OK (sha256 всех файлов копии = оригинал, кроме
  writer.lock живого сервиса); восстановленные счётчики: accounts=4,
  queueEntries=4, receipts=32, dialogs=0, historyStaging=0, sessions=3, format=2;
  негатив: подменённый байт снапшота → NEG_REJECTED (fail-closed); копия секретов
  удалена после теста (rm -rf изолированного каталога). Живые сервисы/данные/
  конфигурация не изменялись; секреты не выводились.
- Репетиция rollback на staging: ОЖИДАЕТ после защиты (демо-заморозка до 23.11).
- Внешняя копия бэкапа: подтверждение владельца ожидается (backup-transition.sh готов).

## GO/NO-GO (план §5)
- [x] server suite зелёный
- [x] flutter suite зелёный + analyze 0/0
- [x] browser-QA матрица PASS оба движка (edge normal+hostile, webkit)
- [ ] физические QA A31/iPhone подписаны (после защиты + «го»)
- [x] restore-тест на копии staging-данных PASS (изолированно, 21.11) + негатив fail-closed
- [ ] репетиция rollback на staging (после защиты, по «го»)
- [x] RC commit-bound: SHA 9998fc0 + MANIFEST (133 файла, sw e5246847d6d00a2ee301)
- [ ] защита 23.11 проведена
- [ ] отдельные «го» на prod-шаги

## Открытые задачи (не блокеры RC, но до открытой беты)
- D3 РЕШЕНО (21.11): сохранить applicationId v1 (com.example.shade); QA v2 APK —
  same id + debug-cert этой машины (отпечаток D7:D8:87:… совпадает с установленной
  базой v1) + versionCode 300 → бесшовное обновление с сохранением SQLCipher/Keystore.
  До открытой беты: release-ключ + portable vault export/restore (иначе reinstall
  release-сборки теряет локальную историю debug-базы).
- Периодический refreshOwn как в web (опережающее обновление каталога другим
  устройством → stale install до refresh; сейчас честный отказ).
- Переносимый vault-экспорт native→web (после беты, решение lead).
- PRF-проводка натива (после беты).
- Групповая история v1 не переносится (v2 = 1:1; честно в UI enrollment).
- Firebase service-account key для нативного push (действие владельца).