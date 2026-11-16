# device-v2 Backend API — контракты для клиентов (ZCODE PWA / Android)

Ветка `android-web-e2ee`. Сервер: `server/alpha.mjs` (изолированный alpha-процесс),
модель: `server/multidevice/registry.mjs`. Production `server.js` (v1) не изменён.
Все ответы JSON; ошибки: `{error: code}`.

## 1. Авторизация (не ослаблять)

Два независимых фактора на каждый запрос:
1. **Google-сессия**: cookie `shade-alpha` (`__Host-shade-alpha` на HTTPS),
   HttpOnly/SameSite=Lax/Secure, 8 ч. Получение: браузерный OAuth code+PKCE
   (`/auth/google`) или native `POST /api/v2/session/google {idToken}`
   (проверка audience/signature/verified_email тем же `googleProfile`; 15/мин).
2. **Device proof** на каждую операцию:
   - `operation = SHA256hex(JSON.stringify([op, body]))`, где для `send`
     body = `SHA256hex(messageText(message))`, для остальных — тело как есть
     (`null` для fetch/users/socket).
   - `POST /api/v2/challenge {account, id, operation}` → `{nonce}` (60 с, одноразовый).
   - `proof = RSA-PSS-SHA256(salt32)` над `requestText(account,id,nonce,operation)`
     ключом устройства; канонические тексты — `client/web/protocol/device-v2.mjs`.
   - `POST /api/v2/operation {op, body, auth:{account,id,nonce,proof}}`.
   Nonce расходуется даже при ошибке; replay → 401. Cookie без proof не авторизует
   чтение очередей. Socket.IO handshake: `auth = {account,id,nonce,proof}` для op
   `socket` + Cookie; при reconnect — свежий proof.

Коды ошибок: 401 `device_auth_required`/`google_login_required`;
400 `operation_rejected`/`google_not_configured`/`push_not_configured`;
409 — конфликты (`already`, `Stale`, `capacity`, `queue full`, `history limit`).
Лимит `/api`: 300 запросов/мин на IP; POST только `application/json`; Origin проверяется.

## 2. Операции `/api/v2/operation`

| op | body | результат | примечания |
| --- | --- | --- | --- |
| `send` | message v2 | `{accepted, duplicate}` | fanout всем устройствам обеих сторон; self-chat — один ростер (см. §4); retry с тем же ID/ciphertext идемпотентен |
| `fetch` | `null` | `[{message, senderHistory, recipientHistory}]` | только своя очередь; lease каталога должен быть свежим |
| `ack` | `[refs]` ≤200 | `{acknowledged}` | device-scoped; ref = `from:deviceId:id` |
| `status` | `[refs]` ≤200 | `{ref: [{account,id,acknowledgedAt,readAt?}]}` | только отправителю |
| `read` | `[refs]` ≤200 | `{read}` | **новый (C5)**: только устройство-получатель; идемпотентно; `readAt` виден отправителю в `status`; чужие/неизвестные ref — no-op без раскрытия |
| `retract` | `[refs]` ≤200 | `{retracted}` | **новый (C3)**: только отправитель; удаляет недоставленные копии из всех очередей; tombstone 7 дней; идемпотентно |
| `retractions` | `{since: ms}` | `{retractions:[{ref,deletedAt,from}]}` ≤500 | **новый**: только участники (отправитель или устройство-получатель); курсор `since` exclusive |
| `push.subscribe` | `{endpoint, keys:{p256dh,auth}}` | `{subscribed:true}` | **новый (C6)**: одна подписка на устройство; HTTPS public endpoint (SSRF-guard: без IP/loopback/private/.local/.internal); ключи base64url ≤256 |
| `push.unsubscribe` | `null` | `{subscribed:false}` | **новый** |
| `users` | `null` | `[{account}]` | зарегистрированные v2-аккаунты |
| `directory` | account | `{root, genesis, history}` | каталог любого аккаунта |
| `install` | `{manifest, proofs?, genesis?}` | `{revision, digest}` | добавление/отзыв устройств, recovery (`signer:'recovery'`), продление lease; pairing-proof свежего устройства обязателен |

