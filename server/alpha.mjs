import express from 'express';
import cookieParser from 'cookie-parser';
import { rateLimit } from 'express-rate-limit';
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, createHash, createPublicKey } from 'node:crypto';
import { OAuth2Client } from 'google-auth-library';
import { Server } from 'socket.io';
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
const webPush = require('web-push');
import { createAuthProof } from './auth-proof.js';
import { createDeviceRegistry, operationDigest, legacyRoot } from './multidevice/registry.mjs';
import { createV2Stickers } from './multidevice/v2-stickers.mjs';
import { check, ACCOUNT, verify, requestText, hash, manifestText, genesisText, verifyRotation, publicKey } from '../client/web/protocol/device-v2.mjs';
import { alphaStore } from './multidevice/alpha-store.mjs';
import { openV1Source, validateLegacyUser } from './multidevice/v1-source.mjs';
import { createMigration } from './multidevice/migration.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const token = () => randomBytes(32).toString('hex');
const SESSION_MS = 8 * 60 * 60 * 1000;

// Injected OAuth providers are available ONLY to in-process tests. No test login
// route, environment bypass or fake identity provider is shipped to users.
export async function createAlphaServer({ dataDir, storageSecret, publicOrigin,
  clientId = '', clientSecret = '', oauthProvider, verifyGoogle, legacyUsers = new Map(), tls,
  vapidKeys = null, pushSender = null, pushAllowedHosts = null,
  legacySource = null, guardFile = null, bridgeAckFile = null, checkpointDir = null, checkpointKeep = 20,
  allowedOrigins = [] } = {}) {
  check(dataDir && publicOrigin, 'Explicit alpha dataDir and publicOrigin required');
  const origin = new URL(publicOrigin);
  check(origin.origin === publicOrigin && (origin.protocol === 'https:' ||
    (origin.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname))), 'HTTPS origin required');
  // Additional trusted first-party origins (e.g. api.<domain> alongside the
  // canonical app.<domain>). OAuth redirects and __Host- cookies stay bound to
  // the canonical publicOrigin; each origin keeps its own cookie jar.
  check(Array.isArray(allowedOrigins), 'Invalid allowedOrigins');
  for (const extra of allowedOrigins) {
    const u = new URL(extra);
    check(u.origin === extra && u.protocol === 'https:' && extra !== publicOrigin, 'Invalid extra origin');
  }
  const originAllowed = value => value === publicOrigin || allowedOrigins.includes(value);
  check(path.resolve(dataDir) !== path.join(here, 'data'), 'Production directory forbidden');
  const store = await alphaStore(dataDir, storageSecret, { checkpointDir, checkpointKeep });
  const sessions = new Map(), flows = new Map();
  const oauth = new OAuth2Client(clientId, clientSecret, `${publicOrigin}/auth/google/callback`);
  const verifier = createAuthProof({ audience: clientId, verifyGoogle });
  // Web Push (C6): wake-only notifications, no E2EE content or message refs.
  const pushEnabled = Boolean(vapidKeys?.publicKey && vapidKeys?.privateKey);
  const vapidDetails = pushEnabled ? {
    subject: vapidKeys.subject || 'mailto:alpha@shade.local',
    publicKey: vapidKeys.publicKey, privateKey: vapidKeys.privateKey } : null;
  const sendPush = pushSender || ((subscription, payload, options) =>
    webPush.sendNotification({ endpoint: subscription.endpoint, keys: subscription.keys },
      JSON.stringify(payload), { ...options, vapidDetails }));
  function checkSubscription(sub) {
    check(sub && typeof sub === 'object' && typeof sub.endpoint === 'string' &&
      sub.endpoint.length <= 2048 && sub.keys && typeof sub.keys === 'object', 'Invalid push subscription');
    let url;
    try { url = new URL(sub.endpoint); } catch { check(false, 'Invalid push endpoint'); }
    const host = url.hostname;
    // SSRF guard: public HTTPS endpoints only (no loopback/private/IP literals).
    check(url.protocol === 'https:' && !host.includes(':') &&
      !/^\d+\.\d+\.\d+\.\d+$/.test(host) &&
      !/^(localhost|.*\.local|.*\.internal)$/i.test(host) &&
      !/^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|127\.|0\.)/.test(host), 'Push endpoint rejected');
    // Optional operator allowlist of push providers (defense against
    // DNS-rebinding to arbitrary public hosts).
    if (pushAllowedHosts && pushAllowedHosts.length) {
      check(pushAllowedHosts.includes(host), 'Push endpoint host not allowed');
    }
    check(typeof sub.keys.p256dh === 'string' && typeof sub.keys.auth === 'string' &&
      sub.keys.p256dh.length <= 256 && sub.keys.auth.length <= 256 &&
      /^[A-Za-z0-9_-]+$/.test(sub.keys.p256dh) && /^[A-Za-z0-9_-]+$/.test(sub.keys.auth), 'Invalid push keys');
    return { endpoint: sub.endpoint, keys: { p256dh: sub.keys.p256dh, auth: sub.keys.auth } };
  }
  const provider = oauthProvider || {
    configured: Boolean(clientId && clientSecret),
    start({ state, nonce, codeChallenge }) {
      return oauth.generateAuthUrl({ scope: ['openid', 'email', 'profile'], response_type: 'code',
        state, nonce, code_challenge: codeChallenge, code_challenge_method: 'S256', prompt: 'select_account' });
    },
    async finish(code, flow) {
      const { tokens } = await oauth.getToken({ code, codeVerifier: flow.verifier });
      const ticket = await oauth.verifyIdToken({ idToken: tokens.id_token, audience: clientId });
      check(ticket.getPayload()?.nonce === flow.nonce, 'OAuth nonce mismatch');
      return verifier.googleProfile(tokens.id_token);
    },
  };
  // Optional READ-ONLY bridge to a v1 data directory (staging copy or, with
  // owner approval, production). The alpha store never writes into it; the
  // migration engine only adds v2 snapshot sections and drains pending queues.
  let source = null;
  try {
    if (legacySource?.dataDir) source = await openV1Source(legacySource.dataDir, { secret: legacySource.secret });
  } catch (error) { await store.close(); throw error; }
  let registry, migration = null;
  try {
    const saved = await store.load();
    let seedUsers = legacyUsers;
    if (source) {
      // Seed from the snapshot's own immutable roots (fail-closed chain checks
      // stay intact); the live source is used only by the migration engine.
      seedUsers = new Map();
      for (const [account, record] of Object.entries(saved?.accounts || {})) {
        if (!record.legacy) continue;
        const pem = createPublicKey({ key: Buffer.from(record.root, 'base64'), format: 'der', type: 'spki' })
          .export({ type: 'spki', format: 'pem' });
        seedUsers.set(account, { publicKey: pem, googleSub: record.googleSub || null });
      }
    }
    registry = await createDeviceRegistry({ users: seedUsers, snapshot: saved, persist: s => store.save(s),
      verifyGoogle: async sid => {
        const session = sessions.get(sid);
        check(session && session.expiresAt > Date.now() && session.profile, 'Google session expired');
        return session.profile;
      } });
    if (source) migration = createMigration({ registry, source });
  } catch (error) { await store.close(); throw error; }
  // Durable two-phase ACK repair: ACK tombstones live in the snapshot; a crash
  // between the ack transaction and the additive file export is healed here by
  // re-exporting from persisted state (idempotent, v1 prunes only confirmed refs).
  if (migration) {
    exportGuard().catch(e => console.error('[alpha] guard re-export failed:', e.message));
    exportBridgeAck().catch(e => console.error('[alpha] bridge-ack re-export failed:', e.message));
  }
  // Guard file consumed by the v1 server (opt-in SHADE_V2_GUARD_FILE): enrolled
  // accounts must no longer authenticate/send on v1. Atomic, additive write.
  async function exportGuard() {
    if (!guardFile || !migration) return;
    const guard = migration.guard();
    const tmp = `${guardFile}.${randomBytes(6).toString('hex')}.tmp`;
    await fs.writeFile(tmp, JSON.stringify(guard), { mode: 0o600 });
    await fs.rename(tmp, guardFile);
  }
  // Bridge-ack export: lets the v1 server prune ciphertext the v2 client has
  // confirmed, keeping the live v1→v2 bridge flowing without queue overflow.
  async function exportBridgeAck() {
    if (!bridgeAckFile || !migration) return;
    const payload = migration.bridgeAck();
    const tmp = `${bridgeAckFile}.${randomBytes(6).toString('hex')}.tmp`;
    await fs.writeFile(tmp, JSON.stringify(payload), { mode: 0o600 });
    await fs.rename(tmp, bridgeAckFile);
  }
  const app = express(), server = tls ? https.createServer(tls, app) : http.createServer(app);
  const io = new Server(server, { maxHttpBufferSize: 512 * 1024,
    allowRequest: (req, done) => done(null, !req.headers.origin || originAllowed(req.headers.origin)) });
  app.disable('x-powered-by');
  app.use((req, res, next) => {
    res.set({ 'Content-Security-Policy': "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data: blob:; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; worker-src 'self' blob:",
      'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer',
      'Permissions-Policy': 'camera=(), microphone=(), geolocation=()', 'Cache-Control': 'no-store' });
    if (origin.protocol === 'https:') res.setHeader('Strict-Transport-Security', 'max-age=31536000');
    next();
  });
  app.use(cookieParser());
  // Up to 16 per-device envelopes for a 64 KiB text in the existing protocol.
  app.use(express.json({ limit: '2mb' }));
  const cookieOptions = { httpOnly: true, secure: origin.protocol === 'https:', sameSite: 'lax', path: '/' };
  const sidName = origin.protocol === 'https:' ? '__Host-shade-alpha' : 'shade-alpha';
  const flowName = origin.protocol === 'https:' ? '__Host-shade-oauth' : 'shade-oauth';
  const wrap = fn => (req, res, next) => Promise.resolve(fn(req, res)).catch(next);
  // Sessions: Google OAuth (new accounts), legacy-key proof (v1 accounts during
  // migration) or enrolled-device proof (any platform, incl. paired web devices).
  // A session alone NEVER authorizes reading queues: every operation still
  // requires a fresh one-time device proof bound to the same account.
  const sessionAccount = session => session.profile
    ? registry.accountForGoogle(session.profile.googleSub)
    : (session.account || null);
  const requireSession = (req, res, next) => {
    const sid = req.cookies[sidName], session = sessions.get(sid);
    if (!session || session.expiresAt <= Date.now()) return res.status(401).json({ error: 'login_required' });
    req.alphaSession = session; req.alphaSid = sid; next();
  };
  // Browser mutations must be same-origin JSON. Device proofs additionally bind
  // every operation; cookies alone never authorize reading message queues.
  app.use('/api', rateLimit({ windowMs: 60000, limit: 300, standardHeaders: 'draft-8', legacyHeaders: false }), (req, res, next) => {
    if (req.headers.origin && !originAllowed(req.headers.origin)) return res.status(403).json({ error: 'origin_rejected' });
    if (req.method === 'POST' && !req.is('application/json')) return res.status(415).json({ error: 'json_required' });
    next();
  });
  app.get('/api/health', (_req, res) => res.json({ service: 'shade-web-alpha', protocol: 2, isolated: true, legacyBridge: Boolean(source) }));
  app.get('/api/session', (req, res) => {
    // The VAPID PUBLIC key is public information the PWA needs to create a
    // PushSubscription (applicationServerKey). The private key never leaves
    // the server configuration; null when push is not configured.
    const vapidPublicKey = pushEnabled ? vapidKeys.publicKey : null;
    const s = sessions.get(req.cookies[sidName]);
    if (!s || s.expiresAt <= Date.now()) return res.json({ authenticated: false, googleConfigured: provider.configured, vapidPublicKey });
    const account = sessionAccount(s);
    res.json({ authenticated: true, googleConfigured: provider.configured, account, vapidPublicKey,
      directory: account ? registry.directory(account) : null });
  });
  app.get('/auth/google', rateLimit({ windowMs: 60000, limit: 15 }), wrap(async (_req, res) => {
    check(provider.configured, 'Google OAuth is not configured');
    for (const [id, flow] of flows) if (flow.expiresAt <= Date.now()) flows.delete(id);
    check(flows.size < 1000, 'OAuth capacity reached');
    const id = token(), state = token(), nonce = token(), verifier = token();
    flows.set(id, { state, nonce, verifier, expiresAt: Date.now() + 300000 });
    res.cookie(flowName, id, { ...cookieOptions, maxAge: 300000 });
    res.redirect(provider.start({ state, nonce, codeChallenge: createHash('sha256').update(verifier).digest('base64url') }));
  }));
  app.get('/auth/google/callback', wrap(async (req, res) => {
    const id = req.cookies[flowName], flow = flows.get(id);
    flows.delete(id); res.clearCookie(flowName, cookieOptions);
    check(flow && flow.expiresAt > Date.now() && req.query.state === flow.state &&
      typeof req.query.code === 'string' && !req.query.error, 'Invalid OAuth callback');
    const profile = await provider.finish(req.query.code, flow);
    check(typeof profile?.googleSub === 'string' && profile.googleSub.length > 0, 'Verified Google identity required');
    const old = req.cookies[sidName]; if (old) sessions.delete(old);
    const sid = token(); sessions.set(sid, { profile, expiresAt: Date.now() + SESSION_MS });
    res.cookie(sidName, sid, { ...cookieOptions, maxAge: SESSION_MS });
    res.redirect('/');
  }));
  // Native (Android) Google sign-in: the google_sign_in plugin obtains an ID
  // token for the same OAuth client; verification is identical to the browser
  // code flow (audience, signature, verified email). Device proofs are still
  // required for every operation; the cookie alone never authorizes reads.
  // Single-use login nonces close ID-token replay within the token lifetime.
  const loginNonces = new Map();
  app.get('/api/v2/session/nonce', rateLimit({ windowMs: 60000, limit: 30 }), wrap(async (_req, res) => {
    const now = Date.now();
    for (const [key, value] of loginNonces) if (value.expiresAt <= now) loginNonces.delete(key);
    check(loginNonces.size < 1000, 'Login nonce capacity reached');
    const nonce = token();
    loginNonces.set(nonce, { expiresAt: now + 300000 });
    res.json({ nonce });
  }));
  app.post('/api/v2/session/google', rateLimit({ windowMs: 60000, limit: 15 }), wrap(async (req, res) => {
    // Fail-closed origin: both the PWA (same-origin POST) and the native
    // transport send Origin; a missing/mismatched Origin is rejected.
    check(originAllowed(req.headers.origin), 'Origin required');
    // Audience (the OAuth client ID) is mandatory for ID-token verification.
    check(Boolean(clientId), 'Google OAuth is not configured');
    const { idToken, nonce } = req.body || {};
    check(typeof idToken === 'string' && idToken.length > 0 && idToken.length <= 10000, 'Invalid Google ID token');
    check(typeof nonce === 'string' && nonce.length > 0 && nonce.length <= 200, 'Google login nonce required');
    const issued = loginNonces.get(nonce);
    loginNonces.delete(nonce); // Single-use: consumed even when verification fails.
    check(issued && issued.expiresAt > Date.now(), 'Google login nonce invalid or expired');
    const profile = await verifier.googleProfile(idToken, nonce);
    const old = req.cookies[sidName]; if (old) sessions.delete(old);
    const sid = token(); sessions.set(sid, { profile, expiresAt: Date.now() + SESSION_MS });
    res.cookie(sidName, sid, { ...cookieOptions, maxAge: SESSION_MS });
    const account = registry.accountForGoogle(profile.googleSub);
    res.json({ authenticated: true, account, directory: account ? registry.directory(account) : null });
  }));
  // Legacy-key session: proves possession of the ORIGINAL v1 RSA private key
  // (the same ownership proof v1 /register uses). Lets nickname-only accounts
  // migrate without forcing a Google link. The key never leaves the device.
  const legacyChallenges = new Map();
  app.post('/api/v2/session/legacy-challenge', rateLimit({ windowMs: 60000, limit: 30 }), wrap(async (req, res) => {
    const { account } = req.body || {};
    check(typeof account === 'string' && ACCOUNT.test(account), 'Invalid account');
    const dir = registry.directory(account); // Unknown account -> rejected.
    check(!dir.genesis || dir.genesis.legacy === true, 'Not a legacy account');
    const now = Date.now();
    for (const [key, value] of legacyChallenges) if (value.expiresAt <= now) legacyChallenges.delete(key);
    check(legacyChallenges.size < 1000, 'Challenge capacity reached');
    let perAccount = 0;
    for (const value of legacyChallenges.values()) if (value.account === account) perAccount++;
    check(perAccount < 100, 'Challenge quota reached');
    const nonce = token();
    legacyChallenges.set(nonce, { account, expiresAt: now + 60000 });
    res.json({ nonce });
  }));
  app.post('/api/v2/session/legacy', rateLimit({ windowMs: 60000, limit: 15 }), wrap(async (req, res) => {
    const { account, nonce, proof } = req.body || {};
    check(typeof account === 'string' && ACCOUNT.test(account), 'Invalid account');
    const challenge = legacyChallenges.get(nonce);
    legacyChallenges.delete(nonce); // Single-use, consumed even on failure.
    check(challenge && challenge.account === account && challenge.expiresAt > Date.now(), 'Invalid or replayed challenge');
    const dir = registry.directory(account);
    const operation = await operationDigest('legacy-session');
    check(typeof proof === 'string' && proof.length <= 2000 &&
      await verify(requestText(account, 'primary', nonce, operation), proof, dir.root), 'Invalid key proof');
    const old = req.cookies[sidName]; if (old) sessions.delete(old);
    const sid = token(); sessions.set(sid, { account, expiresAt: Date.now() + SESSION_MS });
    res.cookie(sidName, sid, { ...cookieOptions, maxAge: SESSION_MS });
    res.json({ authenticated: true, account, directory: dir.history.length ? dir : null });
  }));
  // Device session: any currently enrolled device can open a session for its
  // account (covers paired web devices of nickname-only accounts). Challenge
  // via /api/v2/challenge with operation = operationDigest('device-session').
  app.post('/api/v2/session/device', rateLimit({ windowMs: 60000, limit: 30 }), wrap(async (req, res) => {
    const { account, id, nonce, proof } = req.body || {};
    const operation = await operationDigest('device-session');
    await registry.authorize({ account, id, nonce, proof }, operation);
    const old = req.cookies[sidName]; if (old) sessions.delete(old);
    const sid = token(); sessions.set(sid, { account, expiresAt: Date.now() + SESSION_MS });
    res.cookie(sidName, sid, { ...cookieOptions, maxAge: SESSION_MS });
    res.json({ authenticated: true, account, directory: registry.directory(account) });
  }));
  app.post('/api/logout', requireSession, (req, res) => {
    sessions.delete(req.alphaSid); res.clearCookie(sidName, cookieOptions);
    for (const socket of io.sockets.sockets.values()) if (socket.data.sid === req.alphaSid) socket.disconnect(true);
    res.json({ ok: true });
  });
  app.post('/api/v2/register', requireSession, wrap(async (req, res) => {
    const { genesis, manifest, proofs } = req.body;
    const result = await registry.register({ genesis, manifest, proofs, googleIdToken: req.alphaSid });
    res.json(result);
  }));
  // Legacy enrollment: the account must be prepared by the operator CLI (or an
  // isolated fixture). The ORIGINAL RSA signs the migration genesis on the
  // device; the server never sees the private key. Idempotent resume: a client
  // crash after the server commit can retry with the SAME genesis and gets the
  // committed tip back instead of a conflict.
  app.post('/api/v2/legacy-enrollment', requireSession, wrap(async (req, res) => {
    const { genesis, manifest, proofs = [] } = req.body;
    const account = sessionAccount(req.alphaSession);
    check(account && account === genesis?.account && genesis.legacy === true, 'Explicit legacy enrollment required');
    const dir = registry.directory(account);
    if (dir.history.length) {
      check(dir.genesis && await hash(JSON.stringify(genesis)) === await hash(JSON.stringify(dir.genesis)), 'Genesis is immutable');
      const tip = dir.history.at(-1);
      return res.json({ revision: tip.revision, digest: await hash(manifestText(tip)), resumed: true });
    }
    check(genesis.createdAt <= Date.now() + 30000 && genesis.createdAt >= Date.now() - 300000, 'Stale enrollment');
    const result = await registry.install(manifest, proofs, genesis);
    if (migration) { await migration.finalizeEnrollment(account); await exportGuard(); }
    res.json(result);
  }));
  // ── RSA-2048 → RSA-4096 rotation enrollment ─────────────────────────────
  // v1 accepted RSA-2048; v2 anchors require RSA-4096. The owner proves
  // possession of the OLD key (attestation signed by it) and enrolls a NEW
  // RSA-4096 identity. This is an auditable identity CHANGE: the attestation
  // is stored on the account and served in the directory so contacts can
  // verify the transition; the old private key never leaves the device and
  // stays available for decrypting legacy history/bridged ciphertext.
  const rotationChallenges = new Map();
  const sha256hex = value => createHash('sha256').update(value).digest('hex');
  app.post('/api/v2/session/rotation-challenge', rateLimit({ windowMs: 60000, limit: 30 }), wrap(async (req, res) => {
    const { account } = req.body || {};
    check(typeof account === 'string' && ACCOUNT.test(account), 'Invalid account');
    check(source && migration, 'Legacy bridge not configured');
    const user = source.users.get(account);
    check(user, 'Unknown account');
    check(validateLegacyUser(account, user).rotation === true, 'Account does not require rotation');
    check(!registry.exportSnapshot().accounts[account]?.history?.length, 'Account already enrolled');
    const now = Date.now();
    for (const [key, value] of rotationChallenges) if (value.expiresAt <= now) rotationChallenges.delete(key);
    check(rotationChallenges.size < 1000, 'Challenge capacity reached');
    let perAccount = 0;
    for (const value of rotationChallenges.values()) if (value.account === account) perAccount++;
    check(perAccount < 10, 'Challenge quota reached');
    const nonce = token();
    rotationChallenges.set(nonce, { account, expiresAt: now + 60000 });
    res.json({ nonce, oldRootFingerprint: sha256hex(Buffer.from(legacyRoot(user.publicKey), 'base64')) });
  }));
  app.post('/api/v2/legacy-rotation', rateLimit({ windowMs: 60000, limit: 15 }), wrap(async (req, res) => {
    const { account, nonce, attestation, genesis, manifest, proofs = [] } = req.body || {};
    check(typeof account === 'string' && ACCOUNT.test(account), 'Invalid account');
    check(source && migration, 'Legacy bridge not configured');
    const challenge = rotationChallenges.get(nonce);
    rotationChallenges.delete(nonce); // single-use, consumed even on failure
    check(challenge && challenge.account === account && challenge.expiresAt > Date.now(), 'Invalid or replayed challenge');
    const user = source.users.get(account);
    check(user, 'Unknown account');
    check(validateLegacyUser(account, user).rotation === true, 'Account does not require rotation');
    const oldRoot = legacyRoot(user.publicKey);
    const oldFingerprint = sha256hex(Buffer.from(oldRoot, 'base64'));
    check(attestation && attestation.account === account &&
      attestation.oldRootFingerprint === oldFingerprint && attestation.nonce === nonce &&
      attestation.createdAt <= Date.now() + 30000 && attestation.createdAt >= Date.now() - 300000,
    'Invalid rotation attestation');
    check(await verifyRotation(attestation, oldRoot), 'Invalid old-key possession proof');
    check(genesis?.account === account && genesis.legacy === true, 'Explicit legacy rotation genesis required');
    check(attestation.newRoot === genesis.firstDevice?.encryptionKey &&
      attestation.newRoot === genesis.firstDevice?.signingKey, 'Rotation root mismatch');
    // The old key binds the EXACT genesis and manifest being enrolled: an
    // attestation cannot be replayed with a different device roster.
    check(attestation.genesisDigest === await hash(genesisText(genesis)) &&
      attestation.manifestDigest === await hash(manifestText(manifest)), 'Rotation digest mismatch');
    await publicKey(attestation.newRoot, 'RSA-OAEP', 'encrypt'); // enforces RSA-4096, e=65537
    const existing = registry.exportSnapshot().accounts[account];
    if (existing?.history?.length) {
      // Idempotent resume after a client crash past the server commit.
      check(existing.root === attestation.newRoot, 'Rotation root conflict');
      const dir = registry.directory(account);
      check(dir.genesis && await hash(JSON.stringify(genesis)) === await hash(JSON.stringify(dir.genesis)), 'Genesis is immutable');
      const tip = dir.history.at(-1);
      return res.json({ revision: tip.revision, digest: await hash(manifestText(tip)), resumed: true });
    }
    check(genesis.createdAt <= Date.now() + 30000 && genesis.createdAt >= Date.now() - 300000, 'Stale enrollment');
    if (!existing) {
      await registry.updateState(next => {
        check(!next.accounts[account], 'Account already exists');
        next.accounts[account] = { root: attestation.newRoot, legacy: true,
          googleSub: user.googleSub || null, genesis: null, history: [], retired: [],
          rotation: { oldRootFingerprint: oldFingerprint, attestation: structuredClone(attestation) } };
      });
    } else {
      check(existing.root === attestation.newRoot && existing.legacy === true && existing.rotation, 'Rotation state conflict');
    }
    const result = await registry.install(manifest, proofs, genesis);
    await registry.updateState(next => {
      const record = next.migration.accounts[account] ||= { attempts: 0, acked: [] };
      record.status = 'enrolled'; record.rotation = true;
      record.oldRootFingerprint = oldFingerprint;
      record.rotatedFrom = { oldRootFingerprint: oldFingerprint, newRoot: attestation.newRoot };
      record.enrolledAt ||= Date.now(); record.lastError = null;
    });
    await migration.finalizeEnrollment(account);
    await exportGuard(); await exportBridgeAck();
    res.json(result);
  }));
  function bindSession(req, auth) {
    check(auth && sessionAccount(req.alphaSession) === auth.account, 'Wrong session account');
  }
  // Challenge issuance: with a valid session the account must match (prevents
  // cross-account quota exhaustion). Sessionless issuance is allowed ONLY for
  // the device-session bootstrap operation, with a tighter per-account cap;
  // the nonce is bound to account+device+operation and consumed once, and
  // authorization happens when the device proof is verified.
  const bootstrapChallenges = new Map(); // account -> [{nonce, expiresAt}]
  app.post('/api/v2/challenge', rateLimit({ windowMs: 60000, limit: 120 }), wrap(async (req, res) => {
    const { account, id, operation } = req.body;
    const session = sessions.get(req.cookies[sidName]);
    const validSession = session && session.expiresAt > Date.now();
    if (validSession) {
      check(sessionAccount(session) === account, 'Wrong session account');
    } else {
      check(operation === await operationDigest('device-session'), 'Login required');
      const now = Date.now();
      const pending = (bootstrapChallenges.get(account) || []).filter(c => c.expiresAt > now);
      check(pending.length < 10, 'Challenge quota reached');
      const nonce = registry.challenge(account, id, operation);
      pending.push({ nonce, expiresAt: now + 60000 });
      bootstrapChallenges.set(account, pending);
      return res.json({ nonce });
    }
    res.json({ nonce: registry.challenge(account, id, operation) });
  }));
  const room = (account, id) => `${account}:${id}`;
  app.post('/api/v2/operation', requireSession, wrap(async (req, res) => {
    const { op, body = null, auth } = req.body;
    bindSession(req, auth);
    let result;
    if (op === 'send') {
      try {
        result = await registry.send(body, auth);
      } catch (e) {
        // Honest limitation, not silent isolation: the peer is still on v1.
        // The client keeps the ciphertext in its signed outbox and shows an
        // explicit notice; delivery resumes after the peer migrates.
        if (e?.message === 'Both accounts must opt into v2' &&
            !registry.exportSnapshot().accounts[body.to]?.history?.length) {
          return res.status(409).json({ error: 'peer_upgrade_required' });
        }
        throw e;
      }
      relations.add(pairKey(body.from, body.to));
      for (const e of body.envelopes) io.to(room(e.account, e.deviceId)).emit('inbox');
      if (pushEnabled) {
        for (const e of body.envelopes) {
          if (e.account === body.from) continue;
          const sub = registry.pushSubscription(e.account, e.deviceId);
          if (!sub) continue;
          try { await sendPush(sub, { type: 'wake' }, { TTL: 60 }); }
          catch (error) {
            // Gone endpoints are pruned; push never fails the E2EE send.
            if (error?.statusCode === 404 || error?.statusCode === 410) {
              await registry.dropPushSubscription(e.account, e.deviceId);
            }
          }
        }
      }
    } else if (op === 'fetch') result = await registry.fetch(auth);
    else if (op === 'ack') {
      const pending = registry.exportSnapshot().queues[room(auth.account, auth.id)] || [];
      result = await registry.acknowledge(body, auth);
      for (const m of pending) if (body.includes(`${m.from}:${m.deviceId}:${m.id}`)) {
        const dir = registry.directory(m.from).history.at(-1);
        for (const d of dir.devices) io.to(room(m.from, d.id)).emit('receipts');
      }
    } else if (op === 'status') result = await registry.status(body, auth);
    else if (op === 'read') {
      result = await registry.read(body, auth);
      const snap = registry.exportSnapshot();
      for (const ref of body) {
        const from = snap.delivery[ref]?.from;
        const dir = from ? snap.accounts[from]?.history.at(-1) : null;
        if (dir) for (const d of dir.devices) io.to(room(from, d.id)).emit('receipts');
      }
    } else if (op === 'retract') {
      result = await registry.retract(body, auth);
      const snap = registry.exportSnapshot();
      for (const ref of body) {
        const delivery = snap.delivery[ref];
        if (!delivery) continue;
        for (const d of delivery.devices) io.to(room(d.account, d.id)).emit('retracted');
        const senderDir = snap.accounts[delivery.from]?.history.at(-1);
        if (senderDir) for (const d of senderDir.devices) io.to(room(delivery.from, d.id)).emit('retracted');
      }
    } else if (op === 'retractions') result = await registry.retractions(body, auth);
    else if (op === 'legacy.inbox' || op === 'legacy.ack') {
      // One-way v1 ciphertext bridge for migrated accounts. Payloads stay E2EE
      // ({k,d} encrypted to the legacy RSA). ONLY the primary device holds the
      // legacy private key: a secondary device could drain/ACK the shared
      // account-scoped inbox without being able to decrypt, starving primary.
      check(migration, 'Legacy bridge not configured');
      check(auth.id === 'primary', 'Legacy bridge is primary-only');
      await registry.authorize(auth, await operationDigest(op, body));
      result = op === 'legacy.inbox'
        ? await migration.syncInbox(auth.account)
        : await migration.ackInbox(auth.account, body);
      if (op === 'legacy.ack') await exportBridgeAck();
    } else if (op === 'push.subscribe' || op === 'push.unsubscribe') {
      check(pushEnabled, 'Push is not configured');
      await registry.authorize(auth, await operationDigest(op, body));
      result = op === 'push.subscribe'
        ? await registry.pushSubscribe(auth, checkSubscription(body))
        : await registry.pushUnsubscribe(auth);
    } else {
      check(['users', 'directory', 'install'].includes(op), 'Unknown operation');
      await registry.authorize(auth, await operationDigest(op, body));
      if (op === 'users') result = registry.list();
      if (op === 'directory') result = registry.directory(body);
      if (op === 'install') {
        result = await registry.install(body.manifest, body.proofs || [], body.genesis || null);
        // First enrollment can also arrive through the generic install op.
        if (migration && body.genesis?.legacy === true &&
          registry.directory(auth.account).history.length === 1) {
          await migration.finalizeEnrollment(auth.account);
          await exportGuard();
        }
      }
    }
    res.json(result);
  }));
  // Verified v1 stickers/profiles business logic behind device-v2 auth only
  // (session + one-time device proof). Storage: encrypted alpha snapshot.
  app.use('/api/v2', requireSession, createV2Stickers({ registry, io, sessionAccount }));
  // Socket events are wake-up hints only. Lost hints are repaired by signed
  // fetch on reconnect/foreground and periodic polling; receipt != socket emit.
  io.use(async (socket, next) => {
    try {
      const cookies = Object.fromEntries((socket.handshake.headers.cookie || '').split(';').map(p => p.trim().split('=')));
      const sid = cookies[sidName], session = sessions.get(sid);
      check(session && session.expiresAt > Date.now(), 'Login required');
      const auth = socket.handshake.auth;
      check(sessionAccount(session) === auth.account, 'Wrong session account');
      await registry.authorize(auth, await operationDigest('socket'));
      socket.data = { sid, account: auth.account, id: auth.id, expiresAt: session.expiresAt };
      next();
    } catch { next(Error('device_auth_required')); }
  });
  // Typing/presence (contract C2): in-memory only, no message content, and
  // delivered only between accounts with an existing message relationship —
  // an authenticated stranger cannot watch or ping arbitrary accounts.
  const pairKey = (a, b) => [a, b].sort().join('|');
  const relations = new Set();
  for (const [ref, delivery] of Object.entries(registry.exportSnapshot().delivery || {})) {
    const from = ref.split(':')[0];
    for (const d of delivery.devices || []) relations.add(pairKey(from, d.account));
  }
  const watchers = new Map(); // account -> Set<socket>
  const onlineCount = new Map(); // account -> connected device sockets
  const lastTyping = new Map(); // account -> timestamp (2s throttle)
  const broadcastPresence = (account, online) => {
    for (const socket of watchers.get(account) || []) {
      if (socket.connected) socket.emit('presence', { account, online });
    }
  };
  io.on('connection', socket => {
    const account = socket.data.account;
    socket.join(room(account, socket.data.id));
    socket.emit('inbox');
    onlineCount.set(account, (onlineCount.get(account) || 0) + 1);
    broadcastPresence(account, true);
    socket.on('watch', data => {
      const peer = data?.peer;
      if (typeof peer !== 'string' || !ACCOUNT.test(peer) || peer === account ||
        !relations.has(pairKey(account, peer))) return;
      const set = watchers.get(peer) || new Set();
      if (set.size >= 100) return;
      set.add(socket); watchers.set(peer, set);
      socket.emit('presence', { account: peer, online: (onlineCount.get(peer) || 0) > 0 });
    });
    socket.on('unwatch', data => {
      const peer = data?.peer;
      if (typeof peer === 'string') watchers.get(peer)?.delete(socket);
    });
    socket.on('typing', data => {
      const peer = data?.peer;
      if (typeof peer !== 'string' || !ACCOUNT.test(peer) ||
        !relations.has(pairKey(account, peer))) return;
      const now = Date.now();
      // Per-pair throttle: typing to one peer must not mute another conversation.
      const throttleKey = `${account}|${peer}`;
      if ((lastTyping.get(throttleKey) || 0) > now - 2000) return;
      lastTyping.set(throttleKey, now);
      for (const target of io.sockets.sockets.values()) {
        if (target.data.account === peer) target.emit('typing', { account, until: now + 3000 });
      }
    });
    socket.on('disconnect', () => {
      for (const set of watchers.values()) set.delete(socket);
      const left = (onlineCount.get(account) || 1) - 1;
      if (left <= 0) { onlineCount.delete(account); broadcastPresence(account, false); }
      else onlineCount.set(account, left);
    });
  });
  const cleanup = setInterval(() => {
    for (const [sid, s] of sessions) if (s.expiresAt <= Date.now()) sessions.delete(sid);
    const typingCutoff = Date.now() - 60000;
    for (const [account, at] of lastTyping) if (at <= typingCutoff) lastTyping.delete(account);
    for (const socket of io.sockets.sockets.values()) {
      const dir = registry.directory(socket.data.account).history.at(-1);
      if (!sessions.has(socket.data.sid) || !dir.devices.some(d => d.id === socket.data.id)) socket.disconnect(true);
    }
  }, 10000);
  cleanup.unref();
  // Static presentation assets only; device-v2 routes are unchanged.
  app.use('/flutter-ui', express.static(path.resolve(here, '../client/build/web-alpha'), {
    index: false, dotfiles: 'deny', setHeaders: res => res.setHeader('Cache-Control', 'no-cache') }));
  app.use(express.static(path.resolve(here, '../client/web'), { index: 'alpha.html', dotfiles: 'deny',
    setHeaders: res => res.setHeader('Cache-Control', 'no-cache') }));
  app.use((err, _req, res, _next) => {
    const message = typeof err.message === 'string' ? err.message : '';
    const code = /already|Stale|capacity|queue full|history limit/.test(message) ? 409 : 400;
    // No tokens, public/private keys or OAuth provider diagnostics in responses/logs.
    res.status(code).json({ error: /Google OAuth is not configured/.test(message) ? 'google_not_configured' :
      /Push is not configured/.test(message) ? 'push_not_configured' :
      /already registered/.test(message) ? 'account_requires_linking' : 'operation_rejected' });
  });
  return { app, server, io, registry, migration,
    async close() { clearInterval(cleanup); await new Promise(resolve => io.close(resolve)); await store.close(); } };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  check(process.env.SHADE_ENV === 'alpha', 'Set SHADE_ENV=alpha; production startup forbidden');
  const instance = await createAlphaServer({ dataDir: process.env.ALPHA_DATA_DIR,
    storageSecret: process.env.ALPHA_STORAGE_SECRET, publicOrigin: process.env.ALPHA_PUBLIC_ORIGIN,
    clientId: process.env.ALPHA_GOOGLE_CLIENT_ID, clientSecret: process.env.ALPHA_GOOGLE_CLIENT_SECRET,
    // Optional read-only v1 bridge (staging copy; production only with owner
    // approval). ALPHA_V1_SECRET_ENV names an env var holding the v1 secret;
    // by default the source's own session_secret file is used.
    legacySource: process.env.ALPHA_V1_DATA_DIR ? { dataDir: process.env.ALPHA_V1_DATA_DIR,
      secret: process.env.ALPHA_V1_SECRET_ENV ? process.env[process.env.ALPHA_V1_SECRET_ENV] : undefined } : null,
    guardFile: process.env.ALPHA_V2_GUARD_FILE || null,
    allowedOrigins: process.env.ALPHA_ALLOWED_ORIGINS
      ? process.env.ALPHA_ALLOWED_ORIGINS.split(',').map(o => o.trim()).filter(Boolean) : [],
    bridgeAckFile: process.env.ALPHA_V2_BRIDGE_ACK_FILE || null,
    // Durable rolling checkpoints for lossless rollback (opt-in).
    checkpointDir: process.env.ALPHA_CHECKPOINT_DIR || null,
    checkpointKeep: Number(process.env.ALPHA_CHECKPOINT_KEEP || 20),
    vapidKeys: process.env.ALPHA_VAPID_PUBLIC_KEY && process.env.ALPHA_VAPID_PRIVATE_KEY ? {
      publicKey: process.env.ALPHA_VAPID_PUBLIC_KEY, privateKey: process.env.ALPHA_VAPID_PRIVATE_KEY,
      subject: process.env.ALPHA_VAPID_SUBJECT } : null,
    pushAllowedHosts: process.env.ALPHA_PUSH_ALLOWED_HOSTS
      ? process.env.ALPHA_PUSH_ALLOWED_HOSTS.split(',').map(h => h.trim()).filter(Boolean) : null });
  const port = Number(process.env.ALPHA_PORT || 3101);
  instance.server.once('error', error => {
    console.error(`Alpha listener failed: ${error.code || 'unknown'}`);
    instance.close().finally(() => process.exit(1));
  });
  instance.server.listen(port, '127.0.0.1', () => console.log(`Shade alpha listening on loopback port ${port}`));
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => instance.close().then(() => process.exit(0)));
}
