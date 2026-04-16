# 🔍 Shade Messenger — Полный Аудит Безопасности

## 📋 Обзор Реализованного Функционала

### ✅ Что Уже Реализовано (Хорошо)

#### 1. **Криптография (E2EE)**
- RSA-2048 для обмена ключами
- AES-256-GCM для шифрования сообщений
- Подпись сообщений через RSA-PSS
- Верификация подписей при регистрации

#### 2. **TLS/HTTPS**
- Поддержка HTTPS с TLS 1.2+
- Автоматический редирект HTTP → HTTPS
- Настройка cipher suites (ECDHE+AESGCM, CHACHA20)
- Скрипты генерации самоподписанных сертификатов

#### 3. **Аутентификация**
- Session tokens на основе HMAC-SHA256
- Верификация токенов для WebSocket соединений
- Basic Auth для админ-панели

#### 4. **Защита Данных**
- Шифрование локальной БД (SQLCipher)
- Anti-screenshot на Android
- Хранение ключей только на устройстве

#### 5. **Push-уведомления**
- Firebase FCM интеграция
- Локальные уведомления как fallback
- Регистрация FCM токенов

---

## 🚨 КРИТИЧЕСКИЕ УЯЗВИМОСТИ (Must Fix)

### 1. ❌ Хардкод Пароля Администратора
**CWE-798: Hardcoded Credentials**

```javascript
// server.js:160
const DASHBOARD_PASS = process.env.DASHBOARD_PASS || 'shade2026';
```

**Проблема:** Пароль по умолчанию известен всем, кто видит код.

**Риск:** Полный доступ к админ-панели, удаление пользователей, утечка данных.

**Fix:**
```javascript
// Требовать переменную окружения, блокировать запуск без неё
const DASHBOARD_PASS = process.env.DASHBOARD_PASS;
if (!DASHBOARD_PASS) {
  console.error('ERROR: DASHBOARD_PASS environment variable is required');
  process.exit(1);
}
```

---

### 2. ❌ CORS Wildcard Origin
**CWE-942: Permissive Cross-domain Policy**

```javascript
// server.js:74, 82
cors: { origin: '*', methods: ['GET', 'POST'] }
app.use(cors({ origin: '*' }));
```

**Проблема:** Любой сайт может делать запросы к вашему API.

**Риск:** CSRF атаки, утечка данных через браузер жертвы.

**Fix:**
```javascript
const ALLOWED_ORIGINS = process.env.ALLOWED_ORIGINS?.split(',') || ['http://localhost:3000'];

app.use(cors({
  origin: (origin, callback) => {
    if (!origin || ALLOWED_ORIGINS.includes(origin)) {
      callback(null, true);
    } else {
      callback(new Error('Not allowed by CORS'));
    }
  },
  credentials: true,
  methods: ['GET', 'POST', 'DELETE'],
}));
```

---

### 3. ❌ Отсутствие Rate Limiting
**CWE-770: Allocation of Resources Without Limits**

```javascript
// Нет никакой защиты от brute-force
app.post('/register', (req, res) => {...});
app.post('/fcm/register', (req, res) => {...});
```

**Проблема:** Можно отправлять тысячи запросов в секунду.

**Риск:** 
- Brute-force атаки на регистрацию
- DDoS через FCM registration
- Exhaustion ресурсов сервера

**Fix:**
```bash
npm install express-rate-limit
```

```javascript
const rateLimit = require('express-rate-limit');

const registerLimiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 минут
  max: 5, // 5 попыток регистрации
  message: { error: 'Слишком много попыток, попробуйте позже' },
  standardHeaders: true,
  legacyHeaders: false,
});

app.post('/register', registerLimiter, (req, res) => {...});

const apiLimiter = rateLimit({
  windowMs: 60 * 1000, // 1 минута
  max: 100, // 100 запросов в минуту
});

app.use('/api/', apiLimiter);
```

---

### 4. ❌ Работа в HTTP-режиме Без TLS
**CWE-319: Cleartext Transmission of Sensitive Information**

```javascript
// server.js:64-68
console.log('[tls] No certificates found — running HTTP only (development mode)');
const server = httpsServer || http.createServer(app);
```

**Проблема:** При отсутствии сертификатов сервер автоматически падает в HTTP.

**Риск:** 
- Перехват трафика (MITM)
- Кража session tokens
- Деанонимизация пользователей

**Fix:**
```javascript
// Требовать HTTPS в production
const IS_PRODUCTION = process.env.NODE_ENV === 'production';

if (IS_PRODUCTION && !httpsServer) {
  console.error('ERROR: TLS certificates required in production');
  process.exit(1);
}

const server = httpsServer || (IS_PRODUCTION ? null : http.createServer(app));
```

---

