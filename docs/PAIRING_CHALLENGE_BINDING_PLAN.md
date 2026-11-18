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

Требуется явное «согласовано» на изменение pairingText/registry (п. 3.1–3.4)
и выбор политики cutoff v1. До согласования действует UI-митигация 4ba238c:
pairing безопасен только при осознанном сравнении отпечатков пользователем.