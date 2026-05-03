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
app.use('/dashboard', authLimiter);

// ── In-memory stores ─────────────────────────────────────────

const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');

// Ensure data directory exists
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
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
    console.error('[session] Error saving session secret file:', e.message);
    console.warn('[session] SESSION_SECRET will be lost on server restart!');
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
  }
}

const users = loadMap('users.json');
const fcmTokens = loadMap('fcm_tokens.json');
const groups = loadMap('groups.json');
const lastSeen = loadMap('last_seen.json'); // username → timestamp
const onlineUsers = new Map();
const offlineBuffer = new Map();
const sessions = new Map(); // username → sessionToken
const watchers = new Map(); // targetUsername → Set<socketId> (who is watching)

// SESSION_SECRET уже определён выше через loadSessionSecret()
// SESSION_DURATION уже определён выше

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
  
  try {
    return crypto.timingSafeEqual(
      Buffer.from(signature, 'hex'),
      Buffer.from(expectedSignature, 'hex')
    );
  } catch (e) {
    return false;
  }
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

// ── REST endpoints ───────────────────────────────────────────

app.get('/', (_req, res) => {
  res.json({
    name: 'Shade Relay Server',
    status: 'ok',
    users: users.size,
    online: onlineUsers.size,
  });
});

// ── Dashboard Auth ────────────────────────────────────────

const DASHBOARD_PASS = process.env.DASHBOARD_PASS;
if (!DASHBOARD_PASS) {
  console.error('[ERROR] DASHBOARD_PASS environment variable is not set!');
  console.error('Set it with: export DASHBOARD_PASS="your_secure_password" or create .env file');
  process.exit(1);
}

function requireAuth(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth || auth !== 'Basic ' + Buffer.from('admin:' + DASHBOARD_PASS).toString('base64')) {
    res.setHeader('WWW-Authenticate', 'Basic realm="Shade Dashboard"');
    return res.status(401).send('Unauthorized');
  }
  next();
}

// ── Dashboard API (JSON) ──────────────────────────────────

