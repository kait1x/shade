# Shade Web Alpha 0.1

Реализован отдельный HTTP/Socket.IO transport и браузерный интерфейс над
существующими `device_crypto.mjs`, `device-v2.mjs` и `registry.mjs`.
Это кандидат закрытой альфы, **не подтверждённый публичный релиз**.
Вход через настоящий Google и переписку физических iPhone/Android ещё необходимо
проверить на отдельном HTTPS origin. Тестовый OAuth-провайдер существует только
в `server/test/helpers`; в запускаемом сервере нет тестового входа.

## Что запускается

- `server/alpha.mjs`: отдельный процесс, по умолчанию loopback:3101.
- `/`: `client/web/alpha.html`, вход и разблокировка прежней Alpha; после входа —
  Flutter UI из `client/lib/main_alpha.dart`. JS/WebCrypto-клиент остаётся владельцем
  ключей, encrypted storage, очереди, транспорта и ACK. Flutter получает только
  проекцию данных интерфейса через `alpha-ui.mjs`.
- Перед локальным запуском выполните из корня `python client/tools/build_web_alpha.py`.
  Сборка лежит в `client/build/web-alpha`, сервер отдаёт её через `/flutter-ui/`.
  Старый `build_web_beta.py` по-прежнему собирает отдельную оболочку Beta.
- Повторно используются Android `MessageBubble`, `MessageInput`, `AvatarView`,
  тема, логотип, разделитель дат, пустые состояния и motion-компоненты. UI-метаданные
  выбранного чата, позиции и локального просмотра лежат в sessionStorage; тексты
  сообщений и ключи туда не записываются. Локальный просмотр не означает сетевой read ACK.
- CSP разрешает WebAssembly и inline-стили, необходимые Flutter. JS собирается с
  `--csp`: `unsafe-eval` и сторонние сетевые origin не разрешены. Шрифты, CanvasKit
  и emoji загружаются локально; offline-cache содержит явный список статических файлов.
- Клавиатура учитывается через VisualViewport и embedded Flutter view, safe area —
  через CSS env. Эмуляция WebKit не подтверждает физический iPhone/standalone PWA.
- `server/server.js` и существующий native Flutter UI продолжают использовать v1.
  Они не переключаются на alpha-процесс и не мигрируют пользователей.
- Alpha-хранилище: `device-v2.enc`, AES-256-GCM, атомарная запись с flush/rename,
  единственный writer. Отдельные storage secret, директория и учётная запись ОС.
  Ошибка расшифровки/повреждение/занятый writer приводят к отказу запуска.

## Настройка Google и HTTPS

1. Выделить **новый** hostname, например `alpha.example.com`, направить DNS на
   тестовый сервер. Не использовать origin приложения production.
2. В Google Cloud создать отдельный OAuth client типа **Web application**.
   В consent screen включить Testing и добавить **оба** Google-аккаунта тестировщиков.
   Области: `openid email profile`.
3. В Authorized redirect URIs указать строго
   `https://alpha.example.com/auth/google/callback`.
   Для localhost-разработки отдельный URI: `http://localhost:3101/auth/google/callback`.
   Здесь используется server-side code flow, поэтому Google JavaScript origins
   и подключение Google SDK на страницу не требуются.
4. Скопировать `deploy/alpha/.env.example` в закрытый файл `alpha.env` (не Git).
   Задать точный `ALPHA_PUBLIC_ORIGIN` без завершающего `/`, свой client ID/secret,
   **новый** storage secret и новую пустую директорию данных.
   Секрет можно создать командой `node -e "console.log(require('crypto').randomBytes(32).toString('hex'))"`.
   Сохранить его вне устройства сервера: без него резервная копия БД не читается.
5. Установить зависимости из существующего lockfile: `npm ci` из `server`.
   Node.js >=22. Запуск: `node --env-file=<путь-к-alpha.env> alpha.mjs` из `server`.
   В репозиторий/релиз нужны `server` и `client/web`, включая protocol, icons и
   alpha-файлы. Не включать `.env`, data, build, сертификаты, профили QA и артефакты.
6. Перед Node установить HTTPS reverse proxy, пример —
   `deploy/alpha/Caddyfile.example`. Caddy поддерживает WSS upgrade автоматически.
   Новый systemd service приведён в `shade-alpha.service.example`.
   Примеры подготовлены, **на VPS не применялись**. Не заменять существующий Caddyfile.
7. Проверить `/api/health`: `service=shade-web-alpha`, `protocol=2`, `isolated=true`.
   На странице до настройки OAuth честно отображается отсутствие конфигурации.

