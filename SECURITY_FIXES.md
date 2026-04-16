# 🔧 SECURITY FIXES FOR SHADE MESSENGER

## 📦 Шаг 1: Установка зависимостей

```bash
npm install express-rate-limit dotenv helmet express-validator --save
```

---

## 🚨 FIX #1: Rate Limiting (Защита от brute-force/DDoS)

**Проблема:** Нет ограничения запросов → возможен перебор паролей и DDoS

**Файл:** `server/server.js`

**Добавить после строки 3 (после require):**
```javascript
const rateLimit = require('express-rate-limit');
```

**Добавить после строки 82 (после app.use(cors...)):**
```javascript
// ── Rate Limiting ───────────────────────────────────────────
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000, // 15 минут
  max: 100, // максимум 100 запросов с одного IP
  message: { error: 'Too many requests, please try again later' },
  standardHeaders: true,
  legacyHeaders: false,
});

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5, // только 5 попыток входа
  message: { error: 'Too many authentication attempts' },
});

app.use('/api/', limiter);
app.use('/register', limiter);
app.use('/dashboard', authLimiter);
```

---

## 🚨 FIX #2: Удаление хардкода пароля

**Проблема:** Пароль 'shade2026' захардкожен → любой имеет доступ к админке

**Файл:** `server/server.js`, строка 160

**Заменить:**
```javascript
// Было:
const DASHBOARD_PASS = process.env.DASHBOARD_PASS || 'shade2026';

// Стало:
const DASHBOARD_PASS = process.env.DASHBOARD_PASS;
if (!DASHBOARD_PASS) {
  console.error('[ERROR] DASHBOARD_PASS environment variable is not set!');
  console.error('Set it with: export DASHBOARD_PASS="your_secure_password"');
  process.exit(1);
}
```

**Создать файл `.env` в папке `server/`:**
```bash
DASHBOARD_PASS=YourSuperSecurePassword_2026!@#$
NODE_ENV=production
ALLOWED_ORIGINS=https://your-domain.com
```

---

## 🚨 FIX #3: CORS Wildcard → Whitelist

**Проблема:** `origin: '*'` позволяет CSRF атаки с любых сайтов

**Файл:** `server/server.js`, строки 74 и 82

**Заменить:**
```javascript
// Было:
cors: { origin: '*', methods: ['GET', 'POST'] }
app.use(cors({ origin: '*' }));

// Стало:
const ALLOWED_ORIGINS = (process.env.ALLOWED_ORIGINS || 'http://localhost:3000').split(',');

const corsOptions = {
  origin: function(origin, callback) {
    if (!origin || ALLOWED_ORIGINS.includes(origin)) {
      callback(null, true);
    } else {
      console.warn('[CORS] Blocked origin:', origin);
      callback(new Error('Not allowed by CORS'));
    }
  },
  methods: ['GET', 'POST'],
  credentials: true,
};

io.opts.cors = corsOptions;
app.use(cors(corsOptions));
```

---

## 🚨 FIX #4: Принудительный HTTPS (отключить HTTP fallback)

**Проблема:** Сервер работает в HTTP режиме без TLS → MITM атаки

**Файл:** `server/server.js`, строки 63-71

**Заменить:**
```javascript
// Было:
} else {
  console.log('[tls] No certificates found — running HTTP only (development mode)');
}
// ...
const server = httpsServer || http.createServer(app);

// Стало:
} else {
  if (process.env.NODE_ENV === 'production') {
    console.error('[ERROR] TLS certificates required in production!');
    console.error('Generate with: ./gen-certs.sh or ./gen-certs.bat');
    process.exit(1);
  }
  console.log('[tls] No certificates — development mode only');
  httpServer = http.createServer(app);
}

// Всегда использовать HTTPS в production
const server = httpsServer || (process.env.NODE_ENV === 'production' ? null : httpServer);
if (!server) {
  console.error('[FATAL] Cannot start without TLS in production');
  process.exit(1);
}
```

---

## 🚨 FIX #5: Авторизация публичных endpoints

**Проблема:** `/user/:username` и `/fcm/register` доступны без авторизации

**Файл:** `server/server.js`

**Найти endpoint `/user/:username` (примерно строка 450) и добавить middleware:**

Сначала создай middleware после строки 145:
```javascript
// Middleware для проверки сессии пользователя
function requireUserAuth(req, res, next) {
  const sessionToken = req.headers['x-session-token'];
  const username = req.params.username || req.body.username;
  
  if (!sessionToken || !username) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  
  const expectedToken = generateSessionToken(username);
  if (sessionToken !== expectedToken) {
    return res.status(403).json({ error: 'Invalid session' });
  }
  
  next();
}
```

**Теперь применить к endpoints:**
```javascript
// Найти app.get('/user/:username', ...) и изменить:
app.get('/user/:username', requireUserAuth, (req, res) => {
  // ... существующий код
});

app.post('/fcm/register', requireUserAuth, (req, res) => {
  // ... существующий код
});
```

---

## 🚨 FIX #6: IDOR в удалении пользователей

**Проблема:** Можно удалить любого пользователя включая себя

**Файл:** `server/server.js`, найти `app.delete('/admin/user/:username'`

**Заменить логику удаления:**
```javascript
app.delete('/admin/user/:username', requireAuth, (req, res) => {
  const targetUser = req.params.username;
  
  // Нельзя удалить самого себя (админа)
  if (targetUser === 'admin') {
    return res.status(403).json({ error: 'Cannot delete admin account' });
  }
  
  // Проверка существования пользователя
  if (!users.has(targetUser)) {
    return res.status(404).json({ error: 'User not found' });
  }
  
  // Логирование действия
  console.log(`[AUDIT] Admin deleted user: ${targetUser}`);
  
  // Удаляем пользователя
  users.delete(targetUser);
  saveMap('users.json', users);
  
  // Disconnect socket если онлайн
  const socketId = onlineUsers.get(targetUser);
  if (socketId) {
    io.to(socketId).emit('kicked', { reason: 'Account deleted by admin' });
    io.sockets.sockets.get(socketId)?.disconnect();
  }
  
  res.json({ ok: true, message: 'User deleted' });
});
```

