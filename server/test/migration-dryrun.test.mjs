// Staging-style migration dry-run matrix on synthetic v1 data (task §9):
// empty accounts, bulk history beyond the inbox cap, RSA-2048 vs RSA-4096,
// multi-device, revoked devices, failed enrollment, crash-safe re-runs and
// graceful stop/resume. Integration tests: real CLI, real alpha server, real
// v1 storage format. No production data is touched.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomBytes, generateKeyPairSync, sign as nodeSign, createPublicKey, constants } from 'node:crypto';
import { fixture } from './helpers/alpha-fixture.mjs';
import { buildV1Fixture } from './helpers/v1-fixture.mjs';
import { alphaStore } from '../multidevice/alpha-store.mjs';
import { legacyRoot } from '../multidevice/registry.mjs';
import { genesisText, manifestText, messageText, requestText, hash, fingerprint, sign } from '../../client/web/protocol/device-v2.mjs';
import * as c from '../../client/web/device_crypto.mjs';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(serverRoot, 'tools', 'migrate-v1-to-v2.mjs');
const PHRASE = 'synthetic dry-run recovery phrase only';

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
async function enrollmentPayload(account, privateKey, { createdAt = Date.now(), signerKey = null } = {}) {
  const root = legacyRoot(createPublicKey(privateKey).export({ type: 'spki', format: 'pem' }));
  const recovery = await c.createRecoveryBackup(account, root, PHRASE);
  const genesis = { version: 2, account, nonce: randomBytes(32).toString('hex'), createdAt,
    legacy: true, firstDevice: { id: 'primary', encryptionKey: root, signingKey: root },
    recoveryKey: recovery.publicKey, signature: '' };
  genesis.signature = signText(genesisText(genesis), signerKey || privateKey);
  const manifest = { account, rootFingerprint: await fingerprint(root), revision: 1, previous: '',
    issuedAt: createdAt, expiresAt: createdAt + 86400000, devices: [genesis.firstDevice], signer: 'primary', signature: '' };
  manifest.signature = signText(manifestText(manifest), signerKey || privateKey);
  return { genesis, manifest, root, recovery };
}

test('dry-run matrix: empty/bulk/weak/multi accounts, cap truncation, idempotent re-run, stop/resume', { timeout: 240000 }, async () => {
  const sourceDir = await tempDir('dry-src-');
  const targetDir = path.join(await tempDir('dry-dst-'), 'store');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const env = { ALPHA_STORAGE_SECRET: targetSecret };
  const messages = [];
  for (let i = 0; i < 250; i++) {
    messages.push({ to: 'dry_bulk', from: 'dry_empty', id: randomBytes(16).toString('hex'), text: `bulk message ${i}` });
  }
  await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'dry_empty' },
    { account: 'dry_bulk' },
    { account: 'dry_weak', bits: 2048 },
    { account: 'dry_multi', googleSub: 'synthetic-multi' },
    { account: 'dry_nokey', noKey: true },
  ], messages });

  const audit = cli(['audit', '--source', sourceDir]);
  assert.equal(audit.counts.users, 5);
  assert.equal(audit.counts.eligible, 3);
  assert.equal(audit.counts.queuedMessages, 250);
  assert.deepEqual(audit.rotationRequired, ['dry_weak']);
  assert.equal(audit.ineligible.unsupported_key_size, undefined);
  assert.deepEqual(audit.ineligible.missing_public_key, ['dry_nokey']);

  const prepared = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], env);
  const by = Object.fromEntries(prepared.results.map(r => [r.account, r]));
  assert.equal(by.dry_empty.status, 'prepared');
  assert.equal(by.dry_empty.imported, 0);
  assert.equal(by.dry_bulk.status, 'prepared');
  assert.equal(by.dry_bulk.imported, 200, 'inbox capped at 200 entries');
  assert.equal(by.dry_multi.status, 'prepared');
  assert.equal(by.dry_weak.status, 'rotation_required', 'RSA-2048 requires explicit rotation');
  assert.equal(by.dry_nokey, undefined);

  // Truncation is recorded honestly, not silently.
  const store = await alphaStore(targetDir, targetSecret);
  const snap = await store.load(); await store.close();
  assert.equal(snap.legacyInbox.dry_bulk.length, 200);
  assert.equal(snap.migration.accounts.dry_bulk.inboxTruncated, true);
  assert.equal((snap.legacyInbox.dry_empty || []).length, 0);

  // Re-run: idempotent, no duplicates, attempts counted.
  const again = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], env);
  assert.ok(again.results.every(r => r.alreadyPresent && r.imported === 0));
  const verified = cli(['verify', '--source', sourceDir, '--target', targetDir], env);
  assert.equal(verified.ok, true, JSON.stringify(verified.problems));
  assert.equal(verified.counts.prepared, 3);
  assert.equal(verified.counts.inboxPending, 200);

  // Graceful stop halts the batch; resume continues without state damage.
  cli(['stop', '--target', targetDir]);
  const stopped = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--accounts', 'dry_multi'], env);
  assert.equal(stopped.results[0].status, 'stopped');
  cli(['resume', '--target', targetDir]);
  const resumed = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--accounts', 'dry_multi'], env);
  assert.equal(resumed.results[0].status, 'prepared');
  const finalVerify = cli(['verify', '--source', sourceDir, '--target', targetDir], env);
  assert.equal(finalVerify.ok, true);
});

