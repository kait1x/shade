# Shade v1 → v2: миграция существующих пользователей

Статус: механизмы реализованы и проверены на синтетических данных локально.
**Production-миграция не выполнялась.** Этапы с реальными пользователями
требуют отдельного разрешения владельца.

Фактическое состояние репозитория на 17.11.2026:
- Основной checkout `C:\Users\Kait1x\Documents\Shade` находится на ветке
  `codex/vinyl-material-redesign` (`cf81ac6`), а не на заявленной
  `integration-android-pwa`. Заявленное состояние v2 (`e986759`,
  66/66 серверных, 127/127 Flutter) существует в worktree
  `.agents/worktrees/integration-android-pwa` — на 60 коммитов впереди,
  без расхождений. Вся миграционная работа выполнена в этом worktree.
- `main` (`ceaa1d1`) — линия production v1. Production VPS обслуживает
  `server.js` за Caddy на `13-143-207-108.sslip.io`.
- VPS на момент проверки не отвечал на прикладном уровне (TCP открыты,
  SSH/HTTP/TLS таймауты); `shadechat.ru`/`api.shadechat.ru` — NXDOMAIN.
  См. `docs/V2_DEPLOYMENT.md`.

## 1. Обнаруженные различия v1 / v2 (карта несовместимостей)

| Аспект | v1 (production) | v2 (устройства) | Совместимость / решение |
|---|---|---|---|
| Идентичность | username (nickname) = ключ записи в `users.json`; RSA-ключ пользователя | аккаунт = тот же username; якорь `root` = SPKI исходного RSA; устройства с независимыми ключами | **Сохраняется**: legacy-аккаунт импортируется с тем же именем и тем же RSA как `primary` |
| Требования к ключу | сервер принимает любой RSA (в тестах встречается 2048) | только RSA-4096, e=65537 | RSA-4096 — прямой перенос якоря; RSA-2048..4095 — **rotation** (`rotation_required`): новый RSA-4096 + аттестация старого ключа (см. §3a); RSA < 2048 — `unsupported_key_size`, остаётся на v1 |
| Хранилище сервера | `users.json`, `messaging.json`, `stickers.json`, `fcm_tokens.json` (AES-256-GCM, ключ SHA256(SESSION_SECRET)), `groups.json`, `last_seen.json`, HMAC sidecar | отдельный зашифрованный snapshot `device-v2.enc` (alpha-store), аддитивные секции `migration`, `legacyInbox` | v1-файлы **никогда не перезаписываются**; v2 читает их read-only |
| История сообщений | сервер — relay: offline-очередь ≤200/30 MiB на получателя, TTL 7 дней; постоянная история — в клиентском SQLCipher | сервер — очередь per-device ciphertext; история — локально | история не «переносится» сервером: она остаётся в клиентской БД; недошедшая v1-очередь переносится one-way мостом |
| Формат сообщения | socket `message` `{to,id,data:"{k,d}"}`; RSA-OAEP-SHA256 над base64(`2‖AESkey32‖nonce12`) + AES-GCM | fanout `{k,d}` **на каждое устройство** обоих участников + подпись устройства PSS | внутренний конверт идентичен → старый ciphertext расшифровывается тем же RSA (`primary`); подписи v2 старые клиенты не проверяют |
| Авторизация | session token + refresh; владение RSA доказывает аккаунт (`/register` reissue) | Google-сессия + одноразовый device-proof на каждую операцию; добавлены legacy-key и device-сессии | добавлены два новых типа сессий (см. §3); device-proof обязателен всегда |
| Socket.IO | `register/message/delivered/read/deleteMessage/typing/watch/...` | `inbox/receipts/retracted/typing/presence` — только wake-hints; данные через подписанный fetch | протоколы несовместимы; двусторонний мост небезопасен (см. §5) |
| Группы | `groupMessage` отклоняется («Groups are not available») | не реализованы | терять нечего; группы вне миграции |
| Аватары/рамки/стикеры | `stickers.json`, `avatarOwner = SHA256(PEM publicKey)` | тот же бизнес-код (`v2-stickers.mjs`), snapshot `stickers`, `avatarOwner = SHA256(SPKI base64 root)` | профиль копируется при prepare/finalize; владелец перепривязывается к тому же неизменному ключу в v2-кодировке |
| Клиентское хранилище | SQLCipher `shade.db` (schema v9), ключ в EncryptedSharedPreferences; RSA в secure storage; сессия в SharedPreferences | аддитивные таблицы v2 в той же БД (v9) + журнал enrollment (v10) | обновление поверх сохраняет БД/ключи/сессию; миграция схемы аддитивная |
| Android | `com.example.shade`, versionCode 1; release-ключ `CN=Shade Android Release`; на тестовом A31 — **debug-подпись** | тот же applicationId; versionCode поднят до 2 | release→release обновляется поверх; debug→release — нет (см. `docs/ANDROID_V1_V2_UPGRADE.md`) |

