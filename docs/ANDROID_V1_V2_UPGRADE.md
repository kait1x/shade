# Shade Android: обновление v1 → v2 поверх существующей установки

Проверено по фактическим артефактам 17.11.2026 (keytool/apksigner/aapt2).

## 1. Факты

| Параметр | Значение | Источник |
|---|---|---|
| applicationId | `com.example.shade` (одинаков у v1 и v2) | `client/android/app/build.gradle.kts` |
| versionCode / versionName | было `1 / 1.0.0`; **поднято до `2 / 2.0.0`** | `client/pubspec.yaml` |
| Release-подпись | `CN=Shade Android Release`, SHA-256 `d790f976…104edf` | apksigner по `artifacts/builds/shade-release.apk` и `shade-vps-2026-11-15-arm64.apk` (совпадают) |
| Release-ключ | `client/android/shade-release.jks` + `key.properties` (в основном checkout, gitignored) | наличие подтверждено; пароли не читались |
| Подпись на тестовом Galaxy A31 | **`CN=Android Debug`** (debug.keystore этой машины) | keytool по `artifacts/ui-ux-2/installed.apk` |
| Локальная БД | SQLCipher `shade.db`, schema v9 → **v10** (аддитивно) | `database_service.dart` |
| Ключ БД | `sqlcipher_db_key` в EncryptedSharedPreferences (Keystore), PBKDF2 2.1M + device salt | `database_service.dart` |
| Приватный RSA | secure storage (`_privKeyAlias`), RSA-4096 | `crypto_service.dart` |
| Сессия v1 | SharedPreferences + refresh | `auth_notifier.dart` |

## 2. Вывод об обновляемости

- **Release v1 → Release v2**: обновляется поверх (тот же applicationId, тот же
  release-ключ, versionCode 2 > 1). Данные, ключи и сессия сохраняются.
- **Debug v1 → Release v2**: НЕ обновляется поверх — разные подписи. Это уже
  наблюдалось на A31 (release-обновление отклонено, удаление не выполнялось).
- **Debug v1 → Debug v2** (тот же `~/.android/debug.keystore`): обновляется
  поверх; данные сохраняются. Пригодно для тестовых устройств, не для релиза.

## 3. Безопасные пути перехода

### Путь A (рекомендуемый для реальных release-пользователей)
1. Собрать v2 release тем же ключом:
   ```powershell
   # key.properties и shade-release.jks должны быть в client/android (из основного checkout)
   cd client
   flutter build apk --release --target-platform android-arm64 `
     --dart-define-from-file=config/production.json
   ```
   `production.json` содержит адрес сервера и fingerprint; для v2 дополнительно
   `--dart-define=ALPHA_GOOGLE_CLIENT_ID=<Web client ID>` при тестировании
   против staging.
2. Проверить подпись собранного APK:
   `apksigner verify --print-certs <apk>` → SHA-256 должен совпасть с
   `d790f976…104edf`.
3. Установить поверх: `adb install -r <apk>` (или раздать APK пользователям).
4. Приложение открывает ту же SQLCipher-БД (миграция v9→v10 аддитивная),
   тот же RSA и сессию. Пользователь продолжает работать в v1-режиме, пока
   аккаунт не переведён; затем — явный переход в «Устройства (v2)».

### Путь B (тестовое устройство с debug-подписью, напр. A31)
- Вариант B1: собрать v2 **debug** тем же debug.keystore и установить поверх —
  данные сохраняются, сценарий миграции проверяется на реальных данных устройства.
- Вариант B2 (переход на release): только через экспорт/импорт или переустановку.
  Переустановка **удаляет** локальную БД и ключи → потеря истории и идентичности,
  если нет recovery. Поэтому: сначала выполнить enrollment v2 и сохранить
  recovery-пакет, затем чистая установка release, вход тем же аккаунтом
  (legacy-key proof невозможен без старого ключа — потребуется Google-привязка
  или pairing с другого устройства). **Без recovery/второго устройства этот путь
  ведёт к потере доступа к аккаунту — не выполнять без подготовки.**

## 4. Локальная миграция и восстановление после сбоя

- Схема БД версионируется (`_dbVersion`, `_onUpgrade`): v10 добавляет только
  `v2_enrollment_journal`; v1-таблицы, ключи и история не переписываются.
- Enrollment v2 (`repository.dart enrollLegacy`):
  1. Recovery-пакет + подписанные genesis/manifest пишутся в журнал **до** сети.
  2. Сетевой вызов; при потере ответа/сбое — повтор перенимает серверный каталог
     (resume), не создаёт второй genesis и не теряет recovery.
  3. Локальный аккаунт сохраняется, журнал удаляется. Старое хранилище не
     удаляется ни на каком этапе.
- Ключи: исходный RSA остаётся `primary`; новый recovery-ключ независим.
  Автоматическая регенерация идентичности при ошибках запрещена.
- Secure Storage / Keystore: ключ БД и RSA не экспортируются и не меняются;
  при недоступности secure storage клиент отказывается работать, а не
  пересоздаёт ключ.

## 5. Чек-лист перед раздачей обновления

- [x] Подпись v2 release APK совпадает с v1 release-эталоном (apksigner,
      17.11.2026): `artifacts/v2-release/shade-v2-arm64-release.apk`,
      SHA-256 `d790f9763fbc4bb33a87b0d530c5738d9d3aabcaaebb7ef5b67a099745104edf`
      = эталон `shade-vps-2026-11-15-arm64.apk`. На установленном A31 —
      DEBUG-подпись (release поверх не встанет, см. §2–3).
- [x] versionCode > установленного release (2 > 1), versionName 2.0.0,
      applicationId com.example.shade (aapt2 badging).
- [x] `flutter analyze` 0 errors/0 warnings; `flutter test` 134/134 (17.11.2026).
- [ ] Обновление поверх проверено на тестовом устройстве (adb install -r),
      история/ключи/сессия на месте.
- [ ] Enrollment + recovery-пакет проверены; recovery сохранён вне устройства.
- [ ] Для debug-устройств выбран путь B1/B2 осознанно.

## 6. Не проверено

- Физическая установка release v2 поверх release v1 на реальном пользовательском
  устройстве (тестовый A31 имеет debug-подпись).
- Физический iPhone/PWA (см. `docs/PHYSICAL_DEVICE_TEST_PLAN.md`).
- Поведение Keystore при OTA-обновлении Android на конкретных OEM.