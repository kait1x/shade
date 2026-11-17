# Shade V2 — финальный релизный документ

Дата: 17.11.2026. Worktree: `.agents/worktrees/integration-android-pwa`,
ветка `integration-android-pwa`, HEAD `e986759` + незакоммиченные изменения
(коммиты не выполнялись согласно правилам репозитория). Резервная копия
исходных незакоммиченных изменений:
`.agents/backups/pre-v2-release-20261117-1717/` (patch + untracked, HEAD.txt).
Дополнительный независимый бэкап (17.11.2026 20:07):
`C:\Users\Kait1x\Documents\shade-worktree-backup-20261117-200718\`
(tracked-changes.patch 116 КБ + 20 untracked файлов + git-status/head).

**Общий статус: READY FOR STAGING / BLOCKED FOR PRODUCTION.**
Production-операции (DNS, Caddy, БД, массовая миграция, guard, остановка v1,
публикация APK/PWA) НЕ выполнялись и требуют отдельного разрешения владельца.

## 1. Статусы по направлениям

| Направление | Статус | Доказательство |
|---|---|---|
| Migration engine v1→v2 | VERIFIED (локально, синтетика) | `migration.test.mjs`, `migration-dryrun.test.mjs` |
| RSA-2048→4096 rotation | READY (сервер+Android), NOT TESTED (физ. устройство) | `rsa-rotation.test.mjs` 2/2; Dart rotation-тесты 5/5 файл |
| Rollback без потери сообщений | VERIFIED (интеграционно) | `rollback-journal.test.mjs` 6/6, включая randomized model |
| Живой мост v1→v2 | VERIFIED (интеграционно + сквозной E2E) | guard-тест: bridged send + bridge-ack prune + delivered; Dart `E2E bridge` тест: реальный v1-сток → CLI prepare → alpha → enrollment → drain текста/IMG → late-сообщение без дублей → v2-переписка |
| Multi-origin (app+api) | VERIFIED | `alpha-origins.test.mjs`: extra first-party origin принят, чужой отклонён, http-extra запрещён; `ALPHA_ALLOWED_ORIGINS` |
| v2→v1 | ОГРАНИЧЕНО (честный отказ) | `peer_upgrade_required` 409 + outbox + UI-баннер |
| Android v2 ↔ Web v2 E2EE | VERIFIED (интеграционно) | `alpha-native-session`, `multidevice`, `self-chat` |
| Server tests | VERIFIED 82/82 | `node --test --test-concurrency=1`, 183 с |
| Flutter tests | VERIFIED 134/134 | `flutter test`, 3:01 |
| Flutter analyze | VERIFIED 0 errors / 0 warnings / 49 info | info — существовавшие ранее (SDK deprecated material, alpha-web линты) |
| Android release APK (ARM64) | VERIFIED (собран, подпись = v1) | `artifacts/v2-release/shade-v2-arm64-release.apk`, apksigner |
| Android universal APK / AAB | VERIFIED (собраны, подпись = v1) | universal 96 279 358 B; AAB 83 830 606 B (jarsigner + keytool) |
| Web/PWA release | INTEGRATED / VERIFIED (QA) | финальная ZCODE `73653d8` слита (merge `a367a9d`, 0 конфликтов); Edge+WebKit browser QA PASS/0 ошибок; server 82/82, Flutter 137/137; `docs/PWA_INTEGRATION_REPORT.md`; Flutter-web standalone crypto (fast_rsa) — документированное ограничение, рабочий PWA — JS-оболочка |
| DNS | VERIFIED | A @/www/api + **alpha** резолвятся (1.1.1.1/ns1.reg.ru); app — записи нет (этап F) |
| HTTPS alpha.shadechat.ru | VERIFIED | Let's Encrypt до 15.02.2027, TLS 1.3, HSTS/CSP; WSS 101; `docs/STAGING_VERIFICATION_REPORT.md`. api.shadechat.ru — site-блок не добавлен (этап F, решение владельца) |
| Staging на VPS | DEPLOYED (systemd) / VERIFIED | `shade-staging.service` active, Caddy alpha-блок, origin https; smoke 12/12 на домене; интегрированный релиз `20261117-225500` (commit `3edb28b`, MANIFEST 122/122) загружен и проверен, переключение — `admin-update.sh` (владелец) |
| Production deployment | NOT DEPLOYED | этапы D–G только с разрешения владельца |
| Физический iPhone / реальный A31 | NOT TESTED (устройство) / READY (сборка) | A31 debug APK `artifacts/v2-a31/shade-v2-a31-debug.apk` подпись = установленной на A31 (обновление поверх, путь B1); процедура — `docs/PWA_INTEGRATION_REPORT.md` §A31; iPhone — `docs/IPHONE_PWA_STAGING.md` |

## 2. Устранённые блокеры

### 2.1 RSA-2048 → RSA-4096 (было: аккаунты не мигрировали)
Реализована явная rotation с доказательством владения старым ключом:
- `validateLegacyUser`: RSA-2048..4095 → `rotation_required` (RSA<2048 — отказ).
- CLI `prepare` импортирует очередь таким аккаунтам без записи в реестр.
- Протокол: `rotationText`/`verifyRotation` (client/web/protocol/device-v2.mjs —
  аддитивные экспорты; общий v2-протокол по-прежнему требует 4096 везде;
  2048 допускается ТОЛЬКО в отдельном legacy-attestation verifier).
- Сервер: `/api/v2/session/rotation-challenge` + `/api/v2/legacy-rotation`
  (sessionless bootstrap, rate-limit, одноразовый nonce, привязка аттестации
  к точным digest genesis/manifest, первая-успешная-фиксируется, конфликтующая
  вторая отклоняется, idempotent resume после crash).
- Клиент Android: `enrollWithRotation` (crash-safe журнал schema v11, новый
  якорь сохраняется ДО сети; старый ключ остаётся в secure storage v1 +
  `legacy_key` в SQLCipher для расшифровки истории/bridged-ciphertext;
  неверная фраза не повреждает состояние). UI: явный баннер «смена
  криптографической идентичности», кнопка «Сменить ключ и зарегистрировать».
- Аттестация публикуется в `directory.rotation` — собеседники со старым
  pinned ключом проверяют непрерывность владения. **Это смена идентичности,
  не её сохранение** — документировано честно.
- `verify` перепроверяет цепочку аттестации против read-only источника.
- Тесты: `server/test/rsa-rotation.test.mjs` (CLI-матрица + enrollment +
  6 негативных кейсов), Dart (rotation, crash-resume, wrong phrase).

### 2.2 Rollback без потери новых сообщений (было: потеря очередей после бэкапа)
- `server/multidevice/rollback-journal.mjs`: event-монотонное слияние
  старый-бэкап + новое-живое-состояние. Очереди: live-проекция авторитетна;
  backup-записи не воскрешаются при доказанном пост-бэкап ACK/retract/revocation.
  Receipts/delivery/retractions: объединение с приоритетом live (конфликт
  digest — fail closed). Каталоги: только точный подписанный префикс +
  полная криптографическая перепроверка реестром. Rotation-аттестации
  сохраняются. Lease не «чинится» — expired lease требует renewal (честно).
- CLI: `checkpoint` (разовый проверяемый бэкап) и `replay-restore`
  (атомарное слияние + safety-бэкап live перед заменой; конфликт — без изменений).
- `alpha-store`: opt-in скользящие durable checkpoints
  (`ALPHA_CHECKPOINT_DIR`/`ALPHA_CHECKPOINT_KEEP`, по умолчанию 20).
- `rollback-v2.sh`/`migration-run.sh`: новые команды, обновлённые заголовки.
- Доказано: 6/6 интеграционных тестов, включая randomized model (5 раундов
  случайных send/ack/read/retract через точку бэкапа; merged == live).
- Ограничение: если живой снапшот нечитаем — replay невозможен, остаётся
  прямой snapshot-restore с документированной потерей пост-бэкап очередей
  с relay (локальные копии на устройствах сохраняются).

### 2.3 Совместимость v1↔v2 (было: v2-пользователь не получал сообщения от v1)
- **Живой мост v1→v2**: v1-сервер принимает отправки к enrolled-получателям
  (ciphertext тем же неизменным root RSA → E2EE не ослабляется); v2-клиент
  дренирует через live `legacyInbox`; после durable ACK клиента v2 экспортирует
  additive bridge-ack файл (`ALPHA_V2_BRIDGE_ACK_FILE` →
  `SHADE_V2_BRIDGE_ACK_FILE`), v1 в своей serial-транзакции удаляет
  подтверждённый ciphertext и переводит receipts в `delivered` — очередь
  не переполняется, v1-отправитель видит честный статус.
- Durable two-phase ACK: тумбстоуны в том же snapshot-транзакционе, что и
  удаление из inbox; re-export при старте alpha залечивает crash между
  коммитом и записью файла.
- **P0-фиксы**: ACK по полному ref `from:id` (коллизия id двух отправителей
  больше не удаляет чужое сообщение; клиент+сервер+тесты обновлены);
  legacy-мост разрешён ТОЛЬКО primary-устройству (вторичное не может
  дренировать/ACK-ать очередь, которую не в силах расшифровать).
- **v2→v1**: полноценный обратный мост отложен (оценка 10–15 дней, отдельное
  решение). Вместо тихой изоляции — честный структурированный отказ
  `peer_upgrade_required` (409), ciphertext остаётся в подписанном outbox,
  UI-баннер «собеседник ещё не перешёл на v2». Отправка возобновится после
  миграции собеседника (retry outbox).
- Ограничения моста (документированы): `read`-статус bridged-сообщений не
  транслируется (только delivered); v1-push будит обновлённое Android-приложение
  (FCM-токен v1 жив до TTL 7 дней), PWA полагается на foreground/reconnect/polling;
  TTL v1-очереди 7 дней — сообщения офлайн >7 дней теряются by design v1.
- Тесты: guard-тест (bridged send → bridge-ack → messageStatus delivered →
  idempotent retry → reversibility), primary-only негатив, peer_upgrade_required.
- **Сквозной E2E (17.11.2026, интеграционный, синтетика):**
  `client/test/device_v2_migration_test.dart` → `E2E bridge`: реальный v1
  at-rest сток (AES-GCM/HMAC/metadata-конверты) → CLI `prepare` → alpha с
  read-only `legacySource` → Dart `enrollLegacy` → `syncLegacyInbox`
  (текст + `IMG:` расшифрованы исходным RSA) → bridge-ack файл содержит
  `from:id` тумбстоуны → v1-отправитель пишет после enrollment → live top-up
  доставляет без дублей → повторная синхронизация 0 → v2-сообщение Web-пиру
  доходит. Helper: `server/tools/alpha-native-transport.mjs` (`init-bridge`,
  `v1-send`).

## 3. Инфраструктура: установленные причины (read-only, 17.11.2026)

Проверено с рабочей машины + внешними узлами check-host.net (API JSON):
- DNS A согласованы на 1.1.1.1, 8.8.8.8, ns1.reg.ru, ns2.reg.ru (16/16
  запросов): `@`/`www` → 95.163.244.138, `api` → 13.143.207.108.
  **`app.shadechat.ru` — записи нет (NO ANSWER на всех 4).**
- **NS/SOA «не возвращаются» — АРТЕФАКТ КЛИЕНТА, не проблема зоны:**
  контрольный тест `NS reg.ru`/`SOA reg.ru` через 1.1.1.1 тоже пуст, хотя
  записи заведомо существуют. VPN happ-xray (fake-ip DNS) перехватывает DNS
  и обрабатывает только A/AAAA, молча отбрасывая прочие типы. Делегирование
  подтверждено рабочими A-ответами авторитетных ns1.reg.ru/ns2.reg.ru;
  полная проверка NS/SOA — с машины вне VPN (`dig NS shadechat.ru +trace`).
- TCP 22/80/443 открыты на ОБЕИХ IP.
- SSH banner 13.143.207.108: `SSH-2.0-OpenSSH_10.0p2 Debian-7+deb13u4` —
  SSH жив (утверждение прежних docs «SSH таймаутит» устарело).
- HTTP :80 api → 308 → https (Caddy жив; подтверждено внешне: Baku/Warsaw).
- HTTP :80 apex (Host shadechat.ru) → 200 (другой сервер 95.163.244.138).
- **TLS api.shadechat.ru → `tlsv1 alert internal error` из Болгарии/Румынии/
  Швеции; apex → `handshake failure` из РФ/США. Проблема СЕРВЕРНАЯ,
  не VPN/не DNS/не Schannel.** Контроль: TLS к 1.1.1.1 с этой машины — 301 OK.
- **Корень**: `https://13-143-207-108.sslip.io/` → **200 OK внешне**
  (Iran/Iceland) — Caddy + Let's Encrypt на VPS работают. В Caddyfile
  (`deploy/vps/Caddyfile`) есть ТОЛЬКО sslip.io-блок; для SNI
  `api.shadechat.ru` сертификата нет → internal error. Исправление —
  добавить site-блоки `deploy/production/Caddyfile.example` (с разрешения
  владельца). Apex-сервер 95.163.244.138 не имеет сертификата shadechat.ru.
