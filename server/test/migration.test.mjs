// v1 -> v2 migration integration tests. SYNTHETIC data only: temporary v1
// fixtures in the v1 at-rest format, isolated alpha stores, loopback servers.
// Production data/VPS are never touched. Covers: idempotent prepare, per-user
// failure isolation, dry-run, queue bridge without server-side decryption,
// crash-safe enrollment resume, multi-device, restart persistence, rollback
// limits, integrity verification, stop flag and the opt-in v1 guard.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync, spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomBytes, generateKeyPairSync, createPublicKey, privateDecrypt,
  createDecipheriv, constants, sign as nodeSign } from 'node:crypto';
import { io } from 'socket.io-client';
import { fixture, freePort } from './helpers/alpha-fixture.mjs';
import { buildV1Fixture, writeV1Queue, v1Seal } from './helpers/v1-fixture.mjs';
import { alphaStore } from '../multidevice/alpha-store.mjs';
import { createDeviceRegistry, legacyRoot } from '../multidevice/registry.mjs';
import { createMigration } from '../multidevice/migration.mjs';
import { openV1Source } from '../multidevice/v1-source.mjs';
import { genesisText, manifestText, messageText, requestText, hash, fingerprint, sign } from '../../client/web/protocol/device-v2.mjs';
import * as c from '../../client/web/device_crypto.mjs';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(serverRoot, 'tools', 'migrate-v1-to-v2.mjs');
const PHRASE = 'synthetic migration recovery phrase only';

