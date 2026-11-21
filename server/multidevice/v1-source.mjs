// READ-ONLY bridge to the legacy v1 data directory (server.js format).
// Never writes, renames or deletes anything inside the source directory.
// Used by the migration CLI and (optionally) by the isolated alpha process to
// seed legacy accounts and drain pending offline queues at cutover.
// E2EE ciphertext ({k,d}) is passed through untouched: the server never
// decrypts message payloads, only the at-rest metadata envelope.
import { createHash, createHmac, createDecipheriv, createPublicKey, timingSafeEqual } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const ACCOUNT = /^[a-z0-9_]{3,32}$/;
const QUEUE_TTL_MS = 7 * 24 * 60 * 60 * 1000;

function decryptFile(encryptedStr, secret) {
  const key = createHash('sha256').update(secret).digest();
  const { nonce, tag, data } = JSON.parse(encryptedStr);
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(nonce, 'hex'));
  decipher.setAuthTag(Buffer.from(tag, 'hex'));
  return JSON.parse(Buffer.concat([decipher.update(Buffer.from(data, 'hex')), decipher.final()]).toString('utf8'));
}

// session_secret file format: "secret:sha256(secret)" or legacy plain secret.
export function parseSessionSecret(content) {
  const trimmed = String(content).trim();
  const idx = trimmed.lastIndexOf(':');
  if (idx > 0) {
    const secret = trimmed.slice(0, idx);
    const checksum = trimmed.slice(idx + 1);
    const computed = createHash('sha256').update(secret).digest('hex');
    const a = Buffer.from(checksum, 'hex'), b = Buffer.from(computed, 'hex');
    if (a.length === b.length && timingSafeEqual(a, b) && secret.length >= 32) return secret;
  }
  if (trimmed.length >= 32) return trimmed;
  throw new Error('Invalid session_secret file');
}

async function readOptional(dir, file) {
  try { return await fs.readFile(path.join(dir, file), 'utf8'); }
  catch (e) { if (e.code === 'ENOENT') return null; throw e; }
}

// Validates one legacy user record for v2 eligibility. Returns a reason code
// (never secret material) when the account cannot be migrated.
export function validateLegacyUser(account, user) {
  if (!ACCOUNT.test(account)) return { eligible: false, reason: 'invalid_account' };
  if (!user || typeof user.publicKey !== 'string') return { eligible: false, reason: 'missing_public_key' };
  let key;
  try { key = createPublicKey(user.publicKey); }
  catch { return { eligible: false, reason: 'unparsable_public_key' }; }
  if (key.asymmetricKeyType !== 'rsa') return { eligible: false, reason: 'unsupported_key_type' };
  const bits = key.asymmetricKeyDetails?.modulusLength;
  if (bits !== 4096) {
    // RSA-2048..4095 accounts cannot keep their key as a v2 anchor, but the
    // owner can prove possession of the old key and rotate to a fresh
    // RSA-4096 identity (auditable change, not the same crypto identity).
    if (bits >= 2048 && bits < 4096) return { eligible: false, rotation: true, reason: 'rotation_required' };
    return { eligible: false, reason: 'unsupported_key_size' };
  }
  return { eligible: true, reason: null };
}

export async function openV1Source(dataDir, { secret, now = Date.now } = {}) {
  const dir = path.resolve(dataDir);
  const stat = await fs.stat(dir).catch(() => null);
  if (!stat?.isDirectory()) throw new Error('V1 data directory not found');
  if (!secret) {
    const content = await readOptional(dir, 'session_secret');
    if (content == null) throw new Error('session_secret missing; provide the secret explicitly');
    secret = parseSessionSecret(content);
  }
  if (typeof secret !== 'string' || secret.length < 32) throw new Error('Invalid v1 storage secret');

  async function loadEncryptedMap(file, { hmac = false } = {}) {
    const content = await readOptional(dir, file);
    if (content == null) return new Map();
    const data = decryptFile(content, secret);
    if (hmac) {
      const stored = await readOptional(dir, file + '.hmac');
      if (stored != null) {
        const expected = createHmac('sha256', secret).update(JSON.stringify(data)).digest();
        const a = Buffer.from(stored.trim(), 'hex');
        if (a.length !== expected.length || !timingSafeEqual(a, expected)) {
          throw new Error(`Integrity check failed for ${file}`);
        }
      }
    }
    return new Map(data);
  }

  const users = await loadEncryptedMap('users.json', { hmac: true });
  let stickers = new Map();
  let stickersError = null;
  try { stickers = await loadEncryptedMap('stickers.json'); }
  catch { stickers = new Map(); stickersError = 'stickers_unreadable'; }

  // The offline queue is re-read on every access: the v1 server keeps writing
  // it until the migration guard activates, and the bridge must see arrivals
  // that happened after this source was opened (cutover race window).
  async function loadMessaging() {
    try { return { map: await loadEncryptedMap('messaging.json'), error: null }; }
    catch { return { map: new Map(), error: 'messaging_unreadable' }; }
  }

  const eligibility = new Map();
  for (const [account, user] of users) eligibility.set(account, validateLegacyUser(account, user));

  // Unwrap the v1 offline-metadata envelope {s,d,m}; m stays E2EE ciphertext.
  function unwrapQueued(value) {
    if (!value || typeof value !== 'object') return null;
    if (!value.s) return value; // plain legacy envelope
    try {
      const salt = Buffer.from(value.s, 'base64');
      const combined = Buffer.from(value.d, 'base64');
      const key = createHash('sha256').update('offline_meta_' + secret + salt.toString('hex')).digest();
      const nonce = combined.subarray(0, 12), tag = combined.subarray(12, 28), body = combined.subarray(28);
      const decipher = createDecipheriv('aes-256-gcm', key, nonce);
      decipher.setAuthTag(tag);
      const meta = JSON.parse(Buffer.concat([decipher.update(body), decipher.final()]).toString('utf8'));
      return { id: meta.id, from: meta.from, timestamp: meta.ts, data: value.m };
    } catch { return null; }
  }

  async function queueFor(account) {
    const { map, error } = await loadMessaging();
    if (error) throw new Error(error);
    const raw = map.get('queues') || [];
    const queue = new Map(raw).get(account) || [];
    const cutoff = now() - QUEUE_TTL_MS;
    const out = [];
    for (const value of queue) {
      const envelope = unwrapQueued(value);
      if (!envelope || typeof envelope.data !== 'string') continue;
      if ((envelope.timestamp || 0) < cutoff) continue;
      out.push({ id: envelope.id, from: envelope.from, timestamp: envelope.timestamp, data: envelope.data });
    }
    return out;
  }

  return {
    dir,
    users,
    eligibility,
    queueFor,
    stickersError,
    profileFor(account) { return stickers.get(account) || null; },
    async counts() {
      const { map, error } = await loadMessaging();
      const queues = error ? null : new Map(map.get('queues') || []);
      const receipts = error ? null : new Map(map.get('receipts') || []);
      let groups = null;
      const groupsRaw = await readOptional(dir, 'groups.json');
      if (groupsRaw != null) { try { groups = JSON.parse(groupsRaw).length; } catch { groups = null; } }
      return {
        users: users.size,
        eligible: [...eligibility.values()].filter(e => e.eligible).length,
        rotationEligible: [...eligibility.values()].filter(e => e.rotation).length,
        queues: queues ? queues.size : null,
        queuedMessages: queues ? [...queues.values()].reduce((n, q) => n + (Array.isArray(q) ? q.length : 0), 0) : null,
        receipts: receipts ? receipts.size : null,
        groups,
        messagingError: error,
      };
    },
  };
}