- VPN happ-xray активен (default route), но на результат не влияет
  (внешние узлы воспроизводят ошибку).

Команды владельцу на VPS (read-only аудит): `deploy/staging/production-audit.sh`
(SSH key `~/.ssh/id_ed25519_pl`). Дополнительно:
```bash
systemctl status caddy shade --no-pager
journalctl -u caddy -n 100 --no-pager | grep -iE 'error|certificate|acme|obtain'
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
cat /etc/caddy/Caddyfile
ss -tlnp | grep -E ':(22|80|443|3000|3101|3201)\b'
curl -s http://127.0.0.1:3000/health
ls -la /var/lib/caddy/.local/share/caddy/certificates/ 2>/dev/null || ls -la /root/.local/share/caddy/certificates/
```

### DNS-записи REG.RU (точные значения, применяет владелец)
| Тип | Имя | Значение | TTL | Назначение |
|---|---|---|---|---|
| A | `app` | `13.143.207.108` | 3600 | production PWA+API (этап F) |
| A | `alpha` | `13.143.207.108` | 3600 | staging v2 (этап B) |
| A | `staging-api` | `13.143.207.108` | 3600 | резерв staging |

`@`/`www` (95.163.244.138) и `api` (13.143.207.108) уже существуют —
не менять до отдельного решения. `api` переключается на v2-процесс только
на этапе F; до этого v1 работает через sslip.io hostname.