Отзыв устройства (`install` без него в ростере): очереди очищаются, push-подписка
устройства удаляется, ID/ключи нельзя воскресить.

## 3. Профили и наклейки (адаптер v1, B1/B2)

Бизнес-логика и валидация — проверенные `server/stickers.js` + `server/avatars.js`;
хранение — зашифрованный alpha-snapshot (раздел `stickers`), **не** production-файлы.
Авторизация: Google-сессия + device proof на каждый запрос (v1-токены не принимаются).

Маршруты (монтированы под `/api/v2`):
- `PUT /profile/name {displayName}` — 1..64 символа.
- `GET /user/:username/avatar` → `{image, imageUrl, frame, revision, displayName}`
  (image — нормализованный JPEG 512×512 без EXIF; чужой профиль виден любому
  аутентифицированному v2-устройству, как в v1).
- `PUT /profile/avatar {image?, frame, revision, uploadId?}` — CAS по `revision`;
  frames: `none|minimal|silver|graphite`; image ≤512 КБ (JPEG/PNG/WebP, статичный,
  ≤16 MP, перекодируется sharp); `uploadId` (16–80 `[A-Za-z0-9_-]`) — идемпотентность;
  смена frame без image сохраняет фото; `avatarOwner = SHA256(root)` — фото не
  наследуется при переиспользовании ника.
- `POST /profile/avatar/chunk {uploadId, offset, total, chunk, frame, revision}` —
  chunk ≤65536 base64-символов, total ≤699052, порядок строгий, повтор хвоста
  идемпотентен, TTL 120 с, ≤8 одновременных загрузок.
- `GET /stickers/inventory` → `{inventory, wall, revision}` (свои).
- `GET /user/:username/stickers` → публично: `{displayName, revision, wall,
  inventory:[{giftId, stickerId}]}` (без note/from).
- `POST /stickers/gift {toUsername, stickerId, note≤240, requestId}` → `{giftId}`;
  каталог: `orbit, moth, comet, ghost, flowers`; self-gift запрещён; получатель
  должен быть v2-enrolled; requestId — идемпотентность (конфликт параметров → 409);
  лимиты: 8 подарков/мин, receipts ≤10000, inventory получателя ≤2000.
- `PUT /stickers/wall {wall, revision}` — CAS; ≤32 размещений; только свои giftId;
  поля `{giftId,xNorm∈[0,1],yNorm∈[0,1],scale∈[0.5,2],rotation∈[-π,π],zIndex∈[0,31]}`.

**Proof для адаптера**: `operation = SHA256hex(JSON.stringify(['stickers',
{method, path, body}]))`, где `path` — путь относительно `/api/v2`
(например `/stickers/gift`), `body` — точное отправляемое JSON-тело
(`null` для GET). Заголовок `x-device-auth: {"account","id","nonce","proof"}`.
Один nonce на запрос. Account proof должен совпадать с Google-сессией.
Socket-hint `profile {account}` рассылается устройствам аккаунта при смене аватара.

## 4. Self-chat / «Избранное» (B3)

`messageText` допускает `from === to`: конвертов `1..8` (один ростер),
`fromRevision === toRevision`, `fromDigest === toDigest`. `sealMessage` при
self шифрует только ростер отправителя (не дедуплицирует постфактум).
`verifyMessage` ожидает fanout из одного ростера. Обычные сообщения
(from≠to) байт-совместимы со старой схемой (golden-векторы не изменились).
**Rollout**: старые клиенты отвергают self-сообщения — обновить клиенты до
включения «Избранного». Delivery/ACK — per-device как обычно.

## 5. Wire payload (соглашение клиентов, opaque для сервера)

- Plain text — без маркера (обратная совместимость).
- Reply (ZCODE): `{"shade":1,"t":"текст","r":{"ref","from","text"}}`,
  preview `r.text` ≤2000 UTF-16 единиц; decode с fallback на raw text.
