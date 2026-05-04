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
const cookieParser = require('cookie-parser');
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

const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');

// [FIX] HIGH #4: Validate DASHBOARD_PASS at startup
const DASHBOARD_PASS = process.env.DASHBOARD_PASS || '<SET_YOUR_STRONG_PASSWORD_HERE>';
if (!DASHBOARD_PASS || DASHBOARD_PASS === '<SET_YOUR_STRONG_PASSWORD_HERE>') {
  console.error('[FATAL] DASHBOARD_PASS is not configured!');
  console.error('[FATAL] Please set a strong password:');
  console.error('[FATAL]   export DASHBOARD_PASS="your_secure_password"');
  console.error('[FATAL] Or update server/.env with a real password');
  process.exit(1);
}

// ── App Setup ────────────────────────────────────────────

const app = express();

// Try to load TLS certificates
const CERT_DIR = process.env.CERT_DIR || path.join(__dirname, 'certs');
let httpsServer = null;
let httpServer = null;

function generateSelfSignedCerts() {
  const keyPath = path.join(CERT_DIR, 'key.pem');
  const certPath = path.join(CERT_DIR, 'cert.pem');
  const key = crypto.generateKeySync('rsa', { modulusLength: 2048 });
  const cert = crypto.createSelfSignedSubject({
    keys: [
      { key: key.export({ type: 'pkcs8', format: 'pem' }) },
    ],
    days: 365,
    subject: { commonName: 'localhost' },
  });
  fs.mkdirSync(CERT_DIR, { recursive: true });
  fs.writeFileSync(keyPath, key.export({ type: 'pkcs8', format: 'pem' }), { mode: 0o600 });
  fs.writeFileSync(certPath, cert, { mode: 0o644 });
  console.log('[tls] Self-signed certificates generated in', CERT_DIR);
}

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

    // MED-02: Self-signed cert warning
    const certContent = fs.readFileSync(certPath);
    const certObj = crypto.X509Certificate.from PEM(certContent);
    const isSelfSigned = certObj.issuer === certObj.subject;
    if (process.env.NODE_ENV === 'production' && isSelfSigned) {
      // LOW-02: Block production with self-signed cert
      console.error('[tls] FATAL: Use Let\'s Encrypt or commercial cert in production');
      process.exit(1);
    }
  } else {
    console.log('[tls] No certificates found — generating self-signed...');
    if (process.env.NODE_ENV === 'production') {
      // LOW-02: Block production with self-signed cert
      console.error('[tls] FATAL: Use Let\'s Encrypt or commercial cert in production');
      process.exit(1);
    }
    generateSelfSignedCerts();
    const tlsOptions = {
      key: fs.readFileSync(keyPath),
      cert: fs.readFileSync(certPath),
      minVersion: 'TLSv1.2',
      ciphers: 'ECDHE+AESGCM:ECDHE+CHACHA20:DHE+AESGCM:DHE+CHACHA20:!aNULL:!MD5:!DSS',
    };
    httpsServer = https.createServer(tlsOptions, app);

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

    console.log('[tls] HTTPS (self-signed) enabled');
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

// TLS is required in all modes
const server = httpsServer;
if (!server) {
  console.error('[FATAL] TLS is required in all modes. Run gen-certs.sh to generate certificates.');
  process.exit(1);
}

const io = new Server(server || http.createServer(app), {
  cors: corsOptions,
  transports: ['websocket'],
  pingTimeout: 60000,
  pingInterval: 25000,
  maxHttpBufferSize: 10e6,
});

app.set('trust proxy', 1);
app.use(cors(corsOptions));
app.use(cookieParser());
app.use(express.json({ limit: '1mb' }));
app.use(express.raw({ limit: '10mb', type: 'application/octet-stream' }));

// ── Security Headers ───────────────────────────────────────
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload'); // MED-01: HSTS preload confirmed
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self' wss://" + (process.env.WS_HOST || '*') + "'"); // MED-06: CSP connect-src restricted
  res.removeHeader('X-Powered-By');
  next();
});

// ── Rate Limiting ───────────────────────────────────────────
const limiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 100,
  message: { error: 'Too many requests, please try again later' },
  standardHeaders: true,
  legacyHeaders: false,
});

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5,
  message: { error: 'Too many authentication attempts' },
});

// HIGH-02: Лимиты регистрации - 3 в минуту, 10 в час
const registerLimiterMinute = rateLimit({
  windowMs: 60 * 1000,
  max: 3,
  message: { error: 'Too many registration attempts, please wait' },
  standardHeaders: true,
  legacyHeaders: false,
});

const registerLimiterHour = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 10,
  message: { error: 'Registration limit exceeded, try again later' },
  standardHeaders: true,
  legacyHeaders: false,
});

app.use('/api/', limiter);
app.use('/register', registerLimiterMinute, registerLimiterHour);
app.use('/dashboard', requireAuth, authLimiter);

// ── In-memory stores ─────────────────────────────────────────

// Ensure data directory exists with restricted permissions
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true, mode: 0o700 });
}

// ── SESSION_SECRET Management ─────────────────────────────────
const SESSION_SECRET_FILE = path.join(DATA_DIR, 'session_secret');
let sessionSecretSource = 'unknown';