OAuth: server-side authorization code + PKCE S256, одноразовые state/nonce,
проверка Google ID token/audience/email, HttpOnly SameSite=Lax Secure cookie.
SDK Google не загружается в origin, где разблокированы ключи. CSP — только self.
Cookie подтверждает Google-аккаунт; чтение/ACK/Socket дополнительно требуют
одноразовую подпись текущего устройства, привязанную к операции.
Сессии живут до 8 часов в памяти; после рестарта нужен повторный вход через Google.

Официальные ссылки для настройки:
- https://developers.google.com/identity/protocols/oauth2/web-server
- https://developers.google.com/identity/openid-connect/reference
- https://socket.io/docs/v4/delivery-guarantees/

## Пользовательская проверка

1. Открыть origin в двух независимых Safari/браузерных профилях, войти разными
   Google-аккаунтами. Android для регистрации не требуется.
2. Выбрать разные nickname. Ввести фразу устройства (16+ символов) и отдельную
   recovery-фразу (24+). RSA-4096 ключи создаются WebCrypto локально.
3. Скачать recovery-пакет и сохранить обе фразы отдельно. Файл содержит только
   зашифрованный независимый recovery-ключ и публичный genesis. Приватные ключи
   устройства и фразы в API не отправляются.
4. Каждый пользователь открывает «Ключ». Через независимый доверенный канал
   сверить **полный genesis digest** собеседника и ввести его в диалоге контакта.
   До сверки отправка и ACK входящих сообщений этого контакта заблокированы.
5. Обменяться текстом в обе стороны. Статус «На сервере» не означает доставку.
   «Доставлено: N/M устройств» появляется только после подписанного ACK, после
   расшифровки и атомарного сохранения истории на принимающем устройстве.
6. Обновить страницы, разблокировать фразами: ключи и локальная история прежние.
7. Отключить сеть у получателя, отправить ему сообщение. Проверить отсутствие
   отметки доставки. Открыть PWA offline, разблокировать историю, поставить ответ
   в очередь. Включить сеть: очередь доставляется без генерации новых ID/ключей.
8. На физическом iPhone: Safari → «Поделиться» → «На экран Домой». Отдельно
   проверить вход через Google в standalone PWA и после переключения приложений.
   Разные профили/standalone-контексты могут иметь разные хранилища; нельзя
   автоматически назначать им новую личность существующего аккаунта.

Локальные vault PKCS8 и история/checkpoints/outbox шифруются существующей
AES-GCM/PBKDF2 схемой (600000 итераций). Разблокированные CryptoKey non-extractable,
живут в памяти. IndexedDB commit происходит до ACK. CAS версии локального
состояния останавливает конфликтующие записи из нескольких вкладок.
Тексты отображаются через `textContent`, без HTML из сообщений.

Socket.IO используется для сигналов о новых сообщениях/ACK. После reconnect,
возврата вкладки и каждые 15 секунд выполняется подписанный HTTP fetch.
Подписанный outbox сохраняется до подтверждения сервера. При неоднозначном
ответе повторяется **тот же** ciphertext/ID. Изменившийся каталог может
заблокировать старую очередь; она не перешифровывается молча и не теряется.

## Android и границы совместимости

Исходные `users.publicKey`, RSA private key, SQLCipher, v1 API и сообщения
не изменяются. Alpha CLI вообще не загружает production `users.json`.
Существующий v1 Android ещё не умеет формировать device-v2 fanout и подписи;
Web Alpha не притворяется совместимым с его неподписанным v1 send.

Тест `alpha_http_interop_test.dart` использует **реальный существующий native
CryptoService/fast_rsa** на Windows, синтетический исходный RSA и отдельную БД.
Он подписывает legacy genesis исходным RSA, проходит HTTP enrollment,
расшифровывает Web-сообщение, подписывает/шифрует ответ, проверяет ACK. В конце
проверяются неизменность обоих исходных RSA и корня на сервере.
Это тест криптографии/HTTP, **не тест установленного Android APK**.
Перевод реального Android-аккаунта в v2 и native UI/transport требуют отдельной
интеграции; production-миграция здесь не выполнена и не разрешена.

## Воспроизведение

Из `server`:
```
npm test
node tools/alpha-browser-qa.mjs <абсолютный-путь-к-playwright-core> webkit
node tools/alpha-browser-qa.mjs <абсолютный-путь-к-playwright-core> edge
```
Нужны установленный Playwright WebKit и Microsoft Edge. QA поднимает настоящий
HTTPS/WSS сервер с отдельным временным localhost-сертификатом и **только для
него** разрешает недоверенный сертификат в браузере. Приложение TLS не ослабляет.
Профили, тестовые ключи/БД и скриншоты остаются в игнорируемом
`server/build/alpha-browser`; результаты — `<engine>-results.json`.

Из `client`:
```
flutter test
flutter analyze --no-pub
```
Результаты исходной Alpha до Flutter UI-порта (16.11.2026):

