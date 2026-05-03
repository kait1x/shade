'use strict';

const express = require('express');
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Server } = require('socket.io');
const cors = require('cors');
const rateLimit = require('express-rate-limit');
require('dotenv').config();

// ── Firebase Admin SDK (optional) ─────────────────────────────
let admin = null;
try {
  admin = require('firebase-admin');
  const serviceAccount = require('./firebase-service-account.json');
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });
  console.log('[firebase] initialized');
} catch (e) {
  console.log('[firebase] disabled — push notifications unavailable');
}

// ── Мастер-ключ сервера (для подписи публичных ключей пользователей) ─────────────────────
const MASTER_KEY_FILE = path.join(DATA_DIR, 'server_master_key');
let serverMasterKey = null;
let serverPublicKey = null;

function loadOrGenerateMasterKey() {
  if (fs.existsSync(MASTER_KEY_FILE)) {
    try {
      const data = JSON.parse(fs.readFileSync(MASTER_KEY_FILE, 'utf8'));
      serverMasterKey = data;
      serverPublicKey = data.publicKey;
      console.log('[server] Мастер-ключ загружен');
      return;
    } catch (e) {
      console.error('[server] Ошибка чтения мастер-ключа:', e.message);
    }
  }
  // Генерируем новый мастер-ключ (RSA-4096)
  console.log('[server] Генерация нового мастер-ключа...');
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 4096,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
  });
  serverMasterKey = { publicKey, privateKey };
  serverPublicKey = publicKey;
  fs.writeFileSync(MASTER_KEY_FILE, JSON.stringify({ publicKey, privateKey }), { mode: 0o600 });
  console.log('[server] Мастер-ключ сгенерирован и сохранён');
}

loadOrGenerateMasterKey();

// [FIX] HIGH #4: Validate DASHBOARD_PASS at startup
if (!DASHBOARD_PASS || DASHBOARD_PASS === '<SET_YOUR_STRONG_PASSWORD_HERE>') {
  console.error('[FATAL] DASHBOARD_PASS is not configured!');
  console.error('[FATAL] Please set a strong password:');
  console.error('[FATAL]   export DASHBOARD_PASS="your_secure_password"');
  console.error('[FATAL] Or update server/.env with a real password');
  process.exit(1);
}

// ── App Setup ────────────────────────────────────────────────

const app = express();

// Try to load TLS certificates
const CERT_DIR = process.env.CERT_DIR || path.join(__dirname, 'certs');
let httpsServer = null;
let httpServer = null;

try {
  const keyPath = path.join(CERT_DIR, 'key.pem');
  const certPath = path.join(CERT_DIR, 'cert.pem');

  if (fs.existsSync(keyPath) && fs.existsSync(certPath)) {
    const tlsOptions = {
      key: fs.readFileSync(keyPath),
      cert: fs.readFileSync(certPath),
      minVersion: 'TLSv1.2',
      ciphers: 'ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:DHE+CHACHA20:!aNULL:!MD5:!DSS',
    };

    httpsServer = https.createServer(tlsOptions, app);

    // HTTP redirect server — redirects to HTTPS
    const HTTP_PORT = process.env.HTTP_PORT || 3000;
    const HTTPS_PORT = process.env.HTTPS_PORT || 3443;

    httpServer = http.createServer((req, res) => {
      const host = req.headers.host ? req.headers.host.replace(/:\d+$/, '') : 'localhost';
      res.writeHead(301, { Location: `https://${host}:${HTTPS_PORT}${req.url}` });
      res.end();
    });

    httpServer.listen(HTTP_PORT, '0.0.0.0', () => {
      console.log(`[tls] HTTP redirect on :${HTTP_PORT} → :${HTTPS_PORT}`);
    });

    console.log('[tls] HTTPS certificates loaded');
  } else {
    console.log('[tls] No certificates found — running HTTP only (development mode)');
  }
} catch (e) {
  console.log('[tls] Cert load failed — running HTTP only:', e.message);
}

// ── CORS Configuration ───────────────────────────────────────
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

// Use HTTPS if available, otherwise HTTP
const server = httpsServer || (process.env.NODE_ENV === 'production' ? null : httpServer);
if (!server && process.env.NODE_ENV === 'production') {
  console.error('[FATAL] Cannot start without TLS in production');
  process.exit(1);
}

const io = new Server(server || http.createServer(app), {
  cors: corsOptions,
  transports: ['websocket'],
  pingTimeout: 60000,
  pingInterval: 25000,
  maxHttpBufferSize: 10e6, // 10MB for photos
});

