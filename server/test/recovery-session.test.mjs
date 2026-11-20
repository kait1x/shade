// Recovery-сессия (PRF_RECOVERY_BLOCKER §3): серверный вход по независимому
// recovery-ключу при утрате всех устройств. Негативы (подпись, genesis, replay),
// запрет прочих ops/маршрутов/socket, rate limit, TTL, полный flow против
// реального registry и регрессии обычных сессий. Только синтетические ключи.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { io } from 'socket.io-client';
import { fixture, register, operation, proof } from './helpers/alpha-fixture.mjs';
import { createVault, unlockVault, descriptor, createRecoveryBackup, finalizeRecoveryBackup,
  unlockRecoveryBackup, createGenesis, approveDevices, sealMessage, openMessage } from '../../client/web/device_crypto.mjs';
import { sign, requestText, hash, genesisText, pairingTextV2 } from '../../client/web/protocol/device-v2.mjs';
import { operationDigest } from '../multidevice/registry.mjs';

const password = 'synthetic recovery device passphrase 2026';
const recoveryPassword = 'independent synthetic offline recovery passphrase only';

async function tempDir() {
  const build = path.resolve('build');
  await fs.mkdir(build, { recursive: true });
  return fs.mkdtemp(path.join(build, 'alpha-recovery-'));
}
const opts = async extra => ({ dataDir: await tempDir(), storageSecret: randomBytes(32).toString('hex'), ...extra });
const cookieOf = reply => reply.response.headers.getSetCookie().find(s => s.startsWith('shade-alpha=')).split(';')[0];

// Идентичность с финализированным recovery-пакетом (привязан к точному genesis).
async function makeIdentity(account) {
  const vault = await createVault(account, password);
  const session = await unlockVault(vault, password);
  let backup = await createRecoveryBackup(account, vault.signingKey, recoveryPassword);
  const genesis = await createGenesis(vault, session, backup.publicKey);
  backup = await finalizeRecoveryBackup(backup, recoveryPassword, genesis);
  const manifest = await approveDevices(genesis, [], [descriptor(vault)], session);
  return { vault, session, genesis, backup, manifest };
}
async function newDevice(account) {
  const vault = await createVault(account, `${password} fresh`);
  const session = await unlockVault(vault, `${password} fresh`);
  return { vault, session, descriptor: descriptor(vault) };
}
// Possession proof нового устройства (challenge-bound v2, как в pairing-v2).
async function pairingProofV2(account, vault, session) {
  const d = descriptor(vault), nonce = randomBytes(32).toString('hex'), expiresAt = Date.now() + 60000;
  const challenge = randomBytes(15).toString('hex');
  return { id: d.id, nonce, expiresAt, challenge, pairingVersion: 2,
    signature: await sign(pairingTextV2(account, d, nonce, expiresAt, challenge), session.signing) };
}
// Подпись recovery-ключом: requestText с operation, привязанным к genesisDigest.
async function recoveryProof(who, account, nonce) {
  const recovery = await unlockRecoveryBackup(who.backup, recoveryPassword, who.genesis);
  const operation = await operationDigest('recovery-session', await hash(genesisText(who.genesis)));
  return sign(requestText(account, 'primary', nonce, operation), recovery.signing);
}
async function recoveryLogin(f, who, account) {
  const ch = await f.request('/api/v2/session/recovery-challenge', { account });
  assert.equal(ch.response.status, 200);
  const p = await recoveryProof(who, account, ch.result.nonce);
  return f.request('/api/v2/session/recovery', { account, genesis: who.genesis, nonce: ch.result.nonce, proof: p });
}
const trust = (a, b) => ({ senderRoot: a.vault.signingKey, recipientRoot: b.vault.signingKey,
  senderGenesis: a.genesis, recipientGenesis: b.genesis });