async function tempDir(prefix) {
  const build = path.join(serverRoot, 'build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, prefix));
}
function cli(args, env = {}) {
  const stdout = execFileSync(process.execPath, [CLI, ...args], {
    cwd: serverRoot, env: { ...process.env, ...env }, encoding: 'utf8' });
  return JSON.parse(stdout);
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
  assert.equal(challenge.response.status, 200);
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
async function enroll(f, account, privateKey, cookie) {
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
  return { root, genesis, manifest, recovery };
}
// WebCrypto session for the legacy primary key (same RSA, two algorithm views).
async function primaryWebSession(account, privateKeyPem) {
  const der = Buffer.from(privateKeyPem.replace(/-----[^-]+-----|\s/g, ''), 'base64');
  const signing = await crypto.subtle.importKey('pkcs8', der, { name: 'RSA-PSS', hash: 'SHA-256' }, false, ['sign']);
  const encryption = await crypto.subtle.importKey('pkcs8', der, { name: 'RSA-OAEP', hash: 'SHA-256' }, false, ['decrypt']);
  return { account, id: 'primary', signing, encryption };
}

test('CLI audit + dry-run + idempotent prepare + failure isolation + stop + rollback', { timeout: 240000 }, async () => {
  const sourceDir = await tempDir('mig-src-');
  const targetDir = path.join(await tempDir('mig-dst-'), 'store');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'mig_alice', googleSub: 'synthetic-alice', profile: { displayName: 'Alice', avatarFrame: 'silver', avatarRevision: 3, inventory: [], wall: [], revision: 2 } },
    { account: 'mig_bob' },
    { account: 'mig_weak', bits: 2048 },
    { account: 'mig_nokey', noKey: true },
  ], messages: [
    { to: 'mig_alice', from: 'mig_bob', id: randomBytes(16).toString('hex'), text: 'старое сообщение 1' },
    { to: 'mig_alice', from: 'mig_bob', id: randomBytes(16).toString('hex'), text: 'старое сообщение 2' },
  ] });

  const audit = cli(['audit', '--source', sourceDir]);
  assert.equal(audit.counts.users, 4);
  assert.equal(audit.counts.eligible, 2);
  // RSA-2048 теперь классифицируется как rotation_required (явная смена ключа).
  assert.deepEqual(audit.rotationRequired, ['mig_weak']);
  assert.equal(audit.ineligible.unsupported_key_size, undefined);
  assert.deepEqual(audit.ineligible.missing_public_key, ['mig_nokey']);
  assert.equal(audit.counts.queuedMessages, 2);

  // Dry-run must not create the target store at all.
  const dry = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all', '--dry-run'],
    { ALPHA_STORAGE_SECRET: targetSecret });
  assert.equal(dry.dryRun, true);
  assert.equal(dry.results.filter(r => r.status === 'prepared').length, 2);
  await assert.rejects(fs.access(targetDir));

  const prepared = cli(['prepare', '--source', sourceDir, '--target', targetDir,
    '--accounts', 'mig_alice,mig_bob,mig_weak,mig_nokey'], { ALPHA_STORAGE_SECRET: targetSecret });
  const byAccount = Object.fromEntries(prepared.results.map(r => [r.account, r]));
  assert.equal(byAccount.mig_alice.status, 'prepared');
  assert.equal(byAccount.mig_alice.imported, 2);
  assert.equal(byAccount.mig_bob.status, 'prepared');
  assert.equal(byAccount.mig_weak.status, 'rotation_required');
  assert.equal(byAccount.mig_nokey.error, 'missing_public_key');

  // Idempotent repeat: no duplicate accounts or inbox entries.
  const again = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--accounts', 'mig_alice,mig_bob'],
    { ALPHA_STORAGE_SECRET: targetSecret });
  assert.ok(again.results.every(r => r.alreadyPresent && r.imported === 0));
  const status = cli(['status', '--target', targetDir, '--source', sourceDir], { ALPHA_STORAGE_SECRET: targetSecret });
  assert.equal(Object.keys(status.accounts).length, 3);
  assert.equal(status.accounts.mig_alice.inboxPending, 2);
  assert.equal(status.accounts.mig_alice.attempts, 2);
  assert.equal(status.accounts.mig_weak.status, 'rotation_required');

  // Root substitution is refused without touching the stored account.
  const tamperedDir = await tempDir('mig-tamper-');
  await buildV1Fixture(tamperedDir, { secret, users: [{ account: 'mig_alice' }] });
  const mismatch = cli(['prepare', '--source', tamperedDir, '--target', targetDir, '--accounts', 'mig_alice'],
    { ALPHA_STORAGE_SECRET: targetSecret });
  assert.equal(mismatch.results[0].error, 'root_mismatch');
  // Restore the prepared state from the genuine source (idempotent recovery).
  const restored = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--accounts', 'mig_alice'],
    { ALPHA_STORAGE_SECRET: targetSecret });
  assert.equal(restored.results[0].status, 'prepared');

  // Integrity verification passes on the clean state.
  const verified = cli(['verify', '--source', sourceDir, '--target', targetDir], { ALPHA_STORAGE_SECRET: targetSecret });
  assert.equal(verified.ok, true);
  assert.equal(verified.counts.prepared, 2);

  // Cooperative stop flag halts before processing accounts.
  cli(['stop', '--target', targetDir]);
  const stopped = cli(['prepare', '--source', sourceDir, '--target', targetDir, '--accounts', 'mig_bob'],
    { ALPHA_STORAGE_SECRET: targetSecret });
  assert.equal(stopped.results[0].status, 'stopped');
  cli(['resume', '--target', targetDir]);

  // Rollback removes prepared accounts and keeps a verified backup.
  const rolled = cli(['rollback', '--target', targetDir, '--accounts', 'mig_bob', '--confirm'],
    { ALPHA_STORAGE_SECRET: targetSecret });
  assert.deepEqual(rolled.removed, ['mig_bob']);
  const backup = JSON.parse(await fs.readFile(rolled.backup, 'utf8'));
  assert.ok(backup.data && backup.nonce && backup.tag);
  const afterRollback = cli(['status', '--target', targetDir], { ALPHA_STORAGE_SECRET: targetSecret });
  assert.equal(Object.keys(afterRollback.accounts).length, 2);

  // Engine-level: persistence failure aborts without visible state change.
  const store = await alphaStore(targetDir, targetSecret);
  try {
    const snapshot = await store.load();
    const source = await openV1Source(sourceDir, { secret });
    const users = new Map([...source.users].filter(([a]) => snapshot.accounts[a]));
    let failNext = true;
    const registry = await createDeviceRegistry({ users, snapshot,
      persist: async s => { if (failNext) { failNext = false; return false; } return store.save(s); } });
    const migration = createMigration({ registry, source });
    const results = await migration.prepare({ accounts: ['mig_alice'] });
    assert.equal(results[0].status, 'failed');
    assert.equal(results[0].error, 'prepare_failed');
    const unchanged = registry.exportSnapshot();
    // The failed transaction never committed account/inbox changes; only the
    // failure audit record (a separate, successful transaction) is visible.
    assert.equal(unchanged.migration.accounts.mig_alice.lastError, 'prepare_failed');
    assert.equal(unchanged.legacyInbox.mig_alice.length, 2);
    assert.equal(unchanged.accounts.mig_alice.history.length, 0);
  } finally { await store.close(); }
  void keys;
});

