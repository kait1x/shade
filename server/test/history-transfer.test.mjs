// history.transfer (SYNC_PLAN §5.2): per-device staging E2EE-пакетов истории
// между устройствами одного аккаунта; сервер хранит ciphertext как есть,
// дедуп по id, курсор, лимиты, запрет recovery-сессиям и чужим аккаунтам.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { createDeviceRegistry, operationDigest } from '../multidevice/registry.mjs';
import { createVault, unlockVault, descriptor, createRecoveryBackup, finalizeRecoveryBackup,
  createGenesis, approveDevices, pairingProof, unlockRecoveryBackup } from '../../client/web/device_crypto.mjs';
import { sign, requestText, hash, genesisText } from '../../client/web/protocol/device-v2.mjs';
import { fixture, register as alphaRegister } from './helpers/alpha-fixture.mjs';

const password = 'synthetic device password 2026 only';
const recoveryPassword = 'independent synthetic offline recovery passphrase only';
let alice, alice2, bob;
async function device(account, suffix = '') {
  const vault = await createVault(account, password + suffix);
  return { vault, session: await unlockVault(vault, password + suffix), descriptor: descriptor(vault) };
}
before(async () => {
  alice = await device('ht_alice');
  alice2 = await device('ht_alice', ' second');
  let backup = await createRecoveryBackup('ht_alice', alice.vault.signingKey, recoveryPassword);
  const genesis = await createGenesis(alice.vault, alice.session, backup.publicKey);
  backup = await finalizeRecoveryBackup(backup, recoveryPassword, genesis);
  alice.genesis = genesis; alice.backup = backup;
  alice.manifest = await approveDevices(genesis, [], [alice.descriptor, alice2.descriptor], alice.session);
  bob = await device('ht_bob');
  let b2 = await createRecoveryBackup('ht_bob', bob.vault.signingKey, recoveryPassword);
  const g2 = await createGenesis(bob.vault, bob.session, b2.publicKey);
  b2 = await finalizeRecoveryBackup(b2, recoveryPassword, g2);
  bob.genesis = g2; bob.backup = b2;
  bob.manifest = await approveDevices(g2, [], [bob.descriptor], bob.session);
});
function fixtureReg() {
  let now = Date.now();
  return { create: () => createDeviceRegistry({ users: new Map(), clock: () => now,
    persist: async () => true, verifyGoogle: async token => ({ googleSub: token }) }), advance: ms => { now += ms; } };
}
async function register(registry, who, extraProofs = []) {
  return registry.register({ genesis: who.genesis, manifest: who.manifest,
    googleIdToken: `verified:${who.genesis.account}`,
    proofs: [await pairingProof(who.vault, who.session), ...extraProofs] });
}
async function authenticate(registry, session, operation, body = null) {
  const nonce = registry.challenge(session.account, session.id, operation);
  return { account: session.account, id: session.id, nonce,
    proof: await sign(requestText(session.account, session.id, nonce, operation), session.signing) };
}
const pkg = (seq, size = 32) => ({ id: randomBytes(32).toString('hex'), seq, payload: randomBytes(size).toString('base64') });
async function transfer(r, session, to, packages) {
  return r.historyTransfer({ to, packages }, await authenticate(r, session, await operationDigest('history.transfer', { to, packages }), { to, packages }));
}
async function fetchH(r, session, since = 0) {
  return r.historyFetch({ since }, await authenticate(r, session, await operationDigest('history.fetch', { since }), { since }));
}
async function ackH(r, session, ids) {
  return r.historyAck({ ids }, await authenticate(r, session, await operationDigest('history.ack', { ids }), { ids }));
}