## 4. Staging (этап B) — готово к развёртыванию

**Read-only аудит VPS выполнен 17.11.2026 21:07 MSK** (проектный audit-ключ):
`docs/VPS_AUDIT_2026-11-17.md`. Сервер здоров (shade/caddy active, ошибок нет),
Node v22.23.5 / Caddy 2.6.2 / Debian 13.7, 15G диск / 547 МБ RAM available,
порты 3101/3201 свободны, production-данные 0700 (изоляция подтверждена),
бэкапы ежедневно 03:17 (retention не задан), Caddyfile валиден и содержит
ТОЛЬКО sslip-блок (корень TLS-дефекта доменов подтверждён на сервере).
Staging-пользователей/каталогов/юнитов нет — чистый лист. Ничего не изменено.

Комплект `shade-staging` (запрос владельца, SSH-доступ агента):
`deploy/staging/setup-staging.sh`, `shade-staging.service.example`,
`staging.env.example`, `Caddyfile.staging.example`, `smoke-staging.sh`,
`package-upload.ps1`; upload-пакет собран (`build/staging-upload`, 51.3 МБ,
без секретов; web-alpha пересобран 17.11.2026). Выделенный SSH-ключ
`id_ed25519_shade_staging` передан владельцу; пользователь ещё не создан.

