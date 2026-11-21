# Shade V2 — отчёт о совместимости (17.11.2026)

Все проверки — локальные интеграционные тесты на синтетических данных
(реальный `server.js`, реальный alpha-процесс, реальные форматы хранилищ,
Socket.IO-клиенты). Физических устройств не было. Статусы честные.

## 1. Матрица направлений

| Направление | Статус | Поведение | Доказательство |
|---|---|---|---|
| v1 → v1 | VERIFIED | без изменений (guard default off) | guard-тест: pre-guard send ok |
| v1 → v2 (получатель enrolled) | VERIFIED | живой мост: v1 принимает ciphertext (тот же root RSA), v2 дренирует legacyInbox, bridge-ack дренирует v1-очередь, receipt → delivered | guard-тест: bridged send ok → messageStatus delivered → idempotent retry |
| v1 → v2 (получатель rotation_required) | VERIFIED (сервер) | очередь импортируется при prepare; после rotation расшифровка старым ключом на устройстве | rsa-rotation тест: legacy.inbox + openV1Payload старым ключом |
| v2 → v1 (получатель на v1) | ОГРАНИЧЕНО | честный отказ `peer_upgrade_required` (409); ciphertext в подписанном outbox; UI-баннер; отправка после миграции собеседника | bridge-тест: 409 + код; Dart outbox |
| v2 → v2 | VERIFIED | fanout на все устройства обоих + PSS-подписи | bridge-тест, multidevice, self-chat |
| Android v2 ↔ Web v2 | VERIFIED | native RSA ↔ WebCrypto vault, второе устройство, device-session bootstrap | alpha-native-session, bridge-тест (op2 fanout) |
| v1 → v2 (отправитель enrolled) | VERIFIED | `upgrade_required` на v1 send/auth/refresh/reissue/profile; reversibility при guard-off | guard-тест |

## 2. Сквозные свойства

| Свойство | Статус | Детали |
|---|---|---|
| Доставка без дублирования | VERIFIED | дедуп по `from:id`+digest (мост), receipts/digest (v2), replay ID (клиент); ACK-тумбстоуны ≤1000; collision-тест двух отправителей с одним id |
| Порядок | VERIFIED (в рамках модели) | v1-очередь FIFO + timestamp; v2 createdAt + клиентская сортировка; мост сохраняет исходные v1 ID (`v1:<from>:<id>`) |
| E2EE | VERIFIED | сервер видит только {k,d}; snapshot не содержит plaintext (тест); bridged-ciphertext тем же root RSA; rotation — старый ключ только на устройстве |
| ACK | VERIFIED | v2 per-device acknowledgedAt; мост ACK по ref после durable save; v1 receipts delivered через bridge-ack |
| Read state | ЧАСТИЧНО | v2 read-ACK per-device (тесты); bridged v1→v2 read НЕ транслируется (только delivered) — документированное ограничение |
| Retract | VERIFIED (v2) | delete-for-all, тумбстоуны ≤2000/аккаунт, очистка очередей; rollback replay сохраняет retract; v2→v1 retract не мостится (ограничение) |
| Offline queues | VERIFIED | v1 ≤200/30MiB/TTL 7 дней; мост импортирует ≤200 + честный inboxTruncated; v2 per-device ≤200/8MiB; queue-full — явный отказ, не тихая потеря |
| Повторное подключение | VERIFIED | restart alpha (снапшот+тумбстоуны), signed fetch repair, socket wake-hints не гарантируют доставку (fetch авторитетен) |
| Multi-device | VERIFIED | pairing proof, fanout, device-session bootstrap, revocation (tombstone+purge); legacy-мост primary-only (P0) |
| Гонка prepare↔guard | VERIFIED | live-перечитывание очереди при каждом legacy.inbox; поздние сообщения доставляются; acked не возвращаются |
| Crash enrollment | VERIFIED | журнал v10/v11, resume тем же genesis, adoption каталога, неверная фраза не повреждает состояние |
| Crash ACK↔export | VERIFIED | тумбстоуны в snapshot-транзакции; re-export при старте |
| Rollback | VERIFIED | lossless replay (6/6, randomized model); guard-off reversibility; prepared rollback с бэкапом; enrolled rollback CLI refused |
| Сквозной v1→v2 E2E (Dart) | VERIFIED (интеграционный, синтетика) | `E2E bridge` тест: реальный v1 at-rest сток → prepare → alpha → enrollment → drain текста/IMG исходным RSA → bridge-ack тумбстоуны → late-сообщение без дублей → v2 send Web-пиру |
| Multi-origin app+api | VERIFIED | `alpha-origins.test.mjs`; `ALPHA_ALLOWED_ORIGINS`; OAuth/cookie канонические на app |

## 3. Ограничения перехода (честно)

1. v2→v1 доставка недоступна до миграции собеседника (обратный мост отложен).
   Ранние v2-пользователи могут переписываться с другими v2 и получать от v1.
2. `read` для bridged v1→v2 не транслируется; v1-отправитель видит delivered.
3. Push о bridged-сообщениях: Android будится v1-FCM (токен жив ≤7 дней),
   PWA — foreground/reconnect/polling. Выделенный v2 wake-push для моста —
   следующий этап.
4. TTL v1-очереди 7 дней: офлайн >7 дней — потеря by design v1 (документировано).
5. Rotation — смена криптографической идентичности (аттестация проверяема
   старым pinned ключом; новые контакты — TOFU). Старый скомпрометированный
   ключ ⇒ скомпрометированная аттестация.
6. Web/PWA: legacy-мост и rotation не реализованы (направление ZCODE).
7. Lease каталога 24 ч: после rollback/replay expired lease требует renewal;
   send/fetch закрыты до продления (модель, не дефект).
8. Группы в v1 production отключены — переносить нечего.

## 4. Не проверено

- Физические устройства (Galaxy A31 release-подпись, iPhone PWA/push).
- Production OAuth (реальные credentials), реальный VPS staging.
- Поведение Keystore при OTA-обновлениях OEM.
- Нагрузочное тестирование (baseline порогов rollout — на staging).