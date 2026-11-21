// Когортная миграция целыми диалогами (D1, V2_COHORT_MIGRATION.md) против
// РЕАЛЬНОГО registry + alpha fixture + синтетического v1-источника (формат
// at-rest server.js). Production data/VPS не трогаются. Покрыто: happy path
// (оба ready → gate → flip → поток v2), один offline → pending без потерь,
// replay дублей transfer → дедуп, перемешанная доставка → порядок по seq,
// краш между transfer и flip → resume без дублей, abort до flip → v1 нетронут,
// rollback после flip → reverse replay читается v1-ключом (interop-алгоритм
// decryptData, совместимость подтверждена alpha_http_interop_test.dart),
// send при рассинхроне → HOLD/честная ошибка, gate fail-closed при неполной
// готовности, grace-окно rollback, per-dialog guard-экспорт.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { randomBytes, createPublicKey, privateDecrypt, createDecipheriv,
  constants, sign as nodeSign } from 'node:crypto';
import { fixture, identity, register, operation } from './helpers/alpha-fixture.mjs';
import { buildV1Fixture, writeV1Queue, v1Seal } from './helpers/v1-fixture.mjs';
import { alphaStore } from '../multidevice/alpha-store.mjs';
import { createDeviceRegistry, legacyRoot } from '../multidevice/registry.mjs';
import { createMigration, dialogKey } from '../multidevice/migration.mjs';
import { openV1Source } from '../multidevice/v1-source.mjs';
import { genesisText, manifestText, messageText, requestText, hash, fingerprint, sign } from '../../client/web/protocol/device-v2.mjs';
import * as c from '../../client/web/device_crypto.mjs';

const serverRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const CLI = path.join(serverRoot, 'tools', 'migrate-v1-to-v2.mjs');
const PHRASE = 'synthetic cohort migration recovery phrase only';

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
// Тот же алгоритм, что decryptData нативного v1 CryptoService: RSA-OAEP-SHA256
// над base64(2||AESkey32||nonce12) + AES-256-GCM. Структурная совместимость
// v2-конверта для legacy-ключа подтверждена alpha_http_interop_test.dart.
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
  const op = await hash(JSON.stringify(['legacy-session', null]));
  const proof = signText(requestText(account, 'primary', challenge.result.nonce, op), privateKey);
  const reply = await f.request('/api/v2/session/legacy', { account, nonce: challenge.result.nonce, proof });
  assert.equal(reply.response.status, 200, JSON.stringify(reply.result));
  return reply.response.headers.getSetCookie().find(s => s.startsWith('shade-alpha=')).split(';')[0];
}
async function primaryOp(f, account, privateKey, cookie, op, body = null) {
  const operationDigest = await hash(JSON.stringify([op, op === 'send' ? await hash(messageText(body)) : body]));
  const challenge = await f.request('/api/v2/challenge', { account, id: 'primary', operation: operationDigest }, cookie);
  assert.equal(challenge.response.status, 200, JSON.stringify(challenge.result));
  const nonce = challenge.result.nonce;
  return f.request('/api/v2/operation', { op, body,
    auth: { account, id: 'primary', nonce, proof: signText(requestText(account, 'primary', nonce, operationDigest), privateKey) } }, cookie);
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
async function primaryWebSession(account, privateKeyPem) {
  const der = Buffer.from(privateKeyPem.replace(/-----[^-]+-----|\s/g, ''), 'base64');
  const signing = await crypto.subtle.importKey('pkcs8', der, { name: 'RSA-PSS', hash: 'SHA-256' }, false, ['sign']);
  const encryption = await crypto.subtle.importKey('pkcs8', der, { name: 'RSA-OAEP', hash: 'SHA-256' }, false, ['decrypt']);
  return { account, id: 'primary', signing, encryption };
}
// Синтетические v1-конверты диалога (ciphertext известен тесту для interop).
function v1Message(from, to, text, keys) {
  return { id: randomBytes(16).toString('hex'), from, timestamp: Date.now(),
    data: v1Seal(text, keys.get(to).publicKey), text };
}
const trustOf = (a, b) => ({ senderRoot: a.root, recipientRoot: b.root,
  senderGenesis: a.genesis, recipientGenesis: b.genesis });

// Полный цикл когортной миграции диалога до flip через реальные HTTP-операции.
async function migrateToFlip(f, ctx, a, b) {
  const start = await primaryOp(f, a.account, a.privateKey, a.cookie, 'dialog.migration.start', { peer: b.account });
  assert.equal(start.response.status, 200, JSON.stringify(start.result));
  assert.equal(start.result.state, 'migration_pending');
  for (const side of [a, b]) {
    const ready = await primaryOp(f, side.account, side.privateKey, side.cookie, 'dialog.migration.ready',
      { peer: side === a ? b.account : a.account, devices: ['primary'] });
    assert.equal(ready.response.status, 200, JSON.stringify(ready.result));
  }
  for (const side of [a, b]) {
    const ack = await primaryOp(f, side.account, side.privateKey, side.cookie, 'dialog.migration.outbox-empty',
      { peer: side === a ? b.account : a.account });
    assert.equal(ack.response.status, 200, JSON.stringify(ack.result));
  }
  const status = await primaryOp(f, a.account, a.privateKey, a.cookie, 'dialog.migration.status', { peer: b.account });
  assert.equal(status.result.state, 'v2_active', JSON.stringify(status.result.gate));
  return status.result;
}

test('cohort happy path: fail-closed gate, offline wait, scoped transfer, dedup, seq order, flip, v2 flow', { timeout: 300000 }, async () => {
  const sourceDir = await tempDir('coh-src-');
  const targetDir = path.join(await tempDir('coh-dst-'), 'store');
  const guardFile = path.join(await tempDir('coh-guard-'), 'guard.json');
  const bridgeAckFile = path.join(await tempDir('coh-bridge-'), 'bridge-ack.json');
  const reverseReplayFile = path.join(await tempDir('coh-replay-'), 'reverse-replay.json');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'coh_alice' }, { account: 'coh_bob' }, { account: 'coh_dave' }] });
  const alice = keys.get('coh_alice'), bob = keys.get('coh_bob');
  // v1-очередь диалога: три сообщения bob → alice (ciphertext под контролем теста).
  const q1 = [v1Message('coh_bob', 'coh_alice', 'первое v1', keys),
    v1Message('coh_bob', 'coh_alice', 'второе v1', keys),
    v1Message('coh_bob', 'coh_alice', 'третье v1', keys)];
  await writeV1Queue(sourceDir, secret, new Map([['coh_alice', q1]]));
  cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], { ALPHA_STORAGE_SECRET: targetSecret });
  const f = await fixture({ dataDir: targetDir, storageSecret: targetSecret,
    legacySource: { dataDir: sourceDir }, guardFile, bridgeAckFile, reverseReplayFile });
  try {
    const ac = await legacySession(f, 'coh_alice', alice.privateKey);
    const bc = await legacySession(f, 'coh_bob', bob.privateKey);
    const ea = await enroll(f, 'coh_alice', alice.privateKey, ac);
    const eb = await enroll(f, 'coh_bob', bob.privateKey, bc);
    const as = await primaryWebSession('coh_alice', alice.privateKey);
    const bs = await primaryWebSession('coh_bob', bob.privateKey);

    // Старт с не-enrolled собеседником — честный отказ, состояние не создано.
    const refused = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.start', { peer: 'coh_dave' });
    assert.equal(refused.response.status, 409);
    assert.equal(refused.result.error, 'peer_not_enrolled');

    const start = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.start', { peer: 'coh_bob' });
    assert.equal(start.result.state, 'migration_pending');
    assert.equal(start.result.revision, 1);

    // Send при рассинхроне (pending): HOLD, честная ошибка, тихой отправки нет.
    const held = await c.sealMessage('hold во время переноса', [ea.manifest], [eb.manifest], as, trustOf(ea, eb));
    const holdSend = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'send', held);
    assert.equal(holdSend.response.status, 409);
    assert.equal(holdSend.result.error, 'migration_pending');

    // Alice ready; bob OFFLINE — состояние ожидания честное, без форса.
    const readyA = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.ready', { peer: 'coh_bob', devices: ['primary'] });
    assert.equal(readyA.result.state, 'migration_pending');
    const waiting = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.status', { peer: 'coh_bob' });
    assert.ok(waiting.result.waitingFor.includes('coh_bob'));
    // Неполный список устройств — честный отказ (готовность ВСЕХ по каталогу).
    const badReady = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.ready', { peer: 'coh_bob', devices: [] });
    assert.equal(badReady.response.status, 409);
    assert.equal(badReady.result.error, 'invalid_ready_devices');

    // Offline без потерь: позднее v1-сообщение добирается мостом до flip.
    const late = v1Message('coh_bob', 'coh_alice', 'позднее v1 (offline)', keys);
    const q2 = [...q1, late];
    await writeV1Queue(sourceDir, secret, new Map([['coh_alice', q2]]));
    const inboxWhileOffline = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'legacy.inbox');
    assert.equal(inboxWhileOffline.result.length, 4);

    // Bob вернулся: оба ready → transferring + scoped-перенос со счётчиками.
    const readyB = await primaryOp(f, 'coh_bob', bob.privateKey, bc, 'dialog.migration.ready', { peer: 'coh_alice', devices: ['primary'] });
    assert.equal(readyB.result.state, 'transferring');
    assert.equal(readyB.result.transferred.count, 4);
    assert.equal(readyB.result.journalLength, 4);
    // Gate не пропускает без подписанных outbox-empty ack обеих сторон.
    const noOutbox = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.status', { peer: 'coh_bob' });
    assert.equal(noOutbox.result.state, 'transferring');
    assert.ok(noOutbox.result.gate.reasons.includes('outbox_not_empty:coh_alice'));
    assert.ok(noOutbox.result.gate.reasons.includes('outbox_not_empty:coh_bob'));

    // Ростер вырос ПОСЛЕ ready: gate закрыт до нового ack по всем устройствам.
    const vault2 = await c.createVault('coh_alice', 'synthetic cohort second device passphrase');
    const session2 = await c.unlockVault(vault2, 'synthetic cohort second device passphrase');
    const manifest2 = await c.approveDevices(ea.genesis, [ea.manifest], [...ea.manifest.devices, c.descriptor(vault2)], as);
    const installed = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'install',
      { manifest: manifest2, proofs: [await c.pairingProof(vault2, session2)] });
    assert.equal(installed.result.revision, 2);
    for (const [account, key, cookie, peer] of [['coh_alice', alice.privateKey, ac, 'coh_bob'], ['coh_bob', bob.privateKey, bc, 'coh_alice']]) {
      const ack = await primaryOp(f, account, key, cookie, 'dialog.migration.outbox-empty', { peer });
      assert.equal(ack.response.status, 200, JSON.stringify(ack.result));
    }
    const staleReady = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.status', { peer: 'coh_bob' });
    assert.equal(staleReady.result.state, 'transferring');
    assert.ok(staleReady.result.gate.reasons.includes('devices_not_ready:coh_alice'));
    // Повторный ready полным ростером → все gate-условия → атомарный flip.
    const reReady = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.ready',
      { peer: 'coh_bob', devices: ['primary', session2.id] });
    assert.equal(reReady.result.state, 'v2_active');
    assert.equal(reReady.result.flipped, true);

    // Per-dialog routing-флаг ушёл через guard-мост (аддитивная секция).
    const guard = JSON.parse(await fs.readFile(guardFile, 'utf8'));
    assert.ok(guard.accounts.coh_alice && guard.accounts.coh_bob);
    assert.equal(guard.dialogs[dialogKey('coh_alice', 'coh_bob')].state, 'v2_active');

    // Replay дублей transfer: тот же v1-файл перемешан + дубль пакета → дедуп.
    await writeV1Queue(sourceDir, secret, new Map([['coh_alice', [q2[2], q2[0], q2[3], q2[1], q2[0]]]]));
    const afterReplay = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.status', { peer: 'coh_bob' });
    assert.equal(afterReplay.result.journalLength, 4);
    assert.equal(afterReplay.result.transferred.count, 4);
    assert.equal(afterReplay.result.state, 'v2_active');
    const redelivery = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'legacy.inbox');
    assert.equal(redelivery.result.length, 4); // повторная доставка тем же id/ciphertext
    assert.equal(new Set(redelivery.result.map(e => e.id)).size, 4);

    // Перемешанная доставка → порядок восстанавливается по seq journal.
    const journal = afterReplay.result.journal;
    assert.deepEqual(journal.map(e => e.seq), [1, 2, 3, 4]);
    const seqOf = new Map(journal.map(e => [`${e.from}:${e.id}`, e.seq]));
    const shuffled = [...redelivery.result].reverse();
    const ordered = shuffled.sort((x, y) => seqOf.get(`${x.from}:${x.id}`) - seqOf.get(`${y.from}:${y.id}`));
    assert.deepEqual(ordered.map(e => openV1Payload(e.data, alice.privateKey)),
      ['первое v1', 'второе v1', 'третье v1', 'позднее v1 (offline)']);
    // Проекция для UI не содержит ciphertext.
    assert.ok(!JSON.stringify(journal).includes('"data"'));

    // Поток v2 после flip: fanout на оба устройства alice, журнал v2-origine.
    const text = 'v2 поток после flip 🔐';
    const message = await c.sealMessage(text, [ea.manifest, manifest2], [eb.manifest], as, trustOf(ea, eb));
    const sent = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'send', message);
    assert.equal(sent.result.accepted, true);
    const bobInbox = await primaryOp(f, 'coh_bob', bob.privateKey, bc, 'fetch');
    const bundle = bobInbox.result.find(b => b.message.id === message.id);
    assert.ok(bundle);
    assert.equal(await c.openMessage(bundle, bs, trustOf(ea, eb)), text);
    const op2 = async (op, body = null) => {
      const digest = await hash(JSON.stringify([op, body]));
      const challenge = await f.request('/api/v2/challenge', { account: 'coh_alice', id: session2.id, operation: digest }, ac);
      const nonce = challenge.result.nonce;
      const proof = await sign(requestText('coh_alice', session2.id, nonce, digest), session2.signing);
      return f.request('/api/v2/operation', { op, body, auth: { account: 'coh_alice', id: session2.id, nonce, proof } }, ac);
    };
    const own = (await op2('fetch')).result.find(b => b.message.id === message.id);
    assert.ok(own, 'второе устройство отправителя получает fanout');
    assert.equal(await c.openMessage(own, session2, trustOf(ea, eb)), text);
    const v2Journal = (await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.status', { peer: 'coh_bob' })).result.journal;
    assert.equal(v2Journal.length, 5);
    assert.equal(v2Journal[4].origin, 'v2');
    assert.equal(v2Journal[4].seq, 5);

    // Ретрай тем же id → дедуп на сервере и в journal (без дублей).
    const retry = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'send', message);
    assert.equal(retry.result.duplicate, true);
    const afterRetry = (await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.status', { peer: 'coh_bob' })).result;
    assert.equal(afterRetry.journalLength, 5);
    // Конфликт id/digest — честный отказ, journal не меняется.
    const conflict = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'send', { ...message, createdAt: message.createdAt + 1 });
    assert.equal(conflict.response.status, 400);

    // Ack v2-сообщения отмечается в journal диалога.
    const acked = await primaryOp(f, 'coh_bob', bob.privateKey, bc, 'ack', [`${message.from}:${message.deviceId}:${message.id}`]);
    assert.equal(acked.result.acknowledged, 1);
    const ackedJournal = (await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.status', { peer: 'coh_bob' })).result.journal;
    assert.equal(ackedJournal[4].acked, true);
    // Ack v1-пакета моста также отмечается в journal (пакет хранится до ack).
    const legacyAck = await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'legacy.ack', [`coh_bob:${q1[0].id}`]);
    assert.equal(legacyAck.result.acknowledged, 1);
    const finalJournal = (await primaryOp(f, 'coh_alice', alice.privateKey, ac, 'dialog.migration.status', { peer: 'coh_bob' })).result.journal;
    assert.equal(finalJournal[0].acked, true);
  } finally { await f.close().catch(() => {}); }
});

