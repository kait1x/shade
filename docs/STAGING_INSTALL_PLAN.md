# Staging install plan — systemd + Caddy (ожидает отдельного разрешения)

Дата: 17.11.2026. Состояние ДО установки: staging-процесс alpha уже запущен
как пользовательский процесс `shade-staging` на **127.0.0.1:3101** (не systemd),
синтетический мост настроен, smoke 11/11 + packaged tests 11/11 PASS на VPS.
Production v1 не затронут. Root-ключ не использовался на этом этапе.

Пакет: `/opt/shade-staging/releases/20261117-213644/`, commit
`02569bbcced7787b4c3a6206f3900e8271d36a9e` (ветка `v2-staging-release`),
MANIFEST 134/134 verified. ZCODE PWA-оптимизации НЕ интегрированы.

## 0. Текущий процесс (остановить перед systemd)

```bash
# от shade-staging:
kill $(cat /var/lib/shade-staging/alpha.pid)
# проверка:
curl -s -m 3 http://127.0.0.1:3101/api/health || echo "stopped"
```

## 1. Symlink current (от shade-staging, без root)

```bash
ln -sfn /opt/shade-staging/releases/20261117-213644 /opt/shade-staging/current
readlink -f /opt/shade-staging/current   # проверка
```
Откат: `ln -sfn <предыдущий release> /opt/shade-staging/current`.

## 2. systemd-юнит (root; ОТДЕЛЬНОЕ разрешение владельца)

Файл `/etc/systemd/system/shade-staging.service` (точное содержимое):

```ini
[Unit]
Description=Shade v2 isolated staging (device protocol)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=shade-staging
Group=shade-staging
WorkingDirectory=/opt/shade-staging/current/server
EnvironmentFile=/var/lib/shade-staging/staging.env
ExecStart=/opt/node/bin/node alpha.mjs
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/shade-staging

[Install]
WantedBy=multi-user.target
```

Отличия от раннего шаблона: `ExecStart=/opt/node/bin/node` (node установлен
в /opt/node, не /usr/bin), `EnvironmentFile=/var/lib/shade-staging/staging.env`
(секреты созданы там от shade-staging; /etc/shade-staging root-owned 750).

Команды установки и проверки:
```bash
install -m 644 shade-staging.service /etc/systemd/system/shade-staging.service
systemctl daemon-reload
systemctl enable --now shade-staging
systemctl status shade-staging --no-pager        # active (running)
systemctl show shade-staging -p NRestarts -p MemoryCurrent
curl -fsS -m 5 http://127.0.0.1:3101/api/health  # {"protocol":2,"isolated":true,...}
journalctl -u shade-staging -n 20 --no-pager     # без ошибок
ss -tlnp | grep 3101                             # loopback, user shade-staging
```

Откат systemd:
```bash
systemctl disable --now shade-staging
rm /etc/systemd/system/shade-staging.service
systemctl daemon-reload
# при необходимости вернуть пользовательский процесс:
# от shade-staging: cd /opt/shade-staging/current/server; set -a; . /var/lib/shade-staging/staging.env; set +a
# nohup /opt/node/bin/node alpha.mjs > /var/lib/shade-staging/alpha.log 2>&1 & echo $! > /var/lib/shade-staging/alpha.pid
```

## 3. DNS (владелец, REG.RU)

| Тип | Имя | Значение | TTL |
|---|---|---|---|
| A | `alpha` | `13.143.207.108` | 3600 |

Проверка: `Resolve-DnsName alpha.shadechat.ru -Type A -Server 1.1.1.1`.
Без записи Let's Encrypt не выдаст сертификат (HTTP-01).

## 4. ALPHA_PUBLIC_ORIGIN (от shade-staging, до Caddy)

```bash
sed -i 's#^ALPHA_PUBLIC_ORIGIN=.*#ALPHA_PUBLIC_ORIGIN=https://alpha.shadechat.ru#' /var/lib/shade-staging/staging.env
systemctl restart shade-staging   # после установки юнита
curl -fsS -m 5 http://127.0.0.1:3101/api/health
```
Внимание: после смены origin браузерные запросы с `http://127.0.0.1:3101`
будут отклоняться (origin_rejected) — smoke-скрипты обновить на доменный
origin либо запускать с Origin-заголовком https://alpha.shadechat.ru.
Откат: вернуть `ALPHA_PUBLIC_ORIGIN=http://127.0.0.1:3101` + restart.

## 5. Caddy: добавление alpha-блока (root; ОТДЕЛЬНОЕ разрешение владельца)