- Медиа (C4, контракт для реализации UI): `{"shade":1,"m":{"id","mime","index","total","chunk"}}`,
  chunk — base64 сырых байтов, **RAW_CHUNK = 32768** (итоговый plaintext ≤65536).
  Сборка по `id/index` на клиенте; EXIF/ICC срезаются до шифрования
  (Android `prepareMessageImage`, web Canvas/ImageDecoder). Серверных изменений
  не требует: лимиты конверта/очередей проверены тестом 300 КБ round-trip.
  Кодек `m` должен быть добавлен согласованно в `alpha-client.mjs` и Dart
  `payload.dart` (сейчас неизвестные маркеры отображаются как raw text).

## 6. Socket.IO события

Сервер→клиент (hints, без содержимого; потеря чинится signed fetch 15 с):
`inbox`, `receipts` (ack/read), `retracted`, `profile {account}`,
`typing {account, until}` (TTL 3 с), `presence {account, online}`.
Клиент→сервер: `watch {peer}`, `unwatch {peer}`, `typing {peer}`.
Приватность (C2): typing/presence доставляются **только между аккаунтами с
существующей перепиской** (relationship из delivery-снапшота); состояние в
памяти процесса; троттлинг typing 2 с на аккаунт; online = любое устройство
аккаунта в сети; ≤100 watchers на аккаунт.

## 7. Web Push (C6)

VAPID: `ALPHA_VAPID_PUBLIC_KEY/PRIVATE_KEY/SUBJECT` (без них `push_not_configured`).
Уведомление — **wake-only**: payload `{"type":"wake"}`, TTL 60 с; без текста,
ref, имён аккаунтов. Отправка только устройствам-получателям; ошибка push не
роняет E2EE-send; 404/410 → подписка удаляется; отзыв устройства → подписка
удаляется. Подписки хранятся в зашифрованном snapshot, ≤10000 глобально.
Клиент: `PushManager.subscribe` → `push.subscribe`; при wake — разблокировка
vault и signed fetch (фоновая расшифровка без ключей невозможна — честно
«Новое сообщение»).

## 8. Лимиты и ресурсы

8 устройств/аккаунт; lease ≤24 ч; каталог ≤4096 ревизий; текст ≤64 КиБ;
очередь устройства ≤200 сообщений / ≤8 МиБ; receipts ≤10000; tombstones ≤10000
и 7 дней; аватар ≤512 КБ; стена ≤32; подарки 8/мин; API 300/мин;
challenge ≤1000 активных; сессия 8 ч.

## 9. Покрытие тестами (server, 53/53)

`alpha-profiles-stickers` (профили/наклейки/авторизация/restart),
`self-chat` (fanout/негативы), `alpha-typing-presence` (приватность/троттлинг/
multi-device/restart), `alpha-retract` (авторизация/offline/идемпотентность/
приватность tombstones/restart), `alpha-media` (300 КБ round-trip/лимиты),
`alpha-read-ack` (авторизация/идемпотентность/restart), `alpha-push`
(SSRF/wake-only/410/restart/unconfigured), `alpha-integration` (сквозной
жизненный цикл всех фич + отзыв + restart), плюс прежние 42 теста v1/v2.
Клиентские golden-векторы: `client/test/assets/device_v2_vectors.json`
(генератор `client/tools/generate_v2_vectors.mjs`, включая self-векторы).

## 10. Ограничения / следующие шаги

- Медиа-кодек `m` и UI reply/media/typing/presence/read/retract/push в PWA и
  Android — клиентская работа ZCODE/следующая итерация (контракты выше).
- DNS-rebinding SSRF для push-endpoint не закрыт полностью (только литералы/
  приватные диапазоны); для production — резолв с проверкой адреса.
- Nonce для native ID token-входа (рекомендация Kimi-ревью) — перед публичным
  production; для изолированного alpha приемлемо.
- `upgrade_required` guard для v1-маршрутов после enrollment (`assertLegacyAllowed`)
  существует в модели, но не подключён к production `server.js` — отдельное
  разрешение на production-миграцию.
- Реальный Google OAuth/APK/iPhone не проверялись; тесты — синтетические
  идентичности против реального alpha HTTP/WSS.