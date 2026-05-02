# 🌑 Shade — Secure Messenger Source Code (White-Label)

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart)](https://dart.dev)
[![Node.js](https://img.shields.io/badge/Node.js-Express-339933?logo=node.js)](https://nodejs.org)
[![Socket.IO](https://img.shields.io/badge/Socket.IO-4.8-blue)](https://socket.io)
[![Commercial License](https://img.shields.io/badge/License-Commercial-red)](#-условия-продажи)
[![Ready for Deployment](https://img.shields.io/badge/Status-Production--Ready-green)](#-готовность-к-запуску-и-деплою)

---

## 💼 О продукте

**Shade** — готовый к продаже white-label мессенджер корпоративного уровня с сквозным шифрованием (E2EE). Проект представляет собой полностью функциональное решение для безопасной коммуникации, включающее клиентские приложения под Android/iOS/Desktop и сервер ретрансляции сообщений.

Архитектура построена по принципу **zero-knowledge**: сервер не имеет доступа к содержимому переписки, ключи шифрования никогда не покидают устройство пользователя. Продукт готов к немедленному развёртыванию под собственным брендом заказчика.

**Ключевые характеристики:**
- Гибридное шифрование RSA-4096 + AES-256-GCM
- Защищённое хранение ключей в Keystore/Keychain
- SQLCipher для локальной базы данных (мобильные платформы)
- WebSocket-коммуникация в реальном времени
- Push-уведомления через Firebase Cloud Messaging
- Встроенная защита от скриншотов и записи экрана (Android)
- Административная панель с мониторингом и управлением пользователями

---

## 📦 Что входит в продажу

### Клиентская часть (Flutter)
| Компонент | Описание |
|-----------|----------|
| `lib/core/services/crypto_service.dart` | Служба криптографии: генерация RSA-4096, гибридное шифрование AES-256-GCM, цифровые подписи RSA-PSS-SHA256 |
| `lib/core/database/database_service.dart` | Работа с encrypted SQLite (SQLCipher на мобильных, FFI на десктопах) |
| `lib/core/services/connection_service.dart` | HTTP + WebSocket клиент с certificate pinning, авто-реконнектом, потоками сообщений |
| `lib/core/services/notification_service.dart` | Интеграция Firebase Messaging + локальные уведомления |
| `lib/services/security_service.dart` | Platform channel для FLAG_SECURE (защита от скриншотов) |
| `lib/features/auth/` | Модуль аутентификации: регистрация, генерация ключей, управление сессией |
| `lib/features/chats/` | Экраны чатов, список контактов, отправка/получение сообщений |
| `lib/features/home/` | Главный экран, поиск пользователей, навигация |
| `lib/core/routing/app_router.dart` | Маршрутизация на базе go_router |
| `test/crypto_service_test.dart` | Набор unit-тестов для проверки криптографических функций |

### Серверная часть (Node.js)
| Компонент | Описание |
|-----------|----------|
| `server/server.js` | Express + Socket.IO сервер ретрансляции |
| `server/gen-certs.sh` / `gen-certs.bat` | Скрипты генерации TLS-сертификатов (OpenSSL) |
| `server/.env` | Конфигурационный файл с переменными окружения |
| Встроенный Dashboard | Веб-интерфейс администратора: статистика, пользователи, логи |
| REST API | Регистрация, получение публичных ключей, статус пользователей |
| WebSocket Events | message, typing, read, delivered, deleteMessage, statusUpdate |

### Конфигурация и зависимости
| Файл | Назначение |
|------|------------|
| `client/pubspec.yaml` | Зависимости Flutter (Flutter Riverpod, encrypt, fast_rsa, sqflite_sqlcipher, firebase_messaging) |
| `server/package.json` | Зависимости Node.js (express, socket.io, firebase-admin, cors, express-rate-limit) |
| `client/android/`, `client/ios/` | Нативные платформы с настроенными конфигурациями |
| `.github/workflows/` | CI/CD pipeline для сборки Android и iOS |

---

## 🔐 Безопасность и архитектура (на основе реального кода)

### Криптографический стек

**Генерация ключей:**
```dart
// crypto_service.dart:42
final kp = await RSA.generate(4096);
```
- RSA-4096 бит для асимметричного шифрования
- Ключи хранятся во FlutterSecureStorage (Android Keystore / iOS Keychain)
- Резервное файловое хранилище для desktop-платформ

**Гибридное шифрование сообщений:**
```dart
// crypto_service.dart:63-93
// 1. Генерация случайного AES-256 ключа (32 байта) + nonce (12 байт)
// 2. AES-256-GCM шифрование контента
// 3. RSA-OAEP-SHA256 шифрование конверта (ключ + nonce)
// 4. Формат: {"k": "<encrypted key>", "d": "<encrypted data+tag>"}
```

**Цифровые подписи:**
```dart
// crypto_service.dart:151-182
// RSA-PSS-SHA256 подпись данных
await RSA.signPSS(dataB64, Hash.SHA256, SaltLength.AUTO, privateKey);
await RSA.verifyPSS(signature, dataB64, Hash.SHA256, SaltLength.AUTO, publicKey);
```

**Защита базы данных:**
```dart
// database_service.dart:66-75
// SQLCipher с паролем из secure storage
final key = await _getOrCreateKey(); // 32-byte random key
return sqlcipher.openDatabase(filePath, password: key, ...);
```

### Сетевая безопасность

| Механизм | Реализация |
|----------|------------|
| TLS 1.2+ | Минимальная версия TLS явно указана в server.js:44 |
| Certificate Pinning | SHA-256 fingerprint через `--dart-define=SHADED_PIN_SHA256` |
| CORS Protection | Строгий whitelist ALLOWED_ORIGINS |
| Rate Limiting | 100 запросов/15 мин (API), 5 попыток/15 мин (auth) |
| Security Headers | HSTS, X-Frame-Options, CSP, X-Content-Type-Options |
| Session Tokens | HMAC-SHA256 подписанные токены с временем жизни 24 часа |

### Защита на уровне ОС

```dart
// security_service.dart + main.dart:43
await SecurityService.enableSecureMode(); // FLAG_SECURE на Android
```
- Блокировка скриншотов и записи экрана
- Исключение из превью многозадачности (Recent Apps)
- Размытие контента при переключении приложений (iOS)

---

## 🛠 Автоматически определённый стек

### Клиент (Flutter)
| Категория | Пакет | Версия |
|-----------|-------|--------|
| **Фреймворк** | Flutter SDK | >=3.0.0 <4.0.0 |
| **State Management** | flutter_riverpod | ^2.6.1 |
| **Навигация** | go_router | ^14.8.1 |
| **Криптография** | encrypt | ^5.0.3 |
| | pointycastle | ^3.7.3 |
| | fast_rsa | ^3.8.6 |
| | crypto | ^3.0.3 |
| **Безопасное хранение** | flutter_secure_storage | ^9.2.2 |
| **База данных** | sqflite_sqlcipher | ^3.1.0+1 |
| | sqflite_common_ffi | ^2.3.4+4 |
| **Сеть** | http | ^1.2.2 |
| | socket_io_client | ^2.0.3+1 |
| **Push-уведомления** | firebase_core | ^3.12.1 |
| | firebase_messaging | ^15.2.4 |
| | flutter_local_notifications | ^18.0.1 |
| **Работа с файлами** | path_provider | ^2.1.5 |
| | image_picker | ^1.0.7 |
| | gal | ^2.3.0 |
| | image | ^4.1.3 |
| **Утилиты** | shared_preferences | ^2.2.2 |
| | device_info_plus | ^11.2.0 |
| | permission_handler | ^11.3.1 |

### Сервер (Node.js)
| Категория | Пакет | Версия |
|-----------|-------|--------|
| **Фреймворк** | express | ^4.21.0 |
| **WebSocket** | socket.io | ^4.8.3 |
| **Firebase Admin** | firebase-admin | ^13.8.0 |
| **Безопасность** | cors | ^2.8.6 |
| | express-rate-limit | ^8.3.2 |
| **Конфигурация** | dotenv | ^17.4.2 |

### Архитектурные паттерны
- **Clean Architecture** с разделением на features/core/services
- **Repository Pattern** для доступа к данным
- **Provider/Riverpod** для управления состоянием
- **Event-driven WebSocket** коммуникация
- **Hybrid Encryption** (асимметричное + симметричное)

---

## ⚡ Готовность к запуску и деплою

### Требования к окружению

**Клиент:**
- Flutter SDK 3.x
- Android SDK (для сборки APK/AAB)
- Xcode 15+ (для сборки iOS)
- Firebase проект с настроенным FCM (опционально для push)

**Сервер:**
- Node.js 18+
- OpenSSL (для генерации TLS-сертификатов)
- PM2 или systemd для production-развёртывания

### Быстрый старт

```bash
# 1. Сервер
cd server
npm install
bash gen-certs.sh  # или gen-certs.bat для Windows
export DASHBOARD_PASS="your_secure_password"
npm start

# 2. Клиент
cd client
flutter pub get
flutter run --release
```

### Production Checklist

- [ ] Заменить self-signed сертификаты на Let's Encrypt / коммерческие
- [ ] Настроить certificate pinning (`--dart-define=SHADED_PIN_SHA256`)
- [ ] Изменить `ALLOWED_ORIGINS` в .env
- [ ] Настроить Firebase проект и заменить `google-services.json` / `GoogleService-Info.plist`
- [ ] Установить `NODE_ENV=production`
- [ ] Включить rate limiting в production
- [ ] Настроить резервное копирование директории `data/`

---

## 📈 Потенциал масштабирования

### Текущие возможности
- **In-memory хранилище** с персистентностью в JSON-файлы
- **Однопоточная архитектура** Node.js (горизонтальное масштабирование через load balancer)
- **WebSocket broadcast** для групповых чатов
- **Очереди офлайн-сообщений** с доставкой при подключении

### Точки расширения
1. **База данных**: замена JSON-хранилища на PostgreSQL/MongoDB/Redis
2. **Микросервисы**: выделение auth, messaging, notification в отдельные сервисы
3. **Kubernetes**: контейнеризация для оркестрации
4. **CDN**: выгрузка медиафайлов в объектное хранилище (S3-compatible)
5. **WebRTC**: добавление голосовых/видеозвонков
6. **Боты**: webhook API для интеграции внешних сервисов

---

## 💰 Условия продажи

### Лицензия
**Commercial License / Private Acquisition**

Покупатель получает:
- ✅ Полные права на исходный код
- ✅ Право на модификацию и форкинг
- ✅ Право на использование в коммерческих продуктах
- ✅ Право на перепродажу как white-label решение
- ✅ Исключительность (после продажи код снимается с реализации)

**Не включено:**
- ❌ Открытая публикация исходного кода (open-source)
- ❌ Право на сублицензирование без согласования
- ❌ Техническая поддержка после передачи (доступна отдельно)

### Формат передачи
1. Полный доступ к приватному Git-репозиторию
2. Передача прав на домен и инфраструктуру (по согласованию)
3. Документация по развёртыванию и архитектуре
4. One-time knowledge transfer session (опционально)

### Контакт для приобретения
Для обсуждения условий сделки, демонстрации функционала и получения доступа к коду свяжитесь напрямую с владельцем проекта.

---

**Shade Relay Server • E2EE • RSA-4096 + AES-256-GCM**