app.set('trust proxy', 1);
app.use(cors(corsOptions));
app.use(express.json({ limit: '1mb' }));

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
// [FIX] Добавляем requireAuth для защиты админ-панели
app.use('/dashboard', requireAuth, authLimiter);

// ── In-memory stores ─────────────────────────────────────────

const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');

// Ensure data directory exists with restricted permissions
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });
}

// ── SESSION_SECRET Management ─────────────────────────────────
// Priority: 1) Environment variable, 2) File, 3) Generate new
const SESSION_SECRET_FILE = path.join(DATA_DIR, 'session_secret');

function loadSessionSecret() {
  // 1. Check environment variable first
  if (process.env.SESSION_SECRET) {
    console.log('[session] SESSION_SECRET loaded from environment variable');
    return process.env.SESSION_SECRET;
  }
  
  // 2. Check if file exists
  if (fs.existsSync(SESSION_SECRET_FILE)) {
    try {
      const secret = fs.readFileSync(SESSION_SECRET_FILE, 'utf8').trim();
      if (secret) {
        console.log('[session] SESSION_SECRET loaded from file');
        return secret;
      }
    } catch (e) {
      console.error('[session] Error reading session secret file:', e.message);
    }
  }
  
  // 3. Generate new secret and save to file
  const newSecret = crypto.randomBytes(64).toString('hex');
  try {
    fs.writeFileSync(SESSION_SECRET_FILE, newSecret, { mode: 0o600 });
    console.log('[session] SESSION_SECRET generated and saved to file (mode 600)');
  } catch (e) {
    console.error('[session] FATAL: Cannot write session secret to data/session_secret. Check permissions.');
    process.exit(1); // Exit server - session secret is critical
  }
  
  return newSecret;
}

const SESSION_SECRET = loadSessionSecret();
const SESSION_DURATION = 24 * 60 * 60 * 1000; // 24 часа

function loadMap(filename) {
  const file = path.join(DATA_DIR, filename);
  try {
    if (fs.existsSync(file)) {
      const data = JSON.parse(fs.readFileSync(file, 'utf8'));
      const m = new Map(data);
      // Convert Sets for groups
      if (filename === 'groups.json') {
        for (const [k, v] of m) {
          if (v.members && Array.isArray(v.members)) {
            v.members = new Set(v.members);
          }
        }
      }
      return m;
    }
  } catch (e) {
    console.error('[db] load error:', filename, e.message);
  }
  return new Map();
}

function saveMap(filename, map) {
  const file = path.join(DATA_DIR, filename);
  // [FIX] CRIT #3: Use mutex for race condition protection
  dbMutex.acquire().then((release) => {
    try {
      let data;
      if (filename === 'groups.json') {
        data = [...map.entries()].map(([k, v]) => [k, { ...v, members: [...v.members] }]);
      } else {
        data = [...map.entries()];
      }
      fs.writeFileSync(file, JSON.stringify(data));
    } catch (e) {
      console.error('[db] save error:', filename, e.message);
    } finally {
      release();
    }
  });
}

const users = loadMap('users.json');
const fcmTokens = loadMap('fcm_tokens.json');
const groups = loadMap('groups.json');
const lastSeen = loadMap('last_seen.json'); // username → timestamp
const onlineUsers = new Map();
const offlineBuffer = new Map();
const sessions = new Map(); // username → sessionToken
const watchers = new Map(); // targetUsername → Set<socketId> (who is watching)

// [FIX] CRIT #3: Simple mutex for race condition protection
class Mutex {
  constructor() {
    this.queue = [];
    this.locked = false;
  }
  
  acquire() {
    return new Promise((resolve) => {
      if (!this.locked) {
        this.locked = true;
        resolve(() => { this.release(); });
      } else {
        this.queue.push(resolve);
      }
    });
  }
  
  release() {
    if (this.queue.length > 0) {
      const next = this.queue.shift();
      next(() => { this.release(); });
    } else {
      this.locked = false;
    }
  }
}

const dbMutex = new Mutex();

// SESSION_SECRET уже определён выше через loadSessionSecret()
// SESSION_DURATION уже определён выше
const REFRESH_TOKEN_DURATION = 7 * 24 * 60 * 60 * 1000; // 7 дней для refresh token

// [FIX] CRIT #3: Store refresh tokens separately
const refreshTokens = new Map(); // refreshToken → { username, expiresAt }

function generateSessionToken(username) {
  const timestamp = Date.now();
  const base = `${username}:${timestamp}`;
  const signature = crypto.createHmac('sha256', SESSION_SECRET).update(base).digest('hex');
  return `${base}:${signature}`;
}

