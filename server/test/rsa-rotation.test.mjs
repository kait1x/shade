// RSA-2048 → RSA-4096 rotation: integration tests. The OLD key proves
// possession via an attestation bound to the exact genesis/manifest digests;
// the NEW RSA-4096 becomes the v2 anchor. This is an auditable identity
// CHANGE (attestation served in the directory), never a claim of preserving
// the same cryptographic identity. Old ciphertext stays decryptable only
// with the old private key, which never leaves the device.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomBytes, generateKeyPairSync, sign as nodeSign, createPublicKey,
  privateDecrypt, createDecipheriv, createHash, constants } from 'node:crypto';
import { fixture } from './helpers/alpha-fixture.mjs';
import { buildV1Fixture } from './helpers/v1-fixture.mjs';
import { legacyRoot } from '../multidevice/registry.mjs';
import { genesisText, manifestText, rotationText, requestText, hash, fingerprint, messageText } from '../../client/web/protocol/device-v2.mjs';
import * as c from '../../client/web/device_crypto.mjs';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(serverRoot, 'tools', 'migrate-v1-to-v2.mjs');
const PHRASE = 'synthetic rotation recovery phrase only';

async function tempDir(prefix) {
  const build = path.join(serverRoot, 'build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, prefix));
}
function cli(args, env = {}) {
  return JSON.parse(execFileSync(process.execPath, [CLI, ...args], {
    cwd: serverRoot, env: { ...process.env, ...env }, encoding: 'utf8' }));
}
const signText = (text, privateKey) => nodeSign('sha256',
  Buffer.from(Buffer.from(text, 'utf8').toString('base64')),
  { key: privateKey, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
function openV1Payload(payloadJson, privateKey) {
  const { k, d } = JSON.parse(payloadJson);
  const envelope = Buffer.from(privateDecrypt({ key: privateKey,
    padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: 'sha256' }, Buffer.from(k, 'base64')).toString('utf8'), 'base64');
  const data = Buffer.from(d, 'base64');
  const decipher = createDecipheriv('aes-256-gcm', envelope.subarray(1, 33), envelope.subarray(33));
  decipher.setAuthTag(data.subarray(data.length - 16));
  return Buffer.concat([decipher.update(data.subarray(0, data.length - 16)), decipher.final()]).toString('utf8');
}
async function legacySession(f, account, privateKey) {
  const challenge = await f.request('/api/v2/session/legacy-challenge', { account });
  assert.equal(challenge.response.status, 200, JSON.stringify(challenge.result));
  const operation = await hash(JSON.stringify(['legacy-session', null]));
  const proof = signText(requestText(account, 'primary', challenge.result.nonce, operation), privateKey);
  const reply = await f.request('/api/v2/session/legacy', { account, nonce: challenge.result.nonce, proof });
  assert.equal(reply.response.status, 200, JSON.stringify(reply.result));
  return reply.response.headers.getSetCookie().find(s => s.startsWith('shade-alpha=')).split(';')[0];
}
async function primaryOp(f, account, privateKey, cookie, op, body = null) {
  const operation = await hash(JSON.stringify([op, op === 'send' ? await hash(messageText(body)) : body]));
  const challenge = await f.request('/api/v2/challenge', { account, id: 'primary', operation }, cookie);
  assert.equal(challenge.response.status, 200, JSON.stringify(challenge.result));
  const nonce = challenge.result.nonce;
  return f.request('/api/v2/operation', { op, body,
    auth: { account, id: 'primary', nonce, proof: signText(requestText(account, 'primary', nonce, operation), privateKey) } }, cookie);
}
function newIdentity() {
  const pair = generateKeyPairSync('rsa', { modulusLength: 4096 });
  const pem = pair.publicKey.export({ type: 'spki', format: 'pem' }).toString();
  return { ...pair, pem, root: legacyRoot(pem) };
}
async function rotationPayload(account, oldKey, fresh, nonce, oldRootFingerprint, { signWith = null, genesisOverride = null } = {}) {
  const recovery = await c.createRecoveryBackup(account, fresh.root, PHRASE);
  const now = Date.now();
  const genesis = genesisOverride || { version: 2, account, nonce: randomBytes(32).toString('hex'), createdAt: now,
    legacy: true, firstDevice: { id: 'primary', encryptionKey: fresh.root, signingKey: fresh.root },
    recoveryKey: recovery.publicKey, signature: '' };
  if (!genesisOverride) genesis.signature = signText(genesisText(genesis), fresh.privateKey);
  const manifest = { account, rootFingerprint: await fingerprint(fresh.root), revision: 1, previous: '',
    issuedAt: now, expiresAt: now + 86400000, devices: [genesis.firstDevice], signer: 'primary', signature: '' };
  manifest.signature = signText(manifestText(manifest), fresh.privateKey);
  const attestation = { version: 1, account, oldRootFingerprint, newRoot: fresh.root,
    genesisDigest: await hash(genesisText(genesis)), manifestDigest: await hash(manifestText(manifest)),
    createdAt: now, nonce, signature: 'AA==' };
  attestation.signature = signText(rotationText(attestation), signWith || oldKey);
  return { genesis, manifest, attestation };
}
async function enrollDirect(f, account, privateKey, cookie) {
  const root = legacyRoot(createPublicKey(privateKey).export({ type: 'spki', format: 'pem' }));
  const recovery = await c.createRecoveryBackup(account, root, PHRASE);
  const now = Date.now();
  const genesis = { version: 2, account, nonce: randomBytes(32).toString('hex'), createdAt: now,
    legacy: true, firstDevice: { id: 'primary', encryptionKey: root, signingKey: root },
    recoveryKey: recovery.publicKey, signature: '' };
  genesis.signature = signText(genesisText(genesis), privateKey);
  const manifest = { account, rootFingerprint: await fingerprint(root), revision: 1, previous: '',
    issuedAt: now, expiresAt: now + 86400000, devices: [genesis.firstDevice], signer: 'primary', signature: '' };
  manifest.signature = signText(manifestText(manifest), privateKey);
  const reply = await f.request('/api/v2/legacy-enrollment', { genesis, manifest }, cookie);
  assert.equal(reply.response.status, 200, JSON.stringify(reply.result));
  return { root, genesis, manifest };
}

test('CLI: rotation-required accounts are prepared honestly, verify passes before and after rotation', { timeout: 240000 }, async () => {
  const sourceDir = await tempDir('rot-src-');
  const targetDir = path.join(await tempDir('rot-dst-'), 'store');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const env = { ALPHA_STORAGE_SECRET: targetSecret };
  await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'rot_alice', bits: 2048, profile: { displayName: 'Alice', avatarFrame: 'silver', avatarRevision: 1, inventory: [], wall: [], revision: 1 } },
    { account: 'rot_bob' },
    { account: 'rot_tiny', bits: 1024 },
  ], messages: [{ to: 'rot_alice', from: 'rot_bob', id: randomBytes(16).toString('hex'), text: 'old-key ciphertext' }] });

  const audit = cli(['audit', '--source', sourceDir]);
  assert.equal(audit.counts.rotationEligible, 1);
  assert.deepEqual(audit.rotationRequired, ['rot_alice']);
  assert.deepEqual(audit.ineligible.unsupported_key_size, ['rot_tiny']);

  const prepared = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], env);
  const by = Object.fromEntries(prepared.results.map(r => [r.account, r]));
  assert.equal(by.rot_alice.status, 'rotation_required');
  assert.equal(by.rot_alice.imported, 1, 'old-key queue imported for later local decryption');
  assert.equal(by.rot_bob.status, 'prepared');
  assert.equal(by.rot_tiny, undefined);

  const status = cli(['status', '--target', targetDir, '--source', sourceDir], env);
  assert.equal(status.accounts.rot_alice.status, 'rotation_required');
  assert.equal(status.accounts.rot_alice.inboxPending, 1);
  const verified = cli(['verify', '--source', sourceDir, '--target', targetDir], env);
  assert.equal(verified.ok, true, JSON.stringify(verified.problems));
  assert.equal(verified.counts.rotationRequired, 1);

  // Idempotent re-run.
  const again = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], env);
  assert.ok(again.results.every(r => r.alreadyPresent && r.imported === 0));
});

