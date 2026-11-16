// Native (Android-style) session and legacy enrollment over the real alpha
// HTTP adapter. Synthetic keys/users only; production data is never touched.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { generateKeyPairSync, randomBytes, createPublicKey, publicEncrypt,
  privateDecrypt, createCipheriv, createDecipheriv, constants,
  sign as nodeSign, verify as nodeVerify } from 'node:crypto';
import { fixture, identity, register, operation } from './helpers/alpha-fixture.mjs';
import { legacyRoot, messageRef } from '../multidevice/registry.mjs';
import { genesisText, manifestText, messageText, requestText, hash,
  fingerprint } from '../../client/web/protocol/device-v2.mjs';
import { sealMessage, openMessage, createRecoveryBackup } from '../../client/web/device_crypto.mjs';

const verifyGoogle = async (token, audience) => {
  if (audience !== 'test-client') throw Error('Wrong audience');
  if (!token.startsWith('synthetic-')) throw Error('Invalid test token');
  return { sub: token, email: `${token}@test.invalid`, email_verified: true };
};
const signText = (text, privateKey) => nodeSign('sha256',
  Buffer.from(Buffer.from(text, 'utf8').toString('base64')),
  { key: privateKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
const verifyText = (text, signature, spki) => nodeVerify('sha256',
  Buffer.from(Buffer.from(text, 'utf8').toString('base64')),
  { key: createPublicKey({ key: Buffer.from(spki, 'base64'), format: 'der', type: 'spki' }),
    padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }, Buffer.from(signature, 'base64'));

function sealEnvelope(text, spki) {
  const raw = randomBytes(32), nonce = randomBytes(12);
  const envelope = Buffer.alloc(45); envelope[0] = 2; raw.copy(envelope, 1); nonce.copy(envelope, 33);
  const key = createPublicKey({ key: Buffer.from(spki, 'base64'), format: 'der', type: 'spki' });
  const k = publicEncrypt({ key, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
    Buffer.from(envelope.toString('base64'), 'utf8')).toString('base64');
  const cipher = createCipheriv('aes-256-gcm', raw, nonce);
  const d = Buffer.concat([cipher.update(text, 'utf8'), cipher.final(), cipher.getAuthTag()]).toString('base64');
  return { k, d };
}
function openEnvelope(payload, privateKey) {
  const envelope = Buffer.from(privateDecrypt(
    { key: privateKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' },
    Buffer.from(payload.k, 'base64')).toString('utf8'), 'base64');
  assert.equal(envelope.length, 45);
  assert.equal(envelope[0], 2);
  const data = Buffer.from(payload.d, 'base64');
  const decipher = createDecipheriv('aes-256-gcm', envelope.subarray(1, 33), envelope.subarray(33));
  decipher.setAuthTag(data.subarray(data.length - 16));
  return Buffer.concat([decipher.update(data.subarray(0, data.length - 16)), decipher.final()]).toString('utf8');
}
async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-native-session-'));
}

test('native Google ID-token session, legacy enrollment and bidirectional E2EE over HTTP', async () => {
  const native = generateKeyPairSync('rsa', { modulusLength: 4096,
    publicKeyEncoding: { type: 'spki', format: 'pem' }, privateKeyEncoding: { type: 'pkcs8', format: 'pem' } });
  const root = legacyRoot(native.publicKey);
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex'),
    clientId: 'test-client', clientSecret: 'test-secret', verifyGoogle,
    legacyUsers: new Map([['native_android', { publicKey: native.publicKey, googleSub: 'synthetic-native' }]]) });
  try {
    const web = await identity('native_web');
    const wc = await f.login('synthetic-web');
    await register(f, web, wc);
    const nc = await f.loginToken('synthetic-native');
    const session = await f.request('/api/session', undefined, nc);
    assert.equal(session.result.authenticated, true);
    assert.equal(session.result.account, 'native_android');

    const recovery = await createRecoveryBackup('native_android', root, 'synthetic native offline recovery phrase');
    const now = Date.now();
    const genesis = { version: 2, account: 'native_android', nonce: randomBytes(32).toString('hex'),
      createdAt: now, legacy: true, firstDevice: { id: 'primary', encryptionKey: root, signingKey: root },
      recoveryKey: recovery.publicKey, signature: '' };
    genesis.signature = signText(genesisText(genesis), native.privateKey);
    const manifest = { account: 'native_android', rootFingerprint: await fingerprint(root),
      revision: 1, previous: '', issuedAt: now, expiresAt: now + 86400000,
      devices: [genesis.firstDevice], signer: 'primary', signature: '' };
    manifest.signature = signText(manifestText(manifest), native.privateKey);
    const enrolled = await f.request('/api/v2/legacy-enrollment', { genesis, manifest }, nc);
    assert.equal(enrolled.response.status, 200);
    assert.equal(enrolled.result.revision, 1);
    // Повторная enrollment запрещена: история уже существует.
    const again = await f.request('/api/v2/legacy-enrollment', { genesis, manifest }, nc);
    assert.equal(again.response.status, 400);

    const nativeOp = async (op, body = null) => {
      const operation = await hash(JSON.stringify([op, op === 'send' ? await hash(messageText(body)) : body]));
      const challenge = await f.request('/api/v2/challenge',
        { account: 'native_android', id: 'primary', operation }, nc);
      assert.equal(challenge.response.status, 200);
      const nonce = challenge.result.nonce;
      return f.request('/api/v2/operation', { op, body,
        auth: { account: 'native_android', id: 'primary', nonce,
          proof: signText(requestText('native_android', 'primary', nonce, operation), native.privateKey) } }, nc);
    };

    // Web → native: сервер хранит только шифротекст, native расшифровывает.
    const toNative = 'Web → native session 🔐';
    const trust = { senderRoot: web.vault.signingKey, recipientRoot: root,
      senderGenesis: web.genesis, recipientGenesis: genesis };
    const m = await sealMessage(toNative, [web.manifest], [manifest], web.session, trust);
    assert.equal((await operation(f, web, wc, 'send', m)).result.accepted, true);
    const inbox = (await nativeOp('fetch')).result;
    const bundle = inbox.find(b => b.message.from === 'native_web');
    assert.ok(bundle);
    assert.ok(verifyText(messageText(bundle.message), bundle.message.signature, web.vault.signingKey));
    const own = bundle.message.envelopes.find(e => e.deviceId === 'primary');
    assert.equal(openEnvelope(own.payload, native.privateKey), toNative);
    const ref = messageRef(bundle.message);
    assert.equal((await nativeOp('ack', [ref])).result.acknowledged, 1);

    // Native → web: подписанный fanout, Web расшифровывает и ACK-ает.
    const toWeb = 'native session → Web 🌍';
    const reply = { version: 2, id: randomBytes(32).toString('hex'), from: 'native_android',
      deviceId: 'primary', to: 'native_web', fromRevision: 1, toRevision: 1,
      fromDigest: await hash(manifestText(manifest)), toDigest: await hash(manifestText(web.manifest)),
      createdAt: Date.now(), envelopes: [
        { account: 'native_android', deviceId: 'primary', payload: sealEnvelope(toWeb, root) },
        { account: 'native_web', deviceId: web.session.id, payload: sealEnvelope(toWeb, web.vault.encryptionKey) }],
      signature: '' };
    reply.signature = signText(messageText(reply), native.privateKey);
    assert.equal((await nativeOp('send', reply)).result.accepted, true);
    const webInbox = (await operation(f, web, wc, 'fetch')).result;
    const webBundle = webInbox.find(b => b.message.from === 'native_android');
    const plaintext = await openMessage(webBundle, web.session,
      { senderRoot: root, recipientRoot: web.vault.signingKey,
        senderGenesis: genesis, recipientGenesis: web.genesis });
    assert.equal(plaintext, toWeb);
    const replyRef = messageRef(reply);
    await operation(f, web, wc, 'ack', [replyRef]);
    const status = (await nativeOp('status', [replyRef])).result;
    assert.equal(typeof status[replyRef][0].acknowledgedAt, 'number');

    // Cookie без device-proof не авторизует чтение очереди.
    const fetchDigest = await hash(JSON.stringify(['fetch', null]));
    const challenge = await f.request('/api/v2/challenge',
      { account: 'native_android', id: 'primary', operation: fetchDigest }, nc);
    const noProof = await f.request('/api/v2/operation',
      { op: 'fetch', auth: { account: 'native_android', id: 'primary', nonce: challenge.result.nonce } }, nc);
    assert.equal(noProof.response.status, 400);
  } finally { await f.close(); }
});

test('google token session fails closed on bad tokens and unconfigured provider', async () => {
  const f = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex'),
    clientId: 'test-client', clientSecret: 'test-secret', verifyGoogle });
  try {
    assert.equal((await f.request('/api/v2/session/google', { idToken: 'bad-token' })).response.status, 400);
    assert.equal((await f.request('/api/v2/session/google', {})).response.status, 400);
    const ok = await f.request('/api/v2/session/google', { idToken: 'synthetic-new-user' });
    assert.equal(ok.response.status, 200);
    assert.equal(ok.result.authenticated, true);
    assert.equal(ok.result.account, null);
  } finally { await f.close(); }
  const unconfigured = await fixture({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex') });
  try {
    const reply = await unconfigured.request('/api/v2/session/google', { idToken: 'synthetic-native' });
    assert.equal(reply.response.status, 400);
    assert.equal(reply.result.error, 'google_not_configured');
  } finally { await unconfigured.close(); }
});