test('failed enrollment never corrupts prepared state; valid enrollment still succeeds', { timeout: 240000 }, async () => {
  const sourceDir = await tempDir('dry-enroll-src-');
  const targetDir = path.join(await tempDir('dry-enroll-dst-'), 'store');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'fail_alice' }, { account: 'fail_bob' }] });
  const alice = keys.get('fail_alice');
  cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], { ALPHA_STORAGE_SECRET: targetSecret });
  const f = await fixture({ dataDir: targetDir, storageSecret: targetSecret, legacySource: { dataDir: sourceDir } });
  try {
    const ac = await legacySession(f, 'fail_alice', alice.privateKey);

    // 1. Genesis signed by a FOREIGN key (possession proof must fail).
    const attacker = generateKeyPairSync('rsa', { modulusLength: 4096 });
    const forged = await enrollmentPayload('fail_alice', alice.privateKey, { signerKey: attacker.privateKey });
    const r1 = await f.request('/api/v2/legacy-enrollment', { genesis: forged.genesis, manifest: forged.manifest }, ac);
    assert.equal(r1.response.status, 400);

    // 2. Stale enrollment window.
    const stale = await enrollmentPayload('fail_alice', alice.privateKey, { createdAt: Date.now() - 400000 });
    const r2 = await f.request('/api/v2/legacy-enrollment', { genesis: stale.genesis, manifest: stale.manifest }, ac);
    assert.equal(r2.response.status, 409); // 'Stale' maps to 409; error text is sanitized

    // 3. Genesis for a DIFFERENT account than the session.
    const other = await enrollmentPayload('fail_bob', keys.get('fail_bob').privateKey);
    const r3 = await f.request('/api/v2/legacy-enrollment', { genesis: other.genesis, manifest: other.manifest }, ac);
    assert.equal(r3.response.status, 400);

    // 4. Unprepared account cannot even get a legacy challenge.
    const r4 = await f.request('/api/v2/session/legacy-challenge', { account: 'fail_unknown' });
    assert.equal(r4.response.status, 400);

    // State is still clean: no genesis, no directory, prepared status intact.
    const dir = f.registry.directory('fail_alice');
    assert.equal(dir.history.length, 0);
    assert.equal(dir.genesis, null);

    // 5. The legitimate enrollment succeeds after all failed attempts.
    const good = await enrollmentPayload('fail_alice', alice.privateKey);
    const r5 = await f.request('/api/v2/legacy-enrollment', { genesis: good.genesis, manifest: good.manifest }, ac);
    assert.equal(r5.response.status, 200, JSON.stringify(r5.result));
    assert.equal(r5.result.revision, 1);
    // Idempotent resume with the same genesis.
    const r6 = await f.request('/api/v2/legacy-enrollment', { genesis: good.genesis, manifest: good.manifest }, ac);
    assert.equal(r6.result.resumed, true);
  } finally { await f.close().catch(() => {}); }
});