test('recovery session rejects a wrong-key signature and consumes the nonce', { timeout: 120000 }, async () => {
  const f = await fixture(await opts());
  try {
    const who = await makeIdentity('rec_wrong');
    await register(f, who, await f.login('synthetic-rec_wrong'));
    const ch = await f.request('/api/v2/session/recovery-challenge', { account: 'rec_wrong' });
    assert.equal(ch.response.status, 200);
    // Подпись device-ключом вместо recovery-ключа отклоняется.
    const operation = await operationDigest('recovery-session', await hash(genesisText(who.genesis)));
    const wrong = await sign(requestText('rec_wrong', 'primary', ch.result.nonce, operation), who.session.signing);
    const bad = await f.request('/api/v2/session/recovery',
      { account: 'rec_wrong', genesis: who.genesis, nonce: ch.result.nonce, proof: wrong });
    assert.equal(bad.response.status, 400);
    // Nonce потреблён даже при неудаче: повтор → 400.
    const replay = await f.request('/api/v2/session/recovery',
      { account: 'rec_wrong', genesis: who.genesis, nonce: ch.result.nonce, proof: wrong });
    assert.equal(replay.response.status, 400);
  } finally { await f.close(); }
});

test('recovery session rejects foreign or substituted genesis (digest mismatch)', { timeout: 120000 }, async () => {
  const f = await fixture(await opts());
  try {
    const who = await makeIdentity('rec_genesis');
    const other = await makeIdentity('rec_other');
    await register(f, who, await f.login('synthetic-rec_genesis'));
    // Чужой genesis (другой аккаунт).
    const ch1 = await f.request('/api/v2/session/recovery-challenge', { account: 'rec_genesis' });
    const foreign = await f.request('/api/v2/session/recovery', { account: 'rec_genesis',
      genesis: other.genesis, nonce: ch1.result.nonce, proof: await recoveryProof(who, 'rec_genesis', ch1.result.nonce) });
    assert.equal(foreign.response.status, 400);
    // Подменённый genesis: тот же аккаунт, другой nonce.
    const substituted = structuredClone(who.genesis); substituted.nonce = 'f'.repeat(64);
    const ch2 = await f.request('/api/v2/session/recovery-challenge', { account: 'rec_genesis' });
    const sub = await f.request('/api/v2/session/recovery', { account: 'rec_genesis',
      genesis: substituted, nonce: ch2.result.nonce, proof: await recoveryProof(who, 'rec_genesis', ch2.result.nonce) });
    assert.equal(sub.response.status, 400);
    // Подменённый recoveryKey внутри genesis.
    const tampered = structuredClone(who.genesis); tampered.recoveryKey = other.genesis.recoveryKey;
    const ch3 = await f.request('/api/v2/session/recovery-challenge', { account: 'rec_genesis' });
    const tam = await f.request('/api/v2/session/recovery', { account: 'rec_genesis',
      genesis: tampered, nonce: ch3.result.nonce, proof: await recoveryProof(who, 'rec_genesis', ch3.result.nonce) });
    assert.equal(tam.response.status, 400);
    // Неизвестный аккаунт: challenge не выдаётся.
    assert.equal((await f.request('/api/v2/session/recovery-challenge', { account: 'rec_ghost' })).response.status, 400);
  } finally { await f.close(); }
});

test('recovery challenge and proof are single-use and nonce-bound', { timeout: 120000 }, async () => {
  const f = await fixture(await opts());
  try {
    const who = await makeIdentity('rec_replay');
    await register(f, who, await f.login('synthetic-rec_replay'));
    const ch = await f.request('/api/v2/session/recovery-challenge', { account: 'rec_replay' });
    const p = await recoveryProof(who, 'rec_replay', ch.result.nonce);
    const ok = await f.request('/api/v2/session/recovery',
      { account: 'rec_replay', genesis: who.genesis, nonce: ch.result.nonce, proof: p });
    assert.equal(ok.response.status, 200);
    assert.equal(ok.result.kind, 'recovery');
    // Повтор того же nonce+proof → 400.
    const replay = await f.request('/api/v2/session/recovery',
      { account: 'rec_replay', genesis: who.genesis, nonce: ch.result.nonce, proof: p });
    assert.equal(replay.response.status, 400);
    // Тот же proof с новым nonce → 400 (proof привязан к nonce).
    const ch2 = await f.request('/api/v2/session/recovery-challenge', { account: 'rec_replay' });
    const reuse = await f.request('/api/v2/session/recovery',
      { account: 'rec_replay', genesis: who.genesis, nonce: ch2.result.nonce, proof: p });
    assert.equal(reuse.response.status, 400);
  } finally { await f.close(); }
});

