# Shade v2: развёртывание и подключение домена

Статус: подготовлено локально; **публичный deployment НЕ выполнялся**.
Production v1 не затрагивается. Все действия на VPS требуют отдельного
разрешения владельца и доступного SSH.

Проверено 17.11.2026 с рабочей машины + внешними узлами check-host.net:
- DNS A согласованы на 1.1.1.1/8.8.8.8/ns1.reg.ru/ns2.reg.ru:
  `@`/`www` → `95.163.244.138`, `api` → `13.143.207.108`.
  **`app.shadechat.ru` — записи НЕТ (NXDOMAIN).** Прежний вывод «NXDOMAIN
  для всех» устарел: записи @/www/api созданы владельцем после той проверки.
- VPS `13.143.207.108` **ЖИВ**: TCP 22/80/443 открыты; SSH banner
  `OpenSSH_10.0p2 Debian 13`; HTTP :80 → 308 (Caddy); TLS для
  `13-143-207-108.sslip.io` → **200 OK из внешних узлов** (Iran/Iceland).
- **TLS `api.shadechat.ru` → `tlsv1 alert internal error` из внешних узлов
  (BG/RO/SE); `shadechat.ru` (95.163.244.138) → `handshake failure` (RU/US).
  Причина СЕРВЕРНАЯ: в Caddyfile нет site-блока для SNI api.shadechat.ru
  (сертификата нет). НЕ VPN, НЕ DNS, НЕ клиентский Schannel (контроль:
  TLS к 1.1.1.1 с этой машины работает).** Исправление — добавить блоки
  `deploy/production/Caddyfile.example` (с разрешения владельца).
- Apex `95.163.244.138` — отдельный сервер (HTTP 200 с Host shadechat.ru),
  не VPS v2; сертификата shadechat.ru там нет. Решение о лендинге — владелец.
- Действующий production v1 обслуживает hostname `13-143-207-108.sslip.io`
  (см. `deploy/vps/README.md`), порт 3000 за Caddy — подтверждено 200 OK.

## 1. DNS в REG.RU (точные записи)

Личный кабинет REG.RU → Домены → `shadechat.ru` → «Управление DNS» (NS должны
быть `ns1.reg.ru`/`ns2.reg.ru`; если домен делегирован другому DNS — записи
создаются там). Удалить конфликтующие CNAME/парковочные записи для этих имён.

**Уже существуют (проверено 17.11.2026, не менять вслепую):** `@` и `www` →
`95.163.244.138`, `api` → `13.143.207.108`. **Добавить:**

| Тип | Имя | Значение | TTL |
|---|---|---|---|
| A | `app` | `13.143.207.108` | 3600 |
| A | `alpha` | `13.143.207.108` | 3600 |
| A | `staging-api` | `13.143.207.108` | 3600 |

Назначение:
- `api.shadechat.ru` — будущий production API v2 (Android). **Не переключать**,
  пока v2 не проверен на staging и тестовых пользователях.
- `app.shadechat.ru` — будущая production PWA.
- `alpha.shadechat.ru` — изолированный staging v2 (PWA + API + WSS на одном
  origin; требование `ALPHA_PUBLIC_ORIGIN`).
- `staging-api.shadechat.ru` — зарезервирован для отдельного staging API при
  необходимости; сейчас не используется.

Проверка после распространения (до 24 ч, обычно минуты):
```powershell
Resolve-DnsName alpha.shadechat.ru -Type A
```
Если домен не зарегистрирован/не делегирован — сначала восстановить делегирование
в REG.RU; покупка сторонних услуг не требуется.

## 2. Staging v2 (изолированно от production)

Архитектура изоляции — `docs/IPHONE_PWA_STAGING.md` §1. Отдельный процесс
`alpha.mjs` (порт 3101, loopback), отдельные данные/секреты/OAuth Web-клиент.
Production `shade.service` и его Caddy-блок не меняются.