**Только ДОБАВЛЕНИЕ** к `/etc/caddy/Caddyfile`; существующий sslip-блок
сохраняется дословно. Блок (из `deploy/staging/Caddyfile.staging.example`):

```caddyfile
alpha.shadechat.ru {
	encode gzip
	request_body {
		max_size 12MB
	}
	@admin path /admin* /dashboard* /logs /api/stats /api/dashboard-stats
	respond @admin 404
	reverse_proxy 127.0.0.1:3101 {
		header_up X-Forwarded-For {remote_host}
	}
	log {
		output file /var/log/caddy/shade-staging-access.log {
			mode 0600
			roll_size 10MiB
			roll_keep 5
		}
		format filter {
			wrap json
			fields {
				request>headers>X-Session-Token delete
				request>headers>Authorization delete
				request>headers>X-Username delete
				request>headers>Cookie delete
			}
		}
	}
}
```

Команды (backup → append → validate → reload):
```bash
STAMP=$(date +%Y%m%d-%H%M%S)
cp -a /etc/caddy/Caddyfile /var/backups/shade/Caddyfile-staging-$STAMP
cat alpha-block.caddyfile >> /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile   # ОБЯЗАТЕЛЬНО до reload
systemctl reload caddy
```

Проверка HTTPS/WSS:
```bash
curl -fsS -m 10 https://alpha.shadechat.ru/api/health
curl -sI -m 10 https://alpha.shadechat.ru/ | grep -iE 'content-security-policy|x-content-type'
curl -s -m 10 'https://alpha.shadechat.ru/socket.io/?EIO=4&transport=polling' | head -c 120   # ожидается 0{"sid"...}
curl -s -o /dev/null -w '%{http_code}\n' -m 10 https://alpha.shadechat.ru/admin   # 404
echo | openssl s_client -connect alpha.shadechat.ru:443 -servername alpha.shadechat.ru 2>/dev/null | openssl x509 -noout -subject -issuer -dates
# production не затронут:
curl -fsS -m 10 https://13-143-207-108.sslip.io/api/health
systemctl is-active shade caddy
```

Откат Caddy:
```bash
cp -a /var/backups/shade/Caddyfile-staging-$STAMP /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
```

## 6. OAuth (владелец, Google Console) — до подключения реальных людей

Отдельный OAuth Web-клиент для `https://alpha.shadechat.ru` (authorized
JavaScript origin + redirect URI `https://alpha.shadechat.ru/auth/google/callback`).
Заполнить `ALPHA_GOOGLE_CLIENT_ID/SECRET` в staging.env (новые, не production).
**До этого Google-вход отключён; staging использует только синтетические
аккаунты и legacy-key вход. Реальных пользователей не подключать.**

## 7. Условия остановки / отката всего staging

- Любая ошибка E2EE/потеря сообщений в синтетических тестах → стоп, разбор.
- Рост NRestarts, ошибки в journalctl, недоступность health → стоп.
- Полный откат: шаги 5→2→0 в обратном порядке; данные staging изолированы
  в /var/lib/shade-staging и не влияют на production.
- Production v1 (`shade.service`, sslip-блок, /var/lib/shade) НЕ затрагивается
  ни на одном шаге; guard в production НЕ включается.

## 8. Что уже проверено на VPS (без systemd/Caddy)

- npm ci 246 пакетов; node --check alpha/server/CLI; MANIFEST 134/134 (commit-bound).
- Новые staging-секреты (0600), VAPID сгенерирован на сервере; production-секреты не использовались.
- Live smoke 11/11: health/legacyBridge, CSP, admin-404, socket.io polling,
  cross-origin-403, legacy-key session, enrollment rev1, bridged ciphertext
  (расшифровка только старым ключом), legacy.ack + bridge-ack export,
  staging guard export, дедуп acked.
- Packaged integration tests 11/11: migration-dryrun (3), rsa-rotation (2),
  rollback-journal (6).
- **Пре-валидация без установки (17.11.2026 21:51):**
  `systemd-analyze verify /opt/shade-staging/shade-staging.service` — без
  ошибок; `caddy validate --config /opt/shade-staging/Caddyfile.staging-block
  --adapter caddyfile` — **Valid configuration** (отдельный файл, production
  Caddyfile не затрагивался). Symlink `/opt/shade-staging/current` →
  `releases/20261117-213644` создан (шаг 1 выполнен). Процесс стабилен:
  RSS ~100 МБ, ошибок в alpha.log нет.