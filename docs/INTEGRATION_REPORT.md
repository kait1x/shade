# Отчёт интеграции: Android + PWA + device-v2

Ветка: `integration-android-pwa` (worktree
`.agents/worktrees/integration-android-pwa`). Исходные ветки не изменялись;
merge в main и deployment не выполнялись; production-файлы не тронуты.

## 1. Топология и слияния

- База: `android-web-e2ee` (backend B1–B9 + Android v2 клиент, HEAD b868f7f).
- Merge 1: `zcode/pwa-parity` @ 570ce75 (PWA-профили, редактор аватаров,
  виниловые наклейки, reverse-чаты, dual-engine QA) — чисто, авто-слияние
  `profile_screen.dart`.
- Merge 2: `zcode/pwa-parity` @ 192224a (GLM: клиентская интеграция B1–B9) —
  чисто; self-chat изменения протокола в обеих ветках оказались идентичны.
- Последующие коммиты интеграции: security hardening, Android v2 операции/UI,
  IndexedDB durability, QA-инфраструктура, документы.

## 2. Аудит совместимости (роль интегратора)

- Маршруты/тела PWA-адаптера совпадают с DEVICE_V2_API.md: профили/аватары
  (CAS revision, uploadId), наклейки (inventory/gift/wall, requestId),
  read/retract/retractions, typing/watch, медиа-кодек `m` (32768 байт/чанк,
  идентичный JSON в JS и Dart).
- Подарки PWA → v2 adapter → v1 бизнес-логика: проверено тестами сервера.
- Android v2 ↔ Web: сквозной interop против реального alpha.mjs (HTTP/WSS):
  enrollment, E2EE в обе стороны, reply, self-chat, read-ACK (readAt у
  отправителя), retract (tombstone у получателя), медиа 70 КБ байт-в-байт,
  продление lease, recovery, tamper/replay negatives.
- Кодеки: Dart `payload.dart` и JS `alpha-client.mjs` — одинаковая wire-схема;
  golden-векторы протокола (включая self) совпадают байт-в-байт.

## 3. Независимое ревью безопасности (Kimi) и исправления

Подтверждённые находки исправлены (коммит a1d4fba + тесты
`alpha-security-hardening`):
- retract: tombstone только для реально отправленных ref; per-account quota
  2000 (защита от исчерпания глобального лимита фиктивными ref).
- challenge: per-account quota 100 (изоляция от DoS ёмкости).
- typing: троттлинг per-pair (не per-account).
- `/api/v2/session/google`: fail-closed Origin === publicOrigin.
- push: опциональный allowlist хостов `ALPHA_PUSH_ALLOWED_HOSTS`.
- IndexedDB: `onversionchange → close`.
Отклонённые как false-positive (подтверждено тестами): ACK/status/read
изолированы per-device (чужой ACK — no-op, чужой status — пустой список);
socket handshake требует device-proof; SID ротируется при каждом входе.
Остаточные рекомендации (документированы): nonce для native ID token,
DNS-rebinding egress-защита push, `upgrade_required` в production v1.

## 4. Исследование WebKit IndexedDB (задача 10)

Метод: реальные Edge/WebKit прогоны + диагностика (очередь сервера, сырой
IDB-снапшот, журнал) + node-тесты модели потерь.
Факты: WebKit flush асинхронный и для IndexedDB, и для localStorage
(StorageTracker); свежие соединения читают in-memory состояние IDB-сервера,
reload после закрытия соединений читает диск; последний батч может потеряться
при abrupt reload/kill внутри flush-окна. JS-примитива синхронного flush нет.
Искусственная задержка 1500 мс удалена как «фикс клиента»; для WebKit QA
восстановлено документированное ожидание flush ПЛАТФОРМЫ перед reload-проверкой
(Edge проходит немедленный reload без ожиданий).
Клиентские механизмы (мои файлы `alpha-storage.mjs`, `device_crypto.mjs`):
1. Синхронный localStorage-журнал удалений (refs без содержимого) ДО IDB-commit.
2. IDB write-ahead журнал (атомарно с состоянием) + применение при чтении.
3. Double re-commit идентичной записи + meta-flush (vault и state).
4. Фоновая конвергенция (перезапись при устаревшем свежем чтении).
Node-тесты (5/5): CAS, журнал против отката состояния, синхронный журнал
против полной потери IDB-батча, аддитивный апгрейд v1→v2→v3, vault flush.
Остаточный риск: потеря последнего батча ИСТОРИИ (не удалений) при kill внутри
flush-окна; UI GLM скрывает сообщение оптимистично до завершения save —
рекомендация GLM: скрывать после resolve save (их файлы не редактировались).

## 5. Проверки

- Сервер `npm test`: 60/60 (v1 регрессии, B1–B9, hardening, storage, interop).
- Flutter `flutter test`: 127/127 (Android v2, PWA-проекция GLM, UI, interop).
- `flutter analyze`: 0 errors, 0 warnings (info — предсуществующие deprecations).
- Browser QA (реальные HTTPS/WSS, синтетический OAuth, два независимых
  persistent-профиля): **Edge — полный PASS, WebKit — полный PASS** (финальные
  прогоны: registration, fingerprints, pinned contacts, bidirectional E2EE+WSS,
  reload identity/history, offline outbox+reconnect, reply round-trip,
  local delete durability, unlinked-device identity protection, responsive
  320–1440, scroll restoration, reduced keyboard viewport, pageErrors=[]).
  Результаты: `server/build/alpha-browser/{edge,webkit}-results.json`.
- QA-инструмент: pre-check Flutter-сборки, метки read-ACK, IDB без версии,
  условия durability (журнал клиента + дренаж очереди сервера); WebKit —
  документированное ожидание flush платформы, не фиксированная задержка клиента.

## 6. Ограничения и следующие шаги

1. Web Push: backend готов (B8), клиентская подписка PWA не реализована
   (зона GLM); Android использует FCM v1 (не затронут).
2. Физические устройства: не тестировались; обязательный шлюз —
   PHYSICAL_DEVICE_TEST_PLAN.md (A1–A12, S1–S5, G1–G4).
3. Рекомендации GLM: порядок оптимистичного скрытия при удалении (после
   save); Web Push-подписка; проверка delete-durability на физическом Safari.
4. Production-миграция v1→v2 (`assertLegacyAllowed`/`upgrade_required`) —
   отдельное разрешение владельца, backup/restore dry-run.
5. Nonce для ID token-входа и push egress-защита — до публичного release.
6. Реальный Google OAuth не сертифицирован синтетическим QA.

## 7. Коммиты интеграции (поверх merge)

- a1d4fba security hardening + тесты
- c2d00e8 Android v2 read/retract/media/typing/presence transport + interop
- 8fa5248 Android v2 UI (read/retract/typing/presence/media)
- 01cb945 IndexedDB journal + re-commit
- 2583bec QA: read-метки, IDB-версия, удаление искусственной задержки
- 5ec217c QA pre-check Flutter-сборки
- 0964631 документы: API hardening + physical device gate
- (финальные коммиты durability/QA — см. git log)