Конфигурация (альтернативный комплект shade-alpha, другая сессия):
`deploy/alpha/.env.example`, `deploy/alpha/shade-alpha.service.example`
(ReadWritePaths исправлен: guard/checkpoints требуют записи вне data/),
`deploy/staging/Caddyfile.example`, **`deploy/staging/staging-deploy.sh`**
(идемпотентный деплой staging: пользователь/каталоги, npm ci, node --check,
health-check, бэкап Caddyfile + validate перед merge блока),
**`deploy/staging/Caddyfile.stage1`** (промежуточный шаг: alpha → staging v2,
api → ТЕКУЩИЙ v1 для получения сертификата без переключения трафика),
`migration-run.sh`, `backup-verify.sh`, `rollback-v2.sh`, `production-audit.sh`,
`rollout-monitor.sh` (read-only мониторинг health/очередей/error-rate).
Процедура: `docs/V2_DEPLOYMENT.md` §2–3, `docs/IPHONE_PWA_STAGING.md`.

Dry-run матрица на синтетических данных (локально, integration):
`server/test/migration-dryrun.test.mjs` 3/3 — пустые аккаунты; 250 сообщений
(обрезка до 200 + честный `inboxTruncated`); RSA-2048/4096/1024; multi-device;
отозванное устройство (очистка очередей, тумбстоун, независимость legacy-inbox);
неудачный enrollment (чужой ключ, stale, чужой аккаунт, неподготовленный) +
успешный после отказов; идемпотентный повтор; stop/resume. Crash-recovery:
Dart journal-тесты + серверный restart-тест + rollback replay-тесты.