// [FIX] CRIT #3: Generate refresh token
function generateRefreshToken(username) {
  const token = crypto.randomBytes(64).toString('hex');
  const expiresAt = Date.now() + REFRESH_TOKEN_DURATION;
  refreshTokens.set(token, { username, expiresAt });
  return token;
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
  
  try {
    return crypto.timingSafeEqual(
      Buffer.from(signature, 'hex'),
      Buffer.from(expectedSignature, 'hex')
    );
  } catch (e) {
    return false;
  }
}

// [FIX] CRIT #3: Validate refresh token
function validateRefreshToken(token) {
  if (!token) return null;
  const data = refreshTokens.get(token);
  if (!data) return null;
  
  // Check expiration
  if (Date.now() > data.expiresAt) {
    refreshTokens.delete(token);
    return null;
  }
  
  return data.username;
}

// Middleware для проверки сессии пользователя
function requireUserAuth(req, res, next) {
  const sessionToken = req.headers['x-session-token'];
  const username = req.params.username || req.body.username;
  
  if (!sessionToken || !username) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  
  if (!validateSessionToken(username, sessionToken)) {
    return res.status(403).json({ error: 'Invalid or expired session' });
  }
  
  next();
}

// [FIX] Middleware для защиты админ-эндпоинтов (Basic Auth)
function requireAuth(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || auth !== 'Basic ' + Buffer.from('admin:' + DASHBOARD_PASS).toString('base64')) {
    return res.status(401).send('Unauthorized');
  }
  next();
}

// ── REST endpoints ───────────────────────────────────────────

app.get('/', (_req, res) => {
  res.json({
    name: 'Shade Relay Server',
    status: 'ok',
    users: users.size,
    online: onlineUsers.size,
  });
});

// [FIX] Защищённый эндпоинт статистики (только для админа)
app.get('/api/stats', requireAuth, (req, res) => {
  const mem = process.memoryUsage();
  const uptime = process.uptime();
  const userList = [...users.entries()].map(([name, u]) => ({
    name,
    online: onlineUsers.has(name),
    lastSeen: lastSeen.get(name) || 0,
    registeredAt: u.registeredAt,
  }));

  res.json({
    totalUsers: users.size,
    online: onlineUsers.size,
    uptime,
    memory: {
      used: Math.round(mem.heapUsed / 1024 / 1024),
      total: Math.round(mem.heapTotal / 1024 / 1024),
    },
    groups: groups.size,
    queuedMessages: [...offlineBuffer.values()].reduce((s, a) => s + a.length, 0),
    users: userList.sort((a, b) => b.registeredAt - a.registeredAt),
  });
});

// Отдаёт публичный ключ сервера (для проверки подписей)
app.get('/api/server/public-key', (req, res) => {
  if (!serverPublicKey) {
    return res.status(500).json({ error: 'Server key not available' });
  }
  res.json({ publicKey: serverPublicKey });
});