test('crash between transfer and flip: durable journal, resume without duplicates', { timeout: 300000 }, async () => {
  const sourceDir = await tempDir('coh-crash-src-');
  const targetDir = path.join(await tempDir('coh-crash-dst-'), 'store');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [{ account: 'cr_alice' }, { account: 'cr_bob' }] });
  const alice = keys.get('cr_alice'), bob = keys.get('cr_bob');
  const q1 = [v1Message('cr_bob', 'cr_alice', 'до краша 1', keys), v1Message('cr_bob', 'cr_alice', 'до краша 2', keys)];
  await writeV1Queue(sourceDir, secret, new Map([['cr_alice', q1]]));
  cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], { ALPHA_STORAGE_SECRET: targetSecret });
  const options = { dataDir: targetDir, storageSecret: targetSecret, legacySource: { dataDir: sourceDir } };
  let f = await fixture(options);
  try {
    const ac = await legacySession(f, 'cr_alice', alice.privateKey);
    const bc = await legacySession(f, 'cr_bob', bob.privateKey);
    await enroll(f, 'cr_alice', alice.privateKey, ac);
    await enroll(f, 'cr_bob', bob.privateKey, bc);
    await primaryOp(f, 'cr_alice', alice.privateKey, ac, 'dialog.migration.start', { peer: 'cr_bob' });
    await primaryOp(f, 'cr_alice', alice.privateKey, ac, 'dialog.migration.ready', { peer: 'cr_bob', devices: ['primary'] });
    const transferring = await primaryOp(f, 'cr_bob', bob.privateKey, bc, 'dialog.migration.ready', { peer: 'cr_alice', devices: ['primary'] });
    assert.equal(transferring.result.state, 'transferring');
    assert.equal(transferring.result.journalLength, 2);
    // КРАШ между transfer и flip: процесс закрыт без outbox-ack и без flip.
    await f.close();

    f = await fixture(options);
    const ac2 = await legacySession(f, 'cr_alice', alice.privateKey);
    const bc2 = await legacySession(f, 'cr_bob', bob.privateKey);
    const resumed = await primaryOp(f, 'cr_alice', alice.privateKey, ac2, 'dialog.migration.status', { peer: 'cr_bob' });
    assert.equal(resumed.result.state, 'transferring');
    assert.equal(resumed.result.journalLength, 2); // journal пережил краш
    // Поздний пакет + повтор всего файла: resume добирает ТОЛЬКО новое.
    const late = v1Message('cr_bob', 'cr_alice', 'после краша', keys);
    await writeV1Queue(sourceDir, secret, new Map([['cr_alice', [...q1, late, q1[0]]]]));
    const toppedUp = await primaryOp(f, 'cr_alice', alice.privateKey, ac2, 'dialog.migration.status', { peer: 'cr_bob' });
    assert.equal(toppedUp.result.journalLength, 3);
    assert.equal(toppedUp.result.transferred.count, 3);
    assert.deepEqual(toppedUp.result.journal.map(e => e.seq), [1, 2, 3]);
    // Повторные ready идемпотентны, flip всё ещё закрыт без outbox-ack.
    const reReady = await primaryOp(f, 'cr_alice', alice.privateKey, ac2, 'dialog.migration.ready', { peer: 'cr_bob', devices: ['primary'] });
    assert.equal(reReady.result.state, 'transferring');
    assert.equal(reReady.result.journalLength, 3);
    await primaryOp(f, 'cr_alice', alice.privateKey, ac2, 'dialog.migration.outbox-empty', { peer: 'cr_bob' });
    const flipped = await primaryOp(f, 'cr_bob', bob.privateKey, bc2, 'dialog.migration.outbox-empty', { peer: 'cr_alice' });
    assert.equal(flipped.result.state, 'v2_active');
    assert.equal(flipped.result.journalLength, 3); // без дублей после resume
    const inbox = await primaryOp(f, 'cr_alice', alice.privateKey, ac2, 'legacy.inbox');
    assert.equal(inbox.result.length, 3);
    assert.equal(new Set(inbox.result.map(e => e.id)).size, 3);
    assert.deepEqual(inbox.result.map(e => openV1Payload(e.data, alice.privateKey)).sort(),
      ['до краша 1', 'до краша 2', 'после краша'].sort());
  } finally { await f.close().catch(() => {}); }
});