## 2. Архитектура миграции

Принцип: **сервер подготавливает, устройство решает**. Приватные ключи никогда
не покидают устройство и не передаются на сервер. Сервер не расшифровывает
E2EE-payload ни на одном этапе.

Компоненты (все в этом worktree):
- `server/multidevice/v1-source.mjs` — read-only загрузчик v1-хранилища
  (формат AES-GCM/HMAC/metadata-конвертов байт-совместим с `server.js`).
- `server/multidevice/migration.mjs` — движок: idempotent `prepare`,
  per-user состояние (`migration.accounts`), one-way мост очереди
  (`legacyInbox`), `finalizeEnrollment`, `syncInbox/ackInbox`, `verify`,
  `rollbackPrepared`, `guard`.
- `server/tools/migrate-v1-to-v2.mjs` — CLI: `audit`, `prepare [--dry-run]`,
  `status`, `verify`, `retry`, `rollback --confirm`, `guard-export`,
  `stop/resume`.
- `server/alpha.mjs` — опциональный `legacySource` (read-only) + `guardFile`;
  новые сессии и операции `legacy.inbox`/`legacy.ack`; идемпотентный resume
  enrollment; экспорт guard при enrollment.
- `server/server.js` + `server/direct-messaging.js` — **opt-in** guard
  `SHADE_V2_GUARD_FILE` (по умолчанию выключен, поведение v1 не меняется) +
  **opt-in** bridge-ack `SHADE_V2_BRIDGE_ACK_FILE` (дренаж подтверждённого
  bridged-ciphertext из v1-очереди, статусы delivered для v1-отправителей).
- Клиент: `repository.dart enrollLegacy` с долговечным журналом (schema v10),
  `syncLegacyInbox`, вход ключом v1 без Google (`connectWithLegacyKey` +
  кнопка «Войти ключом v1» на экране устройств), честные `upgrade_required`
  уведомления в v1-UI.

Состояния аккаунта: `prepared` (импортирован, genesis ещё нет) → `enrolled`
(устройство подписало genesis исходным RSA, каталог revision ≥ 1) → активен.
`sessions` v1 не «переносятся»: после enrollment v1-маршруты отвечают
`upgrade_required`, клиент входит в v2 тем же ключом (Google или legacy-key
сессия). Это осознанная повторная авторизация тем же аккаунтом, не выдаваемая
за бесшовный перенос сессии.

## 3. Новые механизмы авторизации v2 (для мигрирующих аккаунтов)

1. **Google-сессия** (существовала): для аккаунтов с `googleSub` в v1.
2. **Legacy-key сессия** (`/api/v2/session/legacy-challenge` + `/session/legacy`):
   одноразовый nonce + подпись `requestText(account,'primary',nonce,op)`
   исходным RSA. Позволяет мигрировать nickname-only аккаунтам **без** принуждения
   к Google. Модель владения та же, что в v1 `/register`.
3. **Device-сессия** (`/api/v2/session/device`): любое enrolled-устройство
   открывает сессию своего аккаунта через штатный challenge/proof — покрывает
   новые Web-устройства nickname-only аккаунтов после pairing.

Challenge без сессии допускается только для bootstrap-операции
`device-session` с отдельной квотой (10/аккаунт); с валидной сессией аккаунт
обязан совпадать (защита от исчерпания квоты чужого аккаунта). Каждая операция
по-прежнему требует свежий device-proof; cookie сама по себе ничего не читает.

## 3a. RSA-2048 → RSA-4096: rotation (реализовано 17.11.2026)

