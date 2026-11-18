# Staging-релиз 4ba238c: подготовка и процедура переключения

Статус: **подготовлено, НЕ переключено**. Переключение выполняет владелец
после явного подтверждения. Production v1 не затрагивается ни одним шагом.

Релиз: ветка `v2-glm-integration`, runtime-код server/client зафиксирован
коммитом `4ba238ca1b636fafc16c858ebd2013a77cf7b87e` (база 9a94fb0 + b9a101f
onboarding/PRF + 6347782 pairing); поверх — только deploy/docs-артефакты
подготовки релиза. Точный commit упаковки записан в `MANIFEST.meta`
(на момент подготовки: `fac01e0e522a…`, сверяйте с meta). SW-версия оболочки
`8b648d1d131aa57e14d7`. Stamp релиза: `20261118-122400` (зашит в
`admin-update-v2-glm.sh`).

Проверки на этом commit: server 98/98, Flutter 139/139 (analyze 0
errors/warnings), Edge QA PASS + WebKit QA PASS (pairing=true, 0 ошибок
страницы), interop 2/2 focused. Криптопротокол не менялся.

## 1. Состав upload-пакета

`build/staging-upload/` (генерируется `deploy/staging/package-upload.ps1`):

- `server/` — исходники alpha (mjs/js/json + multidevice/, tools/, test/),
  package.json + package-lock.json для `npm ci`. Без node_modules, data,
  .env, сертификатов, build-артефактов.
- `client/web/` — alpha-оболочка (включая device_binding.mjs,
  recovery-words.mjs, pairing.mjs).
- `client/build/web-alpha/` — собранный Flutter UI + cache-files.js
  (SW digest покрывает все новые модули).
- `MANIFEST.sha256` — чистый checksum-формат (`sha256sum -c`), покрывает
  каждый файл server/ + client/; `MANIFEST.meta` — commit/branch/generated/
  sw_version/files (метаданные отдельно, как в релизе 20261117-225500+).
- Шаблоны и скрипты: `shade-staging.service`, `Caddyfile.staging-block`,
  `staging.env.example`, `staging-deploy.sh` (НЕ использовать: старое
  именование shade-alpha), `smoke-staging.sh`, `admin-update-v2-glm.sh`,
  `make-manifest.py`, `README.txt`.

Секреты в пакет не попадают: package-upload.ps1 вычищает .env/.pem/.key/
.crt/.enc/.jks/production.json/google.local.json и проверяет отсутствие
secret-like файлов; staging.env.example содержит только REPLACE_WITH-
плейсхолдеры. Реальные секреты staging уже существуют на сервере
(`/var/lib/shade-staging/staging.env`) и не перезаписываются.

## 2. Локальный просмотр (рабочая машина, до загрузки)

```pwsh
cd C:\Users\Kait1x\Documents\Shade\.agents\worktrees\v2-glm-integration
git log --oneline -4                      # 4ba238c, cc725cd, fddd396, b9a101f
git show 4ba238c --stat                   # UI-митигация security review
Get-Content deploy\staging\admin-update-v2-glm.sh
Get-Content build\staging-upload\MANIFEST.meta
Get-Content build\staging-upload\README.txt
# локальная сверка MANIFEST (python):
python -c "import hashlib,pathlib,sys; pkg=pathlib.Path('build/staging-upload'); bad=[l.split('  ',1)[1] for l in (pkg/'MANIFEST.sha256').read_text().splitlines() if hashlib.sha256((pkg/l.split('  ',1)[1]).read_bytes()).hexdigest()!=l.split('  ',1)[0]]; print('MISMATCH:',bad) if bad else print('MANIFEST OK')"
```

## 3. Загрузка на VPS (владелец)

```bash
# с рабочей машины (OpenSSH scp; каталог пакета целиком):
scp -r "C:\Users\Kait1x\Documents\Shade\.agents\worktrees\v2-glm-integration\build\staging-upload" <VPS>:/root/shade-staging-upload-20261118-122400
```

## 4. Инспекция текущего состояния VPS (root, read-only)

```bash
readlink -f /opt/shade-staging/current                 # текущий релиз (ожидается 20261118-005500 или 20261117-225500)
ls -la /opt/shade-staging/releases/                    # прежние релизы на месте (откат)
systemctl cat shade-staging --no-pager                 # ExecStart=current/server, EnvironmentFile=/var/lib/shade-staging/staging.env
systemctl is-active shade-staging shade caddy
stat -c '%a %U:%G %n' /var/lib/shade-staging/staging.env   # 600/640, без вывода содержимого
grep -c 'REPLACE_WITH' /var/lib/shade-staging/staging.env || true   # 0 = плейсхолдеров нет
grep -q 'alpha.shadechat.ru' /etc/caddy/Caddyfile && echo 'staging Caddy block present'
# production v1 ДО переключения:
systemctl is-active shade caddy
curl -fsS -m 5 http://127.0.0.1:3000/api/health; echo
```