test('revoked device after enrollment: queues purged, tombstone kept, legacy inbox unaffected', { timeout: 240000 }, async () => {
  const sourceDir = await tempDir('dry-revoke-src-');
  const targetDir = path.join(await tempDir('dry-revoke-dst-'), 'store');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'rev_alice' }, { account: 'rev_bob' }],
    messages: [{ to: 'rev_alice', from: 'rev_bob', id: randomBytes(16).toString('hex'), text: 'legacy pending' }] });
  const alice = keys.get('rev_alice'), bob = keys.get('rev_bob');
  cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], { ALPHA_STORAGE_SECRET: targetSecret });
  const f = await fixture({ dataDir: targetDir, storageSecret: targetSecret, legacySource: { dataDir: sourceDir } });
  try {
    const ac = await legacySession(f, 'rev_alice', alice.privateKey);
    const enrolled = await enrollmentPayload('rev_alice', alice.privateKey);
    assert.equal((await f.request('/api/v2/legacy-enrollment', { genesis: enrolled.genesis, manifest: enrolled.manifest }, ac)).response.status, 200);
    const bc = await legacySession(f, 'rev_bob', bob.privateKey);
    const enrolledBob = await enrollmentPayload('rev_bob', bob.privateKey);
    assert.equal((await f.request('/api/v2/legacy-enrollment', { genesis: enrolledBob.genesis, manifest: enrolledBob.manifest }, bc)).response.status, 200);

    // Pair a second device for alice.
    const vault2 = await c.createVault('rev_alice', 'synthetic revoke device passphrase');
    const session2 = await c.unlockVault(vault2, 'synthetic revoke device passphrase');
    const primarySession = await (async () => {
      const der = Buffer.from(alice.privateKey.replace(/-----[^-]+-----|\s/g, ''), 'base64');
      const signing = await crypto.subtle.importKey('pkcs8', der, { name: 'RSA-PSS', hash: 'SHA-256' }, false, ['sign']);
      return { account: 'rev_alice', id: 'primary', signing };
    })();
    const manifest2 = await c.approveDevices(enrolled.genesis, [enrolled.manifest],
      [...enrolled.manifest.devices, c.descriptor(vault2)], primarySession);
    const installed = await primaryOp(f, 'rev_alice', alice.privateKey, ac, 'install',
      { manifest: manifest2, proofs: [await c.pairingProof(vault2, session2)] });
    assert.equal(installed.response.status, 200, JSON.stringify(installed.result));
    const secondId = c.descriptor(vault2).id;

    // bob sends a v2 message: fanout reaches both alice devices.
    const bobSession = await (async () => {
      const der = Buffer.from(bob.privateKey.replace(/-----[^-]+-----|\s/g, ''), 'base64');
      const signing = await crypto.subtle.importKey('pkcs8', der, { name: 'RSA-PSS', hash: 'SHA-256' }, false, ['sign']);
      const encryption = await crypto.subtle.importKey('pkcs8', der, { name: 'RSA-OAEP', hash: 'SHA-256' }, false, ['decrypt']);
      return { account: 'rev_bob', id: 'primary', signing, encryption };
    })();
    const text = 'message before revocation';
    const message = await c.sealMessage(text, [enrolledBob.manifest], [enrolled.manifest, manifest2], bobSession,
      { senderRoot: enrolledBob.root, recipientRoot: enrolled.root,
        senderGenesis: enrolledBob.genesis, recipientGenesis: enrolled.genesis });
    const sent = await primaryOp(f, 'rev_bob', bob.privateKey, bc, 'send', message);
    assert.equal(sent.result.accepted, true);
    assert.ok(f.registry.exportSnapshot().queues[`rev_alice:${secondId}`]?.length === 1);

    // Revoke the second device (manifest without it).
    const manifest3 = await c.approveDevices(enrolled.genesis, [enrolled.manifest, manifest2],
      [{ id: 'primary', encryptionKey: enrolled.root, signingKey: enrolled.root }], primarySession);
    const revoked = await primaryOp(f, 'rev_alice', alice.privateKey, ac, 'install', { manifest: manifest3, proofs: [] });
    assert.equal(revoked.response.status, 200, JSON.stringify(revoked.result));
    const snap = f.registry.exportSnapshot();
    assert.ok(!snap.queues[`rev_alice:${secondId}`]?.length, 'revoked device queue purged');
    assert.ok(snap.accounts.rev_alice.retired.includes(secondId), 'revocation tombstone kept');
    // The revoked device cannot authenticate anymore.
    const operation = await hash(JSON.stringify(['fetch', null]));
    const challenge = await f.request('/api/v2/challenge', { account: 'rev_alice', id: secondId, operation }, ac);
    assert.equal(challenge.response.status, 400);
    // Legacy inbox bridge is independent of device revocation.
    const inbox = await primaryOp(f, 'rev_alice', alice.privateKey, ac, 'legacy.inbox');
    assert.equal(inbox.result.length, 1);
    // Primary device still receives new messages.
    const message2 = await c.sealMessage('after revocation', [enrolledBob.manifest], [enrolled.manifest, manifest2, manifest3], bobSession,
      { senderRoot: enrolledBob.root, recipientRoot: enrolled.root,
        senderGenesis: enrolledBob.genesis, recipientGenesis: enrolled.genesis });
    assert.equal((await primaryOp(f, 'rev_bob', bob.privateKey, bc, 'send', message2)).result.accepted, true);
    const fetched = await primaryOp(f, 'rev_alice', alice.privateKey, ac, 'fetch');
    assert.ok(fetched.result.some(b => b.message.id === message2.id));
  } finally { await f.close().catch(() => {}); }
});