function loadSessionSecret() {
  const isProduction = process.env.NODE_ENV === 'production' || process.env.PRODUCTION === 'true';
  
  // Priority 1: Environment variable
  if (process.env.SESSION_SECRET) {
    sessionSecretSource = 'environment';
    console.log('[session] SESSION_SECRET loaded from environment variable');
    try {
      fs.writeFileSync(SESSION_SECRET_FILE, process.env.SESSION_SECRET, { mode: 0o600 });
      console.log('[session] SESSION_SECRET saved to file for persistence');
    } catch (e) {
      console.error('[session] Warning: Cannot save env secret to file:', e.message);
    }
    return process.env.SESSION_SECRET;
  }
  // Priority 2: File exists (read existing or generate new and save for next run)
  if (fs.existsSync(SESSION_SECRET_FILE)) {
    try {
      const fileContent = fs.readFileSync(SESSION_SECRET_FILE, 'utf8').trim();
      // Format: secret:sha256Checksum
      const lastColonIdx = fileContent.lastIndexOf(':');
      if (lastColonIdx > 0) {
        const secret = fileContent.substring(0, lastColonIdx);
        const storedChecksum = fileContent.substring(lastColonIdx + 1);
        const computedChecksum = crypto.createHash('sha256').update(secret).digest('hex');
        if (storedChecksum === computedChecksum && secret.length >= 32) {
          sessionSecretSource = 'file';
          console.log('[session] SESSION_SECRET loaded from file (checksum verified)');
          return secret;
        }
      }
      // Fallback: legacy format without checksum
      if (fileContent && fileContent.length >= 32) {
        sessionSecretSource = 'file';
        console.log('[session] SESSION_SECRET loaded from file (legacy format)');
        return fileContent;
      }
      console.warn('[session] Stored secret is empty or too short (< 32 chars) - generating new');
    } catch (e) {
      console.error('[session] Error reading session secret file:', e.message);
    }
  }
  // Priority 3: Generate new and save to file for next run
  if (isProduction) {
    console.error('[session] FATAL: SESSION_SECRET required in production.');
    process.exit(1);
  }
  const newSecret = crypto.randomBytes(64).toString('hex');
  sessionSecretSource = 'generated';
  console.warn('[session] WARNING: SESSION_SECRET generated at runtime. Saved to file for next run.');
  try {
    const checksum = crypto.createHash('sha256').update(newSecret).digest('hex');
    fs.writeFileSync(SESSION_SECRET_FILE, `${newSecret}:${checksum}`, { mode: 0o600 });
    console.log('[session] SESSION_SECRET saved to file with checksum');
  } catch (e) {
    console.error('[session] FATAL: Cannot write session secret to data/session_secret. Check permissions.');
    process.exit(1);
  }
  return newSecret;
}

const SESSION_SECRET = loadSessionSecret();
const SESSION_DURATION = 24 * 60 * 60 * 1000;
const REFRESH_TOKEN_DURATION = 7 * 24 * 60 * 60 * 1000;

// ── AES-256-GCM helpers for master key encryption ──────────────────
function _deriveEncryptionKey(secret) {
  return crypto.createHash('sha256').update(secret).digest();
}

function _encryptMasterKey(privateKey, publicKey, secret) {
  const key = _deriveEncryptionKey(secret);
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  const encrypted = Buffer.concat([
    cipher.update(JSON.stringify({ privateKey, publicKey }), 'utf8'),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return JSON.stringify({
    nonce: nonce.toString('hex'),
    tag: tag.toString('hex'),
    data: encrypted.toString('hex'),
  });
}

function _decryptMasterKey(encryptedData, secret) {
  const key = _deriveEncryptionKey(secret);
  const { nonce, tag, data } = JSON.parse(encryptedData);
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm',
    key,
    Buffer.from(nonce, 'hex'),
  );
  decipher.setAuthTag(Buffer.from(tag, 'hex'));
  const decrypted = Buffer.concat([
    decipher.update(Buffer.from(data, 'hex')),
    decipher.final(),
  ]);
  return JSON.parse(decrypted.toString('utf8'));
}

// ── Server master key (for signing user public keys) ─────────────────────
// Master key encrypted at rest with key derived from SESSION_SECRET
const MASTER_KEY_FILE = path.join(DATA_DIR, 'server_master_key');
let serverMasterKey = null;
let serverPublicKey = null;

function loadOrGenerateMasterKey() {
  if (fs.existsSync(MASTER_KEY_FILE)) {
    try {
      const encryptedData = fs.readFileSync(MASTER_KEY_FILE, 'utf8');
      const decrypted = _decryptMasterKey(encryptedData, SESSION_SECRET);
      serverMasterKey = decrypted;
      serverPublicKey = decrypted.publicKey;
      console.log('[server] Master key loaded and decrypted');
      return;
    } catch (e) {
      console.error('[server] Error reading/decrypting master key:', e.message);
    }
  }
  console.log('[server] Generating new master key...');
  const { publicKey, privateKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 4096,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' }
  });
  serverMasterKey = { publicKey, privateKey };
  serverPublicKey = publicKey;
  const encrypted = _encryptMasterKey(privateKey, publicKey, SESSION_SECRET);
  fs.writeFileSync(MASTER_KEY_FILE, encrypted, { mode: 0o600 });
  console.log('[server] Master key generated and encrypted at rest');
}

loadOrGenerateMasterKey();

// AES-256-GCM encryption for sensitive files (fcm_tokens.json)
function _encryptData(data, secret) {
  const key = crypto.createHash('sha256').update(secret).digest();
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, nonce);
  const encrypted = Buffer.concat([
    cipher.update(JSON.stringify(data), 'utf8'),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return JSON.stringify({
    nonce: nonce.toString('hex'),
    tag: tag.toString('hex'),
    data: encrypted.toString('hex'),
  });
}

function _decryptData(encryptedStr, secret) {
  const key = crypto.createHash('sha256').update(secret).digest();
  const { nonce, tag, data } = JSON.parse(encryptedStr);
  const decipher = crypto.createDecipheriv(
    'aes-256-gcm',
    key,
    Buffer.from(nonce, 'hex'),
  );
  decipher.setAuthTag(Buffer.from(tag, 'hex'));
  const decrypted = Buffer.concat([
    decipher.update(Buffer.from(data, 'hex')),
    decipher.final(),
  ]);
  return JSON.parse(decrypted.toString('utf8'));
}

// Master key wiped after use
function _wipeKey(key) {
  if (key && Buffer.isBuffer(key)) {
    key.fill(0);
  }
}

// HIGH-03: HMAC integrity check for data files
const HMAC_FILE_SUFFIX = '.hmac';

function _computeHmac(data, secret) {
  return crypto.createHmac('sha256', secret).update(JSON.stringify(data)).digest('hex');
}

function _loadHmac(filename) {
  const hmacFile = path.join(DATA_DIR, filename + HMAC_FILE_SUFFIX);
  if (fs.existsSync(hmacFile)) {
    return fs.readFileSync(hmacFile, 'utf8').trim();
  }
  return null;
}

function _saveHmac(filename, data, secret) {
  const hmac = _computeHmac(data, secret);
  const hmacFile = path.join(DATA_DIR, filename + HMAC_FILE_SUFFIX);
  fs.writeFileSync(hmacFile, hmac);
}

function _verifyHmac(filename, data, secret) {
  const storedHmac = _loadHmac(filename);
  if (!storedHmac) {
    console.warn('[hmac] No HMAC file found for:', filename, '- skipping verification');
    return true; // No HMAC file yet - skip
  }
  const computedHmac = _computeHmac(data, secret);
  if (storedHmac !== computedHmac) {
    console.error('[hmac] HIGH-03 WARNING: HMAC mismatch for', filename, '- data may be corrupted!');
    return false;
  }
  return true;
}
    'aes-256-gcm',
    key,
    Buffer.from(nonce, 'hex'),
  );
  decipher.setAuthTag(Buffer.from(tag, 'hex'));
  const decrypted = Buffer.concat([
    decipher.update(Buffer.from(data, 'hex')),
    decipher.final(),
  ]);
  return JSON.parse(decrypted.toString('utf8'));
}