test('alpha bridge: legacy-key enrollment, E2EE queue drain, race top-up, restart, multi-device, guard', { timeout: 300000 }, async () => {
  const sourceDir = await tempDir('mig-e2e-src-');
  const targetDir = path.join(await tempDir('mig-e2e-dst-'), 'store');
  const guardFile = path.join(await tempDir('mig-guard-'), 'guard.json');
  const bridgeAckFile = path.join(await tempDir('mig-bridge-'), 'bridge-ack.json');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const msg1 = randomBytes(16).toString('hex'), msg2 = randomBytes(16).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'e2e_alice', profile: { displayName: 'Alice', avatarFrame: 'graphite', avatarRevision: 1, inventory: [], wall: [], revision: 1 } },
    { account: 'e2e_bob', googleSub: 'synthetic-bob' },
    { account: 'e2e_carol' },
  ], messages: [
    { to: 'e2e_alice', from: 'e2e_bob', id: msg1, text: 'v1 очередь: сообщение до миграции' },
  ] });
  const alice = keys.get('e2e_alice'), bob = keys.get('e2e_bob');

  cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], { ALPHA_STORAGE_SECRET: targetSecret });
  let f = await fixture({ dataDir: targetDir, storageSecret: targetSecret,
    legacySource: { dataDir: sourceDir }, guardFile, bridgeAckFile });
  try {
    assert.equal((await f.request('/api/health')).result.legacyBridge, true);

    // Nickname-only account migrates WITHOUT Google: possession of the original
    // RSA is the ownership proof (same model as v1 /register).
    const ac = await legacySession(f, 'e2e_alice', alice.privateKey);
    const sessionInfo = await f.request('/api/session', undefined, ac);
    assert.equal(sessionInfo.result.account, 'e2e_alice');
    const enrolledAlice = await enroll(f, 'e2e_alice', alice.privateKey, ac);
    assert.equal(enrolledAlice.manifest.revision, 1);

    // Guard export happened at enrollment.
    const guard = JSON.parse(await fs.readFile(guardFile, 'utf8'));
    assert.ok(guard.accounts.e2e_alice);

    // Crash-safe resume: the SAME genesis returns the committed tip.
    const replay = await f.request('/api/v2/legacy-enrollment',
      { genesis: enrolledAlice.genesis, manifest: enrolledAlice.manifest }, ac);
    assert.equal(replay.response.status, 200);
    assert.equal(replay.result.resumed, true);
    assert.equal(replay.result.revision, 1);

    // Pending v1 queue arrived as ciphertext; decryptable ONLY with the legacy
    // private key (which stayed on the "device"). Server never saw plaintext.
    const inbox = await primaryOp(f, 'e2e_alice', alice.privateKey, ac, 'legacy.inbox');
    assert.equal(inbox.response.status, 200);
    assert.equal(inbox.result.length, 1);
    assert.equal(inbox.result[0].id, msg1);
    assert.equal(openV1Payload(inbox.result[0].data, alice.privateKey), 'v1 очередь: сообщение до миграции');
    assert.ok(!JSON.stringify(f.registry.exportSnapshot()).includes('v1 очередь'));
    const acked = await primaryOp(f, 'e2e_alice', alice.privateKey, ac, 'legacy.ack', [`e2e_bob:${msg1}`]);
    assert.equal(acked.result.acknowledged, 1);
    // Bridge-ack export: the v1 server can prune confirmed ciphertext.
    const bridgeAck = JSON.parse(await fs.readFile(bridgeAckFile, 'utf8'));
    assert.ok(bridgeAck.accounts.e2e_alice.acked.includes(`e2e_bob:${msg1}`));

    // Race: a v1 message enqueued between prepare and the guard activating is
    // picked up by the next inbox sync; acked ones never return.
    const msgLate = randomBytes(16).toString('hex');
    await writeV1Queue(sourceDir, secret, new Map([['e2e_alice', [
      { id: msg1, from: 'e2e_bob', timestamp: Date.now(), data: v1Seal('дубль', alice.publicKey) },
      { id: msgLate, from: 'e2e_bob', timestamp: Date.now(), data: v1Seal('позднее сообщение', alice.publicKey) },
    ]]]));
    const topUp = await primaryOp(f, 'e2e_alice', alice.privateKey, ac, 'legacy.inbox');
    assert.equal(topUp.result.length, 1);
    assert.equal(topUp.result[0].id, msgLate);
    assert.equal(openV1Payload(topUp.result[0].data, alice.privateKey), 'позднее сообщение');

    // v1 profile migrated with ownership rebound to the immutable v2 root.
    const stickers = f.registry.exportSnapshot().stickers.e2e_alice;
    assert.equal(stickers.displayName, 'Alice');
    assert.equal(stickers.avatarFrame, 'graphite');

    // Restart: snapshot + ack tombstones survive; no re-migration.
    await f.close();
    f = await fixture({ dataDir: targetDir, storageSecret: targetSecret,
      legacySource: { dataDir: sourceDir }, guardFile, bridgeAckFile });
    const ac2 = await legacySession(f, 'e2e_alice', alice.privateKey);
    const afterRestart = await primaryOp(f, 'e2e_alice', alice.privateKey, ac2, 'legacy.inbox');
    assert.equal(afterRestart.result.length, 1, 'unacked bridge message survives restart');
    assert.equal(afterRestart.result[0].id, msgLate);
    await primaryOp(f, 'e2e_alice', alice.privateKey, ac2, 'legacy.ack', [`e2e_bob:${msgLate}`]);
    const statusAfter = cli(['status', '--target', targetDir, '--source', sourceDir], { ALPHA_STORAGE_SECRET: targetSecret });
    assert.equal(statusAfter.accounts.e2e_alice.status, 'enrolled');
    assert.equal(statusAfter.accounts.e2e_alice.revision, 1);

    // Google-linked account uses the Google session path.
    const bc = await f.login('synthetic-bob');
    assert.equal((await f.request('/api/session', undefined, bc)).result.account, 'e2e_bob');
    const enrolledBob = await enroll(f, 'e2e_bob', bob.privateKey, bc);

    // Second device for alice (paired via QR-style possession proof).
    const vault2 = await c.createVault('e2e_alice', 'synthetic second device passphrase');
    const session2 = await c.unlockVault(vault2, 'synthetic second device passphrase');
    const primarySession = await primaryWebSession('e2e_alice', alice.privateKey);
    const manifest2 = await c.approveDevices(enrolledAlice.genesis, [enrolledAlice.manifest],
      [...enrolledAlice.manifest.devices, c.descriptor(vault2)], primarySession);
    const installed = await primaryOp(f, 'e2e_alice', alice.privateKey, ac2, 'install',
      { manifest: manifest2, proofs: [await c.pairingProof(vault2, session2)] });
    assert.equal(installed.response.status, 200, JSON.stringify(installed.result));
    assert.equal(installed.result.revision, 2);

    // v2 -> v2 E2EE between migrated accounts; both alice devices get fanout.
    const bobSession = await primaryWebSession('e2e_bob', bob.privateKey);
    const text = 'v2 сообщение после миграции 🔐';
    const message = await c.sealMessage(text, [enrolledAlice.manifest, manifest2], [enrolledBob.manifest],
      primarySession, { senderRoot: enrolledAlice.root, recipientRoot: enrolledBob.root,
        senderGenesis: enrolledAlice.genesis, recipientGenesis: enrolledBob.genesis });
    const sent = await primaryOp(f, 'e2e_alice', alice.privateKey, ac2, 'send', message);
    assert.equal(sent.result.accepted, true);
    const bobInbox = await primaryOp(f, 'e2e_bob', bob.privateKey, bc, 'fetch');
    const bundle = bobInbox.result.find(b => b.message.id === message.id);
    assert.ok(bundle);
    assert.equal(await c.openMessage(bundle, bobSession,
      { senderRoot: enrolledAlice.root, recipientRoot: enrolledBob.root,
        senderGenesis: enrolledAlice.genesis, recipientGenesis: enrolledBob.genesis }), text);
    // alice's second device receives and decrypts its own fanout copy.
    const op2 = async (op, body = null) => {
      const operation = await hash(JSON.stringify([op, body]));
      const challenge = await f.request('/api/v2/challenge',
        { account: 'e2e_alice', id: session2.id, operation }, ac2);
      const nonce = challenge.result.nonce;
      const proof = await sign(requestText('e2e_alice', session2.id, nonce, operation), session2.signing);
      return f.request('/api/v2/operation', { op, body,
        auth: { account: 'e2e_alice', id: session2.id, nonce, proof } }, ac2);
    };
    const secondInbox = await op2('fetch');
    const own = secondInbox.result.find(b => b.message.id === message.id);
    assert.ok(own, 'sender second device must receive fanout');
    assert.equal(await c.openMessage(own, session2,
      { senderRoot: enrolledAlice.root, recipientRoot: enrolledBob.root,
        senderGenesis: enrolledAlice.genesis, recipientGenesis: enrolledBob.genesis }), text);
    // P0: the account-scoped legacy bridge is primary-only — a secondary
    // device cannot drain/ACK ciphertext it has no key to decrypt.
    assert.equal((await op2('legacy.inbox')).response.status, 400);
    assert.equal((await op2('legacy.ack', [`e2e_bob:${msgLate}`])).response.status, 400);

    // v2→v1 (peer not enrolled): honest structured refusal, not silent loss.
    // The client keeps the ciphertext in its signed outbox and shows a notice.
    const toV1 = { ...message, to: 'e2e_carol', id: randomBytes(32).toString('hex') };
    const blockedSend = await primaryOp(f, 'e2e_alice', alice.privateKey, ac2, 'send', toV1);
    assert.equal(blockedSend.response.status, 409, JSON.stringify(blockedSend.result));
    assert.equal(blockedSend.result.error, 'peer_upgrade_required');

    // Device-session bootstrap: a paired device opens a session WITHOUT any
    // prior cookie (covers web devices of nickname-only accounts).
    const bootstrapOp = await hash(JSON.stringify(['device-session', null]));
    const bootstrapChallenge = await f.request('/api/v2/challenge',
      { account: 'e2e_alice', id: session2.id, operation: bootstrapOp });
    assert.equal(bootstrapChallenge.response.status, 200);
    const bootstrapProof = await sign(
      requestText('e2e_alice', session2.id, bootstrapChallenge.result.nonce, bootstrapOp), session2.signing);
    const deviceSession = await f.request('/api/v2/session/device',
      { account: 'e2e_alice', id: session2.id, nonce: bootstrapChallenge.result.nonce, proof: bootstrapProof });
    assert.equal(deviceSession.response.status, 200, JSON.stringify(deviceSession.result));
    const deviceCookie = deviceSession.response.headers.getSetCookie().find(s => s.startsWith('shade-alpha=')).split(';')[0];
    const deviceSessionInfo = await f.request('/api/session', undefined, deviceCookie);
    assert.equal(deviceSessionInfo.result.account, 'e2e_alice');
    // With a valid session, challenges for a FOREIGN account are rejected
    // (cross-account quota protection). Sessionless issuance is limited to
    // the device-session bootstrap operation and gated by the device proof.
    const foreignChallenge = await f.request('/api/v2/challenge',
      { account: 'e2e_bob', id: 'primary', operation: '0'.repeat(64) }, ac2);
    assert.equal(foreignChallenge.response.status, 400);

    // Rollback of an ENROLLED account is refused (backup-restore only).
    // The CLI must run while no alpha writer holds the store lock.
    await f.close();
    assert.throws(() => cli(['rollback', '--target', targetDir, '--accounts', 'e2e_alice', '--confirm'],
      { ALPHA_STORAGE_SECRET: targetSecret }), /rollback_refused_enrolled/);

    // Final integrity verification against the source.
    const verified = cli(['verify', '--source', sourceDir, '--target', targetDir], { ALPHA_STORAGE_SECRET: targetSecret });
    assert.equal(verified.ok, true, JSON.stringify(verified.problems));
    assert.equal(verified.counts.enrolled, 2);
  } finally { await f.close().catch(() => {}); }
});

