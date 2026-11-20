# Переход production v1 → v2: план, карта рисков, GO/NO-GO

Статус: **D1 и D2 утверждены владельцем 20.11.2026 ~18:00** (D1 — когортная
миграция целыми диалогами со всеми устройствами участников, спека
V2_COHORT_MIGRATION.md; D2 — вариант A: полноценный Flutter/Dart UI поверх v2
repository/transport/vault с переиспользованием компонентов). Приоритеты:
1 native entry+сценарии → 2 pairing/approve/recovery → 3 enrollment+локальный
импорт истории → 4 двухустройственный QA/recovery/offline/push → 5 history.transfer/
pruning/backup-restore/rollback-репетиция → 6 production RC и GO/NO-GO.
Дополнительное требование владельца: регрессионные тесты recovery TTL
(rolling-refresh никогда не продлевает recovery-сессию) и проверка аналогичных
путей обновления/отзыва сессий — выполнено (коммит 0dd5304).
Никаких изменений действующего
production v1, реальных данных, DNS, Caddy, systemd, симлинков и клиентских
endpoints не выполнено и не выполняется без отдельного «го» на каждый шаг.
Незавершённые ветки в main не мержатся. Демо-окружение стабильно до защиты 23.11.

## 0. Сверенное состояние (20.11.2026, лично, не по отчётам)

- production v1: `/opt/shade/current` = releases/20261119-144943 (линия
  codex/vinyl-material-redesign, HEAD e67e73f запушен); unit shade active;
  health :3000 ok; админка только через SSH-туннель (Caddy respond @admin 404).
- staging v2: `/opt/shade-staging/current` = releases/20261119-2355,
  MANIFEST commit **092f1fb** (= HEAD pairing-challenge-binding, запушен),
  SW f3431f49c0c28669fa99; включает keyboard/visualViewport/read-ACK фиксы и
  persistent sessions (25ad711), которых не было в моём релизе 170951.
- recovery: ветка recovery-session HEAD **0d1a805** (сервер c6f064e + клиент),
  запушена; suite 152/152 на момент коммита.
- переходная ветка **v2-production** = merge(092f1fb, recovery-session);
  конфликты разрешены вручную (см. §1.3); тесты прогоняются, SHA RC будет ниже.
- main = ceaa1d1, не тронут. Worktree-зоопарк (14 шт.) — чистка после защиты.
- Бэкапы прода: /var/backups/shade/data-predeploy-20261119-144943.tgz + env;
  staging-env и prod-env на месте.

## 1. Целевая архитектура и сохранность идентичности/данных

### 1.1 Топология dual-run
- v1 остаётся на :3000 (unit shade, origin 13-143-207-108.sslip.io) до cutoff.
- v2-production: новый unit `shade-v2`, loopback :3101, **отдельный** data dir
  `/var/lib/shade-v2` и **отдельный storage secret** (создаёт владелец, вне Git);
  origin `https://shadechat.ru` (новый Caddy-блок, добавляется только на шаге
  переключения, после `caddy validate`). alpha.shadechat.ru остаётся
  staging/QA-origin до retirement staging.
- Закрытая бета = allowlist на v2-prod (oauthAllowlist уже есть в alpha.mjs);
  открытая бета — после QA и лимитов.

### 1.2 Сохранность аккаунтов, ключей, истории, сообщений
- **Идентичность не меняется**: legacy-enrollment создаёт genesis с
  `legacy:true`, первое устройство = существующий v1 RSA-ключ (interop проверен
  `alpha_http_interop_test.dart`). Приватный ключ не покидает устройство и не
  перегенерируется. Отпечаток device-ключа continuity проверяется в QA.
- **История**: при enrollment на том же устройстве локальная SQLCipher-история
  перешифровывается в v2-vault ЛОКАЛЬНО (сервер plaintext не видит). Для новых
  устройств — op `history.transfer` (дизайн MULTIDEVICE_SYNC_PLAN §5.2:
  per-device staging ≤64 КиБ, OAEP ключом нового устройства, курсор +
  идемпотентность, БЕЗ учёта в receipts).
- **Сообщения в очередях v1**: мост migration.mjs syncInbox → v2; v1-очередь
  очищается только после подтверждённого коммита в v2 (bridgeAck journal);
  сверка счётчиков до/после; v1 data не prune-ится до cutoff + grace-период.
- **Контакты**: re-pin TOFU в v2 (ключи те же RSA → continuity), ручная сверка
  остаётся; расхождение genesis/root = fail-closed блокировка.
