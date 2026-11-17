# Shade PWA на iPhone: staging-развёртывание и установка

Статус: подготовка выполнена в ветке `integration-android-pwa`; публичный
deployment НЕ выполнялся и требует отдельного разрешения владельца.
Production Android v1 на VPS не затрагивается: alpha — отдельный процесс,
порт, каталог данных, OAuth-клиент и hostname.

## 1. Архитектура изоляции

| Компонент | Production v1 | Alpha/staging |
|---|---|---|
| Процесс | `server.js` (shade.service) | `alpha.mjs` (shade-alpha.service) |
| Порт | существующий | 3101 (loopback) |
| Данные | существующий каталог | `/var/lib/shade-alpha/data` |
| OAuth | существующий клиент | отдельный Web-клиент alpha |
| Hostname | существующий домен | новый, напр. `alpha.<домен>` |
| Секреты | не трогаем | новый `ALPHA_STORAGE_SECRET`, новые VAPID |

`alpha.mjs` refusing start без `SHADE_ENV=alpha`; слушает только 127.0.0.1;
TLS терминирует Caddy. Production Caddyfile не заменяется — добавляется
отдельный блок.

## 2. Действия владельца (DNS/HTTPS/VPS)

1. Купить/выбрать домен (если ещё нет) и создать A-запись
   `alpha.<домен>` → IP VPS. Дождаться распространения DNS.
2. На VPS открыть 80/443 (если закрыты) — Caddy сам получит Let's Encrypt
   сертификат для нового hostname. HTTP-01 challenge требует доступности 80.
3. Создать пользователя и каталоги (один раз):
   ```bash
   sudo useradd --system --home /opt/shade-alpha --shell /usr/sbin/nologin shade-alpha
   sudo mkdir -p /opt/shade-alpha/current /var/lib/shade-alpha/data /etc/shade-alpha
   sudo chown shade-alpha:shade-alpha /var/lib/shade-alpha/data
   sudo chmod 750 /var/lib/shade-alpha/data
   ```
4. Скопировать сборку (из интеграционного worktree, после команды владельца):
   ```bash
   # на машине сборки: npm ci в server/, python client/tools/build_web_alpha.py
   rsync -a --delete server/ shade-alpha@VPS:/opt/shade-alpha/current/server/
   rsync -a --delete client/web/ shade-alpha@VPS:/opt/shade-alpha/current/client/web/
   rsync -a --delete client/build/web-alpha/ shade-alpha@VPS:/opt/shade-alpha/current/client/build/web-alpha/
   ```
   Альтернатива: git-клон ветки на VPS + `npm ci --omit=dev` + сборка Flutter
   на машине сборки (Flutter на VPS не обязателен).
5. Заполнить `/etc/shade-alpha/alpha.env` по `deploy/alpha/.env.example`:
   ```bash
   openssl rand -hex 32                      # ALPHA_STORAGE_SECRET
   npx web-push generate-vapid-keys          # ALPHA_VAPID_PUBLIC_KEY/PRIVATE_KEY
   ```
   `ALPHA_PUBLIC_ORIGIN=https://alpha.<домен>` — точное совпадение с адресом
   в Safari (иначе Origin-проверка отклонит вход).
   ```bash
   sudo chown root:shade-alpha /etc/shade-alpha/alpha.env
   sudo chmod 640 /etc/shade-alpha/alpha.env
   ```
6. Caddy: добавить блок из `deploy/alpha/Caddyfile.example` с реальным
   hostname в существующий Caddyfile (не заменять его), `sudo systemctl reload caddy`.
7. systemd: скопировать `deploy/alpha/shade-alpha.service.example` в
   `/etc/systemd/system/shade-alpha.service`, затем:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now shade-alpha
   systemctl status shade-alpha
   curl -s https://alpha.<домен>/api/health   # {"service":"shade-web-alpha","protocol":2,...}
   ```

## 3. Google OAuth Console (точные настройки)

Отдельный проект или отдельные клиенты в существующем — на усмотрение
владельца; production-клиенты не менять.

1. APIs & Services → OAuth consent screen: External, название Shade,
   support email; scopes: `openid`, `email`, `profile` (базовые, без
   чувствительных). Добавить тестовых пользователей на время Testing.
2. Credentials → Create Credentials → OAuth client ID → **Web application**
   («Shade Alpha Web»):
   - Authorized JavaScript origins: `https://alpha.<домен>`
   - Authorized redirect URIs: `https://alpha.<домен>/auth/google/callback`
   - Client ID → `ALPHA_GOOGLE_CLIENT_ID`, Client secret →
     `ALPHA_GOOGLE_CLIENT_SECRET` в alpha.env.