test('transfer → fetch by cursor → ack; ciphertext stored as-is; order preserved; dedup by id', async () => {
  const r = await fixtureReg().create();
  await register(r, alice, [await pairingProof(alice2.vault, alice2.session)]);
  const packages = [pkg(3), pkg(1), pkg(2)];
  const t = await transfer(r, alice.session, alice2.session.id, packages);
  assert.equal(t.added, 3);
  // Повторная отправка тех же пакетов — идемпотентна.
  const again = await transfer(r, alice.session, alice2.session.id, packages);
  assert.equal(again.added, 0); assert.equal(again.duplicate, 3);
  const got = await fetchH(r, alice2.session, 0);
  assert.deepEqual(got.packages.map(p => p.seq), [1, 2, 3]);
  assert.deepEqual(got.packages.map(p => p.payload), [...packages].sort((a, b) => a.seq - b.seq).map(p => p.payload));
  assert.equal(got.cursor, 3);
  const partial = await fetchH(r, alice2.session, 1);
  assert.deepEqual(partial.packages.map(p => p.seq), [2, 3]);
  const a1 = await ackH(r, alice2.session, got.packages.slice(0, 2).map(p => p.id));
  assert.equal(a1.acked, 2);
  assert.equal((await ackH(r, alice2.session, got.packages.slice(0, 2).map(p => p.id))).acked, 0);
  const rest = await fetchH(r, alice2.session, 0);
  assert.deepEqual(rest.packages.map(p => p.seq), [3]);
  assert.equal((await ackH(r, alice2.session, [rest.packages[0].id])).acked, 1);
  assert.equal((await fetchH(r, alice2.session, 0)).packages.length, 0);
});

test('limits: oversized package, too many packages per call, staging capacity; foreign target rejected', async () => {
  const r = await fixtureReg().create();
  await register(r, alice, [await pairingProof(alice2.vault, alice2.session)]);
  await register(r, bob);
  await assert.rejects(() => transfer(r, alice.session, alice2.session.id, [{ id: randomBytes(32).toString('hex'), seq: 1, payload: 'A'.repeat(87385) }]), /Invalid history package/);
  await assert.rejects(() => transfer(r, alice.session, alice2.session.id, Array.from({ length: 51 }, (_, i) => pkg(i + 1))), /Invalid transfer body/);
  await assert.rejects(() => transfer(r, alice.session, bob.session.id, [pkg(1)]), /Revoked or unknown target device/);
  // Объём-потолок 64 МиБ: 768 пакетов по 87384 символа base64 пересекают его.
  const big = 'A'.repeat(87384);
  let seq = 0;
  for (let batch = 0; batch < 15; batch++) {
    const ps = Array.from({ length: 50 }, () => ({ id: randomBytes(32).toString('hex'), seq: ++seq, payload: big }));
    await transfer(r, alice.session, alice2.session.id, ps);
  }
  await assert.rejects(() => transfer(r, alice.session, alice2.session.id,
    Array.from({ length: 18 }, () => ({ id: randomBytes(32).toString('hex'), seq: ++seq, payload: big }))), /History staging volume reached/);
});

test('recovery session cannot use history.* ops (alpha-level guard)', async () => {
  await fs.mkdir(path.resolve('build'), { recursive: true });
  const dataDir = await fs.mkdtemp(path.join(path.resolve('build'), 'alpha-ht-'));
  const f = await fixture({ dataDir, storageSecret: randomBytes(32).toString('hex') });
  try {
    const vault = await createVault('ht_alice', password);
    const session = await unlockVault(vault, password);
    let backup = await createRecoveryBackup('ht_alice', vault.signingKey, recoveryPassword);
    const genesis = await createGenesis(vault, session, backup.publicKey);
    backup = await finalizeRecoveryBackup(backup, recoveryPassword, genesis);
    const manifest = await approveDevices(genesis, [], [descriptor(vault)], session);
    const who = { vault, session, genesis, backup, manifest };
    await alphaRegister(f, who, await f.login('synthetic-ht_alice'));
    const ch = await f.request('/api/v2/session/recovery-challenge', { account: 'ht_alice' });
    const recovery = await unlockRecoveryBackup(who.backup, recoveryPassword, who.genesis);
    const opDigest = await operationDigest('recovery-session', await hash(genesisText(who.genesis)));
    const proof = await sign(requestText('ht_alice', 'primary', ch.result.nonce, opDigest), recovery.signing);
    const rc = (await f.request('/api/v2/session/recovery', { account: 'ht_alice', genesis: who.genesis, nonce: ch.result.nonce, proof })).response.headers.getSetCookie().find(s => s.startsWith('shade-alpha=')).split(';')[0];
    for (const op of ['history.transfer', 'history.fetch', 'history.ack']) {
      const reply = await f.request('/api/v2/operation', { op, body: { to: 'x', packages: [], ids: [], since: 0 }, auth: { account: 'ht_alice' } }, rc);
      assert.equal(reply.response.status, 400, op);
    }
  } finally { await f.close(); }
});