### 5. ❌ Недостаточная Авторизация Endpoints
**CWE-862: Missing Authorization**

```javascript
// server.js:466-483 - Публичный доступ к public key
app.get('/user/:username', (req, res) => {
  const user = users.get(req.params.username);
  // Нет проверки аутентификации!
  res.json({ publicKey: user.publicKey, ... });
});

// server.js:452-463 - FCM регистрация без проверки
app.post('/fcm/register', (req, res) => {
  // Любой может зарегистрировать любой username!
  fcmTokens.set(username, token);
});
```

**Проблема:** endpoints не требуют аутентификации.

**Риск:**
- Enumeration пользователей
- Подделка FCM токенов
- Перехват push-уведомлений

**Fix:**
```javascript
// Middleware для проверки сессии
function requireSession(req, res, next) {
  const token = req.headers['x-session-token'];
  const username = req.body.username || req.params.username;
  
  if (!token || sessions.get(username) !== token) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  next();
}

app.get('/user/:username', requireSession, (req, res) => {...});
app.post('/fcm/register', requireSession, (req, res) => {...});
```

---

## ⚠️ УЯЗВИМОСТИ СРЕДНЕЙ ТЯЖЕСТИ (Should Fix)

### 6. ⚠️ IDOR в Удалении Пользователей
**CWE-639: Authorization Bypass Through User-Controlled Key**

```javascript
// server.js:798-825
app.delete('/admin/user/:username', requireAuth, (req, res) => {
  const name = req.params.username.toLowerCase().trim();
  // Нет проверки что админ не удаляет сам себя
  // Нет логирования действия
  users.delete(foundKey);
});
```

**Проблема:** Нет аудита действий, можно удалить себя.

**Fix:**
```javascript
app.delete('/admin/user/:username', requireAuth, (req, res) => {
  const targetUser = req.params.username.toLowerCase().trim();
  const adminUser = 'admin'; // из auth
  
  if (targetUser === adminUser) {
    return res.status(403).json({ error: 'Cannot delete admin account' });
  }
  
  console.log(`[audit] Admin ${adminUser} deleted user ${targetUser}`);
  // ... остальной код
});
```

---

### 7. ⚠️ Утечка Информации Через Error Messages
**CWE-209: Observable Response Discrepancy**

```javascript
// server.js:404-405
console.warn('[register] signature verification error:', e.message);
return res.status(403).json({ error: 'Signature verification failed' });

// server.js:470
return res.status(404).json({ error: 'Not found' });
```

**Проблема:** Детали ошибок могут помочь атаковать.

**Fix:**
```javascript
// Логировать детали внутри, клиенту давать общее сообщение
console.warn('[register] signature verification error:', {
  error: e.message,
  username: req.body.username,
  ip: req.ip,
  timestamp: Date.now()
});
return res.status(403).json({ error: 'Registration failed' });
```

---

### 8. ⚠️ Отсутствие Certificate Pinning В Клиенте
**CWE-295: Improper Certificate Validation**

```dart
// connection_service.dart:148-150
} else {
  // Development: allow any certificate (self-signed)
  client.badCertificateCallback = (_, __, ___) => true;
}
```

**Проблема:** В development режиме принимается любой сертификат.

**Риск:** MITM атаки в production если pin не настроен.

**Fix:**
```dart
// Всегда требовать pinning в production
const _isProduction = bool.fromEnvironment('dart.vm.product');

if (_isProduction && _pinSha256.isEmpty) {
  throw StateError('Certificate pin required in production');
}

client.badCertificateCallback = (X509Certificate cert, String host, int port) {
  if (_isProduction) {
    final fingerprint = sha256.convert(cert.der).toString();
    return fingerprint == _pinSha256;
  }
  // Только для development
  return true;
};
```

---

### 9. ⚠️ Небезопасное Хранение Session Tokens
**CWE-315: Cleartext Storage of Sensitive Information in Cookie**

```javascript
// server.js:137
const sessions = new Map(); // username → sessionToken

// server.js:141-144
const SESSION_SECRET = crypto.randomBytes(32).toString('hex');
function generateSessionToken(username) {
  return crypto.createHmac('sha256', SESSION_SECRET).update(username).digest('hex');
}
```

**Проблемы:**
- Токены не истекают
- Нет refresh механизма
- SESSION_SECRET меняется при рестарте (все сессии сбрасываются)

**Fix:**
```javascript
const SESSION_DURATION = 24 * 60 * 60 * 1000; // 24 часа

function generateSessionToken(username) {
  return {
    token: crypto.createHmac('sha256', SESSION_SECRET)
                 .update(username + Date.now())
                 .digest('hex'),
    expires: Date.now() + SESSION_DURATION
  };
}

function validateSession(username, token) {
  const session = sessions.get(username);
  if (!session) return false;
  if (Date.now() > session.expires) {
    sessions.delete(username);
    return false;
  }
  return session.token === token;
}
```

