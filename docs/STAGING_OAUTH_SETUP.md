# Staging Google OAuth — настройка для закрытого iPhone-тестирования

Дата: 18.11.2026. Staging: https://alpha.shadechat.ru (изолирован, production
v1 не затрагивается). Цель: подруга устанавливает PWA на iPhone, входит через
Google, переписывается с владельцем через E2EE.

## 1. Что мешает Google-входу сейчас (диагноз)

1. **Главный блокер**: в `/var/lib/shade-staging/staging.env` не заданы
   `ALPHA_GOOGLE_CLIENT_ID` / `ALPHA_GOOGLE_CLIENT_SECRET` →
   `provider.configured=false` → `/auth/google` отвечает «Google OAuth is not
   configured», UI показывает честное уведомление. Нужен отдельный staging
   Web-клиент (действия ниже).
2. **iOS standalone PWA cookie-jar**: у установленной PWA и Safari/in-app
   браузера РАЗНЫЕ хранилища cookie. Существующий flow привязывает OAuth-flow
   к cookie (`__Host-shade-oauth`), а сессию ставит в том jar, где прошёл
   callback. В standalone это может дать «Invalid OAuth callback» или сессию,
   которая не видна приложению. **Исправляется на сервере/клиенте** (моя зона,
   без изменения E2EE): поиск flow по state + одноразовый handoff-код во
   фрагменте URL, который PWA обменивает на сессию в своём jar.
3. Consent screen в режиме Testing пускает только test users — это и есть
   allowlist Google; дополнительно будет серверный allowlist (опционально).

Существующая система НЕ переписывается: PKCE S256 + state + nonce,
verifyIdToken (audience/email_verified), single-use login nonces для Android,
device-proof на каждую операцию — всё сохраняется. Android native flow не
меняется.

## 2. Точные действия владельца в Google Cloud Console

Используйте **существующий проект Shade** (тот же, что у production v1 —
его client ID в `/etc/shade/shade.env`, НЕ менять и не переиспользовать для
staging).

### Шаг 1. OAuth consent screen (APIs & Services → OAuth consent screen)
- Если экран уже создан (External): ничего не пересоздавать.
- User type: **External**; publishing status: **Testing** (для закрытого теста
  верификация Google не нужна).
- App name: `Shade Staging` (можно отдельный от production, если экран уже
  есть — оставить как есть, имя не критично).
- Scopes: `openid`, `email`, `profile` (не добавлять лишние).
- **Test users → Add users**: Gmail владельца и Gmail подруги (без этого
  вход невозможен в Testing-режиме). До 100 пользователей.
- Подруга при входе увидит экран «Google hasn't verified this app» →
  «Advanced» → «Go to Shade Staging (unsafe)» — это нормально для закрытого
  теста, объяснить ей заранее.

### Шаг 2. Новый OAuth client (Credentials → Create Credentials → OAuth client ID)
- Application type: **Web application**
- Name: `Shade Staging PWA`
- **Authorized JavaScript origins**:
  ```
  https://alpha.shadechat.ru
  ```
- **Authorized redirect URIs** (точно, без слеша на конце):
  ```
  https://alpha.shadechat.ru/auth/google/callback
  ```
- Создать. Скопировать **Client ID** и **Client secret**.

### Шаг 3. Заполнить staging.env НА СЕРВЕРЕ (не присылать секреты в чат/отчёты)
```bash
# root SSH, отредактировать /var/lib/shade-staging/staging.env:
ALPHA_GOOGLE_CLIENT_ID=<новый Client ID>.apps.googleusercontent.com
ALPHA_GOOGLE_CLIENT_SECRET=<новый Client secret>
# затем:
systemctl restart shade-staging
curl -s https://alpha.shadechat.ru/api/session | grep googleConfigured
# ожидается "googleConfigured":true
```
(Файл уже существует с остальными настройками; добавить/заменить только эти
две строки. Права 0600 сохраняются.)

### Шаг 4. Сообщить мне
- Что клиент создан и env заполнен (значения НЕ присылать).
- Gmail подруги — если нужен серверный allowlist (опционально; можно без него,
  Google Test users уже ограничивают вход).

## 3. Что реализую я (без ожидания Console, кодовая часть)

1. Callback: поиск flow по cookie ИЛИ по state (single-use, 5 мин) —
   устраняет cross-jar проблему iOS standalone.
2. Одноразовый handoff-код (60 с, привязан к профилю) во фрагменте
   `/#shade_login=<code>`; PWA обменивает его POST-запросом в своём jar →
   сессия ставится в PWA. Возврат в PWA после Google — в рамках scope.
3. Сохранение сессии (8 ч, `__Host-` Secure HttpOnly SameSite=Lax) и повторный
   вход через welcome-экран; ключи/история в IndexedDB не затрагиваются.
4. Опциональный серверный allowlist `ALPHA_OAUTH_ALLOWLIST` (email/sub,
   fail-closed при заданном списке) в callback и native session/google.
5. Тесты безопасности: state-replay, чужой/просроченный flow, handoff-replay,
   allowlist-отказ, nonce-replay (существующие), origin-отказ.
6. Браузерное QA: WebKit (движок Safari) + Edge, мобильная геометрия;
   синтетический OAuth-провайдер в изолированном fixture (реальный Google
   проверяется владельцем/подругой на устройстве — headless не доказывает
   физический iPhone).
7. Staging-деплой с откатом (новый release-каталог + admin-скрипт переключения,
   backup/rollback как раньше). Production не трогать.

## 4. Сценарий закрытого теста (после настройки)

1. Подруга: iPhone → Safari → https://alpha.shadechat.ru → «Установить Shade»
   (Поделиться → На экран Домой) → запуск с иконки (standalone).
2. «Войти через Google» → тестовый Gmail → consent (unverified warning →
   Advanced) → возврат в PWA → создание никнейма + фразы устройства +
   recovery-фразы → ключи RSA-4096 создаются в её браузере (до минуты).
3. Recovery-пакет скачать и сохранить вне телефона.
4. Владелец: аналогично на своём устройстве (staging-аккаунт отдельный от
   production v1 — существующие аккаунты/ключи не меняются).
5. Добавить друг друга по никнейму, сверить отпечатки genesis по независимому
   каналу, переписываться (E2EE), проверить push/offline/reply/медиа.