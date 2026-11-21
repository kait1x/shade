# Shade V2 — security / test report (17.11.2026)

Worktree `integration-android-pwa` (HEAD `e986759` + uncommitted).
Все результаты — фактические запуски в этой сессии. Физических устройств
и браузерного E2E в этой сессии не было (NOT TESTED).

## 1. Итоги прогонов

| Suite | Результат | Команда | Длительность |
|---|---|---|---|
| Server (27 файлов) | **82/82 PASS**, 0 fail/skip | `node --test --test-concurrency=1 test/*.test.js test/*.test.mjs` | 183 с |
| Flutter (26 файлов) | **134/134 PASS**, 0 fail/skip | `flutter test` | 3:01 |
| Flutter analyze | **0 errors, 0 warnings, 49 info** | `flutter analyze` | ~36 с |

Примечание: при параллельном запуске файлов (`npm test` default concurrency)
на этой Windows-машине наблюдалась нагрузочная флейки-регрессия socket-теста
(register outcome >15 с под конкуренцией CPU/Defender); добавлен таймаут 15 с,
финальный gate прогоняется serialized. Продуктовый код не менялся ради тестов;
проверки безопасности не отключались.

49 info — существовавшие ранее: 43× deprecated_member_use (SDK-депрекация
`material.dart` после Flutter 3.47 + `translate`), 4× unnecessary_import
(alpha-web), 2× prefer_const (alpha_avatar_editor). К изменённым областям
(rotation/bridge/rollback) не относятся.

## 2. Классификация тестов (unit / integration / E2E / physical)

### Server — integration (реальный сервер/хранилища/Socket.IO)
| Файл | Что проверяет |
|---|---|
| migration.test.mjs (3) | CLI audit/dry-run/idempotency/failure isolation/stop/rollback; alpha-мост (legacy-key enrollment без Google, E2EE drain, race top-up, restart, multi-device, device-session bootstrap, guard, primary-only P0, peer_upgrade_required); реальный server.js guard (auth/send/refresh/reissue/profile, живой bridge-ack → delivered, reversibility, default off) |
| migration-dryrun.test.mjs (3) | dry-run матрица §9 ТЗ: empty/bulk-250→cap-200+truncation/RSA-2048/4096/1024/multi/nokey; failed enrollment (foreign key/stale/wrong account/unprepared) + recovery; revocation (purge/tombstone/inbox independence) |
| rsa-rotation.test.mjs (2) | CLI rotation_required + verify до/после; полный rotation enrollment: old-key proof, digest binding, RSA-4096 anchor, attestation publication, avatar rebind, guard/bridge-ack, legacy-session новым ключом, old-ciphertext decryption, resume, 6 негативных кейсов |
| rollback-journal.test.mjs (6) | lossless replay (messages/ACK/read/retract/new device); CLI replay-restore + safety backup + fail-closed divergence; revocation non-resurrection; inbox merge semantics; randomized model (5 раундов); rolling checkpoints |
| alpha-integration, alpha-media, alpha-profiles-stickers, alpha-read-ack, alpha-transport, alpha-typing-presence, alpha-retract, alpha-push, alpha-sw-push, alpha-security-hardening, alpha-storage, alpha-native-session, multidevice, self-chat, account-platforms | протокол v2: fanout/подписи/lease/revocation/read-ACK/retract/push (SSRF guard)/storage isolation/native↔web E2EE/self-chat |
| relay.test.js, direct-messaging.test.js | v1 relay: очередь/TTL/receipts/deleteMessage/лимиты |

### Server — unit / mixed
| Файл | Что проверяет |
|---|---|
| auth-proof.test.js | PKCE/state/nonce/Google id_token verification (unit) |
| alpha-vault.test.mjs | vault/recovery crypto, rebind protection (unit) |
| avatars.test.js | avatar ownership/нормализация (unit) |
| audit-regressions.test.js | регрессии аудита (unit/integration) |

### Flutter — unit / widget / local-integration
| Файл | Тип | Что проверяет |
|---|---|---|
| device_v2_migration_test.dart (5) | local-integration (sqflite ffi + real crypto) | schema v9→v10→v11; crash journal resume; legacy-inbox dedup/ACK-ref/IMG/collision; RSA-rotation attestation/anchor/legacy-decryption; rotation crash + wrong phrase |
| alpha_v2_screen_test.dart | widget | вход ключом v1 без Google, enrollment UI, rotation-флаг |
| остальные 24 файла | unit/widget | crypto, protocol, store, outbox, UI-состояния, welcome/OAuth-config |