3. Для Android v2 (native ID token): Create Credentials → OAuth client ID →
   **Android**: package name приложения (из `client/android/app/build.gradle*`,
   applicationId), SHA-1 подписи debug/release keystore
   (`keytool -list -v -keystore <keystore>`). Отдельный client ID не нужен
   для serverClientId — используется Web client ID выше; Android-клиент
   нужен для авторизации самого приложения.
4. Client ID для Flutter-сборки Android передаётся при сборке:
   `--dart-define=ALPHA_GOOGLE_CLIENT_ID=<Web client ID>`.
5. Реальные credentials не коммитить и не пересылать в чат/логи.

Без этих настроек вход вернёт честную ошибку `google_not_configured`;
синтетический QA не сертифицирует реальный Google.

## 4. Установка на iPhone (после развёртывания)

1. iPhone: iOS 16.4+ (Web Push требует 16.4+; чат работает и на более старых).
2. Safari → `https://alpha.<домен>` → дождаться загрузки.
3. Поделиться (квадрат со стрелкой) → **«На экран Домой»** → имя Shade →
   Добавить. Запускать именно с экрана Домой (standalone): так работают
   push и полный viewport; в обычной вкладке Safari push недоступен.
4. Открыть Shade с экрана Домой → «Войти через Google» → выбрать аккаунт.
5. Создать ключи устройства: две разные сильные фразы (устройство + recovery).
   **Скачать recovery-пакет и сохранить фразу вне телефона** — без них
   потеря устройства/данных сайта = потеря идентичности.
6. Обмен отпечатками с собеседником через независимый канал (Профиль →
   Ключ шифрования) и закрепление контакта.
7. Push (опционально): Профиль → Уведомления → разрешить. Уведомление —
   только сигнал «Новое сообщение», без текста; расшифровка после входа.
8. Не очищать данные сайта Safari без recovery-пакета.

## 5. Подключение Android к тестовому backend

Экран «Устройства (v2)» в Android-сборке: поле origin =
`https://alpha.<домен>`, вход через Google (сборка с
`--dart-define=ALPHA_GOOGLE_CLIENT_ID=<Web client ID>`), enrollment,
закрепление отпечатка PWA-собеседника. Далее текст/фото/подарки/Избранное.

## 6. Вариант без покупки домена (быстрый тест)

iPhone требует доверенный HTTPS; самоподписанный сертификат на LAN-IP не
подойдёт без установки профиля. Рабочие варианты:
- **Tailscale Serve/Funnel**: `tailscale serve --bg --https=443 http://127.0.0.1:3101`
  (сертификат `*.ts.net` доверенный; Funnel публикует наружу — только с
  разрешения владельца). `ALPHA_PUBLIC_ORIGIN=https://<host>.<tailnet>.ts.net`.
- **Cloudflare Tunnel**: `cloudflared tunnel --url http://127.0.0.1:3101`
  (временный `*.trycloudflare.com` HTTPS; Origin включить в OAuth-клиент).
- Реальный домен + Caddy (раздел 2) — постоянный вариант.
Во всех случаях OAuth redirect/origin должны точно совпадать с публичным URL.

## 7. Проверки перед реальными пользователями

- Физический iPhone: `docs/PHYSICAL_DEVICE_TEST_PLAN.md` (S1–S5, включая
  abrupt kill Safari и сохранность ключей; WebKit-эмуляция НЕ заменяет).
- Android ↔ PWA на синтетических аккаунтах: текст, фото, подарки, Избранное,
  read-ACK, retract, offline/reconnect, второе устройство и отзыв.
- Остаточные риски WebKit (асинхронный flush IDB/localStorage) документированы
  в `docs/INTEGRATION_REPORT.md` §6; клиентские механизмы (журнал удалений,
  re-commit, pagehide-refresh) минимизируют, но не гарантируют fsync.