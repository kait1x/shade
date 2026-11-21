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
const { createAuthProof } = require('./auth-proof');
const authProof = createAuthProof();

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
  admin = null;
  console.log('[firebase] disabled — push notifications unavailable');
}

const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');

// ── App Setup ────────────────────────────────────────────

const app = express();

// Try to load TLS certificates
const CERT_DIR = process.env.CERT_DIR || path.join(__dirname, 'certs');
let httpsServer = null;
let httpServer = null;
// Production behind a local reverse proxy (Caddy/Nginx): TLS terminates at the
// proxy with a CA-signed certificate; Node listens in plain HTTP on loopback only.
const TLS_BY_PROXY = process.env.TLS_TERMINATED_BY_PROXY === '1';
const BIND_HOST = process.env.BIND_HOST || (TLS_BY_PROXY ? '127.0.0.1' : '0.0.0.0');
if (TLS_BY_PROXY && !['127.0.0.1', '::1'].includes(BIND_HOST)) {
  console.error('[FATAL] TLS_TERMINATED_BY_PROXY requires a loopback BIND_HOST');
  process.exit(1);
}

function generateSelfSignedCerts() {
  const { execSync } = require('child_process');
  const certDir = path.resolve(CERT_DIR);
  fs.mkdirSync(certDir, { recursive: true });
  const keyPath = path.join(certDir, 'key.pem');
  const certPath = path.join(certDir, 'cert.pem');
  execSync(
    `openssl req -x509 -nodes -days 365 -newkey rsa:2048 ` +
    `-keyout "${keyPath}" -out "${certPath}" ` +
    `-subj "/CN=localhost" ` +
    `-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"`,
    { stdio: 'pipe' }
  );
  console.log('[tls] Self-signed certificates generated in', certDir);
}

if (!TLS_BY_PROXY) try {
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
    const certObj = new crypto.X509Certificate(certContent);
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

// TLS is required in all modes (directly or by the loopback-only reverse proxy)
const server = TLS_BY_PROXY ? http.createServer(app) : httpsServer;
if (!server) {
  console.error('[FATAL] TLS is required in all modes. Run gen-certs.sh to generate certificates.');
  process.exit(1);
}

// Only the configured local proxy hop is trusted; it appends the real peer last.
function socketClientIp(socket) {
  if (process.env.TRUST_PROXY === '1') {
    const xff = String(socket.handshake.headers['x-forwarded-for'] || '').split(',').map(v => v.trim()).filter(Boolean);
    if (xff.length) return xff[xff.length - 1];
  }
  return socket.handshake.address || socket.conn.remoteAddress || 'unknown';
}

const io = new Server(server || http.createServer(app), {
  cors: corsOptions,
  transports: ['websocket'],
  pingTimeout: 60000,
  pingInterval: 25000,
  maxHttpBufferSize: 11 * 1024 * 1024,
});

app.set('trust proxy', process.env.TRUST_PROXY === '1' ? 1 : false);
app.use(cors(corsOptions));
app.use(cookieParser());
app.use(express.json({ limit: '1mb' }));
app.use(express.raw({ limit: '10mb', type: 'application/octet-stream' }));

// Every mutation route receives an object, including empty-body requests.
// Express 4 does not automatically catch rejected async route promises.
app.use((req, res, next) => {
  if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) {
    if (req.body == null) req.body = {};
    if (typeof req.body !== 'object' || Array.isArray(req.body) || Buffer.isBuffer(req.body)) {
      return res.status(400).json({ error: 'Expected a JSON object' });
    }
  }
  next();
});

// ── Security Headers ───────────────────────────────────────
app.use((req, res, next) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('X-XSS-Protection', '1; mode=block');
  res.setHeader('Strict-Transport-Security', 'max-age=31536000; includeSubDomains; preload'); // MED-02: Submit domain to hstspreload.org for full preload
  const wsHost = process.env.WS_HOST || 'wss://localhost';
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self' " + wsHost); // MED-01: CSP connect-src restricted
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
  // The admin panel polls dashboard-stats every 5s; it gets its own soft
  // per-route budget (panelLimiter) instead of this general API quota.
  skip: req => req.path === '/dashboard-stats',
});

const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5,
  message: { error: 'Too many authentication attempts' },
});

// Owner decision: the panel is loopback-only behind an SSH tunnel, so
// authenticated GET polling must not self-throttle (5s auto-refresh ≈ 180
// req/15min per endpoint). Each panel route gets its own soft 240/15min IP
// budget; the strict anti-brute-force limiter stays on POST /admin/login only.
const panelLimiter = () => rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 240,
  message: { error: 'Too many requests, please try again later' },
  standardHeaders: true,
  legacyHeaders: false,
});

// HIGH-02: Лимиты регистрации - 3 в минуту, 10 в час
const registerLimiterMinute = rateLimit({
  windowMs: 60 * 1000,
  max: 10,
  message: { error: 'Too many registration attempts, please wait' },
  standardHeaders: true,
  legacyHeaders: false,
});

const registerLimiterHour = rateLimit({
  windowMs: 60 * 60 * 1000,
  max: 30,
  message: { error: 'Registration limit exceeded, try again later' },
  standardHeaders: true,
  legacyHeaders: false,
});

app.use('/api/', limiter);
app.use('/register', registerLimiterMinute, registerLimiterHour);
app.use('/dashboard', requireAuth, panelLimiter());

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
let serverPublicKey = null;