Развёртывание на VPS: BLOCKED — нужен SSH-доступ и разрешение владельца.
Production-база на запись не подключалась; staging использует отдельную
копию (`ALPHA_V1_DATA_DIR`), отдельные секреты/OAuth/порт/данные/логи.

## 5. Security gate (сводка; детали — docs/V2_SECURITY_TEST_REPORT.md)

| Проверка | Статус |
|---|---|
| E2EE: сервер не видит plaintext | VERIFIED (тесты: snapshot не содержит plaintext; openMessage только на устройстве) |
| Приватные ключи не покидают устройство | VERIFIED (код-аудит + rotation-тесты) |
| Nonce/replay (challenge, legacy-session, rotation) | VERIFIED (одноразовые nonce, consumed-on-failure, тесты replay) |
| PKCE S256 + state + nonce OAuth | VERIFIED (код + alpha-vault/session тесты) |
| Device revocation | VERIFIED (tombstones, queue purge, отказ challenge, тесты) |
| Session fixation | VERIFIED (старая сессия удаляется при login; cookie __Host- prefix HTTPS) |
| Legacy RSA authentication | VERIFIED (proof-of-possession, квоты, отказ cross-account challenge; `alpha-legacy-session.test.mjs`: replay nonce, чужой ключ, неизвестный аккаунт, pre-enrollment lock) |
| Multi-origin trust | VERIFIED (`alpha-origins.test.mjs`; extra origins только https, OAuth/cookie канонические) |
| Migration guard / opt-in | VERIFIED (default off; reversibility тест) |
| Race conditions (prepare↔guard, ACK↔export) | VERIFIED (race top-up тест, durable two-phase ACK, re-export при старте) |
| DNS-rebinding egress Push | VERIFIED (SSRF guard + allowlist провайдеров; тесты) |
| Секреты в логах | VERIFIED (Caddy filter вырезает Authorization/Cookie/X-Session-Token/X-Username; аудит-журнал — только коды ошибок) |
| Права хранилищ | VERIFIED (0700 dirs, 0600 files, writer.lock, UMask 0077, ProtectSystem=strict) |
| TLS-конфигурация | BLOCKED (server-side: нет site-блоков для доменов; шаблон готов) |
| Backup/restore | VERIFIED локально (backup-verify.sh, replay-restore тесты, safety-бэкапы); на VPS — NOT TESTED |
| Primary-only legacy bridge | VERIFIED (P0-фикс + негативный тест) |
| ACK ref collision | VERIFIED (P0-фикс + Dart collision-тест) |

## 6. Android v2 release

- applicationId `com.example.shade`, versionCode 2 / versionName 2.0.0
  (pubspec `2.0.0+2`), minSdk 24, targetSdk 36 — подтверждено baseline-аудитом
  и `aapt2 dump badging` собранного APK.
- **ARM64 release APK СОБРАН и ПРОВЕРЕН (17.11.2026 20:19):**
  `artifacts/v2-release/shade-v2-arm64-release.apk` (56 613 412 B).
  `apksigner verify --print-certs`: `CN=Shade Android Release`, SHA-256
  `d790f9763fbc4bb33a87b0d530c5738d9d3aabcaaebb7ef5b67a099745104edf` —
  **ТОЧНО совпадает с v1 эталоном**
  (`artifacts/builds/shade-vps-2026-11-15-arm64.apk`). Debuggable-флаг
  отсутствует. Release v1 → release v2 обновляется поверх (та же подпись,
  versionCode 2 > 1); данные/ключи/сессия сохраняются (схема аддитивная).