Полностью бесшовный переход для RSA-2048 невозможен без смены ключа: v2
требует RSA-4096, а смена ключа **не является сохранением той же
криптографической идентичности**. Реализован безопасный явный сценарий:

1. `prepare` помечает аккаунт `rotation_required` (без записи в реестре
   каталогов — якорь ещё неизвестен) и импортирует недошедшую v1-очередь.
2. Клиент (Android v2) генерирует новый RSA-4096 **на устройстве**, строит
   genesis/manifest нового якоря и аттестацию
   `{version, account, oldRootFingerprint, newRoot, genesisDigest,
   manifestDigest, createdAt, nonce}`; аттестация подписывается СТАРЫМ
   приватным ключом (PSS-SHA256, канонический текст `shade-rotation:v1`).
3. Сервер (`/api/v2/session/rotation-challenge` + `/api/v2/legacy-rotation`,
   оба sessionless bootstrap с rate-limit и одноразовым nonce) проверяет:
   подпись старым публичным ключом из read-only v1-источника; свежесть;
   привязку к ТОЧНЫМ digest genesis/manifest (защита от подмены каталога);
   новый ключ — RSA-4096 e=65537 (отдельный verifier; общий v2-протокол
   по-прежнему требует 4096 везде). Первая успешная rotation фиксируется;
   конфликтующая вторая отклоняется; повтор после crash — idempotent resume.
4. Аккаунт создаётся с root=НОВЫЙ ключ; `rotation.attestation` сохраняется
   на аккаунте и публикуется в `directory` — собеседники со старым pinned
   ключом проверяют непрерывность владения. `avatarOwner` атомарно
   перепривязывается к новому корню при finalize. Guard/bridge-ack
   экспортируются.
5. Старый приватный ключ остаётся на устройстве (secure storage v1 не
   трогается + `legacy_key` в SQLCipher v2): локальная история и bridged
   v1-ciphertext расшифровываются им. Новые сообщения шифруются новому ключу.
6. `verify` перепроверяет всю цепочку аттестации против read-only источника.

Ограничения (честно): rotation пока только Android (ключ в secure storage);
web/PWA — направление ZCODE. Скомпрометированный старый ключ означает
скомпрометированную аттестацию. Контакты без pinned старого ключа видят
новый ключ (TOFU). `read`-статус bridged-сообщений v1→v2 не транслируется.

Тесты: `server/test/rsa-rotation.test.mjs` (2 интеграционных: CLI-матрица +
полный enrollment с негативными кейсами), `client/test/device_v2_migration_test.dart`
(rotation + crash-resume + неверная фраза, 5/5 файл).

## 4. Сохранность данных при переходе

- v1-файлы не изменяются вообще (миграция аддитивна: отдельный v2-snapshot).
- Недошедшие v1-сообщения: импортируются в `legacyInbox` при prepare,
  дозабираются при finalize и при каждом `legacy.inbox` (live-чтение очереди),
  дедупликация по `from:id` + digest, ACK-тумбстоуны (≤1000). Гонка
  «сообщение пришло между prepare и включением guard» закрыта повторным
  чтением. После активации guard новые v1-отправки к переведённому аккаунту
  **продолжают приниматься** и доставляются через живой мост (см. §5);
  v1-очередь дренируется bridge-ack файлом после подтверждения клиентом v2.
- E2EE: ciphertext v1 расшифровывается только исходным приватным RSA, который
  остаётся `primary`-устройством. Сервер видит только `{k,d}`.
- История: клиентский SQLCipher не удаляется и не переписывается; старые
  сообщения расшифровываются тем же ключом. Полная серверная история в v1
  отсутствует by design (relay + TTL 7 дней) — терять на сервере нечего,
  кроме недошедшей очереди, которая переносится мостом.
- Профиль/аватар/рамки/стикеры копируются; `avatarOwner` перепривязывается к
  неизменному ключу (иная кодировка того же ключа).
- Ошибка одного аккаунта не прерывает остальных (per-user try/catch, код
  ошибки в аудит-журнале без секретов). Сбой persist откатывает транзакцию
  целиком (persist-before-visible).
- Повторный запуск не дублирует: root сверяется, очередь дедуплицируется,
  genesis неизменяем, enrollment идемпотентен (resume).