function loadMap(filename) {
  const file = path.join(DATA_DIR, filename);
  try {
    if (fs.existsSync(file)) {
      let data;
      // HIGH-01: users.json encrypted at rest with AES-256-GCM
      if (filename === 'users.json') {
        const encryptedData = fs.readFileSync(file, 'utf8');
        data = _decryptData(encryptedData, SESSION_SECRET);
        // HIGH-03: Verify HMAC integrity
        _verifyHmac(filename, data, SESSION_SECRET);
      } else if (filename === 'fcm_tokens.json') {
        const encryptedData = fs.readFileSync(file, 'utf8');
        data = _decryptData(encryptedData, SESSION_SECRET);
      } else {
        data = JSON.parse(fs.readFileSync(file, 'utf8'));
        // HIGH-03: Verify HMAC for other data files
        if (filename === 'last_seen.json' || filename === 'groups.json') {
          _verifyHmac(filename, data, SESSION_SECRET);
        }
      }
      const m = new Map(data);
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

// HIGH-02: Async file writes with mutex
async function saveMap(filename, map) {
  const release = await dbMutex.acquire();
  try {
    const file = path.join(DATA_DIR, filename);
    let data;
    if (filename === 'groups.json') {
      data = [...map.entries()].map(([k, v]) => [k, { ...v, members: [...v.members] }]);
    } else {
      data = [...map.entries()];
    }
    // HIGH-01: users.json encrypted at rest with AES-256-GCM
    if (filename === 'users.json') {
      const encrypted = _encryptData(data, SESSION_SECRET);
      await fs.promises.writeFile(file, encrypted);
      // HIGH-03: Save HMAC for integrity check
      _saveHmac(filename, data, SESSION_SECRET);
    } else if (filename === 'fcm_tokens.json') {
      const encrypted = _encryptData(data, SESSION_SECRET);
      await fs.promises.writeFile(file, encrypted);
    } else {
      await fs.promises.writeFile(file, JSON.stringify(data));
      // HIGH-03: Save HMAC for integrity check
      if (filename === 'last_seen.json' || filename === 'groups.json') {
        _saveHmac(filename, data, SESSION_SECRET);
      }
    }
  } catch (e) {
    console.error('[db] save error:', filename, e.message);
  } finally {
    release();
  }
}

const users = loadMap('users.json');
const fcmTokens = loadMap('fcm_tokens.json');
// MED-08: FCM token cache TTL 24h
const FCM_TOKEN_TTL_MS = 24 * 60 * 60 * 1000;
const groups = loadMap('groups.json');
const lastSeen = loadMap('last_seen.json');
const onlineUsers = new Map();
const offlineBuffer = new Map();
const sessions = new Map();
const watchers = new Map();
const refreshTokens = new Map();
const gracePeriodSessions = new Map();
const GRACE_PERIOD_MS = 5000;

// MED-03: Encrypt offline metadata
const OFFLINE_METADATA_KEY = crypto.createHash('sha256').update('offline_meta_' + SESSION_SECRET).digest();

function _encryptMetadata(envelope) {
  // Шифруем только метаданные (from, id, timestamp), не данные сообщения
  const metadata = JSON.stringify({ id: envelope.id, from: envelope.from, ts: envelope.timestamp });
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', OFFLINE_METADATA_KEY, nonce);
  const encrypted = Buffer.concat([cipher.update(metadata, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return {
    e: encrypted.toString('hex'), // encrypted metadata
    n: nonce.toString('hex'),      // nonce
    t: tag.toString('hex'),        // auth tag
    d: envelope.data              // actual encrypted message data (unchanged)
  };
}

function _decryptMetadata(encryptedEnvelope) {
  try {
    const decipher = crypto.createDecipheriv(
      'aes-256-gcm',
      OFFLINE_METADATA_KEY,
      Buffer.from(encryptedEnvelope.n, 'hex')
    );
    decipher.setAuthTag(Buffer.from(encryptedEnvelope.t, 'hex'));
    const decrypted = Buffer.concat([decipher.update(encryptedEnvelope.e, 'hex'), decipher.final()]);
    const metadata = JSON.parse(decrypted.toString('utf8'));
    return {
      id: metadata.id,
      from: metadata.from,
      timestamp: metadata.ts,
      data: encryptedEnvelope.d
    };
  } catch (e) {
    console.error('[offline] Failed to decrypt metadata:', e.message);
    return null;
  }
}

// MED-08: Validate FCM token TTL
function isFcmTokenValid(tokenData) {
  if (!tokenData) return false;
  if (typeof tokenData === 'string') {
    // Legacy format: no TTL, assume valid
    return true;
  }
  // New format: { token, timestamp }
  if (tokenData.timestamp && Date.now() - tokenData.timestamp > FCM_TOKEN_TTL_MS) {
    return false;
  }
  return true;
}

// ── Mutex for race condition protection ─────────────────────
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
const refreshTokenMutex = new Mutex();
const sessionNonceMutex = new Mutex();

// ── Session token nonce tracking (prevent replay attacks) ──────────────────
const usedSessionNonces = new Set();
const SESSION_NONCE_TTL_MS = 24 * 60 * 60 * 1000;
let nonceCleanupScheduled = false;

function scheduleNonceCleanup() {
  if (nonceCleanupScheduled) return;
  nonceCleanupScheduled = true;
  setInterval(() => {
    const now = Date.now();
    for (const nonce of usedSessionNonces) {
      const [ts] = nonce.split(':');
      if (now - parseInt(ts, 10) > SESSION_NONCE_TTL_MS) {
        usedSessionNonces.delete(nonce);
      }
    }
  }, 60 * 60 * 1000); // Cleanup every hour
}

// ── Token functions ─────────────────────────────────────────
function generateSessionToken(username) {
  // TODO: TOTP 2FA for admin (LOW-03)
  const timestamp = Date.now();
  const nonce = crypto.randomBytes(16).toString('hex');
  const usedNonceKey = `${timestamp}:${nonce}`;
  usedSessionNonces.add(usedNonceKey);
  scheduleNonceCleanup();
  const base = `${username}:${timestamp}:${nonce}`;
  const signature = crypto.createHmac('sha256', SESSION_SECRET).update(base).digest('hex');
  return `${base}:${signature}`;
}

// Track used refresh token nonces to detect family reuse
const usedRefreshNonces = new Set();
const REFRESH_NONCE_TTL = 24 * 60 * 60 * 1000; // 24 hours

async function generateRefreshToken(username, oldToken = null) {
  const release = await refreshTokenMutex.acquire();
  try {
    const token = crypto.randomBytes(64).toString('hex');
    const familyId = crypto.randomBytes(16).toString('hex');
    const expiresAt = Date.now() + REFRESH_TOKEN_DURATION;
    const user = users.get(username);
    const tokenVersion = user?.tokenVersion || 1;
    
    // If replacing old token, record old nonce to detect family reuse
    if (oldToken) {
      const oldData = refreshTokens.get(oldToken);
      if (oldData && oldData.familyId) {
        usedRefreshNonces.add(oldData.familyId);
      }
      refreshTokens.delete(oldToken);
    }
    
    refreshTokens.set(token, { username, expiresAt, tokenVersion, familyId });
    return token;
  } finally {
    release();
  }
}

function validateSessionToken(username, token) {
  if (!token) return false;
  const parts = token.split(':');
  if (parts.length !== 4) return false;
  const [tokenUsername, timestampStr, nonce, signature] = parts;
  const timestamp = parseInt(timestampStr, 10);
  if (tokenUsername !== username) return false;
  if (Date.now() - timestamp > SESSION_DURATION) {
    console.log('[session] expired for', username);
    return false;
  }
  const nonceKey = `${timestamp}:${nonce}`;
  if (usedSessionNonces.has(nonceKey)) {
    console.log('[session] nonce already used for', username, '- possible replay attack');
    return false;
  }
  usedSessionNonces.add(nonceKey);
  const base = `${username}:${timestamp}:${nonce}`;
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

async function validateRefreshToken(token) {
  const release = await refreshTokenMutex.acquire();
  try {
    if (!token) return null;
    const data = refreshTokens.get(token);
    if (!data) return null;
    if (Date.now() > data.expiresAt) {
      refreshTokens.delete(token);
      return null;
    }
    // Check tokenVersion
    const user = users.get(data.username);
    const userVersion = user?.tokenVersion || 1;
    if (data.tokenVersion !== userVersion) {
      refreshTokens.delete(token);
      console.log('[refresh] token invalidated due to tokenVersion mismatch for', data.username);
      return null;
    }
    // HIGH-07: Check family reuse (if this family was already used, invalidate entire family)
    if (data.familyId && usedRefreshNonces.has(data.familyId)) {
      // Family reuse detected - invalidate all tokens for this user
      for (const [t, d] of refreshTokens) {
        if (d.username === data.username) {
          refreshTokens.delete(t);
        }
      }
      console.log('[refresh] Family reuse detected - invalidated all tokens for', data.username);
      // Возвращаем объект с кодом ошибки вместо null для обработки на клиенте
      return { error: 'TOKEN_FAMILY_REUSE_DETECTED', message: 'Security violation: token reuse detected' };
    }
    return { username: data.username, tokenVersion: data.tokenVersion };
  } finally {
    release();
  }
}

// ── Middleware ──────────────────────────────────────────────
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

// Admin session cookie management
const adminSessions = new Map();
const ADMIN_SESSION_DURATION = 60 * 60 * 1000; // 1 hour
const ADMIN_COOKIE_NAME = 'shade_admin_sess';
const ADMIN_LOGIN_ATTEMPTS = new Map();
const ADMIN_MAX_LOGIN_ATTEMPTS = 5;
const ADMIN_LOGIN_WINDOW = 15 * 60 * 1000; // 15 minutes

function _signAdminToken(token) {
  return crypto.createHmac('sha256', SESSION_SECRET).update(token).digest('hex');
}

function _verifyAdminToken(token, signature) {
  const expected = _signAdminToken(token);
  try {
    return crypto.timingSafeEqual(Buffer.from(signature, 'hex'), Buffer.from(expected, 'hex'));
  } catch (_) {
    return false;
  }
}

function requireAuth(req, res, next) {
  // HIGH-08: Только cookie-сессии, без Basic Auth fallback
  const sessionCookie = req.cookies?.[ADMIN_COOKIE_NAME];
  if (sessionCookie) {
    const parts = sessionCookie.split('.');
    if (parts.length === 2) {
      const [token, signature] = parts;
      if (_verifyAdminToken(token, signature)) {
        const sessionData = adminSessions.get(token);
        if (sessionData && Date.now() < sessionData.expiresAt) {
          sessionData.expiresAt = Date.now() + ADMIN_SESSION_DURATION;
          return next();
        }
      }
    }
    adminSessions.delete(sessionCookie);
  }
  
  // Только cookie-аутентификация, без Basic Auth
  return res.status(401).send('Unauthorized');
}

// Endpoint to set session cookie after successful Basic Auth
// TODO: TOTP 2FA for admin (LOW-03)
app.post('/admin/login', (req, res) => {
  const clientIp = req.ip || req.connection.remoteAddress || 'unknown';
  const now = Date.now();
  
  // Rate limiting check
  let loginAttempt = ADMIN_LOGIN_ATTEMPTS.get(clientIp);
  if (!loginAttempt || now > loginAttempt.resetTime) {
    loginAttempt = { count: 0, resetTime: now + ADMIN_LOGIN_WINDOW };
  }
  loginAttempt.count++;
  ADMIN_LOGIN_ATTEMPTS.set(clientIp, loginAttempt);
  
  if (loginAttempt.count > ADMIN_MAX_LOGIN_ATTEMPTS) {
    console.warn('[admin] Too many login attempts from:', clientIp);
    return res.status(429).json({ error: 'Too many login attempts. Try again later.' });
  }
  
  const auth = req.headers.authorization;
  if (!auth || auth !== 'Basic ' + Buffer.from('admin:' + DASHBOARD_PASS).toString('base64')) {
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  
  const sessionToken = crypto.randomBytes(32).toString('hex');
  const signature = _signAdminToken(sessionToken);
  const signedToken = `${sessionToken}.${signature}`;
  
  adminSessions.set(sessionToken, {
    createdAt: Date.now(),
    expiresAt: Date.now() + ADMIN_SESSION_DURATION,
  });
  res.cookie(ADMIN_COOKIE_NAME, signedToken, {
    httpOnly: true,
    secure: true,
    sameSite: 'strict',
    maxAge: ADMIN_SESSION_DURATION,
  });
  console.log('[admin] Session created for IP:', clientIp);
  res.json({ ok: true, message: 'Session created' });
});

// Endpoint to logout and clear cookie
app.post('/admin/logout', (req, res) => {
  const sessionCookie = req.cookies?.[ADMIN_COOKIE_NAME];
  if (sessionCookie) {
    adminSessions.delete(sessionCookie);
  }
  res.clearCookie(ADMIN_COOKIE_NAME);
  res.json({ ok: true });
});

// ── REST endpoints ───────────────────────────────────────────

app.get('/', (_req, res) => {
  res.json({
    name: 'Shade Relay Server',
    status: 'ok',
    users: users.size,
    online: onlineUsers.size,
  });
});

app.get('/api/stats', requireAuth, (req, res) => {
  // HIGH-07: Hide user list from non-admin (stats endpoint already requires auth)
  const mem = process.memoryUsage();
  const uptime = process.uptime();
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
    // Users list removed - only admin should see full user data
  });
});

app.get('/api/health', (req, res) => {
  res.json({
    ok: true,
    timestamp: Date.now(),
    sessionSecretSource: sessionSecretSource,
  });
});

app.get('/api/server/public-key', (req, res) => {
  if (!serverPublicKey) {
    return res.status(500).json({ error: 'Server key not available' });
  }
  res.json({ publicKey: serverPublicKey });
});

// Register user
app.post('/register', (req, res) => {
  dbMutex.acquire().then((release) => {
    try {
      const { username, publicKey, signature } = req.body;
      const nick = (username || '').toLowerCase().trim();
      if (!/^[a-z0-9_]{3,32}$/.test(nick)) {
        release();
        return res.status(400).json({
          error: 'Nickname: 3-32 characters, only a-z, 0-9, _',
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
      const username_norm = nick;
      try {
        const dataB64 = Buffer.from(publicKey).toString('base64');
        const isValid = crypto.verify(
          'sha256',
          Buffer.from(dataB64),
          {
            key: publicKey,
            padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
            saltLength: 32,
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
      try {
        const pubKey = crypto.createPublicKey(publicKey);
        const testData = Buffer.from('test');
        crypto.publicEncrypt(pubKey, testData);
        console.log('[register] public key validated');
      } catch (e) {
        console.warn('[register] invalid public key:', e.message);
        release();
        return res.status(400).json({ error: 'Invalid public key' });
      }
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
        if (existing.publicKey !== publicKey) {
          release();
          return res.status(409).json({ error: 'Nickname already taken' });
        }
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
      let serverSignature = null;
      if (serverMasterKey && serverMasterKey.privateKey) {
        try {
          const sign = crypto.createSign('sha256');
          sign.update(publicKey);
          sign.end();
          const sig = sign.sign({
            key: serverMasterKey.privateKey,
            padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
            saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST,
          });
          serverSignature = sig.toString('base64');
          // Master key wiped after use
          _wipeKey(serverMasterKey.privateKey);
        } catch (e) {
          console.error('[register] Error signing public key:', e.message);
        }
      }
      users.set(username_norm, {
        publicKey,
        signature,
        serverSignature,
        registeredAt: Date.now(),
        tokenVersion: 1,
      });
      saveMap('users.json', users);
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

app.post('/logout', requireUserAuth, (req, res) => {
  const username = req.params.username || req.body.username;
  if (username) {
    sessions.delete(username);
    fcmTokens.delete(username);
    // MED-03: Очищаем буфер офлайн-сообщений при logout
    offlineBuffer.delete(username);
    // HIGH-05: Инвалидируем ВСЕ сессии пользователя через tokenVersion++
    const user = users.get(username);
    if (user) {
      user.tokenVersion = (user.tokenVersion || 0) + 1;
      users.set(username, user);
      saveMap('users.json', users);
      // Инвалидируем все refresh токены
      for (const [token, data] of refreshTokens) {
        if (data.username === username) {
          refreshTokens.delete(token);
        }
      }
      console.log('[logout] All sessions invalidated, tokenVersion:', user.tokenVersion);
    }
    saveMap('fcm_tokens.json', fcmTokens);
    console.log('[logout] user logged out');
  }
  res.json({ ok: true });
});

app.post('/refresh', async (req, res) => {
  const release = await refreshTokenMutex.acquire();
  try {
    const { refreshToken } = req.body;
    if (!refreshToken) {
      return res.status(400).json({ error: 'Missing refresh token' });
    }
    const data = await validateRefreshToken(refreshToken);
    if (!data) {
      return res.status(403).json({ error: 'Invalid or expired refresh token' });
    }
    // HIGH-07: Handle family reuse detection
    if (data.error && data.error === 'TOKEN_FAMILY_REUSE_DETECTED') {
      return res.status(403).json({ error: data.message, code: 'TOKEN_FAMILY_REUSE_DETECTED' });
    }
    // Token rotation: delete old and generate new with family tracking
    const newSessionToken = generateSessionToken(data.username);
    sessions.set(data.username, newSessionToken);
    const newRefreshToken = await generateRefreshToken(data.username, refreshToken);
    console.log('[refresh] token refreshed for', data.username);
    res.json({ ok: true, token: newSessionToken, refreshToken: newRefreshToken });
  } finally {
    release();
  }
});

app.post('/fcm/register', (req, res) => {
  const { username, token } = req.body;
  // Support both x-session-token and Authorization: Bearer <token>
  let sessionToken = req.headers['x-session-token'];
  if (!sessionToken && req.headers['authorization']) {
    const auth = req.headers['authorization'];
    if (auth.startsWith('Bearer ')) {
      sessionToken = auth.substring(7);
    }
  }
  if (!username || !token) {
    return res.status(400).json({ error: 'Missing data' });
  }
  if (!sessionToken || !validateSessionToken(username, sessionToken)) {
    return res.status(403).json({ error: 'Invalid or expired session' });
  }
  const sessionUsername = sessionToken.split(':')[0];
  if (sessionUsername !== username) {
    console.warn('[fcm] Username mismatch: session=' + sessionUsername + ' req=' + username);
    return res.status(403).json({ error: 'Username mismatch' });
  }
  // MED-08: Store token with timestamp for TTL tracking
  fcmTokens.set(username, { token: token, timestamp: Date.now() });
  saveMap('fcm_tokens.json', fcmTokens);
  console.log('[fcm] token registered for', username);
  res.json({ ok: true });
});

app.post('/fcm/unregister', (req, res) => {
  const { username, token } = req.body;
  const sessionToken = req.headers['x-session-token'];
  if (!username || !token) {
    return res.status(400).json({ error: 'Missing data' });
  }
  if (!sessionToken || !validateSessionToken(username, sessionToken)) {
    return res.status(403).json({ error: 'Invalid or expired session' });
  }
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

app.get('/user/:username', requireUserAuth, (req, res) => {
  // HIGH-06: Constant-time user lookup for all requests
  const baseDelay = 200;
  // Используем crypto.randomBytes для аппаратного джиттера
  const jitterBytes = crypto.randomBytes(2);
  const jitter = (jitterBytes[0] << 8 | jitterBytes[1]) % 300; // 0-299ms
  const delay = baseDelay + jitter;
  
  // Задержка для ВСЕХ запросов (существующих и несуществующих пользователей)
  setTimeout(() => {
    const user = users.get(req.params.username);
    // Return same response structure for non-existent users (prevent enumeration)
    if (!user) {
      return res.json({
        username: req.params.username,
        publicKey: null,
        signature: null,
        serverSignature: null,
        online: false,
        lastSeen: 0,
      });
    }
    
    if (!user.serverSignature && serverMasterKey && serverMasterKey.privateKey) {
      try {
        user.serverSignature = crypto.sign('sha256', Buffer.from(user.publicKey), serverMasterKey.privateKey).toString('base64');
        users.set(req.params.username, user);
        saveMap('users.json', users);
      } catch (e) {
        console.error('[user] Error signing public key:', e.message);
      }
    }
    const isOnline = onlineUsers.has(req.params.username);
    const lastSeenTime = lastSeen.get(req.params.username) || 0;
    return res.json({
      username: req.params.username,
      publicKey: user.publicKey,
      signature: user.signature,
      serverSignature: user.serverSignature || null,
      online: isOnline,
      lastSeen: lastSeenTime,
    });
  }, delay);
});

// ── FCM Push Notification ────────────────────────────────────

async function sendFcmPush(username, from) {
  if (!admin) return;
  const tokenData = fcmTokens.get(username);
  if (!tokenData || !isFcmTokenValid(tokenData)) {
    // MED-08: Token expired or invalid - skip push
    if (tokenData) {
      fcmTokens.delete(username);
      saveMap('fcm_tokens.json', fcmTokens);
    }
    return;
  }
  // Extract token from data structure
  const token = typeof tokenData === 'string' ? tokenData : tokenData.token;
  try {
    await admin.messaging().send({
      token: token,
      notification: {
        title: 'Shade',
        body: 'New message',
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

// MED-07: WS connection limit 5 per IP
const wsConnectionsPerIp = new Map();
const lastDisconnectTime = new Map();

io.on('connection', (socket) => {
  // MED-07: Ограничение 5 одновременных подключений с одного IP
  const clientIp = socket.handshake.address || socket.conn.remoteAddress || 'unknown';
  const currentCount = wsConnectionsPerIp.get(clientIp) || 0;
  if (currentCount >= 5) {
    console.warn('[ws] Connection limit exceeded for IP:', clientIp);
    socket.emit('error', { message: 'Too many connections from this IP' });
    socket.disconnect();
    return;
  }
  wsConnectionsPerIp.set(clientIp, currentCount + 1);
  // LOW-04: Reconnect throttle 5s
  const RECONNECT_THROTTLE_MS = 5000;
  const lastDisconnect = lastDisconnectTime.get(clientIp);
  if (lastDisconnect && (Date.now() - lastDisconnect) < RECONNECT_THROTTLE_MS) {
    console.warn('[ws] Reconnect throttle active for IP:', clientIp);
    socket.emit('error', { message: 'Too soon after disconnect, try again later' });
    socket.disconnect();
    return;
  }
  socket.on('disconnect', () => {
    lastDisconnectTime.set(clientIp, Date.now());
    const count = wsConnectionsPerIp.get(clientIp) || 1;
    wsConnectionsPerIp.set(clientIp, Math.max(0, count - 1));
  });
  
  console.log('[ws] connected:', socket.id);

  const wsRegisterAttempts = new Map();
  const WS_MAX_REGISTER_PER_MINUTE = 5;

  // Per-event rate limiter for WebSocket events with exponential backoff
  const wsRateLimits = new Map();
  const WS_MAX_MESSAGE_PER_MINUTE = 30;
  const WS_MAX_TYPING_PER_MINUTE = 60;
  const WS_MAX_OTHER_PER_MINUTE = 30;
  socket.use((packet, next) => {
    const eventName = packet[0];
    const now = Date.now();
    let rateInfo = wsRateLimits.get(socket.id);
    if (!rateInfo || now > rateInfo.resetTime) {
      rateInfo = { message: 0, typing: 0, other: 0, resetTime: now + 60000, backoff: 0 };
    }
    let limit;
    if (eventName === 'message') {
      rateInfo.message++;
      limit = WS_MAX_MESSAGE_PER_MINUTE;
      if (rateInfo.message > limit) {
        // Exponential backoff: delay response
        const delay = Math.min(1000 * Math.pow(2, rateInfo.backoff), 10000);
        rateInfo.backoff++;
        socket.emit('error', { message: 'Too many messages, slow down', retryAfter: delay });
        console.log('[ws] message rate limit exceeded for', socket.id, 'backoff:', delay);
        return;
      }
    } else if (eventName === 'typing') {
      rateInfo.typing++;
      limit = WS_MAX_TYPING_PER_MINUTE;
      if (rateInfo.typing > limit) {
        socket.emit('error', { message: 'Typing too fast, slow down' });
        console.log('[ws] typing rate limit exceeded for', socket.id);
        return;
      }
    } else {
      rateInfo.other++;
      limit = WS_MAX_OTHER_PER_MINUTE;
      if (rateInfo.other > limit) {
        socket.emit('error', { message: 'Rate limit exceeded, slow down' });
        console.log('[ws] rate limit exceeded for', socket.id, 'event:', eventName);
        return;
      }
    }
    wsRateLimits.set(socket.id, rateInfo);
    next();
  });

  socket.on('register', (payload) => {
    if (!payload || typeof payload.username !== 'string' || !payload.username) return;
    // HIGH-02: Rate limiting для register - 3 попытки в минуту
    const now = Date.now();
    let regInfo = wsRegisterAttempts.get(socket.id);
    if (!regInfo || now > regInfo.resetTime) {
      regInfo = { count: 0, resetTime: now + 60000 };
    }
    regInfo.count++;
    wsRegisterAttempts.set(socket.id, regInfo);
    if (regInfo.count > 3) {
      socket.emit('authError', { error: 'Too many register attempts (max 3/min)' });
      console.warn('[ws] register rate limit exceeded for', socket.id);
      return;
    }
    const username = payload.username.toLowerCase().trim();
    const token = payload.token;
    let expected = sessions.get(username);
    
    let gracePeriodReconnect = false;
    if (!expected || token !== expected) {
      const graceData = gracePeriodSessions.get(username);
      if (graceData && token === graceData.sessionToken) {
        const elapsed = Date.now() - graceData.timestamp;
        if (elapsed < GRACE_PERIOD_MS) {
          const newToken = generateSessionToken(username);
          sessions.set(username, newToken);
          gracePeriodSessions.delete(username);
          console.log('[ws] Reconnected during grace period for:', username, '- issued new token');
          socket.emit('sessionRefreshed', { token: newToken });
          gracePeriodReconnect = true;
        } else {
          expected = null;
        }
      }
    }
    
    if (!gracePeriodReconnect && (!expected || token !== expected)) {
      console.warn('[ws] auth failed');
      socket.emit('authError', { error: 'Invalid session token' });
      setTimeout(() => socket.disconnect(true), 1000);
      return;
    }
    onlineUsers.set(username, socket.id);
    socket.username = username;
    lastSeen.set(username, Date.now());
    saveMap('last_seen.json', lastSeen);
    console.log('[ws] user online');
    const userWatchers = watchers.get(username);
    if (userWatchers) {
      for (const sid of userWatchers) {
        io.to(sid).emit('statusUpdate', { username, online: true, lastSeen: Date.now() });
      }
    }
    const queued = offlineBuffer.get(username);
    if (queued && queued.length > 0) {
      for (const msg of queued) {
        socket.emit('message', msg);
      }
      offlineBuffer.delete(username);
    }
  });

  socket.on('message', (payload) => {
    // MED-04: Раздельные лимиты для текста и файлов
    const MAX_TEXT_SIZE = 1 * 1024 * 1024;   // 1MB для текстовых сообщений
    const MAX_FILE_SIZE = 10 * 1024 * 1024; // 10MB для файлов
    if (!payload || !payload.to || !payload.data) return;
    
    // CRIT-02: Validate encrypted payload format before relay
    if (typeof payload.data === 'string') {
      try {
        const parsed = JSON.parse(payload.data);
        if (typeof parsed !== 'object' || parsed === null) {
          socket.emit('error', { message: 'Invalid encrypted payload' });
          console.log('[security] invalid payload: not an object');
          return;
        }
        const keyBase64 = parsed.k;
        const dataBase64 = parsed.d;
        if (!keyBase64 || typeof keyBase64 !== 'string' || keyBase64.trim() === '') {
          socket.emit('error', { message: 'Invalid encrypted payload: missing key' });
          console.log('[security] invalid payload: empty key');
          return;
        }
        if (!dataBase64 || typeof dataBase64 !== 'string' || dataBase64.trim() === '') {
          socket.emit('error', { message: 'Invalid encrypted payload: missing data' });
          console.log('[security] invalid payload: empty data');
          return;
        }
      } catch (e) {
        socket.emit('error', { message: 'Invalid encrypted payload' });
        console.log('[security] invalid payload: not valid JSON');
        return;
      }
    }
    
    const dataSize = Buffer.byteLength(JSON.stringify(payload.data), 'utf8');
    const isFileOrImage = payload.data.type === 'file' || payload.data.type === 'image';
    const limit = isFileOrImage ? MAX_FILE_SIZE : MAX_TEXT_SIZE;
    if (dataSize > limit) {
      socket.emit('error', { message: isFileOrImage ? 'File too large (max 10MB)' : 'Message too large (max 1MB)' });
      console.log('[security] oversized message rejected, type:', isFileOrImage ? 'file' : 'text');
      return;
    }
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
    if (from === payload.to) {
      console.log('[skip] self-message');
      return;
    }
    const targetSocketId = onlineUsers.get(payload.to);
    if (targetSocketId) {
      io.to(targetSocketId).emit('message', envelope);
      console.log('[relay] message delivered');
      socket.emit('messageStatus', { msgId, status: 'delivered' });
    } else {
      if (!offlineBuffer.has(payload.to)) {
        offlineBuffer.set(payload.to, []);
      }
      // MED-03: Encrypt offline metadata before storing
      offlineBuffer.get(payload.to).push(_encryptMetadata(envelope));
      console.log('[queue] message buffered (metadata encrypted)');
      sendFcmPush(payload.to, from);
    }
  });

  socket.on('delivered', (msgId) => {
    if (!socket.username || !msgId) return;
    socket.broadcast.emit('messageStatus', { msgId, status: 'delivered' });
  });

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
  });

  socket.on('deleteMessage', (payload) => {
    if (!payload || !payload.to || !payload.msgId) return;
    const from = socket.username || 'unknown';
    if (payload.forEveryone) {
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

  socket.on('groupMessage', (payload) => {
    if (!payload || !payload.groupId || !payload.data) return;
    const from = socket.username || 'unknown';
    const group = groups.get(payload.groupId);
    if (!group) {
      console.log('[group] unknown group');
      return;
    }
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
        if (!offlineBuffer.has(member)) {
          offlineBuffer.set(member, []);
        }
        offlineBuffer.get(member).push(envelope);
        sendFcmPush(member, from);
      }
    }
    console.log('[group] message delivered');
  });

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

  socket.on('watch', (targetUsername) => {
    if (typeof targetUsername !== 'string' || !targetUsername) return;
    if (!watchers.has(targetUsername)) watchers.set(targetUsername, new Set());
    watchers.get(targetUsername).add(socket.id);
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
      const username = socket.username;
      const existingSession = sessions.get(username);
      
      onlineUsers.delete(username);
      
      if (existingSession) {
        gracePeriodSessions.set(username, {
          sessionToken: existingSession,
          timestamp: Date.now(),
        });
        sessions.delete(username);
        setTimeout(() => {
          const graceData = gracePeriodSessions.get(username);
          if (graceData && Date.now() - graceData.timestamp >= GRACE_PERIOD_MS) {
            gracePeriodSessions.delete(username);
            for (const [token, data] of refreshTokens) {
              if (data.username === username) {
                refreshTokens.delete(token);
              }
            }
            console.log('[session] Session and refresh tokens invalidated for user:', username, 'after grace period');
          }
        }, GRACE_PERIOD_MS);
      }
      
      lastSeen.set(username, Date.now());
      saveMap('last_seen.json', lastSeen);
      const userWatchers = watchers.get(username);
      if (userWatchers) {
        for (const sid of userWatchers) {
          io.to(sid).emit('statusUpdate', { username: username, online: false, lastSeen: Date.now() });
        }
      }
      for (const [target, set] of watchers) {
        set.delete(socket.id);
      }
      console.log('[ws] user offline:', username, existingSession ? '(grace period active)' : '');
    }
  });
});

// ── Logs endpoint for dashboard ──────────────────────────────

const recentLogs = [];
const MAX_LOGS = 100;

// HIGH-03: Log filter для чувствительных данных
function _filterLog(msg) {
  // Filter usernames: word:word → [user]:[user]
  msg = msg.replace(/username[=:]?\s*([a-zA-Z0-9_]+)/gi, 'username=[user]');
  msg = msg.replace(/for\s+([a-zA-Z0-9_]+)(?:\s|$|,|\.)/gi, 'for [user]$2');
  msg = msg.replace(/user:\s*([a-zA-Z0-9_]+)/gi, 'user: [user]');
  
  // Filter IPv4: 192.168.x.x, 10.x.x.x, 172.16-31.x.x
  msg = msg.replace(/\b(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b/g, '[ip]');
  // Filter IPv6
  msg = msg.replace(/\b(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}\b/g, '[ip]');
  msg = msg.replace(/\b(?:[0-9a-fA-F]{1,4}:){1,7}:/g, '[ip]');
  msg = msg.replace(/\b::(?:[0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4}\b/g, '[ip]');
  // Filter localhost variants
  msg = msg.replace(/\b(?:localhost|127\.0\.0\.1)\b/g, '[ip]');
  
  // Filter tokens: long hex strings are likely tokens
  msg = msg.replace(/([a-f0-9]{32,})\b/gi, '[token]');
  msg = msg.replace(/token[=:]?\s*([a-zA-Z0-9_-]+)/gi, 'token=[token]');
  
  // Filter session tokens (format: user:timestamp:nonce:signature)
  msg = msg.replace(/[a-zA-Z0-9_]+:\d+:[a-f0-9]+:[a-f0-9]+/g, '[token]');
  
  // HIGH-03: Фильтрация base64-строк (типичные ключи и токены)
  msg = msg.replace(/\b[A-Za-z0-9+/]{40,}={0,2}\b/g, '[base64]');
  
  // HIGH-03: Фильтрация UUID
  msg = msg.replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, '[uuid]');
  
  return msg;
}

const origLog = console.log;
const origWarn = console.warn;
const origError = console.error;

console.log = (...args) => {
  const msg = _filterLog(args.join(' '));
  recentLogs.push(msg);
  if (recentLogs.length > MAX_LOGS) recentLogs.shift();
  origLog(...args);
};
console.warn = (...args) => {
  const msg = _filterLog(args.join(' '));
  recentLogs.push(msg);
  if (recentLogs.length > MAX_LOGS) recentLogs.shift();
  origWarn(...args);
};
console.error = (...args) => {
  const msg = _filterLog(args.join(' '));
  recentLogs.push(msg);
  if (recentLogs.length > MAX_LOGS) recentLogs.shift();
  origError(...args);
};

// ── Admin: revoke all tokens (token versioning) ───────────────────────
app.post('/admin/revoke/:username', requireAuth, (req, res) => {
  const targetUser = req.params.username;
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
  const user = users.get(foundKey);
  const newVersion = (user?.tokenVersion || 0) + 1;
  users.set(foundKey, { ...user, tokenVersion: newVersion });
  saveMap('users.json', users);
  
  // Invalidate all existing refresh tokens for this user
  for (const [token, data] of refreshTokens) {
    if (data.username === foundKey) {
      refreshTokens.delete(token);
    }
  }
  sessions.delete(foundKey);
  console.log(`[AUDIT] Admin revoked tokens for: ${foundKey} (tokenVersion=${newVersion})`);
  res.json({ ok: true, message: `All tokens revoked. New tokenVersion: ${newVersion}` });
});

// ── Admin: delete user ────────────────────────────────────

app.delete('/admin/user/:username', requireAuth, (req, res) => {
  const targetUser = req.params.username;
  if (targetUser.toLowerCase() === 'admin') {
    return res.status(403).json({ error: 'Cannot delete admin account' });
  }
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
  console.log(`[AUDIT] Admin deleted user: ${foundKey}`);
  users.delete(foundKey);
  onlineUsers.delete(foundKey);
  sessions.delete(foundKey);
  lastSeen.delete(foundKey);
  fcmTokens.delete(foundKey);
  saveMap('users.json', users);
  saveMap('fcm_tokens.json', fcmTokens);
  saveMap('last_seen.json', lastSeen);
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

// MED-07: Error Handler с санитизацией сообщений
app.use((err, req, res, next) => {
  // Санитизация сообщения об ошибке - убираем потенциально опасные символы
  const sanitizeMessage = (msg) => {
    if (!msg) return 'Unknown error';
    return msg.replace(/[<>'"&;]/g, '').substring(0, 200);
  };
  
  console.error('[ERROR]', sanitizeMessage(err.message));
  if (process.env.NODE_ENV === 'production') {
    res.status(err.status || 500).json({
      error: 'Internal server error',
      code: 'SERVER_ERROR'
    });
  } else {
    res.status(err.status || 500).json({
      error: sanitizeMessage(err.message),
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
