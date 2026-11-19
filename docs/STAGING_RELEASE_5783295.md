# Staging-релиз 5783295 (challenge-binding): подготовка и переключение

Статус: **подготовлено, НЕ переключено**. Переключение выполняет владелец
после явного подтверждения. Production v1 не затрагивается ни одним шагом.
Только `alpha.shadechat.ru` (изолированный staging, порт 3101 loopback).

Релиз: commit `5783295` (ветка `pairing-challenge-binding`), содержит весь
объём предыдущего релиза cb376c1 (onboarding/PRF + pairing + UI-митигация)
плюс криптографическую привязку challenge (offer `shade-pair-v2:`).
SW-версия оболочки: `452edec1ece3d2d41c01`. Stamp релиза: `20261118-141500`
(зашит в `admin-update-challenge.sh`).

## 1. Проверки на этом commit (фактические)

- Server: **107/107** (включая 9 новых v2-негативов: мутация challenge без
  пересчёта подписи, подмена ключей, downgrade proof, ambiguous/malformed
  proof, cutoff genesis-exempt, полный v2-flow с fanout E2EE).
- Flutter: **139/139**; analyze 0 errors/warnings (info-deprecations SDK).
- Android↔Web interop: **2/2** focused + в полном наборе; Dart-порт
  `protocol.dart` и golden-векторы `generate_v2_vectors.mjs` не изменялись.
- Browser QA: **Edge PASS + WebKit PASS**, `pairing=true`, 0 ошибок страницы;
  push C6: Edge `subscribed`, WebKit честный отказ (нет push-сервиса в headless).
- OAuth: `server/auth-proof.js` не изменён; в `alpha.mjs` добавлена только
  опция `pairingV1` (cutoff). PKCE S256, state, nonce, fragment-handoff,
  redirect/allowlist — без изменений.
- Vault/E2EE/recovery/offline: `device_crypto.mjs`, `alpha-storage.mjs` не
  изменены — ciphertext/salt/iv/AAD/PBKDF2-600k и IndexedDB-схемы байт-совместимы.
- `device-v2.mjs`: только аддитивная `pairingTextV2` (тег `shade-pair:v3`);
  legacy `pairingText` (`shade-pair:v2`) байт-в-байт прежний.

## 2. Совместимость и cutoff

- Сервер принимает proof v1 (legacy) и v2 (challenge-bound). Новые web-клиенты
  шлют v2; старые offline-оболочки (SW-кеш) и Android native v2 продолжают
  работать с v1 до отдельного решения владельца о cutoff.
- Cutoff: `ALPHA_PAIRING_V1=off` в staging.env запрещает v1-proof при росте
  ростера; genesis-enrollment освобождён. **По умолчанию не включён**;
  staging.env этим релизом НЕ меняется.
- Данные staging (снапшоты, очереди, checkpoints) формат не меняют → откат
  на предыдущий релиз безопасен в обе стороны.

## 3. Состав upload-пакета

`build/staging-upload/` (генерируется `deploy/staging/package-upload.ps1`):
server/ (исходники + package*.json, без node_modules/data/.env/сертификатов),
client/web/, client/build/web-alpha/, `MANIFEST.sha256` (чистый checksum-формат,
покрывает каждый файл server/ + client/) + `MANIFEST.meta` (commit/branch/
generated/sw_version/files), шаблоны сервиса/Caddy/env, `smoke-staging.sh`,
`admin-update-challenge.sh`, `make-manifest.py`, README.txt.
Секреты в пакет не попадают (filename- и content-скан); реальные секреты
staging уже на сервере и не перезаписываются.

## 4. Локальный просмотр (рабочая машина)

```pwsh
cd C:\Users\Kait1x\Documents\Shade\.agents\worktrees\pairing-challenge-binding
git log --oneline -3
Get-Content deploy\staging\admin-update-challenge.sh
Get-Content build\staging-upload\MANIFEST.meta
python -c "import hashlib,pathlib; pkg=pathlib.Path('build/staging-upload'); lines=(pkg/'MANIFEST.sha256').read_text().splitlines(); bad=[l.split('  ',1)[1] for l in lines if hashlib.sha256((pkg/l.split('  ',1)[1]).read_bytes()).hexdigest()!=l.split('  ',1)[0]]; print('MISMATCH:',bad) if bad else print('MANIFEST OK:',len(lines),'files')"
```

## 5. Загрузка и инспекция VPS (root, read-only)

```bash
scp -r "C:\Users\Kait1x\Documents\Shade\.agents\worktrees\pairing-challenge-binding\build\staging-upload" <VPS>:/root/shade-staging-upload-20261118-141500
readlink -f /opt/shade-staging/current
ls -la /opt/shade-staging/releases/
systemctl cat shade-staging --no-pager
systemctl is-active shade-staging shade caddy
stat -c '%a %U:%G %n' /var/lib/shade-staging/staging.env
grep -c 'REPLACE_WITH' /var/lib/shade-staging/staging.env || true
grep -q 'alpha.shadechat.ru' /etc/caddy/Caddyfile && echo 'staging Caddy block present'
curl -fsS -m 5 http://127.0.0.1:3000/api/health; echo   # production v1 ДО
```

## 6. Подготовка нового релиза (без переключения)