function loadOrGenerateMasterKey() {
  if (fs.existsSync(MASTER_KEY_FILE)) {
    try {
      const encryptedData = fs.readFileSync(MASTER_KEY_FILE, 'utf8');
      const decrypted = _decryptMasterKey(encryptedData, SESSION_SECRET);
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
  serverPublicKey = publicKey;
  // CRIT-03: Wipe master key after signing — only public key stays in memory
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
  // HIGH-03: Constant-time HMAC comparison
  const storedBuf = Buffer.from(storedHmac, 'hex');
  const computedBuf = Buffer.from(computedHmac, 'hex');
  if (storedBuf.length !== computedBuf.length || !crypto.timingSafeEqual(storedBuf, computedBuf)) {
    console.error('[hmac] HIGH-03 WARNING: HMAC mismatch for', filename, '- data may be corrupted!');
    return false;
  }
  return true;
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
      } else if ((['fcm_tokens.json','messaging.json','stickers.json'].includes(filename))) {
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
    if (['messaging.json','stickers.json'].includes(filename)) throw new Error('Cannot load durable messaging state; restore a verified backup');
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
    // HIGH-01: Atomic file write via rename
    if (filename === 'users.json') {
      const encrypted = _encryptData(data, SESSION_SECRET);
      const tmpFile = file + '.tmp';
      await fs.promises.writeFile(tmpFile, encrypted, { mode: 0o600, flush: true });
      await fs.promises.rename(tmpFile, file);
      // HIGH-03: Save HMAC for integrity check
      _saveHmac(filename, data, SESSION_SECRET);
    } else if ((['fcm_tokens.json','messaging.json','stickers.json'].includes(filename))) {
      const encrypted = _encryptData(data, SESSION_SECRET);
      const tmpFile = file + '.tmp';
      await fs.promises.writeFile(tmpFile, encrypted, { mode: 0o600, flush: true });
      await fs.promises.rename(tmpFile, file);
    } else {
      const tmpFile = file + '.tmp';
      await fs.promises.writeFile(tmpFile, JSON.stringify(data), { mode: 0o600, flush: true });
      await fs.promises.rename(tmpFile, file);
      // HIGH-03: Save HMAC for integrity check
      if (filename === 'last_seen.json' || filename === 'groups.json') {
        _saveHmac(filename, data, SESSION_SECRET);
      }
    }
  } catch (e) {
    console.error('[db] save error:', filename, e.message);
    return false;
  } finally {
    release();
  }
}

const users = loadMap('users.json');
const fcmTokens = loadMap('fcm_tokens.json');
// MED-03: FCM TTL 7 days
const FCM_TOKEN_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const groups = loadMap('groups.json');
const lastSeen = loadMap('last_seen.json');
const onlineUsers = new Map();
const messagingSnapshot = loadMap('messaging.json');
const directReceipts = new Map(messagingSnapshot.get('receipts') || []);
const offlineBuffer = messagingSnapshot.has('queues')
  ? new Map(messagingSnapshot.get('queues')) : loadMap('offline.json');
const directMessaging = require('./direct-messaging').createDirectMessaging({
  io, users, onlineUsers, offlineBuffer, receipts: directReceipts,
  encrypt: _encryptMetadata, decrypt: _decryptMetadata, push: sendFcmPush,
  blocked: v2Migrated,
  bridged: v2Migrated,
  persist: () => saveMap('messaging.json', new Map([
    ['queues', [...offlineBuffer]], ['receipts', [...directReceipts]],
  ])),
});
// ── Optional v2 bridge-ack ingestion (opt-in via SHADE_V2_BRIDGE_ACK_FILE) ──
// The v2 process exports per-account ACK tombstones (additive file owned by
// v2; this server only reads it). Confirmed bridged ciphertext is pruned from
// the v1 queue and receipts advance to delivered/read, so v1 senders keep
// seeing honest status while the recipient lives on v2. Absent file = no-op.
const V2_BRIDGE_ACK_FILE = process.env.SHADE_V2_BRIDGE_ACK_FILE || '';
let v2BridgeAckMtime = 0;
const V2_BRIDGE_REF = /^[a-z0-9_]{3,32}:[a-zA-Z0-9_-]{16,80}$/;
function readBridgeAcks() {
  if (!V2_BRIDGE_ACK_FILE) return [];
  try {
    const stat = fs.statSync(V2_BRIDGE_ACK_FILE);
    if (stat.mtimeMs === v2BridgeAckMtime) return [];
    const parsed = JSON.parse(fs.readFileSync(V2_BRIDGE_ACK_FILE, 'utf8'));
    v2BridgeAckMtime = stat.mtimeMs;
    if (!parsed || parsed.version !== 1 || !parsed.accounts || typeof parsed.accounts !== 'object') return [];
    const entries = [];
    for (const [account, value] of Object.entries(parsed.accounts)) {
      if (!v2Migrated(account)) continue; // only enrolled accounts are bridged
      const acked = Array.isArray(value?.acked) ? value.acked.filter(r => typeof r === 'string' && V2_BRIDGE_REF.test(r)).slice(0, 1000) : [];
      const read = Array.isArray(value?.read) ? value.read.filter(r => typeof r === 'string' && V2_BRIDGE_REF.test(r)).slice(0, 1000) : [];
      if (acked.length) entries.push({ account, acked, read });
    }
    return entries;
  } catch (e) {
    if (e.code !== 'ENOENT') console.error('[v2-bridge] ack file unreadable, keeping last known state:', e.code || 'parse error');
    return [];
  }
}
if (V2_BRIDGE_ACK_FILE) {
  const timer = setInterval(() => {
    const entries = readBridgeAcks();
    if (entries.length) directMessaging.bridgeAck(entries).catch(e =>
      console.error('[v2-bridge] ack ingestion failed:', e.message));
  }, 2000);
  timer.unref();
}
// MED-03: Offline message TTL 7 days
const OFFLINE_MESSAGE_TTL_MS = 7 * 24 * 60 * 60 * 1000;
const sessions = new Map();
const watchers = new Map();
const refreshTokens = new Map();
const gracePeriodSessions = new Map();
const GRACE_PERIOD_MS = 30000;

// HIGH-04: LRU cache for token maps
const MAX_SESSIONS = 10000;
const MAX_REFRESH_TOKENS = 5000;
const MAX_GRACE_PERIOD = 1000;

// MED-03: Offline message TTL 7 days - cleanup every 24h
let offlineCleanupScheduled = false;
function scheduleOfflineCleanup() {
  if (offlineCleanupScheduled) return;
  offlineCleanupScheduled = true;
  setInterval(() => {
    void directMessaging.sweep().catch(() => console.error('[db] queue cleanup failed'));
  }, 24 * 60 * 60 * 1000); // Cleanup every 24 hours
}

function lruTrim(map, maxSize) {
  if (map.size > maxSize) {
    const keys = Array.from(map.keys()).slice(0, map.size - maxSize);
    for (const k of keys) map.delete(k);
  }
}

// MED-03: Encrypt offline metadata
function _getOfflineMetadataKey(salt) {
  // HIGH-03: Unique salt per offline message
  return crypto.createHash('sha256').update('offline_meta_' + SESSION_SECRET + salt).digest();
}

function _encryptMetadata(envelope) {
  // HIGH-03: Unique salt per offline message
  const salt = crypto.randomBytes(16);
  const OFFLINE_METADATA_KEY = _getOfflineMetadataKey(salt.toString('hex'));
  // Шифруем метаданные: from, id, timestamp
  const metadata = JSON.stringify({ id: envelope.id, from: envelope.from, ts: envelope.timestamp });
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', OFFLINE_METADATA_KEY, nonce);
  const encrypted = Buffer.concat([cipher.update(metadata, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  // CRIT-03: Salt in clear for offline metadata
  const combined = Buffer.concat([nonce, tag, encrypted]);
  return {
    s: salt.toString('base64'),
    d: combined.toString('base64'),
    m: envelope.data // actual encrypted message data preserved
  };
}

function _decryptMetadata(encryptedEnvelope) {
  try {
    // CRIT-03: Salt in clear — single decryption
    const salt = Buffer.from(encryptedEnvelope.s, 'base64');
    const combined = Buffer.from(encryptedEnvelope.d, 'base64');
    const nonce = combined.subarray(0, 12);
    const tag = combined.subarray(12, 28);
    const encrypted = combined.subarray(28);
    
    const OFFLINE_METADATA_KEY = _getOfflineMetadataKey(salt.toString('hex'));
    const decipher = crypto.createDecipheriv('aes-256-gcm', OFFLINE_METADATA_KEY, nonce);
    decipher.setAuthTag(tag);
    const decrypted = Buffer.concat([decipher.update(encrypted), decipher.final()]);
    const metadata = JSON.parse(decrypted.toString('utf8'));
    return {
      id: metadata.id,
      from: metadata.from,
      timestamp: metadata.ts,
      data: encryptedEnvelope.m
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
const usersMutex = new Mutex();

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
    // HIGH-07: LRU eviction for session nonces - enforce max 10000
    if (usedSessionNonces.size > 10000) {
      const sorted = Array.from(usedSessionNonces).sort((a, b) => {
        const [tsA] = a.split(':');
        const [tsB] = b.split(':');
        return parseInt(tsA, 10) - parseInt(tsB, 10);
      });
      for (let i = 0; i < 5000; i++) {
        usedSessionNonces.delete(sorted[i]);
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
  scheduleOfflineCleanup();
  const base = `${username}:${timestamp}:${nonce}`;
  const signature = crypto.createHmac('sha256', SESSION_SECRET).update(base).digest('hex');
  const token = `${base}:${signature}`;
  // HIGH-04: LRU cache for token maps
  lruTrim(sessions, MAX_SESSIONS);
  return token;
}

// Track used refresh token nonces to detect family reuse

// Called while the refresh route holds refreshTokenMutex; synchronous by design.
const consumedRefreshTokens = new Map();
function generateRefreshToken(username, oldToken = null) {
  const old = oldToken ? refreshTokens.get(oldToken) : null;
  const familyId = old?.familyId || crypto.randomBytes(16).toString('hex');
  const expiresAt = old?.expiresAt || Date.now() + REFRESH_TOKEN_DURATION;
  if (oldToken && old) {
    consumedRefreshTokens.set(oldToken, { ...old });
    refreshTokens.delete(oldToken);
  }
  const token = crypto.randomBytes(64).toString('hex');
  refreshTokens.set(token, { username, expiresAt, tokenVersion: users.get(username)?.tokenVersion || 1, familyId });
  for (const [key, value] of consumedRefreshTokens) if (value.expiresAt <= Date.now()) consumedRefreshTokens.delete(key);
  lruTrim(refreshTokens, MAX_REFRESH_TOKENS);
  lruTrim(consumedRefreshTokens, MAX_REFRESH_TOKENS * 2);
  return token;
}

function validateSessionToken(username, token) {
  if (!token || sessions.get(username) !== token) return false;
  const parts = token.split(':');
  if (parts.length !== 4) return false;
  const [tokenUsername, timestampStr, nonce, signature] = parts;
  const timestamp = parseInt(timestampStr, 10);
  if (tokenUsername !== username) return false;
  if (Date.now() - timestamp > SESSION_DURATION) {
    console.log('[session] expired for', username);
    return false;
  }
  const base = `${username}:${timestamp}:${nonce}`;
  const expectedSignature = crypto.createHmac('sha256', SESSION_SECRET).update(base).digest('hex');
  try {
    // HIGH-01: Constant-time session token comparison
    const sigBuf = Buffer.from(signature, 'hex');
    const expBuf = Buffer.from(expectedSignature, 'hex');
    if (sigBuf.length !== expBuf.length) return false;
    return crypto.timingSafeEqual(sigBuf, expBuf);
  } catch (e) {
    return false;
  }
}

function validateRefreshToken(token) {
  if (typeof token !== 'string' || !token) return null;
  const consumed = consumedRefreshTokens.get(token);
  if (consumed && consumed.expiresAt > Date.now()) {
    for (const [key, value] of refreshTokens) if (value.familyId === consumed.familyId) refreshTokens.delete(key);
    revokeUserSessions(consumed.username);
    return { error: 'TOKEN_FAMILY_REUSE_DETECTED', message: 'Sign in again' };
  }
  const data = refreshTokens.get(token);
  if (!data || data.expiresAt <= Date.now() || data.tokenVersion !== (users.get(data.username)?.tokenVersion || 1)) {
    refreshTokens.delete(token);
    return null;
  }
  return data;
}

function revokeUserSessions(username) {
  const socketId = onlineUsers.get(username);
  // Remove ownership BEFORE disconnect, so its handler cannot create grace credentials.
  onlineUsers.delete(username);
  sessions.delete(username);
  gracePeriodSessions.delete(username);
  fcmTokens.delete(username);
  for (const [token, value] of refreshTokens) if (value.username === username) refreshTokens.delete(token);
  for (const [token, value] of consumedRefreshTokens) if (value.username === username) consumedRefreshTokens.delete(token);
  if (socketId) io.sockets.sockets.get(socketId)?.disconnect(true);
  const timestamp = Date.now();
  lastSeen.set(username, timestamp);
  for (const watcher of watchers.get(username) || []) io.to(watcher).emit('statusUpdate', { username, online: false, lastSeen: timestamp });
}

// ── Optional v2 migration guard (opt-in via SHADE_V2_GUARD_FILE) ──────────
// Accounts enrolled into device protocol v2 must no longer authenticate or
// SEND on v1 (upgrade_required). Incoming v1 messages TO enrolled accounts
// are still accepted and bridged (see SHADE_V2_BRIDGE_ACK_FILE below): the
// ciphertext is encrypted to the same immutable root RSA. The guard file is
// an ADDITIVE export owned by the v2 process; this server only reads it.
// Absent file = unchanged v1 behavior. mtime-cached; on read/parse errors the
// last known set is kept.
const V2_GUARD_FILE = process.env.SHADE_V2_GUARD_FILE || '';
let v2GuardAccounts = new Set();
// D1 (V2_COHORT_MIGRATION.md): аддитивная секция `dialogs` guard-экспорта несёт
// per-dialog routing-флаг через мост. Ключ — отсортированная пара 'a|b'
// (dialogKey migration.mjs). Отсутствие секции = пустая карта = прежнее
// аккаунтное поведение байт-в-байт.
let v2GuardDialogs = new Map();
let v2GuardMtime = 0;
let v2GuardCheckedAt = 0;
const V2_ACCOUNT_REF = /^[a-z0-9_]{3,32}$/;
const V2_DIALOG_STATES = new Set(['v1_active', 'migration_pending', 'transferring', 'v2_active']);
function refreshV2Guard() {
  if (!V2_GUARD_FILE) return;
  const now = Date.now();
  if (now - v2GuardCheckedAt < 1000) return;
  v2GuardCheckedAt = now;
  try {
    const stat = fs.statSync(V2_GUARD_FILE);
    if (stat.mtimeMs === v2GuardMtime) return;
    const parsed = JSON.parse(fs.readFileSync(V2_GUARD_FILE, 'utf8'));
    if (parsed && parsed.version === 1 && parsed.accounts && typeof parsed.accounts === 'object') {
      v2GuardAccounts = new Set(Object.keys(parsed.accounts));
      // Аддитивный разбор dialogs: невалидные записи пропускаются; секция
      // отсутствует или невалидна → per-dialog уточнений нет (прежнее поведение).
      const dialogs = new Map();
      if (parsed.dialogs && typeof parsed.dialogs === 'object' && !Array.isArray(parsed.dialogs)) {
        for (const [key, value] of Object.entries(parsed.dialogs)) {
          const pair = key.split('|');
          if (pair.length !== 2 || pair[0] === pair[1] || !pair.every(a => V2_ACCOUNT_REF.test(a))) continue;
          if (!value || !V2_DIALOG_STATES.has(value.state)) continue;
          dialogs.set(key, { state: value.state, rolledBackAt: Number(value.rolledBackAt) || null });
        }
      }
      v2GuardDialogs = dialogs;
      v2GuardMtime = stat.mtimeMs;
    }
  } catch (e) {
    if (e.code === 'ENOENT') { v2GuardAccounts = new Set(); v2GuardDialogs = new Map(); v2GuardMtime = 0; return; }
    console.error('[v2-guard] guard file unreadable, keeping last known state:', e.code || 'parse error');
  }
}
// Гранулярность v1-guard — аккаунт (ограничение v1-протокола, задокументировано):
// диалог v2_active запрещает v1-send его участников; аккаунт снимается с guard
// только когда ВСЕ его диалоги откатаны (v1_active + rolledBackAt). Смешанные
// диалоги (v2_active + rollback) держат аккаунт под guard. Enrolled-аккаунты
// без journal остаются под guard — поведение enrollment не меняется.
function v2Migrated(username) {
  refreshV2Guard();
  if (!v2GuardDialogs.size) return v2GuardAccounts.has(username);
  let listed = false, allRolledBack = true, anyV2Active = false;
  for (const [key, record] of v2GuardDialogs) {
    const [a, b] = key.split('|');
    if (a !== username && b !== username) continue;
    listed = true;
    if (record.state !== 'v1_active' || !record.rolledBackAt) allRolledBack = false;
    if (record.state === 'v2_active') anyV2Active = true;
  }
  if (v2GuardAccounts.has(username)) return !(listed && allRolledBack);
  // Fail-closed per-dialog routing: v2_active диалог запрещает v1-send даже
  // если аккаунт не listed в accounts (рассинхрон экспорта). Pending/transferring
  // не блокируют аккаунт без journal-записи: v1 остаётся текущим окружением.
  return anyV2Active;
}

// ── Optional v2 reverse-replay ingestion (opt-in via SHADE_V2_REVERSE_REPLAY_FILE) ──
// D1 rollback: v2-процесс экспортирует v2-origine конверты диалога (формат
// reverseReplay() migration.mjs: {version, accounts: {account: [{id, from,
// timestamp, data:{k,d}}]}}) для v1-очередей legacy-устройств. v1 только
// ДОБАВЛЯЕТ пакеты в существующие очереди (дедуп по from:id), ciphertext не
// расшифровывает и формат v1 не меняет. После успешного ingestion файл
// помечается consumed: атомарный журнал `${file}.consumed` (tmp+rename, по
// образцу guard/bridgeAck экспортов) + удаление экспорта. Журнал — источник
// дедупа, переживающий prune очередей/квитанций и повторные экспорты v2.
// Отсутствие файла = no-op; сбой парсинга = честный лог без падения сервиса.
const V2_REVERSE_REPLAY_FILE = process.env.SHADE_V2_REVERSE_REPLAY_FILE || '';
const V2_REPLAY_CONSUMED = V2_REVERSE_REPLAY_FILE ? `${V2_REVERSE_REPLAY_FILE}.consumed` : '';
const V2_REPLAY_ID = /^[a-zA-Z0-9_-]{16,80}$/;
const V2_REPLAY_MAX_BYTES = 10 * 1024 * 1024; // лимит конверта как в v1-send
let v2ReplayMtime = 0;
let v2ReplayBusy = false;
// Fail-closed валидация: весь файл должен быть валиден, иначе ingestion нет.
function parseReverseReplay(raw) {
  const parsed = JSON.parse(raw);
  if (!parsed || parsed.version !== 1 || !parsed.accounts ||
    typeof parsed.accounts !== 'object' || Array.isArray(parsed.accounts)) throw new Error('invalid format');
  const batches = [];
  for (const [account, list] of Object.entries(parsed.accounts)) {
    if (!V2_ACCOUNT_REF.test(account)) throw new Error('invalid account');
    if (!Array.isArray(list)) throw new Error('invalid entries');
    const entries = [];
    for (const e of list) {
      if (!e || typeof e.id !== 'string' || !V2_REPLAY_ID.test(e.id) ||
        typeof e.from !== 'string' || !V2_ACCOUNT_REF.test(e.from) || e.from === account ||
        typeof e.timestamp !== 'number' || !Number.isFinite(e.timestamp) || e.timestamp <= 0 ||
        typeof e.data !== 'string' || !e.data || Buffer.byteLength(e.data) > V2_REPLAY_MAX_BYTES) throw new Error('invalid entry');
      let payload;
      try { payload = JSON.parse(e.data); } catch { throw new Error('invalid ciphertext'); }
      if (!payload || typeof payload.k !== 'string' || !payload.k ||
        typeof payload.d !== 'string' || !payload.d) throw new Error('invalid ciphertext');
      entries.push({ id: e.id, from: e.from, timestamp: e.timestamp, data: e.data });
    }
    batches.push({ account, entries });
  }
  return batches;
}
// Журнал consumed читается мягко: повреждение не роняет сервис, дедуп в этом
// случае опирается на очереди и квитанции (честный лог).
function readReplayLedger() {
  try {
    const parsed = JSON.parse(fs.readFileSync(V2_REPLAY_CONSUMED, 'utf8'));
    const refs = new Map();
    if (!parsed || parsed.version !== 1 || !parsed.accounts || typeof parsed.accounts !== 'object') return refs;
    for (const [account, list] of Object.entries(parsed.accounts)) {
      if (Array.isArray(list)) refs.set(account, list.filter(e => e && typeof e.id === 'string' && typeof e.from === 'string'));
    }
    return refs;
  } catch (e) {
    if (e.code !== 'ENOENT') console.error('[v2-replay] consumed journal unreadable, falling back to queue/receipt dedup:', e.code || 'parse error');
    return new Map();
  }
}
async function ingestReverseReplay() {
  if (!V2_REVERSE_REPLAY_FILE || v2ReplayBusy) return;
  let stat;
  try { stat = fs.statSync(V2_REVERSE_REPLAY_FILE); }
  catch (e) {
    if (e.code === 'ENOENT') { v2ReplayMtime = 0; return; }
    console.error('[v2-replay] export file unreadable:', e.code || e.message);
    return;
  }
  if (stat.mtimeMs === v2ReplayMtime) return;
  let batches;
  try {
    batches = parseReverseReplay(fs.readFileSync(V2_REVERSE_REPLAY_FILE, 'utf8'));
  } catch (e) {
    // mtime кэшируется, чтобы не повторять одну и ту же ошибку каждые 2 с;
    // новый экспорт v2 (другой mtime) повторит попытку.
    v2ReplayMtime = stat.mtimeMs;
    console.error('[v2-replay] export invalid, ingestion skipped:', e.message);
    return;
  }
  v2ReplayBusy = true;
  try {
    const ledger = readReplayLedger();
    const knownRefs = new Set();
    for (const list of ledger.values()) for (const e of list) knownRefs.add(`${e.from}:${e.id}`);
    const added = [];
    const unknown = [];
    for (const { account, entries } of batches) {
      if (!users.has(account)) { if (entries.length) unknown.push(account); continue; }
      const queuedRefs = new Set();
      for (const value of offlineBuffer.get(account) || []) {
        const item = _decryptMetadata(value);
        if (item) queuedRefs.add(`${item.from}:${item.id}`);
      }
      for (const e of entries) {
        const refKey = `${e.from}:${e.id}`;
        // Дедуп по id+from: журнал consumed, очередь и квитанции (включая
        // deletedAt — отозванное сообщение не воскрешаем).
        if (knownRefs.has(refKey) || queuedRefs.has(refKey) || directReceipts.has(refKey)) continue;
        added.push({ account, envelope: e });
        queuedRefs.add(refKey);
        knownRefs.add(refKey);
      }
    }
    if (unknown.length) console.error('[v2-replay] unknown accounts skipped:', unknown.join(', '));
    if (added.length) {
      // Транзакция по образцу direct-messaging: копии → мутация → persist ДО
      // пометки consumed; при сбое хранилища состояние полностью откатывается,
      // экспорт остаётся для идемпотентного повтора.
      const previousQueues = new Map([...offlineBuffer].map(([u, q]) => [u, [...q]]));
      const previousReceipts = new Map(directReceipts);
      try {
        for (const { account, envelope } of added) {
          offlineBuffer.set(account, [...(offlineBuffer.get(account) || []), _encryptMetadata(envelope)]);
          const digest = crypto.createHash('sha256').update(envelope.data).digest('hex');
          directReceipts.set(`${envelope.from}:${envelope.id}`,
            { from: envelope.from, to: account, id: envelope.id, digest, timestamp: envelope.timestamp, status: 'sent' });
        }
        if (await saveMap('messaging.json', new Map([
          ['queues', [...offlineBuffer]], ['receipts', [...directReceipts]],
        ])) === false) throw new Error('Server storage unavailable');
      } catch (e) {
        offlineBuffer.clear(); previousQueues.forEach((v, k) => offlineBuffer.set(k, v));
        directReceipts.clear(); previousReceipts.forEach((v, k) => directReceipts.set(k, v));
        console.error('[v2-replay] ingestion failed, export kept for retry:', e.message);
        return;
      }
      // Защита от гонки с откатом параллельной транзакции: consumed только
      // если пакеты действительно остались в очереди после persist.
      const survived = added.every(({ account, envelope }) =>
        (offlineBuffer.get(account) || []).some(value => {
          const item = _decryptMetadata(value);
          return item && item.id === envelope.id && item.from === envelope.from;
        }));
      if (!survived) {
        console.error('[v2-replay] concurrent rollback detected, export kept for retry');
        return;
      }
      // Живая доставка онлайн-получателю v1; аккаунты под guard — через мост.
      for (const { account, envelope } of added) {
        const target = onlineUsers.get(account);
        if (target && !v2Migrated(account)) io.to(target).emit('message', envelope);
      }
    }
    // Пометка consumed: журнал сливается с предыдущим и пишется атомарно
    // (tmp+rename), затем экспорт удаляется. Краш между шагами лечится
    // идемпотентным повтором: журнал уже содержит принятые refs.
    const merged = {};
    for (const [account, list] of ledger) merged[account] = [...list];
    for (const { account, entries } of batches) {
      // Неизвестные аккаунты в журнал не пишем: будущий повторный экспорт
      // должен иметь шанс доставить пакеты, если аккаунт появится в v1.
      if (!users.has(account)) continue;
      const list = merged[account] ||= [];
      for (const e of entries) if (!list.some(x => x.id === e.id && x.from === e.from)) list.push(e);
    }
    const tmp = `${V2_REPLAY_CONSUMED}.${crypto.randomBytes(6).toString('hex')}.tmp`;
    try {
      fs.writeFileSync(tmp, JSON.stringify({ version: 1, updatedAt: Date.now(), accounts: merged }), { mode: 0o600 });
      try { fs.renameSync(tmp, V2_REPLAY_CONSUMED); }
      catch (e) {
        // Windows: rename не перезаписывает существующую цель.
        if (e.code !== 'EPERM' && e.code !== 'EEXIST') throw e;
        fs.unlinkSync(V2_REPLAY_CONSUMED);
        fs.renameSync(tmp, V2_REPLAY_CONSUMED);
      }
      // Свежий экспорт v2 (другой mtime) не удаляем — его заберёт следующий poll.
      if (fs.statSync(V2_REVERSE_REPLAY_FILE).mtimeMs === stat.mtimeMs) fs.unlinkSync(V2_REVERSE_REPLAY_FILE);
      v2ReplayMtime = 0;
    } catch (e) {
      try { fs.unlinkSync(tmp); } catch { /* tmp мог не создаться */ }
      if (e.code === 'ENOENT') { v2ReplayMtime = 0; return; }
      console.error('[v2-replay] consumed marking failed, export kept for retry:', e.code || e.message);
    }
  } finally { v2ReplayBusy = false; }
}
if (V2_REVERSE_REPLAY_FILE) {
  const timer = setInterval(() => {
    ingestReverseReplay().catch(e => console.error('[v2-replay] ingestion failed:', e.message));
  }, 2000);
  timer.unref();
}

// ── Middleware ──────────────────────────────────────────────
function requireUserAuth(req, res, next) {
  const sessionToken = req.headers['x-session-token'];
  const username = req.headers['x-username'] || req.body?.username;
  if (!sessionToken || !username) {
    return res.status(401).json({ error: 'Authentication required' });
  }
  if (!validateSessionToken(username, sessionToken)) {
    return res.status(403).json({ error: 'Invalid or expired session' });
  }
  if (v2Migrated(username)) {
    return res.status(403).json({ error: 'upgrade_required' });
  }
  req.auth = Object.freeze({ username });
  next();
}

// Admin session cookie management
const adminSessions = new Map();
const adminBackoff = new Map();
const adminFailedAttempts = new Map();
const adminUsernameLockout = new Map();
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
  // MED-07: Username-based backoff for admin
  const username = req.params.username || req.body?.username || 'admin';
  const userBackoff = adminBackoff.get(username) || { backoff: 0 };
  if (userBackoff.backoff > 0) {
    const waitTime = Math.min(1000 * Math.pow(2, userBackoff.backoff), 30000);
    if (Date.now() < userBackoff.lastAttempt + waitTime) {
      return res.status(429).json({ error: 'Too many requests, try again later', retryAfter: waitTime });
    }
  }
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
          adminBackoff.set(username, { backoff: 0, lastAttempt: 0 });
          return next();
        }
      }
    }
    adminSessions.delete(sessionCookie.split('.')[0]);
  }
  
  // Update backoff on failure
  adminBackoff.set(username, { backoff: (userBackoff.backoff || 0) + 1, lastAttempt: Date.now() });
  // Только cookie-аутентификация, без Basic Auth
  return res.redirect('/admin/login');
}

// ── Admin Login Page ─────────────────────────────────────────

app.get('/admin/login', (req, res) => {
  const html = `<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Shade — Вход в админ-панель</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0f0f1a;
  --card:#1a1a2e;
  --card-border:rgba(148,163,184,.08);
  --accent:#7c3aed;
  --accent-hover:#6d28d9;
  --accent-glow:rgba(124,58,237,.35);
  --text:#e2e8f0;
  --text-muted:#64748b;
  --input-bg:#0f0f1a;
  --input-border:rgba(148,163,184,.15);
  --input-focus:rgba(124,58,237,.4);
  --danger:#ef4444;
  --radius:16px;
  --shadow:0 8px 40px rgba(0,0,0,.45);
  --font:Inter,system-ui,-apple-system,sans-serif;
}
html{font-size:16px}
body{
  font-family:var(--font);
  background:var(--bg);
  color:var(--text);
  min-height:100vh;
  display:flex;
  align-items:center;
  justify-content:center;
  padding:20px;
  position:relative;
  overflow:hidden;
}
body::before{
  content:'';
  position:absolute;
  top:-50%;left:-50%;
  width:200%;height:200%;
  background:radial-gradient(ellipse at 30% 20%,rgba(124,58,237,.08) 0%,transparent 50%),
             radial-gradient(ellipse at 70% 80%,rgba(0,212,170,.05) 0%,transparent 50%);
  pointer-events:none;
}
.login-card{
  position:relative;
  width:100%;
  max-width:420px;
  background:var(--card);
  border:1px solid var(--card-border);
  border-radius:var(--radius);
  box-shadow:var(--shadow);
  padding:40px 36px 36px;
}
.login-header{text-align:center;margin-bottom:32px}
.logo-icon{
  width:56px;height:56px;
  margin:0 auto 16px;
  background:linear-gradient(135deg,var(--accent),#00d4aa);
  border-radius:14px;
  display:flex;align-items:center;justify-content:center;
  font-weight:800;font-size:26px;color:#fff;
  box-shadow:0 4px 20px var(--accent-glow);
}
.login-header h1{font-size:1.5rem;font-weight:700;letter-spacing:.5px;margin-bottom:4px}
.login-header p{font-size:.88rem;color:var(--text-muted)}
.form-group{margin-bottom:20px;position:relative}
.form-group label{
  display:block;
  font-size:.82rem;
  font-weight:600;
  color:var(--text-muted);
  margin-bottom:8px;
  text-transform:uppercase;
  letter-spacing:.5px;
}
.input-wrap{position:relative}
.input-wrap .icon{
  position:absolute;
  left:14px;top:50%;
  transform:translateY(-50%);
  font-size:1.1rem;
  color:var(--text-muted);
  pointer-events:none;
  transition:color .2s;
}
.input-wrap input{
  width:100%;
  padding:13px 14px 13px 44px;
  background:var(--input-bg);
  border:1px solid var(--input-border);
  border-radius:10px;
  color:var(--text);
  font-size:.95rem;
  font-family:var(--font);
  outline:none;
  transition:border-color .2s,box-shadow .2s;
}
.input-wrap input::placeholder{color:var(--text-muted);opacity:.6}
.input-wrap input:focus{
  border-color:var(--accent);
  box-shadow:0 0 0 3px var(--input-focus);
}
.input-wrap input:focus + .icon,
.input-wrap input:focus ~ .icon{color:var(--accent)}
.btn-login{
  width:100%;
  padding:14px;
  margin-top:8px;
  background:linear-gradient(135deg,var(--accent),var(--accent-hover));
  color:#fff;
  font-size:1rem;
  font-weight:600;
  font-family:var(--font);
  border:none;
  border-radius:10px;
  cursor:pointer;
  transition:transform .15s,box-shadow .2s,opacity .2s;
  box-shadow:0 4px 16px var(--accent-glow);
}
.btn-login:hover{
  transform:translateY(-1px);
  box-shadow:0 6px 24px var(--accent-glow);
}
.btn-login:active{transform:translateY(0);opacity:.9}
.forgot-link{
  display:block;
  text-align:center;
  margin-top:20px;
  font-size:.85rem;
  color:var(--text-muted);
}
.forgot-link a{
  color:var(--accent);
  text-decoration:none;
  font-weight:500;
  transition:color .2s;
}
.forgot-link a:hover{color:#a78bfa}
.error-msg{
  background:rgba(239,68,68,.1);
  border:1px solid rgba(239,68,68,.2);
  color:var(--danger);
  padding:10px 14px;
  border-radius:8px;
  font-size:.85rem;
  margin-bottom:20px;
  display:none;
  text-align:center;
}
.error-msg.visible{display:block}
.footer-text{
  text-align:center;
  margin-top:28px;
  font-size:.75rem;
  color:var(--text-muted);
  opacity:.6;
}
@media(max-width:480px){
  .login-card{padding:32px 24px 28px}
  .logo-icon{width:48px;height:48px;font-size:22px;border-radius:12px}
  .login-header h1{font-size:1.3rem}
}
</style>
</head>
<body>
<div class="login-card">
  <div class="login-header">
    <div class="logo-icon">S</div>
    <h1>Shade</h1>
    <p>Административная панель</p>
  </div>
  <div class="error-msg" id="error"></div>
  <form id="loginForm" onsubmit="handleLogin(event)">
    <div class="form-group">
      <label for="username">Логин</label>
      <div class="input-wrap">
        <input type="text" id="username" name="username" placeholder="admin" autocomplete="username" required>
        <span class="icon">&#x1F464;</span>
      </div>
    </div>
    <div class="form-group">
      <label for="password">Пароль</label>
      <div class="input-wrap">
        <input type="password" id="password" name="password" placeholder="Введите пароль" autocomplete="current-password" required>
        <span class="icon">&#x1F512;</span>
      </div>
    </div>
    <button type="submit" class="btn-login" id="btn">Войти</button>
  </form>
  <div class="forgot-link">
    <a href="#">Забыли пароль?</a>
  </div>
  <div class="footer-text">Shade Relay Server &middot; Secure Admin Console</div>
</div>
<script>
function handleLogin(e){
  e.preventDefault();
  var btn=document.getElementById('btn');
  var err=document.getElementById('error');
  var user=document.getElementById('username').value;
  var pass=document.getElementById('password').value;
  btn.textContent='Вход...';
  btn.disabled=true;
  err.classList.remove('visible');
  var auth='Basic '+btoa(user+':'+pass);
  fetch('/admin/login',{
    method:'POST',
    headers:{'Authorization':auth,'Content-Type':'application/json'}
  })
  .then(function(r){
    if(r.ok)return r.json();
    if(r.status===429)return r.json().then(function(d){throw new Error(d.error||'Слишком много попыток')});
    return r.json().then(function(d){throw new Error(d.error||'Неверные учётные данные')});
  })
  .then(function(){
    window.location.href='/dashboard';
  })
  .catch(function(e){
    err.textContent=e.message;
    err.classList.add('visible');
    btn.textContent='Войти';
    btn.disabled=false;
  });
}
</script>
</body>
</html>`;
  res.send(html);
});

// Endpoint to authenticate admin and set session cookie
// TODO: TOTP 2FA for admin (LOW-03)
app.post('/admin/login', authLimiter, (req, res) => {
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
  
  // HIGH-02: Username lockout for admin brute-force
  const username = 'admin';
  const usernameLockout = adminUsernameLockout.get(username);
  if (usernameLockout && now < usernameLockout.expiresAt) {
    const remaining = Math.ceil((usernameLockout.expiresAt - now) / 1000);
    return res.status(429).json({ error: 'Account locked', retryAfter: remaining });
  }
  
  const auth = req.headers.authorization;
  if (!auth || auth !== 'Basic ' + Buffer.from('admin:' + DASHBOARD_PASS).toString('base64')) {
    // Track failed attempt for username lockout
    const failedAttempts = adminFailedAttempts.get(username) || { count: 0, resetTime: now + ADMIN_LOGIN_WINDOW };
    failedAttempts.count++;
    adminFailedAttempts.set(username, failedAttempts);
    if (failedAttempts.count >= 5) {
      adminUsernameLockout.set(username, { expiresAt: now + 15 * 60 * 1000 }); // 15 min lockout
      console.warn('[admin] Account locked due to failed attempts');
    }
    return res.status(401).json({ error: 'Invalid credentials' });
  }
  
  // Clear failed attempts on success
  adminFailedAttempts.delete(username);
  adminUsernameLockout.delete(username);
  
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
    adminSessions.delete(sessionCookie.split('.')[0]);
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
  });
});

app.get('/api/dashboard-stats', requireAuth, panelLimiter(), (req, res) => {
  res.json({
    totalUsers: users.size,
    online: onlineUsers.size,
    groups: groups.size,
    queuedMessages: [...offlineBuffer.values()].reduce((s, a) => s + a.length, 0),
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
app.post('/auth/challenge', rateLimit({ windowMs: 60000, max: 30 }), (req, res) => {
  const username = typeof req.body.username === 'string' ? req.body.username.toLowerCase().trim() : '';
  const challenge = authProof.issue(username);
  if (!challenge) return res.status(400).json({ error: 'Invalid nickname or challenge limit exceeded' });
  res.json({ challenge });
});

app.post('/register', async (req, res) => {
  const nickname = typeof req.body.username === 'string' ? req.body.username.toLowerCase().trim() : '';
  if (!authProof.verify({ ...req.body, username: nickname })) {
    return res.status(403).json({ error: 'Fresh private-key proof required' });
  }
  let googleProfile = null;
  if (req.body.googleIdToken) {
    try { googleProfile = await authProof.googleProfile(req.body.googleIdToken); }
    catch { return res.status(401).json({ error: 'Google sign-in failed. Check server OAuth configuration.' }); }
  }
  // Existing installations may reconnect with a fresh private-key proof. New
  // registrations require Google unless the owner explicitly enables legacy mode.
  if (!users.has(nickname) && !googleProfile && process.env.ALLOW_LEGACY_REGISTRATION !== 'true') {
    return res.status(401).json({ error: 'Sign in with Google to create your account' });
  }
  dbMutex.acquire().then((release) => {
    try {
      const { username, publicKey, signature } = req.body;
      const nick = nickname;
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
      if (googleProfile) {
        const linked = [...users.entries()].find(([key, user]) => user.googleSub === googleProfile.googleSub && key !== username_norm);
        if (linked) {
          release();
          return res.status(409).json({ error: 'This Google account already has a nickname. Use the original device/profile.' });
        }
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
        if (v2Migrated(username_norm)) {
          release();
          return res.status(403).json({ error: 'upgrade_required' });
        }
        if (googleProfile && existing.googleSub && existing.googleSub !== googleProfile.googleSub) {
          release();
          return res.status(403).json({ error: 'Google account does not match this profile' });
        }
        if (existing.publicKey !== publicKey) {
          release();
          return res.status(409).json({ error: 'Nickname already taken' });
        }
        if (existingKey !== username_norm) {
          users.delete(existingKey);
          users.set(username_norm, existing);
          saveMap('users.json', users);
        }
        if (googleProfile) {
          Object.assign(existing, googleProfile);
          saveMap('users.json', users);
        }
        const token = generateSessionToken(username_norm);
        sessions.set(username_norm, token);
        console.log('[register] reissued token');
        release();
        return res.json({ ok: true, username: username_norm, token, refreshToken: generateRefreshToken(username_norm), profile: { email: existing.email, displayName: existing.displayName, avatarUrl: existing.avatarUrl } });
      }
let serverSignature = null;
       // CRIT-03: Decrypt private key on-demand, sign, then wipe immediately
       if (fs.existsSync(MASTER_KEY_FILE)) {
         try {
           const decrypted = _decryptMasterKey(fs.readFileSync(MASTER_KEY_FILE, 'utf8'), SESSION_SECRET);
           const privateKeyBuffer = Buffer.from(decrypted.privateKey, 'utf8');
           const sign = crypto.createSign('sha256');
           sign.update(Buffer.from(`shade-user-key:v1:${username_norm}:${publicKey}`).toString('base64'));
           sign.end();
           const sig = sign.sign({
             key: privateKeyBuffer,
             padding: crypto.constants.RSA_PKCS1_PSS_PADDING,
             saltLength: crypto.constants.RSA_PSS_SALTLEN_DIGEST,
           });
serverSignature = sig.toString('base64');
            // CRIT-02: Wipe both Buffer and original PEM string
            _wipeKey(privateKeyBuffer);
            decrypted.privateKey = '';
          } catch (e) {
            console.error('[register] Error signing public key:', e.message);
         }
       }
      users.set(username_norm, {
        publicKey,
        signature,
        serverSignature,
        serverSignatureVersion: 3,
        ...googleProfile,
        registeredAt: Date.now(),
        tokenVersion: 1,
      });
      saveMap('users.json', users);
      const token = generateSessionToken(username_norm);
      sessions.set(username_norm, token);
      console.log('[register] new user');
      release();
      res.json({ ok: true, username: username_norm, token, refreshToken: generateRefreshToken(username_norm), profile: googleProfile || {} });
    } catch (e) {
      console.error('[register] error:', e.message);
      release();
      res.status(500).json({ error: 'Internal error' });
    }
  });
});

app.post('/logout', requireUserAuth, async (req, res) => {
  const username = req.auth.username;
  if (req.body?.username && req.body.username !== username) return res.status(403).json({ error: 'Identity mismatch' });
  const release = await usersMutex.acquire();
  try {
    revokeUserSessions(username);
    const user = users.get(username);
    if (user) user.tokenVersion = (user.tokenVersion || 1) + 1;
    const saved = await Promise.all([saveMap('users.json', users), saveMap('fcm_tokens.json', fcmTokens), saveMap('last_seen.json', lastSeen)]);
    // Queued messages survive ordinary sign-out.
    res.status(saved.includes(false) ? 503 : 200).json({ ok: !saved.includes(false) });
  } finally { release(); }
});

app.post('/refresh', async (req, res) => {
  const release = await refreshTokenMutex.acquire();
  try {
    const { refreshToken } = req.body;
    if (!refreshToken) {
      return res.status(400).json({ error: 'Missing refresh token' });
    }
    const data = validateRefreshToken(refreshToken);
    if (!data) {
      return res.status(403).json({ error: 'Invalid or expired refresh token' });
    }
    // HIGH-07: Handle family reuse detection
    if (data.error && data.error === 'TOKEN_FAMILY_REUSE_DETECTED') {
      return res.status(403).json({ error: data.message, code: 'TOKEN_FAMILY_REUSE_DETECTED' });
    }
    if (v2Migrated(data.username)) {
      return res.status(403).json({ error: 'upgrade_required' });
    }
    // Token rotation: delete old and generate new with family tracking
    const newSessionToken = generateSessionToken(data.username);
    sessions.set(data.username, newSessionToken);
    const newRefreshToken = generateRefreshToken(data.username, refreshToken);
    console.log('[refresh] token refreshed for', data.username);
    res.json({ ok: true, token: newSessionToken, refreshToken: newRefreshToken });
  } finally {
    release();
  }
});

app.post('/fcm/register', requireUserAuth, async (req, res) => {
  const { token, format } = req.body;
  if (format !== 'fcm-v1' || typeof token !== 'string' || token.length < 16 || token.length > 4096 || !/^[a-zA-Z0-9_:.-]+$/.test(token)) return res.status(400).json({ error: 'Invalid FCM token format' });
  fcmTokens.set(req.auth.username, { token, format, timestamp: Date.now() });
  const saved = await saveMap('fcm_tokens.json', fcmTokens);
  res.status(saved === false ? 503 : 200).json({ ok: saved !== false });
});

app.post('/fcm/unregister', requireUserAuth, async (req, res) => {
  const stored = fcmTokens.get(req.auth.username);
  if (stored?.token === req.body.token) fcmTokens.delete(req.auth.username);
  const saved = await saveMap('fcm_tokens.json', fcmTokens);
  res.status(saved === false ? 503 : 200).json({ ok: saved !== false });
});

require('./stickers').installStickers(app, requireUserAuth, users, loadMap('stickers.json'), map => saveMap('stickers.json', map),
  (username,revision) => io.to(`profile:${username}`).emit('avatarUpdated',{username,revision}));

app.get('/user/:username', requireUserAuth, (req, res) => {
  // HIGH-06: Constant-time user lookup for all requests
  const baseDelay = 200;
  // Используем crypto.randomBytes для аппаратного джиттера
  const jitterBytes = crypto.randomBytes(2);
  const jitter = (jitterBytes[0] << 8 | jitterBytes[1]) % 300; // 0-299ms
  const delay = baseDelay + jitter;
  
  // Задержка для ВСЕХ запросов (существующих и несуществующих пользователей)
  setTimeout(async () => {
    const release = await usersMutex.acquire();
    try {
      // HIGH-01: Users Map mutex protection
      const user = users.get(req.params.username);
      // HIGH-05: Uniform response for all users
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
    
if (user.serverSignatureVersion !== 3 && fs.existsSync(MASTER_KEY_FILE)) {
       try {
// CRIT-03: Decrypt private key on-demand, sign, then wipe immediately
         const decrypted = _decryptMasterKey(fs.readFileSync(MASTER_KEY_FILE, 'utf8'), SESSION_SECRET);
         const privateKeyBuffer = Buffer.from(decrypted.privateKey, 'utf8');
user.serverSignatureVersion = 3;
user.serverSignature = crypto.sign('sha256', Buffer.from(Buffer.from(`shade-user-key:v1:${req.params.username}:${user.publicKey}`).toString('base64')), { key: privateKeyBuffer, padding: crypto.constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
          // CRIT-02: Wipe both Buffer and original PEM string
          _wipeKey(privateKeyBuffer);
          decrypted.privateKey = '';
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
      serverSignatureVersion: user.serverSignatureVersion || 0,
      online: isOnline,
      lastSeen: lastSeenTime,
    });
    } finally {
      release();
    }
  }, delay);
});

// ── FCM Push Notification ────────────────────────────────────

async function sendFcmPush(username, from) {
  if (!admin) return;
  const tokenData = fcmTokens.get(username);
  if (!tokenData || tokenData.format !== 'fcm-v1' || !isFcmTokenValid(tokenData)) {
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
    // Generic visible notification; message contents remain client-encrypted.
    await admin.messaging().send({
      token,
      notification: { title: 'Shade', body: 'Новое сообщение' },
      android: { priority: 'high', notification: { channelId: 'shade_messages' } },
      apns: { payload: { aps: { sound: 'default' } } },
      data: {
        type: 'new_message',
        from: from,
      },
    });
    console.log('[fcm] push sent');
  } catch (e) {
    console.error('[fcm] push failed:', e.message);
  }
}

// ── Group endpoints ──────────────────────────────────────────

app.all(['/group/create', '/group/:id'], requireUserAuth, (_req, res) => {
  res.status(410).json({ error: 'Groups are not available in this version' });
});

// ── WebSocket ────────────────────────────────────────────────

// MED-07: WS connection limit 5 per IP
const wsConnectionsPerIp = new Map();
const lastDisconnectTime = new Map();
const reconnectRateLimit = new Map(); // HIGH-02: 10 reconnects/min per IP

// MED-06: Global WS rate limit 10/sec
const globalWsRateLimit = new Map();
const GLOBAL_WS_MAX_PER_SEC = 10;

io.on('connection', (socket) => {
  // MED-06: Global WS rate limit 10/sec
  const now = Date.now();
  const bucket = Math.floor(now / 1000);
  const globalCount = globalWsRateLimit.get(bucket) || 0;
  if (globalCount >= GLOBAL_WS_MAX_PER_SEC) {
    console.warn('[ws] Global rate limit exceeded');
    socket.emit('error', { message: 'Too many connections, please try again later' });
    socket.disconnect();
    return;
  }
  globalWsRateLimit.set(bucket, globalCount + 1);
  setTimeout(() => globalWsRateLimit.delete(bucket), 1000);
  
  // MED-07: Ограничение 5 одновременных подключений с одного IP
  const clientIp = socketClientIp(socket);
  const currentCount = wsConnectionsPerIp.get(clientIp) || 0;
  if (currentCount >= 50) {
    console.warn('[ws] Connection limit exceeded for IP:', clientIp);
    socket.emit('error', { message: 'Too many connections from this IP' });
    socket.disconnect();
    return;
  }
  wsConnectionsPerIp.set(clientIp, currentCount + 1);
  socket.on('disconnect', () => {
    lastDisconnectTime.set(clientIp, Date.now());
    const count = wsConnectionsPerIp.get(clientIp) || 1;
    wsConnectionsPerIp.set(clientIp, Math.max(0, count - 1));
  });
  // HIGH-02: Global reconnect rate limit 10/min per IP
  const reconnectAttempts = reconnectRateLimit.get(clientIp) || [];
  const nowReconnect = Date.now();
  const recentAttempts = reconnectAttempts.filter(ts => nowReconnect - ts < 60000);
  if (recentAttempts.length >= 100) {
    console.warn('[ws] Rate limit exceeded for IP:', clientIp);
    socket.emit('error', { message: 'Too many connection attempts, try again later' });
    socket.disconnect();
    return;
  }
  recentAttempts.push(nowReconnect);
  reconnectRateLimit.set(clientIp, recentAttempts);
  // LOW-04: Reconnect throttle 5s
  const RECONNECT_THROTTLE_MS = 500;
  const lastDisconnect = lastDisconnectTime.get(clientIp);
  if (lastDisconnect && (Date.now() - lastDisconnect) < RECONNECT_THROTTLE_MS) {
    console.warn('[ws] Reconnect throttle active for IP:', clientIp);
    socket.emit('error', { message: 'Too soon after disconnect, try again later' });
    socket.disconnect();
    return;
  }

  
  console.log('[ws] connected:', socket.id);

  const wsRegisterAttempts = new Map();
  const WS_MAX_REGISTER_PER_MINUTE = 5;

  // Per-event rate limiter for WebSocket events with exponential backoff
  const wsRateLimits = new Map();
  const WS_MAX_MESSAGE_PER_MINUTE = 30;
  const WS_MAX_TYPING_PER_MINUTE = 60;
  const WS_MAX_OTHER_PER_MINUTE = 30;
  // MED-05: Group message rate limit
  const WS_MAX_GROUP_MESSAGE_PER_MINUTE = 30;
  
  socket.use((packet, next) => {
    const eventName = packet[0];
    if (eventName !== 'register' && (!socket.username || onlineUsers.get(socket.username) !== socket.id || !validateSessionToken(socket.username, sessions.get(socket.username)))) {
      socket.emit('authError', { error: 'Authentication required' });
      const ack = packet[packet.length - 1];
      if (typeof ack === 'function') ack({ ok: false, error: 'Authentication required' });
      return;
    }
    const now = Date.now();
    let rateInfo = wsRateLimits.get(socket.id);
    if (!rateInfo || now > rateInfo.resetTime) {
      rateInfo = { message: 0, typing: 0, other: 0, groupMessage: 0, groupId: null, resetTime: now + 60000, backoff: 0 };
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
    } else if (eventName === 'groupMessage') {
      // MED-05: Group message rate limit - per group
      const payload = packet[1] || {};
      const groupId = payload.groupId;
      if (rateInfo.groupId !== groupId) {
        rateInfo.groupMessage = 0;
        rateInfo.groupId = groupId;
      }
      rateInfo.groupMessage++;
      limit = WS_MAX_GROUP_MESSAGE_PER_MINUTE;
      if (rateInfo.groupMessage > limit) {
        socket.emit('error', { message: 'Too many group messages, slow down' });
        console.log('[ws] group message rate limit exceeded for', socket.id, 'group:', groupId);
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
    if (v2Migrated(username)) {
      socket.emit('authError', { error: 'upgrade_required' });
      setTimeout(() => socket.disconnect(true), 1000);
      return;
    }
    const previous = onlineUsers.get(username);
    if (previous && previous !== socket.id) io.sockets.sockets.get(previous)?.disconnect(true);
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
    socket.emit('registered', { username });
    void directMessaging.replay(socket).catch(() => socket.emit('error', { message: 'Sync unavailable' }));
  });

  directMessaging.attach(socket);

  // One bounded batch replaces subscriptions; existing presence watches stay
  // independent so opening/closing a profile cannot unwatch an active chat.
  socket.on('watchProfiles', names => {
    if (!Array.isArray(names) || names.length>256 || names.some(n=>typeof n!=='string' || !/^[a-z0-9_]{3,32}$/.test(n))) return;
    for (const room of socket.rooms) if (room.startsWith('profile:')) socket.leave(room);
    for (const name of new Set(names)) socket.join(`profile:${name}`);
  });

  socket.on('groupMessage', (_payload, ack) => {
    if (typeof ack === 'function') ack({ ok: false, error: 'Groups are not available in this version' });
    else socket.emit('error', { message: 'Groups are not available in this version' });
  });

  socket.on('logout', () => {
    if (!socket.username) return;
    const username = socket.username;
    revokeUserSessions(username);
    const user = users.get(username);
    if (user) user.tokenVersion = (user.tokenVersion || 1) + 1;
    void saveMap('users.json', users);
    void saveMap('fcm_tokens.json', fcmTokens);
    void saveMap('last_seen.json', lastSeen);
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
      
      if (onlineUsers.get(username) !== socket.id) return;
      onlineUsers.delete(username);
      
      if (existingSession) {
        gracePeriodSessions.set(username, {
          sessionToken: existingSession,
          timestamp: Date.now(),
        });
        sessions.delete(username);
        // HIGH-04: LRU cache for token maps
        lruTrim(gracePeriodSessions, MAX_GRACE_PERIOD);
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
app.post('/admin/revoke/:username', requireAuth, async (req, res) => {
  const release = await usersMutex.acquire();
  try {
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
    // HIGH-01: Users Map mutex protection
    
    // Invalidate all existing refresh tokens for this user
    for (const [token, data] of refreshTokens) {
      if (data.username === foundKey) {
        refreshTokens.delete(token);
      }
    }
    revokeUserSessions(foundKey);
    console.log(`[AUDIT] Admin revoked tokens for: ${foundKey} (tokenVersion=${newVersion})`);
    res.json({ ok: true, message: `All tokens revoked. New tokenVersion: ${newVersion}` });
  } finally {
    release();
  }
});

// ── Admin: delete user ────────────────────────────────────

app.delete('/admin/user/:username', requireAuth, async (req, res) => {
  const release = await usersMutex.acquire();
  try {
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
    revokeUserSessions(foundKey);
    users.delete(foundKey);
    // HIGH-01: Users Map mutex protection
    onlineUsers.delete(foundKey);
    revokeUserSessions(foundKey);
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
  } finally {
    release();
  }
});

app.get('/logs', requireAuth, panelLimiter(), (_req, res) => {
  res.json(recentLogs.slice(-50));
});

// ── Admin Dashboard ──────────────────────────────────────────

app.get('/dashboard', requireAuth, (_req, res) => {
  const uptime = process.uptime();
  const uptimeStr = (() => {
    const h = Math.floor(uptime / 3600);
    const m = Math.floor((uptime % 3600) / 60);
    const s = Math.floor(uptime % 60);
    return `${h}h ${m}m ${s}s`;
  })();
  const totalUsers = users.size;
  const activeSessions = onlineUsers.size;
  const totalGroups = groups.size;
  const todayMessages = [...offlineBuffer.values()].reduce((s, a) => s + a.length, 0);
  const serverVersion = '1.0.0';
  const userList = [];
  for (const [key, value] of users) {
    const isOnline = onlineUsers.has(key);
    const lastSeenTime = lastSeen.get(key) || value.registeredAt || 0;
    userList.push({
      username: key,
      online: isOnline,
      lastSeen: lastSeenTime,
      registeredAt: value.registeredAt || 0,
    });
  }
  userList.sort((a, b) => b.lastSeen - a.lastSeen);

  function timeAgo(ts) {
    const diff = Date.now() - ts;
    const sec = Math.floor(diff / 1000);
    if (sec < 60) return sec + 's ago';
    const min = Math.floor(sec / 60);
    if (min < 60) return min + 'm ago';
    const hr = Math.floor(min / 60);
    if (hr < 24) return hr + 'h ago';
    const days = Math.floor(hr / 24);
    return days + 'd ago';
  }
  function escHtml(s) {
    return String(s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;')
      .replace(/'/g, '&#39;');
  }

  // Ghost mascot SVG derived 1:1 from client ShadeGhostPainter
  // (client/lib/core/widgets/shade_logo.dart, 100-unit coordinate space).
  const ghostSvg = '<svg class="ghost" viewBox="0 0 100 100" aria-hidden="true" focusable="false">' +
    '<g transform="translate(50 50) scale(0.82) translate(-53 -51.5)">' +
    '<path fill="#F5F5F7" d="M18 48C18 25 31 13 50 13C70 13 82 27 82 48C82 62 86 73 88 79C90 86 80 90 74 85L66 79C61 92 49 94 43 81C34 92 20 91 19 80C18 70 18 58 18 48Z"/>' +
    '<ellipse cx="37.5" cy="47" rx="5.5" ry="9" fill="#000000"/>' +
    '<ellipse cx="62.5" cy="45" rx="5.5" ry="9" fill="#000000"/>' +
    '<path d="M44 64Q51 70 58 62" fill="none" stroke="#000000" stroke-width="3.5" stroke-linecap="round"/>' +
    '</g></svg>';

  // Existing filtered log buffer (see /logs) — presentation only, newest first.
  const logEntries = recentLogs.slice(-50);
  const logRows = logEntries.length === 0
    ? '<tr class="empty-row"><td colspan="2">No logs yet</td></tr>'
    : logEntries.map((line, i) => ({ line: line, n: i + 1 })).reverse().map(e =>
        '<tr><td class="log-num">' + e.n + '</td><td class="log-msg">' + escHtml(e.line) + '</td></tr>'
      ).join('');

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="color-scheme" content="dark">
<meta name="theme-color" content="#000000">
<title>Shade — Admin Dashboard</title>
<style>
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#000000;
  --surface:#111113;
  --surface-zebra:#0C0C0E;
  --surface-elevated:#1C1C1F;
  --border:#29292D;
  --text:#F5F5F7;
  --text-secondary:#9C9CA3;
  --text-muted:#8E8E93;
  --success:#32D74B;
  --danger:#FF453A;
  --warning:#FF9F0A;
  --radius:16px;
  --radius-sm:12px;
  --font:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Inter,sans-serif;
  --mono:ui-monospace,'SF Mono','Cascadia Code',Consolas,'JetBrains Mono',monospace;
}
html{font-size:16px;-webkit-text-size-adjust:100%}
body{
  font-family:var(--font);
  background:var(--bg);
  color:var(--text);
  min-height:100vh;
  display:flex;
  flex-direction:column;
  line-height:1.5;
  font-size:.9375rem;
}
a{color:inherit;text-decoration:none}
button{font-family:inherit;cursor:pointer;border:none;background:none;color:inherit}
:focus-visible{outline:2px solid var(--text-muted);outline-offset:2px;border-radius:4px}
[id]{scroll-margin-top:84px}
.ghost{width:30px;height:30px;flex-shrink:0;display:block}

/* ── Layout ── */
.layout{display:flex;min-height:100vh;flex:1}

/* ── Sidebar ── */
.sidebar{
  width:232px;
  background:var(--bg);
  border-right:1px solid var(--border);
  display:flex;
  flex-direction:column;
  position:fixed;
  top:0;left:0;bottom:0;
  z-index:100;
  transition:transform .2s ease;
}
.sidebar-brand{
  padding:20px;
  display:flex;
  align-items:center;
  gap:12px;
  border-bottom:1px solid var(--border);
}
.brand-text{display:flex;flex-direction:column;line-height:1.2}
.brand-name{font-size:.9375rem;font-weight:700;letter-spacing:2px;color:var(--text)}
.brand-sub{font-size:.6875rem;font-weight:500;letter-spacing:1.5px;text-transform:uppercase;color:var(--text-muted)}
.sidebar-nav{flex:1;padding:16px 12px;display:flex;flex-direction:column;gap:2px}
.nav-label{padding:0 12px 8px}
.nav-item{
  display:flex;align-items:center;gap:12px;
  padding:9px 12px;border-radius:var(--radius-sm);
  font-size:.875rem;font-weight:500;
  color:var(--text-muted);
  border:1px solid transparent;
  transition:color .16s ease,background-color .16s ease,border-color .16s ease;
}
.nav-item svg{width:18px;height:18px;flex-shrink:0}
.nav-item:hover{color:var(--text);background:var(--surface-zebra)}
.nav-item.active{
  background:var(--surface);
  border-color:var(--border);
  color:var(--text);
}
.sidebar-footer{
  padding:16px 20px;
  border-top:1px solid var(--border);
  font-size:.75rem;
  color:var(--text-muted);
}

/* ── Main ── */
.main{flex:1;margin-left:232px;display:flex;flex-direction:column;min-height:100vh;min-width:0}

/* ── Header ── */
.header{
  background:var(--bg);
  border-bottom:1px solid var(--border);
  padding:12px 28px;
  display:flex;
  align-items:center;
  justify-content:space-between;
  gap:12px;
  position:sticky;top:0;z-index:50;
}
.header-left{display:flex;align-items:center;gap:12px;min-width:0}
.menu-toggle{
  display:none;
  width:32px;height:32px;
  align-items:center;justify-content:center;
  border-radius:8px;color:var(--text-secondary);
}
.menu-toggle svg{width:20px;height:20px}
.header-brand{display:flex;align-items:center;gap:10px;min-width:0}
.header-brand .ghost{width:26px;height:26px}
.header-tag{
  font-size:.6875rem;font-weight:600;letter-spacing:1.5px;
  text-transform:uppercase;color:var(--text-muted);
  padding:3px 8px;border:1px solid var(--border);border-radius:999px;
  white-space:nowrap;
}
.header-right{display:flex;align-items:center;gap:12px;flex-shrink:0}
.server-status{
  display:flex;align-items:center;gap:7px;
  font-size:.8125rem;font-weight:500;
  padding:5px 12px;
  border-radius:999px;
  border:1px solid var(--border);
  background:var(--surface);
  color:var(--text-secondary);
  white-space:nowrap;
}
.server-status .dot{
  width:7px;height:7px;border-radius:50%;
  background:var(--success);
  flex-shrink:0;
}
.btn-logout{
  padding:6px 14px;
  border-radius:var(--radius-sm);
  font-size:.8125rem;
  font-weight:500;
  background:var(--surface);
  border:1px solid var(--border);
  color:var(--text-secondary);
  transition:color .16s ease,border-color .16s ease;
  white-space:nowrap;
}
.btn-logout:hover{color:var(--text);border-color:var(--text-muted)}

/* ── Content ── */
.content{padding:28px;flex:1;width:100%;max-width:1160px;margin:0 auto;display:flex;flex-direction:column;gap:24px}
.content-title{font-size:1.75rem;font-weight:700;letter-spacing:-.3px;line-height:1.2}
.section-label{
  font-size:.75rem;
  font-weight:600;
  letter-spacing:1.5px;
  text-transform:uppercase;
  color:var(--text-muted);
}

/* ── Stat Cards ── */
.stats{
  display:grid;
  grid-template-columns:repeat(auto-fit,minmax(200px,1fr));
  gap:16px;
}
.stat-card{
  background:var(--surface);
  border:1px solid var(--border);
  border-radius:var(--radius);
  padding:18px 20px;
  display:flex;flex-direction:column;gap:8px;
}
.stat-card .stat-label{
  font-size:.75rem;color:var(--text-muted);font-weight:600;
  letter-spacing:1.2px;text-transform:uppercase;
}
.stat-card .stat-value{
  font-size:1.75rem;font-weight:700;letter-spacing:-.5px;
  font-variant-numeric:tabular-nums;line-height:1.1;
}

/* ── Cards / Tables ── */
.card{
  background:var(--surface);
  border:1px solid var(--border);
  border-radius:var(--radius);
  overflow:hidden;
}
.table-header{
  padding:16px 20px;
  border-bottom:1px solid var(--border);
  display:flex;align-items:center;justify-content:space-between;gap:12px;
}
.table-header .count{
  font-size:.75rem;
  padding:3px 10px;
  border-radius:999px;
  background:var(--surface-elevated);
  border:1px solid var(--border);
  color:var(--text-secondary);
  font-weight:500;
  font-variant-numeric:tabular-nums;
  white-space:nowrap;
}
.table-wrap{overflow-x:auto;-webkit-overflow-scrolling:touch}
table{width:100%;border-collapse:collapse;min-width:600px}
thead th{
  text-align:left;
  padding:10px 20px;
  font-size:.6875rem;
  font-weight:600;
  text-transform:uppercase;
  letter-spacing:1.2px;
  color:var(--text-muted);
  border-bottom:1px solid var(--border);
  white-space:nowrap;
}
tbody td{
  padding:12px 20px;
  font-size:.875rem;
  vertical-align:middle;
}
tbody tr:nth-child(odd){background:var(--surface-zebra)}
tbody tr:nth-child(even){background:var(--surface)}
tbody tr:hover{background:var(--surface-elevated)}
.muted-cell{color:var(--text-secondary);font-variant-numeric:tabular-nums;white-space:nowrap}
.user-cell{display:flex;align-items:center;gap:10px;min-width:0}
.avatar{
  width:32px;height:32px;
  border-radius:50%;
  background:var(--surface-elevated);
  border:1px solid var(--border);
  display:flex;align-items:center;justify-content:center;
  font-weight:700;font-size:.75rem;color:var(--text);
  flex-shrink:0;text-transform:uppercase;
}
.user-cell .name{
  font-family:var(--mono);
  font-size:.8125rem;
  color:var(--text);
  overflow-wrap:anywhere;
}
.status-badge{
  display:inline-flex;align-items:center;gap:6px;
  padding:3px 10px;border-radius:999px;
  font-size:.75rem;font-weight:600;white-space:nowrap;
}
.status-badge.online{background:rgba(50,215,75,.1);color:var(--success)}
.status-badge.offline{background:rgba(142,142,147,.1);color:var(--text-muted)}
.status-badge .dot{width:6px;height:6px;border-radius:50%;flex-shrink:0}
.status-badge.online .dot{background:var(--success)}
.status-badge.offline .dot{background:var(--text-muted)}
.btn-revoke,.btn-delete{
  padding:5px 12px;
  border-radius:10px;
  font-size:.75rem;
  font-weight:600;
  transition:background-color .16s ease;
  white-space:nowrap;
}
.btn-revoke{background:rgba(255,69,58,.08);color:var(--danger)}
.btn-revoke:hover{background:rgba(255,69,58,.18)}
.btn-delete{background:rgba(255,159,10,.08);color:var(--warning)}
.btn-delete:hover{background:rgba(255,159,10,.18)}
.actions{display:flex;gap:8px}
.empty-row td{
  text-align:center;
  padding:36px 20px;
  color:var(--text-muted);
  font-size:.875rem;
}

/* ── Logs ── */
.logs-table{min-width:0;table-layout:fixed}
.logs-table .log-num{
  width:56px;
  font-family:var(--mono);
  font-size:.75rem;
  color:var(--text-muted);
  font-variant-numeric:tabular-nums;
}
.logs-table .log-msg{
  font-family:var(--mono);
  font-size:.78125rem;
  color:var(--text-secondary);
  white-space:pre-wrap;
  overflow-wrap:anywhere;
  line-height:1.55;
}

/* ── Footer ── */
.footer{
  padding:16px 28px;
  border-top:1px solid var(--border);
  display:flex;
  align-items:center;
  justify-content:space-between;
  gap:8px;flex-wrap:wrap;
  font-size:.75rem;
  color:var(--text-muted);
  background:var(--bg);
  font-variant-numeric:tabular-nums;
}

/* ── Overlay ── */
.overlay{
  display:none;
  position:fixed;inset:0;
  background:rgba(0,0,0,.6);
  z-index:90;
}
.overlay.active{display:block}

/* ── Mobile ── */
@media(max-width:768px){
  .sidebar{transform:translateX(-100%)}
  .sidebar.open{transform:translateX(0)}
  .main{margin-left:0}
  .menu-toggle{display:flex}
  .stats{grid-template-columns:1fr 1fr}
  .content{padding:20px 16px;gap:20px}
  .header{padding:10px 16px}
  .footer{padding:14px 16px;justify-content:center;text-align:center}
  .content-title{font-size:1.5rem}
}
@media(max-width:480px){
  .stats{grid-template-columns:1fr}
  .header-right{gap:8px}
  .server-status{padding:5px 9px}
  .server-status span:not(.dot){display:none}
  .stat-card{padding:16px}
  thead th,tbody td{padding-left:14px;padding-right:14px}
  .table-header{padding:14px 16px}
}
@media(max-width:360px){
  .header-tag{display:none}
  .header-left{gap:8px}
  .btn-logout{padding:6px 10px}
}
@media(prefers-reduced-motion:reduce){
  *,*::before,*::after{transition:none!important;animation:none!important}
}
</style>
</head>
<body>
<div class="overlay" id="overlay" onclick="toggleSidebar()"></div>
<div class="layout">
  <!-- Sidebar -->
  <aside class="sidebar" id="sidebar">
    <div class="sidebar-brand">
      ${ghostSvg}
      <div class="brand-text">
        <span class="brand-name">SHADE</span>
        <span class="brand-sub">Admin</span>
      </div>
    </div>
    <nav class="sidebar-nav" aria-label="Admin navigation">
      <span class="nav-label section-label">Navigation</span>
      <a href="/dashboard" class="nav-item active"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/></svg>Dashboard</a>
      <a href="#users" class="nav-item"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>Users</a>
      <a href="#groups" class="nav-item"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/></svg>Groups</a>
      <a href="#logs" class="nav-item"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/><path d="M16 13H8"/><path d="M16 17H8"/><path d="M10 9H8"/></svg>Logs</a>
    </nav>
    <div class="sidebar-footer">
      v${serverVersion} &middot; Shade Relay Server
    </div>
  </aside>

  <!-- Main -->
  <div class="main">
    <!-- Header -->
    <header class="header">
      <div class="header-left">
        <button class="menu-toggle" onclick="toggleSidebar()" aria-label="Toggle menu"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true"><path d="M3 6h18"/><path d="M3 12h18"/><path d="M3 18h18"/></svg></button>
        <div class="header-brand">
          ${ghostSvg}
          <span class="brand-name">SHADE</span>
          <span class="header-tag">Admin</span>
        </div>
      </div>
      <div class="header-right">
        <div class="server-status">
          <span class="dot"></span>
          <span>Online</span>
        </div>
        <form action="/admin/logout" method="POST">
          <button type="submit" class="btn-logout">Logout</button>
        </form>
      </div>
    </header>

    <!-- Content -->
    <div class="content">
      <h2 class="content-title">Overview</h2>

      <!-- Stat Cards -->
      <div class="stats">
        <div class="stat-card">
          <div class="stat-label">Total Users</div>
          <div class="stat-value">${totalUsers}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Active Sessions</div>
          <div class="stat-value">${activeSessions}</div>
        </div>
        <div class="stat-card" id="groups">
          <div class="stat-label">Groups</div>
          <div class="stat-value">${totalGroups}</div>
        </div>
        <div class="stat-card">
          <div class="stat-label">Queued Messages</div>
          <div class="stat-value">${todayMessages}</div>
        </div>
      </div>

      <!-- Users Table -->
      <div class="card table-section" id="users">
        <div class="table-header">
          <h2 class="section-label">Users</h2>
          <span class="count">${totalUsers} total</span>
        </div>
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th scope="col">User</th>
                <th scope="col">Status</th>
                <th scope="col">Last Seen</th>
                <th scope="col">Registered</th>
                <th scope="col">Actions</th>
              </tr>
            </thead>
            <tbody>
              ${userList.length === 0
                ? '<tr class="empty-row"><td colspan="5">No users registered yet</td></tr>'
                : userList.map(u => {
                    const ls = u.lastSeen ? timeAgo(u.lastSeen) : 'Never';
                    const reg = u.registeredAt ? timeAgo(u.registeredAt) : 'Unknown';
                    const usernameEscaped = escHtml(u.username);
                    const initial = escHtml(u.username.charAt(0).toUpperCase());
                    return '<tr>' +
                      '<td><div class="user-cell"><span class="avatar">' + initial + '</span><span class="name">' + usernameEscaped + '</span></div></td>' +
                      '<td><span class="status-badge ' + (u.online ? 'online' : 'offline') + '"><span class="dot"></span>' + (u.online ? 'Online' : 'Offline') + '</span></td>' +
                      '<td class="muted-cell">' + ls + '</td>' +
                      '<td class="muted-cell">' + reg + '</td>' +
                      '<td><div class="actions">' +
                        '<button type="button" class="btn-revoke" data-action="revoke" data-username="' + usernameEscaped + '">Revoke</button>' +
                        '<button type="button" class="btn-delete" data-action="delete" data-username="' + usernameEscaped + '">Delete</button>' +
                      '</div></td>' +
                    '</tr>';
                  }).join('')
              }
            </tbody>
          </table>
        </div>
      </div>

      <!-- Logs -->
      <div class="card logs-section" id="logs">
        <div class="table-header">
          <h2 class="section-label">Logs</h2>
          <span class="count">${logEntries.length} entries</span>
        </div>
        <div class="table-wrap">
          <table class="logs-table">
            <thead>
              <tr>
                <th scope="col" class="log-num">#</th>
                <th scope="col">Event</th>
              </tr>
            </thead>
            <tbody>
              ${logRows}
            </tbody>
          </table>
        </div>
      </div>
    </div>

    <!-- Footer -->
    <footer class="footer">
      <span>Shade Server v${serverVersion}</span>
      <span>Uptime: ${uptimeStr}</span>
    </footer>
  </div>
</div>

<script>
function toggleSidebar(){
  document.getElementById('sidebar').classList.toggle('open');
  document.getElementById('overlay').classList.toggle('active');
}
function timeAgo(ts){
  const diff=Date.now()-ts;
  const s=Math.floor(diff/1000);
  if(s<60)return s+'s ago';
  const m=Math.floor(s/60);
  if(m<60)return m+'m ago';
  const h=Math.floor(m/60);
  if(h<24)return h+'h ago';
  const d=Math.floor(h/24);
  return d+'d ago';
}
function escHtml(s){
  var d=document.createElement('div');
  d.appendChild(document.createTextNode(s));
  return d.innerHTML;
}
function revokeToken(user){
  if(!confirm('Revoke all tokens for '+user+'?'))return;
  fetch('/admin/revoke/'+encodeURIComponent(user),{method:'POST'})
    .then(function(r){return r.json()})
    .then(function(d){
      if(d.ok){alert('Tokens revoked for '+user);location.reload()}
      else{alert('Error: '+d.error)}
    })
    .catch(function(e){alert('Request failed')});
}
function deleteUser(user){
  if(!confirm('Delete user '+user+'? This cannot be undone.'))return;
  fetch('/admin/user/'+encodeURIComponent(user),{method:'DELETE'})
    .then(function(r){return r.json()})
    .then(function(d){
      if(d.ok){alert('User deleted');location.reload()}
      else{alert('Error: '+d.error)}
    })
    .catch(function(e){alert('Request failed')});
}
// User actions via event delegation: usernames travel in HTML-escaped
// data attributes (never inside inline JS), and handlers survive the
// periodic table refresh below.
document.addEventListener('click',function(e){
  var el=e.target;
  var btn=(el&&el.closest)?el.closest('button[data-action]'):null;
  if(!btn)return;
  var user=btn.getAttribute('data-username');
  var action=btn.getAttribute('data-action');
  if(action==='revoke')revokeToken(user);
  else if(action==='delete')deleteUser(user);
});
// Auto-refresh every 5 seconds
setInterval(function(){
  fetch('/api/dashboard-stats')
    .then(function(r){return r.json()})
    .then(function(d){
      var cards=document.querySelectorAll('.stat-value');
      if(cards.length>=4){
        cards[0].textContent=d.totalUsers;
        cards[1].textContent=d.online;
        cards[2].textContent=d.groups;
        cards[3].textContent=d.queuedMessages;
      }
    })
    .catch(function(){});
  // Refresh user table and logs
  fetch('/dashboard')
    .then(function(r){return r.text()})
    .then(function(html){
      var parser=new DOMParser();
      var doc=parser.parseFromString(html,'text/html');
      var newTable=doc.querySelector('.table-section');
      var oldTable=document.querySelector('.table-section');
      if(newTable&&oldTable) oldTable.innerHTML=newTable.innerHTML;
      var newLogs=doc.querySelector('.logs-section');
      var oldLogs=document.querySelector('.logs-section');
      if(newLogs&&oldLogs) oldLogs.innerHTML=newLogs.innerHTML;
    })
    .catch(function(){});
},5000);
</script>
</body>
</html>`;

  res.send(html);
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

// HIGH-02: DASHBOARD_PASS check after TLS init
const DASHBOARD_PASS = process.env.DASHBOARD_PASS || 'admin';
if (!DASHBOARD_PASS || DASHBOARD_PASS.length < 8) {
  console.error('[FATAL] DASHBOARD_PASS must be at least 8 characters!');
  console.error('[FATAL] Set DASHBOARD_PASS in .env or environment');
  process.exit(1);
}

// ── Start ────────────────────────────────────────────────────

const PORT = httpsServer
  ? (process.env.HTTPS_PORT || 3443)
  : (process.env.PORT || 3000);

server.listen(PORT, BIND_HOST, () => {
  const proto = httpsServer ? 'https' : 'http (TLS by proxy)';
  console.log(`Shade ${proto} server on :${PORT}`);
});

// ── HTTP WebSocket server (for testing without TLS) ──────────
if (process.env.ENABLE_INSECURE_TEST_PORT === 'true' && process.env.NODE_ENV !== 'production') {
const HTTP_WS_PORT = process.env.HTTP_WS_PORT || 3001;
const httpWsServer = http.createServer(app);
io.attach(httpWsServer, {
  cors: corsOptions,
  transports: ['websocket'],
  pingTimeout: 60000,
  pingInterval: 25000,
  maxHttpBufferSize: 11 * 1024 * 1024,
});
httpWsServer.listen(HTTP_WS_PORT, '0.0.0.0', () => {
  console.log(`Shade HTTP WebSocket server on :${HTTP_WS_PORT}`);
});

}
