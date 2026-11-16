import express from 'express';
import cookieParser from 'cookie-parser';
import { rateLimit } from 'express-rate-limit';
import http from 'node:http';
import https from 'node:https';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, createHash } from 'node:crypto';
import { OAuth2Client } from 'google-auth-library';
import { Server } from 'socket.io';
import { createAuthProof } from './auth-proof.js';
import { createDeviceRegistry, operationDigest } from './multidevice/registry.mjs';
import { check } from '../client/web/protocol/device-v2.mjs';
import { alphaStore } from './multidevice/alpha-store.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const token = () => randomBytes(32).toString('hex');
const SESSION_MS = 8 * 60 * 60 * 1000;

// Injected OAuth providers are available ONLY to in-process tests. No test login
// route, environment bypass or fake identity provider is shipped to users.
export async function createAlphaServer({ dataDir, storageSecret, publicOrigin,
  clientId = '', clientSecret = '', oauthProvider, verifyGoogle, legacyUsers = new Map(), tls } = {}) {
  check(dataDir && publicOrigin, 'Explicit alpha dataDir and publicOrigin required');
  const origin = new URL(publicOrigin);
  check(origin.origin === publicOrigin && (origin.protocol === 'https:' ||
    (origin.protocol === 'http:' && ['localhost', '127.0.0.1', '[::1]'].includes(origin.hostname))), 'HTTPS origin required');
  check(path.resolve(dataDir) !== path.join(here, 'data'), 'Production directory forbidden');
  const store = await alphaStore(dataDir, storageSecret);
  const sessions = new Map(), flows = new Map();
  const oauth = new OAuth2Client(clientId, clientSecret, `${publicOrigin}/auth/google/callback`);
  const verifier = createAuthProof({ audience: clientId, verifyGoogle });
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
  let registry;
  try {
    registry = await createDeviceRegistry({ users: legacyUsers, snapshot: await store.load(), persist: s => store.save(s),
      verifyGoogle: async sid => {
        const session = sessions.get(sid);
        check(session && session.expiresAt > Date.now(), 'Google session expired');
        return session.profile;
      } });
  } catch (error) { await store.close(); throw error; }
  const app = express(), server = tls ? https.createServer(tls, app) : http.createServer(app);
  const io = new Server(server, { maxHttpBufferSize: 512 * 1024,
    allowRequest: (req, done) => done(null, !req.headers.origin || req.headers.origin === publicOrigin) });
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
  const requireGoogle = (req, res, next) => {
    const sid = req.cookies[sidName], session = sessions.get(sid);
    if (!session || session.expiresAt <= Date.now()) return res.status(401).json({ error: 'google_login_required' });
    req.alphaSession = session; req.alphaSid = sid; next();
  };
  // Browser mutations must be same-origin JSON. Device proofs additionally bind
  // every operation; cookies alone never authorize reading message queues.
  app.use('/api', rateLimit({ windowMs: 60000, limit: 300, standardHeaders: 'draft-8', legacyHeaders: false }), (req, res, next) => {
    if (req.headers.origin && req.headers.origin !== publicOrigin) return res.status(403).json({ error: 'origin_rejected' });
    if (req.method === 'POST' && !req.is('application/json')) return res.status(415).json({ error: 'json_required' });
    next();
  });
  app.get('/api/health', (_req, res) => res.json({ service: 'shade-web-alpha', protocol: 2, isolated: true }));
  app.get('/api/session', (req, res) => {
    const s = sessions.get(req.cookies[sidName]);
    if (!s || s.expiresAt <= Date.now()) return res.json({ authenticated: false, googleConfigured: provider.configured });
    const account = registry.accountForGoogle(s.profile.googleSub);
    res.json({ authenticated: true, googleConfigured: provider.configured, account,
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
  app.post('/api/v2/session/google', rateLimit({ windowMs: 60000, limit: 15 }), wrap(async (req, res) => {
    // Audience (the OAuth client ID) is mandatory for ID-token verification.
    check(Boolean(clientId), 'Google OAuth is not configured');
    const { idToken } = req.body || {};
    check(typeof idToken === 'string' && idToken.length > 0 && idToken.length <= 10000, 'Invalid Google ID token');
    const profile = await verifier.googleProfile(idToken);
    const old = req.cookies[sidName]; if (old) sessions.delete(old);
    const sid = token(); sessions.set(sid, { profile, expiresAt: Date.now() + SESSION_MS });
    res.cookie(sidName, sid, { ...cookieOptions, maxAge: SESSION_MS });
    const account = registry.accountForGoogle(profile.googleSub);
    res.json({ authenticated: true, account, directory: account ? registry.directory(account) : null });
  }));
  app.post('/api/logout', requireGoogle, (req, res) => {
    sessions.delete(req.alphaSid); res.clearCookie(sidName, cookieOptions);
    for (const socket of io.sockets.sockets.values()) if (socket.data.sid === req.alphaSid) socket.disconnect(true);
    res.json({ ok: true });
  });
  app.post('/api/v2/register', requireGoogle, wrap(async (req, res) => {
    const { genesis, manifest, proofs } = req.body;
    const result = await registry.register({ genesis, manifest, proofs, googleIdToken: req.alphaSid });
    res.json(result);
  }));
  // Only explicit isolated legacy fixtures/imports can appear here. The CLI
  // never loads production users. Original RSA must sign the migration genesis.
  app.post('/api/v2/legacy-enrollment', requireGoogle, wrap(async (req, res) => {
    const { genesis, manifest, proofs = [] } = req.body;
    const account = registry.accountForGoogle(req.alphaSession.profile.googleSub);
    check(account === genesis?.account && genesis.legacy === true &&
      registry.directory(account).history.length === 0, 'Explicit legacy enrollment required');
    res.json(await registry.install(manifest, proofs, genesis));
  }));
  function bindSession(req, auth) {
    check(auth && registry.accountForGoogle(req.alphaSession.profile.googleSub) === auth.account, 'Wrong Google account');
  }
  app.post('/api/v2/challenge', requireGoogle, wrap(async (req, res) => {
    const { account, id, operation } = req.body;
    bindSession(req, { account });
    res.json({ nonce: registry.challenge(account, id, operation) });
  }));
  const room = (account, id) => `${account}:${id}`;
  app.post('/api/v2/operation', requireGoogle, wrap(async (req, res) => {
    const { op, body = null, auth } = req.body;
    bindSession(req, auth);
    let result;
    if (op === 'send') {
      result = await registry.send(body, auth);
      for (const e of body.envelopes) io.to(room(e.account, e.deviceId)).emit('inbox');
    } else if (op === 'fetch') result = await registry.fetch(auth);
    else if (op === 'ack') {
      const pending = registry.exportSnapshot().queues[room(auth.account, auth.id)] || [];
      result = await registry.acknowledge(body, auth);
      for (const m of pending) if (body.includes(`${m.from}:${m.deviceId}:${m.id}`)) {
        const dir = registry.directory(m.from).history.at(-1);
        for (const d of dir.devices) io.to(room(m.from, d.id)).emit('receipts');
      }
    } else if (op === 'status') result = await registry.status(body, auth);
    else {
      check(['users', 'directory', 'install'].includes(op), 'Unknown operation');
      await registry.authorize(auth, await operationDigest(op, body));
      if (op === 'users') result = registry.list();
      if (op === 'directory') result = registry.directory(body);
      if (op === 'install') result = await registry.install(body.manifest, body.proofs || [], body.genesis || null);
    }
    res.json(result);
  }));
  // Socket events are wake-up hints only. Lost hints are repaired by signed
  // fetch on reconnect/foreground and periodic polling; receipt != socket emit.
  io.use(async (socket, next) => {
    try {
      const cookies = Object.fromEntries((socket.handshake.headers.cookie || '').split(';').map(p => p.trim().split('=')));
      const sid = cookies[sidName], session = sessions.get(sid);
      check(session && session.expiresAt > Date.now(), 'Google login required');
      const auth = socket.handshake.auth;
      check(registry.accountForGoogle(session.profile.googleSub) === auth.account, 'Wrong Google account');
      await registry.authorize(auth, await operationDigest('socket'));
      socket.data = { sid, account: auth.account, id: auth.id, expiresAt: session.expiresAt };
      next();
    } catch { next(Error('device_auth_required')); }
  });
  io.on('connection', socket => { socket.join(room(socket.data.account, socket.data.id)); socket.emit('inbox'); });
  const cleanup = setInterval(() => {
    for (const [sid, s] of sessions) if (s.expiresAt <= Date.now()) sessions.delete(sid);
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
      /already registered/.test(message) ? 'account_requires_linking' : 'operation_rejected' });
  });
  return { app, server, io, registry,
    async close() { clearInterval(cleanup); await new Promise(resolve => io.close(resolve)); await store.close(); } };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  check(process.env.SHADE_ENV === 'alpha', 'Set SHADE_ENV=alpha; production startup forbidden');
  const instance = await createAlphaServer({ dataDir: process.env.ALPHA_DATA_DIR,
    storageSecret: process.env.ALPHA_STORAGE_SECRET, publicOrigin: process.env.ALPHA_PUBLIC_ORIGIN,
    clientId: process.env.ALPHA_GOOGLE_CLIENT_ID, clientSecret: process.env.ALPHA_GOOGLE_CLIENT_SECRET });
  const port = Number(process.env.ALPHA_PORT || 3101);
  instance.server.once('error', error => {
    console.error(`Alpha listener failed: ${error.code || 'unknown'}`);
    instance.close().finally(() => process.exit(1));
  });
  instance.server.listen(port, '127.0.0.1', () => console.log(`Shade alpha listening on loopback port ${port}`));
  for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => instance.close().then(() => process.exit(0)));
}
