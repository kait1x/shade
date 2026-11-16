// Safe adapter: reuse the verified v1 stickers/profiles business logic
// (server/stickers.js + server/avatars.js) inside the isolated alpha process.
// Authorization is device-v2 only: Google session + one-time device proof per
// request. v1 session tokens are never accepted here; production storage is
// never touched — the profile store lives in the encrypted alpha snapshot.
import express from 'express';
import { createRequire } from 'node:module';
import { check, requestText } from '../../client/web/protocol/device-v2.mjs';
import { operationDigest } from './registry.mjs';

const require = createRequire(import.meta.url);
const { installStickers } = require('../stickers.js');

export function createV2Stickers({ registry, io }) {
  const router = express.Router();
  // Live view of enrolled v2 accounts; avatarOwner binds to the immutable root.
  const users = {
    has(name) {
      try { return registry.directory(name).history.length > 0; } catch { return false; }
    },
    get(name) {
      const dir = registry.directory(name);
      return { publicKey: dir.root, displayName: null, avatarUrl: null };
    }
  };
  const initial = new Map(Object.entries(registry.exportSnapshot().stickers || {}));
  const persist = async next => {
    try {
      await registry.updateState(state => { state.stickers = Object.fromEntries(next); });
      return true;
    } catch { return false; }
  };
  const auth = (req, res, next) => {
    (async () => {
      // Defense in depth: the proof account must match the Google session.
      const sessionAccount = registry.accountForGoogle(req.alphaSession.profile.googleSub);
      const raw = req.headers['x-device-auth'];
      check(typeof raw === 'string' && raw.length <= 2000, 'Device proof required');
      const auth = JSON.parse(raw);
      check(auth && auth.account === sessionAccount, 'Wrong Google account');
      // GET/HEAD carry no body; express.json defaults it to {} — normalize so
      // the client digest (body: null) matches byte-for-byte.
      const body = (req.method === 'GET' || req.method === 'HEAD') ? null : (req.body ?? null);
      const operation = await operationDigest('stickers',
        { method: req.method, path: req.path, body });
      await registry.authorize(auth, operation);
      req.auth = { username: auth.account };
      next();
    })().catch(() => res.status(401).json({ error: 'device_auth_required' }));
  };
  const avatarChanged = name => {
    try {
      const dir = registry.directory(name).history.at(-1);
      if (dir) for (const d of dir.devices) io.to(`${name}:${d.id}`).emit('profile', { account: name });
    } catch { /* unknown account: no hint */ }
  };
  installStickers(router, auth, users, initial, persist, avatarChanged);
  return router;
}

// Client helper contract (documented for ZCODE):
// operation = SHA256(JSON.stringify(['stickers', {method, path, body}]))
// where path is router-relative (e.g. '/stickers/gift') and body is the exact
// JSON sent (null for GET). Challenge via /api/v2/challenge, then send header
// x-device-auth: {account, id, nonce, proof} with proof = RSA-PSS over
// requestText(account, id, nonce, operation). One nonce per request.
export const stickersOperation = (method, path, body = null) =>
  operationDigest('stickers', { method, path, body });
export { requestText };