test('rotation enrollment: old-key proof, digest binding, new-root anchor, bridge, session, resume, negatives', { timeout: 300000 }, async () => {
  const sourceDir = await tempDir('rot-e2e-src-');
  const targetDir = path.join(await tempDir('rot-e2e-dst-'), 'store');
  const guardFile = path.join(await tempDir('rot-guard-'), 'guard.json');
  const bridgeAckFile = path.join(await tempDir('rot-bridge-'), 'bridge-ack.json');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const msgId = randomBytes(16).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'rot_alice', bits: 2048, profile: { displayName: 'Alice', avatarFrame: 'graphite', avatarRevision: 2, inventory: [], wall: [], revision: 2 } },
    { account: 'rot_bob' },
  ], messages: [{ to: 'rot_alice', from: 'rot_bob', id: msgId, text: 'сообщение старому ключу' }] });
  const aliceOld = keys.get('rot_alice'), bob = keys.get('rot_bob');
  cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], { ALPHA_STORAGE_SECRET: targetSecret });
  const f = await fixture({ dataDir: targetDir, storageSecret: targetSecret,
    legacySource: { dataDir: sourceDir }, guardFile, bridgeAckFile });
  try {
    // 4096 accounts do not need rotation; unknown accounts are rejected.
    assert.equal((await f.request('/api/v2/session/rotation-challenge', { account: 'rot_bob' })).response.status, 400);
    assert.equal((await f.request('/api/v2/session/rotation-challenge', { account: 'rot_nobody' })).response.status, 400);

    const challenge = await f.request('/api/v2/session/rotation-challenge', { account: 'rot_alice' });
    assert.equal(challenge.response.status, 200, JSON.stringify(challenge.result));
    const { nonce, oldRootFingerprint } = challenge.result;
    const fresh = newIdentity();

    // Negative: attestation signed by a FOREIGN key.
    const attacker = newIdentity();
    const forged = await rotationPayload('rot_alice', aliceOld.privateKey, fresh, nonce, oldRootFingerprint, { signWith: attacker.privateKey });
    assert.equal((await f.request('/api/v2/legacy-rotation', { account: 'rot_alice', nonce, ...forged })).response.status, 400);
    // Negative: replayed nonce (consumed even on failure).
    const good = await rotationPayload('rot_alice', aliceOld.privateKey, fresh, nonce, oldRootFingerprint);
    assert.equal((await f.request('/api/v2/legacy-rotation', { account: 'rot_alice', nonce, ...good })).response.status, 400);

    // Fresh challenge; negative: digest binding (attestation over another genesis).
    const c2 = await f.request('/api/v2/session/rotation-challenge', { account: 'rot_alice' });
    const otherGenesis = await rotationPayload('rot_alice', aliceOld.privateKey, newIdentity(), c2.result.nonce, oldRootFingerprint);
    const mismatched = await rotationPayload('rot_alice', aliceOld.privateKey, fresh, c2.result.nonce, oldRootFingerprint);
    mismatched.attestation.genesisDigest = otherGenesis.attestation.genesisDigest;
    mismatched.attestation.signature = 'AA==';
    mismatched.attestation.signature = signText(rotationText(mismatched.attestation), aliceOld.privateKey);
    assert.equal((await f.request('/api/v2/legacy-rotation', { account: 'rot_alice', nonce: c2.result.nonce, ...mismatched })).response.status, 400);

    // Fresh challenge; negative: NEW root is RSA-2048 (v2 anchor must be 4096).
    const c3 = await f.request('/api/v2/session/rotation-challenge', { account: 'rot_alice' });
    const weak = generateKeyPairSync('rsa', { modulusLength: 2048 });
    const weakRoot = legacyRoot(weak.publicKey.export({ type: 'spki', format: 'pem' }).toString());
    const weakPayload = await rotationPayload('rot_alice', aliceOld.privateKey,
      { ...weak, root: weakRoot }, c3.result.nonce, oldRootFingerprint);
    assert.equal((await f.request('/api/v2/legacy-rotation', { account: 'rot_alice', nonce: c3.result.nonce, ...weakPayload })).response.status, 400);

    // Successful rotation with a fresh challenge.
    const c4 = await f.request('/api/v2/session/rotation-challenge', { account: 'rot_alice' });
    const payload = await rotationPayload('rot_alice', aliceOld.privateKey, fresh, c4.result.nonce, oldRootFingerprint);
    const enrolled = await f.request('/api/v2/legacy-rotation', { account: 'rot_alice', nonce: c4.result.nonce, ...payload });
    assert.equal(enrolled.response.status, 200, JSON.stringify(enrolled.result));
    assert.equal(enrolled.result.revision, 1);

    // Anchor is the NEW root; attestation is published for contact verification.
    const dir = f.registry.directory('rot_alice');
    assert.equal(dir.root, fresh.root);
    assert.equal(dir.rotation.oldRootFingerprint, oldRootFingerprint);
    assert.equal(dir.rotation.attestation.newRoot, fresh.root);
    // Guard exported; profile ownership rebound to the NEW root atomically.
    const guard = JSON.parse(await fs.readFile(guardFile, 'utf8'));
    assert.ok(guard.accounts.rot_alice);
    const stickers = f.registry.exportSnapshot().stickers.rot_alice;
    assert.equal(stickers.avatarOwner, createHash('sha256').update(fresh.root).digest('hex'));
    assert.equal(stickers.displayName, 'Alice');

    // Idempotent resume: a NEW attestation (fresh nonce) over the SAME genesis.
    const c5 = await f.request('/api/v2/session/rotation-challenge', { account: 'rot_alice' });
    assert.equal(c5.response.status, 409, 'already enrolled account cannot rotate again');
    // Resume path via the enrollment endpoint itself (crash after commit):
    // re-use the committed genesis with a legacy-session of the NEW key.
    const ac = await legacySession(f, 'rot_alice', fresh.privateKey);
    const resume = await f.request('/api/v2/legacy-enrollment', { genesis: payload.genesis, manifest: payload.manifest }, ac);
    assert.equal(resume.response.status, 200, JSON.stringify(resume.result));
    assert.equal(resume.result.resumed, true);

    // Old-key ciphertext drains through the bridge and opens ONLY with the
    // OLD private key (which stayed on the device).
    const inbox = await primaryOp(f, 'rot_alice', fresh.privateKey, ac, 'legacy.inbox');
    assert.equal(inbox.result.length, 1);
    assert.equal(openV1Payload(inbox.result[0].data, aliceOld.privateKey), 'сообщение старому ключу');
    assert.throws(() => openV1Payload(inbox.result[0].data, fresh.privateKey));
    const acked = await primaryOp(f, 'rot_alice', fresh.privateKey, ac, 'legacy.ack', [`rot_bob:${msgId}`]);
    assert.equal(acked.result.acknowledged, 1);
    const bridgeAck = JSON.parse(await fs.readFile(bridgeAckFile, 'utf8'));
    assert.ok(bridgeAck.accounts.rot_alice.acked.includes(`rot_bob:${msgId}`));

    // verify re-checks the attestation chain against the read-only source.
    await f.close();
    const verified = cli(['verify', '--source', sourceDir, '--target', targetDir], { ALPHA_STORAGE_SECRET: targetSecret });
    assert.equal(verified.ok, true, JSON.stringify(verified.problems));
    assert.equal(verified.counts.enrolled, 1, 'rot_alice rotated; rot_bob still prepared');
    assert.equal(verified.counts.prepared, 1);
  } finally { await f.close().catch(() => {}); }
});