test('recovery session allows only directory/install; other ops, routes and sockets are denied', { timeout: 120000 }, async () => {
  const f = await fixture(await opts());
  try {
    const who = await makeIdentity('rec_ops');
    await register(f, who, await f.login('synthetic-rec_ops'));
    const rc = cookieOf(await recoveryLogin(f, who, 'rec_ops'));
    const auth = { account: 'rec_ops' };
    for (const op of ['users', 'fetch', 'send', 'ack', 'status', 'read', 'retract', 'retractions',
      'legacy.inbox', 'legacy.ack', 'push.subscribe', 'push.unsubscribe']) {
      const r = await f.request('/api/v2/operation', { op, body: null, auth }, rc);
      assert.equal(r.response.status, 400, `op ${op} must be denied`);
    }
    // directory чужого аккаунта запрещён, своего — разрешён.
    assert.equal((await f.request('/api/v2/operation', { op: 'directory', body: 'rec_ghost', auth }, rc)).response.status, 400);
    const own = await f.request('/api/v2/operation', { op: 'directory', body: 'rec_ops', auth }, rc);
    assert.equal(own.response.status, 200);
    assert.equal(own.result.history.length, 1);
    // install без recovery-подписи запрещён.
    const badInstall = await f.request('/api/v2/operation',
      { op: 'install', body: { manifest: { ...who.manifest, revision: 2 } }, auth }, rc);
    assert.equal(badInstall.response.status, 400);
    // Прочие маршруты закрыты.
    assert.equal((await f.request('/api/v2/register', { genesis: who.genesis, manifest: who.manifest, proofs: [] }, rc)).response.status, 403);
    assert.equal((await f.request('/api/v2/stickers/wall', undefined, rc)).response.status, 403);
    // GET /api/session не раскрывает каталог recovery-сессии.
    const sess = await f.request('/api/session', undefined, rc);
    assert.equal(sess.result.authenticated, true);
    assert.equal(sess.result.kind, 'recovery');
    assert.equal(sess.result.directory, null);
    // Socket недоступен recovery-сессии.
    const sock = io(f.origin, { autoConnect: false, transports: ['websocket'], extraHeaders: { Cookie: rc }, auth });
    const err = await new Promise((res, rej) => {
      sock.once('connect', () => rej(Error('socket must be denied'))); sock.once('connect_error', res); sock.connect();
    });
    assert.match(err.message, /device_auth_required/);
    sock.disconnect();
  } finally { await f.close(); }
});

test('recovery session rate limit: 6th attempt within an hour returns 429', { timeout: 120000 }, async () => {
  const f = await fixture(await opts());
  try {
    const who = await makeIdentity('rec_rate');
    await register(f, who, await f.login('synthetic-rec_rate'));
    for (let i = 0; i < 5; i++) {
      const ok = await recoveryLogin(f, who, 'rec_rate');
      assert.equal(ok.response.status, 200, `attempt ${i + 1} must succeed`);
    }
    const sixth = await recoveryLogin(f, who, 'rec_rate');
    assert.equal(sixth.response.status, 429);
    assert.equal(sixth.result.error, 'rate_limited');
  } finally { await f.close(); }
});

