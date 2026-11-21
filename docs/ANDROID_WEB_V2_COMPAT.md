# Совместимость веток: android-web-e2ee ↔ zcode/pwa-parity

Обновлено 16.11.2026. Отчёт подготовлен перед объединением; merge не выполнялся,
ветка ZCODE не изменялась. Источник по ZCODE — `git show zcode/pwa-parity:docs/PWA_PARITY_MATRIX.md`
и diff от общего предка.

## База и пересечения

- Общий предок (merge-base): `cf81ac6` (codex/vinyl-material-redesign).
- ZCODE (`8e58e65`+): PWA-итерация 1 — reply, deleteLocal, профиль собеседника,
  jump-to-latest FAB; 86/86 Flutter, 42/42 server, browser QA PASS.
- Данная ветка: native Android device-v2 клиент (протокол/крипта/транспорт/
  хранилище/репозиторий/UI) + native Google-вход в alpha-процесс.
- **Пересечений изменённых файлов нет.** ZCODE меняет `client/web/*`,
  `features/web/*`, `web_alpha_ui_test.dart`, `alpha-browser-qa.mjs`, артефакты;
  данная ветка — `core/services/device_v2/*`, `features/devices/*`,
  `database_service.dart` (аддитивная схема v9), `profile_screen.dart` (+15 строк,
  точка входа), `server/alpha.mjs` (+маршрут), новые тесты/мосты.
  Текстуальный merge в любом порядке ожидается чистым.

## Выровненные контракты (проверено тестами)

| Контракт | ZCODE (PWA) | android-web-e2ee (Android) | Проверка |
| --- | --- | --- | --- |
| Wire payload reply | `{"shade":1,"t","r":{ref,from,text}}`, plain text без маркера; preview ≤2000 | `device_v2/payload.dart` — точный порт encode/decode, включая fallback для JSON-подобного текста | `device_v2_payload_test.dart` (8), round-trip с WebCrypto в `device_v2_repository_test.dart` |
| «Удалить у себя» | локальное скрытие + отмена очереди; ACK перед удалением pending | `V2ChatRepository.deleteLocal`: ACK-first для не-ACK входящих, отмена outbox, удаление строки; другие устройства сохраняют копию | repository-тест (удаление входящего/исходящего) |
| Статусы доставки | queued/accepted/blocked + per-device ACK «N/M» | outbox с тем же ciphertext/ID при retry; `Доставлено: N/M` через `MessageBubble.deliveryLabel`; blocked фиксируется в outbox.last_error | transport/repository-тесты против реального alpha.mjs |
| Сверка ключей | genesisDigest 64 hex → pinContact | `confirmContact`: verifyGenesis + сравнение digest + verifyHistory; до сверки отправка/ACK заблокированы | repository + widget-тесты |
| Регистрация | web-first RSA-4096 WebCrypto, genesis подписан устройством | legacy-enrollment: исходный RSA подписывает genesis, остаётся primary-якорем; ключи/SQLCipher/v1 не переписываются | `alpha-native-session.test.mjs`, transport/repository-тесты |
| Recovery | независимый RSA-PSS, PBKDF2-600k + AES-GCM AAD, пакет вне устройства | тот же формат; Dart↔JS разблокировка в обе стороны | `device_v2_crypto_test.dart` |
| Транспорт | challenge/operation device-proof, socket hints + fetch 15с | `AlphaTransport` — тот же протокол, свежий proof на каждый reconnect | transport-тест (реальный HTTP/WSS) |

## Что добавляет данная ветка для объединения

- `server/alpha.mjs`: `POST /api/v2/session/google` (Google ID token, тот же
  `googleProfile`/audience, rate limit 15/мин) + test-only инъекция `verifyGoogle`
  по образцу `oauthProvider`. PWA-flow ZCODE не затрагивается.
- `server/test/helpers/alpha-fixture.mjs`: аддитивный `loginToken`.
- SQLCipher schema v9: только новые `v2_*` таблицы; v1-данные не меняются.
- Точка входа в профиле: «Shade Alpha — Web ↔ Android» (Navigator.push, без
  изменения GoRouter-редиректов).

## Контракты C1–C7 из матрицы ZCODE (не реализованы ни в одной ветке)

C1 self-chat, C2 typing/presence, C3 retract, C4 фото, C5 read-ACK, C6 Web Push,
C7 displayName/аватары — остаются согласованными требованиями к протоколу.
Данная ветка не меняет `device-v2.mjs`/`registry.mjs`, поэтому требования
матрицы сохраняются без изменений. При реализации C1–C7 кодек payload
(`shade:1`) должен версионироваться согласованно в `alpha-client.mjs` и
`device_v2/payload.dart` (единственные две точки wire-схемы).

## Рекомендации по объединению

1. Порядок merge любой (пересечений нет); после merge прогнать объединённые
   наборы: `server: npm test` (ожидается 44+ теста ZCODE не добавляли серверных),
   `client: flutter test` (82 базы + 4 ZCODE + 28 данной ветки = 114),
   `flutter analyze --no-pub` (0 errors/warnings; info — предсуществующие
   Material deprecations + 2 новых файла в том же стиле).
2. Browser QA ZCODE (`alpha-browser-qa.mjs`) после merge повторить: изменения
   alpha.mjs аддитивны, но CSP/маршруты стоит проверить целиком.
3. Точки внимания:
   - `GoogleSignIn.instance.initialize` вызывается с `GOOGLE_WEB_CLIENT_ID` (v1)
     и `ALPHA_GOOGLE_CLIENT_ID` (alpha) — на реальном Android проверить
     совместимость повторной инициализации плагина (в тестах не покрыто).
   - `MessageBubble.deliveryLabel` — semantics-метка, не видимый текст; если
     PWA-проекция показывает «Доставлено: N/M» текстом, для визуального паритета
     может понадобиться видимый label в общем виджете (отдельное решение).
   - Nonce для ID token-входа (рекомендация независимого ревью Kimi): для
     публичного production добавить серверный nonce; для изолированного alpha
     приемлемо (bearer до exp, rate limit, HttpOnly/Secure/SameSite cookie).
4. Production `server.js` (v1), VPS, ZCODE-worktree и реальные ключи не
   изменялись ни в одной из веток; миграция аккаунтов v1→v2 остаётся явной и
   требует отдельного разрешения с backup/restore.

## Непроверенное (обе ветки)

Настоящий Google OAuth на физическом Android/iPhone, установленный APK с v2,
standalone PWA, production-миграция. Interop доказан на синтетических ключах
против реального alpha-процесса (HTTP/WSS) и реальными native RSA-библиотеками
на Windows.