// Synthetic v1 storage fixture: byte-compatible with server.js at-rest format
// (AES-256-GCM + HMAC sidecar + offline metadata envelopes). Test data only.
import { createHash, createHmac, createCipheriv, randomBytes,
  generateKeyPairSync, publicEncrypt, constants } from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

export function v1Encrypt(data, secret) {
  const key = createHash('sha256').update(secret).digest();
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  const encrypted = Buffer.concat([cipher.update(JSON.stringify(data), 'utf8'), cipher.final()]);
  return JSON.stringify({ nonce: nonce.toString('hex'), tag: cipher.getAuthTag().toString('hex'),
    data: encrypted.toString('hex') });
}

// Mirrors server.js _encryptMetadata for queued offline envelopes.
export function v1WrapMeta(envelope, secret) {
  const salt = randomBytes(16);
  const key = createHash('sha256').update('offline_meta_' + secret + salt.toString('hex')).digest();
  const metadata = JSON.stringify({ id: envelope.id, from: envelope.from, ts: envelope.timestamp });
  const nonce = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, nonce);
  const encrypted = Buffer.concat([cipher.update(metadata, 'utf8'), cipher.final()]);
  return { s: salt.toString('base64'),
    d: Buffer.concat([nonce, cipher.getAuthTag(), encrypted]).toString('base64'),
    m: envelope.data };
}

// v1 E2EE payload: RSA-OAEP-SHA256 over base64(2||AESkey32||nonce12) + AES-GCM.
export function v1Seal(text, publicKeyPem) {
  const raw = randomBytes(32), nonce = randomBytes(12);
  const envelope = Buffer.concat([Buffer.from([2]), raw, nonce]).toString('base64');
  const k = publicEncrypt({ key: publicKeyPem, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
    Buffer.from(envelope, 'utf8')).toString('base64');
  const cipher = createCipheriv('aes-256-gcm', raw, nonce);
  const d = Buffer.concat([cipher.update(text, 'utf8'), cipher.final(), cipher.getAuthTag()]).toString('base64');
  return JSON.stringify({ k, d });
}

export async function writeV1Queue(dir, secret, queues, receipts = []) {
  const wrapped = [...queues.entries()].map(([account, queue]) =>
    [account, queue.map(envelope => v1WrapMeta(envelope, secret))]);
  await fs.writeFile(path.join(dir, 'messaging.json'),
    v1Encrypt([['queues', wrapped], ['receipts', receipts]], secret), { mode: 0o600 });
}

// users: [{account, bits?, googleSub?, displayName?, profile?}]
// messages: [{to, from, id, text}] — queued to the recipient's public key.
export async function buildV1Fixture(dir, { secret, users, messages = [] }) {
  await fs.mkdir(dir, { recursive: true });
  const keys = new Map();
  const entries = [];
  const stickers = [];
  for (const spec of users) {
    if (spec.noKey) { entries.push([spec.account, { registeredAt: Date.now(), tokenVersion: 1 }]); continue; }
    // An externally supplied public key (e.g. the Dart test device's RSA) is
    // used verbatim; the private half never exists in this process.
    const pair = spec.publicKey
      ? { publicKey: spec.publicKey, privateKey: null }
      : generateKeyPairSync('rsa', { modulusLength: spec.bits || 4096,
          publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
    keys.set(spec.account, pair);
    entries.push([spec.account, { publicKey: pair.publicKey, registeredAt: Date.now(), tokenVersion: 1,
      ...(spec.googleSub ? { googleSub: spec.googleSub, email: `${spec.account}@test.invalid`,
        email_verified: true, displayName: spec.displayName || spec.account } : {}) }]);
    if (spec.profile) {
      stickers.push([spec.account, { ...spec.profile,
        avatarOwner: createHash('sha256').update(pair.publicKey).digest('hex') }]);
    }
  }
  const checksum = createHash('sha256').update(secret).digest('hex');
  await fs.writeFile(path.join(dir, 'session_secret'), `${secret}:${checksum}`, { mode: 0o600 });
  await fs.writeFile(path.join(dir, 'users.json'), v1Encrypt(entries, secret), { mode: 0o600 });
  await fs.writeFile(path.join(dir, 'users.json.hmac'),
    createHmac('sha256', secret).update(JSON.stringify(entries)).digest('hex'), { mode: 0o600 });
  if (stickers.length) {
    await fs.writeFile(path.join(dir, 'stickers.json'), v1Encrypt(stickers, secret), { mode: 0o600 });
  }
  const queues = new Map();
  for (const m of messages) {
    const recipient = keys.get(m.to);
    if (!recipient) throw new Error(`fixture: unknown recipient ${m.to}`);
    const queue = queues.get(m.to) || [];
    queue.push({ id: m.id, from: m.from, timestamp: m.timestamp || Date.now(),
      data: v1Seal(m.text, recipient.publicKey) });
    queues.set(m.to, queue);
  }
  await writeV1Queue(dir, secret, queues);
  return { secret, keys };
}