test('recovery session expires after its TTL', { timeout: 120000 }, async () => {
  const f = await fixture(await opts({ recoverySessionMs: 400 }));
  try {
    const who = await makeIdentity('rec_ttl');
    await register(f, who, await f.login('synthetic-rec_ttl'));
    const rc = cookieOf(await recoveryLogin(f, who, 'rec_ttl'));
    const auth = { account: 'rec_ttl' };
    const before = await f.request('/api/v2/operation', { op: 'directory', body: 'rec_ttl', auth }, rc);
    assert.equal(before.response.status, 200);
    await new Promise(r => setTimeout(r, 550));
    assert.equal((await f.request('/api/v2/operation', { op: 'directory', body: 'rec_ttl', auth }, rc)).response.status, 401);
    assert.equal((await f.request('/api/session', undefined, rc)).result.authenticated, false);
  } finally { await f.close(); }
});

test('full recovery flow: session → directory → install (recovery signer) → tombstones → new device session', { timeout: 120000 }, async () => {
  const f = await fixture(await opts());
  try {
    const who = await makeIdentity('rec_flow');
    await register(f, who, await f.login('synthetic-rec_flow'));
    const oldId = who.session.id;
    const rc = cookieOf(await recoveryLogin(f, who, 'rec_flow'));
    const auth = { account: 'rec_flow' };
    // Каталог через op directory.
    const dir = (await f.request('/api/v2/operation', { op: 'directory', body: 'rec_flow', auth }, rc)).result;
    assert.equal(dir.history.length, 1);
    const fresh = await newDevice('rec_flow');
    const recovery = await unlockRecoveryBackup(who.backup, recoveryPassword, who.genesis);
    const v2proof = await pairingProofV2('rec_flow', fresh.vault, fresh.session);
    // Манифест, сохраняющий старое устройство, отклоняется (ростер заменяется).
    const keepOld = await approveDevices(who.genesis, dir.history, [descriptor(who.vault), fresh.descriptor], recovery);
    assert.equal((await f.request('/api/v2/operation',
      { op: 'install', body: { manifest: keepOld, proofs: [v2proof] }, auth }, rc)).response.status, 400);
    // Recovery-подписанный манифест только с новым устройством.
    const manifest = await approveDevices(who.genesis, dir.history, [fresh.descriptor], recovery);
    assert.equal(manifest.signer, 'recovery');
    assert.equal(manifest.revision, 2);
    const install = await f.request('/api/v2/operation', { op: 'install', body: { manifest, proofs: [v2proof] }, auth }, rc);
    assert.equal(install.response.status, 200);
    assert.equal(install.result.revision, 2);
    // Старое устройство в tombstones, новое активно, ростер заменён.
    const snap = f.registry.exportSnapshot();
    assert.ok(snap.accounts.rec_flow.retired.includes(oldId));
    const tip = f.registry.directory('rec_flow').history.at(-1);
    assert.deepEqual(tip.devices.map(d => d.id), [fresh.descriptor.id]);
    assert.equal(tip.signer, 'recovery');
    // Recovery-сессия по-прежнему не может fetch.
    assert.equal((await f.request('/api/v2/operation', { op: 'fetch', body: null, auth }, rc)).response.status, 400);
    // Socket закрыт даже с валидным proof нового устройства под recovery-сессией.
    const sockOp = await operationDigest('socket');
    const sch = await f.request('/api/v2/challenge', { account: 'rec_flow', id: fresh.descriptor.id, operation: sockOp }, rc);
    assert.equal(sch.response.status, 200);
    const sockAuth = { account: 'rec_flow', id: fresh.descriptor.id, nonce: sch.result.nonce,
      proof: await sign(requestText('rec_flow', fresh.descriptor.id, sch.result.nonce, sockOp), fresh.session.signing) };
    const sock = io(f.origin, { autoConnect: false, transports: ['websocket'], extraHeaders: { Cookie: rc }, auth: sockAuth });
    const err = await new Promise((res, rej) => {
      sock.once('connect', () => rej(Error('socket must be denied'))); sock.once('connect_error', res); sock.connect();
    });
    assert.match(err.message, /device_auth_required/);
    sock.disconnect();
    // Bootstrap обычной device-сессии нового устройства (sessionless challenge).
    const devOp = await operationDigest('device-session');
    const dch = await f.request('/api/v2/challenge', { account: 'rec_flow', id: fresh.descriptor.id, operation: devOp });
    assert.equal(dch.response.status, 200);
    const dsess = await f.request('/api/v2/session/device', { account: 'rec_flow', id: fresh.descriptor.id,
      nonce: dch.result.nonce, proof: await sign(requestText('rec_flow', fresh.descriptor.id, dch.result.nonce, devOp), fresh.session.signing) });
    assert.equal(dsess.response.status, 200);
    const dc = cookieOf(dsess);
    // Обычная device-сессия нового устройства работает: fetch.
    const fetchOp = await operationDigest('fetch');
    const fch = await f.request('/api/v2/challenge', { account: 'rec_flow', id: fresh.descriptor.id, operation: fetchOp }, dc);
    const fetched = await f.request('/api/v2/operation', { op: 'fetch', body: null,
      auth: { account: 'rec_flow', id: fresh.descriptor.id, nonce: fch.result.nonce,
        proof: await sign(requestText('rec_flow', fresh.descriptor.id, fch.result.nonce, fetchOp), fresh.session.signing) } }, dc);
    assert.equal(fetched.response.status, 200);
    assert.deepEqual(fetched.result, []);
    // Старое устройство больше не может получить challenge (retired).
    assert.equal((await f.request('/api/v2/challenge', { account: 'rec_flow', id: oldId, operation: fetchOp }, dc)).response.status, 400);
  } finally { await f.close(); }
});