### E2E / physical
- Бразерный E2E (Playwright): NOT TESTED в этой сессии (ZCODE-направление).
- Физический Android (A31 release-over-release): NOT TESTED.
- Физический iPhone PWA/push: NOT TESTED (не заявляется проверенным).
- Production OAuth / реальный VPS: NOT TESTED (BLOCKED, доступ владельца).

## 3. Security gate — доказательства

| Контроль | Механизм | Доказательство |
|---|---|---|
| E2EE end-to-end | сервер только {k,d}; RSA-OAEP-SHA256+AES-GCM; PSS-подписи устройств | bridge-тест: snapshot без plaintext; openMessage только устройством; multidevice verifyMessage |
| Приватные ключи | secure storage (Keystore) + SQLCipher; серверу не передаются; rotation: старый ключ только на устройстве | код-аудит repository/crypto; rotation-тесты (legacyKey локально) |
| Replay protection | одноразовые nonce (challenge/legacy/rotation/device-session), consumed-on-failure, expiry 60 с | rsa-rotation replay-негатив; alpha-security-hardening; guard reissue-негатив |
| PKCE/state/nonce | S256 code_challenge, state cookie, nonce claim в id_token | auth-proof.test.js; alpha-vault |
| Authorization bypass | каждая операция = session + свежий device-proof; bindSession; cross-account challenge отказ | bridge-тест foreign challenge 400; alpha-security-hardening |
| Device revocation | retired tombstones, key reuse ban, queue purge, challenge отказ | dryrun revocation-тест; multidevice |
| Session fixation | старая сессия удаляется при login; __Host- cookie prefix (HTTPS); Origin checks | alpha-код; alpha-security-hardening |
| Legacy RSA auth | proof-of-possession исходным RSA; квоты 100/аккаунт, 1000 глобально; bootstrap только device-session/rotation | bridge-тест; rotation-тест |
| Migration guard | opt-in default off; mtime-кэш; fail-closed при ошибке чтения; reversibility | guard-тест |
| Race conditions | persist-before-visible; serial transactions; live queue re-read; durable two-phase ACK + startup re-export | race top-up тест; rollback crash-тесты |
| Push SSRF/DNS-rebinding | https-only, no IP literals/loopback/private; operator allowlist провайдеров; gone-endpoint prune | alpha-push/alpha-sw-push тесты |
| Секреты в логах | Caddy filter (Authorization/Cookie/X-Session-Token/X-Username delete); аудит-журнал только коды ошибок; CLI не печатает секреты | deploy-конфиги; migration код-аудит |
| Права хранилищ | 0700 dirs / 0600 files / writer.lock / UMask 0077 / ProtectSystem=strict / ProtectHome / NoNewPrivileges | alpha-store код; systemd-шаблоны |
| TLS | Caddy auto-HTTPS; строгий CSP; security headers | ВНЕШНЯЯ проверка: sslip.io 200 OK; доменные SNI BLOCKED (нет site-блоков) — диагноз установлен, шаблон готов |
| Backup/restore | проверяемые бэкапы до изменений; backup-verify.sh; replay-restore fail-closed; checkpoints | rollback-journal тесты; CLI rollback backup |
| ACK collision (P0) | ref `from:id` вместо голого id | Dart collision-тест + серверный ackInbox |
| Bridge primary-only (P0) | вторичное устройство не дренирует account-scoped inbox | bridge-тест op2 legacy.inbox/ack 400 |
| Rotation binding | аттестация связана с точными digest genesis/manifest; first-commit-wins; конфликтующая вторая отклоняется | rsa-rotation digest-mismatch негатив |
| Legacy-session negatives | replay nonce (consumed-on-failure), чужой ключ, неизвестный аккаунт, pre-enrollment device-lock | `alpha-legacy-session.test.mjs` (17.11.2026) |
| Multi-origin trust | extra origins только https и явным списком; чужой Origin 403; OAuth redirect/cookie канонические | `alpha-origins.test.mjs` (17.11.2026) |

## 4. Остаточные риски

- TLS доменов не работает до Caddy-изменения (владелец) — staging HTTPS/WSS
  не проверен на VPS.
- Обратный мост v2→v1 отсутствует (честное ограничение, не уязвимость).
- read-receipt bridged не транслируется (приватность не нарушает; UX-ограничение).
- Скомпрометированный старый ключ ⇒ скомпрометированная rotation-аттестация
  (модель это не скрывает; документировано).
- Lease 24 ч: злонамеренный сервер может скрывать отзыв до истечения lease
  (ограничение модели v2, не миграции).
- Физические устройства не проверены; Keystore OEM-поведение неизвестно.
- Нагрузочные пороги rollout не калиброваны (нужен staging baseline).