// Register user (or reissue token for existing user with valid signature)
app.post('/register', (req, res) => {
  // [FIX] CRIT #3: Acquire mutex for race condition protection
  dbMutex.acquire().then((release) => {
    try {
      const { username, publicKey, signature } = req.body;

      // Validate nickname: 3-32 chars, a-z 0-9 _, case-insensitive
      const nick = (username || '').toLowerCase().trim();
      if (!/^[a-z0-9_]{3,32}$/.test(nick)) {
        release();
        return res.status(400).json({
          error: 'Никнейм: 3-32 символа, только a-z, 0-9, _',
        });
      }
      if (!publicKey) {
        release();
        return res.status(400).json({ error: 'Invalid key' });
      }
      if (!signature) {
        release();
        return res.status(400).json({ error: 'Missing signature' });
      }
  
      // Use normalized nickname everywhere
      const username_norm = nick;
  
      // Verify RSA-PSS signature: signer proves they hold the private key
      try {
        const dataB64 = Buffer.from(publicKey).toString('base64');
        const isValid = crypto.verify(
          'sha256',
          Buffer.from(dataB64),
          {
            key: publicKey,
            padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
            saltLength: crypto.constants.RSA_PSS_SALTLEN_AUTO,
          },
          Buffer.from(signature, 'base64'),
        );
  
        if (!isValid) {
          console.warn('[register] invalid signature');
          release();
          return res.status(403).json({ error: 'Invalid signature' });
        }
      } catch (e) {
        console.warn('[register] signature verification error:', e.message);
        release();
        return res.status(403).json({ error: 'Signature verification failed' });
      }
  
      // [FIX] Validate public key is valid RSA key
      try {
        const pubKey = crypto.createPublicKey(publicKey);
        // Try to use it for encryption (should not throw)
        const testData = Buffer.from('test');
        crypto.publicEncrypt(pubKey, testData);
        console.log('[register] public key validated');
      } catch (e) {
        console.warn('[register] invalid public key:', e.message);
        release();
        return res.status(400).json({ error: 'Invalid public key' });
      }
  
      // Case-insensitive lookup (handles old mixed-case keys)
      let existingKey = null;
      let existing = null;
      for (const [key, value] of users) {
        if (key.toLowerCase() === username_norm) {
          existingKey = key;
          existing = value;
          break;
        }
      }
  
      if (existing) {
        // Same key? Reissue token. Different key? Taken.
        if (existing.publicKey !== publicKey) {
          release();
          return res.status(409).json({ error: 'Никнейм уже занят' });
        }
        // Migrate old key to lowercase
        if (existingKey !== username_norm) {
          users.delete(existingKey);
          users.set(username_norm, existing);
          saveMap('users.json', users);
        }
        const token = generateSessionToken(username_norm);
        sessions.set(username_norm, token);
        console.log('[register] reissued token');
        release();
        return res.json({ ok: true, username: username_norm, token });
      }
  
      // Подписываем публичный ключ мастер-ключом сервера используя RSA-PSS-SHA256
      let serverSignature = null;
      if (serverMasterKey && serverMasterKey.privateKey) {
        try {
          // [FIX] Используем RSA-PSS вместо PKCS#1 v1.5
          const sign = crypto.createSign('sha256');
          sign.update(publicKey);
          sign.end();
          const signature = sign.sign({
            key: serverMasterKey.privateKey,
            padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
            saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST, // salt = hash length (32 bytes for SHA-256)
          });
          serverSignature = signature.toString('base64');
        } catch (e) {
          console.error('[register] Ошибка подписи публичного ключа:', e.message);
        }
      }
  
      users.set(username_norm, {
        publicKey,
        signature,
        serverSignature,
        registeredAt: Date.now(),
      });
      saveMap('users.json', users);
  
      // Generate session token for WebSocket authentication
      const token = generateSessionToken(username_norm);
      sessions.set(username_norm, token);
  
      console.log('[register] new user');
      release();
      res.json({ ok: true, username: username_norm, token });
    } catch (e) {
      console.error('[register] error:', e.message);
      release();
      res.status(500).json({ error: 'Internal error' });
    }
  });
});
});
});
  }
  if (!publicKey) {
    return res.status(400).json({ error: 'Invalid key' });
  }
  if (!signature) {
    return res.status(400).json({ error: 'Missing signature' });
  }

  // Use normalized nickname everywhere
  const username_norm = nick;

  // Verify RSA-PSS signature: signer proves they hold the private key
  try {
    const dataB64 = Buffer.from(publicKey).toString('base64');
    const isValid = crypto.verify(
      'sha256',
      Buffer.from(dataB64),
      {
        key: publicKey,
        padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
        saltLength: crypto.constants.RSA_PSS_SALTLEN_AUTO,
      },
      Buffer.from(signature, 'base64'),
    );

    if (!isValid) {
      console.warn('[register] invalid signature');
      return res.status(403).json({ error: 'Invalid signature' });
    }
  } catch (e) {
    console.warn('[register] signature verification error:', e.message);
    return res.status(403).json({ error: 'Signature verification failed' });
  }

  // [FIX] Validate public key is valid RSA key
  try {
    const pubKey = crypto.createPublicKey(publicKey);
    // Try to use it for encryption (should not throw)
    const testData = Buffer.from('test');
    crypto.publicEncrypt(pubKey, testData);
    console.log('[register] public key validated');
  } catch (e) {
    console.warn('[register] invalid public key:', e.message);
    return res.status(400).json({ error: 'Invalid public key' });
  }

  // Case-insensitive lookup (handles old mixed-case keys)
  let existingKey = null;
  let existing = null;
  for (const [key, value] of users) {
    if (key.toLowerCase() === username_norm) {
      existingKey = key;
      existing = value;
      break;
    }
  }

  if (existing) {
    // Same key? Reissue token. Different key? Taken.
    if (existing.publicKey !== publicKey) {
      return res.status(409).json({ error: 'Никнейм уже занят' });
    }
    // Migrate old key to lowercase
    if (existingKey !== username_norm) {
      users.delete(existingKey);
      users.set(username_norm, existing);
      saveMap('users.json', users);
    }
    const token = generateSessionToken(username_norm);
    sessions.set(username_norm, token);
    console.log('[register] reissued token');
    return res.json({ ok: true, username: username_norm, token });
  }

  // Подписываем публичный ключ мастер-ключом сервера используя RSA-PSS-SHA256
  let serverSignature = null;
  if (serverMasterKey && serverMasterKey.privateKey) {
    try {
      // [FIX] Используем RSA-PSS вместо PKCS#1 v1.5
      const sign = crypto.createSign('sha256');
      sign.update(publicKey);
      sign.end();
      const signature = sign.sign({
        key: serverMasterKey.privateKey,
        padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
        saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST, // salt = hash length (32 bytes for SHA-256)
      });
      serverSignature = signature.toString('base64');
    } catch (e) {
      console.error('[register] Ошибка подписи публичного ключа:', e.message);
    }
  }

  users.set(username_norm, {
    publicKey,
    signature,
    serverSignature,
    registeredAt: Date.now(),
  });
  saveMap('users.json', users);

  // Generate session token for WebSocket authentication
  const token = generateSessionToken(username_norm);
  sessions.set(username_norm, token);

  console.log('[register] new user');
  res.json({ ok: true, username: username_norm, token });
});