test('abort before flip: v1 untouched, journal preserved, participant-only authorization', { timeout: 300000 }, async () => {
  const sourceDir = await tempDir('coh-abort-src-');
  const targetDir = path.join(await tempDir('coh-abort-dst-'), 'store');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [
    { account: 'ab_alice' }, { account: 'ab_bob' }, { account: 'ab_carol' }] });
  const alice = keys.get('ab_alice'), bob = keys.get('ab_bob'), carol = keys.get('ab_carol');
  const q1 = [v1Message('ab_bob', 'ab_alice', 'v1 нетронут 1', keys), v1Message('ab_bob', 'ab_alice', 'v1 нетронут 2', keys)];
  await writeV1Queue(sourceDir, secret, new Map([['ab_alice', q1]]));
  cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], { ALPHA_STORAGE_SECRET: targetSecret });
  const f = await fixture({ dataDir: targetDir, storageSecret: targetSecret, legacySource: { dataDir: sourceDir } });
  try {
    const ac = await legacySession(f, 'ab_alice', alice.privateKey);
    const bc = await legacySession(f, 'ab_bob', bob.privateKey);
    const cc = await legacySession(f, 'ab_carol', carol.privateKey);
    const ea = await enroll(f, 'ab_alice', alice.privateKey, ac);
    const eb = await enroll(f, 'ab_bob', bob.privateKey, bc);
    await enroll(f, 'ab_carol', carol.privateKey, cc);
    await primaryOp(f, 'ab_alice', alice.privateKey, ac, 'dialog.migration.start', { peer: 'ab_bob' });
    await primaryOp(f, 'ab_alice', alice.privateKey, ac, 'dialog.migration.ready', { peer: 'ab_bob', devices: ['primary'] });
    const before = await fs.readFile(path.join(sourceDir, 'messaging.json'));
    const aborted = await primaryOp(f, 'ab_alice', alice.privateKey, ac, 'dialog.migration.abort', { peer: 'ab_bob' });
    assert.equal(aborted.result.state, 'v1_active');
    assert.ok(aborted.result.abortedAt);
    assert.equal(aborted.result.journalLength, 0);
    // v1-очереди не тронуты abort (байт-в-байт).
    assert.deepEqual(await fs.readFile(path.join(sourceDir, 'messaging.json')), before);
    // После abort диалог в обычном режиме enrolled-пары: v2-send принимается.
    const as = await primaryWebSession('ab_alice', alice.privateKey);
    const message = await c.sealMessage('после abort', [ea.manifest], [eb.manifest], as, trustOf(ea, eb));
    const sent = await primaryOp(f, 'ab_alice', alice.privateKey, ac, 'send', message);
    assert.equal(sent.result.accepted, true);
    // Rollback до flip невозможен — честный отказ.
    const earlyRollback = await primaryOp(f, 'ab_alice', alice.privateKey, ac, 'dialog.migration.rollback', { peer: 'ab_bob' });
    assert.equal(earlyRollback.response.status, 409);
    assert.equal(earlyRollback.result.error, 'not_v2_active');
    // Авторизация участника: carol не видит и не меняет диалог alice–bob.
    const foreign = await primaryOp(f, 'ab_carol', carol.privateKey, cc, 'dialog.migration.ready', { peer: 'ab_bob', devices: ['primary'] });
    assert.equal(foreign.response.status, 409);
    assert.equal(foreign.result.error, 'dialog_not_found');
    const foreignStatus = await primaryOp(f, 'ab_bob', bob.privateKey, bc, 'dialog.migration.status', { peer: 'ab_carol' });
    assert.equal(foreignStatus.response.status, 409);
    assert.equal(foreignStatus.result.error, 'dialog_not_found');
    // Некорректный peer (сам с собой) отклоняется.
    const selfDialog = await primaryOp(f, 'ab_alice', alice.privateKey, ac, 'dialog.migration.start', { peer: 'ab_alice' });
    assert.equal(selfDialog.response.status, 400);
    // Повторный старт после abort сохраняет journal и продолжает seq.
    const restarted = await primaryOp(f, 'ab_alice', alice.privateKey, ac, 'dialog.migration.start', { peer: 'ab_bob' });
    assert.equal(restarted.result.state, 'migration_pending');
    const abortAgain = await primaryOp(f, 'ab_alice', alice.privateKey, ac, 'dialog.migration.abort', { peer: 'ab_bob' });
    assert.equal(abortAgain.result.state, 'v1_active');
    const idempotent = await primaryOp(f, 'ab_alice', alice.privateKey, ac, 'dialog.migration.abort', { peer: 'ab_bob' });
    assert.equal(idempotent.result.already, true);
    assert.deepEqual(await fs.readFile(path.join(sourceDir, 'messaging.json')), before);
  } finally { await f.close().catch(() => {}); }
});

