// Shade v2 STAGING live smoke — синтетические данные, без реальных пользователей.
// Режимы: prepare (fixture + CLI prepare + env bridge) | enroll (HTTP flow).
// Запускается из <release>/server. НЕ трогает production.
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { randomBytes, createPublicKey, privateDecrypt, createDecipheriv,
  constants, sign as nodeSign, createHash } from 'node:crypto';
import { buildV1Fixture } from './test/helpers/v1-fixture.mjs';
import { legacyRoot } from './multidevice/registry.mjs';
import { genesisText, manifestText, requestText, hash, fingerprint } from '../client/web/protocol/device-v2.mjs';
import * as c from '../client/web/device_crypto.mjs';

const MODE = process.argv[2];
const DATA = '/var/lib/shade-staging';
const BASE = process.argv[3] || 'https://alpha.shadechat.ru';
const V1DIR = path.join(DATA, 'v1-synthetic');
const ENVF = path.join(DATA, 'staging.env');
const PHRASE = 'synthetic staging smoke recovery phrase only';
const signText = (text, privateKey) => nodeSign('sha256',
  Buffer.from(Buffer.from(text, 'utf8').toString('base64')),
  { key: privateKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function readEnv() {
  const out = {};
  for (const line of (await fs.readFile(ENVF, 'utf8')).split('\n')) {
    const i = line.indexOf('=');
    if (i > 0 && !line.startsWith('#')) out[line.slice(0, i)] = line.slice(i + 1);
  }
  return out;
}
async function req(route, body, cookie = '', headers = {}) {
  const response = await fetch(BASE + route, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { 'Content-Type': 'application/json', Origin: BASE, Cookie: cookie, ...headers },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  });
  const text = await response.text();
  let json = null; try { json = JSON.parse(text); } catch {}
  return { status: response.status, json, headers: response.headers };
}
function openV1Payload(payloadJson, privateKey) {
  const { k, d } = JSON.parse(payloadJson);
  const envelope = Buffer.from(privateDecrypt({ key: privateKey,
    padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, Buffer.from(k, 'base64')).toString('utf8'), 'base64');
  const data = Buffer.from(d, 'base64');
  const decipher = createDecipheriv('aes-256-gcm', envelope.subarray(1, 33), envelope.subarray(33));
  decipher.setAuthTag(data.subarray(data.length - 16));
  return Buffer.concat([decipher.update(data.subarray(0, data.length - 16)), decipher.final()]).toString('utf8');
}

if (MODE === 'prepare') {
  const secret = randomBytes(32).toString('hex');
  const msgId = randomBytes(16).toString('hex');
  const { keys } = await buildV1Fixture(V1DIR, { secret, users: [
    { account: 'smoke_alice', profile: { displayName: 'Smoke Alice', avatarFrame: 'silver', avatarRevision: 1, inventory: [], wall: [], revision: 1 } },
    { account: 'smoke_bob' },
  ], messages: [{ to: 'smoke_alice', from: 'smoke_bob', id: msgId, text: 'synthetic v1 queue message' }] });
  // Сохраняем синтетические ключи/secret для enroll-режима (только synthetic).
  await fs.writeFile(path.join(DATA, 'smoke-fixture.json'), JSON.stringify({
    secret, msgId,
    alicePrivate: keys.get('smoke_alice').privateKey,
    bobPrivate: keys.get('smoke_bob').privateKey
  }), { mode: 0o600 });
  const env = await readEnv();
  execFileSync(process.execPath, ['tools/migrate-v1-to-v2.mjs', 'prepare',
    '--source', V1DIR, '--target', env.ALPHA_DATA_DIR, '--all'],
    { env: { ...process.env, ALPHA_STORAGE_SECRET: env.ALPHA_STORAGE_SECRET }, stdio: 'inherit' });
  const verify = execFileSync(process.execPath, ['tools/migrate-v1-to-v2.mjs', 'verify',
    '--source', V1DIR, '--target', env.ALPHA_DATA_DIR],
    { env: { ...process.env, ALPHA_STORAGE_SECRET: env.ALPHA_STORAGE_SECRET }, encoding: 'utf8' });
  console.log('verify:', verify.trim().split('\n').slice(0, 3).join(' '));
  // Bridge env (staging-only paths; production guard НЕ включается).
  let envText = await fs.readFile(ENVF, 'utf8');
  if (!envText.includes('ALPHA_V1_DATA_DIR=')) {
    envText += `\nALPHA_V1_DATA_DIR=${V1DIR}\nALPHA_V2_GUARD_FILE=${DATA}/v2-migration-guard.json\nALPHA_V2_BRIDGE_ACK_FILE=${DATA}/v2-bridge-ack.json\n`;
    await fs.writeFile(ENVF, envText, { mode: 0o600 });
  }
  console.log('PREPARE_OK');
} else if (MODE === 'enroll') {
  const fx = JSON.parse(await fs.readFile(path.join(DATA, 'smoke-fixture.json'), 'utf8'));
  // 1. Базовые проверки.
  const health = await req('/api/health');
  if (health.status !== 200 || health.json.protocol !== 2 || health.json.legacyBridge !== true)
    throw Error('health/legacyBridge check failed: ' + JSON.stringify(health.json));
  console.log('PASS health + legacyBridge');
  const root = await req('/');
  const csp = root.headers.get('content-security-policy') || '';
  if (!csp.includes("default-src 'self'")) throw Error('CSP missing');
  console.log('PASS CSP');
  for (const p of ['/admin', '/dashboard', '/api/stats']) {
    const r = await req(p);
    if (r.status !== 404) throw Error(`admin surface ${p} -> ${r.status}`);
  }
  console.log('PASS admin surfaces 404');
  const sioRaw = await (await fetch(BASE + '/socket.io/?EIO=4&transport=polling', { headers: { Origin: BASE } })).text();
  if (!sioRaw.includes('"sid"')) throw Error('socket.io handshake failed: ' + sioRaw.slice(0, 120));
  console.log('PASS socket.io polling');
  const evil = await fetch(BASE + '/api/session', { headers: { Origin: 'https://evil.example' } });
  if (evil.status !== 403) throw Error('cross-origin not rejected: ' + evil.status);
  console.log('PASS cross-origin 403');
  // 2. Legacy-key сессия + enrollment синтетического аккаунта.
  const ch = await req('/api/v2/session/legacy-challenge', { account: 'smoke_alice' });
  if (ch.status !== 200) throw Error('legacy-challenge failed: ' + JSON.stringify(ch.json));
  const operation = await hash(JSON.stringify(['legacy-session', null]));
  const proof = signText(requestText('smoke_alice', 'primary', ch.json.nonce, operation), fx.alicePrivate);
  const sess = await req('/api/v2/session/legacy', { account: 'smoke_alice', nonce: ch.json.nonce, proof });
  if (sess.status !== 200) throw Error('legacy session failed: ' + JSON.stringify(sess.json));
  const cookie = (sess.headers.getSetCookie?.() || []).find(s =>
    s.startsWith('__Host-shade-alpha=') || s.startsWith('shade-alpha='))?.split(';')[0];
  if (!cookie) throw Error('no session cookie');
  console.log('PASS legacy-key session (synthetic account)');
  const rootSpki = legacyRoot(createPublicKey(fx.alicePrivate).export({ type: 'spki', format: 'pem' }));
  const recovery = await c.createRecoveryBackup('smoke_alice', rootSpki, PHRASE);
  const now = Date.now();
  const genesis = { version: 2, account: 'smoke_alice', nonce: randomBytes(32).toString('hex'), createdAt: now,
    legacy: true, firstDevice: { id: 'primary', encryptionKey: rootSpki, signingKey: rootSpki },
    recoveryKey: recovery.publicKey, signature: '' };
  genesis.signature = signText(genesisText(genesis), fx.alicePrivate);
  const manifest = { account: 'smoke_alice', rootFingerprint: await fingerprint(rootSpki), revision: 1, previous: '',
    issuedAt: now, expiresAt: now + 86400000, devices: [genesis.firstDevice], signer: 'primary', signature: '' };
  manifest.signature = signText(manifestText(manifest), fx.alicePrivate);
  const enrolled = await req('/api/v2/legacy-enrollment', { genesis, manifest }, cookie);
  if (enrolled.status !== 200) throw Error('enrollment failed: ' + JSON.stringify(enrolled.json));
  console.log('PASS legacy enrollment revision', enrolled.json.revision);
  // 3. Bridged v1 ciphertext: drains and decrypts ONLY with the synthetic old key.
  const opDigest = async (op, body = null) => hash(JSON.stringify([op, body]));
  const primaryOp = async (op, body = null) => {
    const opHash = await opDigest(op, body);
    const challenge = await req('/api/v2/challenge', { account: 'smoke_alice', id: 'primary', operation: opHash }, cookie);
    const nonce = challenge.json.nonce;
    const auth = { account: 'smoke_alice', id: 'primary', nonce,
      proof: signText(requestText('smoke_alice', 'primary', nonce, opHash), fx.alicePrivate) };
    return req('/api/v2/operation', { op, body, auth }, cookie);
  };
  const inbox = await primaryOp('legacy.inbox');
  if (inbox.status !== 200 || inbox.json.length !== 1) throw Error('inbox: ' + JSON.stringify(inbox.json));
  const plain = openV1Payload(inbox.json[0].data, fx.alicePrivate);
  if (plain !== 'synthetic v1 queue message') throw Error('decryption mismatch: ' + plain);
  console.log('PASS bridged v1 ciphertext decrypted (old key, server never saw plaintext)');
  const ack = await primaryOp('legacy.ack', [`smoke_bob:${fx.msgId}`]);
  if (ack.json.acknowledged !== 1) throw Error('ack failed');
  const bridgeAck = JSON.parse(await fs.readFile(path.join(DATA, 'v2-bridge-ack.json'), 'utf8'));
  if (!bridgeAck.accounts.smoke_alice?.acked.includes(`smoke_bob:${fx.msgId}`)) throw Error('bridge-ack export missing');
  console.log('PASS legacy.ack + bridge-ack export');
  const guard = JSON.parse(await fs.readFile(path.join(DATA, 'v2-migration-guard.json'), 'utf8'));
  if (!guard.accounts.smoke_alice) throw Error('guard export missing (staging file only)');
  console.log('PASS staging guard export (production v1 NOT touched)');
  const inbox2 = await primaryOp('legacy.inbox');
  if (inbox2.json.length !== 0) throw Error('acked message returned');
  console.log('PASS dedup: acked message never returns');
  console.log('ENROLL_SMOKE_OK');
} else {
  throw Error('usage: staging-live-smoke.mjs prepare|enroll');
}