**Два комплекта (согласовать перед развёртыванием):**
- **`shade-staging` (запрос владельца 17.11.2026, SSH-доступ агента):**
  `deploy/staging/setup-staging.sh` (root, идемпотентно: пользователь без
  sudo/каталоги/SSH-ключ/env-шаблон/юнит БЕЗ включения + проверка изоляции),
  `shade-staging.service.example`, `staging.env.example`,
  `Caddyfile.staging.example`, `smoke-staging.sh` (read-only smoke).
  Пути: `/opt/shade-staging`, `/var/lib/shade-staging`, `/etc/shade-staging`.
  SSH-ключ агента: `~/.ssh/id_ed25519_shade_staging` (публичный передан
  владельцу; доступ ожидается).
- **`shade-alpha` (более ранний автоматизированный вариант, другая сессия):**
  `deploy/staging/staging-deploy.sh <upload-dir>` (идемпотентен, бэкапит
  Caddyfile, validate перед reload, health-check; состав upload в шапке) +
  `deploy/alpha/shade-alpha.service.example` + `deploy/alpha/.env.example`.
  System-пользователь `shade-alpha` (nologin, без SSH).
- **Не разворачивать оба одновременно.** Рекомендация: унифицировать на
  `shade-staging` (явный запрос владельца); адаптация `staging-deploy.sh`
  под это именование — после подтверждения владельца, чтобы не конфликтовать
  с параллельной сессией.

`Caddyfile.stage1` (предложение другой сессии, требует разрешения владельца):
сохраняет sslip-блок дословно + **api.shadechat.ru → ТЕКУЩИЙ v1 backend :3000**
(валидный Let's Encrypt сертификат для api-домена БЕЗ переключения трафика на
v2) + alpha.shadechat.ru → staging :3101. Это безопасный промежуточный шаг,
устраняющий установленный TLS-дефект api-домена; применять только с
разрешения владельца (production Caddy change).

Шаги (выполняет владелец или агент с явного разрешения). Автоматизированный
вариант: `deploy/staging/staging-deploy.sh <upload-dir>` (идемпотентен,
бэкапит Caddyfile, validate перед reload, health-check; состав upload описан
в шапке скрипта). Ручной вариант:
1. DNS-запись `alpha` из таблицы выше.
2. На VPS создать пользователя/каталоги (команды в `docs/IPHONE_PWA_STAGING.md` §2.3).
3. Сборка на рабочей машине:
   ```powershell
   cd server; npm ci
   cd ../client; python tools/build_web_alpha.py   # Web/PWA сборка
   ```
4. Загрузить `server/`, `client/web/`, `client/build/web-alpha/` в
   `/opt/shade-alpha/current/` (rsync/scp; `.env`, сертификаты и локальные
   тестовые базы не включать).
5. Заполнить `/etc/shade-alpha/alpha.env` по `deploy/alpha/.env.example`
   (новые секреты: `openssl rand -hex 32`, `npx web-push generate-vapid-keys`).
   `ALPHA_PUBLIC_ORIGIN=https://alpha.shadechat.ru`.
6. Caddy: **добавить** блок `deploy/staging/Caddyfile.example` в существующий
   `/etc/caddy/Caddyfile` (не заменять файл), затем:
   ```bash
   caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
   systemctl reload caddy
   ```
   Let's Encrypt выдаст сертификат автоматически (HTTP-01, порт 80 должен быть
   доступен извне).
7. systemd: `deploy/alpha/shade-alpha.service.example` →
   `/etc/systemd/system/shade-alpha.service`, `daemon-reload`, `enable --now`.
8. Проверка: `curl -s https://alpha.shadechat.ru/api/health` →
   `{"service":"shade-web-alpha","protocol":2,...}`.
9. Google OAuth Console — отдельный Web-клиент для origin
   `https://alpha.shadechat.ru` (точные шаги: `docs/IPHONE_PWA_STAGING.md` §3).

## 3. Миграционный мост на staging

1. Сделать **копию** production-хранилища для staging (только с разрешения
   владельца; копия содержит зашифрованные данные, обращаться как с секретом):
   ```bash
   tar -czf /var/backups/shade/data-for-staging.tgz -C /var/lib/shade data
   install -d -m 700 /var/lib/shade-alpha/v1-copy
   tar -xzf /var/backups/shade/data-for-staging.tgz -C /var/lib/shade-alpha/v1-copy --strip-components=1
   chown -R shade-alpha:shade-alpha /var/lib/shade-alpha/v1-copy
   ```