// [FIX] Logout endpoint - invalidates session token
app.post('/logout', requireUserAuth, (req, res) => {
  const username = req.params.username || req.body.username;
  if (username) {
    sessions.delete(username);
    // Also clear FCM token
    fcmTokens.delete(username);
    saveMap('fcm_tokens.json', fcmTokens);
    console.log('[logout] user logged out');
  }
  res.json({ ok: true });
});

// [FIX] CRIT #3: Refresh token endpoint
app.post('/refresh', (req, res) => {
  const { refreshToken } = req.body;
  
  if (!refreshToken) {
    return res.status(400).json({ error: 'Missing refresh token' });
  }
  
  const data = validateRefreshToken(refreshToken);
  if (!data) {
    return res.status(403).json({ error: 'Invalid or expired refresh token' });
  }
  
  // Generate new session token
  const newSessionToken = generateSessionToken(data.username);
  sessions.set(data.username, newSessionToken);
  
  // Generate new refresh token
  const newRefreshToken = generateRefreshToken(data.username);
  
  console.log('[refresh] token refreshed for', data.username);
  res.json({ ok: true, token: newSessionToken, refreshToken: newRefreshToken });
});

// [FIX] HIGH #7: Register FCM token with authentication
app.post('/fcm/register', (req, res) => {
  const { username, token } = req.body;
  const sessionToken = req.headers['x-session-token'];

  if (!username || !token) {
    return res.status(400).json({ error: 'Missing data' });
  }

  // [FIX] Verify session token and username match
  if (!sessionToken || !validateSessionToken(username, sessionToken)) {
    return res.status(403).json({ error: 'Invalid or expired session' });
  }

  // [FIX] HIGH #7: Verify username in request matches session
  const sessionUsername = sessionToken.split(':')[0];
  if (sessionUsername !== username) {
    console.warn('[fcm] Username mismatch: session=' + sessionUsername + ' req=' + username);
    return res.status(403).json({ error: 'Username mismatch' });
  }

  fcmTokens.set(username, token);
  saveMap('fcm_tokens.json', fcmTokens);
  console.log('[fcm] token registered');
  res.json({ ok: true });
});

// [FIX] HIGH #7: Unregister FCM token (logout) with authentication
app.post('/fcm/unregister', (req, res) => {
  const { username, token } = req.body;
  const sessionToken = req.headers['x-session-token'];

  if (!username || !token) {
    return res.status(400).json({ error: 'Missing data' });
  }

  // [FIX] Verify session token and username match
  if (!sessionToken || !validateSessionToken(username, sessionToken)) {
    return res.status(403).json({ error: 'Invalid or expired session' });
  }

  // [FIX] HIGH #7: Verify username in request matches session
  const sessionUsername = sessionToken.split(':')[0];
  if (sessionUsername !== username) {
    console.warn('[fcm] Username mismatch: session=' + sessionUsername + ' req=' + username);
    return res.status(403).json({ error: 'Username mismatch' });
  }

  const storedToken = fcmTokens.get(username);
  if (storedToken === token) {
    fcmTokens.delete(username);
    saveMap('fcm_tokens.json', fcmTokens);
    console.log('[fcm] token unregistered');
  }
  res.json({ ok: true });
});