- **Решение D1 (требует согласования)**: двусторонний мост v2→v1 для send в
  dual-run. Закрытая бета вся на v2 → cross-traffic не нужен; публичная миграция
  требует либо двухстороннего моста, либо миграции «разговор целиком» (оба
  участника одновременно) + баннер и cutoff. Рекомендация: закрытая бета без
  cross-traffic, публичная миграция когортами-разговорами.

### 1.3 Разрешение конфликтов merge (v2-production)
- `server/alpha.mjs`: сохранены SESSION_MS=30д/SESSION_REFRESH_LEFT=7д (staging
  persistent sessions) + добавлены recovery-константы (TTL ≤10 мин, ≤5/час).
- `client/web/alpha-ui.mjs`: hostFlutter() переписан на **implicit Flutter view**
  (staging-фикс клавиатуры 743f700) с идемпотентным guard (одна загрузка движка
  на переход recovery→чат); восстановлен watchPeer resume; tail-загрузка
  bootstrap, потерянная автомерджем, возвращена внутрь hostFlutter.
- Проверки после merge: node --check ok; suites прогоняются (результаты в RC).

## 2. Фазы и порядок деплоя (каждый prod-шаг — отдельное «го»)

- **P0 (сейчас → 23.11)**: только изолированные ветки (v2-production: merge
  recovery ✓, native pairing, enrollment-UI, history.transfer, receipts pruning).
  Развёрнутые staging/prod не трогаем; защита на текущем staging.
- **P1 (после защиты)**: RC собран и проверен → бэкап + тест восстановления →
  unit shade-v2 + env (секреты владельца) + Caddy-блок validate → деплой релиза
  v2-prod (npm ci от shade-v2, chown/go+rX уроки) → reload Caddy с новым блоком
  shadechat.ru→v2 (sslip и alpha не меняются) → smoke обоих origins + baseline
  прода → закрытая бета по allowlist.
- **P2**: физические QA (2 устройства) + browser-QA recovery/pairing/enrollment;
  history.transfer + pruning задеплоены; окно enrollment для v1-юзеров (баннер в
  v1-клиенте + дата cutoff).
- **P3**: cutoff: v1 read-only grace (очереди до drained через мост), retirement
  v1 unit/origin отдельным «го»; DNS TTL 300 с заранее; rollback-окно 14 дней с
  сохранением v1 data.

## 3. Бэкапы, тест восстановления, rollback

- Перед каждым prod-шагом: tar data v1 + data v2 + envs + Caddyfile + units →
  `/var/backups/shade-transition/<stamp>/` + **внешняя копия у владельца**
  (секреты не через Git/чат). Контроль: sha256 всех архивов.
- **Тест восстановления (обязателен для GO)**: restore v2-снапшота в изолированный
  каталог с копией storage secret → boot → /api/health + op directory → сверка
  checksum и счётчиков аккаунтов/очередей; результат документирован.
- **Rollback**: симлинк current назад + restart unit + Caddy reload из бэкапа;
  репетиция rollback выполняется на staging до P1 и фиксируется в отчёте.
  Клиенты: PWA origin зашит в сборку/SW → переключение клиентов = новый релиз,
  не DNS-трюки; нативный v1 APK живёт на v1 endpoint до баннера принудительного
  обновления (без тихой смены личности/ключей).

## 4. Карта рисков

| Риск | Вероятн. | Ущерб | Митигация |
| --- | --- | --- | --- |
| Тихая потеря сообщений при мосте v1→v2 | ср | выс | journal + счётчики до/после, no-prune до cutoff, QA-сценарий миграции |
| Смена крипто-идентичности при enrollment | низ | крит | legacy genesis = v1 RSA-ключ; interop-тест; сверка отпечатков в QA |
| Утеря storage secret / бэкапа | низ | крит | внешняя копия у владельца, тест восстановления, fail-closed boot |
| Регресс клавиатуры/UI из merge | ср | ср | implicit-view разрешение конфликта, полный suite + browser-QA |
| Исчерпание receipts-ёмкости | выс | ср | op pruning до открытого enrollment (§5.3 SYNC_PLAN) |
| Lease 24 ч скрывает отзыв устройства | ср | ср | refreshOwn <1 ч; известное ограничение, документировано |
| v1-клиенты остались без сервера после cutoff | ср | ср | dual-run grace + баннер + дата cutoff + rollback-окно |
| DNS/TLS/Caddy misconfig при переключении | низ | выс | caddy validate, объединённый Caddyfile, TTL 300, репетиция rollback |
| XSS/подмена JS на origin | низ | выс | CSP self, без сторонних origin; известное ограничение E2EE-web |
| Дестабилизация демо до 23.11 | ср | выс | P0-заморозка развёрнутых окружений |
| PRF-vault без пути восстановления | ср | выс | recovery merged + QA + предупреждающий UX (уже есть) |
| Нативный at-rest отличается от web (SQLCipher/Keystore без фразы-обёртки) | низ | ср | решение lead 20.11: вариант A (консистентно с v1), честный текст экрана; переносимый vault-экспорт для web — отдельная задача после беты; украденное разблокированное устройство = риск как у v1/Signal |

