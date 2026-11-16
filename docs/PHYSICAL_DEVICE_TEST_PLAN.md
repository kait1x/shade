# Отчёт о тестировании на физических устройствах (перед интеграцией с реальными пользователями)

Статус: **план подготовлен, физические тесты НЕ выполнены в этой сессии**
(устройства недоступны агенту). Автоматизированные проверки покрывают
движковый уровень (Edge/WebKit QA, реальные HTTP/WSS, синтетические идентичности);
данный документ — обязательный шлюз перед реальными пользователями.

## 1. Окружение для испытаний

- Отдельный HTTPS-origin (не production), `alpha.env`: новый storage secret,
  пустой dataDir, отдельный OAuth Web-клиент (Testing + оба тест-аккаунта),
  VAPID-ключи (`ALPHA_VAPID_*`), при необходимости `ALPHA_PUSH_ALLOWED_HOSTS`.
- Android: debug/release APK из интеграционной ветки с
  `--dart-define=ALPHA_GOOGLE_CLIENT_ID=<client>` и доступным HTTPS-relay.
- iPhone: Safari → «На экран Домой» (standalone PWA), iOS 16.4+ для Web Push.
- Два независимых тест-аккаунта Google; синтетические данные, не реальные.

## 2. Android ↔ PWA переписка (критично)

| # | Шаг | Ожидание |
|---|---|---|
| A1 | Enrollment legacy-аккаунта в v2 (исходный RSA) | genesis подписан старым ключом; ключи/SQLCipher/v1-история не изменены; recovery-пакет сохранён вне устройства |
| A2 | Android → PWA текст | Web расшифровывает; «Доставлено: N/M» после подписанного ACK; статус «На сервере» ≠ доставка |
| A3 | PWA → Android текст | Android расшифровляет; ACK device-scoped |
| A4 | Reply в обе стороны | payload `{"shade":1,"t","r"}` совместим; цитата отображается |
| A5 | Self-chat «Избранное» | fanout на все свои устройства; ACK каждого; нет дублей |
| A6 | Фото Android→PWA и PWA→Android | чанки ≤32 КиБ; EXIF/GPS срезаны до шифрования (проверить метаданные полученного JPEG); сборка байт-в-байт |
| A7 | Подарок/стена | gift идемпотентен по requestId; стена CAS; чужой профиль виден, приватные поля нет |
| A8 | Typing/presence | индикатор только после сверки контакта; троттлинг; offline → online корректно |
| A9 | Read-ACK | «Прочитано» у отправителя после просмотра получателем |
| A10 | Retract | недоставленные копии исчезают из очередей; доставленные помечаются «отозвано»; повтор идемпотентен |
| A11 | Offline/outbox | очередь сохраняется при kill/reload; retry тем же ciphertext/ID; после восстановления сети доставка без новых ключей |
| A12 | Отзыв устройства | очереди и push-подписка отозванного устройства удалены; ID не воскресает |

## 3. Надёжность хранилища (WebKit IndexedDB — отдельный риск)

| # | Шаг | Ожидание |
|---|---|---|
| S1 | Регистрация → немедленный kill Safari (без задержки) → перезапуск | vault на месте (durability-flush + read-back); идентичность не регенерируется |
| S2 | Длинная история → kill во время записи → перезапуск | последняя подтверждённая транзакция сохранена; CAS revision не ломается |
| S3 | Две вкладки PWA | конфликтующая запись отклоняется CAS; `onversionchange` закрывает старое соединение |
| S4 | Очистка данных сайта | честная блокировка без подмены личности; recovery-пакет восстанавливает членство |
| S5 | Android: reboot/обновление приложения | ключи в Keystore сохранены; SQLCipher v9 миграция аддитивна |

Примечание: искусственные задержки в QA **не** считаются доказательством
надёжности; проверять именно abrupt kill. Фикс клиента: follow-up meta-транзакция
+ read-back verification (`alpha-storage.mjs`, `device_crypto.mjs`).

## 4. Google-вход и push

| # | Шаг | Ожидание |
|---|---|---|
| G1 | Реальный Google OAuth (браузерный code flow) на обоих тест-аккаунтах | state/nonce/PKCE; сессия 8 ч; повторный вход ротатирует SID |
| G2 | Native ID token-вход (google_sign_in) | audience = alpha client ID; Origin обязателен; device-proof на каждую операцию |
| G3 | Web Push (standalone iOS / Edge) | подписка `push.subscribe`; wake-only без текста; 410 → prune; отзыв → prune |
| G4 | Android FCM (v1) | не затронут v2-миграцией; работает как раньше |

## 5. Шлюзы безопасности перед реальными пользователями

1. Nonce для native ID token-входа (рекомендация независимого ревью) —
   реализовать до публичного release; для закрытой альфы приемлемо.
2. Push egress: настроить `ALPHA_PUSH_ALLOWED_HOSTS` (allowlist провайдеров)
   либо DNS-резолв с проверкой адреса (DNS-rebinding не закрыт полностью).
3. Production-миграция v1→v2: `assertLegacyAllowed`/`upgrade_required` не
   подключены к `server.js`; требуется отдельное разрешение владельца,
   dry-run копия данных, проверенный backup/restore.
4. Lease 24 ч: злонамеренный relay может скрывать свежий отзыв до истечения
   lease — key transparency/gossip вне текущего объёма; документировать.
5. Ротация ранее утекших .env из Git-истории (KNOWN_ISSUES) — до deployment.

## 6. Что уже проверено автоматически (интеграционная ветка)

- Сервер: 60/60 (v1 регрессии + все B1–B9 + security hardening + storage).
- Flutter: полный набор (Android v2 клиент + PWA-проекция + UI).
- Реальный Android↔Web interop: Dart CryptoService/fast_rsa ↔ WebCrypto
  против реального alpha.mjs (HTTP/WSS): enrollment, E2EE в обе стороны,
  reply, self-chat, read, retract, media 70 КБ байт-в-байт, lease renewal,
  recovery, tamper/replay negatives.
- Edge/WebKit QA: см. `server/build/alpha-browser/*-results.json`
  (синтетический OAuth; реальный Google не сертифицируется).