```bash
STAMP=20261118-141500; UP=/root/shade-staging-upload-$STAMP; REL=/opt/shade-staging/releases/$STAMP
install -d -m 755 -o shade-staging -g shade-staging "$REL"
cp -a "$UP/server" "$REL/server"; cp -a "$UP/client" "$REL/client"
cp -a "$UP/MANIFEST.sha256" "$UP/MANIFEST.meta" "$REL/"
sudo -u shade-staging bash -c "export PATH=/opt/node/bin:\$PATH; cd $REL/server && npm ci --omit=dev --no-audit --no-fund --loglevel=error"
node --check "$REL/server/alpha.mjs"
(cd "$REL" && sha256sum -c MANIFEST.sha256 --quiet) && echo 'MANIFEST OK'
grep '^commit:' "$REL/MANIFEST.meta"
chown -R root:root "$REL"; chmod -R u+rwX,go+rX,go-w "$REL"
# Грабля 19.11: cp -a сохраняет режимы источника (scp с Windows даёт каталогам 700);
# одного go-w НЕ достаточно — shade-staging теряет вход в каталог (CHDIR Permission
# denied при старте юнита). go+rX возвращает чтение/вход без права записи.
cp "$UP/admin-update-challenge.sh" /opt/shade-staging/; chmod 755 /opt/shade-staging/admin-update-challenge.sh
```

Caddy не меняется (блок alpha.shadechat.ru уже существует). staging.env не
трогается. `/var/lib/shade`, `/etc/shade`, `shade.service` не затрагиваются.

## 7. Переключение — только после подтверждения владельца

```bash
bash /opt/shade-staging/admin-update-challenge.sh   # ожидается UPDATE_DONE
bash /opt/shade-staging/smoke-staging.sh https://alpha.shadechat.ru   # SMOKE_OK
curl -fsS https://alpha.shadechat.ru/flutter-ui/cache-files.js | head -1
# ожидается SHADE_UI_VERSION = "452edec1ece3d2d41c01"
```

Скрипт (fail-closed): до переключения — сверка MANIFEST по checksum, **точное
совпадение commit в MANIFEST.meta с EXPECTED_COMMIT** (подставляется при
упаковке = commit упаковки; нереплейснутый плейсхолдер = отказ), синтаксис,
наличие staging.env без REPLACE_WITH в Google client id/secret, наличие
каталога предыдущего релиза, baseline production v1 (is-active shade/caddy,
health :3000, ExecStart/EnvironmentFile юнита shade). После переключения —
health loopback:3101 + домен, **googleConfigured именно true**, **фактическая
SW-версия 452edec1ece3d2d41c01** в cache-files.js, сохранность каталога
предыдущего релиза, неизменность health и ExecStart/EnvironmentFile production.
Провал post-switch проверок = автоматический откат (одна попытка) с печатью
результата; деградация/изменение production = CRITICAL + exit 1 без автоотката
staging. Ручной откат печатается всегда; прежние релизы не удаляются.

## 8. Откат (всегда доступен)

```bash
ln -sfn /opt/shade-staging/releases/<предыдущий stamp> /opt/shade-staging/current
systemctl restart shade-staging
curl -fsS -m 5 http://127.0.0.1:3101/api/health
```

Прежние релизы не удаляются; данные совместимы в обе стороны.

## 9. После развёртывания: реальные устройства

Короткая инструкция iPhone/Galaxy A31 — в финальном сообщении сессии
(шаги 1–8 iPhone, 1–5 A31) и `docs/PHYSICAL_DEVICE_TEST_PLAN.md` (S1–S7,
G1–G3). Отдельно перечислены отсутствующие функции (перенос истории,
recovery-UI, Android-pairing, QR и др.). APK для A31 от 9a94fb0 не содержит
web-изменений релиза; native v2-протокол совместим, пересборка для паритета —
отдельное решение владельца.

## 10. Уточнения для физических тестов (A31 без Google, PRF fallback)

**Galaxy A31, Google-вход может быть недоступен** (нет GMS/Play Services,
не настроен Android OAuth-клиент или сборка без
`--dart-define=ALPHA_GOOGLE_CLIENT_ID`). Альтернативный путь без Google:
legacy-key сессия (`/api/v2/session/legacy-challenge` + `/session/legacy`)
и явная legacy-enrollment на экране «Устройства (v2)» исходным RSA-ключом
v1-аккаунта (ключи/SQLCipher/v1-история не заменяются; при RSA-2048 —
rotation до RSA-4096, crash-safe журнал). Условия: в staging настроена
read-only копия v1 (`ALPHA_V1_DATA_DIR`), т.е. `/api/health` показывает
`"legacyBridge":true`, и тестовый аккаунт существует в этой копии. Проверка
до теста: `curl -s https://alpha.shadechat.ru/api/health`. Если
`legacyBridge:false` и Google недоступен — Android не сможет авторизоваться
в этом staging; решение владельца: staging-копия v1 (только staging,
docs/V2_DEPLOYMENT.md §3) либо Google-способное устройство. Pairing-роль
Android в любом случае отсутствует (см. список отсутствующих функций).

**PRF fallback — точная семантика.** Fallback существует ТОЛЬКО на этапе
создания идентичности: при недоступности/ошибке PRF кнопка «Использовать
фразу устройства» переводит на фразу ≥16 символов (iOS ≤17 и не-PRF-браузеры
получают фразу автоматически по probe). Для уже PRF-привязанного vault фраза
устройства машинно-выводимая и пользователю неизвестна: поле фразы при
разблокировке скрыто, при утрате passkey/отмене биометрии показывается
честная ошибка, но фразового fallback и recovery-UI пока НЕТ — локальный
vault останется недоступным до реализации recovery-флоу. Рекомендация для
закрытого теста: на тестовых устройствах либо выбирать фразовый путь при
создании, либо тестировать PRF с сохранённым passkey и пониманием риска;
сценарий «удалил passkey» фиксировать как ожидаемую блокировку, не дефект.