---

## 🚨 FIX #7: Безопасная обработка ошибок (без утечки информации)

**Проблема:** Детали ошибок помогают атакующему

**Файл:** `server/server.js`

**Добавить глобальный обработчик ошибок после всех routes (перед io.on):**
```javascript
// ── Error Handler (без утечки деталей) ──────────────────────
app.use((err, req, res, next) => {
  console.error('[ERROR]', err.message);
  
  // В production скрываем детали ошибок
  if (process.env.NODE_ENV === 'production') {
    res.status(err.status || 500).json({
      error: 'Internal server error',
      code: 'SERVER_ERROR'
    });
  } else {
    res.status(err.status || 500).json({
      error: err.message,
      stack: err.stack
    });
  }
});
```

---

## 🚨 FIX #8: Session Token Expiration

**Проблема:** Сессии не истекают → украденный токен работает вечно

**Файл:** `server/server.js`

**Изменить функцию generateSessionToken (строка 143-145):**
```javascript
// Было:
function generateSessionToken(username) {
  return crypto.createHmac('sha256', SESSION_SECRET).update(username).digest('hex');
}

// Стало:
const SESSION_DURATION = 24 * 60 * 60 * 1000; // 24 часа

function generateSessionToken(username) {
  const timestamp = Date.now();
  const base = `${username}:${timestamp}`;
  const signature = crypto.createHmac('sha256', SESSION_SECRET).update(base).digest('hex');
  return `${base}:${signature}`;
}

function validateSessionToken(username, token) {
  if (!token) return false;
  
  const parts = token.split(':');
  if (parts.length !== 3) return false;
  
  const [tokenUsername, timestampStr, signature] = parts;
  const timestamp = parseInt(timestampStr, 10);
  
  // Проверка имени пользователя
  if (tokenUsername !== username) return false;
  
  // Проверка времени (24 часа)
  if (Date.now() - timestamp > SESSION_DURATION) {
    console.log('[session] expired for', username);
    return false;
  }
  
  // Проверка подписи
  const base = `${username}:${timestamp}`;
  const expectedSignature = crypto.createHmac('sha256', SESSION_SECRET).update(base).digest('hex');
  
  return crypto.timingSafeEqual(
    Buffer.from(signature, 'hex'),
    Buffer.from(expectedSignature, 'hex')
  );
}
```

**Обновить место использования в `/register`:**
```javascript
// В ответе /register добавить:
res.json({
  ok: true,
  sessionToken: generateSessionToken(username_norm),
  publicKey: existing ? existing.publicKey : publicKey,
  isNew: !existing,
});
```

---

## 🚨 FIX #9: Валидация размера файлов и типов

**Проблема:** Нет проверки что именно передаётся как фото

**Файл:** `server/server.js`, Socket.IO обработка messages

**Добавить в начале socket.on('message', ...) после стро 582:**
```javascript
socket.on('message', (payload) => {
  // Валидация размера данных
  const MAX_MESSAGE_SIZE = 1 * 1024 * 1024; // 1MB для текста
  const MAX_FILE_SIZE = 10 * 1024 * 1024;   // 10MB для файлов
  
  if (!payload || !payload.to || !payload.data) return;
  
  // Проверка размера
  const dataSize = Buffer.byteLength(JSON.stringify(payload.data), 'utf8');
  if (dataSize > MAX_FILE_SIZE) {
    socket.emit('error', { message: 'Message too large' });
    console.log('[security] oversized message rejected');
    return;
  }
  
  // Если это файл, проверить тип
  if (payload.data.type === 'file' || payload.data.type === 'image') {
    const allowedExtensions = ['.jpg', '.jpeg', '.png', '.gif', '.pdf', '.txt'];
    const fileName = payload.data.fileName || '';
    const ext = path.extname(fileName).toLowerCase();
    
    if (!allowedExtensions.includes(ext)) {
      socket.emit('error', { message: 'File type not allowed' });
      console.log('[security] blocked file type:', ext);
      return;
    }
  }
  
  // ... остальной код
```

---

## 🚨 FIX #10: Security Headers

**Добавить после строки 83:**
```javascript
// ── Security Headers ───────────────────────────────────────
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'");
  res.removeHeader('X-Powered-By');
  next();
});
```

---

## 📝 ШПАРГАЛКА ДЛЯ ЗАПУСКА

```bash
# 1. Установить зависимости
cd /workspace/server
npm install express-rate-limit dotenv helmet express-validator --save

# 2. Создать .env файл
cat > .env << EOF
DASHBOARD_PASS=$(openssl rand -base64 32)
NODE_ENV=production
ALLOWED_ORIGINS=https://your-domain.com
EOF

# 3. Сгенерировать TLS сертификаты
./gen-certs.sh  # или gen-certs.bat на Windows

# 4. Запустить сервер
node server.js
```

---

## ✅ ЧЕКЛИСТ ПРОВЕРКИ

- [ ] Rate limiting работает (попробовать 105 запросов подряд)
- [ ] Пароль админки нельзя угадать (старый 'shade2026' не работает)
- [ ] CORS блокирует запросы с других доменов
- [ ] Без HTTPS сервер не запускается в production
- [ ] Сессии истекают через 24 часа
- [ ] Файлы .exe/.js/.php блокируются
- [ ] Ошибки не показывают стектрейсы в production