Внимание: шаблон `staging.env.example` в заголовке упоминает
`/etc/shade-staging/staging.env` — фактический путь задаёт systemd-юнит:
`/var/lib/shade-staging/staging.env`. Сверьте `systemctl cat` и не создавайте
второй env-файл.

## 5. Подготовка нового релиза (root + shade-staging)

```bash
STAMP=20261118-122400
UP=/root/shade-staging-upload-$STAMP
REL=/opt/shade-staging/releases/$STAMP
install -d -m 755 -o shade-staging -g shade-staging "$REL"
cp -a "$UP/server" "$REL/server"
cp -a "$UP/client" "$REL/client"
cp -a "$UP/MANIFEST.sha256" "$UP/MANIFEST.meta" "$REL/"
# зависимости от shade-staging (не root):
sudo -u shade-staging bash -c "export PATH=/opt/node/bin:\$PATH; cd $REL/server && npm ci --omit=dev --no-audit --no-fund --loglevel=error"
node --check "$REL/server/alpha.mjs"
# верификация MANIFEST до переключения (fail-closed):
(cd "$REL" && sha256sum -c MANIFEST.sha256 --quiet) && echo 'MANIFEST OK'
grep '^commit:' "$REL/MANIFEST.meta"
# commit-binding: runtime-код пакета должен совпадать с 4ba238c:
# на рабочей машине: git diff <commit из MANIFEST.meta> 4ba238c -- server client
# ожидается пустой diff (после 4ba238c менялись только deploy/ и docs/).
# hardening после установки зависимостей:
chown -R root:root "$REL"
chmod -R go-w "$REL"
# скрипт переключения:
cp "$UP/admin-update-v2-glm.sh" /opt/shade-staging/admin-update-v2-glm.sh
chmod 755 /opt/shade-staging/admin-update-v2-glm.sh
```

Данные staging (`/var/lib/shade-staging/data`, checkpoints) не трогаются:
формат снапшота и IndexedDB-схемы клиентов в этом релизе не менялись.
Caddy не меняется (блок alpha.shadechat.ru уже существует).

## 6. Переключение (только после подтверждения владельца)

```bash
bash /opt/shade-staging/admin-update-v2-glm.sh
```

Скрипт: проверит MANIFEST по checksum (fail-closed), commit-binding,
синтаксис, наличие env; переключит symlink; рестартует shade-staging;
проверит health loopback:3101 + https://alpha.shadechat.ru, googleConfigured,
SW-версию; проверит production (shade/caddy active, v1 health :3000,
ExecStart production-юнита); напечатает команду отката. При любой ошибке
trap ERR печатает откат. Ожидается `UPDATE_DONE`.

## 7. Проверки после переключения

```bash
bash /opt/shade-staging/smoke-staging.sh https://alpha.shadechat.ru   # read-only, ожидается SMOKE_OK
curl -fsS https://alpha.shadechat.ru/flutter-ui/cache-files.js | head -1
# ожидается SHADE_UI_VERSION = "8b648d1d131aa57e14d7"
systemctl is-active shade caddy shade-staging
curl -fsS -m 5 http://127.0.0.1:3000/api/health; echo   # production v1 жив
```

Браузерно (владелец): https://alpha.shadechat.ru → вход Google → онбординг
(никнейм → ключи → recovery-пакет) → чат; обновление SW-оболочки через
диалог «Доступно обновление Shade» (ключи/история не затрагиваются).

## 8. Откат (всегда доступен)

```bash
ln -sfn /opt/shade-staging/releases/<предыдущий stamp> /opt/shade-staging/current
systemctl restart shade-staging
curl -fsS -m 5 http://127.0.0.1:3101/api/health
```

Предыдущие релизы не удаляются. Данные staging совместимы в обе стороны
(формат не менялся). Откат не затрагивает production.

## 9. Гарантии изоляции production v1

- Все шаги пишут только в `/opt/shade-staging`, `/root/shade-staging-upload-*`
  и рестартуют `shade-staging`. `/var/lib/shade`, `/etc/shade`, `shade.service`,
  production-блок Caddy не изменяются.
- `staging-deploy.sh` из пакета НЕ используется (старое именование
  shade-alpha, создание сервиса и merge Caddy — не нужно для обновления).
- Контроль production до и после: `systemctl is-active shade caddy` +
  `curl http://127.0.0.1:3000/api/health` + браузерная проверка production-
  домена владельцем.

## 10. После развёртывания: реальные устройства

- iPhone: чеклист PRF/pairing/durability из итогового отчёта интеграции
  (docs/PRF_BINDING_PLAN.md §5, docs/PHYSICAL_DEVICE_TEST_PLAN.md S1–S7,
  G1–G3); pairing — осознанное сравнение отпечатков на двух экранах.
- Galaxy A31: установленная APK от 9a94fb0 НЕ содержит изменений этого
  релиза. Для Android↔PWA тестов на новом backend APK пересобрать из
  4ba238c (подпись debug совпадает с установленной → обновление поверх с
  сохранением данных); pairing-роль Android пока не реализована в Dart.