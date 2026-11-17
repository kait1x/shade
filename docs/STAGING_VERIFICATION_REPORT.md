# Staging verification report — https://alpha.shadechat.ru (17.11.2026 22:40 MSK)

Админ-скрипт выполнен владельцем (`ADMIN_SETUP_DONE stamp=20261117-222630`):
`shade-staging.service` active, Caddy alpha-блок добавлен (backup
`/var/backups/shade/Caddyfile-staging-20261117-222630`), origin переключён.
Production v1 не изменён (подтверждено ниже). Google OAuth отключён по
решению владельца.

## 1. HTTPS и сертификат — PASS
- `GET https://alpha.shadechat.ru/api/health` → 200
  `{"service":"shade-web-alpha","protocol":2,"isolated":true,"legacyBridge":true}`.
- Сертификат: CN=`alpha.shadechat.ru`, SAN=[alpha.shadechat.ru],
  issuer Let's Encrypt (YE1), действителен до **15.02.2027**, TLS **1.3**.
- Заголовки: strict CSP (`default-src 'self'`…), HSTS max-age=31536000,
  X-Content-Type-Options nosniff, Referrer-Policy no-referrer,
  Permissions-Policy camera/mic/geo=().

## 2. WSS / Socket.IO — PASS
- Raw TLS websocket upgrade `GET /socket.io/?EIO=4&transport=websocket`
  → **101 Switching Protocols**, engine.io open-пакет с sid.
- Polling probe → sid (доменный smoke). Alt-Svc h3 присутствует.

## 3. Service Worker и PWA — PASS (оболочка) / находки (Flutter UI)
- Корень `/` (alpha.html + alpha-ui.mjs, WebCrypto-клиент): **0 ошибок
  консоли**; SW `alpha-sw.js` active, scope `/`, controller активен;
  кеш `shade-alpha-flutter-dd06e1c7b6c76b12cc73` — **52 записи** (allowlist).
- Манифест `alpha-manifest.json`: name Shade, display standalone, icons
  192/512/maskable, start_url/scope `/`, theme #000000.
- Кнопка «Установить Shade» + beforeinstallprompt handler + Safari-инструкция.
- Честное уведомление «Google OAuth ещё не настроен администратором» ✓.
- Скриншот: `shade-staging-pwa-landing.png` (Playwright output).

### Находки Flutter UI (`/flutter-ui/index.html`)
1. UI рендерится (CanvasKit, главный экран, поиск, профиль), но:
   - **fast_rsa worker 404**: `assets/packages/fast_rsa/web/assets/worker.js`
     отсутствует; пакет fast_rsa 3.8.6 **не имеет web-платформы** (только
     android/ios/linux/macos/windows). Flutter-приложение на web не может
     выполнять RSA-операции через fast_rsa → **E2EE Flutter-web пути не
     готов**. Рабочий web-клиент — JS-оболочка (WebCrypto, device_crypto.mjs).
     Решение — в интеграции ZCODE (PWA parity).
   - **base-uri CSP conflict**: серверный CSP `base-uri 'none'` блокирует
     `<base href="/flutter-ui/">` из index.html (ассеты всё равно грузятся —
     путь совпадает). Косметика; исправить в интеграции (base-uri 'self'
     либо убрать base-тег).
   - **GSI script blocked**: main.dart.js пытается загрузить
     `accounts.google.com/gsi/client` при отключённом OAuth → CSP-блокировка
     + ошибка в Dart-стеке. Клиент должен пропускать GSI-инициализацию без
     конфигурации (ZCODE).
   - `/flutter-ui/` → 404 by design (`index: false`); вход —
     `/flutter-ui/index.html`.
   - Текст «Переписка в Web Beta пока недоступна» в index.html устарел
     (шаблон client/web/index.html, зона ZCODE).
2. JS-оболочка без OAuth не имеет способа входа (legacy-key вход реализован
   только в Android-клиенте). Для закрытого web-тестирования нужен либо
   OAuth-клиент staging, либо legacy-вход в оболочке (ZCODE).

## 4. Доменный smoke на синтетике — 12/12 PASS
`staging-live-smoke.mjs enroll https://alpha.shadechat.ru` (на VPS):
health+legacyBridge · CSP · admin-404 · socket.io polling · cross-origin-403 ·
legacy-key сессия · **cookie flags (__Host-, Secure, HttpOnly, SameSite=Lax)** ·
**свежий legacy-enrollment через HTTPS (rev 1)** · подписанный fetch ·
дедуп acked bridged-сообщения · bridge-ack export · staging guard export.
Ранее (loopback этап): bridged v1-ciphertext расшифрован только старым
ключом, сервер plaintext не видел; packaged integration tests 11/11 на VPS;
backup/rollback drill end-to-end.

## 5. Безопасность и изоляция — PASS
- `shade-staging.service`: User/Group=shade-staging, ProtectSystem=strict,
  ProtectHome=yes, NoNewPrivileges=yes, PrivateTmp=yes,
  ReadWritePaths=/var/lib/shade-staging, NRestarts=0, ~62 МБ.
- :3101 слушает **только 127.0.0.1**; публично — только через Caddy alpha-блок.
- staging.env 0600 shade-staging; production-секреты не использовались.
- `/var/lib/shade/data` недоступен shade-staging (Permission denied) ✓.
- Admin-поверхности (/admin, /dashboard, /api/stats) → 404 ✓.
- Cross-origin запросы → 403 origin_rejected ✓.
- **Production не изменён**: shade/caddy active, v1 `/api/health` 200
  (loopback и sslip.io), sslip-блок в Caddyfile сохранён.
- Минорное замечание: каталог `/var/lib/shade-staging/data` был 775 —
  ужесточён до 700 (файлы снапшота всегда 0600).

## 6. Итог

**Staging готов к закрытому тестированию протокола и Android-клиента.**
Рабочий URL: **https://alpha.shadechat.ru** (PWA-оболочка),
https://alpha.shadechat.ru/flutter-ui/index.html (Flutter UI, web-crypto
ограничен — см. находки). Web-переписка требует OAuth staging-клиента или
legacy-входа в оболочке (зона ZCODE). Реальные пользователи к синтетическому
staging не подключались.

Следующий этап (разрешён владельцем): интеграция финальной PWA ZCODE в
отдельном worktree, пересборка, повторные проверки, подготовка Galaxy A31.