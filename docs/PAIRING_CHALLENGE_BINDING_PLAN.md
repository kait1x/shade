# Pairing: включение challenge в подписываемые данные — план (на согласование)

Статус: **ПРЕДЛОЖЕНИЕ, не реализовано**. Изменение криптографического
протокола требует явного согласования владельца (инструкция интеграции,
п. 6). Основание: High-замечание независимого security review интеграции
4ba238c (docs/MULTIDEVICE_SYNC_PLAN.md §8.1).

## 1. Проблема (подтверждена аудитом)

`pairingText(account, device, nonce, expiresAt)` (client/web/protocol/
device-v2.mjs) НЕ включает challenge. Подпись нового устройства над offer
валидна при любой подмене `offer.challenge`. Атакующий, знающий актуальный
challenge (фишинг/подмена канала), может изготовить собственный RSA-4096
device и валидно подписанный offer с аккаунтом жертвы; все криптографические
проверки пройдут. Текущая митигация — UI-сравнение отпечатков на двух
экранах (4ba238c) — защищает только при осознанном сравнении пользователем.

## 2. Цель

Криптографически привязать offer к одноразовому challenge доверенного
устройства: подмена challenge или ключей устройства инвалидирует подпись.
Совместимое обновление клиента и сервера без flag-day и без миграции данных.

## 3. Дизайн (аддитивный, версионированный)

1. **Новая функция `pairingTextV2`** в device-v2.mjs: доменно-разделённый
   префикс `shade-pair-v2` + канонический JSON `{account, device, nonce,
   expiresAt, challenge}` (challenge — 30 hex, как сейчас). Старая
   `pairingText` (v1) остаётся байт-в-байт: golden-векторы interop и Dart-порт
   не затрагиваются.
2. **Offer v2**: новый префикс `shade-pair-v2:` (старый `shade-pair-v1:`
   читается). Поля те же; подпись строится над `pairingTextV2`.
   `buildPairingOffer`/`verifyPairingOffer` (pairing.mjs) переходят на v2;
   decode принимает обе версии, verify для v1 сохраняет текущее поведение
   (с документированным остаточным риском) до cutoff.
3. **Сервер (registry.mjs, update/install)**: проверка possession proof
   принимает подпись над v1 ИЛИ v2 текстом (аддитивная ветка verify).
   Если proof заявляет v2 (новое опциональное поле `pairingVersion: 2` в
   payload install), сервер требует v2-текст и отклоняет downgrade на v1.
   Значение challenge серверу неизвестно и не нужно: он проверяет, что
   новое устройство подписало ИМЕННО тот challenge, который проверил
   доверенный клиент (challenge echo уже сверяется доверенным клиентом).
4. **Доверенный клиент (alpha-client.mjs approvePairing)**: для v2-offer
   строит proof над pairingTextV2 с тем же challenge, что показан на экране;
   `reviewPairingOffer` для v2 требует валидную подпись над v2-текстом
   (подмена challenge ломает подпись). Для v1-offer — текущее поведение.
5. **Новое устройство (completePairing)**: без изменений (confirmation —
   routing hint, доверие строится из серверного каталога).
6. **Cutoff**: после обновления всех клиентов владелец может запретить v1
   proof конфигурацией сервера (например `ALPHA_PAIRING_V1=off`); до этого
   окна старые offline-оболочки (SW-кеш) продолжают работать с v1 и несут
   документированный остаточный риск. Окно и решение — за владельцем.

## 4. Совместимость и объём

- Форматы vault, manifest, genesis, snapshot, IndexedDB — без изменений.
- Android: Dart-клиент pairing не реализован → правок Dart нет; при будущей
  реализации использовать сразу v2. `device_v2` interop golden-векторы (v1)
  не меняются и должны пройти без правок.
- Файлы: client/web/protocol/device-v2.mjs (+pairingTextV2),
  client/web/pairing.mjs (v2 encode/decode/sign/verify),
  client/web/alpha-client.mjs (approve/review v2),
  server/multidevice/registry.mjs (аддитивная verify-ветка + downgrade-
  protection), тесты server/test/pairing.test.mjs и новые негативы,
  browser QA pairing-секция (v2 flow).
