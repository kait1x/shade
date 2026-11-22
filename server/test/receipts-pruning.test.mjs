// Pruning receipts (SYNC_PLAN §5.3): окно дедупа = TTL очередей 7 дней,
// глобальный cap 10000 не исчерпывается навсегда; legacy-снапшоты без receiptAt
// загружаются консервативно; дедуп в очереди не плодит копии при ретраях.
import { test, before } from 'node:test';
import assert from 'node:assert/strict';
import { createDeviceRegistry, operationDigest } from '../multidevice/registry.mjs';
import { createVault, unlockVault, descriptor, createRecoveryBackup, finalizeRecoveryBackup,
  createGenesis, approveDevices, pairingProof, sealMessage } from '../../client/web/device_crypto.mjs';
import { sign, requestText, hash, messageText } from '../../client/web/protocol/device-v2.mjs';

const password = 'synthetic device password 2026 only';
const recoveryPassword = 'independent synthetic offline recovery passphrase only';
let alice, bob;
async function identity(account) {
  const vault = await createVault(account, password);
  const session = await unlockVault(vault, password);
  let backup = await createRecoveryBackup(account, vault.signingKey, recoveryPassword);
  const genesis = await createGenesis(vault, session, backup.publicKey);
  backup = await finalizeRecoveryBackup(backup, recoveryPassword, genesis);
  const manifest = await approveDevices(genesis, [], [descriptor(vault)], session);
  return { vault, session, genesis, backup, manifest };
}
before(async () => { alice = await identity('pr_alice'); bob = await identity('pr_bob'); });
function fixture() {
  let saved, now = Date.now();
  return { create: extra => createDeviceRegistry({ users: new Map(), clock: () => now,
    persist: async snapshot => { saved = snapshot; }, verifyGoogle: async token => ({ googleSub: token }), ...extra }),
    saved: () => saved, advance: ms => { now += ms; }, now: () => now };
}
async function register(registry, who) {
  return registry.register({ genesis: who.genesis, manifest: who.manifest,
    googleIdToken: `verified:${who.genesis.account}`, proofs: [await pairingProof(who.vault, who.session)] });
}
async function authenticate(registry, session, operation) {
  const nonce = registry.challenge(session.account, session.id, operation);
  return { account: session.account, id: session.id, nonce,
    proof: await sign(requestText(session.account, session.id, nonce, operation), session.signing) };
}
const trust = (a, b) => ({ senderRoot: a.genesis.firstDevice.signingKey,
  recipientRoot: b.genesis.firstDevice.signingKey, senderGenesis: a.genesis, recipientGenesis: b.genesis });
async function send(registry, from, to, text, now = Date.now()) {
  const m = await sealMessage(text, from.history || [from.manifest], to.history || [to.manifest], from.session, trust(from, to), now);
  const r = await registry.send(m, await authenticate(registry, from.session, await operationDigest('send', await hash(messageText(m)))));
  return { m, r };
}
const DAY = 24 * 60 * 60 * 1000;

test('dedup within TTL window; retry never duplicates queue copies', async () => {
  const f = fixture(); const r = await f.create();
  await register(r, alice); await register(r, bob);
  const { m, r: first } = await send(r, alice, bob, 'one');
  assert.equal(first.duplicate, false);
  const again = await r.send(m, await authenticate(r, alice.session, await operationDigest('send', await hash(messageText(m)))));
  assert.equal(again.duplicate, true);
  const inbox = await r.fetch(await authenticate(r, bob.session, await operationDigest('fetch')));
  assert.equal(inbox.filter(b => b.message.id === m.id).length, 1);
});

test('pruneReceipts skips persistence when no receipts are expired', async () => {
  const f = fixture(); const r = await f.create();
  await register(r, alice); await register(r, bob);
  await send(r, alice, bob, 'fresh message');
  const snapshot = f.saved();

  assert.equal(await r.pruneReceipts(), 0);
  assert.strictEqual(f.saved(), snapshot);

  f.advance(8 * DAY);
  assert.equal(await r.pruneReceipts(), 1);
  assert.notStrictEqual(f.saved(), snapshot);
});

test('pruneReceipts removes only expired receipts/delivery; fresh survive; retract of pruned ref purges queues without tombstone', async () => {
  const f = fixture(); const r = await f.create();
  await register(r, alice); await register(r, bob);
  const old = await send(r, alice, bob, 'old message');
  f.advance(8 * DAY);
  // Lease каталога 24 ч: после advance обновляем манифесты тем же clock.
  // Локальные копии identity: общие фикстуры before-хука не мутируем.
  const renewed = new Map();
  for (const who of [alice, bob]) {
    const renewal = await approveDevices(who.genesis, [who.manifest], [descriptor(who.vault)], who.session, undefined, f.now());
    await r.install(renewal, []);
    renewed.set(who, { ...who, manifest: renewal, history: [who.manifest, renewal] });
  }
  const A = renewed.get(alice), B = renewed.get(bob);
  const fresh = await send(r, A, B, 'fresh message', f.now());
  assert.equal(await r.pruneReceipts(), 1);
  // Старый id после prune не принимается повторно: ревизии/время зафиксированы
  // в ciphertext ('Stale device directory'/'Expired message') — оригинал уже в
  // очереди, потери нет и дублей нет.
  const oldAuth = await authenticate(r, A.session, await operationDigest('send', await hash(messageText(old.m))));
  await assert.rejects(() => r.send(old.m, oldAuth), /Stale device directory|Expired message/);
  const inbox = await r.fetch(await authenticate(r, B.session, await operationDigest('fetch')));
  assert.equal(inbox.filter(b => b.message.id === old.m.id).length, 1);
  assert.equal(inbox.filter(b => b.message.id === fresh.m.id).length, 1);
  // Свежая квитанция жива: повтор fresh = duplicate.
  const freshAgain = await r.send(fresh.m, await authenticate(r, A.session, await operationDigest('send', await hash(messageText(fresh.m)))));
  assert.equal(freshAgain.duplicate, true);
  // Отзыв pruned-ссылки: tombstone не создаётся (квитанции нет, квоты не тратятся),
  // но недоставленные копии в очередях явно удаляются — это «удалить у всех»,
  // а не тихая потеря. Доставленное получателем сообщение остаётся у него.
  const refs = [`${A.session.account}:${A.session.id}:${old.m.id}`];
  const ret = await r.retract(refs, await authenticate(r, A.session, await operationDigest('retract', refs)));
  assert.equal(ret.retracted, 0);
  const after = await r.fetch(await authenticate(r, B.session, await operationDigest('fetch')));
  assert.equal(after.filter(b => b.message.id === old.m.id).length, 0);
  assert.equal(after.filter(b => b.message.id === fresh.m.id).length, 1);
});

test('legacy snapshot without receiptAt loads conservatively and prunes after TTL from load', async () => {
  const f = fixture(); const r = await f.create();
  await register(r, alice); await register(r, bob);
  const { m } = await send(r, alice, bob, 'legacy snapshot message');
  const snapshot = structuredClone(f.saved());
  delete snapshot.receiptAt;
  const f2 = fixture();
  const r2 = await f2.create({ snapshot });
  // Сразу после загрузки квитанция ещё жива (консервативный stamp).
  const dup = await r2.send(m, await authenticate(r2, alice.session, await operationDigest('send', await hash(messageText(m)))));
  assert.equal(dup.duplicate, true);
  f2.advance(8 * DAY);
  assert.equal(await r2.pruneReceipts(), 1);
});