## 5. Критерии GO/NO-GO (массовое переключение)

GO только при ВСЕХ:
1. Server suite зелёный (включая recovery/pairing/migration/pruning тесты).
2. Flutter suite зелёный + analyze 0 errors/0 warnings.
3. Browser-QA Edge+WebKit: регистрация, E2EE roundtrip, offline-очередь,
   pairing, recovery, enrollment-миграция, read-ACK — PASS оба движка.
4. Физический QA на двух реальных устройствах (A31 + iPhone): чек-лист подписан
   владельцем/тестером (E2EE, offline, pairing, recovery, прочитано, push).
5. Тест восстановления из бэкапа PASS + репетиция rollback PASS (отчёты).
6. RC: точный commit SHA + MANIFEST.sha256/meta без плейсхолдеров + логи тестов.
7. Защита 23.11 проведена; демо-окружение не деградировало.
8. Отдельное явное «го» владельца на каждый prod-шаг §2.
NO-GO триггеры: любая тихая потеря сообщений; перегенерация ключей/личности;
провал restore/rollback теста; красный QA на устройствах; caddy validate fail;
утечка секрета; незакрытый P1-баг.

## 6. Релиз-кандидат

Ветка v2-production; SHA фиксируется после зелёных suites и интеграции native
pairing/enrollment (аудит Android v2 в работе). Состав RC: merge recovery +
native pairing + enrollment-UI + history.transfer + receipts pruning +
миграционные тесты. Артефакты: MANIFEST, логи server/flutter/browser-QA,
чек-лист физического QA, отчёты backup-restore и rollback-репетиции.

## 6.1 Переключение клиентов и applicationId (D3, ожидает решения владельца)
- PWA: origin зашит в сборку/SW; переключение клиентов = новый релиз оболочки,
  не DNS-трюки. Beta-PWA остаётся на alpha.shadechat.ru до cutover; prod-PWA
  (shadechat.ru) поднимается вместе с v2-prod unit и новым Caddy-блоком.
- Натив: v1 APK (com.example.shade) живёт на v1 endpoint до баннера принудительного
  обновления и cutoff. v2 APK для закрытой беты — ОТДЕЛЬНЫЙ applicationId
  (предложение: ru.shadechat.app), чтобы сосуществовать с v1 на одном телефоне
  и не ломать апгрейды v1; ключ подписи у владельца (key.properties).
- Открытая бета/Play: com.example.* Play не примет → финальный applicationId
  утверждается владельцем до публикации; смена id после закрытой беты = потеря
  апгрейд-пути тестеров (документированный trade-off, решаем на cutover).
- DNS: TTL 300 с заранее (48 ч до cutover); Caddy-блок shadechat.ru→v2 добавляется
  только на шаге переключения после caddy validate; sslip и alpha не меняются
  до retirement; rollback = возврат блока из бэкапа + reload.
- Баннер в v1-клиенте: «Диалог перенесён в Shade v2 / обновите приложение» при
  upgrade_required/migration_rolled_back (серверные коды уже есть); тихой
  отправки в несовместимое окружение нет (gate когортной миграции).

## 7. Что можно делать СЕЙЧАС vs что блокирует переключение

СЕЙЧАС (изолированно, без prod): merge recovery ✓; native pairing (Dart);
enrollment-UI натива; history.transfer op + клиенты; receipts pruning;
миграционные/парные тесты; backup-скрипты и restore-тест в изолированном
каталоге; репетиция rollback на staging; browser-QA сценарии; план DNS/Caddy
как файл-проект (без применения).
БЛОКИРУЕТ переключение: отсутствие native pairing/enrollment (аудит уточняет);
непроведённые физические QA и browser-QA recovery; непройденный restore-тест;
незадеплоенный pruning; решение D1 (cross-traffic); отсутствие «го» владельца
на prod-шаги; защита 23.11 (до неё prod-шаги запрещены этим планом).