- **Универсальный APK + AAB СОБРАНЫ и ПРОВЕРЕНЫ:**
  `shade-v2-universal-release.apk` (96 279 358 B; apksigner: та же подпись,
  versionCode 2) и `shade-v2-release.aab` (83 830 606 B; jarsigner verified,
  keytool: CN=Shade Android Release, тот же SHA-256).
- Release-ключ: `client/android/shade-release.jks` + `key.properties`
  скопированы из основного checkout (gitignored, в Git не попадают).
- Galaxy A31: установлен DEBUG-подписанный APK → release поверх НЕ встанет
  (разные подписи). Пути: B1 (debug поверх debug, данные сохраняются) или
  B2 (осознанная переустановка после enrollment + recovery). Удаление
  приложения с реальными данными без подтверждения/бэкапа НЕ выполнялось.
- Физическая установка release поверх release v1: NOT TESTED.

## 7. Web/PWA

- Направление ZCODE (отдельный worktree). В этом worktree тронут ТОЛЬКО
  `client/web/protocol/device-v2.mjs` (аддитивные rotation-экспорты,
  необходимые серверу; существующие функции не изменены) — зависимость
  сообщена владельцу. `client/web/alpha-ui.mjs` — существовавшее
  незакоммиченное изменение, сохранено без правок.
- CSP strict (`default-src 'self'`, wasm-unsafe-eval, worker-src self blob:),
  SW `alpha-sw.js`, cache-files allowlist, offline — реализованы ранее.
  **Пересборка выполнена 17.11.2026 20:26** из текущего состояния worktree:
  `python client/tools/build_web_alpha.py` → `client/build/web-alpha`
  (37 статических ассетов, Flutter web release, --csp, без CDN).
  Финальное браузерное QA и интеграция с ZCODE — остаются открытыми.
- OAuth credentials в Git не попадали; при отсутствии — инструкция
  `docs/IPHONE_PWA_STAGING.md` §3 (redirect URIs, Console).
- Физический iPhone push: NOT TESTED (не заявляется проверенным).

## 8. Rollout (этапы A–G) и условия остановки

A — Local Validation: **ВЫПОЛНЕН** (этот документ, 82/82 + 134/134).
B — Staging: конфигурация READY; развёртывание BLOCKED (владелец).
C — Real Device QA: NOT TESTED (A31 release-путь, iPhone).
D — Production Canary: только с отдельного разрешения; guard включается
  для проверенного среза; `stop`-флаг доступен.
E — Gradual Rollout: расширение при подтверждённой совместимости.
F — Production v2: api/app переключаются после D/E; v1 остаётся.
G — v1 Retirement: только после подтверждённой сохранности данных и
  решения по немигрируемым аккаунтам (RSA<2048, потерянные ключи).

Feature flags / управляемость: `SHADE_V2_GUARD_FILE` (opt-in, default off),
`SHADE_V2_BRIDGE_ACK_FILE` (opt-in), `migration.stop` (cooperative stop),
`ALPHA_CHECKPOINT_DIR` (durable checkpoints), guard reversibility (~1 с).

Условия остановки rollout: ошибки E2EE; потеря сообщений; нарушение
идентичности аккаунтов; массовые ошибки авторизации; повреждение хранилища;
невозможность безопасного восстановления; неожиданный рост ошибок Socket.IO.
Пороговые значения остальных метрик — по наблюдаемой baseline staging
(очереди: inboxPending не растёт монотонно при активном ACK; bridge prune
lag < 5 с; verify ok; error-rate auth/send < 1% после canary).

## 9. Действия, требующие разрешения владельца

1. ~~SSH-доступ к VPS (ключ) + запуск `production-audit.sh`.~~ **SSH подтверждён
   working (17.11.2026 20:10), read-only аудит выполнен:** Debian 13,
   Node v22.23.5, Caddy 2.6.2, `shade`/`caddy` active, NRestarts=0, диск 22%,
   RAM 902 МБ; данные 448 КБ; ежедневные бэкапы на месте (последний 03:17).
   **Production-пользователи: 4 аккаунта, все RSA-4096, все Google-linked** —
   rotation для текущей базы не требуется; все 4 мигрируемы обычным путём.
   Осталось: разрешение на staging-деплой и миграционные операции.