test('rollback after flip: reverse replay interop, grace window, guard release, honest send refusal', { timeout: 300000 }, async () => {
  const sourceDir = await tempDir('coh-rb-src-');
  const targetDir = path.join(await tempDir('coh-rb-dst-'), 'store');
  const guardFile = path.join(await tempDir('coh-rb-guard-'), 'guard.json');
  const reverseReplayFile = path.join(await tempDir('coh-rb-replay-'), 'reverse-replay.json');
  const secret = randomBytes(32).toString('hex');
  const targetSecret = randomBytes(32).toString('hex');
  const { keys } = await buildV1Fixture(sourceDir, { secret, users: [{ account: 'rb_alice' }, { account: 'rb_bob' }] });
  const alice = keys.get('rb_alice'), bob = keys.get('rb_bob');
  const q1 = [v1Message('rb_bob', 'rb_alice', 'v1 до миграции', keys)];
  await writeV1Queue(sourceDir, secret, new Map([['rb_alice', q1]]));
  cli(['prepare', '--source', sourceDir, '--target', targetDir, '--all'], { ALPHA_STORAGE_SECRET: targetSecret });
  const options = { dataDir: targetDir, storageSecret: targetSecret,
    legacySource: { dataDir: sourceDir }, guardFile, reverseReplayFile };
  let f = await fixture(options);
  const key = dialogKey('rb_alice', 'rb_bob');
  let flippedAt;
  try {
    const ac = await legacySession(f, 'rb_alice', alice.privateKey);
    const bc = await legacySession(f, 'rb_bob', bob.privateKey);
    const ea = await enroll(f, 'rb_alice', alice.privateKey, ac);
    const eb = await enroll(f, 'rb_bob', bob.privateKey, bc);
    const as = await primaryWebSession('rb_alice', alice.privateKey);
    const bs = await primaryWebSession('rb_bob', bob.privateKey);
    const ctx = {};
    await migrateToFlip(f, ctx,
      { account: 'rb_alice', privateKey: alice.privateKey, cookie: ac },
      { account: 'rb_bob', privateKey: bob.privateKey, cookie: bc });
    // Второе устройство bob — НЕ legacy (новый ключ): replay его честно не получает.
    const vault2 = await c.createVault('rb_bob', 'synthetic rollback second device passphrase');
    const session2 = await c.unlockVault(vault2, 'synthetic rollback second device passphrase');
    const bobManifest2 = await c.approveDevices(eb.genesis, [eb.manifest], [...eb.manifest.devices, c.descriptor(vault2)], bs);
    const installed = await primaryOp(f, 'rb_bob', bob.privateKey, bc, 'install',
      { manifest: bobManifest2, proofs: [await c.pairingProof(vault2, session2)] });
    assert.equal(installed.result.revision, 2);
    // v2-origine сообщения в обе стороны; затем ack (очереди prune-ятся).
    const textA = 'v2 период: alice → bob';
    const textB = 'v2 период: bob → alice';
    const msgA = await c.sealMessage(textA, [ea.manifest], [eb.manifest, bobManifest2], as, trustOf(ea, eb));
    const msgB = await c.sealMessage(textB, [eb.manifest, bobManifest2], [ea.manifest], bs, trustOf(eb, ea));
    assert.equal((await primaryOp(f, 'rb_alice', alice.privateKey, ac, 'send', msgA)).result.accepted, true);
    assert.equal((await primaryOp(f, 'rb_bob', bob.privateKey, bc, 'send', msgB)).result.accepted, true);
    const bobFetch = await primaryOp(f, 'rb_bob', bob.privateKey, bc, 'fetch');
    const bundleA = bobFetch.result.find(b => b.message.id === msgA.id);
    assert.equal(await c.openMessage(bundleA, bs, trustOf(ea, eb)), textA);
    await primaryOp(f, 'rb_bob', bob.privateKey, bc, 'ack', [`${msgA.from}:${msgA.deviceId}:${msgA.id}`]);
    const aliceFetch = await primaryOp(f, 'rb_alice', alice.privateKey, ac, 'fetch');
    const bundleB = aliceFetch.result.find(b => b.message.id === msgB.id);
    assert.equal(await c.openMessage(bundleB, as, trustOf(eb, ea)), textB);
    await primaryOp(f, 'rb_alice', alice.privateKey, ac, 'ack', [`${msgB.from}:${msgB.deviceId}:${msgB.id}`]);
    // Replay-конверты journal нацелены ТОЛЬКО на legacy-устройство (primary).
    const snap = f.registry.exportSnapshot();
    const record = snap.dialogRouting.dialogs[key];
    flippedAt = record.flippedAt;
    const entryA = record.journal.find(e => e.id === msgA.id);
    const entryB = record.journal.find(e => e.id === msgB.id);
    assert.deepEqual(entryA.replay.map(r => [r.account, r.deviceId]), [['rb_bob', 'primary']]);
    assert.deepEqual(entryB.replay.map(r => [r.account, r.deviceId]), [['rb_alice', 'primary']]);
    assert.equal(entryA.acked, true);
    assert.equal(entryB.acked, true);
    await f.close();

    // Grace-окно 14 дней:engine-level на РЕАЛЬНОМ registry+store с fake clock.
    const store = await alphaStore(targetDir, targetSecret);
    try {
      const snapshot = await store.load();
      const users = new Map();
      for (const account of ['rb_alice', 'rb_bob']) {
        const pem = createPublicKey({ key: Buffer.from(snapshot.accounts[account].root, 'base64'), format: 'der', type: 'spki' })
          .export({ type: 'spki', format: 'pem' });
        users.set(account, { publicKey: pem });
      }
      const registry = await createDeviceRegistry({ users, snapshot, persist: s => store.save(s) });
      const source = await openV1Source(sourceDir, { secret });
      const expired = createMigration({ registry, source, clock: () => flippedAt + 15 * 86400000 });
      await assert.rejects(expired.rollbackDialog({ account: 'rb_alice', peer: 'rb_bob' }), /rollback_grace_expired/);
      assert.equal(registry.exportSnapshot().dialogRouting.dialogs[key].state, 'v2_active');
      const inGrace = createMigration({ registry, source, clock: () => flippedAt + 13 * 86400000 });
      const rolled = await inGrace.rollbackDialog({ account: 'rb_alice', peer: 'rb_bob' });
      assert.equal(rolled.state, 'v1_active');
      assert.deepEqual(rolled.replayed, { rb_bob: 1, rb_alice: 1 });
      assert.equal(rolled.skipped, 0);
      assert.ok(rolled.rolledBackAt);
    } finally { await store.close(); }

    // Рестарт: rollback персистентен, guard/reverse-replay ре-экспортированы.
    f = await fixture(options);
    const ac2 = await legacySession(f, 'rb_alice', alice.privateKey);
    const bc2 = await legacySession(f, 'rb_bob', bob.privateKey);
    const guard = JSON.parse(await fs.readFile(guardFile, 'utf8'));
    // Все диалоги участников откатаны → guard снят, сервис вернулся на v1.
    assert.ok(!guard.accounts.rb_alice && !guard.accounts.rb_bob);
    assert.equal(guard.dialogs[key].state, 'v1_active');
    // INTEROP: reverse-replay читается ТЕМ ЖЕ алгоритмом, что decryptData v1
    // (нативная совместимость подтверждена alpha_http_interop_test.dart).
    const replay = JSON.parse(await fs.readFile(reverseReplayFile, 'utf8'));
    assert.equal(replay.version, 1);
    assert.equal(replay.accounts.rb_bob.length, 1);
    assert.equal(replay.accounts.rb_alice.length, 1);
    assert.equal(openV1Payload(replay.accounts.rb_bob[0].data, bob.privateKey), textA);
    assert.equal(openV1Payload(replay.accounts.rb_alice[0].data, alice.privateKey), textB);
    assert.equal(replay.accounts.rb_bob[0].from, 'rb_alice');
    assert.equal(replay.accounts.rb_bob[0].id, msgA.id);
    // Send после rollback: честный отказ, тихой отправки в v1-окружение нет.
    const ea2 = { root: ea.root, genesis: ea.genesis };
    const eb2 = { root: eb.root, genesis: eb.genesis };
    const afterRollback = await c.sealMessage('после rollback', [ea.manifest], [eb.manifest, bobManifest2], as, trustOf(ea2, eb2));
    const refused = await primaryOp(f, 'rb_alice', alice.privateKey, ac2, 'send', afterRollback);
    assert.equal(refused.response.status, 409);
    assert.equal(refused.result.error, 'migration_rolled_back');
    // Повторный rollback невозможен (уже v1_active).
    const doubleRollback = await primaryOp(f, 'rb_alice', alice.privateKey, ac2, 'dialog.migration.rollback', { peer: 'rb_bob' });
    assert.equal(doubleRollback.response.status, 409);
    assert.equal(doubleRollback.result.error, 'not_v2_active');

    // Новое (не legacy) устройство/аккаунт: replay честно не получает.
    const cc = await f.login('synthetic-rb-carol');
    const carol = await identity('rb_carol');
    await register(f, carol, cc);
    const carolKey = dialogKey('rb_alice', 'rb_carol');
    assert.equal((await primaryOp(f, 'rb_alice', alice.privateKey, ac2, 'dialog.migration.start', { peer: 'rb_carol' })).result.state, 'migration_pending');
    assert.equal((await primaryOp(f, 'rb_alice', alice.privateKey, ac2, 'dialog.migration.ready', { peer: 'rb_carol', devices: ['primary'] })).result.state, 'migration_pending');
    const carolReady = await operation(f, carol, cc, 'dialog.migration.ready', { peer: 'rb_alice', devices: [carol.session.id] });
    assert.equal(carolReady.result.state, 'transferring');
    await primaryOp(f, 'rb_alice', alice.privateKey, ac2, 'dialog.migration.outbox-empty', { peer: 'rb_carol' });
    const carolFlip = await operation(f, carol, cc, 'dialog.migration.outbox-empty', { peer: 'rb_alice' });
    assert.equal(carolFlip.result.state, 'v2_active', JSON.stringify(carolFlip.result.gate));
    const toCarol = await c.sealMessage('новому аккаунту', [ea.manifest], [carol.manifest], as,
      { senderRoot: ea.root, recipientRoot: carol.vault.signingKey, senderGenesis: ea.genesis, recipientGenesis: carol.genesis });
    assert.equal((await primaryOp(f, 'rb_alice', alice.privateKey, ac2, 'send', toCarol)).result.accepted, true);
    const carolRollback = await primaryOp(f, 'rb_alice', alice.privateKey, ac2, 'dialog.migration.rollback', { peer: 'rb_carol' });
    assert.equal(carolRollback.result.state, 'v1_active');
    assert.deepEqual(carolRollback.result.replayed, {});
    assert.equal(carolRollback.result.skipped, 1); // no_legacy_device
    const replay2 = JSON.parse(await fs.readFile(reverseReplayFile, 'utf8'));
    assert.ok(!replay2.accounts.rb_carol); // новый аккаунт replay не получает
    // Guard: все диалоги alice откатаны → снят; кароль тоже снят.
    const guard2 = JSON.parse(await fs.readFile(guardFile, 'utf8'));
    assert.ok(!guard2.accounts.rb_alice && !guard2.accounts.rb_carol);
    assert.equal(guard2.dialogs[carolKey].state, 'v1_active');
    void bc2;
  } finally { await f.close().catch(() => {}); }
});