test('regression: normal device sessions and ops are unchanged by recovery support', { timeout: 120000 }, async () => {
  const f = await fixture(await opts());
  try {
    const alice = await makeIdentity('rec_reg_a');
    const bob = await makeIdentity('rec_reg_b');
    const ac = await f.login('synthetic-rec_reg_a'), bc = await f.login('synthetic-rec_reg_b');
    await register(f, alice, ac); await register(f, bob, bc);
    // Обычные ops доступны Google-сессии с device-proof.
    assert.equal((await operation(f, alice, ac, 'users')).response.status, 200);
    const dir = await operation(f, alice, ac, 'directory', 'rec_reg_b');
    assert.equal(dir.response.status, 200);
    assert.equal(dir.result.history.length, 1);
    // send/fetch между аккаунтами.
    const msg = await sealMessage('regression hello', [alice.manifest], [bob.manifest], alice.session, trust(alice, bob));
    assert.equal((await operation(f, alice, ac, 'send', msg)).response.status, 200);
    const inbox = await operation(f, bob, bc, 'fetch');
    assert.equal(inbox.response.status, 200);
    assert.equal(await openMessage(inbox.result.find(b => b.message.id === msg.id), bob.session, trust(alice, bob)), 'regression hello');
    // Обычный install (device signer, v2 possession proof) не изменился.
    const second = await newDevice('rec_reg_a');
    const m2 = await approveDevices(alice.genesis, [alice.manifest], [descriptor(alice.vault), second.descriptor], alice.session);
    const inst = await operation(f, alice, ac, 'install',
      { manifest: m2, proofs: [await pairingProofV2('rec_reg_a', second.vault, second.session)], genesis: alice.genesis });
    assert.equal(inst.response.status, 200);
    assert.equal(inst.result.revision, 2);
    // Socket обычной сессии работает.
    const sock = io(f.origin, { autoConnect: false, transports: ['websocket'], extraHeaders: { Cookie: ac },
      auth: await proof(f, alice, ac, 'socket') });
    await new Promise((res, rej) => { sock.once('connect', res); sock.once('connect_error', rej); sock.connect(); });
    sock.disconnect();
  } finally { await f.close(); }
});