| Проверка | Результат |
| --- | --- |
| `server: npm test` | **42/42 PASS**, включая прежние v1 TLS/авторизацию/очереди и новые HTTP v2/security/storage тесты |
| `client: flutter test` | **75/75 PASS**, включая новый native HTTP interop и прежние UI/crypto тесты |
| `flutter analyze --no-pub` | 0 errors, 0 warnings, **36 info**, exit 1 из-за info; полный clean analysis не заявляется |
| WebKit, два независимых постоянных профиля | **PASS**: Web-first регистрация, обмен по HTTPS/WSS, расшифровка, ACK, тот же RSA после reload, encrypted IndexedDB, offline reload, outbox/reconnect |
| Microsoft Edge, два независимых постоянных профиля | **PASS**: тот же сценарий |
| Вход существующего Google-аккаунта на новом устройстве | **PASS**: блокировка без local vault, новые ключи не создаются |
| 320/390/768 px, увеличенный текст на 320 px | **PASS**, горизонтального переполнения нет; скриншоты просмотрены |
| JavaScript syntax | **PASS** для server/client/worker/test bridge |
| Настоящий Google OAuth / физический Safari / установленный Android v2 | **НЕ ПРОВЕРЕНЫ** |
| Публичное развёртывание / production-миграция | **НЕ ВЫПОЛНЯЛИСЬ** |

JSON протоколы и скриншоты синтетической переписки сохранены в
`artifacts/web-alpha-0.1/`. В этих отчётах временные loopback-адреса тестов;
серверы после тестов остановлены, это не публичные ссылки.

Native HTTP interop выполнен существующими RSA-библиотеками на Windows. Обе
стороны проверяют подписи; сервер хранит только шифротекст, история на клиенте
зашифрована. Во время offline-теста у отправителя до получения ACK сохранялся
статус «На сервере». Неавторизованный/повторный proof и подмена ciphertext
отклоняются. Отдельно проверены restart, идемпотентный retry после обновления
каталога, ошибка storage secret и отказ запуска рядом с legacy-файлами.

## Оставшиеся ограничения

- Нет публичного развёртывания и проверки с настоящим Google OAuth.
- WebKit automation не заменяет Safari и standalone PWA на физическом iPhone.
- Нет проверки переписки с установленным Android APK по v2; старый v1 APK
  продолжает работать со своим прежним сервером.
- Добавление второго устройства, отзыв и recovery доступны в протоколе, но
  экранов этих функций в минимальной альфе нет. Google не добавляет устройство.
  При отсутствии local vault показывается блокировка, без замены RSA.
- История хранится только на получившем её устройстве. Снятие/очистка данных
  сайта теряет эту историю; recovery-пакет не содержит старую историю.
- Lease каталога 24 часа, автообновление при активном клиенте. Если контакт
  долго offline и lease истекла, отправка ждёт его обновления. Подпись сообщения
  принимается не позднее 7 дней после создания. Лимиты registry: 200/очередь,
  10000 receipt ID, 4096 версий каталога; очистка не добавлена.
- Активный XSS/подмена JS на сервере всё ещё опасны для разблокированной сессии;
  CSP не устраняет доверие к поставке приложения. Forward secrecy не добавлена.
- Зашифрованный snapshot не защищает от отката всей БД администратором/сбоем
  backup. Клиентские checkpoint обнаруживают известный rollback. Перед любыми
  работами с production нужны отдельное разрешение, backup и проверка restore.
- После аварийного kill может остаться `writer.lock`. Удалять его вручную можно
  только убедившись, что alpha-процесс остановлен и второго writer нет. БД и
  storage secret не удалять и не заменять.

## Проверка Flutter UI-порта (16.11.2026)

- Flutter release Web: PASS (`python client/tools/build_web_alpha.py`).
- Flutter: 82/82, включая 7 UI/ACK/scroll проверок, текст 200% и keyboard inset.
- Server: 42/42; analyzer: 0 errors, 0 warnings, 41 info (Material deprecations).
- WebKit и Edge: два независимых постоянных профиля, HTTPS/WSS E2EE, настоящий
  ACK, reload с прежней identity, offline reload/outbox/reconnect, длинное сообщение,
  восстановление фактической прокрутки, 320/390/430/768/1440 px, reduced viewport.
- Edge при быстром прогоне получил 8 ответов 429 от существующего лимита 300 API
  requests/min; восстановился штатным повтором. Лимит и транспорт не изменялись.
- Alpha API не отдаёт displayName/фотографии профиля: показаны реальные usernames
  и общий AvatarView с инициалом. Доступные устройства — из проверенного каталога.
- Физический iPhone/standalone PWA, настоящий Google OAuth и новый Android APK
  не проверялись. Production/VPS не изменялся.
- Реальные снимки двух локальных QA-аккаунтов, JSON и логи: `artifacts/web-ui-port/`.
