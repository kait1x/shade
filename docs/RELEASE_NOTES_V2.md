# Shade v2 — release notes (17.11.2026)

Статус: **READY FOR STAGING / BLOCKED FOR PRODUCTION**. Публичный релиз
не выполнялся; production v1 не затронут.

## Новое в v2 относительно v1

- Device protocol v2: аккаунт-якорь + независимые ключи устройств, genesis
  подписан исходным RSA, подписанные каталоги ревизий, fanout {k,d} на каждое
  устройство обоих участников + PSS-подписи, per-device ACK/read/retract.
- Multi-device pairing (QR + proof-of-possession), device-session bootstrap,
  отзыв устройств с тумбстоунами и очисткой очередей.
- Web/PWA (alpha): Flutter Web release, strict CSP, Service Worker, offline,
  Web Push (wake-only), Google OAuth PKCE/nonce, Android↔Web E2EE.
- Миграция v1→v2: read-only загрузчик v1-хранилища, idempotent prepare,
  crash-safe enrollment journal (schema v10/v11), legacy-key вход без Google,
  one-way мост недошедших v1-очередей, CLI (audit/prepare/status/verify/retry/
  rollback/checkpoint/replay-restore/guard-export/stop/resume).

## Добавлено в этом релизном цикле

- **RSA-2048 → RSA-4096 rotation**: явная смена криптографической идентичности
  с аттестацией старого ключа (привязка к digest genesis/manifest, одноразовый
  nonce, first-commit-wins). Старый ключ остаётся на устройстве для истории
  и bridged-сообщений. Android UI с честным предупреждением.
- **Живой мост v1→v2**: v1-пользователи продолжают писать переведённым
  собеседникам; ciphertext тем же root RSA; bridge-ack дренирует v1-очередь
  и даёт v1-отправителю статус delivered. Durable two-phase ACK.
- **Lossless rollback**: replay-restore (старый бэкап + новое живое состояние),
  скользящие durable checkpoints, fail-closed конфликты. 6/6 интеграционных
  тестов включая randomized model.
- **P0-фиксы**: ACK моста по полному ref `from:id` (коллизия id исправлена);
  legacy-мост только primary-устройству.
- **Честный v2→v1**: структурированный `peer_upgrade_required`, защищённый
  outbox, UI-баннер вместо тихой изоляции.
- Production-шаблоны: Caddy (app/api), systemd shade-v2, env; исправлен
  ReadWritePaths staging-юнита (guard/checkpoints).

## Исправлено / уточнено

- Диагноз инфраструктуры: VPS жив (SSH/HTTP/Caddy TLS sslip.io 200 OK внешне);
  TLS доменных hostname падает из-за отсутствия site-блоков Caddy (не VPN,
  не DNS). `app.shadechat.ru` DNS отсутствует. Прежние docs «VPS не отвечает /
  NXDOMAIN» устарели — обновлены.
- Schema v11 (аддитивная): anchor_key/legacy_key в v2_accounts, rotation/
  anchor_key в журнале. v9→v10→v11 апгрейд проверен тестом.

## Известные ограничения

- v2→v1 доставка — после миграции собеседника (обратный мост отложен).
- read-статус bridged v1→v2 не транслируется (только delivered).
- Web/PWA rotation и legacy-мост — в работе (ZCODE).
- Galaxy A31 с debug-подписью: release поверх не устанавливается (пути B1/B2
  в docs/ANDROID_V1_V2_UPGRADE.md).
- Физический iPhone/push не тестировался.

## Проверки

Server 82/82 · Flutter 134/134 · analyze 0 errors / 0 warnings / 49 info

## Дополнение (17.11.2026, вечер)

- Сквозной E2E-тест живого моста: реальный v1-сток → CLI prepare → alpha →
  Dart-enrollment → drain ciphertext (текст+IMG) → bridge-ack → late-сообщение
  без дублей → v2-переписка (`device_v2_migration_test.dart`, `E2E bridge`).
- Multi-origin: `ALPHA_ALLOWED_ORIGINS` (app+api на одном v2-процессе),
  тест `alpha-origins.test.mjs`; production env-шаблон обновлён.
- Негативные тесты legacy-сессии: `alpha-legacy-session.test.mjs` (replay,
  чужой ключ, неизвестный аккаунт, pre-enrollment lock).
- Web/PWA пересобран из текущего worktree (37 ассетов, --csp, без CDN).
- SSH-аудит production выполнен (read-only): 4 аккаунта, все RSA-4096 и
  Google-linked; служба здорова, бэкапы на месте.
- Автоматизирован staging-деплой: `deploy/staging/staging-deploy.sh`;
  промежуточный Caddy-шаг `deploy/staging/Caddyfile.stage1` (api → текущий v1
  для сертификата, без переключения трафика).
(существовавшие). Детали: docs/V2_SECURITY_TEST_REPORT.md,
docs/V2_COMPATIBILITY_REPORT.md.

## Совместимость данных

Обновление release v1 → release v2 поверх: тот же applicationId
`com.example.shade`, versionCode 2 > 1, та же release-подпись
`CN=Shade Android Release` — **сверено apksigner/keytool для ARM64 APK,
универсального APK и AAB** (SHA-256
`d790f9763fbc4bb33a87b0d530c5738d9d3aabcaaebb7ef5b67a099745104edf`).
SQLCipher/ключи/сессия сохраняются; миграция схемы аддитивная (v9→v10→v11).