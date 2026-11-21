# Аудит готовности нативного Android к v2 (20.11.2026, lead лично)

Проверено по коду staging-линии (092f1fb), не по отчётам. Два сабагент-аудита
умерли/зависли без отчёта — аудит выполнен lead targeted-инспекцией.

## Что УЖЕ есть (переиспользуется без изменений контрактов)
- `client/lib/core/services/device_v2/`: crypto.dart, payload.dart, protocol.dart,
  repository.dart, store.dart, transport.dart — полный протокольный стек.
- transport.dart операции: session, legacyChallenge/legacySession,
  loginWithGoogleIdToken, register, **legacyEnrollment**, rotationChallenge/
  legacyRotation, operation, fetch, send, ack, status — контракт 1:1 с alpha.mjs.
- repository.dart: **enrollLegacy** с crash-safe journal, идемпотентностью,
  сохранением recovery-ключа и БЕЗ удаления SQLCipher v1 («старое хранилище не
  удаляется»); снимок genesis/history/checkpoint для UI.
- Крипта межстеково проверена: device_crypto_interop_test, alpha-native interop,
  device_v2_migration_test (rotation RSA-2048→4096, crash-resume journal).
- Общие UI-виджеты (MessageBubble, MessageInput, AvatarView, тема) платформо-
  нейтральны и переиспользуемы.

## Реальные гэпы (блокеры полноценного нативного v2)
1. **Entry point не переключён**: main_native.dart = v1-приложение (ShadeApp,
   Riverpod v1, Firebase). device_v2-стек не подключён к нативному entry.
   Размер: средний (проводка) + решение D2 по UI-стратегии.
2. **Нативного v2 UI нет**: features/* живут на v1 API. Варианты D2:
   (a) Dart-UI поверх v2 repository с переиспользованием виджетов (чисто, долго);
   (b) WebView-обёртка PWA на Android (быстро, но push/нативные интеграции хуже);
   (c) адаптер v1-UI → v2-транспорт (средне, риск рассинхрона контрактов).
   Рекомендация lead: (a) для продакшена; (c) допустим как мост закрытой беты.
3. **Экраны pairing/approve/recovery/devices в нативе отсутствуют** (в features
   нет соответствующих dart-файлов). Контракты готовы (pairing.mjs JSON
   платформо-нейтрален; recovery-сессия сервер+PWA готовы). Размер: средний каждый.
4. **Импорт локальной истории SQLCipher→v2 vault при enrollment не реализован**
   (repository сохраняет v1-хранилище, но не перешифровывает историю в v2).
   Требование владельца «сохранение локальной истории» → нужен импорт. Средний.
5. **v2-APK не подтверждён**: app-release.apk от 18.11 собран default-target
   (v1); README-команда apk без --target. Нужен явный v2-target + signing
   (key.properties у владельца). Малый после п.1-2.
6. history.transfer (новые устройства) и receipts pruning — серверные задачи
   плана перехода (§5.2/§5.3 SYNC_PLAN), средние.

## Вывод
Протокольная база нативного v2 ГОТОВА и проверена тестами; не хватает UI-слоя,
проводки entry, экранов pairing/recovery и импорта истории. Это «последняя миля»,
а не переписывание. Порядок: pairing/approve/recovery экраны (контракты готовы) →
импорт истории → D2-проводка entry+UI → v2-APK → физические QA.