app.get('/api/stats', requireAuth, (_req, res) => {
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

// ── Dashboard (HTML) ──────────────────────────────────────

app.get('/dashboard', requireAuth, (_req, res) => {
  res.send(`<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Shade Dashboard</title>
<style>
  :root{--violet:#8b5cf6;--cyan:#06b6d4;--green:#34d399;--red:#ef4444;--bg:#0a0a0a;--card:#111;--border:#1e1e1e;--text:#f5f5f5;--muted:#6b7280}
  *{margin:0;padding:0;box-sizing:border-box}
  body{background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,sans-serif;padding:24px;min-height:100vh}
  .header{display:flex;align-items:center;justify-content:space-between;margin-bottom:32px}
  .header h1{font-size:32px;background:linear-gradient(135deg,var(--violet),var(--cyan));-webkit-background-clip:text;-webkit-text-fill-color:transparent;font-weight:800}
  .header .subtitle{color:var(--muted);font-size:14px;margin-top:4px}
  .live{display:flex;align-items:center;gap:8px;color:var(--green);font-size:13px}
  .live::before{content:'';width:8px;height:8px;background:var(--green);border-radius:50%;animation:pulse 2s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.3}}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:16px;margin-bottom:32px}
  .card{background:var(--card);border:1px solid var(--border);border-radius:16px;padding:20px;transition:border-color .2s}
  .card:hover{border-color:var(--violet)}
  .card h3{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:1.5px;margin-bottom:8px;display:flex;align-items:center;gap:8px}
  .card .value{font-size:36px;font-weight:700;line-height:1}
  .card .sub{color:var(--muted);font-size:12px;margin-top:4px}
  .section{margin-bottom:32px}
  .section h2{color:var(--muted);font-size:14px;text-transform:uppercase;letter-spacing:1px;margin-bottom:16px;display:flex;align-items:center;gap:8px}
  table{width:100%;border-collapse:collapse;background:var(--card);border-radius:16px;overflow:hidden;border:1px solid var(--border)}
  th,td{text-align:left;padding:14px 20px;border-bottom:1px solid var(--border)}
  th{color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:1px;background:rgba(139,92,246,.05)}
  tr:last-child td{border-bottom:none}
  tr:hover td{background:rgba(139,92,246,.03)}
  .badge{display:inline-flex;align-items:center;gap:6px;padding:4px 12px;border-radius:20px;font-size:12px;font-weight:500}
  .badge.online{background:rgba(52,211,153,.1);color:var(--green)}
  .badge.online::before{content:'';width:6px;height:6px;background:var(--green);border-radius:50%}
  .badge.offline{background:rgba(107,114,128,.1);color:var(--muted)}
  .badge.offline::before{content:'';width:6px;height:6px;background:var(--muted);border-radius:50%}
  .btn{border:none;padding:8px 16px;border-radius:8px;cursor:pointer;font-size:13px;font-weight:500;transition:all .2s}
  .btn-danger{background:rgba(239,68,68,.1);color:var(--red)}
  .btn-danger:hover{background:rgba(239,68,68,.2)}
  .btn-primary{background:var(--violet);color:#fff}
  .btn-primary:hover{background:#7c3aed}
  .logs{background:var(--bg);border:1px solid var(--border);border-radius:12px;padding:16px;font-family:'JetBrains Mono',monospace;font-size:13px;max-height:400px;overflow-y:auto}
  .logs::-webkit-scrollbar{width:6px}
  .logs::-webkit-scrollbar-track{background:transparent}
  .logs::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
  .log-line{padding:4px 8px;border-radius:4px;margin:2px 0;display:flex;gap:8px}
  .log-line:hover{background:rgba(255,255,255,.02)}
  .log-time{color:var(--muted);min-width:80px}
  .log-error{color:var(--red)}
  .log-success{color:var(--green)}
  .log-info{color:var(--cyan)}
  .log-warning{color:#f59e0b}
  .empty{text-align:center;padding:40px;color:var(--muted)}
  .footer{text-align:center;color:var(--muted);font-size:12px;margin-top:48px;padding-top:24px;border-top:1px solid var(--border)}
  @media(max-width:768px){.grid{grid-template-columns:repeat(2,1fr)}.header h1{font-size:24px}th,td{padding:10px 12px}}
</style>
</head>
<body>
  <div class="header">
    <div>
      <h1>Shade</h1>
      <div class="subtitle">Relay Server Dashboard</div>
    </div>
    <div class="live">Онлайн</div>
  </div>

  <div class="grid" id="stats"></div>

  <div class="section">
    <h2>Пользователи</h2>
    <div id="users"><div class="empty">Загрузка...</div></div>
  </div>

  <div class="section">
    <h2>Логи сервера</h2>
    <div class="logs" id="logs"><div class="log-line"><span class="log-time">--:--:--</span><span class="log-info">Загрузка...</span></div></div>
  </div>

  <div class="footer">Shade Relay Server • E2EE • RSA-4096 + AES-256-GCM</div>

  <script>
    function formatTime(s) {
      const h = Math.floor(s/3600);
      const m = Math.floor((s%3600)/60);
      return h > 0 ? h+'ч '+m+'м' : m+'м';
    }
    function formatDate(ts) {
      return new Date(ts).toLocaleString('ru-RU',{day:'numeric',month:'short',hour:'2-digit',minute:'2-digit'});
    }
    function lastSeenText(ts) {
      if(!ts) return 'н/д';
      const d = Date.now()-ts;
      const min = Math.floor(d/60000);
      const hrs = Math.floor(d/3600000);
      const days = Math.floor(d/86400000);
      if(min<1) return 'только что';
      if(min<5) return min+'мин';
      if(hrs<24) return 'сегодня';
      if(hrs<48) return 'вчера';
      if(days<7) return days+'дн';
      if(days<30) return 'месяц';
      return 'давно';
    }
    function logClass(msg) {
      if(msg.includes('error')||msg.includes('failed')||msg.includes('auth failed')) return 'log-error';
      if(msg.includes('initialized')||msg.includes('ok')||msg.includes('online')||msg.includes('registered')||msg.includes('Shade')) return 'log-success';
      if(msg.includes('warn')) return 'log-warning';
      return 'log-info';
    }

    async function loadStats() {
      try {
        const r = await fetch('/api/stats');
        const d = await r.json();
        document.getElementById('stats').innerHTML = [
          {icon:'👥',label:'Пользователей',value:d.totalUsers,color:'violet'},
          {icon:'🟢',label:'Онлайн',value:d.online,color:'green'},
          {icon:'⏱',label:'Аптайм',value:formatTime(d.uptime),color:'cyan'},
          {icon:'💾',label:'Память',value:d.memory.used+'MB / '+d.memory.total+'MB',color:'cyan'},
          {icon:'💬',label:'Очередь',value:d.queuedMessages,color:'muted'},
          {icon:'👥',label:'Групп',value:d.groups,color:'muted'},
        ].map(c => '<div class="card"><h3>'+c.icon+' '+c.label+'</h3><div class="value" style="color:var(--'+c.color+')">'+c.value+'</div></div>').join('');

        const users = d.users;
        if(!users.length) {
          document.getElementById('users').innerHTML = '<div class="empty">Нет пользователей</div>';
          return;
        }
        document.getElementById('users').innerHTML = '<table><thead><tr><th>Ник</th><th>Статус</th><th>Активность</th><th>Регистрация</th><th></th></tr></thead><tbody>'+users.map(u => {
          const status = u.online ? '<span class="badge online">онлайн</span>' : '<span class="badge offline">'+lastSeenText(u.lastSeen)+'</span>';
          return '<tr><td><strong>'+u.name+'</strong></td><td>'+status+'</td><td>'+lastSeenText(u.lastSeen)+'</td><td>'+formatDate(u.registeredAt)+'</td><td><button class="btn btn-danger" onclick="deleteUser(\\''+u.name+'\\')">✕</button></td></tr>';
        }).join('')+'</tbody></table>';
      } catch(e) {
        document.getElementById('stats').innerHTML = '<div class="empty">Ошибка загрузки</div>';
      }
    }

    async function loadLogs() {
      try {
        const r = await fetch('/logs');
        const logs = await r.json();
        const el = document.getElementById('logs');
        el.innerHTML = logs.map(l => {
          const time = new Date().toLocaleTimeString('ru-RU',{hour:'2-digit',minute:'2-digit',second:'2-digit'});
          return '<div class="log-line"><span class="log-time">'+time+'</span><span class="'+logClass(l)+'">'+l+'</span></div>';
        }).join('');
        el.scrollTop = el.scrollHeight;
      } catch(e) {}
    }

    function deleteUser(name) {
      if(!confirm('Удалить '+name+'?')) return;
      fetch('/admin/user/'+encodeURIComponent(name),{method:'DELETE'})
        .then(r=>r.json())
        .then(d=>{if(d.ok){loadStats()}else{alert('Ошибка')}});
    }

    loadStats();
    loadLogs();
    setInterval(loadStats, 5000);
    setInterval(loadLogs, 3000);
  </script>
</body>
</html>`);
});

// Register user (or reissue token for existing user with valid signature)
app.post('/register', (req, res) => {
  const { username, publicKey, signature } = req.body;

  // Validate nickname: 3-32 chars, a-z 0-9 _, case-insensitive
  const nick = (username || '').toLowerCase().trim();
  if (!/^[a-z0-9_]{3,32}$/.test(nick)) {
    return res.status(400).json({
      error: 'Никнейм: 3-32 символа, только a-z, 0-9, _',
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

  users.set(username_norm, {
    publicKey,
    signature,
    registeredAt: Date.now(),
  });
  saveMap('users.json', users);

  // Generate session token for WebSocket authentication
  const token = generateSessionToken(username_norm);
  sessions.set(username_norm, token);

  console.log('[register] new user');
  res.json({ ok: true, username: username_norm, token });
});

// Register FCM token
app.post('/fcm/register', (req, res) => {
  const { username, token } = req.body;

  if (!username || !token) {
    return res.status(400).json({ error: 'Missing data' });
  }

  fcmTokens.set(username, token);
  saveMap('fcm_tokens.json', fcmTokens);
  console.log('[fcm] token registered');
  res.json({ ok: true });
});

// Unregister FCM token (logout)
app.post('/fcm/unregister', (req, res) => {
  const { username, token } = req.body;

  if (!username || !token) {
    return res.status(400).json({ error: 'Missing data' });
  }

  const storedToken = fcmTokens.get(username);
  if (storedToken === token) {
    fcmTokens.delete(username);
    saveMap('fcm_tokens.json', fcmTokens);
    console.log('[fcm] token unregistered');
  }
  res.json({ ok: true });
});

// Get user public key (requires authentication)
app.get('/user/:username', requireUserAuth, (req, res) => {
  const user = users.get(req.params.username);

  if (!user) {
    return res.status(404).json({ error: 'Not found' });
  }

  const isOnline = onlineUsers.has(req.params.username);
  const lastSeenTime = lastSeen.get(req.params.username) || 0;

  res.json({
    username: req.params.username,
    publicKey: user.publicKey,
    signature: user.signature,
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

  socket.on('register', (payload) => {
    if (!payload || typeof payload.username !== 'string' || !payload.username) return;

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
  });

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