test('PWA client: аддитивные методы когортной миграции шлют подписываемые ops', { timeout: 60000 }, async () => {
  // Минимальные браузерные шимы для загрузки модуля (существующего полного
  // harness для alpha-client нет; проверяется проводка методов и ростер ready).
  // navigator в Node — read-only getter, переопределяем через defineProperty.
  Object.defineProperty(globalThis, 'window', { value: { addEventListener() {} }, configurable: true });
  Object.defineProperty(globalThis, 'navigator', { value: { onLine: true }, configurable: true });
  Object.defineProperty(globalThis, 'document', { value: { hidden: false }, configurable: true });
  const { AlphaClient } = await import('../../client/web/alpha-client.mjs');
  const client = new AlphaClient();
  const calls = [];
  client.operation = async (op, body) => { calls.push({ op, body }); return { ok: true }; };
  client.state = { own: { history: [{ devices: [{ id: 'primary' }, { id: 'a'.repeat(64) }] }] } };
  await client.dialogMigrationStart('peer_acc');
  await client.dialogMigrationReady('peer_acc');
  await client.dialogMigrationStatus('peer_acc');
  await client.dialogMigrationAbort('peer_acc');
  await client.dialogMigrationRollback('peer_acc');
  await client.dialogMigrationOutboxEmpty('peer_acc');
  assert.deepEqual(calls.map(c => c.op), ['dialog.migration.start', 'dialog.migration.ready',
    'dialog.migration.status', 'dialog.migration.abort', 'dialog.migration.rollback', 'dialog.migration.outbox-empty']);
  // ready по умолчанию подтверждает ВСЕ устройства своего каталога.
  assert.deepEqual(calls[1].body, { peer: 'peer_acc', devices: ['primary', 'a'.repeat(64)] });
  await client.dialogMigrationReady('peer_acc', ['primary']);
  assert.deepEqual(calls[6].body, { peer: 'peer_acc', devices: ['primary'] });
});