- Оценка: 1 согласованная итерация + полный прогон Server/Flutter/QA/interop.

## 5. Обязательные тесты

1. Мутация `offer.challenge` без пересчёта подписи → отклонение (v2).
2. Подмена ключей device при том же challenge → невалидная подпись (v2).
3. v1-offer против v2-сервера: принимается до cutoff, отклоняется после.
4. Downgrade: proof v2-заявленный, но подпись v1 → отклонение.
5. Полный flow v2: challenge → offer → approve → install → confirmation →
   fanout E2EE (browser QA, оба движка).
6. Replay/истечение/TTL/слабый RSA — существующие негативы сохраняются.
7. Interop golden-векторы v1 и Dart-порт — без изменений, PASS.

## 6. Что НЕ входит

- Отображение genesis-отпечатка (TOFU) на новом устройстве — отдельная
  малая UI-задача (рекомендация аудита §8.2).
- Идемпотентная выдача confirmation после committed install (Medium §8.3)
  и классификация vault без state (Medium §8.4) — отдельные задачи.
- Перенос истории и recovery-сессия — планы MULTIDEVICE_SYNC_PLAN §5.

## 7. Решение владельца

Согласовано владельцем 18.11.2026 («план концептуально согласован, реализовывать
отдельно от staging-релиза, с полным набором негативов и проверкой
совместимости; пока не деплоить»). Реализовано в ветке
`pairing-challenge-binding` (см. §8). Staging-релиз `v2-glm-integration`
(cb376c1) НЕ содержит этих изменений и не деплоится с ними.

## 8. Реализация (ветка pairing-challenge-binding)

Отклонения/уточнения относительно концептуального плана:

1. **Домен-тег подписываемого текста — `shade-pair:v3`** (функция
   `pairingTextV2`), а не `shade-pair-v2`: тег `shade-pair:v2` уже занят
   существующим unbound-текстом (`pairingText`, байт-в-байт не изменён).
   Wire-префикс offer — `shade-pair-v2:` как в плане; поле `v: 2`; префикс и
   версия обязаны совпадать при decode.
2. **Proof клиента**: для v2-offer approvePairing отправляет
   `{id, nonce, expiresAt, signature, challenge, pairingVersion: 2}`; для
   v1-offer — legacy-форма без этих полей.
3. **Сервер (registry.update)**: `pairingVersion === 2` → verify над
   `pairingTextV2` с проверкой формата challenge (30 hex); иначе legacy-форма
   обязана быть без `pairingVersion`/`challenge` (ambiguous → reject) и
   проверяется над v1-текстом. Downgrade (заявлен v2, подпись v1) отклоняется.
4. **Cutoff**: опция `createDeviceRegistry({pairingV1})` (env
   `ALPHA_PAIRING_V1=off` в alpha.mjs, по умолчанию окно открыто). Cutoff
   запрещает v1-proof только при росте ростера (pairing approval UX);
   genesis-enrollment без доверенного устройства сохраняет v1-proof —
   иначе cutoff сломал бы регистрацию. Отдельного решения владельца о
   включении cutoff не требуется для деплоя: по умолчанию совместимость.
5. **UI**: плейсхолдер offer обновлён на v2; сравнение отпечатков сохранено
   как defense-in-depth.
6. **Тесты**: server/test/pairing-v2.test.mjs (9 тестов: round-trip v2,
   мутация challenge без пересчёта подписи, подмена ключей, v1-совместимость,
   prefix/version mismatch, TTL/weak-RSA, downgrade/ambiguous/malformed proof,
   cutoff genesis-exempt, полный v2-flow с session/directory/fanout);
   существующий pairing.test.mjs переведён на v2-proof клиента и остаётся
   зелёным (v1-webProof используется для genesis). Dart-порт
   (protocol.dart pairingText) и golden-векторы (generate_v2_vectors.mjs)
   не изменялись.
7. **QA**: alpha-browser-qa.mjs ожидает префикс `shade-pair-v2:`; полный
   pairing-сценарий прогоняется на обоих движках.