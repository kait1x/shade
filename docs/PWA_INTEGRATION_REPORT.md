# PWA integration report — ZCODE final + серверные фиксы (17.11.2026)

Worktree: `.agents/worktrees/integration-android-pwa/.agents/worktrees/v2-pwa-integration`
Ветка: `v2-pwa-integration`. Merge `a367a9d`: родители `6dac4aa` (v2-staging-release)
+ **`73653d8` (финальная `zcode-pwa-release`)**. Подтверждено владельцем и проверено:
- `git merge-base --is-ancestor 73653d8 HEAD` → yes;
- последние 4 коммита ZCODE присутствуют: `d34a212` (paint-size decode +
  media memoize), `33d5b5f` (prune dead engine variants), `369162d` (honest
  rate-limit, sticker wall guard, QA durability), `73653d8` (perf metrics,
  preview, GO/NO-GO) поверх `2d7e6d4`;
- worktree `C:\Users\Kait1x\Documents\Shade-PWA` чистый, HEAD `73653d8` —
  более свежих незакоммиченных работ нет;
- `89df70c` (zcode/pwa-parity) — старый предок, в merge не вносил ничего
  (0 коммитов, уже в базе);
- 34 файла ZCODE, **0 конфликтов** (пересечений с серверной веткой не было).

## Чек-лист владельца — статусы

| Пункт | Статус | Доказательство |
|---|---|---|
| rotationText/verifyRotation | PRESERVED + TESTED | экспорты на месте (grep); rsa-rotation.test.mjs в полном suite |
| legacy.ack from:id | PRESERVED + TESTED | migration.mjs ref-ACK; migration/bridge тесты + Dart collision-тест |
| Android ↔ Web E2EE | PASS | alpha_http_interop_test (Android CryptoService ↔ реальный HTTP v2) PASS; alpha-native-session (native↔web) в suite; browser QA E2EE двух клиентов: **Edge PASS + WebKit PASS**, pageErrors [] |
| fast_rsa worker.js | ОГРАНИЧЕНИЕ (не блокер PWA) | fast_rsa 3.8.6 не имеет web-платформы; standalone Flutter-вход `/flutter-ui/index.html` не может выполнять RSA в web. **Рабочий PWA-путь — JS-оболочка `/` (WebCrypto device_crypto.mjs)**: полный 16-сценарный QA PASS на обоих движках, worker 404 в этом пути не возникает. Рекомендация: не продвигать standalone Flutter-web вход как PWA; WebCrypto-interop для Flutter — отдельная задача ZCODE |
| Service Worker и кеширование | PASS | QA PWA-shell: manifest/icons/SW control/cache allowlist; сборка ZCODE: 23 ассета, −11 engine-артефактов, прекеш ~26.6 МБ (было 50.5); version-digest покрывает все shell-файлы; обновление только по действию пользователя |
| Мобильный onboarding / нижняя белая линия | PASS (эмуляция) + ФИКС | QA 390×844 isMobile/hasTouch: onboarding, клавиатура (480px), overflow-sweep 320–1440, back-gesture — PASS оба движка; добавлен `interactive-widget=resizes-content` (layout viewport ресайзится под клавиатуру — устраняет белую полосу снизу); физический A31 — pending |
| Скрытие install-кнопки в установленной PWA | FIXED | `isStandalone()` (display-mode standalone/window-controls-overlay/navigator.standalone): кнопка на welcome не рендерится, installGuide показывает notice «уже установлен»; проверка в браузере после переключения staging |

## Дополнительные фиксы интеграции

- `server/alpha.mjs`: **JSON-тело 429** `{"error":"rate_limited"}` вместо
  text/html (находка ZCODE: клиент отличает лимит релея от аварии).
  Коммит `3edb28b`.
- `client/web/alpha.html`: viewport `interactive-widget=resizes-content`.
- `client/web/alpha-ui.mjs`: скрытие install в standalone.
- Коммит интеграционных фиксов `51506e4`.

## Browser QA (ZCODE harness, объединённое состояние)

`server/tools/alpha-browser-qa.mjs` — реальный HTTPS/WSS, реальный WebCrypto,
независимые постоянные профили, синтетический OAuth (изолирован), мобильная
геометрия 390×844. 16 сценариев: регистрация → сверка отпечатков →
двусторонний E2EE → offline reload + outbox → reply → deleteLocal → typing →
read-ACK → медиа-чанки → Избранное → профиль v2 → стикеры/подарок → push →
PWA shell → длинные сообщения + скролл → клавиатура → overflow-sweep.

- **Edge: passed=true, pageErrors=[]** (http429DuringRapidRun=28 — честная
  обработка лимита подтверждена).
- **WebKit: passed=true, pageErrors=[]** (http429DuringRapidRun=9).
- Отчёты: `server/build/alpha-browser/{edge,webkit}-results.json`.
- Физический iPhone/Android этим НЕ доказан (headless) — честно.

## Staging-релиз интеграции