2. DNS REG.RU: добавить `app`, `alpha`, `staging-api` (§3).
3. Развёртывание staging (этап B) + копия production-данных в staging.
4. Добавление Caddy-блоков staging (alpha) — `caddy validate` + reload.
5. Canary (этап D): guard + bridge-ack в production v1 env, рестарт shade;
   prepare тестовой группы; enrollment на реальных устройствах.
6. Переключение api/app на v2 (этап F) + production Caddy-блоки.
7. Публикация APK/PWA; решение по A31 (debug→release путь).
8. Вывод v1 (этап G) + сценарий RSA<2048/потерянных ключей.
9. Интеграция worktree ZCODE + полная пересборка + повторное E2E.

## 10. Артефакты

1. Android v2 Release APK — `artifacts/v2-release/` (ARM64 + universal + AAB,
   подпись сверена с v1 эталоном).
2. Web/PWA release — после интеграции ZCODE (этап B/C).
3. Staging deployment config — `deploy/alpha/`, `deploy/staging/`.
4. Production deployment procedure — `deploy/production/`, `docs/V2_DEPLOYMENT.md`.
5. Migration tools — `server/tools/migrate-v1-to-v2.mjs` (audit/prepare/status/
   verify/retry/rollback/checkpoint/replay-restore/guard-export/stop/resume).
6. Backup/restore — `deploy/staging/backup-verify.sh`, `migration-run.sh`,
   checkpoints, replay-restore (проверено локально).
7. Rollback — `docs/V2_ROLLBACK.md`, `deploy/staging/rollback-v2.sh`.
8. Release notes — `docs/RELEASE_NOTES_V2.md`.
9. Compatibility report — `docs/V2_COMPATIBILITY_REPORT.md`.
10. Security/test report — `docs/V2_SECURITY_TEST_REPORT.md`.
11. Чек-лист релиза — §11 ниже.

## 11. Итоговый чек-лист релиза

- [x] Worktree/HEAD проверены; незакоммиченные изменения сохранены (бэкап).
- [x] Блокер RSA-2048: rotation реализована + тесты (сервер/клиент).
- [x] Блокер rollback: lossless replay + checkpoints + 6/6 тестов.
- [x] Блокер v1→v2: живой мост + bridge-ack + P0-фиксы + тесты.
- [x] v2→v1: честный peer_upgrade_required + outbox + UI.
- [x] Server 82/82; Flutter 134/134; analyze 0/0/49.
- [x] DNS/HTTPS диагноз установлен (серверная причина, не VPN).
- [x] Staging-конфигурация + dry-run матрица готовы.
- [x] Production-шаблоны (Caddy/systemd/env) подготовлены, НЕ применены.
- [x] Android ARM64 release APK собран + подпись сверена с v1 (совпадает).
- [x] Универсальный APK/AAB собраны, подпись сверена (совпадает).
- [ ] Web/PWA финальная сборка (интеграция ZCODE).
- [ ] Staging развёрнут на VPS (владелец).
- [ ] HTTPS/WSS проверены на доменах (владелец, после Caddy).
- [ ] Real device QA: A31, iPhone (владелец).
- [ ] Canary + gradual rollout (разрешение владельца).
- [ ] Production cutover + v1 retirement (разрешение владельца).

## 12. Нерешённые проблемы

- TLS доменных hostname не работает до добавления Caddy-блоков (владелец).
- `app.shadechat.ru` DNS отсутствует (владелец).
- Apex 95.163.244.138 — отдельный сервер без сертификата shadechat.ru;
  решение о лендинге/редиректах — владелец.
- Обратный мост v2→v1 не реализован (отложен; честное ограничение).
- `read`-receipt bridged v1→v2 не транслируется; wake-push для bridged-очереди
  в PWA — следующий этап.
- Web/PWA rotation и legacy-мост — направление ZCODE, не реализованы здесь.
- Физические устройства (A31 release, iPhone) не тестировались.
- NS/SOA-запросы с этой машины пусты из-за VPN DNS-перехвата (подтверждено
  контрольным тестом на reg.ru); делегирование работает. Полная проверка —
  вне VPN (команды владельцу в §3).
- SSH :22 на 95.163.244.138 не отдал баннер за 5 с (tarpit/не-SSH сервис/
  VPN-путь) — перепроверить в обход VPN; на v2 VPS SSH подтверждён баннером.