// Получение публичного ключа пользователя (требует аутентификации)
app.get('/user/:username', requireUserAuth, (req, res) => {
  const user = users.get(req.params.username);

  if (!user) {
    return res.status(404).json({ error: 'Not found' });
  }

  // Если serverSignature отсутствует, подписываем ключ сейчас
  if (!user.serverSignature && serverMasterKey && serverMasterKey.privateKey) {
    try {
      user.serverSignature = crypto.sign('sha256', Buffer.from(user.publicKey), serverMasterKey.privateKey).toString('base64');
      // Обновляем хранилище
      users.set(req.params.username, user);
      saveMap('users.json', users);
    } catch (e) {
      console.error('[user] Ошибка подписи публичного ключа:', e.message);
    }
  }

  const isOnline = onlineUsers.has(req.params.username);
  const lastSeenTime = lastSeen.get(req.params.username) || 0;

  res.json({
    username: req.params.username,
    publicKey: user.publicKey,
    signature: user.signature,
    serverSignature: user.serverSignature || null,
    online: isOnline,
    lastSeen: lastSeenTime,
  });
});

// ── FCM Push Notification ────────────────────────────────────

async function sendFcmPush(username, from) {
  if (!admin) return;
  const token = fcmTokens.get(username);
  if (!token) return;

  try {
    await admin.messaging().send({
      token: token,
      notification: {
        title: 'Shade',
        body: 'Новое сообщение',
      },
      data: {},
    });
    console.log('[fcm] push sent');
  } catch (e) {
    console.error('[fcm] push failed:', e.message);
  }
}

// ── Group endpoints ──────────────────────────────────────────

app.post('/group/create', (req, res) => {
  const { name, members } = req.body;
  if (!name || !Array.isArray(members) || members.length < 2) {
    return res.status(400).json({ error: 'Need name and at least 2 members' });
  }

  const groupId = Date.now().toString();
  groups.set(groupId, {
    name,
    members: new Set(members),
    createdAt: Date.now(),
  });
  saveMap('groups.json', groups);

  console.log('[group] created');
  res.json({ ok: true, groupId, name, members });
});

app.get('/group/:id', (req, res) => {
  const group = groups.get(req.params.id);
  if (!group) return res.status(404).json({ error: 'Group not found' });
  res.json({
    id: req.params.id,
    name: group.name,
    members: [...group.members],
  });
});

// ── WebSocket ────────────────────────────────────────────────