- Пакет `build/staging-upload-v2` (27.4 МБ, 122 файла), MANIFEST привязан к
  commit `3edb28b` (после 429-фикса), загружен в
  `/opt/shade-staging/releases/20261117-225500/`, npm ci 246 пакетов,
  node --check OK, **manifest 122/122 verified на VPS**.
- Переключение: владелец выполняет `bash /opt/shade-staging/admin-update.sh`
  (symlink current → новый релиз, restart shade-staging, health-проверки,
  контроль production, команда отката). Данные staging совместимы (формат
  снапшота не менялся).
- После переключения: доменный smoke + браузерная проверка PWA на
  https://alpha.shadechat.ru (мобильная геометрия, standalone-эмуляция).

## Финальные тесты и A31 (фактические результаты 17.11.2026 23:10)

- **Server suite: 82/82 PASS** (serialized, 190 с).
- **Flutter suite: 137/137 PASS** (1:44, включая 3 мобильные регрессии ZCODE
  и rotation/crash/ACK-collision тесты).
- **A31 debug APK собран**: `artifacts/v2-a31/shade-v2-a31-debug.apk`,
  подпись `CN=Android Debug` SHA-256
  `d7d88767fbb4d1269a9bcb5a22f72b93cfb3d6aead596515845307e7563f9d49`
  — **совпадает с установленным на A31 v1 debug** (apksigner по
  `artifacts/ui-ux-2/installed.apk`) → обновление поверх с сохранением данных.

## Финальная доменная верификация (17.11.2026 23:40, после admin-update.sh)

Владелец переключил staging на интегрированный релиз `20261117-225500`
(UPDATE_DONE). Результаты:

- **MANIFEST**: предупреждение о 4 строках — это были metadata-заголовки
  (commit/branch/generated/zcode); вынесены в `MANIFEST.meta`,
  `MANIFEST.sha256` теперь чистый checksum-формат: **122/122 OK, 0 предупреждений**
  (`sha256sum -c` на VPS).
- **Доменный smoke: 12/12 PASS** (health/legacyBridge, CSP, admin-404,
  socket.io polling, cross-origin-403, legacy-key сессия, cookie flags,
  idempotent enrollment resume через HTTPS, signed fetch, дедуп,
  bridge-ack/guard exports).
- **429 JSON**: burst 35 запросов → 30×200 + 5×429, тело
  `{"error":"rate_limited"}`, `application/json` ✅.
- **PWA (Playwright, 390×844, домен)**:
  - консоль: **0 ошибок**;
  - SW active + controller, кеш новой версии **38 записей**;
  - **offline-запуск**: сеть отключена → reload → оболочка рендерится из
    SW-кеша ✅;
  - **install-кнопка**: присутствует в обычном режиме, **скрыта в standalone**
    (эмуляция display-mode) ✅;
  - **обновление SW**: диалог «Доступно обновление Shade» → действие
    пользователя → активация, `waiting=false`, старый кеш удалён, без
    зависания ✅. Применён hardening: reload по `controllerchange` вместо
    немедленного `location.reload()` (гонка со skipWaiting наблюдалась один
    раз в модифицированном контексте; после фикса флоу чистый).
  - **клавиатура/белая линия** (эмуляция 390×500): `--shade-height=500px`
    (visualViewport-handler работает), html-фон чёрный, **0 белых элементов**,
    горизонтального overflow нет; `interactive-widget=resizes-content` в
    viewport. Физический A31 — финальное подтверждение при закрытом тесте.
- **Production не затронут**: shade/caddy active, v1 health 200 (loopback +
  sslip.io), shade-staging active.

SW-hardening коммит: `fix(web): SW update reload on controllerchange`;
обновлённые shell-файлы синхронизированы в staging (статика, без рестарта),
манифест пересобран и проверен (122/122).

## Galaxy A31 — закрытое тестирование (процедура)

1. **Android-приложение**: установить `shade-v2-a31-debug.apk` поверх
   существующего debug v1 (`adb install -r` или передача файла). Данные,
   SQLCipher, ключи сохраняются (та же debug-подпись, versionCode 2 > 1).
   Release-подпись НЕ подходит для этого устройства (другая подпись).
2. В приложении: «Устройства (v2)» →.origin `https://alpha.shadechat.ru` →
   «Войти ключом v1» → enrollment. **Реальный аккаунт на staging не
   мигрируется** (staging содержит только синтетические данные; production
   v1 не затронут, guard выключен). Для теста с реальными данными нужна
   отдельная копия production в staging (разрешение владельца).
3. **PWA через Chrome**: https://alpha.shadechat.ru → установка → standalone →
   чеклист `docs/PWA_ANDROID_QA.md` §4 (14 шагов). Вход через Google требует
   staging OAuth-клиент (отключён по решению владельца); до этого PWA-вход
   недоступен для реальных аккаунтов — тестировать после включения OAuth или
   добавить legacy-вход в оболочку (ZCODE).
4. Push: VAPID на staging настроен, публичный HTTPS есть → подписка возможна
   после аутентификации.