## 5. Совместимость версий во время перехода

| Сценарий | Поведение |
|---|---|
| v1 → v1 | без изменений (guard выключен либо аккаунты не переведены) |
| v1 → v2 (отправитель v1, получатель переведён) | **Живой мост (17.11.2026)**: v1-сервер принимает отправку и кладёт ciphertext (зашифрованный тем же неизменным root RSA) в свою очередь; v2-клиент забирает его через live `legacyInbox` (дедуп по `from:id`+digest, ACK-тумбстоуны). После ACK клиента v2 экспортирует bridge-ack файл (`ALPHA_V2_BRIDGE_ACK_FILE` → `SHADE_V2_BRIDGE_ACK_FILE`), v1 удаляет подтверждённый ciphertext из очереди и переводит receipt в `delivered` — отправитель v1 видит честный статус, очередь не переполняется. Ограничения: `read`-статус для bridged-сообщений не транслируется (только `delivered`); push о новом v1-сообщении приходит при синхронизации v2-клиента (foreground/reconnect/polling), отдельный wake-push для bridged-очереди — следующий этап |
| v2 → v1 (получатель ещё на v1) | v2 `send` отклоняется («Both accounts must opt into v2»); клиент показывает честное уведомление о необходимости перехода собеседника. Обратный мост (v2→v1) — см. §8, требует отдельного решения |
| v2 → v2 | штатный fanout + подписи |
| Android v2 ↔ Web/PWA v2 | проверено интеграционными тестами (включая второе устройство) |

Полноценный двусторонний мост v1↔v2 **не реализован сознательно**: v1-клиент
не проверяет подписи устройств и каталоги v2; тихая доставка «только на один
телефон» запрещена моделью. E2EE не ослабляется: bridged-ciphertext зашифрован
тем же корневым RSA и расшифровывается только на устройстве получателя.
Вместо неконтролируемого dual-write — управляемый per-account переход с явными
уведомлениями, живым one-way мостом v1→v2 и переносом уже принятых сервером
ciphertext.

## 6. Этапы перехода

1. **Подготовка**: SSH-доступ владельца, `production-audit.sh`,
   `backup-verify.sh`, проверить схемы/копии. VPS жив (подтверждено
   17.11.2026: SSH/HTTP/Caddy TLS sslip.io 200 OK); блокер — доступ владельца.
2. **Staging**: `alpha.shadechat.ru` по `docs/V2_DEPLOYMENT.md` §2–3;
   миграция синтетических и обезличенных копий.
3. **Тестовые пользователи**: `prepare --accounts test1,test2`, enrollment на
   реальных устройствах владельца, проверка истории/вложений/моста.
4. **Ограниченная миграция** (отдельное разрешение): малая группа реальных
   аккаунтов, `stop`-флаг доступен, guard включается только для проверенного
   среза; мониторинг `status`/`verify`.
5. **Основной переход**: пакетный `prepare --all` + приглашение пользователей
   обновить приложение; v1 остаётся работать для непереведённых.
6. **Завершение**: все мигрируемые аккаунты переведены; немигрируемые
   (RSA ≠ 4096, потерянные ключи) обработаны отдельным сценарием; вывод v1
   из эксплуатации — только после этого и с разрешения владельца.

Миграция не объявляется завершённой, пока есть неперенесённые данные или
пользователи без понятного сценария.

## 7. Инструменты и проверки

```bash
node server/tools/migrate-v1-to-v2.mjs audit   --source <v1-dir>
node server/tools/migrate-v1-to-v2.mjs prepare --source <v1-dir> --target <v2-dir> --accounts a,b [--dry-run]
node server/tools/migrate-v1-to-v2.mjs status  --target <v2-dir> [--source <v1-dir>]
node server/tools/migrate-v1-to-v2.mjs verify  --source <v1-dir> --target <v2-dir>
node server/tools/migrate-v1-to-v2.mjs retry   --source <v1-dir> --target <v2-dir>
node server/tools/migrate-v1-to-v2.mjs rollback --target <v2-dir> --accounts a --confirm
node server/tools/migrate-v1-to-v2.mjs checkpoint --target <v2-dir> --out <dir>
node server/tools/migrate-v1-to-v2.mjs replay-restore --target <v2-dir> --backup <old.enc> --confirm
node server/tools/migrate-v1-to-v2.mjs guard-export --target <v2-dir> --out <guard.json>
node server/tools/migrate-v1-to-v2.mjs stop|resume --target <v2-dir>
```