test('v1 server guard: upgrade_required on auth/send/refresh, live v1→v2 bridge, reversible, default off', { timeout: 180000 }, async t => {
  const sourceDir = await tempDir('mig-guard-src-');
  const guardFile = path.join(sourceDir, 'v2-migration-guard.json');
  const bridgeAckFile = path.join(sourceDir, 'v2-bridge-ack.json');
  const secret = randomBytes(32).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'guard_alice' }, { account: 'guard_bob' }] });
  const port = await freePort();
  let child, logs = '';
  const environment = { ...process.env, NODE_ENV: 'test', TLS_TERMINATED_BY_PROXY: '1',
    BIND_HOST: '127.0.0.1', PORT: String(port), DATA_DIR: sourceDir, SESSION_SECRET: secret,
    DASHBOARD_PASS: randomBytes(24).toString('hex'), ALLOW_LEGACY_REGISTRATION: 'true',
    SHADE_V2_GUARD_FILE: guardFile, SHADE_V2_BRIDGE_ACK_FILE: bridgeAckFile };
  child = spawn(process.execPath, ['server.js'], { cwd: serverRoot, env: environment, windowsHide: true });
  child.stdout.on('data', d => { logs += d; });
  child.stderr.on('data', d => { logs += d; });
  const sockets = [];
  t.after(async () => {
    sockets.forEach(s => s.disconnect());
    if (child.exitCode === null) { const exit = new Promise(r => child.once('exit', r)); child.kill(); await exit; }
  });
  await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(Error(`startup failed: ${logs}`)), 20000);
    const poll = setInterval(() => {
      if (logs.includes(`server on :${port}`)) { clearTimeout(timeout); clearInterval(poll); resolve(); }
    }, 50);
    child.once('exit', code => { clearInterval(poll); clearTimeout(timeout); reject(Error(`exit ${code}: ${logs}`)); });
  });
  const base = `http://127.0.0.1:${port}`;
  const request = async (route, body, headers = {}) => {
    const response = await fetch(base + route, { method: body ? 'POST' : 'GET',
      headers: { 'Content-Type': 'application/json', ...headers },
      ...(body ? { body: JSON.stringify(body) } : {}) });
    return { status: response.status, data: await response.json() };
  };
  const signWith = (value, key) => nodeSign('sha256', Buffer.from(Buffer.from(value).toString('base64')),
    { key, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength: 32 }).toString('base64');
  async function register(account) {
    const pair = keys.get(account);
    const challenge = (await request('/auth/challenge', { username: account })).data.challenge;
    const body = { username: account, publicKey: pair.publicKey, signature: signWith(pair.publicKey, pair.privateKey),
      challenge, proof: signWith(`shade-register:v1:${account}:${challenge}`, pair.privateKey) };
    const result = await request('/register', body);
    assert.equal(result.status, 200, JSON.stringify(result.data));
    return { ...result.data, body };
  }
  const alice = await register('guard_alice');
  const bob = await register('guard_bob');
  const connect = async (account, token) => {
    const socket = io(base, { transports: ['websocket'], autoConnect: false, reconnection: false });
    sockets.push(socket);
    await new Promise((resolve, reject) => { socket.once('connect', resolve); socket.once('connect_error', reject); socket.connect(); });
    const outcome = await new Promise((resolve, reject) => {
      // 60 с: под параллельной нагрузкой (flutter-компиляции сабагентов) RSA-регистрация
      // v1 может превышать 30 с; проверяемая функция не меняется, только допуск по времени.
      const timer = setTimeout(() => reject(Error(`register outcome timeout: ${account}`)), 60000);
      socket.once('registered', () => { clearTimeout(timer); resolve('registered'); });
      socket.once('authError', e => { clearTimeout(timer); resolve(e.error); });
      socket.emit('register', { username: account, token });
    });
    return { socket, outcome };
  };
  const send = (socket, to, text, fixedId = null, fixedData = null) => {
    const id = fixedId || randomBytes(16).toString('hex');
    const data = fixedData || v1Seal(text, keys.get(to).publicKey);
    return new Promise((resolve, reject) =>
      socket.timeout(20000).emit('message', { to, id, data },
        (err, ack) => err ? reject(err) : resolve({ ...ack, id, data })));
  };

  // Guard file absent: normal v1 behavior.
  const bobConn = await connect('guard_bob', bob.token);
  assert.equal(bobConn.outcome, 'registered');
  assert.equal((await send(bobConn.socket, 'guard_alice', 'до миграции')).ok, true);

  // Enroll alice into the guard file (as the v2 process would).
  await fs.writeFile(guardFile, JSON.stringify({ version: 1, updatedAt: Date.now(),
    accounts: { guard_alice: 'f'.repeat(64) } }));
  await new Promise(r => setTimeout(r, 1200)); // mtime cache TTL

  // Live v1→v2 bridge: a v1 sender can still message an enrolled recipient.
  // The ciphertext (encrypted to the SAME immutable root RSA) is queued for
  // the one-way legacy inbox bridge instead of being rejected.
  const bridgedSend = await send(bobConn.socket, 'guard_alice', 'после миграции');
  assert.equal(bridgedSend.ok, true, JSON.stringify(bridgedSend));
  // Bridge-ack tombstone (as the v2 process exports after the client ACKs):
  // v1 prunes the queue and advances the receipt to delivered; the sender
  // sees an honest messageStatus.
  const statusEvent = new Promise(resolve => bobConn.socket.once('messageStatus', resolve));
  await fs.writeFile(bridgeAckFile, JSON.stringify({ version: 1, updatedAt: Date.now(),
    accounts: { guard_alice: { acked: [`guard_bob:${bridgedSend.id}`] } } }));
  const status = await Promise.race([statusEvent, new Promise((_, rej) => setTimeout(() => rej(Error('no messageStatus within 30s')), 30000))]);
  assert.equal(status.msgId, bridgedSend.id);
  assert.equal(status.status, 'delivered');
  assert.equal(status.from, 'guard_alice');
  // Idempotent re-send with the same id AND ciphertext surfaces the advanced
  // receipt status (a retry must reuse the exact payload, as real clients do).
  const dup = await send(bobConn.socket, 'guard_alice', 'после миграции', bridgedSend.id, bridgedSend.data);
  assert.equal(dup.ok, true, JSON.stringify(dup));
  assert.equal(dup.status, 'delivered');
  const aliceConn = await connect('guard_alice', alice.token);
  assert.equal(aliceConn.outcome, 'upgrade_required');
  // Fresh challenge (the original nonce is single-use): reissue must be
  // rejected because the account is migrated, not because of nonce replay.
  const freshChallenge = (await request('/auth/challenge', { username: 'guard_alice' })).data.challenge;
  const reissue = await request('/register', { ...alice.body, challenge: freshChallenge,
    proof: signWith(`shade-register:v1:guard_alice:${freshChallenge}`, keys.get('guard_alice').privateKey) });
  assert.equal(reissue.status, 403);
  assert.equal(reissue.data.error, 'upgrade_required');
  const refreshed = await request('/refresh', { refreshToken: alice.refreshToken });
  assert.equal(refreshed.status, 403);
  assert.equal(refreshed.data.error, 'upgrade_required');
  const profile = await request('/user/guard_bob', undefined,
    { 'X-Session-Token': alice.token, 'X-Username': 'guard_alice' });
  assert.equal(profile.status, 403);
  // bob (still v1) can read the migrated contact's public profile.
  const bobProfile = await request('/user/guard_alice', undefined,
    { 'X-Session-Token': bob.token, 'X-Username': 'guard_bob' });
  assert.equal(bobProfile.status, 200);

  // Reversible: removing the guard restores v1 access (rollback scenario).
  await fs.rm(guardFile);
  await new Promise(r => setTimeout(r, 1200));
  const aliceBack = await connect('guard_alice', alice.token);
  assert.equal(aliceBack.outcome, 'registered');
  assert.equal((await send(bobConn.socket, 'guard_alice', 'после отката guard')).ok, true);
});