io.on('connection', (socket) => {
  console.log('[ws] connected:', socket.id);

  // [FIX] HIGH #4: Add rate limiting for WebSocket register
  const wsRegisterAttempts = new Map(); // socketId -> { count: 0, resetTime: Date.now() + 60000 }
  const WS_MAX_REGISTER_PER_MINUTE = 5; // maximum 5 register attempts per minute

  socket.on('register', (payload) => {
    if (!payload || typeof payload.username !== 'string' || !payload.username) return;

    // [FIX] HIGH #4: Check rate limiting for register
    const now = Date.now();
    let regInfo = wsRegisterAttempts.get(socket.id);
    if (!regInfo || now > regInfo.resetTime) {
      regInfo = { count: 0, resetTime: now + 60000 };
    }
    regInfo.count++;
    wsRegisterAttempts.set(socket.id, regInfo);
    if (regInfo.count > WS_MAX_REGISTER_PER_MINUTE) {
      socket.emit('authError', { error: 'Too many register attempts' });
      console.warn('[ws] register rate limit exceeded for', socket.id);
      return;
    }

    const username = payload.username.toLowerCase().trim();
    const token = payload.token;

    // Verify session token
    const expected = sessions.get(username);
    if (!expected || token !== expected) {
      console.warn('[ws] auth failed');
      socket.emit('authError', { error: 'Invalid session token' });
      // Delay disconnect so client can process the event
      setTimeout(() => socket.disconnect(true), 1000);
      return;
    }

    onlineUsers.set(username, socket.id);
    socket.username = username;
    lastSeen.set(username, Date.now()); // mark as online
    saveMap('last_seen.json', lastSeen);
    console.log('[ws] user online');

    // Notify watchers that this user is online
    const userWatchers = watchers.get(username);
    if (userWatchers) {
      for (const sid of userWatchers) {
        io.to(sid).emit('statusUpdate', { username, online: true, lastSeen: Date.now() });
      }
    }

    // Flush offline buffer
    const queued = offlineBuffer.get(username);
    if (queued && queued.length > 0) {
      for (const msg of queued) {
        socket.emit('message', msg);
      }
      offlineBuffer.delete(username);
    }
  });

  // [FIX] Rate limiting for WebSocket events
  const wsRateLimits = new Map(); // socketId -> { count: 0, resetTime: Date.now() + 60000 }
  const WS_MAX_MESSAGES_PER_MINUTE = 60; // максимум 60 сообщений в минуту

  socket.on('message', (payload) => {
    // [FIX] Проверка rate limiting для сообщений
    const now = Date.now();
    let rateInfo = wsRateLimits.get(socket.id);
    if (!rateInfo || now > rateInfo.resetTime) {
      rateInfo = { count: 0, resetTime: now + 60000 };
    }
    rateInfo.count++;
    wsRateLimits.set(socket.id, rateInfo);
    if (rateInfo.count > WS_MAX_MESSAGES_PER_MINUTE) {
      socket.emit('error', { message: 'Too many messages, slow down' });
      console.log('[ws] rate limit exceeded for', socket.id);
      return;
    }

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

    const from = socket.username || 'unknown';
    const msgId = Date.now().toString(36) + Math.random().toString(36).substr(2, 5);

    const envelope = {
      id: msgId,
      from: from,
      data: payload.data,
      timestamp: Date.now(),
    };

    // Don't send message back to sender (prevents duplicates)
    if (from === payload.to) {
      console.log('[skip] self-message');
      return;
    }

    const targetSocketId = onlineUsers.get(payload.to);

    if (targetSocketId) {
      // Recipient online — instant relay
      io.to(targetSocketId).emit('message', envelope);
      console.log('[relay] message delivered');

      // Notify sender: message delivered
      socket.emit('messageStatus', { msgId, status: 'delivered' });
    } else {
      // Recipient offline — buffer and send FCM push
      if (!offlineBuffer.has(payload.to)) {
        offlineBuffer.set(payload.to, []);
      }
      offlineBuffer.get(payload.to).push(envelope);
      console.log('[queue] message buffered');

      sendFcmPush(payload.to, from);
    }
  });

  // Recipient confirms message delivered
  socket.on('delivered', (msgId) => {
    if (!socket.username || !msgId) return;
    // Find sender and notify
    for (const [sid, s] of io.sockets.sockets) {
      if (s.username && s.id !== socket.id) {
        // Simple: broadcast to all (sender will filter by msgId)
      }
    }
    // More efficient: find sender from message history
    // For now, just ack back to sender
    socket.broadcast.emit('messageStatus', { msgId, status: 'delivered' });
  });

  // Recipient read messages in a conversation
  socket.on('read', (data) => {
    if (!socket.username || !data || !data.from) return;
    const senderSocketId = onlineUsers.get(data.from);
    if (senderSocketId) {
      io.to(senderSocketId).emit('messageStatus', {
        msgIds: data.msgIds || [],
        status: 'read',
        from: socket.username,
  });
}

// [FIX] Logout endpoint - invalidates session token

  // Delete message
  socket.on('deleteMessage', (payload) => {
    if (!payload || !payload.to || !payload.msgId) return;
    const from = socket.username || 'unknown';

    if (payload.forEveryone) {
      // Notify recipient to delete this message
      const targetSocketId = onlineUsers.get(payload.to);
      if (targetSocketId) {
        io.to(targetSocketId).emit('messageDeleted', {
          msgId: payload.msgId,
          from: from,
        });
      }
      console.log('[delete] message deleted for everyone');
    }
  });

  // Group message handler
  socket.on('groupMessage', (payload) => {
    if (!payload || !payload.groupId || !payload.data) return;

    const from = socket.username || 'unknown';
    const group = groups.get(payload.groupId);

    if (!group) {
      console.log('[group] unknown group');
      return;
    }

    // Send to all members except sender
    const envelope = {
      from,
      data: payload.data,
      groupId: payload.groupId,
      timestamp: Date.now(),
    };

    for (const member of group.members) {
      if (member === from) continue;
      const memberSocketId = onlineUsers.get(member);
      if (memberSocketId) {
        io.to(memberSocketId).emit('groupMessage', envelope);
      } else {
        // Buffer for offline members
        if (!offlineBuffer.has(member)) {
          offlineBuffer.set(member, []);
        }
        offlineBuffer.get(member).push(envelope);
        sendFcmPush(member, from);
      }
    }

    console.log('[group] message delivered');
  });

  // Typing indicator
  socket.on('typing', (payload) => {
    if (!payload || !payload.to) return;
    const from = socket.username || 'unknown';
    const targetSocketId = onlineUsers.get(payload.to);
    if (targetSocketId && from !== payload.to) {
      io.to(targetSocketId).emit('typing', { from });
    }
  });

  socket.on('stopTyping', (payload) => {
    if (!payload || !payload.to) return;
    const from = socket.username || 'unknown';
    const targetSocketId = onlineUsers.get(payload.to);
    if (targetSocketId && from !== payload.to) {
      io.to(targetSocketId).emit('stopTyping', { from });
    }
  });

  // Watch user status (real-time online/offline)
  socket.on('watch', (targetUsername) => {
    if (typeof targetUsername !== 'string' || !targetUsername) return;
    if (!watchers.has(targetUsername)) watchers.set(targetUsername, new Set());
    watchers.get(targetUsername).add(socket.id);

    // Send current status immediately
    const isOnline = onlineUsers.has(targetUsername);
    const ls = lastSeen.get(targetUsername) || 0;
    socket.emit('statusUpdate', { username: targetUsername, online: isOnline, lastSeen: ls });
  });

  socket.on('unwatch', (targetUsername) => {
    if (typeof targetUsername !== 'string') return;
    const set = watchers.get(targetUsername);
    if (set) set.delete(socket.id);
  });

  socket.on('disconnect', () => {
    if (socket.username) {
      onlineUsers.delete(socket.username);
      sessions.delete(socket.username);
      lastSeen.set(socket.username, Date.now());
      saveMap('last_seen.json', lastSeen);

      // Notify watchers that this user is offline
      const userWatchers = watchers.get(socket.username);
      if (userWatchers) {
        for (const sid of userWatchers) {
          io.to(sid).emit('statusUpdate', { username: socket.username, online: false, lastSeen: Date.now() });
        }
      }

      // Clean up watchers for this socket
      for (const [target, set] of watchers) {
        set.delete(socket.id);
      }

      console.log('[ws] user offline');
    }
  });
});

// ── Logs endpoint for dashboard ──────────────────────────────

const recentLogs = [];
const MAX_LOGS = 100;

// Intercept console.log/warn/error
const origLog = console.log;
const origWarn = console.warn;
const origError = console.error;

console.log = (...args) => {
  const msg = args.join(' ');
  recentLogs.push(msg);
  if (recentLogs.length > MAX_LOGS) recentLogs.shift();
  origLog(...args);
};
console.warn = (...args) => {
  const msg = args.join(' ');
  recentLogs.push(msg);
  if (recentLogs.length > MAX_LOGS) recentLogs.shift();
  origWarn(...args);
};
console.error = (...args) => {
  const msg = args.join(' ');
  recentLogs.push(msg);
  if (recentLogs.length > MAX_LOGS) recentLogs.shift();
  origError(...args);
};

// ── Admin: delete user ────────────────────────────────────

app.delete('/admin/user/:username', requireAuth, (req, res) => {
  const targetUser = req.params.username;
  
  // Нельзя удалить самого себя (админа)
  if (targetUser.toLowerCase() === 'admin') {
    return res.status(403).json({ error: 'Cannot delete admin account' });
  }
  
  // Find user (case-insensitive)
  let foundKey = null;
  for (const [key] of users) {
    if (key.toLowerCase() === targetUser.toLowerCase()) {
      foundKey = key;
      break;
    }
  }

  if (!foundKey) {
    return res.status(404).json({ error: 'User not found' });
  }
  
  // Логирование действия
  console.log(`[AUDIT] Admin deleted user: ${foundKey}`);

  users.delete(foundKey);
  onlineUsers.delete(foundKey);
  sessions.delete(foundKey);
  lastSeen.delete(foundKey);
  fcmTokens.delete(foundKey);
  saveMap('users.json', users);
  saveMap('fcm_tokens.json', fcmTokens);
  saveMap('last_seen.json', lastSeen);

  // Disconnect socket если онлайн
  const socketId = onlineUsers.get(foundKey);
  if (socketId) {
    io.to(socketId).emit('kicked', { reason: 'Account deleted by admin' });
    const sock = io.sockets.sockets.get(socketId);
    if (sock) sock.disconnect();
  }

  console.log('[admin] user deleted');
  res.json({ ok: true, deleted: foundKey });
});

app.get('/logs', requireAuth, (_req, res) => {
  res.json(recentLogs.slice(-50));
});

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

// ── Start ────────────────────────────────────────────────────

const PORT = httpsServer
  ? (process.env.HTTPS_PORT || 3443)
  : (process.env.PORT || 3000);

server.listen(PORT, '0.0.0.0', () => {
  const proto = httpsServer ? 'https' : 'http';
  console.log(`Shade ${proto} server on :${PORT}`);
});