2. В `alpha.env`: `ALPHA_V1_DATA_DIR=/var/lib/shade-alpha/v1-copy`,
   `ALPHA_V2_GUARD_FILE=/var/lib/shade-alpha/v2-migration-guard.json`,
   `ALPHA_V2_BRIDGE_ACK_FILE=/var/lib/shade-alpha/v2-bridge-ack.json`,
   `ALPHA_CHECKPOINT_DIR=/var/lib/shade-alpha/checkpoints` (lossless rollback).
   Для v1-копии сервера: `SHADE_V2_GUARD_FILE` и `SHADE_V2_BRIDGE_ACK_FILE`
   указывают на те же экспорты (v1 подрезает подтверждённую очередь и
   показывает отправителям честные delivered/read).
3. Подготовить аккаунты (CLI пишет только в v2-хранилище):
   ```bash
   export ALPHA_STORAGE_SECRET=...   # из alpha.env, не коммитить
   node tools/migrate-v1-to-v2.mjs audit --source /var/lib/shade-alpha/v1-copy
   node tools/migrate-v1-to-v2.mjs prepare --source /var/lib/shade-alpha/v1-copy \
     --target /var/lib/shade-alpha/data --accounts test_user1,test_user2
   node tools/migrate-v1-to-v2.mjs verify --source ... --target ...
   ```
4. Перезапустить `shade-alpha`. Тестовые пользователи входят на
   `https://alpha.shadechat.ru` (Google — если привязан в v1; иначе вход по
   владению исходным RSA в Android-клиенте) и выполняют enrollment.
5. Guard для v1-копии: `guard-export --out /var/lib/shade-alpha/v1-copy/v2-migration-guard.json`,
   затем запустить **копию** v1-сервера на loopback-порту с
   `DATA_DIR=/var/lib/shade-alpha/v1-copy` и `SHADE_V2_GUARD_FILE=...` и
   проверить `upgrade_required`. Production v1 не трогать.

Обёртка с контрольными точками и бэкапами: `deploy/staging/migration-run.sh`
(для production требует `MIGRATION_OWNER_APPROVAL=yes`).

## 4. Production-переход (только после разрешения владельца)

Предпочтительный порядок — `docs/V1_TO_V2_MIGRATION.md` §6 (этапы 1–6) и
`docs/V2_FINAL_RELEASE.md` (этапы A–G). Ключевые ограничения:
- Промежуточный шаг (stage 1): `deploy/staging/Caddyfile.stage1` добавляет
  `alpha` (staging v2) и `api` → **текущий v1** (сертификат для домена без
  переключения трафика). Применение — с разрешения владельца.
- Cutover (stage 2): `deploy/production/Caddyfile.example` + отдельная служба
  `shade-v2` (порт 3201, `deploy/production/shade-v2.service.example`,
  env `deploy/production/v2.env.example` с `ALPHA_ALLOWED_ORIGINS`).
  `api`/`app` направляются на v2 только после этапов B–D.
- Guard в production v1 включается добавлением `SHADE_V2_GUARD_FILE=...` и
  `SHADE_V2_BRIDGE_ACK_FILE=...` в `/etc/shade/shade.env` и рестартом `shade`
  **после** проверки на staging. Без этих переменных поведение v1 не меняется.
- Резервные копии: `deploy/vps/shade-backup.sh` (ежедневно 03:17) +
  `data-premigration-*` перед каждым prepare + rolling checkpoints v2;
  проверка восстановления — `deploy/staging/backup-verify.sh`. Копии на том
  же SSD — внешний backup согласовать отдельно.

## 5. Что НЕ сделано и почему

- Реальный deployment на VPS не выполнялся: требуется отдельное разрешение
  владельца (создание служб, merge Caddy-блоков). SSH-доступ и здоровье
  production подтверждены read-only аудитом; скрипты готовы к запуску.
- DNS не изменялся: доступ к панели REG.RU только у владельца (нужны `app`,
  `alpha`).
- Production OAuth, физический iPhone, реальные устройства: не проверялись.