---

### 10. ⚠️ Отсутствие Валидации Входящих Данных
**CWE-20: Improper Input Validation**

```javascript
// server.js:582-586
socket.on('message', (payload) => {
  if (!payload || !payload.to || !payload.data) return;
  // Нет проверки размера данных
  // Нет проверки формата
  const envelope = {
    from: socket.username || 'unknown', // Может быть подделано?
    data: payload.data, // До 10MB без проверки
  };
});
```

**Fix:**
```javascript
const MAX_MESSAGE_SIZE = 100 * 1024; // 100KB

socket.on('message', (payload) => {
  if (!payload || typeof payload !== 'object') return;
  
  const { to, data } = payload;
  if (typeof to !== 'string' || to.length > 32) return;
  if (typeof data !== 'string' || data.length > MAX_MESSAGE_SIZE) return;
  
  // ... остальная логика
});
```

---

## ℹ️ РЕКОМЕНДАЦИИ (Nice to Have)

### 11. 📝 Добавить Логирование Безопасности
```javascript
const securityLog = fs.createWriteStream('./logs/security.log', { flags: 'a' });

function logSecurity(event, details) {
  securityLog.write(JSON.stringify({
    timestamp: new Date().toISOString(),
    event,
    ...details
  }) + '\n');
}

// Использовать для:
logSecurity('login_failed', { username, ip });
logSecurity('user_deleted', { admin, target });
logSecurity('rate_limit_exceeded', { ip, endpoint });
```

### 12. 📝 Добавить Security Headers
```javascript
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  res.setHeader('Content-Security-Policy', "default-src 'self'");
  next();
});
```

### 13. 📝 Реализовать Logout Endpoint
```javascript
app.post('/logout', requireSession, (req, res) => {
  sessions.delete(req.username);
  res.json({ ok: true });
});
```

---

## 📊 Сводная Таблица Уязвимостей

| # | Уязвимость | CWE | Критичность | Статус |
|---|------------|-----|-------------|--------|
| 1 | Хардкод пароля | CWE-798 | 🔴 Critical | Требуется фикс |
| 2 | CORS wildcard | CWE-942 | 🔴 Critical | Требуется фикс |
| 3 | Нет rate limiting | CWE-770 | 🔴 Critical | Требуется фикс |
| 4 | HTTP без TLS | CWE-319 | 🔴 Critical | Требуется фикс |
| 5 | Нет авторизации endpoints | CWE-862 | 🔴 Critical | Требуется фикс |
| 6 | IDOR в удалении | CWE-639 | 🟡 Medium | Рекомендуется |
| 7 | Утечка в errors | CWE-209 | 🟡 Medium | Рекомендуется |
| 8 | Нет certificate pinning | CWE-295 | 🟡 Medium | Рекомендуется |
| 9 | Session tokens | CWE-315 | 🟡 Medium | Рекомендуется |
| 10 | Нет валидации input | CWE-20 | 🟡 Medium | Рекомендуется |
| 11 | Нет security logging | - | 🟢 Low | Опционально |
| 12 | Нет security headers | CWE-693 | 🟢 Low | Опционально |

---

## 🛠 План Исправлений

### Priority 1 (Немедленно)
1. Удалить хардкод пароля, требовать env variable
2. Настроить CORS с whitelist доменов
3. Добавить rate limiting на все endpoints
4. Запретить HTTP в production

### Priority 2 (В течение недели)
5. Добавить аутентификацию на `/user/:username` и `/fcm/register`
6. Реализовать expiration сессий
7. Добавить валидацию input данных

### Priority 3 (В течение месяца)
8. Настроить certificate pinning в production build
9. Добавить security headers
10. Реализовать audit logging

---

## ✅ Чеклист Безопасности

- [ ] Переменные окружения для всех секретов
- [ ] HTTPS обязателен в production
- [ ] Rate limiting на всех публичных endpoints
- [ ] Аутентификация на всех API endpoints
- [ ] Валидация всех входящих данных
- [ ] Certificate pinning в мобильных клиентах
- [ ] Security headers на всех ответах
- [ ] Логирование security событий
- [ ] Регулярный аудит зависимостей (`npm audit`, `dart pub outdated`)
- [ ] Penetration тестирование перед релизом

---

## 📚 Ресурсы

- [OWASP Top 10](https://owasp.org/www-project-top-ten/)
- [CWE List](https://cwe.mitre.org/)
- [Node.js Security Best Practices](https://nodejs.org/en/docs/guides/security/)
- [Flutter Security](https://docs.flutter.dev/deployment/obfuscate)

---

*Документ создан: $(date)*
*Версия: 1.0*