Тесты (синтетические, локальные):
- `server/test/migration.test.mjs` — 3 интеграционных теста: CLI/idempotency/
  изоляция ошибок/dry-run/stop/rollback; alpha-мост (legacy-key enrollment без
  Google, drain очереди, гонка, restart, multi-device, device-session bootstrap,
  guard, E2EE, primary-only P0, peer_upgrade_required); guard в реальном
  `server.js` (auth/send/refresh/profile, живой bridge-ack → delivered,
  обратимость).
- `server/test/migration-dryrun.test.mjs` — 3 интеграционных: dry-run матрица
  состояний v1 (empty/bulk-cap/RSA-2048/multi/revoked/failed-enrollment/stop).
- `server/test/rsa-rotation.test.mjs` — 2 интеграционных: rotation CLI +
  полный enrollment с негативными кейсами.
- `server/test/rollback-journal.test.mjs` — 6 интеграционных: lossless replay,
  CLI replay-restore fail-closed, revocation, inbox merge, randomized model,
  checkpoints.
- `client/test/device_v2_migration_test.dart` — 5 тестов: schema v9→v10→v11;
  crash после серверного коммита; legacy-inbox (дедуп, ACK-ref, collision, IMG);
  RSA-rotation (аттестация/якорь/legacy-расшифровка); rotation crash + wrong phrase.
- `client/test/alpha_v2_screen_test.dart` — вход ключом v1 без Google (UI).
- Android: v2 debug APK собран (`versionCode 2`, `com.example.shade`);
  подпись release-артефактов сверена с установленным debug (разные — см.
  `docs/ANDROID_V1_V2_UPGRADE.md`).
- Полные suite: сервер **82/82**, Flutter **134/134** (17.11.2026, эта сессия).

Не проверено на реальных устройствах: физический iPhone, production OAuth,
реальный Galaxy A31 с release-подписью. WebKit/Edge QA — эмуляция, не iPhone.

## 8. Риски и ограничения

- Аккаунты с RSA-2048 переводятся через явную rotation (§3a): смена
  криптографической идентичности с аттестацией старого ключа, сохранением
  аккаунта/контактов/локальной истории. RSA < 2048 и потерянные ключи —
  отдельный сценарий владельца.
- Потеря устройства без recovery-пакета/другого доверенного устройства =
  потеря идентичности v2 (не восстанавливается сервером/Google).
- Lease каталога 24 ч: устройство должно продлевать; злонамеренный сервер
  может скрывать отзыв до истечения lease (ограничение модели, не миграции).
- Rollback enrolled-аккаунтов: **lossless replay-restore** (старый бэкап +
  перенос нового живого состояния: сообщения/ACK/retract/ревизии каталога),
  доказано интеграционными тестами `rollback-journal.test.mjs` (6/6).
  Прямой snapshot-restore — только если живой снапшот нечитаем; пост-бэкап
  очереди с relay теряются (локальные копии остаются). См. `docs/V2_ROLLBACK.md`.
- VPS жив, но SSH-доступ только у владельца: этап 1 блокируется до предоставления
  доступа (диагноз 17.11.2026: SSH/HTTP/Caddy работают; TLS доменных hostname
  требует site-блоков Caddy — см. `docs/V2_DEPLOYMENT.md`).
- DNS: `@`/`www`/`api` существуют; `app`/`alpha`/`staging-api` нужно добавить
  в REG.RU. Без записей и Caddy-блоков доменные hostname не заработают
  (sslip.io остаётся рабочим fallback для v1).

## 9. Действия, требующие подтверждения владельца

1. Доступ к VPS (SSH) и восстановление работоспособности служб.
2. DNS-записи в REG.RU.
3. Развёртывание staging и копирование production-данных в staging-копию.
4. Включение guard в production `shade.env` + рестарт `shade`.
5. Миграция реальных пользователей (этапы 4–5) и любой rollback enrolled.
6. Переключение `api`/`app` hostname на v2 и вывод v1 из эксплуатации.